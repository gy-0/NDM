import AppKit
import NDMCore

/// "Now Downloading" cinema strip — the stage at the top of the task list
/// while bytes are moving. One primary transfer gets cover art, an ambient
/// glow in the cover's dominant color, a large rolling speed numeral, and a
/// live progress lane. Collapses away entirely when nothing is downloading.
@MainActor
final class NowDownloadingHeroView: NSView {
    var onActivateTask: ((Int64) -> Void)?

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
    private let percentLabel = NSTextField(labelWithString: "")
    private let hairline = ChromeBox(fill: NDMChrome.hairline)

    private var displayedSpeed: Double = 0
    private var targetSpeed: Double = 0
    private var rollTimer: Timer?
    private var currentTaskID: Int64?
    private var currentCoverTaskID: Int64?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

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

        for view in [atmosphere, coverPlate, coverView, eyebrowLabel, nameLabel,
                     metaLabel, speedLabel, unitLabel, moreLabel, progressBar,
                     percentLabel, hairline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        coverPlate.addSubview(coverSymbol)

        NSLayoutConstraint.activate([
            atmosphere.leadingAnchor.constraint(equalTo: leadingAnchor),
            atmosphere.trailingAnchor.constraint(equalTo: trailingAnchor),
            atmosphere.topAnchor.constraint(equalTo: topAnchor),
            atmosphere.bottomAnchor.constraint(equalTo: bottomAnchor),

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
        onActivateTask?(currentTaskID)
    }

    /// Live refresh from the 1 s presentation tick.
    func update(primary: TaskRowPresentation?, activeCount: Int) {
        guard let primary else {
            currentTaskID = nil
            stopRolling()
            progressBar.isActive = false
            return
        }
        let taskChanged = currentTaskID != primary.taskID
        currentTaskID = primary.taskID

        nameLabel.stringValue = primary.filename
        metaLabel.stringValue = primary.statusDetail
        percentLabel.stringValue = primary.progressText
        progressBar.progress = primary.progressFraction
        progressBar.isActive = true
        moreLabel.isHidden = activeCount <= 1
        if activeCount > 1 {
            moreLabel.stringValue = L10n.heroMoreActive(activeCount - 1)
        }
        setTargetSpeed(primary.speedBytesPerSecond, jump: taskChanged)

        if taskChanged || currentCoverTaskID != primary.taskID {
            applyCover(for: primary, crossfade: !taskChanged || currentCoverTaskID != nil)
        }
    }

    /// Cover art can arrive after the task starts — re-check on cache updates.
    func refreshCover(with rows: [TaskRowPresentation]) {
        guard let currentTaskID,
              let row = rows.first(where: { $0.taskID == currentTaskID }) else { return }
        applyCover(for: row, crossfade: true)
    }

    private func applyCover(for row: TaskRowPresentation, crossfade: Bool) {
        currentCoverTaskID = row.taskID
        let cover = CoverArtCache.shared.image(for: row.taskID)
        if cover == nil {
            CoverArtCache.shared.ensureCover(
                taskID: row.taskID,
                remoteURL: nil,
                localFile: row.localFileURL
            )
        }
        if crossfade, coverView.image !== cover {
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
        atmosphere.setAtmosphere(glow.withAlphaComponent(0.9), animated: crossfade)
    }

    // MARK: - Rolling numeral

    /// Ease the displayed rate toward the live rate at 30 fps so the numeral
    /// rolls smoothly between 1 s samples instead of snapping.
    private func setTargetSpeed(_ speed: Double, jump: Bool) {
        targetSpeed = max(0, speed)
        if jump {
            displayedSpeed = targetSpeed
            renderSpeed()
            return
        }
        guard rollTimer == nil else { return }
        rollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rollTick()
            }
        }
    }

    private func rollTick() {
        let delta = targetSpeed - displayedSpeed
        // Snap within half a percent — close enough that digits stop moving.
        if abs(delta) <= max(targetSpeed, 1024) * 0.005 {
            displayedSpeed = targetSpeed
            renderSpeed()
            stopRolling()
            return
        }
        displayedSpeed += delta * 0.14
        renderSpeed()
    }

    private func stopRolling() {
        rollTimer?.invalidate()
        rollTimer = nil
    }

    private func renderSpeed() {
        let (value, unit) = Self.speedParts(displayedSpeed)
        speedLabel.stringValue = value
        unitLabel.stringValue = unit
    }

    private static func speedParts(_ bytesPerSecond: Double) -> (String, String) {
        let kb = bytesPerSecond / 1024
        if kb < 1000 {
            return (String(format: kb < 100 ? "%.1f" : "%.0f", max(0, kb)), "KB/s")
        }
        let mb = kb / 1024
        if mb < 1000 {
            return (String(format: mb < 100 ? "%.1f" : "%.0f", mb), "MB/s")
        }
        return (String(format: "%.2f", mb / 1024), "GB/s")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRolling() }
    }
}
