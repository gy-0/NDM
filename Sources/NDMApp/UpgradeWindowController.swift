import AppKit
import NDMCore

/// Free → Pro sheet (design suite §07): two honest columns, one accent CTA,
/// license entry for people who already bought. Shown only when a gate is hit
/// or from the menu — never as a launch interstitial.
@MainActor
final class UpgradeWindowController: NSWindowController {
    /// Purchase page — placeholder until the storefront is live.
    static let purchaseURL = URL(string: "https://ndm.example.com/pro")!

    private static var active: UpgradeWindowController?
    var onActivated: (() -> Void)?

    static func present(onActivated: (() -> Void)? = nil) {
        if let existing = active {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = UpgradeWindowController()
        wc.onActivated = onActivated
        active = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.proWindowTitle
        NDMChrome.applyWindowChrome(window)
        super.init(window: window)
        buildUI()
        window.center()
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in Self.active = nil }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makePlanCard(
        name: String,
        price: String,
        tagline: String,
        features: String,
        highlighted: Bool
    ) -> NSView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .bold)
        let priceLabel = NSTextField(labelWithString: price)
        priceLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        let taglineLabel = NSTextField(labelWithString: tagline)
        taglineLabel.font = .systemFont(ofSize: 10)
        taglineLabel.textColor = .secondaryLabelColor
        let featuresLabel = NSTextField(wrappingLabelWithString: features)
        featuresLabel.font = .systemFont(ofSize: 11.5)
        featuresLabel.textColor = .labelColor

        let stack = CardStackView(views: [nameLabel, priceLabel, taglineLabel, featuresLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: taglineLabel)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.cornerRadius = 11
        stack.cardBorderColor = highlighted
            ? NDMChrome.accent.withAlphaComponent(0.65)
            : NDMChrome.hairline
        return stack
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let headline = NSTextField(labelWithString: L10n.proHeadline)
        headline.font = .systemFont(ofSize: 19, weight: .bold)
        headline.alignment = .center
        let subline = NSTextField(labelWithString: L10n.proSubline)
        subline.font = .systemFont(ofSize: 11.5)
        subline.textColor = .secondaryLabelColor
        subline.alignment = .center

        let freeCard = makePlanCard(
            name: L10n.proFreeName,
            price: L10n.proFreePrice,
            tagline: L10n.proFreeTagline,
            features: L10n.proFreeFeatures,
            highlighted: false
        )
        let proCard = makePlanCard(
            name: L10n.proProName,
            price: L10n.proProPrice,
            tagline: L10n.proProTagline,
            features: L10n.proProFeatures,
            highlighted: true
        )
        let plans = NSStackView(views: [freeCard, proCard])
        plans.orientation = .horizontal
        plans.alignment = .top
        plans.spacing = 12
        plans.distribution = .fillEqually

        let cta = NSButton(title: "\(L10n.proCTA) — \(L10n.proProPrice)", target: self, action: #selector(purchaseClicked))
        cta.bezelStyle = .rounded
        cta.controlSize = .large
        cta.keyEquivalent = "\r"
        if #available(macOS 11.0, *) {
            cta.bezelColor = NDMChrome.accent
        }

        let enterLicense = NSButton(title: L10n.proEnterLicense, target: self, action: #selector(enterLicenseClicked))
        enterLicense.isBordered = false
        enterLicense.font = .systemFont(ofSize: 12)
        enterLicense.contentTintColor = NDMChrome.accent

        let fine = NSTextField(labelWithString: L10n.proFine)
        fine.font = .systemFont(ofSize: 10.5)
        fine.textColor = .tertiaryLabelColor
        fine.alignment = .center

        let stack = NSStackView(views: [headline, subline, plans, cta, enterLicense, fine])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: subline)
        stack.setCustomSpacing(18, after: plans)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            plans.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cta.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -120),
        ])
    }

    @objc private func purchaseClicked() {
        NSWorkspace.shared.open(Self.purchaseURL)
    }

    @objc private func enterLicenseClicked() {
        let alert = NSAlert()
        alert.messageText = L10n.proEnterLicense
        alert.informativeText = L10n.proLicensePrompt
        alert.addButton(withTitle: L10n.proActivate)
        alert.addButton(withTitle: L10n.cancel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "\(LicenseStore.keyPrefix).…"
        alert.accessoryView = field
        alert.layout()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let confirmation = NSAlert()
        do {
            let license = try LicenseStore.activate(field.stringValue)
            confirmation.messageText = L10n.proActivated(license.email)
            confirmation.runModal()
            onActivated?()
            window?.close()
        } catch LicenseError.expired {
            confirmation.messageText = L10n.proExpiredKey
            confirmation.runModal()
        } catch {
            confirmation.messageText = L10n.proInvalidKey
            confirmation.runModal()
        }
    }
}
