import AppKit
import NDMCore

/// Contextual Free → Pro sheet. It appears only after a person asks for a Pro
/// outcome (or explicitly opens it from the menu), and leads with that outcome
/// instead of a dense, generic feature comparison.
@MainActor
final class UpgradeWindowController: NSWindowController, NSWindowDelegate {
    private static var active: UpgradeWindowController?

    private let features: [ProFeature]
    private let purchaseURL: URL?
    var onActivated: (() -> Void)?
    private var isDismissing = false

    private var primaryFeature: ProFeature? { features.first }

    static func present(
        features: [ProFeature] = [],
        parentWindow: NSWindow? = nil,
        onActivated: (() -> Void)? = nil
    ) {
        if let existing = active {
            existing.onActivated = onActivated
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let wc = UpgradeWindowController(features: features)
        wc.onActivated = onActivated
        active = wc
        guard let window = wc.window else { return }
        if let parentWindow {
            parentWindow.beginSheet(window)
        } else {
            wc.showWindow(nil)
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    init(features: [ProFeature] = []) {
        self.features = features
        self.purchaseURL = PurchaseConfiguration.purchaseURL()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.proWindowTitle
        window.isReleasedWhenClosed = false
        NDMChrome.applySheetChrome(window)
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let contextCard = makeContextCard()
        let benefits = makeBenefitsCard()

        let cancel = NSButton(title: L10n.proNotNow, target: self, action: #selector(cancelClicked))
        NDMChrome.styleGhostButton(cancel)
        cancel.keyEquivalent = "\u{1b}"

        let primary: NSButton
        if purchaseURL == nil {
            primary = NSButton(
                title: L10n.proEnterLicense,
                target: self,
                action: #selector(enterLicenseClicked)
            )
        } else {
            primary = NSButton(
                title: "\(L10n.proPurchaseCTA) · \(L10n.proProPrice)",
                target: self,
                action: #selector(purchaseClicked)
            )
        }
        NDMChrome.styleMainButton(primary)
        primary.controlSize = .large
        primary.keyEquivalent = "\r"

        var footerViews: [NSView] = [cancel]
        if purchaseURL != nil {
            let enterLicense = NSButton(
                title: L10n.proEnterLicense,
                target: self,
                action: #selector(enterLicenseClicked)
            )
            enterLicense.isBordered = false
            enterLicense.font = .systemFont(ofSize: 12, weight: .medium)
            enterLicense.contentTintColor = NDMChrome.accent
            footerViews.append(enterLicense)
        }
        footerViews.append(NSView())
        footerViews.append(makeFinePrint())
        let footer = NSStackView(views: footerViews)
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let purchaseNote = NSTextField(
            wrappingLabelWithString: purchaseURL == nil
                ? L10n.proPurchaseUnavailableBody
                : L10n.proSubline
        )
        purchaseNote.font = .systemFont(ofSize: 12)
        purchaseNote.textColor = .secondaryLabelColor
        purchaseNote.alignment = .center
        purchaseNote.maximumNumberOfLines = 2

        let stack = NSStackView(views: [contextCard, benefits, primary, purchaseNote, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: contextCard)
        stack.setCustomSpacing(16, after: benefits)
        stack.setCustomSpacing(5, after: primary)
        stack.setCustomSpacing(8, after: purchaseNote)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            contextCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            benefits.widthAnchor.constraint(equalTo: stack.widthAnchor),
            benefits.heightAnchor.constraint(equalToConstant: 152),
            primary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            primary.heightAnchor.constraint(equalToConstant: 38),
            purchaseNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancel.heightAnchor.constraint(equalToConstant: 30),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func makeContextCard() -> NSView {
        let icon = NSImageView(image: NDMChrome.symbol(
            symbolName(for: primaryFeature),
            pointSize: 22,
            weight: .semibold
        ) ?? NSImage())
        icon.contentTintColor = NDMChrome.accent
        icon.imageScaling = .scaleProportionallyDown

        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
        ])

        let eyebrow = NSTextField(labelWithString: L10n.proContextEyebrow)
        eyebrow.font = .systemFont(ofSize: 12, weight: .semibold)
        eyebrow.textColor = NDMChrome.accent

        let title = NSTextField(wrappingLabelWithString: L10n.proContextTitle(primaryFeature))
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = .labelColor
        title.maximumNumberOfLines = 2

        let body = NSTextField(wrappingLabelWithString: L10n.proContextBody(primaryFeature))
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 3

        var textViews: [NSView] = [eyebrow, title, body]
        if let extra = L10n.proAlsoUnlocks(features) {
            let extraLabel = NSTextField(labelWithString: extra)
            extraLabel.font = .systemFont(ofSize: 12, weight: .medium)
            extraLabel.textColor = NDMChrome.accent
            textViews.append(extraLabel)
        }
        let text = NSStackView(views: textViews)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(6, after: title)

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 18)
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            text.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -78),
        ])
        return row
    }

    private func makeBenefitsCard() -> NSView {
        let heading = NSTextField(labelWithString: L10n.proBenefitsTitle)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)

        let columns = NSStackView(views: [
            makeBenefit(
                symbol: "bolt.fill",
                title: L10n.proBenefitSpeedTitle,
                body: L10n.proBenefitSpeedBody
            ),
            makeBenefit(
                symbol: "wand.and.stars",
                title: L10n.proBenefitDeliveryTitle,
                body: L10n.proBenefitDeliveryBody
            ),
            makeBenefit(
                symbol: "square.stack.3d.up.fill",
                title: L10n.proBenefitMediaTitle,
                body: L10n.proBenefitMediaBody
            ),
        ])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 12
        columns.distribution = .fillEqually

        let stack = CardStackView(views: [heading, columns])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 15, right: 16)
        stack.cornerRadius = 0
        stack.fill = nil
        stack.cardBorderColor = nil
        columns.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        return stack
    }

    private func makeBenefit(symbol: String, title: String, body: String) -> NSView {
        let icon = NSImageView(image: NDMChrome.symbol(symbol, pointSize: 14, weight: .semibold) ?? NSImage())
        icon.contentTintColor = NDMChrome.accent
        icon.imageScaling = .scaleProportionallyDown

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 3

        let stack = NSStackView(views: [icon, titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])
        return stack
    }

    private func makeFinePrint() -> NSTextField {
        let fine = NSTextField(labelWithString: L10n.proFine)
        fine.font = .systemFont(ofSize: 12)
        fine.textColor = .tertiaryLabelColor
        return fine
    }

    private func symbolName(for feature: ProFeature?) -> String {
        switch feature {
        case .connections: return "arrow.triangle.branch"
        case .ultraHD: return "4k.tv.fill"
        case .collection: return "rectangle.stack.fill"
        case .subtitles: return "captions.bubble.fill"
        case nil: return "sparkles"
        }
    }

    @objc private func purchaseClicked() {
        guard let purchaseURL else { return }
        NSWorkspace.shared.open(purchaseURL)
    }

    @objc private func enterLicenseClicked() {
        guard let window else { return }
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
        alert.beginSheetModal(for: window) { [weak self, weak field] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  let key = field?.stringValue else { return }
            Task { @MainActor in self.activate(key) }
        }
    }

    private func activate(_ key: String) {
        let confirmation = NSAlert()
        do {
            let license = try LicenseStore.activate(key)
            guard LicenseStore.isPro else {
                confirmation.messageText = L10n.proInvalidKey
                showConfirmation(confirmation)
                return
            }
            confirmation.messageText = L10n.proActivated(license.email)
            guard let window else { return }
            confirmation.beginSheetModal(for: window) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let continuation = self.onActivated
                    self.dismiss(after: continuation)
                }
            }
        } catch LicenseError.expired {
            confirmation.messageText = L10n.proExpiredKey
            showConfirmation(confirmation)
        } catch {
            confirmation.messageText = L10n.proInvalidKey
            showConfirmation(confirmation)
        }
    }

    private func showConfirmation(_ alert: NSAlert) {
        guard let window else { return }
        alert.beginSheetModal(for: window)
    }

    @objc private func cancelClicked() {
        dismiss()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isDismissing else { return true }
        dismiss()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        Self.active = nil
    }

    private func dismiss(after continuation: (() -> Void)? = nil) {
        guard !isDismissing else { return }
        isDismissing = true
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
            window.orderOut(nil)
            Self.active = nil
        } else {
            window.close()
        }
        DispatchQueue.main.async { continuation?() }
    }
}
