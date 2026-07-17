import AppKit
import NDMCore
import NDMEngine

/// The demo moment: two lanes download the same file over the same network —
/// left like a browser (one connection), right with the real engine.
/// The verdict is honest: when a server saturates a single connection we say
/// so, because "32 connections" must never read as marketing magic.
@MainActor
final class SpeedRaceWindowController: NSWindowController, NSWindowDelegate {
    static let raceFileURL = OnboardingWindowController.testFileURL

    private static var active: SpeedRaceWindowController?

    static func present() {
        if let existing = active {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = SpeedRaceWindowController()
        active = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let browserLane = RaceLaneView(title: L10n.raceLaneBrowser, highlighted: false)
    private let ourLane = RaceLaneView(title: L10n.raceLaneOurs, highlighted: true)
    private let verdictLabel = NSTextField(wrappingLabelWithString: "")
    private var startButton: NSButton!

    private var slowEngine: DownloadEngine?
    private var fastEngine: DownloadEngine?
    private var raceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var workRoot: URL?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.raceWindowTitle
        NDMChrome.applyWindowChrome(window)
        super.init(window: window)
        buildUI()
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let headline = NSTextField(labelWithString: L10n.raceHeadline)
        headline.font = .systemFont(ofSize: 20, weight: .bold)
        headline.alignment = .center
        let subline = NSTextField(labelWithString: L10n.raceSubline)
        subline.font = .systemFont(ofSize: 12.5)
        subline.textColor = .secondaryLabelColor
        subline.alignment = .center

        let lanes = NSStackView(views: [browserLane, ourLane])
        lanes.orientation = .horizontal
        lanes.alignment = .top
        lanes.spacing = 14
        lanes.distribution = .fillEqually

        verdictLabel.font = .systemFont(ofSize: 13, weight: .medium)
        verdictLabel.alignment = .center
        verdictLabel.textColor = .labelColor
        verdictLabel.isHidden = true

        startButton = NSButton(title: L10n.raceStart, target: self, action: #selector(startClicked))
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.keyEquivalent = "\r"
        if #available(macOS 11.0, *) {
            startButton.bezelColor = NDMChrome.accent
        }

        let stack = NSStackView(views: [headline, subline, lanes, verdictLabel, startButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(20, after: subline)
        stack.setCustomSpacing(16, after: lanes)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
            lanes.widthAnchor.constraint(equalTo: stack.widthAnchor),
            verdictLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
    }

    // MARK: - Race

    @objc private func startClicked() {
        stopRace()
        browserLane.reset()
        ourLane.reset()
        verdictLabel.isHidden = true
        startButton.isEnabled = false
        startButton.title = L10n.raceRunning

        guard let url = URL(string: Self.raceFileURL) else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-race-\(UUID().uuidString)", isDirectory: true)
        workRoot = root
        let slowDir = root.appendingPathComponent("slow", isDirectory: true)
        let fastDir = root.appendingPathComponent("fast", isDirectory: true)
        try? FileManager.default.createDirectory(at: slowDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: fastDir, withIntermediateDirectories: true)

        var slowRequest = DownloadRequest(url: url, destinationDirectory: slowDir)
        slowRequest.connections = 1
        var fastRequest = DownloadRequest(url: url, destinationDirectory: fastDir)
        fastRequest.connections = 8

        let slow = DownloadEngine(taskID: 9_000_001, request: slowRequest, workDirectory: slowDir)
        let fast = DownloadEngine(taskID: 9_000_002, request: fastRequest, workDirectory: fastDir)
        slowEngine = slow
        fastEngine = fast

        let started = Date()
        raceTask = Task { [weak self] in
            async let slowRun: Void = Self.runEngine(slow)
            async let fastRun: Void = Self.runEngine(fast)
            _ = await (slowRun, fastRun)
            _ = self
        }

        pollTask = Task { [weak self] in
            var verdictShown = false
            while !Task.isCancelled {
                guard let self else { return }
                let slowProgress = await slow.currentProgress()
                let fastProgress = await fast.currentProgress()
                self.browserLane.update(progress: slowProgress)
                self.ourLane.update(progress: fastProgress)

                if !verdictShown, fastProgress.status == .complete {
                    verdictShown = true
                    let elapsed = Date().timeIntervalSince(started)
                    self.presentVerdict(
                        elapsed: elapsed,
                        fastBytes: fastProgress.completedBytes,
                        slowBytes: slowProgress.completedBytes,
                        slowFraction: slowProgress.fractionCompleted
                    )
                    // The point is made — stop burning the slow lane's bandwidth.
                    await slow.cancel()
                    self.browserLane.freeze(atFraction: slowProgress.fractionCompleted)
                }
                if fastProgress.status == .error {
                    self.finishRace(message: L10n.raceFailed)
                    return
                }
                if verdictShown {
                    self.finishRace(message: nil)
                    return
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private static func runEngine(_ engine: DownloadEngine) async {
        _ = try? await engine.start()
    }

    private func presentVerdict(
        elapsed: TimeInterval,
        fastBytes: Int64,
        slowBytes: Int64,
        slowFraction: Double
    ) {
        let seconds = String(format: "%.0fs", elapsed)
        if slowBytes > 0, fastBytes > 0 {
            let ratio = Double(fastBytes) / Double(slowBytes)
            if ratio >= 1.3 {
                verdictLabel.stringValue = L10n.raceVerdictFaster(
                    String(format: "%.1f", ratio),
                    seconds: seconds
                )
                verdictLabel.textColor = NDMChrome.accent
            } else {
                verdictLabel.stringValue = L10n.raceVerdictHonest
                verdictLabel.textColor = .secondaryLabelColor
            }
        } else {
            verdictLabel.stringValue = L10n.raceVerdictHonest
            verdictLabel.textColor = .secondaryLabelColor
        }
        verdictLabel.isHidden = false
        browserLane.setStatus(L10n.raceStillAt(TaskPresentationFormatting.percent(slowFraction)))
        ourLane.setStatus(L10n.raceFinished + " · " + seconds)
    }

    private func finishRace(message: String?) {
        if let message {
            verdictLabel.stringValue = message
            verdictLabel.textColor = .secondaryLabelColor
            verdictLabel.isHidden = false
        }
        startButton.isEnabled = true
        startButton.title = L10n.raceAgain
        pollTask?.cancel()
        pollTask = nil
    }

    private func stopRace() {
        pollTask?.cancel()
        pollTask = nil
        raceTask?.cancel()
        raceTask = nil
        let slow = slowEngine
        let fast = fastEngine
        slowEngine = nil
        fastEngine = nil
        Task {
            await slow?.cancel()
            await fast?.cancel()
        }
        if let root = workRoot {
            try? FileManager.default.removeItem(at: root)
            workRoot = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopRace()
        Self.active = nil
    }
}

/// One lane: title, big live speed, progress bar, status line.
@MainActor
private final class RaceLaneView: NSView {
    private let speedLabel = NSTextField(labelWithString: "0 KB/s")
    private let bar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: L10n.raceWaiting)
    private var frozen = false

    private let highlighted: Bool

    init(title: String, highlighted: Bool) {
        self.highlighted = highlighted
        super.init(frame: .zero)
        wantsLayer = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = highlighted ? NDMChrome.accent : .secondaryLabelColor

        speedLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        speedLabel.textColor = .labelColor

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.controlSize = .regular
        bar.style = .bar

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, speedLabel, bar, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: speedLabel)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 11
        layer?.borderWidth = highlighted ? 2 : 1
        layer?.borderColor = (highlighted
            ? NDMChrome.accent.withAlphaComponent(0.6)
            : NDMChrome.hairline).cgColor
        layer?.backgroundColor = NDMChrome.dockFill.cgColor
    }

    func reset() {
        frozen = false
        speedLabel.stringValue = "0 KB/s"
        bar.doubleValue = 0
        statusLabel.stringValue = L10n.raceWaiting
    }

    func update(progress: DownloadProgress) {
        guard !frozen else { return }
        if progress.bytesPerSecond > 0 {
            speedLabel.stringValue = TaskPresentationFormatting.speed(
                progress.bytesPerSecond,
                status: .downloading
            )
        }
        bar.doubleValue = progress.status == .complete ? 1 : progress.fractionCompleted
        if progress.status == .complete {
            statusLabel.stringValue = L10n.raceFinished
        } else if progress.totalBytes > 0 {
            statusLabel.stringValue = "\(TaskPresentationFormatting.percent(progress.fractionCompleted)) · " +
                TaskPresentationFormatting.sizePair(
                    completed: progress.completedBytes,
                    total: progress.totalBytes
                )
        }
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func freeze(atFraction fraction: Double) {
        frozen = true
        bar.doubleValue = fraction
    }
}
