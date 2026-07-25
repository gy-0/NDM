import AppKit
import NDMCore

/// The About panel, in NDM's own language instead of the system's.
///
/// It used to be a bare `NSAlert`: a grey slab, a stock icon, and a wall of
/// preformatted text with a blue OK button. That is the one window whose entire job
/// is to say what kind of software this is, so shipping the platform default there
/// says "nobody looked at this".
///
/// Same cinema structure as the completion panel — a dark band carrying the mark and
/// the name over an accent rule, a light deck below holding facts and actions — so
/// the app has one identity rather than a designed part and a default part.
@MainActor
final class AboutWindowController: NSWindowController {
    private let bridgeEndpoint: String
    private let dataPath: String

    init(dataPath: String, bridgeEndpoint: String) {
        self.dataPath = dataPath
        self.bridgeEndpoint = bridgeEndpoint
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 366),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.aboutNDM
        NDMChrome.applyWindowChrome(window)
        // The band runs edge to edge under a transparent titlebar; the deck's own
        // Close button replaces the traffic lights.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        buildUI()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NDMChrome.contentSurface.cgColor

        let band = AboutBandView(version: Self.versionString)
        band.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(band)

        let tagline = Self.label(
            L10n.aboutTagline,
            font: .systemFont(ofSize: 13, weight: .medium),
            color: .labelColor
        )
        // The facts are the controls. A row whose value you might want carries its
        // own affordance, so there is no button elsewhere in the window referring
        // back to a line of text sitting right here.
        let specs = NSStackView(views: [
            SpecRow(
                label: L10n.dataLocation,
                value: dataPath,
                action: .init(symbol: "folder", hint: L10n.revealDataFolder) { [weak self] in
                    self?.revealDataFolder()
                    return nil
                }
            ),
            SpecRow(
                label: L10n.bridgeLabel,
                value: bridgeEndpoint,
                action: .init(symbol: "doc.on.doc", hint: L10n.copyBridgeAddress) { [weak self] in
                    self?.copyBridgeAddress()
                    return L10n.copiedToClipboard
                }
            ),
            SpecRow(label: L10n.extensionLabel, value: "NDM Relay"),
        ])
        specs.orientation = .vertical
        specs.alignment = .leading
        specs.spacing = 8
        specs.translatesAutoresizingMaskIntoConstraints = false

        // One button, because there is one thing left to do. Two gray outlined
        // rectangles flanking it added chrome, not capability.
        let close = InspectorActionButton(title: L10n.close, style: .filled)
        close.target = self
        close.action = #selector(closeWindow(_:))
        close.keyEquivalent = "\r"
        // Return already activates it; the exterior focus ring on a filled accent
        // pill just reads as a stray outline.
        close.focusRingType = .none
        close.font = .systemFont(ofSize: 13, weight: .semibold)

        let actions = NSStackView(views: [NSView(), close])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            close.heightAnchor.constraint(equalToConstant: NDMChrome.sheetActionHeight),
            close.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
        ])

        let deck = NSStackView(views: [tagline, specs, actions])
        deck.orientation = .vertical
        deck.alignment = .leading
        deck.spacing = 16
        deck.translatesAutoresizingMaskIntoConstraints = false
        deck.setCustomSpacing(20, after: specs)
        content.addSubview(deck)

        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            band.topAnchor.constraint(equalTo: content.topAnchor),
            band.heightAnchor.constraint(equalToConstant: 168),

            deck.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            deck.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            deck.topAnchor.constraint(equalTo: band.bottomAnchor, constant: 22),

            specs.widthAnchor.constraint(equalTo: deck.widthAnchor),
            actions.widthAnchor.constraint(equalTo: deck.widthAnchor),

            content.bottomAnchor.constraint(equalTo: deck.bottomAnchor, constant: 26),
        ])

        // Otherwise the ring lands on whichever secondary button AppKit picks first,
        // which reads as an accidental highlight rather than a default action.
        window.initialFirstResponder = close
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build: return "\(short) (\(build))"
        case let (short?, _): return short
        case let (_, build?): return build
        default: return "—"
        }
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func copyBridgeAddress() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bridgeEndpoint, forType: .string)
    }

    private func revealDataFolder() {
        let expanded = (dataPath as NSString).expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: expanded)
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.performClose(nil)
    }
}

/// Dark identity band: the mark, the name, the version, and the accent rule.
private final class AboutBandView: NSView {
    private static var plateColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.10, alpha: 1)
                : NSColor(calibratedWhite: 0.13, alpha: 1)
        }
    }

    init(version: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.plateColor.cgColor

        let mark = ChromeBox(fill: NDMChrome.accent, cornerRadius: 15)
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.setAccessibilityElement(false)
        let markIcon = NSImageView()
        markIcon.image = NDMChrome.symbol("arrow.down.to.line", pointSize: 24, weight: .semibold)
        markIcon.contentTintColor = .white
        markIcon.translatesAutoresizingMaskIntoConstraints = false
        markIcon.setAccessibilityElement(false)
        mark.addSubview(markIcon)

        let name = NSTextField(labelWithString: L10n.appName)
        name.font = .systemFont(ofSize: 34, weight: .bold)
        name.textColor = .white
        name.translatesAutoresizingMaskIntoConstraints = false

        let underline = ChromeBox(fill: NDMChrome.accent, cornerRadius: 2)
        underline.translatesAutoresizingMaskIntoConstraints = false

        let versionField = NSTextField(labelWithString: "\(L10n.version) \(version)")
        versionField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        versionField.textColor = NSColor.white.withAlphaComponent(0.62)
        versionField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mark)
        addSubview(name)
        addSubview(underline)
        addSubview(versionField)

        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),
            mark.widthAnchor.constraint(equalToConstant: 58),
            mark.heightAnchor.constraint(equalToConstant: 58),
            markIcon.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            markIcon.centerYAnchor.constraint(equalTo: mark.centerYAnchor),

            name.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 18),
            name.topAnchor.constraint(equalTo: mark.topAnchor, constant: -8),

            underline.leadingAnchor.constraint(equalTo: name.leadingAnchor, constant: 2),
            underline.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
            underline.widthAnchor.constraint(equalToConstant: 52),
            underline.heightAnchor.constraint(equalToConstant: 4),

            versionField.leadingAnchor.constraint(equalTo: name.leadingAnchor, constant: 2),
            versionField.topAnchor.constraint(equalTo: underline.bottomAnchor, constant: 10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = Self.plateColor.cgColor
    }
}

/// One `label — value` line, and the control for that value.
///
/// A path or an address is something you want to *do* something with, so the row
/// carries the action instead of a button somewhere else pointing back at it. The
/// affordance stays invisible until the pointer is over the row — at rest this is a
/// list of facts, and it only becomes a control when you reach for it.
///
/// No gray cushion: hover is a low accent tint, matching the rails elsewhere in the
/// app rather than the boxed-in look of a system dialog.
private final class SpecRow: NSView {
    struct Action {
        let symbol: String
        let hint: String
        /// Returns confirmation text to flash in place of the value, if any.
        let perform: () -> String?
    }

    private let field = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private let value: String
    private let action: Action?
    private var isHovering = false
    private var trackingAreaRef: NSTrackingArea?
    private var confirmationWork: DispatchWorkItem?

    init(label: String, value: String, action: Action? = nil) {
        self.value = value
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = NDMChrome.controlCornerRadius

        let key = NSTextField(labelWithString: label)
        key.font = .systemFont(ofSize: 11.5, weight: .semibold)
        key.textColor = .tertiaryLabelColor
        key.translatesAutoresizingMaskIntoConstraints = false
        key.setContentHuggingPriority(.required, for: .horizontal)

        field.stringValue = value
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false

        glyph.image = action.flatMap { NDMChrome.symbol($0.symbol, pointSize: 11, weight: .semibold) }
        glyph.contentTintColor = NDMChrome.accent
        glyph.alphaValue = 0
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)

        addSubview(key)
        addSubview(field)
        addSubview(glyph)
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            key.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            key.widthAnchor.constraint(equalToConstant: 84),
            field.leadingAnchor.constraint(equalTo: key.trailingAnchor, constant: 10),
            field.firstBaselineAnchor.constraint(equalTo: key.firstBaselineAnchor),
            field.trailingAnchor.constraint(lessThanOrEqualTo: glyph.leadingAnchor, constant: -8),
            glyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            glyph.centerYAnchor.constraint(equalTo: key.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            bottomAnchor.constraint(equalTo: key.bottomAnchor, constant: 5),
        ])

        if let action {
            toolTip = action.hint
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("\(label): \(action.hint)")
        } else {
            // Nothing to do with it, so let it be selected and read instead.
            field.isSelectable = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        guard action != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        refreshHover()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refreshHover()
    }

    override func mouseDown(with event: NSEvent) {
        guard let action else { return super.mouseDown(with: event) }
        guard let confirmation = action.perform() else { return }
        flash(confirmation)
    }

    /// Say it happened where it happened, rather than in a separate alert.
    private func flash(_ text: String) {
        confirmationWork?.cancel()
        field.stringValue = text
        field.textColor = NDMChrome.accent
        field.font = .systemFont(ofSize: 11.5, weight: .semibold)
        let restore = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.field.stringValue = self.value
            self.field.textColor = .secondaryLabelColor
            self.field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        }
        confirmationWork = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: restore)
    }

    private func refreshHover() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            glyph.animator().alphaValue = isHovering ? 1 : 0
        }
        layer?.backgroundColor = isHovering
            ? NDMChrome.accent.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
        NSCursor.pointingHand.set()
        if !isHovering { NSCursor.arrow.set() }
    }

    override func updateLayer() {
        layer?.backgroundColor = isHovering
            ? NDMChrome.accent.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
    }
}
