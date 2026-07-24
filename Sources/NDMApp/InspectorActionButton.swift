import AppKit

/// Flat inspector-rail / sheet action button.
///
/// Idle stays transparent so the rail reads as text + separators, not a row of
/// cards. Hover is intentionally quieter than chip `track` washes: an ultra-light
/// fill and/or a slight tint deepen. Press deepens a notch further. No glow,
/// no conspicuous gray cushion.
@MainActor
final class InspectorActionButton: NSButton {
    enum Style { case flat, filled }

    /// Image-only AppKit buttons can report a larger alignment rect than their
    /// visible siblings. Opt into exact bounds when a compact action row needs
    /// every outlined control to share one physical height.
    var usesExactAlignmentRect = false

    override var alignmentRectInsets: NSEdgeInsets {
        usesExactAlignmentRect
            ? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            : super.alignmentRectInsets
    }

    /// `.filled` is a confident accent pill (primary actions); `.flat` is a
    /// borderless action with a hover cushion (secondary actions).
    var style: Style = .flat {
        didSet {
            applyCornerRadius()
            if style == .filled {
                contentTintColor = .white
            }
            needsDisplay = true
        }
    }

    /// When true, flat hover uses a soft accent wash instead of neutral rail —
    /// reserved for the primary action in an inspector rail so hierarchy
    /// survives hover.
    var prefersAccentHover = false {
        didSet { needsDisplay = true }
    }

    /// Hairline outlined pills (sheet secondary / compact actions). Hover
    /// deepens the ring and skips the rail gray wash so they never share the
    /// same soft block as toolbar-style text actions above.
    var usesOutlinedHover = false {
        didSet {
            applyCornerRadius()
            needsDisplay = true
        }
    }

    private var isHovering = false
    private var isPressed = false
    private var trackingAreaRef: NSTrackingArea?
    /// Resting tint for flat actions — restored on mouse exit so hover can
    /// deepen label/icon color without fighting `decorate` updates.
    private var restingTint: NSColor?

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
        applyCornerRadius()
        layer?.masksToBounds = true
        // Native exterior ring for keyboard focus — quieter than painting our
        // own accent stroke on every flat rail control.
        focusRingType = .exterior
    }

    private func applyCornerRadius() {
        // Flat rail: tight radius so hover doesn't read as a floating card.
        // Outlined pills keep a slightly rounder silhouette; filled stay soft.
        switch style {
        case .filled:
            layer?.cornerRadius = 8
        case .flat:
            layer?.cornerRadius = usesOutlinedHover ? 9 : 4
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch style {
            case .flat:
                // Do not assign NSControl properties (contentTintColor, etc.)
                // here — they invalidate the layer and can loop (see HoverIconButton).
                layer?.backgroundColor = flatFill.cgColor
                if usesOutlinedHover {
                    applyOutlinedBorder()
                }
            case .filled:
                layer?.backgroundColor = filledFill.cgColor
            }
        }
    }

    private var flatFill: NSColor {
        guard isEnabled else { return .clear }
        if usesOutlinedHover {
            // Outlined: idle clear; pressed only — a whisper so it doesn't
            // become the same gray block as the rail above.
            if isPressed { return NDMChrome.railHover }
            return .clear
        }
        if prefersAccentHover {
            if isPressed { return NDMChrome.railAccentPressed }
            if isHovering { return NDMChrome.railAccentHover }
            return .clear
        }
        if isPressed { return NDMChrome.railPressed }
        if isHovering { return NDMChrome.railHover }
        return .clear
    }

    private func applyOutlinedBorder() {
        let base = NDMChrome.hairline
        if isPressed {
            layer?.borderColor = NDMChrome.accent.withAlphaComponent(0.35).cgColor
            layer?.borderWidth = 1
        } else if isHovering {
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
            layer?.borderWidth = 1
        } else {
            layer?.borderColor = base.cgColor
            layer?.borderWidth = 1
        }
    }

    private var filledFill: NSColor {
        let accent = NDMChrome.accent
        guard isEnabled else { return accent.withAlphaComponent(0.35) }
        // Darken on interaction (same recipe as NewDownloadActionButton) —
        // bleaching with white looks washed-out on both light and dark chrome.
        if isPressed {
            return accent.blended(withFraction: 0.14, of: .black) ?? accent.withAlphaComponent(0.82)
        }
        if isHovering {
            return accent.withAlphaComponent(0.90)
        }
        return accent
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
        if hovering, style == .flat, !usesOutlinedHover {
            restingTint = contentTintColor
        }
        isHovering = hovering
        applyInteractionTint()
        refreshFill(animated: true)
    }

    private func setPressed(_ pressed: Bool) {
        guard isPressed != pressed else { return }
        isPressed = pressed
        applyInteractionTint()
        refreshFill(animated: false)
    }

    /// Capture the tint `decorate` just applied so hover deepen / exit restore
    /// stay correct across inspector refresh cycles while the pointer is down.
    func noteRestingTint() {
        guard style == .flat else { return }
        restingTint = contentTintColor
        applyInteractionTint()
    }

    /// Slightly deepen icon/label on rail hover — readable feedback without a
    /// heavy fill. Assigned outside `updateLayer` to avoid re-entrancy loops.
    private func applyInteractionTint() {
        guard style == .flat, isEnabled, !usesOutlinedHover else { return }
        if prefersAccentHover {
            // Primary already carries accent; leave it alone.
            return
        }
        if isHovering || isPressed {
            contentTintColor = .labelColor
        } else if let restingTint {
            contentTintColor = restingTint
        }
    }

    private func refreshFill(animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion else {
            needsDisplay = true
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            self.needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        setPressed(true)
        animatePress(down: true)
        super.mouseDown(with: event)  // blocks until mouse-up
        setPressed(false)
        animatePress(down: false)
    }

    private func animatePress(down: Bool) {
        guard let layer else { return }
        // A view-backed layer already anchors at its center (0.5, 0.5), so the
        // scale sinks toward the middle on its own. Do NOT touch anchorPoint or
        // position here: `position` lives in the SUPERLAYER's coordinate space,
        // and setting it to this view's bounds-center teleported the button to
        // the top-left corner (the "renew/copy jumps over retry" overlap bug).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0
                : (down ? 0.08 : 0.22)
            ctx.timingFunction = down
                ? CAMediaTimingFunction(name: .easeOut)
                : CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
            ctx.allowsImplicitAnimation = true
            // Restrained travel — 0.94 read as a toy squash on a text rail.
            layer.setAffineTransform(
                down ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
            )
        }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                if isHovering { setHovering(false) }
                if isPressed { setPressed(false) }
            }
            // Filled buttons carry their disabled state in the fill color, so
            // they don't also fade the (white) label into mud.
            alphaValue = (isEnabled || style == .filled) ? 1 : 0.4
            needsDisplay = true
        }
    }
}
