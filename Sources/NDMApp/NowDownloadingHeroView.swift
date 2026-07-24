import AppKit
import NDMCore

/// The one visual object that survives the transfer-to-result handoff.
/// Artwork expands into the completed hero; a generic file glyph moves into
/// the hero's resting glyph position.
struct CompletionHandoffPreview {
    let image: NSImage
    let rectInHero: NSRect
    let isArtwork: Bool
}

/// "Now Downloading" cinema strip — the stage at the top of the task list
/// while bytes are moving. Each live transfer gets cover art, an ambient
/// glow in the cover's dominant color, a large rolling speed numeral, and a
/// live progress lane. Multiple concurrent downloads stack as separate heroes.
/// Collapses away entirely when nothing is downloading.
@MainActor
final class NowDownloadingHeroView: NSView {
    var onActivateTask: ((Int64) -> Void)?
    /// Single-click selection when the host shows several heroes at once.
    /// Falls back to `onActivateTask` when unset (progress window).
    var onSelectTask: ((Int64) -> Void)?
    /// Right-click actions for the transfer on stage — the hero is not a table
    /// row, so it carries its own compact menu of in-flight actions.
    var onContextAction: ((TaskListContextAction, Int64) -> Void)?

    private let atmosphere = AtmosphereView()
    private let coverView = NSImageView()
    private let coverPlate = ChromeBox(
        fill: NDMChrome.track,
        borderColor: NDMChrome.hairline,
        cornerRadius: 10,
        borderWidth: 1
    )
    private let coverSymbol = NSImageView()
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let speedLabel = NSTextField(labelWithString: "0")
    private let unitLabel = NSTextField(labelWithString: "KB/s")
    private let moreLabel = NSTextField(labelWithString: "")
    private let progressBar = ThinProgressView()
    private let segmentStrip = HeroSegmentStrip()
    private let percentLabel = NSTextField(labelWithString: "")
    private let hairline = ChromeBox(fill: NDMChrome.hairline)
    private let selectionWash = ChromeBox(fill: NDMChrome.rowActive, cornerRadius: 0)

    private var displayedSpeed: Double = 0
    private var targetSpeed: Double = 0
    private var rollTimer: Timer?
    private var lastRollUptime: TimeInterval?
    private var currentTaskID: Int64?
    private var currentCoverTaskID: Int64?
    private var isSelected = false
    /// Cached row for cover-art refresh without re-querying the list.
    private var currentRow: TaskRowPresentation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.nowDownloading)
        setAccessibilityHelp(L10n.progressDetails)

        atmosphere.translatesAutoresizingMaskIntoConstraints = false

        coverView.translatesAutoresizingMaskIntoConstraints = false
        coverView.imageScaling = .scaleProportionallyUpOrDown
        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 10
        coverView.layer?.masksToBounds = true

        coverPlate.translatesAutoresizingMaskIntoConstraints = false
        coverSymbol.translatesAutoresizingMaskIntoConstraints = false
        coverSymbol.imageScaling = .scaleProportionallyUpOrDown
        coverSymbol.contentTintColor = .tertiaryLabelColor

        eyebrowLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        eyebrowLabel.textColor = NDMChrome.accent
        eyebrowLabel.stringValue = L10n.nowDownloading

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The hero numeral — large, light, monospaced (design language).
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .light)
        speedLabel.textColor = .labelColor

        unitLabel.font = .systemFont(ofSize: 13, weight: .medium)
        unitLabel.textColor = .secondaryLabelColor

        moreLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        moreLabel.textColor = .tertiaryLabelColor
        moreLabel.isHidden = true

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        hairline.translatesAutoresizingMaskIntoConstraints = false
        selectionWash.translatesAutoresizingMaskIntoConstraints = false
        selectionWash.alphaValue = 0
        selectionWash.isHidden = true

        segmentStrip.translatesAutoresizingMaskIntoConstraints = false
        segmentStrip.isHidden = true
        for view in [atmosphere, selectionWash, coverPlate, coverView, eyebrowLabel, nameLabel,
                     metaLabel, speedLabel, unitLabel, moreLabel, progressBar,
                     segmentStrip, percentLabel, hairline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        coverPlate.addSubview(coverSymbol)

        NSLayoutConstraint.activate([
            atmosphere.leadingAnchor.constraint(equalTo: leadingAnchor),
            atmosphere.trailingAnchor.constraint(equalTo: trailingAnchor),
            atmosphere.topAnchor.constraint(equalTo: topAnchor),
            atmosphere.bottomAnchor.constraint(equalTo: bottomAnchor),

            selectionWash.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionWash.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionWash.topAnchor.constraint(equalTo: topAnchor),
            selectionWash.bottomAnchor.constraint(equalTo: bottomAnchor),

            coverView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            coverView.centerYAnchor.constraint(equalTo: centerYAnchor),
            coverView.widthAnchor.constraint(equalToConstant: 178),
            coverView.heightAnchor.constraint(equalToConstant: 100),
            coverPlate.leadingAnchor.constraint(equalTo: coverView.leadingAnchor),
            coverPlate.trailingAnchor.constraint(equalTo: coverView.trailingAnchor),
            coverPlate.topAnchor.constraint(equalTo: coverView.topAnchor),
            coverPlate.bottomAnchor.constraint(equalTo: coverView.bottomAnchor),
            coverSymbol.centerXAnchor.constraint(equalTo: coverPlate.centerXAnchor),
            coverSymbol.centerYAnchor.constraint(equalTo: coverPlate.centerYAnchor),
            coverSymbol.widthAnchor.constraint(equalToConstant: 40),
            coverSymbol.heightAnchor.constraint(equalToConstant: 40),

            eyebrowLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            eyebrowLabel.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 18),

            moreLabel.centerYAnchor.constraint(equalTo: eyebrowLabel.centerYAnchor),
            moreLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            nameLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            metaLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            speedLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
            speedLabel.bottomAnchor.constraint(equalTo: progressBar.topAnchor, constant: -6),
            unitLabel.firstBaselineAnchor.constraint(equalTo: speedLabel.firstBaselineAnchor),
            unitLabel.leadingAnchor.constraint(equalTo: speedLabel.trailingAnchor, constant: 6),

            progressBar.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -12),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            progressBar.heightAnchor.constraint(equalToConstant: 4),
            percentLabel.centerYAnchor.constraint(equalTo: progressBar.centerYAnchor),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            // The segment strip overlays the same lane as the plain bar; only
            // one is visible at a time (multi-connection vs single stream).
            segmentStrip.leadingAnchor.constraint(equalTo: progressBar.leadingAnchor),
            segmentStrip.trailingAnchor.constraint(equalTo: progressBar.trailingAnchor),
            segmentStrip.centerYAnchor.constraint(equalTo: progressBar.centerYAnchor),
            segmentStrip.heightAnchor.constraint(equalToConstant: 5),

            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NDMChrome.contentSurface.cgColor
        // Dark canvas: the numeral is a glowing light source in accent ink.
        // Light canvas: plain label ink, no glow (halos around dark text smear).
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        speedLabel.textColor = isDark ? NDMChrome.accent : .labelColor
        speedLabel.wantsLayer = true
        speedLabel.layer?.shadowColor = NDMChrome.accent.cgColor
        speedLabel.layer?.shadowOpacity = isDark ? 0.45 : 0
        speedLabel.layer?.shadowRadius = 10
        speedLabel.layer?.shadowOffset = .zero
        eyebrowLabel.textColor = NDMChrome.accent
    }

    override var wantsUpdateLayer: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        guard let currentTaskID,
              bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return super.mouseUp(with: event)
        }
        if event.clickCount >= 2 {
            onActivateTask?(currentTaskID)
        } else if let onSelectTask {
            onSelectTask(currentTaskID)
        } else {
            onActivateTask?(currentTaskID)
        }
    }

    override var acceptsFirstResponder: Bool { currentTaskID != nil }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers
        if (key == " " || key == "\r"),
           let currentTaskID {
            onActivateTask?(currentTaskID)
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let currentTaskID else { return false }
        if let onSelectTask {
            onSelectTask(currentTaskID)
        } else {
            onActivateTask?(currentTaskID)
        }
        return true
    }

    /// Quiet Finder-style selection wash so a stacked hero can show focus
    /// without looking like a table row.
    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        selectionWash.isHidden = !selected
        selectionWash.alphaValue = selected ? 1 : 0
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard currentTaskID != nil else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ symbol: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.ndmSymbol(symbol)
            menu.addItem(item)
        }
        add(L10n.progressDetails, #selector(heroProgress), "chart.bar.fill")
        add(L10n.pause, #selector(heroPause), "pause.fill")
        menu.addItem(.separator())
        add(L10n.copyURL, #selector(heroCopyURL), "doc.on.doc")
        add(L10n.propertiesEllipsis, #selector(heroProperties), "info.circle")
        return menu
    }

    @objc private func heroProgress() { if let id = currentTaskID { onContextAction?(.progress, id) } }
    @objc private func heroPause() { if let id = currentTaskID { onContextAction?(.pause, id) } }
    @objc private func heroCopyURL() { if let id = currentTaskID { onContextAction?(.copyURL, id) } }
    @objc private func heroProperties() { if let id = currentTaskID { onContextAction?(.properties, id) } }

    /// Live refresh from the 1 s presentation tick.
    /// `activeCount` still drives the legacy "+N more" eyebrow when a host
    /// shows only one hero for several transfers; list stacking always passes 1.
    func update(primary: TaskRowPresentation?, activeCount: Int) {
        guard let primary else {
            currentTaskID = nil
            currentRow = nil
            setAccessibilityLabel(L10n.nowDownloading)
            setAccessibilityValue(nil)
            stopRolling()
            progressBar.isActive = false
            progressBar.clearSmoothProgress()
            progressBar.onDisplayedProgressChange = nil
            percentLabel.stringValue = ""
            segmentStrip.isActive = false
            setSelected(false)
            return
        }
        let taskChanged = currentTaskID != primary.taskID
        currentTaskID = primary.taskID
        currentRow = primary

        nameLabel.stringValue = primary.filename
        progressBar.onDisplayedProgressChange = { [weak self] display in
            self?.applyDisplayedPercent(display)
        }
        setAccessibilityLabel("\(L10n.nowDownloading): \(primary.filename)")

        // Finishing tail: no bytes move in bursts, so the big speed numeral
        // would read a frozen "0". Show a stable breathing "即将完成…" instead
        // of a flickering byte/phase line — it reads as active work, not a stall.
        if primary.isFinalizing {
            metaLabel.stringValue = ""
            eyebrowLabel.stringValue = L10n.finishingUp
            // A stable line — no flickering byte counts or bouncing phase text
            // during the lumpy tail. metaLabel below still carries any detail.
            speedLabel.stringValue = L10n.almostDone
            speedLabel.font = .systemFont(ofSize: 22, weight: .medium)
            unitLabel.stringValue = ""
            startFinalizePulse()
            segmentStrip.isHidden = true
            segmentStrip.isActive = false
            progressBar.isHidden = false
            progressBar.setSmoothProgress(
                taskID: primary.taskID,
                target: primary.progressFraction,
                complete: primary.isComplete
            )
            progressBar.isActive = true
            applyDisplayedPercent(progressBar.displayedProgress)
            stopRolling()
            moreLabel.isHidden = activeCount <= 1
            if activeCount > 1 { moreLabel.stringValue = L10n.heroMoreActive(activeCount - 1) }
            if taskChanged || currentCoverTaskID != primary.taskID {
                applyCover(for: primary, crossfade: !taskChanged || currentCoverTaskID != nil)
            }
            return
        }
        stopFinalizePulse()
        metaLabel.stringValue = primary.statusDetail
        eyebrowLabel.stringValue = primary.isDownloading ? L10n.nowDownloading : primary.statusTitle
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .light)

        // Multiple live connections → show the parallel segment strip; a
        // single stream keeps the clean accent bar.
        let segments = primary.segmentStates
        if segments.count > 1 {
            segmentStrip.update(segments: segments)
            segmentStrip.isHidden = false
            segmentStrip.isActive = primary.isDownloading
            progressBar.isHidden = true
            progressBar.isActive = false
            // Still drive the shared smoother so the percent numeral eases,
            // even while the segment strip replaces the thin bar.
            progressBar.setSmoothProgress(
                taskID: primary.taskID,
                target: primary.progressFraction,
                complete: primary.isComplete
            )
            applyDisplayedPercent(progressBar.displayedProgress)
        } else {
            segmentStrip.isHidden = true
            segmentStrip.isActive = false
            progressBar.isHidden = false
            progressBar.setSmoothProgress(
                taskID: primary.taskID,
                target: primary.progressFraction,
                complete: primary.isComplete
            )
            progressBar.isActive = primary.isDownloading
            applyDisplayedPercent(progressBar.displayedProgress)
        }
        moreLabel.isHidden = activeCount <= 1
        if activeCount > 1 {
            moreLabel.stringValue = L10n.heroMoreActive(activeCount - 1)
        }
        updateSpeedTarget(from: primary, taskChanged: taskChanged)

        if taskChanged || currentCoverTaskID != primary.taskID {
            applyCover(for: primary, crossfade: !taskChanged || currentCoverTaskID != nil)
        }
    }

    private func applyDisplayedPercent(_ display: Double) {
        guard let primary = currentRow else { return }
        let text = primary.isComplete
            ? L10n.completed
            : TaskPresentationFormatting.percent(display)
        percentLabel.stringValue = text
        setAccessibilityValue(
            [text, primary.statusDetail]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
    }

    /// Cover art can arrive after the task starts — re-check on cache updates.
    func refreshCover(with rows: [TaskRowPresentation]) {
        guard let currentTaskID else { return }
        let row = rows.first(where: { $0.taskID == currentTaskID }) ?? currentRow
        guard let row else { return }
        applyCover(for: row, crossfade: true)
    }

    func refreshCover() {
        guard let currentRow else { return }
        applyCover(for: currentRow, crossfade: true)
    }

    private func applyCover(for row: TaskRowPresentation, crossfade: Bool) {
        currentCoverTaskID = row.taskID
        let allowsCrossfade = crossfade
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let cover = CoverArtCache.shared.image(for: row.taskID)
        if cover == nil {
            CoverArtCache.shared.ensureCover(
                taskID: row.taskID,
                remoteURL: nil,
                localFile: row.localFileURL
            )
        }
        if allowsCrossfade, coverView.image !== cover {
            let transition = CATransition()
            transition.duration = 0.3
            transition.type = .fade
            coverView.layer?.add(transition, forKey: "cover")
        }
        coverView.image = cover
        coverPlate.isHidden = cover != nil
        coverSymbol.isHidden = cover != nil
        if cover == nil {
            coverSymbol.image = NDMChrome.fileIcon(filename: row.filename, pointSize: 40)
        }
        let glow = cover.flatMap { NDMChrome.dominantColor(from: $0) } ?? NDMChrome.accent
        atmosphere.setAtmosphere(glow.withAlphaComponent(0.9), animated: allowsCrossfade)
    }

    /// Read-only transition geometry. This deliberately does not alter the
    /// download state's layout, typography, rolling numeral, or progress lane.
    func completionHandoffPreview() -> CompletionHandoffPreview? {
        layoutSubtreeIfNeeded()
        if let image = coverView.image, !coverView.isHidden {
            return CompletionHandoffPreview(
                image: image,
                rectInHero: convert(coverView.bounds, from: coverView),
                isArtwork: true
            )
        }
        guard let image = coverSymbol.image else { return nil }
        return CompletionHandoffPreview(
            image: image,
            rectInHero: convert(coverSymbol.bounds, from: coverSymbol),
            isArtwork: false
        )
    }

    // MARK: - One-second average, display-rate rolling numeral

    private func updateSpeedTarget(
        from row: TaskRowPresentation,
        taskChanged: Bool
    ) {
        guard row.isDownloading else {
            setTargetSpeed(0, jump: false)
            return
        }

        if taskChanged {
            stopRollTimer()
            setTargetSpeed(row.speedBytesPerSecond, jump: true)
            return
        }

        setTargetSpeed(row.speedBytesPerSecond, jump: false)
    }

    /// The target changes once per completed one-second byte window. Between
    /// targets, the visible numeral rolls at display cadence (up to 120 Hz).
    private func setTargetSpeed(_ speed: Double, jump: Bool) {
        targetSpeed = max(0, speed)
        if jump || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            displayedSpeed = targetSpeed
            renderSpeed()
            stopRollTimer()
            return
        }
        guard abs(targetSpeed - displayedSpeed) > max(targetSpeed, 1024) * 0.002 else {
            displayedSpeed = targetSpeed
            renderSpeed()
            stopRollTimer()
            return
        }
        guard rollTimer == nil else { return }
        lastRollUptime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rollTick()
            }
        }
        rollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func rollTick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let elapsed = min(1.0 / 20.0, max(1.0 / 240.0, now - (lastRollUptime ?? now)))
        lastRollUptime = now
        let delta = targetSpeed - displayedSpeed
        if abs(delta) <= max(targetSpeed, 1024) * 0.002 {
            displayedSpeed = targetSpeed
            renderSpeed()
            stopRollTimer()
            return
        }
        // Time-based easing keeps the same feel on 60 Hz and 120 Hz displays.
        let response = 1 - exp(-elapsed / 0.20)
        displayedSpeed += delta * response
        renderSpeed()
    }

    private func stopRolling() {
        stopRollTimer()
        displayedSpeed = 0
        targetSpeed = 0
    }

    private func stopRollTimer() {
        rollTimer?.invalidate()
        rollTimer = nil
        lastRollUptime = nil
    }

    private func renderSpeed() {
        let (value, unit) = SpeedNumeralFormatting.parts(displayedSpeed)
        speedLabel.stringValue = value
        unitLabel.stringValue = unit
    }

    // MARK: - Finalize pulse

    private func startFinalizePulse() {
        speedLabel.wantsLayer = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            speedLabel.layer?.removeAnimation(forKey: "finalizePulse")
            speedLabel.layer?.opacity = 1
            return
        }
        guard speedLabel.layer?.animation(forKey: "finalizePulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        speedLabel.layer?.add(pulse, forKey: "finalizePulse")
    }

    private func stopFinalizePulse() {
        speedLabel.layer?.removeAnimation(forKey: "finalizePulse")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRolling(); stopFinalizePulse() }
    }
}

/// Parallel-connection strip for the hero: one lane per active segment, each
/// filled to its own completion, laid out proportionally to segment size — the
/// same "many workers pulling at once" picture as the progress window, minified.
@MainActor
final class HeroSegmentStrip: NSView {
    private var segments: [SegmentState] = []
    private var targetSegments: [SegmentState] = []
    private var displayTimer: Timer?
    private var lastDisplayUptime: TimeInterval?

    var isActive = false {
        didSet {
            guard oldValue != isActive else { return }
            refreshActiveAnimation()
        }
    }

    private func refreshActiveAnimation() {
        if isActive && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let breath = CABasicAnimation(keyPath: "opacity")
                breath.fromValue = 1.0
                breath.toValue = 0.64
                breath.duration = 1.2
                breath.autoreverses = true
                breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer?.add(breath, forKey: "breathe")
        } else {
            layer?.removeAnimation(forKey: "breathe")
            layer?.opacity = 1
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(segments: [SegmentState]) {
        // Draw in physical byte order. Connection IDs describe workers, not
        // necessarily the left-to-right order of the finished file.
        let sorted = segments.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        let shapeChanged = self.segments.map(\.id) != sorted.map(\.id)
            || zip(self.segments, sorted).contains { $0.length != $1.length }
        targetSegments = sorted
        refreshActiveAnimation()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopDisplayTimer()
            self.segments = sorted
            needsDisplay = true
            return
        }
        if shapeChanged || self.segments.isEmpty {
            self.segments = sorted
            needsDisplay = true
            return
        }
        startDisplayTimer()
    }

    private func startDisplayTimer() {
        guard displayTimer == nil else { return }
        lastDisplayUptime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayTick()
            }
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func displayTick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard segments.count == targetSegments.count else {
            segments = targetSegments
            stopDisplayTimer()
            needsDisplay = true
            return
        }
        let elapsed = min(1.0 / 20.0, max(1.0 / 240.0, now - (lastDisplayUptime ?? now)))
        lastDisplayUptime = now
        let response = 1 - exp(-elapsed / 0.11)
        var settled = true
        for index in segments.indices {
            let current = Double(segments[index].completed)
            let target = Double(targetSegments[index].completed)
            let delta = target - current
            if abs(delta) > max(1, Double(targetSegments[index].length) * 0.0002) {
                segments[index].completed = Int64((current + delta * response).rounded())
                settled = false
            } else {
                segments[index].completed = targetSegments[index].completed
            }
            segments[index].isFinished = targetSegments[index].isFinished
        }
        needsDisplay = true
        if settled { stopDisplayTimer() }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
        lastDisplayUptime = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopDisplayTimer() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !segments.isEmpty else { return }
        let totalLength = segments.reduce(Int64(0)) { $0 + max(1, $1.length) }
        let radius = bounds.height / 2

        // Segment independence is encoded by each range's own filled byte
        // span, not by decorative spacing. The file itself is one continuous
        // range, so the track and adjacent completed spans remain seamless.
        let clip = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        clip.addClip()
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        clip.fill()

        var x: CGFloat = 0
        let fill = NDMChrome.accent
        for segment in segments {
            let frac = Double(max(1, segment.length)) / Double(totalLength)
            let laneWidth = max(1, bounds.width * CGFloat(frac))

            let done = segment.length > 0
                ? CGFloat(min(1, Double(segment.completed) / Double(segment.length)))
                : (segment.isFinished ? 1 : 0)
            if done > 0.001 {
                let fillRect = NSRect(
                    x: x,
                    y: 0,
                    width: max(1, laneWidth * done),
                    height: bounds.height
                )
                fill.setFill()
                fillRect.fill()
            }
            x += laneWidth
        }
    }
}
