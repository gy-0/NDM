import AppKit
import NDMCore
import NDMEngine

/// Lightweight stand-in for original `NeatDownloadWindowController` progress UI.
@MainActor
final class ProgressWindowController: NSWindowController, NSWindowDelegate {
    private let manager: DownloadManager
    private let taskID: Int64
    private let filenameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let connectionsSummaryLabel = NSTextField(labelWithString: "Connections")
    private let connectionScrollView = NSScrollView()
    private let connectionStack = NSStackView()
    private let connectionsPopup = NSPopUpButton()
    private var connectionRows: [Int: ConnectionProgressRowView] = [:]
    private var displayedConnectionIDs: [Int] = []
    private var pollTask: Task<Void, Never>?

    init(manager: DownloadManager, taskID: Int64, filename: String) {
        self.manager = manager
        self.taskID = taskID
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 560, height: 440)
        window.title = "Download Progress"
        window.center()
        super.init(window: window)
        window.delegate = self
        filenameLabel.stringValue = filename
        buildUI()
        startPolling()
        Task { await loadConnections() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        filenameLabel.font = .boldSystemFont(ofSize: 13)
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 12)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .small

        connectionsSummaryLabel.font = .boldSystemFont(ofSize: 12)
        connectionStack.orientation = .vertical
        connectionStack.alignment = .leading
        connectionStack.spacing = 0
        connectionStack.translatesAutoresizingMaskIntoConstraints = false

        let connectionDocument = FlippedDocumentView()
        connectionDocument.translatesAutoresizingMaskIntoConstraints = false
        connectionDocument.addSubview(connectionStack)
        connectionScrollView.documentView = connectionDocument
        connectionScrollView.hasVerticalScroller = true
        connectionScrollView.drawsBackground = false
        connectionScrollView.borderType = .noBorder
        connectionScrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            connectionStack.topAnchor.constraint(equalTo: connectionDocument.topAnchor),
            connectionStack.leadingAnchor.constraint(equalTo: connectionDocument.leadingAnchor),
            connectionStack.trailingAnchor.constraint(equalTo: connectionDocument.trailingAnchor),
            connectionStack.bottomAnchor.constraint(equalTo: connectionDocument.bottomAnchor),
            connectionDocument.widthAnchor.constraint(equalTo: connectionScrollView.contentView.widthAnchor),
        ])

        connectionsPopup.removeAllItems()
        for i in 1...32 { connectionsPopup.addItem(withTitle: "\(i)") }

        let applyConn = NSButton(title: "Apply Connections", target: self, action: #selector(applyConnections))
        applyConn.bezelStyle = .rounded
        let pause = NSButton(title: "Pause", target: self, action: #selector(pauseClicked))
        pause.bezelStyle = .rounded
        let renew = NSButton(title: "Renew URL…", target: self, action: #selector(renewClicked))
        renew.bezelStyle = .rounded

        let connRow = NSStackView(views: [
            NSTextField(labelWithString: "Connections"),
            connectionsPopup,
            applyConn,
        ])
        connRow.orientation = .horizontal
        connRow.spacing = 8

        let btnRow = NSStackView(views: [pause, renew])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8

        let stack = NSStackView(views: [
            filenameLabel,
            statusLabel,
            progressBar,
            detailLabel,
            connectionsSummaryLabel,
            connectionScrollView,
            connRow,
            btnRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 10),
            connectionScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            connectionScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    private func loadConnections() async {
        if let t = try? await manager.task(id: taskID) {
            let n = max(1, min(32, t.connections))
            connectionsPopup.selectItem(at: n - 1)
        }
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
        if let p = await manager.progress(taskID: taskID) {
            progressBar.doubleValue = p.fractionCompleted
            let pct = Int(p.fractionCompleted * 100)
            statusLabel.stringValue = "\(p.status.rawValue) — \(pct)%"
            let done = ByteCountFormatter.string(fromByteCount: p.completedBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .file)
            let speed = ByteCountFormatter.string(fromByteCount: Int64(p.bytesPerSecond), countStyle: .file)
            let segs = p.segmentStates.isEmpty ? "" : " · \(p.segmentStates.count) segments"
            detailLabel.stringValue = "\(done) / \(total) · \(speed)/s\(segs)"
            renderConnections(p.segmentStates, downloadStatus: p.status)
            if p.status == .complete || p.status == .error || p.status == .paused {
                pollTask?.cancel()
            }
            return
        }
        if let tasks = try? await manager.listTasks(),
           let t = tasks.first(where: { $0.id == taskID }) {
            statusLabel.stringValue = t.status.rawValue
            if t.status == .complete {
                progressBar.doubleValue = 1
                detailLabel.stringValue = ByteCountFormatter.string(fromByteCount: t.fileSize, countStyle: .file)
                pollTask?.cancel()
            }
        }
    }

    private func renderConnections(_ states: [SegmentState], downloadStatus: DownloadStatus) {
        // Connection numbers are the user's stable mental model. Dynamic
        // tail-splitting means byte-range order may be 1, 9, 5, ...; sorting
        // by id keeps the UI predictably Connection 1, 2, 3, ... while each
        // row still shows its exact live Range.
        let sorted = states.sorted { $0.id < $1.id }
        let ids = sorted.map(\.id)

        if ids != displayedConnectionIDs {
            for view in connectionStack.arrangedSubviews {
                connectionStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            connectionRows.removeAll(keepingCapacity: true)
            displayedConnectionIDs = ids

            for state in sorted {
                let row = ConnectionProgressRowView()
                connectionRows[state.id] = row
                connectionStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: connectionStack.widthAnchor).isActive = true
            }
        }

        connectionsSummaryLabel.stringValue = sorted.isEmpty
            ? "Connections"
            : "Connections (\(sorted.count))"
        for state in sorted {
            connectionRows[state.id]?.update(state: state, downloadStatus: downloadStatus)
        }
    }

    @objc private func pauseClicked() {
        Task {
            await manager.pause(taskID: taskID)
            await refresh()
        }
    }

    @objc private func applyConnections() {
        let n = connectionsPopup.indexOfSelectedItem + 1
        Task {
            do {
                try await manager.applyConnections(taskID: taskID, count: n)
                detailLabel.stringValue = "Connections set to \(n) (active Range transfers replanned)"
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        pollTask?.cancel()
        pollTask = nil
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
            } catch {
                let a = NSAlert(error: error)
                a.runModal()
            }
        }
    }
}

/// One real progress track per HTTP Range connection.
///
/// The range, transferred byte count and fraction are all derived from the
/// live `SegmentState`; colour is only a secondary status cue.
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

        setAccessibilityLabel("Connection \(state.id + 1)")
        setAccessibilityValue("\(status), \(percent) percent, byte range \(state.start) through \(state.end)")
    }

    private static func integer(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// Makes the connection list start at Connection 1 instead of the bottom row.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
