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
        let specs = NSStackView(views: [
            SpecRow(label: L10n.dataLocation, value: dataPath),
            SpecRow(label: L10n.bridgeLabel, value: bridgeEndpoint),
            SpecRow(label: L10n.extensionLabel, value: "NDM Relay"),
        ])
        specs.orientation = .vertical
        specs.alignment = .leading
        specs.spacing = 8
        specs.translatesAutoresizingMaskIntoConstraints = false

        let copyBridge = Self.outlinedButton(title: L10n.copyBridgeAddress)
        copyBridge.target = self
        copyBridge.action = #selector(copyBridge(_:))
        let revealData = Self.outlinedButton(title: L10n.revealDataFolder)
        revealData.target = self
        revealData.action = #selector(revealData(_:))
        let close = InspectorActionButton(title: L10n.close, style: .filled)
        close.target = self
        close.action = #selector(closeWindow(_:))
        close.keyEquivalent = "\r"
        // Return already activates it; the exterior focus ring on top of a filled
        // accent pill just reads as a stray outline.
        close.focusRingType = .none

        let actions = NSStackView(views: [copyBridge, revealData, NSView(), close])
        actions.orientation = .horizontal
        actions.spacing = 9
        actions.alignment = .centerY
        actions.translatesAutoresizingMaskIntoConstraints = false
        let actionHeight = NDMChrome.sheetActionHeight
        NSLayoutConstraint.activate([
            copyBridge.heightAnchor.constraint(equalToConstant: actionHeight),
            revealData.heightAnchor.constraint(equalToConstant: actionHeight),
            close.heightAnchor.constraint(equalToConstant: actionHeight),
            close.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
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

    /// Hairline outlined pill — the same secondary-action treatment the completion
    /// panel uses, so a dialog's buttons read as buttons instead of as loose text.
    private static func outlinedButton(title: String) -> InspectorActionButton {
        let button = InspectorActionButton(title: title, style: .flat)
        button.usesOutlinedHover = true
        button.wantsLayer = true
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NDMChrome.hairline.cgColor
        return button
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    @objc private func copyBridge(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bridgeEndpoint, forType: .string)
    }

    @objc private func revealData(_ sender: Any?) {
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

/// One `label — value` line. The value is monospaced because every one of them is
/// a path or an address the user may want to read character by character.
private final class SpecRow: NSView {
    init(label: String, value: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let key = NSTextField(labelWithString: label)
        key.font = .systemFont(ofSize: 11.5, weight: .semibold)
        key.textColor = .tertiaryLabelColor
        key.translatesAutoresizingMaskIntoConstraints = false
        key.setContentHuggingPriority(.required, for: .horizontal)

        let field = NSTextField(labelWithString: value)
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        // Selectable so the path can be picked out without a Copy button for each.
        field.isSelectable = true

        addSubview(key)
        addSubview(field)
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: leadingAnchor),
            key.topAnchor.constraint(equalTo: topAnchor),
            key.widthAnchor.constraint(equalToConstant: 84),
            field.leadingAnchor.constraint(equalTo: key.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.firstBaselineAnchor.constraint(equalTo: key.firstBaselineAnchor),
            bottomAnchor.constraint(equalTo: key.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
