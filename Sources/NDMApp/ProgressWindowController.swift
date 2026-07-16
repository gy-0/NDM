import AppKit
import NDMCore
import NDMEngine

/// Modern download progress window — FDM-like information architecture,
/// without the dated utility chrome.
@MainActor
final class ProgressWindowController: NSWindowController, NSWindowDelegate {
    private let manager: DownloadManager
    private let taskID: Int64
    private var filename: String

    private let tabControl = NSSegmentedControl(
        labels: ["Download", "Options", "Connections"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let tabContainer = NSView()

    // Download tab
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusPill = StatusPillView()
    private let urlValue = LinkLabel()
    private let sizeValue = NSTextField(labelWithString: "—")
    private let downloadedValue = NSTextField(labelWithString: "—")
    private let speedValue = NSTextField(labelWithString: "—")
    private let etaValue = NSTextField(labelWithString: "—")
    private let resumeValue = NSTextField(labelWithString: "—")
    private let overallProgress = NSProgressIndicator()
    private let segmentsCaption = NSTextField(labelWithString: "Segments")
    private let segmentStrip = SegmentStripView()
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let revealButton = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Show in Finder")!, target: nil, action: nil)

    // Options tab
    private let connectionsPopup = NSPopUpButton()
    private let applyConnButton = NSButton(title: "Apply", target: nil, action: nil)
    private let renewButton = NSButton(title: "Renew URL…", target: nil, action: nil)
    private let optionsNote = NSTextField(wrappingLabelWithString: "Change connection count while downloading to replan active Range transfers. Renew replaces an expired URL without discarding partial segments.")

    // Connections tab
    private let connectionScrollView = NSScrollView()
    private let connectionStack = NSStackView()
    private var connectionRows: [Int: ConnectionProgressRowView] = [:]
    private var displayedConnectionIDs: [Int] = []

    private var downloadPane: NSView!
    private var optionsPane: NSView!
    private var connectionsPane: NSView!
    private var pollTask: Task<Void, Never>?
    private var lastStatus: DownloadStatus = .waiting

    init(manager: DownloadManager, taskID: Int64, filename: String) {
        self.manager = manager
        self.taskID = taskID
        self.filename = filename
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 460, height: 420)
        window.title = filename
        window.titlebarAppearsTransparent = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        startPolling()
        Task { await bootstrap() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        tabControl.segmentStyle = .texturedRounded
        tabControl.selectedSegment = 0
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        tabContainer.translatesAutoresizingMaskIntoConstraints = false
        downloadPane = makeDownloadPane()
        optionsPane = makeOptionsPane()
        connectionsPane = makeConnectionsPane()
        for pane in [downloadPane!, optionsPane!, connectionsPane!] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            tabContainer.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: tabContainer.topAnchor),
                pane.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
                pane.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
            ])
        }
        showTab(0)

        content.addSubview(tabControl)
        content.addSubview(tabContainer)
        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            tabControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tabControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),

            tabContainer.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 14),
            tabContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tabContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            tabContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func makeDownloadPane() -> NSView {
        percentLabel.font = .systemFont(ofSize: 36, weight: .semibold)
        percentLabel.textColor = .labelColor
        nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.stringValue = filename

        overallProgress.isIndeterminate = false
        overallProgress.minValue = 0
        overallProgress.maxValue = 1
        overallProgress.controlSize = .regular
        overallProgress.style = .bar

        segmentsCaption.font = .systemFont(ofSize: 11, weight: .semibold)
        segmentsCaption.textColor = .secondaryLabelColor
        segmentStrip.translatesAutoresizingMaskIntoConstraints = false

        styleValue(sizeValue)
        styleValue(downloadedValue)
        styleValue(speedValue)
        styleValue(etaValue)
        styleValue(resumeValue)

        let header = NSStackView(views: [percentLabel, nameLabel, statusPill])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4

        let card = makeStatsCard()

        pauseButton.bezelStyle = .rounded
        pauseButton.setButtonType(.momentaryPushIn)
        pauseButton.keyEquivalent = ""
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pauseButton.controlSize = .large

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.controlSize = .large

        revealButton.bezelStyle = .flexiblePush
        revealButton.isBordered = true
        revealButton.target = self
        revealButton.action = #selector(revealClicked)
        revealButton.toolTip = "Show in Finder"

        let actions = NSStackView(views: [pauseButton, cancelButton])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.distribution = .fillEqually

        let stripBlock = NSStackView(views: [segmentsCaption, segmentStrip])
        stripBlock.orientation = .vertical
        stripBlock.alignment = .leading
        stripBlock.spacing = 6

        let stack = NSStackView(views: [
            header,
            card,
            overallProgress,
            stripBlock,
            actions,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let pane = NSView()
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            overallProgress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            overallProgress.heightAnchor.constraint(equalToConstant: 12),
            segmentStrip.widthAnchor.constraint(equalTo: stack.widthAnchor),
            segmentStrip.heightAnchor.constraint(equalToConstant: 18),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pauseButton.heightAnchor.constraint(equalToConstant: 32),
            cancelButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        return pane
    }

    private func makeStatsCard() -> NSView {
        let rows: [(String, NSView)] = [
            ("URL", urlValue),
            ("Size", sizeValue),
            ("Downloaded", downloadedValue),
            ("Speed", speedValue),
            ("Time left", etaValue),
            ("Resumable", resumeValue),
        ]

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 8
        grid.alignment = .leading

        for (title, value) in rows {
            let key = NSTextField(labelWithString: title)
            key.font = .systemFont(ofSize: 12)
            key.textColor = .secondaryLabelColor
            key.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            key.widthAnchor.constraint(equalToConstant: 88).isActive = true

            if value is LinkLabel {
                // keep
            } else if let field = value as? NSTextField {
                field.lineBreakMode = .byTruncatingMiddle
            }

            let row = NSStackView(views: [key, value])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 10
            row.distribution = .fill
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }

        // Status row with pill + reveal
        let statusKey = NSTextField(labelWithString: "Status")
        statusKey.font = .systemFont(ofSize: 12)
        statusKey.textColor = .secondaryLabelColor
        statusKey.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let statusRow = NSStackView(views: [statusKey, statusPill, NSView(), revealButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 10
        grid.insertArrangedSubview(statusRow, at: 1)
        statusRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        revealButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        revealButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        updateCardChrome(card)
        grid.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])

        return card
    }

    private func updateCardChrome(_ card: NSView) {
        let isDark = card.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        card.layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.black.withAlphaComponent(0.03)).cgColor
        card.layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.08)).cgColor
    }

    private func makeOptionsPane() -> NSView {
        connectionsPopup.removeAllItems()
        for i in 1...32 { connectionsPopup.addItem(withTitle: "\(i)") }

        applyConnButton.bezelStyle = .rounded
        applyConnButton.target = self
        applyConnButton.action = #selector(applyConnections)
        renewButton.bezelStyle = .rounded
        renewButton.target = self
        renewButton.action = #selector(renewClicked)

        optionsNote.font = .systemFont(ofSize: 12)
        optionsNote.textColor = .secondaryLabelColor

        let connLabel = NSTextField(labelWithString: "Connections")
        connLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let connRow = NSStackView(views: [connLabel, connectionsPopup, applyConnButton])
        connRow.orientation = .horizontal
        connRow.spacing = 10
        connRow.alignment = .centerY

        let stack = NSStackView(views: [connRow, renewButton, optionsNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let pane = NSView()
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            optionsNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return pane
    }

    private func makeConnectionsPane() -> NSView {
        connectionStack.orientation = .vertical
        connectionStack.alignment = .leading
        connectionStack.spacing = 0
        connectionStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(connectionStack)
        connectionScrollView.documentView = document
        connectionScrollView.hasVerticalScroller = true
        connectionScrollView.drawsBackground = false
        connectionScrollView.borderType = .noBorder
        connectionScrollView.translatesAutoresizingMaskIntoConstraints = false

        let pane = NSView()
        pane.addSubview(connectionScrollView)
        NSLayoutConstraint.activate([
            connectionStack.topAnchor.constraint(equalTo: document.topAnchor),
            connectionStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            connectionStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            connectionStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: connectionScrollView.contentView.widthAnchor),

            connectionScrollView.topAnchor.constraint(equalTo: pane.topAnchor),
            connectionScrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            connectionScrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            connectionScrollView.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            connectionScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        return pane
    }

    private func styleValue(_ field: NSTextField) {
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.textColor = .labelColor
    }

    private func showTab(_ index: Int) {
        downloadPane.isHidden = index != 0
        optionsPane.isHidden = index != 1
        connectionsPane.isHidden = index != 2
    }

    @objc private func tabChanged() {
        showTab(tabControl.selectedSegment)
    }

    // MARK: - Data

    private func bootstrap() async {
        if let task = try? await manager.task(id: taskID) {
            filename = task.filename.isEmpty ? filename : task.filename
            nameLabel.stringValue = filename
            urlValue.setURL(task.url)
            resumeValue.stringValue = task.resumable ? "Yes" : "No"
            resumeValue.textColor = task.resumable ? .systemGreen : .secondaryLabelColor
            let n = max(1, min(32, task.connections))
            connectionsPopup.selectItem(at: n - 1)
            sizeValue.stringValue = task.fileSize > 0
                ? TaskPresentationFormatting.byteCount(task.fileSize)
                : "—"
        }
        await refresh()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func refresh() async {
        let task = try? await manager.task(id: taskID)
        if let task {
            filename = task.filename.isEmpty ? filename : task.filename
            nameLabel.stringValue = filename
            urlValue.setURL(task.url)
            resumeValue.stringValue = task.resumable ? "Yes" : "No"
            resumeValue.textColor = task.resumable ? .systemGreen : .secondaryLabelColor
            if task.fileSize > 0 {
                sizeValue.stringValue = TaskPresentationFormatting.byteCount(task.fileSize)
            }
        }

        if let progress = await manager.progress(taskID: taskID) {
            apply(progress: progress, task: task)
            if progress.status == .complete || progress.status == .error || progress.status == .paused {
                // Keep showing final state; pause polling for terminal-ish states except allow resume view.
                if progress.status == .complete || progress.status == .error {
                    pollTask?.cancel()
                }
            }
            return
        }

        if let task {
            let synthetic = DownloadProgress(
                taskID: taskID,
                totalBytes: task.fileSize,
                completedBytes: task.status == .complete ? task.fileSize : 0,
                status: task.status,
                errorDescription: task.errorText
            )
            apply(progress: synthetic, task: task)
            if task.status == .complete || task.status == .error {
                pollTask?.cancel()
            }
        }
    }

    private func apply(progress: DownloadProgress, task: DownloadTask?) {
        lastStatus = progress.status
        let fraction = progress.fractionCompleted
        let pct = Int((fraction * 100).rounded(.down))
        percentLabel.stringValue = "\(pct)%"
        window?.title = "\(pct)% \(filename)"

        overallProgress.doubleValue = fraction
        statusPill.setStatus(progress.status, error: progress.errorDescription ?? task?.errorText)

        let total = max(progress.totalBytes, task?.fileSize ?? 0)
        let done = progress.completedBytes
        if total > 0 {
            sizeValue.stringValue = TaskPresentationFormatting.byteCount(total)
        }
        let pctFine = total > 0 ? String(format: "%.1f", fraction * 100) : "0"
        downloadedValue.stringValue = total > 0
            ? "\(TaskPresentationFormatting.byteCount(done))  (\(pctFine)%)"
            : TaskPresentationFormatting.byteCount(done)

        speedValue.stringValue = TaskPresentationFormatting.speed(progress.bytesPerSecond, status: progress.status)
        etaValue.stringValue = TaskPresentationFormatting.eta(progress.remainingTime, status: progress.status)

        let segments = progress.segmentStates.sorted { $0.id < $1.id }
        segmentsCaption.stringValue = segments.isEmpty ? "Segments" : "Segments · \(segments.count)"
        segmentStrip.update(segments: segments, totalBytes: total)

        pauseButton.title = (progress.status == .paused || progress.status == .incomplete || progress.status == .error)
            ? "Resume"
            : "Pause"
        pauseButton.isEnabled = progress.status != .complete
        cancelButton.isEnabled = progress.status != .complete

        renderConnections(segments, downloadStatus: progress.status)
    }

    private func renderConnections(_ states: [SegmentState], downloadStatus: DownloadStatus) {
        let ids = states.map(\.id)
        if ids != displayedConnectionIDs {
            for view in connectionStack.arrangedSubviews {
                connectionStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            connectionRows.removeAll(keepingCapacity: true)
            displayedConnectionIDs = ids
            for state in states {
                let row = ConnectionProgressRowView()
                connectionRows[state.id] = row
                connectionStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: connectionStack.widthAnchor).isActive = true
            }
        }
        for state in states {
            connectionRows[state.id]?.update(state: state, downloadStatus: downloadStatus)
        }
    }

    // MARK: - Actions

    @objc private func pauseClicked() {
        Task {
            if lastStatus == .paused || lastStatus == .incomplete || lastStatus == .error {
                do {
                    try await manager.start(taskID: taskID)
                    startPolling()
                } catch {
                    NSAlert(error: error).runModal()
                }
            } else {
                await manager.pause(taskID: taskID)
            }
            await refresh()
        }
    }

    @objc private func cancelClicked() {
        Task {
            await manager.pause(taskID: taskID)
            window?.close()
        }
    }

    @objc private func revealClicked() {
        Task {
            guard let task = try? await manager.task(id: taskID),
                  let url = task.destinationFileURL else { return }
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }

    @objc private func applyConnections() {
        let n = connectionsPopup.indexOfSelectedItem + 1
        Task {
            do {
                try await manager.applyConnections(taskID: taskID, count: n)
                startPolling()
                await refresh()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func renewClicked() {
        let alert = NSAlert()
        alert.messageText = "Renew URL"
        alert.informativeText = "Paste a fresh URL for this task (keeps partial segments)."
        alert.addButton(withTitle: "Renew")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        alert.accessoryView = field
        alert.layout()
        alert.window.initialFirstResponder = field
        _ = alert.window.makeFirstResponder(field)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        Task {
            do {
                try await manager.renewURL(taskID: taskID, newURL: url)
                try await manager.start(taskID: taskID)
                startPolling()
                await refresh()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        pollTask?.cancel()
        pollTask = nil
    }
}

// MARK: - Segment strip

/// Compact file-map visualization: each Range paints its completed span.
private final class SegmentStripView: NSView {
    private var segments: [SegmentState] = []
    private var totalBytes: Int64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(segments: [SegmentState], totalBytes: Int64) {
        self.segments = segments
        self.totalBytes = totalBytes
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let track = NSColor.quaternaryLabelColor
        track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()

        guard totalBytes > 0, !segments.isEmpty else { return }

        let accent = NSColor.controlAccentColor
        let done = NSColor.systemGreen.withAlphaComponent(0.85)

        for segment in segments {
            let startFrac = Double(segment.start) / Double(totalBytes)
            let completedFrac = Double(min(segment.length, max(0, segment.completed))) / Double(totalBytes)
            let x = bounds.minX + CGFloat(startFrac) * bounds.width
            let w = max(1, CGFloat(completedFrac) * bounds.width)
            let rect = NSRect(x: x, y: bounds.minY, width: w, height: bounds.height)
            let color = (segment.isFinished || segment.fractionCompleted >= 1) ? done : accent
            color.setFill()
            rect.fill()
        }

        // Subtle separators between planned segment starts.
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        for segment in segments.dropFirst() {
            let x = bounds.minX + CGFloat(Double(segment.start) / Double(totalBytes)) * bounds.width
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: bounds.minY))
            path.line(to: NSPoint(x: x, y: bounds.maxY))
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - Status pill

private final class StatusPillView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        setStatus(.waiting, error: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setStatus(_ status: DownloadStatus, error: String?) {
        let title: String
        let fg: NSColor
        let bg: NSColor
        switch status {
        case .downloading:
            title = "Downloading"
            fg = .systemBlue
            bg = NSColor.systemBlue.withAlphaComponent(0.14)
        case .paused:
            title = "Paused"
            fg = .systemOrange
            bg = NSColor.systemOrange.withAlphaComponent(0.14)
        case .complete:
            title = "Completed"
            fg = .systemGreen
            bg = NSColor.systemGreen.withAlphaComponent(0.14)
        case .error:
            title = error?.isEmpty == false ? "Failed" : "Failed"
            fg = .systemRed
            bg = NSColor.systemRed.withAlphaComponent(0.14)
        case .waiting:
            title = "Queued"
            fg = .secondaryLabelColor
            bg = NSColor.quaternaryLabelColor.withAlphaComponent(0.35)
        case .incomplete:
            title = "Incomplete"
            fg = .secondaryLabelColor
            bg = NSColor.quaternaryLabelColor.withAlphaComponent(0.35)
        }
        label.stringValue = title
        label.textColor = fg
        layer?.backgroundColor = bg.cgColor
        toolTip = error
    }
}

// MARK: - Clickable URL

private final class LinkLabel: NSTextField {
    private var urlString = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 12)
        textColor = .linkColor
        lineBreakMode = .byTruncatingMiddle
        isSelectable = true
        allowsEditingTextAttributes = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setURL(_ string: String) {
        urlString = string
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.linkColor,
            .font: NSFont.systemFont(ofSize: 12),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        attributedStringValue = NSAttributedString(string: string, attributes: attrs)
        toolTip = string
    }

    override func mouseDown(with event: NSEvent) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Connection rows (Connections tab)

@MainActor
private final class ConnectionProgressRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let rangeLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .right
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor
        rangeLabel.lineBreakMode = .byTruncatingMiddle

        progress.isIndeterminate = false
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        separator.boxType = .separator

        for view in [titleLabel, stateLabel, rangeLabel, progress, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 54),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stateLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            stateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            progress.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            progress.heightAnchor.constraint(equalToConstant: 7),
            rangeLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 4),
            rangeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            rangeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(state: SegmentState, downloadStatus: DownloadStatus) {
        let fraction = state.fractionCompleted
        let percent = Int((fraction * 100).rounded(.down))
        titleLabel.stringValue = "Connection \(state.id + 1)"
        progress.doubleValue = fraction

        let status: String
        let statusColor: NSColor
        if state.isFinished || fraction >= 1 {
            status = "Complete"
            statusColor = .systemGreen
        } else {
            switch downloadStatus {
            case .paused:
                status = "Paused"
                statusColor = .systemOrange
            case .error:
                status = "Error"
                statusColor = .systemRed
            case .waiting:
                status = "Waiting"
                statusColor = .secondaryLabelColor
            default:
                status = state.completed > 0 ? "Downloading" : "Waiting"
                statusColor = state.completed > 0 ? .controlAccentColor : .secondaryLabelColor
            }
        }
        stateLabel.stringValue = "\(status) · \(percent)%"
        stateLabel.textColor = statusColor

        let completed = ByteCountFormatter.string(
            fromByteCount: max(0, min(state.length, state.completed)),
            countStyle: .file
        )
        let length = ByteCountFormatter.string(fromByteCount: state.length, countStyle: .file)
        rangeLabel.stringValue = "Range \(Self.integer(state.start))–\(Self.integer(state.end)) · \(completed) / \(length)"
    }

    private static func integer(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
