import AppKit
import QuartzCore
import WebKit
import NDMCore

/// Native NDM primary action with a small live animation lens.
///
/// The capsule, label, depth, pointer feedback and accessibility are AppKit.
/// Only the 22×22 lens uses the original Appllama shader/canvas implementation.
/// This prevents the imported component from reading as a rectangular webpage.
/// Preparing/finalizing uses Amicro's AppleIconMorph; action-state icon changes
/// use Amicro's IconSwap port.
@MainActor
final class LoaderPauseButton: NSView, AccentChromeRefreshing {
    static let preferredWidth: CGFloat = 150
    static let preferredHeight: CGFloat = 52
    private static let pillHorizontalInset: CGFloat = 5
    private static let pillVerticalInset: CGFloat = 8

    let loader = LoaderButtonView()
    private let stateIcon = AmicroIconSwapView()
    private let appleMorph = AmicroAppleIconMorphView()
    private let stateLabel = NSTextField(labelWithString: L10n.pause)
    private let clickButton = LoaderInteractionButton()
    private let surfaceLayer = CALayer()
    private let glyphPlateLayer = CALayer()
    private var isHovering = false
    private var isPressing = false
    private var resolvedAccent = NSColor.systemBlue

    private enum VisualMode { case appllama, icon, appleMorph }
    private var visualMode: VisualMode = .appllama

    var onAction: (() -> Void)? {
        didSet { clickButton.target = self; clickButton.action = #selector(clicked) }
    }

    var keyEquivalent: String {
        get { clickButton.keyEquivalent }
        set { clickButton.keyEquivalent = newValue }
    }

    var isEnabled: Bool {
        get { clickButton.isEnabled }
        set { clickButton.isEnabled = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        surfaceLayer.shadowOffset = CGSize(width: 0, height: -2)
        surfaceLayer.shadowRadius = 5
        surfaceLayer.shadowOpacity = 0.22
        layer?.addSublayer(surfaceLayer)

        glyphPlateLayer.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        glyphPlateLayer.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        glyphPlateLayer.borderWidth = 0.5
        glyphPlateLayer.cornerRadius = 13
        layer?.addSublayer(glyphPlateLayer)

        loader.translatesAutoresizingMaskIntoConstraints = false
        loader.layer?.cornerRadius = 13
        loader.layer?.masksToBounds = true
        addSubview(loader)
        NSLayoutConstraint.activate([
            loader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.pillHorizontalInset + 10),
            loader.centerYAnchor.constraint(equalTo: centerYAnchor),
            loader.widthAnchor.constraint(equalToConstant: 26),
            loader.heightAnchor.constraint(equalToConstant: 26),
        ])
        loader.showGlyphOnly()

        for visual in [stateIcon, appleMorph] {
            visual.translatesAutoresizingMaskIntoConstraints = false
            addSubview(visual)
            NSLayoutConstraint.activate([
                visual.leadingAnchor.constraint(equalTo: loader.leadingAnchor),
                visual.topAnchor.constraint(equalTo: loader.topAnchor),
                visual.widthAnchor.constraint(equalTo: loader.widthAnchor),
                visual.heightAnchor.constraint(equalTo: loader.heightAnchor),
            ])
        }
        stateIcon.isHidden = true
        appleMorph.isHidden = true

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stateLabel.textColor = .white
        stateLabel.alignment = .center
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.wantsLayer = true
        addSubview(stateLabel)
        NSLayoutConstraint.activate([
            stateLabel.leadingAnchor.constraint(equalTo: loader.trailingAnchor, constant: 7),
            stateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.pillHorizontalInset + 12)),
            stateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        clickButton.isBordered = false
        clickButton.bezelStyle = .rounded
        clickButton.title = ""
        clickButton.wantsLayer = true
        clickButton.layer?.backgroundColor = NSColor.clear.cgColor
        clickButton.translatesAutoresizingMaskIntoConstraints = false
        clickButton.onHoverChange = { [weak self] hovered in
            guard let self else { return }
            self.isHovering = hovered
            self.updateInteractionAppearance()
        }
        clickButton.onPressChange = { [weak self] pressed in
            guard let self else { return }
            self.isPressing = pressed
            self.updateInteractionAppearance()
        }
        addSubview(clickButton)
        NSLayoutConstraint.activate([
            clickButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.pillHorizontalInset),
            clickButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.pillHorizontalInset),
            clickButton.topAnchor.constraint(equalTo: topAnchor, constant: Self.pillVerticalInset),
            clickButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.pillVerticalInset),
        ])

        refreshAccentChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onAction?() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.preferredWidth, height: Self.preferredHeight)
    }

    override func layout() {
        super.layout()
        let pillFrame = bounds.insetBy(dx: Self.pillHorizontalInset, dy: Self.pillVerticalInset)
        surfaceLayer.frame = pillFrame
        surfaceLayer.cornerRadius = pillFrame.height / 2
        surfaceLayer.shadowPath = CGPath(
            roundedRect: surfaceLayer.bounds,
            cornerWidth: pillFrame.height / 2,
            cornerHeight: pillFrame.height / 2,
            transform: nil
        )
        glyphPlateLayer.frame = loader.frame
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAccentChrome()
    }

    func refreshAccentChrome() {
        var accentHex = "#1E5DDA"
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedAccent = NDMChrome.accent
            accentHex = NDMChrome.hexString(for: resolvedAccent) ?? accentHex
        }
        // The tiny WebGL lens intentionally stays black-on-white in both
        // appearances, like a physical instrument inset into the accent pill.
        loader.setTheme(accentHex: accentHex, isDark: false)
        stateIcon.tintColor = .white
        appleMorph.tintColor = .white
        stateLabel.textColor = .white
        updateInteractionAppearance(animated: false)
    }

    private func updateInteractionAppearance(animated: Bool = true) {
        let scale: CGFloat = isPressing ? 0.96 : (isHovering ? 1.012 : 1)
        let lift: CGFloat = isHovering && !isPressing ? 0.75 : 0
        let duration = animated ? (isPressing ? 0.09 : 0.22) : 0
        let fill = isPressing
            ? (resolvedAccent.blended(withFraction: 0.14, of: .black) ?? resolvedAccent)
            : (isHovering ? resolvedAccent.withAlphaComponent(0.90) : resolvedAccent)

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform = CATransform3DTranslate(transform, 0, lift, 0)
        surfaceLayer.backgroundColor = fill.cgColor
        surfaceLayer.shadowColor = resolvedAccent.cgColor
        surfaceLayer.shadowOpacity = isPressing ? 0.10 : (isHovering ? 0.30 : 0.22)
        surfaceLayer.shadowRadius = isPressing ? 2 : (isHovering ? 7 : 5)
        surfaceLayer.transform = transform
        glyphPlateLayer.transform = transform
        loader.layer?.transform = transform
        stateIcon.layer?.transform = transform
        appleMorph.layer?.transform = transform
        stateLabel.layer?.transform = transform
        CATransaction.commit()
    }

    /// Running-state visual. The action label remains the action the click will
    /// perform; the live glyph carries phase identity.
    func setPhase(_ phase: DownloadPhase?) {
        stateLabel.stringValue = L10n.pause
        clickButton.setAccessibilityLabel(L10n.pause)
        switch phase {
        case .preparing, .finalizing:
            showAppleMorph()
        default:
            showAppllama()
            loader.setPhase(phase)
        }
    }

    func setStatus(_ status: DownloadStatus) {
        switch status {
        case .paused, .incomplete:
            setActionTitle(L10n.resume)
            showIcon("play.fill")
        case .error:
            setActionTitle(L10n.retry)
            showIcon("arrow.clockwise")
        case .complete:
            setActionTitle(L10n.open)
            showIcon("checkmark")
        case .waiting:
            setActionTitle(L10n.resume)
            showIcon("hourglass")
        case .downloading:
            setPhase(nil)
        }
    }

    func setActionTitle(_ title: String) {
        stateLabel.stringValue = title
        clickButton.setAccessibilityLabel(title)
    }

    private func showAppllama() {
        visualMode = .appllama
        glyphPlateLayer.isHidden = false
        loader.isHidden = false
        stateIcon.isHidden = true
        appleMorph.isHidden = true
        appleMorph.stop()
        loader.showGlyphOnly()
    }

    private func showIcon(_ symbol: String) {
        visualMode = .icon
        glyphPlateLayer.isHidden = true
        loader.isHidden = true
        appleMorph.isHidden = true
        appleMorph.stop()
        stateIcon.isHidden = false
        stateIcon.setSymbol(symbol, pointSize: 12, weight: .semibold, animated: true)
    }

    private func showAppleMorph() {
        visualMode = .appleMorph
        glyphPlateLayer.isHidden = true
        loader.isHidden = true
        stateIcon.isHidden = true
        appleMorph.isHidden = false
        appleMorph.start()
    }

    func setAccessibilityLabel(_ label: String) {
        clickButton.setAccessibilityLabel(label)
    }
}

/// A visually empty native action surface that owns mouse semantics while the
/// WKWebView underneath remains visual-only. Tracking is explicit because the
/// overlay otherwise prevents the web button's :hover / :active states.
@MainActor
private final class LoaderInteractionButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    var onPressChange: ((Bool) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?
    private(set) var isPointerInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isEnabled else { return }
        isPointerInside = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerInside = false
        onPressChange?(false)
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            super.mouseDown(with: event)
            return
        }
        onPressChange?(true)
        super.mouseDown(with: event)
        onPressChange?(false)
    }
}
