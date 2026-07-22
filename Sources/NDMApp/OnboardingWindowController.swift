import AppKit
import NDMCore

/// First-run promise: understand what the user gives us, produce a usable file,
/// and keep the optional browser enhancement out of the critical path.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static var exampleShareText: String { L10n.onboardingExampleShareText }

    var onInstallExtension: (() -> Void)?
    var onTryLink: ((String?) -> Void)?
    var onFinished: (() -> Void)?

    private var step = 0
    private let contentBox = NSView()
    private var dots: [ChromeBox] = []
    private var finishedReported = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.onboardingWindowTitle
        window.isReleasedWhenClosed = false
        NDMChrome.applySheetChrome(window)
        super.init(window: window)
        buildUI()
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        contentBox.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentBox)

        let dotsRow = NSStackView()
        dotsRow.orientation = .horizontal
        dotsRow.spacing = 7
        for _ in 0..<3 {
            let dot = ChromeBox(cornerRadius: 3.5)
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
            ])
            dots.append(dot)
            dotsRow.addArrangedSubview(dot)
        }
        dotsRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dotsRow)

        NSLayoutConstraint.activate([
            contentBox.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            contentBox.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            contentBox.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentBox.bottomAnchor.constraint(equalTo: dotsRow.topAnchor, constant: -12),
            dotsRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dotsRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        showStep(0)
    }

    private func showStep(_ index: Int) {
        let animate = step != index && window?.isVisible == true
        step = index
        for (i, dot) in dots.enumerated() {
            dot.fill = i == index
                ? NDMChrome.accent
                : NSColor.tertiaryLabelColor.withAlphaComponent(0.30)
        }

        let page: NSView
        switch index {
        case 0: page = makePromiseStep()
        case 1: page = makeExampleStep()
        default: page = makeReadyStep()
        }
        page.translatesAutoresizingMaskIntoConstraints = false

        if animate {
            contentBox.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.22
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentBox.layer?.add(fade, forKey: "step")
        }

        contentBox.subviews.forEach { $0.removeFromSuperview() }
        contentBox.addSubview(page)
        NSLayoutConstraint.activate([
            page.centerXAnchor.constraint(equalTo: contentBox.centerXAnchor),
            page.centerYAnchor.constraint(equalTo: contentBox.centerYAnchor),
            page.widthAnchor.constraint(equalTo: contentBox.widthAnchor, constant: -104),
        ])
    }

    // MARK: - Shared pieces

    private func makeMark(symbol: String) -> NSView {
        // Open hero glyph — a light accent symbol, no pastel tile behind it.
        let icon = NSImageView()
        icon.image = NDMChrome.symbol(symbol, pointSize: 34, weight: .light)
        icon.contentTintColor = NDMChrome.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(icon)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 52),
            holder.heightAnchor.constraint(equalToConstant: 44),
            icon.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    private func makeTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.alignment = .center
        label.maximumNumberOfLines = 1
        return label
    }

    private func makeBody(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13.5)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 2
        return label
    }

    private func makePrimary(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        NDMChrome.styleMainButton(button)
        button.keyEquivalent = "\r"
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        return button
    }

    private func makeSecondary(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        NDMChrome.styleGhostButton(button)
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func makeActions(primary: NSButton, secondary: NSButton? = nil) -> NSStackView {
        var views: [NSView] = [primary]
        if let secondary { views.append(secondary) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func makeCapabilityRow(symbol: String, title: String, body: String) -> NSView {
        let icon = NSImageView()
        icon.image = NDMChrome.symbol(symbol, pointSize: 17, weight: .medium)
        icon.contentTintColor = NDMChrome.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let detail = NSTextField(labelWithString: body)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [heading, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.edgeInsets = NSEdgeInsets(top: 9, left: 4, bottom: 9, right: 11)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
        ])
        return row
    }

    private func makeCard(rows: [NSView]) -> CardStackView {
        let card = CardStackView(views: rows)
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 0
        card.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        // Open feature list — rows breathe on the page, no gray card.
        card.fill = nil
        card.cardBorderColor = nil
        card.cornerRadius = 0
        for row in rows {
            row.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -4).isActive = true
        }
        return card
    }

    // MARK: - Step 1: product promise

    private func makePromiseStep() -> NSView {
        let sources = NSTextField(labelWithString: L10n.onboardingSources)
        sources.font = .systemFont(ofSize: 11.5, weight: .medium)
        sources.textColor = NDMChrome.accent
        sources.alignment = .center

        let card = makeCard(rows: [
            makeCapabilityRow(
                symbol: "text.viewfinder",
                title: L10n.onboardingUnderstandsTitle,
                body: L10n.onboardingUnderstandsBody
            ),
            makeCapabilityRow(
                symbol: "play.rectangle.on.rectangle",
                title: L10n.onboardingDeliversTitle,
                body: L10n.onboardingDeliversBody
            ),
        ])
        let actions = makeActions(
            primary: makePrimary(L10n.onboardingContinue, action: #selector(nextClicked)),
            secondary: makeSecondary(L10n.onboardingSkip, action: #selector(finishClicked))
        )
        let stack = NSStackView(views: [
            makeMark(symbol: "link"),
            makeTitle(L10n.onboardingStep1Title),
            makeBody(L10n.onboardingStep1Body),
            sources,
            card,
            actions,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 11
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(16, after: sources)
        stack.setCustomSpacing(18, after: card)
        return stack
    }

    // MARK: - Step 2: real product entry

    private func makeExampleStep() -> NSView {
        let shareLabel = NSTextField(wrappingLabelWithString: L10n.onboardingExampleShareText)
        shareLabel.font = .systemFont(ofSize: 12.5)
        shareLabel.textColor = .labelColor
        shareLabel.maximumNumberOfLines = 2
        shareLabel.lineBreakMode = .byTruncatingTail

        let foundIcon = NSImageView()
        foundIcon.image = NDMChrome.symbol("checkmark.circle.fill", pointSize: 14, weight: .semibold)
        foundIcon.contentTintColor = NDMChrome.accent
        foundIcon.setAccessibilityElement(false)
        let foundTitle = NSTextField(labelWithString: L10n.onboardingExampleFound)
        foundTitle.font = .systemFont(ofSize: 11.5, weight: .semibold)
        let foundDetail = NSTextField(labelWithString: L10n.onboardingExampleOutcome)
        foundDetail.font = .systemFont(ofSize: 11)
        foundDetail.textColor = .secondaryLabelColor
        foundDetail.lineBreakMode = .byTruncatingTail
        let foundLabels = NSStackView(views: [foundTitle, foundDetail])
        foundLabels.orientation = .vertical
        foundLabels.alignment = .leading
        foundLabels.spacing = 2
        let foundRow = NSStackView(views: [foundIcon, foundLabels])
        foundRow.orientation = .horizontal
        foundRow.alignment = .centerY
        foundRow.spacing = 9

        let card = CardStackView(views: [shareLabel, foundRow])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 12
        card.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        // Open feature list — rows breathe on the page, no gray card.
        card.fill = nil
        card.cardBorderColor = nil
        card.cornerRadius = 0
        shareLabel.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -32).isActive = true
        foundRow.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -32).isActive = true

        let ownLink = makeSecondary(L10n.onboardingUseOwnLink, action: #selector(ownLinkClicked))
        let actions = makeActions(
            primary: makePrimary(L10n.onboardingTryExample, action: #selector(exampleClicked)),
            secondary: ownLink
        )
        let later = NSButton(title: L10n.onboardingNotNow, target: self, action: #selector(nextClicked))
        later.isBordered = false
        later.font = .systemFont(ofSize: 12, weight: .medium)
        later.contentTintColor = .secondaryLabelColor
        later.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true

        let stack = NSStackView(views: [
            makeMark(symbol: "link.badge.plus"),
            makeTitle(L10n.onboardingStep2Title),
            makeBody(L10n.onboardingStep2Body),
            card,
            actions,
            later,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 11
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(18, after: card)
        stack.setCustomSpacing(2, after: actions)
        return stack
    }

    // MARK: - Step 3: trust and optional enhancement

    private func makeReadyStep() -> NSView {
        let card = makeCard(rows: [
            makeCapabilityRow(
                symbol: "checkmark.seal",
                title: L10n.onboardingBuiltInTitle,
                body: L10n.onboardingBuiltInBody
            ),
            makeCapabilityRow(
                symbol: "lock.shield",
                title: L10n.onboardingPrivateTitle,
                body: L10n.onboardingPrivateBody
            ),
            makeCapabilityRow(
                symbol: "puzzlepiece.extension",
                title: L10n.onboardingBrowserOptionalTitle,
                body: L10n.onboardingBrowserOptionalBody
            ),
        ])
        let actions = makeActions(
            primary: makePrimary(L10n.onboardingDone, action: #selector(finishClicked)),
            secondary: makeSecondary(L10n.onboardingConnectBrowser, action: #selector(browserClicked))
        )
        let stack = NSStackView(views: [
            makeMark(symbol: "checkmark"),
            makeTitle(L10n.onboardingStep3Title),
            makeBody(L10n.onboardingStep3Body),
            card,
            actions,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 11
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(18, after: card)
        return stack
    }

    // MARK: - Actions

    @objc private func nextClicked() {
        showStep(min(2, step + 1))
    }

    @objc private func exampleClicked() {
        leaveOnboarding { [onTryLink] in onTryLink?(Self.exampleShareText) }
    }

    @objc private func ownLinkClicked() {
        leaveOnboarding { [onTryLink] in onTryLink?(nil) }
    }

    @objc private func browserClicked() {
        leaveOnboarding { [onInstallExtension] in onInstallExtension?() }
    }

    @objc private func finishClicked() {
        leaveOnboarding {}
    }

    private func leaveOnboarding(next: () -> Void) {
        reportFinished()
        window?.close()
        next()
    }

    private func reportFinished() {
        guard !finishedReported else { return }
        finishedReported = true
        onFinished?()
    }

    func windowWillClose(_ notification: Notification) {
        reportFinished()
    }
}
