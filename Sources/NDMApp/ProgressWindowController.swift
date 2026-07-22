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
        labels: [L10n.tabDownload, L10n.tabOptions, L10n.tabConnections],
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
    private let speedCaptionLabel = NSTextField(labelWithString: "")
    private let downloadedCaptionLabel = NSTextField(labelWithString: "")
    private let etaCaptionLabel = NSTextField(labelWithString: "")
    private let statusCaptionLabel = NSTextField(labelWithString: "")
    private let sizeCaptionLabel = NSTextField(labelWithString: "")
    private let resumeCaptionLabel = NSTextField(labelWithString: "")
    private let overallProgress = ThinProgressView()
    private let speedSparkline = SpeedSparklineView()
    private let segmentsCaption = NSTextField(labelWithString: L10n.segments)
    private let segmentStrip = SegmentStripView()
    private var segmentBlock: NSView?
    private let pauseButton = NSButton(title: L10n.pause, target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.close, target: nil, action: nil)
    private let openButton = NSButton(title: L10n.open, target: nil, action: nil)
    private let revealActionButton = NSButton(title: L10n.showInFinder, target: nil, action: nil)
    private let revealButton = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: L10n.showInFinder)!, target: nil, action: nil)
    private var actionsStack: NSStackView?

    // Options tab
    private let connectionsPopup = NSPopUpButton()
    private let applyConnButton = NSButton(title: L10n.apply, target: nil, action: nil)
    private let renewButton = NSButton(title: L10n.renewURLEllipsis, target: nil, action: nil)
    private let optionsNote = NSTextField(wrappingLabelWithString: L10n.optionsNote)
    private let connectionsCaptionLabel = NSTextField(labelWithString: "")
    private let smartlineLabel = NSTextField(wrappingLabelWithString: "")
    private let completionStackView = CompletionStackView()
    private let audioExtraction = AudioExtractionCoordinator()
    private let audioStatusView = AudioExtractionStatusView()
    private let moreActionsButton = NSButton(title: "", target: nil, action: nil)

    // Connections tab
    private let connectionScrollView = NSScrollView()
    private let connectionStack = NSStackView()
    private var connectionRows: [Int: ConnectionProgressRowView] = [:]
    private var displayedConnectionIDs: [Int] = []

    private var downloadPane: NSView!
    private weak var downloadStack: NSStackView?
    private var optionsPane: NSView!
    private var connectionsPane: NSView!
    private var pollTask: Task<Void, Never>?
    private var lastStatus: DownloadStatus = .waiting
    private var completionStackApplied = false
    private var completionExpansionAddedHeight: CGFloat = 0
    /// Cleared by MainWindowController so the cache does not retain closed windows.
    var onWindowClose: (() -> Void)?

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
        NDMChrome.applyWindowChrome(window)
        window.center()
        super.init(window: window)
        completionStackView.onExpansionChanged = { [weak self] expanded in
            self?.resizeForCompletionStack(expanded: expanded)
        }
        window.delegate = self
        buildUI()
        audioExtraction.onStateChange = { [weak self] state in
            self?.audioStatusView.apply(state)
            self?.resizeDownloadPaneToFit(animate: true)
        }
        NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relocalizeChrome() }
        }
        relocalizeChrome()
        startPolling()
        Task { await bootstrap() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func resizeForCompletionStack(expanded: Bool) {
        guard let window else { return }
        var frame = window.frame
        let oldTop = frame.maxY
        if expanded {
            let requested = completionStackView.expansionHeight
            let visibleFrame = window.screen?.visibleFrame
                ?? NSRect(x: frame.minX, y: 0, width: frame.width, height: frame.maxY)
            let availableBelowTop = max(0, oldTop - visibleFrame.minY - 24)
            let added = min(requested, max(0, availableBelowTop - frame.height))
            completionExpansionAddedHeight = added
            frame.size.height += added
        } else {
            frame.size.height = max(window.minSize.height, frame.height - completionExpansionAddedHeight)
            completionExpansionAddedHeight = 0
        }
        frame.origin.y = oldTop - frame.height
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Build

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        tabControl.segmentStyle = .rounded
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

    private let progressRing = ProgressRingView()

    private func makeDownloadPane() -> NSView {
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 36, weight: .light)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .tertiaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.alignment = .center
        nameLabel.stringValue = filename

        progressRing.translatesAutoresizingMaskIntoConstraints = false
        overallProgress.progress = 0
        NDMChrome.styleMainButton(pauseButton)
        NDMChrome.styleGhostButton(cancelButton)
        NDMChrome.styleMainButton(openButton)
        NDMChrome.styleGhostButton(revealActionButton)

        segmentsCaption.font = .systemFont(ofSize: 12, weight: .semibold)
        segmentsCaption.textColor = .tertiaryLabelColor
        segmentStrip.translatesAutoresizingMaskIntoConstraints = false

        styleValue(sizeValue)
        styleValue(downloadedValue)
        styleValue(speedValue)
        styleValue(etaValue)
        styleValue(resumeValue)

        // One hero element, not two: the numeral lives inside the ring, so a
        // single glance reads progress instead of parsing ring + digits + bar.
        progressRing.showsCheckmark = false
        let heroRing = NSView()
        heroRing.translatesAutoresizingMaskIntoConstraints = false
        heroRing.addSubview(progressRing)
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        heroRing.addSubview(percentLabel)
        let heroStack = NSStackView(views: [heroRing, nameLabel])
        heroStack.orientation = .vertical
        heroStack.alignment = .centerX
        heroStack.spacing = 10
        let header = heroStack
        NSLayoutConstraint.activate([
            heroRing.widthAnchor.constraint(equalToConstant: 132),
            heroRing.heightAnchor.constraint(equalToConstant: 132),
            progressRing.leadingAnchor.constraint(equalTo: heroRing.leadingAnchor),
            progressRing.trailingAnchor.constraint(equalTo: heroRing.trailingAnchor),
            progressRing.topAnchor.constraint(equalTo: heroRing.topAnchor),
            progressRing.bottomAnchor.constraint(equalTo: heroRing.bottomAnchor),
            percentLabel.centerXAnchor.constraint(equalTo: heroRing.centerXAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: heroRing.centerYAnchor),
        ])

        let card = makeStatsCard()

        pauseButton.bezelStyle = .rounded
        pauseButton.setButtonType(.momentaryPushIn)
        pauseButton.keyEquivalent = "\r"
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pauseButton.controlSize = .regular

        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openClicked)
        openButton.controlSize = .regular
        openButton.keyEquivalent = ""
        openButton.isHidden = true

        revealActionButton.bezelStyle = .rounded
        revealActionButton.target = self
        revealActionButton.action = #selector(revealClicked)
        revealActionButton.controlSize = .regular
        revealActionButton.isHidden = true

        moreActionsButton.isBordered = false
        moreActionsButton.bezelStyle = .inline
        moreActionsButton.image = NDMChrome.symbol("ellipsis", pointSize: 12, weight: .semibold)
        moreActionsButton.imagePosition = .imageOnly
        moreActionsButton.target = self
        moreActionsButton.action = #selector(showMoreActions(_:))
        moreActionsButton.toolTip = L10n.moreActions
        moreActionsButton.setAccessibilityLabel(L10n.moreActions)
        moreActionsButton.isHidden = true

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.controlSize = .regular
        cancelButton.keyEquivalent = "\u{1b}"

        revealButton.bezelStyle = .flexiblePush
        revealButton.isBordered = true
        revealButton.target = self
        revealButton.action = #selector(revealClicked)
        revealButton.toolTip = L10n.showInFinder

        // Right-aligned macOS action row: ghost actions lead, the single
        // accent primary sits at the trailing edge. The spacer absorbs the
        // row width so buttons keep their natural size instead of one of
        // them stretching into a banner.
        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        // Dismissive action first, primary at the trailing edge — 关闭 must
        // never sit between two file actions.
        let actions = NSStackView(views: [
            moreActionsButton, actionSpacer,
            cancelButton, revealActionButton, openButton, pauseButton,
        ])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.distribution = .fill
        for button in [pauseButton, openButton, revealActionButton, cancelButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        actionsStack = actions

        let stripBlock = NSStackView(views: [segmentsCaption, segmentStrip])
        stripBlock.orientation = .vertical
        stripBlock.alignment = .leading
        stripBlock.spacing = 6
        // A single segment repeats the overall bar exactly — the strip only
        // earns its row when it can show real parallelism.
        stripBlock.isHidden = true
        segmentBlock = stripBlock

        // Smartline — the tuner narrating "why this connection count".
        // A quiet caption, not a tinted callout box.
        smartlineLabel.font = .systemFont(ofSize: 11)
        smartlineLabel.textColor = .secondaryLabelColor
        smartlineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        smartlineLabel.isHidden = true

        speedSparkline.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            header,
            card,
            speedSparkline,
            overallProgress,
            stripBlock,
            smartlineLabel,
            completionStackView,
            audioStatusView,
            actions,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        downloadStack = stack

        let pane = NSView()
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor),
            smartlineLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            completionStackView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            audioStatusView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            speedSparkline.widthAnchor.constraint(equalTo: stack.widthAnchor),
            speedSparkline.heightAnchor.constraint(equalToConstant: 40),
            overallProgress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            overallProgress.heightAnchor.constraint(equalToConstant: 4),
            segmentStrip.widthAnchor.constraint(equalTo: stack.widthAnchor),
            segmentStrip.heightAnchor.constraint(equalToConstant: 8),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pauseButton.heightAnchor.constraint(equalToConstant: 32),
            pauseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 108),
            openButton.heightAnchor.constraint(equalToConstant: 32),
            openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 108),
            revealActionButton.heightAnchor.constraint(equalToConstant: 32),
            moreActionsButton.widthAnchor.constraint(equalToConstant: 32),
            moreActionsButton.heightAnchor.constraint(equalToConstant: 32),
            cancelButton.heightAnchor.constraint(equalToConstant: 32),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
        completionStackView.apply(nil)
        audioStatusView.apply(.unavailable)
        return pane
    }

    /// Called when the download finishes while this window is already open.
    /// Keeps completion in-window so a modal alert cannot block Close.
    func presentCompleted(task: DownloadTask) {
        filename = task.filename.isEmpty ? filename : task.filename
        nameLabel.stringValue = filename
        percentLabel.stringValue = "100%"
        window?.title = L10n.doneTitle(filename)
        overallProgress.progress = 1
        progressRing.progress = 1
        statusPill.setStatus(.complete, error: nil)
        celebratePercentLabel()
        smartlineLabel.isHidden = true
        smartlineLabel.stringValue = ""
        speedValue.stringValue = L10n.emDash
        etaValue.stringValue = L10n.emDash
        if task.fileSize > 0 {
            sizeValue.stringValue = TaskPresentationFormatting.byteCount(task.fileSize)
            downloadedValue.stringValue = "\(TaskPresentationFormatting.byteCount(task.fileSize))  (100%)"
        }
        // File is merged — paint a solid strip even if the last live snapshot
        // still had unfinished Range chunks.
        let total = max(0, task.fileSize)
        segmentStrip.update(segments: [], totalBytes: total, forceFilled: true)
        segmentsCaption.stringValue = L10n.segments
        segmentBlock?.isHidden = true
        speedSparkline.isHidden = true
        lastStatus = .complete
        applyCompletionStack(for: task)
        configureActionButtons(for: .complete, task: task)
        pollTask?.cancel()
        pollTask = nil
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Design-suite statgrid: four glanceable cells up top, then the quiet
    /// URL / size details. One sweep of the eyes answers "how is it going".
    private func makeStatsCard() -> NSView {
        func statCell(_ cap: NSTextField, _ value: NSView) -> NSView {
            cap.font = .systemFont(ofSize: 12, weight: .semibold)
            cap.textColor = .tertiaryLabelColor
            if let field = value as? NSTextField {
                field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
                field.textColor = .labelColor
                field.lineBreakMode = .byTruncatingTail
            }
            let cell = NSStackView(views: [cap, value])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 3
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return cell
        }

        func vSeparator() -> NSView {
            let line = ChromeBox(fill: NDMChrome.hairline)
            line.translatesAutoresizingMaskIntoConstraints = false
            line.widthAnchor.constraint(equalToConstant: 1).isActive = true
            line.heightAnchor.constraint(equalToConstant: 30).isActive = true
            return line
        }

        let statusCell: NSView = {
            statusCaptionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            statusCaptionLabel.textColor = .tertiaryLabelColor
            let cell = NSStackView(views: [statusCaptionLabel, statusPill])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 4
            return cell
        }()

        let gridRow = NSStackView(views: [
            statCell(speedCaptionLabel, speedValue),
            vSeparator(),
            statCell(downloadedCaptionLabel, downloadedValue),
            vSeparator(),
            statCell(etaCaptionLabel, etaValue),
            vSeparator(),
            statusCell,
        ])
        gridRow.orientation = .horizontal
        gridRow.alignment = .centerY
        gridRow.spacing = 16
        gridRow.distribution = .fill

        let divider = ChromeBox(fill: NDMChrome.hairline)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        // Quiet detail rows: clickable URL + size / resumable, reveal at right.
        urlValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let urlRow = NSStackView(views: [urlValue, revealButton])
        urlRow.orientation = .horizontal
        urlRow.alignment = .centerY
        urlRow.spacing = 8
        revealButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        revealButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        for field in [sizeValue, resumeValue] {
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.textColor = .secondaryLabelColor
        }
        sizeCaptionLabel.font = .systemFont(ofSize: 11)
        sizeCaptionLabel.textColor = .tertiaryLabelColor
        resumeCaptionLabel.font = .systemFont(ofSize: 11)
        resumeCaptionLabel.textColor = .tertiaryLabelColor
        let metaRow = NSStackView(views: [sizeCaptionLabel, sizeValue, resumeCaptionLabel, resumeValue, NSView()])
        metaRow.orientation = .horizontal
        metaRow.alignment = .firstBaseline
        metaRow.spacing = 6
        metaRow.setCustomSpacing(16, after: sizeValue)

        let grid = NSStackView(views: [gridRow, divider, urlRow, metaRow])
        grid.orientation = .vertical
        grid.spacing = 10
        grid.alignment = .leading
        grid.setCustomSpacing(12, after: gridRow)
        gridRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        divider.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        urlRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        metaRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        // Open composition — typography and hairlines carry the structure;
        // no boxed-in gray card.
        let card = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: card.topAnchor),
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        return card
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

        connectionsCaptionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let connRow = NSStackView(views: [connectionsCaptionLabel, connectionsPopup, applyConnButton])
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

    private func relocalizeChrome() {
        tabControl.setLabel(L10n.tabDownload, forSegment: 0)
        tabControl.setLabel(L10n.tabOptions, forSegment: 1)
        tabControl.setLabel(L10n.tabConnections, forSegment: 2)
        speedCaptionLabel.stringValue = L10n.speed.uppercased()
        downloadedCaptionLabel.stringValue = L10n.downloaded.uppercased()
        etaCaptionLabel.stringValue = L10n.timeLeft.uppercased()
        statusCaptionLabel.stringValue = L10n.status.uppercased()
        sizeCaptionLabel.stringValue = L10n.size
        resumeCaptionLabel.stringValue = L10n.resumable
        connectionsCaptionLabel.stringValue = L10n.connections
        segmentsCaption.stringValue = displayedConnectionIDs.isEmpty
            ? L10n.segments
            : L10n.segmentsCount(displayedConnectionIDs.count)
        cancelButton.title = L10n.close
        openButton.title = L10n.open
        revealActionButton.title = L10n.showInFinder
        revealButton.toolTip = L10n.showInFinder
        applyConnButton.title = L10n.apply
        renewButton.title = L10n.renewURLEllipsis
        optionsNote.stringValue = L10n.optionsNote
        completionStackView.relocalize()
        moreActionsButton.toolTip = L10n.moreActions
        moreActionsButton.setAccessibilityLabel(L10n.moreActions)
        switch lastStatus {
        case .error: pauseButton.title = L10n.retry
        case .paused, .incomplete: pauseButton.title = L10n.resume
        default: pauseButton.title = L10n.pause
        }
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
        let panes = [downloadPane!, optionsPane!, connectionsPane!]
        let changed = panes.enumerated().contains { $0.element.isHidden == ($0.offset == index) }
        downloadPane.isHidden = index != 0
        optionsPane.isHidden = index != 1
        connectionsPane.isHidden = index != 2
        if changed, window?.isVisible == true {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tabContainer.layer?.add(fade, forKey: "tab")
        }
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
            resumeValue.stringValue = task.resumable ? L10n.yes : L10n.no
            resumeValue.textColor = .secondaryLabelColor
            // Media-page tasks download through aria2c, which hard-caps
            // connections per server at 16 — don't offer values the engine
            // would silently clamp.
            if task.linkType.lowercased() == "ytdlp" {
                while connectionsPopup.numberOfItems > 16 {
                    connectionsPopup.removeItem(at: connectionsPopup.numberOfItems - 1)
                }
            }
            let n = max(1, min(connectionsPopup.numberOfItems, task.connections))
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
                // ~20 fps while bytes are moving — smooth enough for the
                // strip. Paused/queued tasks change rarely; polling them at
                // full rate only burns CPU.
                let interval: UInt64 = self.lastStatus == .downloading
                    ? 50_000_000
                    : 500_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func refresh() async {
        let task = try? await manager.task(id: taskID)
        if let task {
            filename = task.filename.isEmpty ? filename : task.filename
            nameLabel.stringValue = filename
            urlValue.setURL(task.url)
            resumeValue.stringValue = task.resumable ? L10n.yes : L10n.no
            resumeValue.textColor = .secondaryLabelColor
            if task.fileSize > 0 {
                sizeValue.stringValue = task.linkType.lowercased() == "ytdlp" && task.status != .complete
                    ? L10n.estimatedSize(task.fileSize)
                    : TaskPresentationFormatting.byteCount(task.fileSize)
            }
        }

        if let progress = await manager.progress(taskID: taskID) {
            apply(progress: progress, task: task)
            if progress.status == .complete || progress.status == .error {
                pollTask?.cancel()
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
        let fraction = progress.status == .complete ? 1 : progress.fractionCompleted
        let pct = Int((fraction * 100).rounded(.down))
        percentLabel.stringValue = "\(pct)%"
        if progress.status == .complete {
            window?.title = L10n.doneTitle(filename)
        } else if progress.status == .downloading, progress.bytesPerSecond > 0 {
            let speed = TaskPresentationFormatting.speed(progress.bytesPerSecond, status: .downloading)
            window?.title = "\(pct)% \(filename) — \(speed)"
        } else {
            window?.title = "\(pct)% \(filename)"
        }

        overallProgress.progress = fraction
        overallProgress.isActive = progress.status == .downloading
        progressRing.progress = fraction
        statusPill.setStatus(progress.status, error: progress.errorDescription ?? task?.errorText)

        let isYtDlp = task?.linkType.lowercased() == "ytdlp"
        // yt-dlp probe sizes are estimates. Once live totals arrive, use the
        // engine's single source of truth for both bars instead of mixing the
        // persisted estimate with the current video/audio aggregate.
        let total = isYtDlp && progress.totalBytes > 0
            ? progress.totalBytes
            : max(progress.totalBytes, task?.fileSize ?? 0)
        let done = progress.status == .complete ? total : progress.completedBytes
        if total > 0 {
            if isYtDlp, progress.status != .complete, let estimate = task?.fileSize, estimate > 0 {
                sizeValue.stringValue = L10n.estimatedSize(estimate)
            } else {
                sizeValue.stringValue = TaskPresentationFormatting.byteCount(total)
            }
        }
        let byteFraction = total > 0
            ? min(1, max(0, Double(done) / Double(total)))
            : 0
        let pctFine = String(format: "%.1f", byteFraction * 100)
        downloadedValue.stringValue = total > 0
            ? "\(TaskPresentationFormatting.byteCount(done))  (\(pctFine)%)"
            : TaskPresentationFormatting.byteCount(done)

        speedValue.stringValue = TaskPresentationFormatting.speed(progress.bytesPerSecond, status: progress.status)
        etaValue.stringValue = TaskPresentationFormatting.eta(progress.remainingTime, status: progress.status)

        if progress.status == .downloading {
            speedSparkline.addSample(progress.bytesPerSecond)
            speedSparkline.isHidden = false
        } else {
            // Paused/queued included: a frozen (or empty) speed curve is noise.
            speedSparkline.isHidden = true
        }

        let segments: [SegmentState]
        if isYtDlp, total > 0 {
            segments = [SegmentState(
                id: 0,
                start: 0,
                end: max(0, total - 1),
                completed: min(total, done),
                isFinished: progress.status == .complete
            )]
        } else {
            segments = progress.segmentStates.sorted { $0.id < $1.id }
        }
        let forceFilled = progress.status == .complete
        segmentsCaption.stringValue = segments.isEmpty
            ? L10n.segments
            : L10n.segmentsCount(segments.count)
        segmentBlock?.isHidden = segments.count <= 1
        // On complete, always solid-fill: live Range snapshots can lag behind merge.
        if isYtDlp {
            segmentStrip.updateUnified(progress: fraction, forceFilled: forceFilled)
        } else {
            segmentStrip.update(segments: segments, totalBytes: total, forceFilled: forceFilled)
        }

        configureActionButtons(for: progress.status, task: task)
        renderConnections(segments, downloadStatus: progress.status)

        if progress.status == .complete, let task {
            applyCompletionStack(for: task)
        } else if progress.status != .complete, completionStackApplied {
            completionStackApplied = false
            completionStackView.apply(nil)
            audioExtraction.apply(sourceURL: nil)
            moreActionsButton.isHidden = true
        }

        smartlineLabel.textColor = .secondaryLabelColor
        smartlineLabel.toolTip = nil
        smartlineLabel.setAccessibilityLabel(L10n.status)
        smartlineLabel.setAccessibilityValue(nil)

        if progress.status == .error {
            let storedError = progress.errorDescription ?? task?.errorText
            let diagnostic = DownloadDiagnostic.fromStoredErrorText(storedError)
            let reason: String
            if let diagnostic {
                reason = "\(diagnostic.title). \(diagnostic.message)"
            } else {
                reason = storedError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? storedError!
                    : L10n.t("The download failed. Retry to continue from the saved data.", "下载失败。重试可从已保存的数据继续。")
            }
            smartlineLabel.stringValue = reason
            smartlineLabel.textColor = .secondaryLabelColor
            smartlineLabel.toolTip = reason
            smartlineLabel.setAccessibilityLabel(L10n.failed)
            smartlineLabel.setAccessibilityValue(reason)
            smartlineLabel.isHidden = false
        } else if let phase = progress.phase, progress.status != .complete {
            switch phase {
            case .preparing:
                smartlineLabel.stringValue = L10n.ytdlpPreparingDownload
            case .transferring:
                smartlineLabel.stringValue = L10n.ytdlpDownloading
            case .merging:
                smartlineLabel.stringValue = L10n.ytdlpMerging
            case .subtitles:
                smartlineLabel.stringValue = L10n.ytdlpPreparingSubtitles
            case .finalizing:
                smartlineLabel.stringValue = L10n.ytdlpFinalizing
            }
            smartlineLabel.isHidden = false
        } else if let tuning = progress.tuning, progress.status != .complete {
            smartlineLabel.stringValue = tuning.summaryLine
            smartlineLabel.isHidden = false
        } else {
            smartlineLabel.isHidden = true
        }

        sizeWindowToFitInitially()
    }

    private func celebratePercentLabel() {
        percentLabel.wantsLayer = true
        guard let layer = percentLabel.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 1.0
        spring.toValue = 1.08
        spring.mass = 1
        spring.stiffness = 300
        spring.damping = 12
        spring.initialVelocity = 8
        spring.autoreverses = true
        spring.duration = spring.settlingDuration / 2
        layer.add(spring, forKey: "celebrate")
    }

    private func applyCompletionStack(for task: DownloadTask) {
        guard !completionStackApplied else { return }
        completionStackApplied = true
        let result = SmartFinalize.completionStack(primary: task.destinationFileURL)
        completionStackView.apply(result)
        audioExtraction.apply(sourceURL: task.destinationFileURL)
        moreActionsButton.isHidden = !SmartFinalize.supportsDeliveryRecipes(
            input: task.destinationFileURL
        )
        resizeDownloadPaneToFit(animate: true)
    }

    private var didSizeToFitInitially = false

    /// First presentation only: shrink the fixed launch height down to the
    /// actual content, so a compact state doesn't open with a slab of dead
    /// space under the buttons. Later growth still goes through
    /// `resizeDownloadPaneToFit`, and user resizes are never fought.
    private func sizeWindowToFitInitially() {
        guard !didSizeToFitInitially, let window, let downloadStack else { return }
        didSizeToFitInitially = true
        window.contentView?.layoutSubtreeIfNeeded()
        guard let contentView = window.contentView else { return }
        let targetContent = max(
            downloadStack.fittingSize.height + 58,
            window.minSize.height - (window.frame.height - contentView.frame.height)
        )
        let delta = targetContent - contentView.frame.height
        guard delta < -1 else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size.height += delta
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    private func resizeDownloadPaneToFit(animate: Bool) {
        guard let window, let downloadStack else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let chromeHeight: CGFloat = 58
        let contentHeight = downloadStack.fittingSize.height + chromeHeight
        let minimum = window.minSize.height
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maximum = max(minimum, (visibleFrame?.height ?? contentHeight) - 24)
        let targetHeight = min(max(minimum, contentHeight), maximum)
        // Completion may grow a compact window, but never shrinks a size the
        // user chose while monitoring the transfer.
        guard window.frame.height < targetHeight else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = targetHeight
        frame.origin.y = top - targetHeight
        window.setFrame(frame, display: true, animate: animate)
    }

    private func configureActionButtons(for status: DownloadStatus, task: DownloadTask?) {
        cancelButton.title = L10n.close
        cancelButton.isEnabled = true
        cancelButton.keyEquivalent = "\u{1b}"

        let fileExists = task?.destinationFileURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false

        switch status {
        case .complete:
            pauseButton.isHidden = true
            pauseButton.keyEquivalent = ""
            openButton.isHidden = false
            openButton.isEnabled = fileExists
            openButton.keyEquivalent = "\r"
            revealActionButton.isHidden = false
            revealActionButton.isEnabled = fileExists || task?.destinationFileURL != nil
            moreActionsButton.isHidden = !SmartFinalize.supportsDeliveryRecipes(
                input: task?.destinationFileURL
            )
        case .paused, .incomplete, .error:
            pauseButton.isHidden = false
            openButton.isHidden = true
            revealActionButton.isHidden = true
            moreActionsButton.isHidden = true
            pauseButton.title = status == .error ? L10n.retry : L10n.resume
            pauseButton.isEnabled = true
            pauseButton.keyEquivalent = "\r"
            openButton.keyEquivalent = ""
        default:
            pauseButton.isHidden = false
            openButton.isHidden = true
            revealActionButton.isHidden = true
            moreActionsButton.isHidden = true
            pauseButton.title = L10n.pause
            pauseButton.isEnabled = true
            pauseButton.keyEquivalent = "\r"
            openButton.keyEquivalent = ""
        }
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
        // Close always works — including after completion. Active transfers pause first.
        if lastStatus == .downloading || lastStatus == .waiting {
            Task {
                await manager.pause(taskID: taskID)
                window?.close()
            }
        } else {
            window?.close()
        }
    }

    @objc private func openClicked() {
        Task {
            guard let task = try? await manager.task(id: taskID),
                  let url = task.destinationFileURL,
                  FileManager.default.fileExists(atPath: url.path) else { return }
            NSWorkspace.shared.open(url)
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

    @objc private func showMoreActions(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch audioExtraction.state {
        case .unavailable:
            return
        case .ready, .failed:
            let item = NSMenuItem(title: L10n.extractAudio, action: #selector(extractAudioClicked), keyEquivalent: "")
            item.image = NDMChrome.symbol("waveform", pointSize: 13, weight: .medium)
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        case .running:
            let item = NSMenuItem(title: L10n.extractingAudio, action: nil, keyEquivalent: "")
            item.image = NDMChrome.symbol("waveform", pointSize: 13, weight: .medium)
            item.isEnabled = false
            menu.addItem(item)
        case .succeeded:
            let reveal = NSMenuItem(title: L10n.showAudioInFinder, action: #selector(revealExtractedAudio), keyEquivalent: "")
            reveal.image = NDMChrome.symbol("folder", pointSize: 13, weight: .medium)
            reveal.target = self
            reveal.isEnabled = true
            menu.addItem(reveal)
            menu.addItem(.separator())
            let again = NSMenuItem(title: L10n.extractAudioAgain, action: #selector(extractAudioClicked), keyEquivalent: "")
            again.image = NDMChrome.symbol("waveform", pointSize: 13, weight: .medium)
            again.target = self
            again.isEnabled = true
            menu.addItem(again)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 3), in: sender)
    }

    @objc private func extractAudioClicked() {
        audioExtraction.extract()
    }

    @objc private func revealExtractedAudio() {
        audioExtraction.revealResult()
    }

    @objc private func applyConnections() {
        let n = connectionsPopup.indexOfSelectedItem + 1
        let cap = LicenseStore.connectionsCap(isPro: LicenseStore.isPro)
        if n > cap {
            connectionsPopup.selectItem(at: cap - 1)
            let alert = NSAlert()
            alert.messageText = L10n.proGateConnectionsTitle
            alert.informativeText = L10n.proGateConnectionsBody
            alert.addButton(withTitle: L10n.proCTA)
            alert.addButton(withTitle: L10n.cancel)
            if alert.runModal() == .alertFirstButtonReturn {
                UpgradeWindowController.present()
            }
            return
        }
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
        Task {
            if let task = try? await manager.task(id: taskID),
               let sourceURL = task.browserRescueURL {
                NSWorkspace.shared.open(sourceURL)
                return
            }
            presentManualRenew()
        }
    }

    private func presentManualRenew() {
        let alert = NSAlert()
        alert.messageText = L10n.renewURL
        alert.informativeText = L10n.renewURLBodyProgress
        alert.addButton(withTitle: L10n.renew)
        alert.addButton(withTitle: L10n.cancel)
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
        audioExtraction.cancel()
        onWindowClose?()
        onWindowClose = nil
    }
}

// MARK: - Segment strip

/// Compact file-map visualization: each Range paints its completed span.
private final class SegmentStripView: NSView {
    private var segments: [SegmentState] = []
    private var totalBytes: Int64 = 0
    /// When true, paint a solid green bar (download finished / merged).
    private var forceFilled = false
    private let unifiedFillLayer = CALayer()
    private var unifiedProgress: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        unifiedFillLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        unifiedFillLayer.backgroundColor = NDMChrome.accent.withAlphaComponent(0.9).cgColor
        unifiedFillLayer.isHidden = true
        layer?.addSublayer(unifiedFillLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(segments: [SegmentState], totalBytes: Int64, forceFilled: Bool = false) {
        unifiedProgress = nil
        unifiedFillLayer.isHidden = true
        self.segments = segments
        self.totalBytes = totalBytes
        self.forceFilled = forceFilled
        needsDisplay = true
    }

    /// Media page downloads use one semantic total even when the resolver has
    /// separate video/audio transfers. Drive the green strip from the exact
    /// same fraction and animation timing as the blue bar.
    func updateUnified(progress: Double, forceFilled: Bool = false) {
        let target = CGFloat(forceFilled ? 1 : min(1, max(0, progress)))
        unifiedProgress = Double(target)
        self.forceFilled = forceFilled
        segments = []
        totalBytes = 0
        unifiedFillLayer.isHidden = false
        let current = (unifiedFillLayer.presentation()?.value(forKeyPath: "transform.scale.x") as? NSNumber)
            .map(CGFloat.init(truncating:))
            ?? (unifiedFillLayer.value(forKeyPath: "transform.scale.x") as? NSNumber)
                .map(CGFloat.init(truncating:))
            ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        unifiedFillLayer.transform = CATransform3DMakeScale(target, 1, 1)
        CATransaction.commit()
        guard window != nil, abs(target - current) > 0.001 else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = target >= current ? 0.24 : 0.12
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        unifiedFillLayer.add(animation, forKey: "progress")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        unifiedFillLayer.bounds = bounds
        unifiedFillLayer.position = CGPoint(x: bounds.minX, y: bounds.midY)
        unifiedFillLayer.cornerRadius = bounds.height / 2
        unifiedFillLayer.transform = CATransform3DMakeScale(
            CGFloat(unifiedProgress ?? 0), 1, 1
        )
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let track = NSColor.quaternaryLabelColor
        track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()

        let fill = NDMChrome.accent.withAlphaComponent(0.9)
        fill.setFill()

        // Completed downloads must read as fully filled — last Range snapshots
        // often lag merge, and uncovered gaps would look like a bug.
        if forceFilled && unifiedProgress == nil {
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
            return
        }

        guard totalBytes > 0, !segments.isEmpty else { return }

        for segment in segments {
            // Prefer full range when the engine marked the chunk finished,
            // even if `completed` briefly lags behind `length`.
            let paintedBytes = segment.isFinished
                ? segment.length
                : min(segment.length, max(0, segment.completed))
            let startFrac = Double(segment.start) / Double(totalBytes)
            let paintedFrac = Double(paintedBytes) / Double(totalBytes)
            guard paintedFrac > 0 else { continue }
            let x = bounds.minX + CGFloat(startFrac) * bounds.width
            let w = max(1, CGFloat(paintedFrac) * bounds.width)
            NSRect(x: x, y: bounds.minY, width: w, height: bounds.height).fill()
        }
    }
}

// MARK: - Status pill

private final class StatusPillView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var lastStatus: DownloadStatus = .waiting
    private var lastError: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        label.setAccessibilityElement(false)
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
        lastStatus = status
        lastError = error
        let title: String
        let fg: NSColor
        let bg: NSColor
        // One accent voice: active uses controlAccent; others stay neutral ink on soft track.
        let track = NSColor.quaternaryLabelColor.withAlphaComponent(0.35)
        switch status {
        case .downloading:
            title = L10n.downloading
            fg = NDMChrome.accent
            bg = NDMChrome.accent.withAlphaComponent(0.12)
        case .paused:
            title = L10n.paused
            fg = .secondaryLabelColor
            bg = track
        case .complete:
            title = L10n.completed
            fg = NSColor.systemGreen.blended(withFraction: 0.35, of: .labelColor) ?? .systemGreen
            bg = NDMChrome.okSoft
        case .error:
            title = L10n.failed
            fg = NSColor.systemRed.blended(withFraction: 0.25, of: .labelColor) ?? .systemRed
            bg = NDMChrome.dangerSoft
        case .waiting:
            title = L10n.queued
            fg = .secondaryLabelColor
            bg = track
        case .incomplete:
            title = L10n.incomplete
            fg = .secondaryLabelColor
            bg = track
        }
        label.stringValue = title
        label.textColor = fg
        layer?.backgroundColor = bg.cgColor
        toolTip = error
        setAccessibilityLabel(title)
        setAccessibilityValue(error)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setStatus(lastStatus, error: lastError)
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
        titleLabel.stringValue = L10n.connectionN(state.id + 1)
        progress.doubleValue = fraction

        let status: String
        let statusColor: NSColor
        if state.isFinished || fraction >= 1 {
            status = L10n.complete
            statusColor = .tertiaryLabelColor
        } else {
            switch downloadStatus {
            case .paused:
                status = L10n.paused
                statusColor = .secondaryLabelColor
            case .error:
                status = L10n.error
                statusColor = .secondaryLabelColor
            case .waiting:
                status = L10n.waiting
                statusColor = .secondaryLabelColor
            default:
                status = state.completed > 0 ? L10n.downloading : L10n.waiting
                statusColor = state.completed > 0 ? .labelColor : .secondaryLabelColor
            }
        }
        stateLabel.stringValue = "\(status) · \(percent)%"
        stateLabel.textColor = statusColor

        let completed = TaskPresentationFormatting.byteCount(max(0, min(state.length, state.completed)))
        let length = TaskPresentationFormatting.byteCount(state.length)
        let rangeWord = L10n.t("Range", "范围")
        rangeLabel.stringValue = "\(rangeWord) \(Self.integer(state.start))–\(Self.integer(state.end)) · \(completed) / \(length)"
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
