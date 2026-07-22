import AppKit

/// Flat inspector-rail button with a tactile, non-slop hover: the background
/// cushions in on enter, the whole control sinks slightly on press and
/// springs back. No gradient, no glow — just weight and responsiveness, the
/// way a good physical key feels.
@MainActor
final class InspectorActionButton: NSButton {
    enum Style { case flat, filled }

    /// `.filled` is a confident accent pill (primary actions); `.flat` is a
    /// borderless action with a hover cushion (secondary actions).
    var style: Style = .flat {
        didSet { needsDisplay = true }
    }

    private var isHovering = false
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    convenience init(title: String, style: Style = .flat) {
        self.init(frame: .zero)
        self.title = title
        self.style = style
        if style == .filled {
            contentTintColor = .white
            font = .systemFont(ofSize: 13, weight: .semibold)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func commonInit() {
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        focusRingType = .none
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        switch style {
        case .flat:
            let base: CGFloat = isHovering ? 1 : 0
            layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(0.06 * base)
                .cgColor
        case .filled:
            let accent = NDMChrome.accent
            let fill = !isEnabled
                ? accent.withAlphaComponent(0.35)
                : (isHovering ? accent.blended(withFraction: 0.12, of: .white) ?? accent : accent)
            layer?.backgroundColor = fill.cgColor
            contentTintColor = .white
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isEnabled else { return }
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovering(false)
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            self.needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        animatePress(down: true)
        super.mouseDown(with: event)  // blocks until mouse-up
        animatePress(down: false)
    }

    private func animatePress(down: Bool) {
        guard let layer else { return }
        // Anchor at center so the sink scales toward the middle.
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = mid
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = down ? 0.09 : 0.28
            ctx.timingFunction = down
                ? CAMediaTimingFunction(name: .easeOut)
                : CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
            ctx.allowsImplicitAnimation = true
            layer.setAffineTransform(
                down ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
            )
        }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled, isHovering { setHovering(false) }
            // Filled buttons carry their disabled state in the fill color, so
            // they don't also fade the (white) label into mud.
            alphaValue = (isEnabled || style == .filled) ? 1 : 0.4
            needsDisplay = true
        }
    }
}
