import AppKit
import NDMCore

/// First-run activation lives in the product itself: paste a link, see what
/// NDM understood, and continue into the same New Download flow used every day.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static var exampleShareText: String { L10n.onboardingExampleShareText }

    var onTryLink: ((String?) -> Void)?
    var onFinished: (() -> Void)?

    private let inputField = NSTextField(string: "")
    private let inputShell = OnboardingLinkInputShell()
    private let clearButton = NSButton()
    private let primaryButton = NSButton(title: L10n.onboardingPasteAndContinue, target: nil, action: nil)
    private let validationLabel = NSTextField(labelWithString: "")
    private let previewRow = OnboardingPreviewRow()
    private var finishedReported = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.onboardingWindowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
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
        content.wantsLayer = true

        let brandMark = NSImageView()
        brandMark.image = Self.brandMarkImage()
        brandMark.imageScaling = .scaleProportionallyUpOrDown
        brandMark.wantsLayer = true
        brandMark.layer?.cornerRadius = 16
        brandMark.layer?.masksToBounds = true
        brandMark.setAccessibilityLabel("NDM")
        brandMark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            brandMark.widthAnchor.constraint(equalToConstant: 64),
            brandMark.heightAnchor.constraint(equalToConstant: 64),
        ])

        let title = NSTextField(labelWithString: L10n.onboardingHeroTitle)
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.alignment = .center
        title.maximumNumberOfLines = 1

        let body = NSTextField(wrappingLabelWithString: L10n.onboardingHeroBody)
        body.font = .systemFont(ofSize: 13.5)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.maximumNumberOfLines = 2

        buildInput()
        buildPrimaryButton()

        let directButton = NSButton(
            title: L10n.onboardingSkip,
            target: self,
            action: #selector(finishClicked)
        )
        directButton.isBordered = false
        directButton.font = .systemFont(ofSize: 12, weight: .medium)
        directButton.contentTintColor = .secondaryLabelColor
        directButton.keyEquivalent = "\u{1b}"
        directButton.setAccessibilityHelp(L10n.t(
            "Close Welcome without starting a download",
            "关闭欢迎页，不立即新建下载"
        ))
        directButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true

        validationLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        validationLabel.textColor = .systemRed
        validationLabel.alignment = .center
        validationLabel.isHidden = true
        validationLabel.setAccessibilityRole(.staticText)

        previewRow.target = self
        previewRow.action = #selector(previewClicked)
        previewRow.heightAnchor.constraint(equalToConstant: 72).isActive = true
        showExamplePreview()

        let mainStack = NSStackView(views: [
            brandMark,
            title,
            body,
            inputShell,
            validationLabel,
            primaryButton,
            directButton,
            previewRow,
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .centerX
        mainStack.spacing = 9
        mainStack.setCustomSpacing(10, after: brandMark)
        mainStack.setCustomSpacing(4, after: title)
        mainStack.setCustomSpacing(18, after: body)
        mainStack.setCustomSpacing(10, after: inputShell)
        mainStack.setCustomSpacing(4, after: validationLabel)
        mainStack.setCustomSpacing(4, after: primaryButton)
        mainStack.setCustomSpacing(18, after: directButton)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(mainStack)

        let footer = NSTextField(labelWithString: L10n.onboardingTrustLine)
        footer.font = .systemFont(ofSize: 10.5, weight: .medium)
        footer.textColor = .secondaryLabelColor
        footer.alignment = .center
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            mainStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            mainStack.widthAnchor.constraint(equalToConstant: 430),
            inputShell.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            inputShell.heightAnchor.constraint(equalToConstant: 44),
            primaryButton.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            previewRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -13),
        ])

        refreshInputState()
        if QAPreviewOverrides.showOnboardingError {
            DispatchQueue.main.async { [weak self] in
                self?.primaryClicked()
            }
        }
    }

    private func buildInput() {
        inputField.placeholderString = L10n.onboardingInputPlaceholder
        inputField.font = .systemFont(ofSize: 13.5, weight: .medium)
        inputField.focusRingType = .none
        inputField.delegate = self
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.isEditable = true
        inputField.isSelectable = true
        inputField.usesSingleLineMode = true
        inputField.lineBreakMode = .byTruncatingMiddle
        inputField.setAccessibilityLabel(L10n.t("Download link or share text", "下载链接或分享口令"))
        inputField.setAccessibilityHelp(L10n.onboardingHeroBody)
        inputField.translatesAutoresizingMaskIntoConstraints = false

        let linkIcon = NSImageView()
        linkIcon.image = NDMChrome.symbol("link", pointSize: 14, weight: .semibold)
        linkIcon.contentTintColor = NDMChrome.accent
        linkIcon.imageScaling = .scaleProportionallyDown
        linkIcon.setAccessibilityElement(false)
        linkIcon.translatesAutoresizingMaskIntoConstraints = false

        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.focusRingType = .none
        clearButton.image = NDMChrome.symbol("xmark.circle.fill", pointSize: 13, weight: .medium)
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearButton.toolTip = L10n.t("Clear", "清除")
        clearButton.setAccessibilityLabel(L10n.t("Clear link", "清除链接"))
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        inputShell.translatesAutoresizingMaskIntoConstraints = false
        inputShell.onActivate = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.inputField)
        }
        inputShell.addSubview(linkIcon)
        inputShell.addSubview(inputField)
        inputShell.addSubview(clearButton)
        NSLayoutConstraint.activate([
            linkIcon.leadingAnchor.constraint(equalTo: inputShell.leadingAnchor, constant: 14),
            linkIcon.centerYAnchor.constraint(equalTo: inputShell.centerYAnchor),
            linkIcon.widthAnchor.constraint(equalToConstant: 17),
            linkIcon.heightAnchor.constraint(equalToConstant: 17),
            inputField.leadingAnchor.constraint(equalTo: linkIcon.trailingAnchor, constant: 9),
            inputField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -3),
            inputField.centerYAnchor.constraint(equalTo: inputShell.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: inputShell.trailingAnchor, constant: -7),
            clearButton.centerYAnchor.constraint(equalTo: inputShell.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 30),
            clearButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func buildPrimaryButton() {
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.keyEquivalent = "\r"
        NDMChrome.styleMainButton(primaryButton)
        primaryButton.heightAnchor.constraint(equalToConstant: 42).isActive = true
        primaryButton.setAccessibilityHelp(L10n.t(
            "Use the typed link, or paste a downloadable link from the clipboard",
            "使用已输入的链接，或从剪贴板粘贴可下载链接"
        ))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(inputField)
        inputShell.isFocused = true
    }

    func windowDidResignKey(_ notification: Notification) {
        inputShell.isFocused = false
    }

    func controlTextDidChange(_ obj: Notification) {
        inputShell.isInvalid = false
        validationLabel.isHidden = true
        refreshInputState()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        inputShell.isFocused = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        inputShell.isFocused = inputField.currentEditor() != nil
    }

    private func refreshInputState() {
        let raw = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        clearButton.isHidden = raw.isEmpty
        guard let resolution = SharedLinkResolver.resolve(raw) else {
            primaryButton.title = L10n.onboardingPasteAndContinue
            primaryButton.setAccessibilityLabel(primaryButton.title)
            showExamplePreview()
            return
        }

        primaryButton.title = L10n.onboardingContinueWithLink
        primaryButton.setAccessibilityLabel(primaryButton.title)
        let sourceName = resolution.source == .web
            ? Self.displayHost(resolution.urlString)
            : SiteBrandKit.displayName(for: resolution.source)
        let title = resolution.wasExtractedFromText
            ? L10n.shareTextLinkFound
            : L10n.onboardingLinkReady(sourceName)
        let detail = resolution.source == .web
            ? L10n.onboardingDirectLinkOutcome
            : L10n.onboardingRecognizedMediaOutcome
        previewRow.configure(
            source: resolution.source,
            title: title,
            detail: detail
        )
    }

    private func showExamplePreview() {
        previewRow.configure(
            source: .youtube,
            title: L10n.onboardingExampleFound,
            detail: L10n.onboardingExampleOutcome
        )
    }

    @objc private func clearClicked() {
        inputField.stringValue = ""
        inputShell.isInvalid = false
        validationLabel.isHidden = true
        refreshInputState()
        window?.makeFirstResponder(inputField)
    }

    @objc private func primaryClicked() {
        let clipboard = QAPreviewOverrides.clipboardText
            ?? NSPasteboard.general.string(forType: .string)
            ?? NSPasteboard.general.string(forType: .URL)
        switch OnboardingLinkActionPolicy.action(
            fieldText: inputField.stringValue,
            clipboardText: clipboard
        ) {
        case .inspect(let rawInput):
            inputField.stringValue = rawInput
            inputShell.isInvalid = false
            validationLabel.isHidden = true
            refreshInputState()
            window?.makeFirstResponder(primaryButton)
            NSAccessibility.post(element: previewRow, notification: .valueChanged)
        case .open(let rawInput):
            leaveOnboarding { [onTryLink] in onTryLink?(rawInput) }
        case .needsInput:
            inputShell.isInvalid = true
            validationLabel.stringValue = L10n.onboardingNoLinkFound
            validationLabel.isHidden = false
            window?.makeFirstResponder(inputField)
            NSSound.beep()
        }
    }

    @objc private func previewClicked() {
        let raw = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if SharedLinkResolver.resolve(raw) != nil {
            leaveOnboarding { [onTryLink] in onTryLink?(raw) }
        } else {
            leaveOnboarding { [onTryLink] in onTryLink?(Self.exampleShareText) }
        }
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

    private static func brandMarkImage() -> NSImage? {
        let url = Bundle.module.url(forResource: "ndm-onboarding-mark", withExtension: "png")
            ?? Bundle.module.url(
                forResource: "ndm-onboarding-mark",
                withExtension: "png",
                subdirectory: "Brand"
            )
        guard let source = url.flatMap(NSImage.init(contentsOf:)) else { return nil }

        // The source includes a generous white export canvas. Crop to the real
        // rounded app tile so dark mode never exposes that canvas as a square.
        let output = NSImage(size: NSSize(width: 64, height: 64))
        output.lockFocus()
        source.draw(
            in: NSRect(x: 0, y: 0, width: 64, height: 64),
            from: NSRect(x: 96, y: 96, width: 320, height: 320),
            operation: .copy,
            fraction: 1
        )
        output.unlockFocus()
        return output
    }

    private static func displayHost(_ rawURL: String) -> String {
        guard let host = URL(string: rawURL)?.host?.lowercased() else { return L10n.t("Web link", "网页链接") }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

@MainActor
private final class OnboardingLinkInputShell: NSView {
    var onActivate: (() -> Void)?
    var isFocused = false { didSet { refreshAppearance() } }
    var isInvalid = false { didSet { refreshAppearance() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        refreshAppearance()
    }

    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 11
            layer?.backgroundColor = (isFocused
                ? NDMChrome.searchSurfaceFocused
                : NDMChrome.searchSurface).cgColor
            layer?.borderWidth = isInvalid ? 1.5 : 1
            layer?.borderColor = {
                if isInvalid { return NSColor.systemRed.withAlphaComponent(0.78).cgColor }
                if isFocused { return NDMChrome.accent.withAlphaComponent(0.72).cgColor }
                return NDMChrome.hairline.cgColor
            }()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }
}

@MainActor
private final class OnboardingPreviewRow: NSButton {
    private let brandView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private var isHovering = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true

        brandView.imageScaling = .scaleProportionallyDown
        brandView.imageAlignment = .alignLeft
        brandView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        chevronView.image = NDMChrome.symbol("chevron.right", pointSize: 11, weight: .semibold)
        chevronView.contentTintColor = .tertiaryLabelColor
        chevronView.setAccessibilityElement(false)
        chevronView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(brandView)
        addSubview(labels)
        addSubview(chevronView)
        NSLayoutConstraint.activate([
            brandView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            brandView.centerYAnchor.constraint(equalTo: centerYAnchor),
            brandView.widthAnchor.constraint(equalToConstant: 86),
            brandView.heightAnchor.constraint(equalToConstant: 24),
            labels.leadingAnchor.constraint(equalTo: brandView.trailingAnchor, constant: 18),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -10),
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 12
            layer?.backgroundColor = (isHovering
                ? NDMChrome.track
                : NDMChrome.dockFill).cgColor
            layer?.borderColor = NDMChrome.hairline.cgColor
            layer?.borderWidth = 1
        }
    }

    func configure(
        source: SharedLinkResolution.Source,
        title: String,
        detail: String
    ) {
        if source == .web {
            brandView.image = NDMChrome.symbol("link", pointSize: 22, weight: .medium)
            brandView.contentTintColor = NDMChrome.accent
        } else {
            brandView.image = SiteBrandKit.image(
                for: source,
                presentation: .wordmark,
                appearance: effectiveAppearance
            )
            brandView.contentTintColor = nil
        }
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        let sourceName = source == .web ? L10n.t("Web link", "网页链接") : SiteBrandKit.displayName(for: source)
        setAccessibilityLabel("\(sourceName) · \(title) · \(detail)")
        setAccessibilityHelp(L10n.t(
            "Open this link in New Download",
            "在新建下载中打开此链接"
        ))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }
}
