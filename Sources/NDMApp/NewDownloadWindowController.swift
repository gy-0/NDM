import AppKit
import UniformTypeIdentifiers
import NDMCore
import NDMEngine

/// Quiet Finder “New Download” sheet — not a wide NSAlert.
/// Prefills from either a URL or a copied social-app share message.
@MainActor
final class NewDownloadWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    struct ReadyChoice {
        let format: YtDlpFormat
        let options: YtDlpDownloadOptions

        var containerLabel: String {
            options.container == .compactMKV ? "MKV" : "MP4"
        }
    }

    struct Submission {
        let urlString: String
        let preflight: MediaPreflightResult?
        let readyChoice: ReadyChoice?
    }

    enum Result {
        case download(Submission)
        case showExisting(Int64)
        case cancel
    }

    private var onFinish: ((Result) -> Void)?
    private let existingTasks: [DownloadTask]
    private let destinationDirectory: URL
    private let urlField = NSTextField(string: "")
    private let urlShell = LinkInputShell()
    private let clearButton = NSButton()
    private let statusIcon = NSImageView()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusRow = NSStackView()
    private let hintRow = NSStackView()
    private let downloadButton = NewDownloadActionButton(title: L10n.linkLensContinue, style: .primary)
    private let viewExistingButton = NewDownloadActionButton(title: L10n.linkLensViewExisting, style: .secondary)
    private let optionsButton = NewDownloadActionButton(title: L10n.linkLensOptions, style: .secondary)
    private let identityView = LinkLensView()
    private var preflightTask: Task<Void, Never>?
    private var preparedResult: MediaPreflightResult?
    private var matchedTask: DownloadTask?
    private var readyChoice: ReadyChoice?
    private var didNormalizeShareInput = false
    private var didFinish = false

    private static var active: NewDownloadWindowController?

    init(
        initialURL: String?,
        existingTasks: [DownloadTask],
        destinationDirectory: URL,
        onFinish: @escaping (Result) -> Void
    ) {
        self.onFinish = onFinish
        self.existingTasks = existingTasks
        self.destinationDirectory = destinationDirectory
        let hasInitialPreview = initialURL.flatMap(ClipboardLinks.resolution) != nil
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: hasInitialPreview ? 420 : 214),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.newDownload
        window.isFloatingPanel = false
        window.becomesKeyOnlyIfNeeded = false
        window.isReleasedWhenClosed = false
        window.representedURL = nil
        NDMChrome.applySheetChrome(window)
        super.init(window: window)
        window.delegate = self
        buildUI(initialURL: initialURL)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Present and await a URL plus any metadata already prepared in the sheet.
    static func present(
        on parentWindow: NSWindow?,
        existingTasks: [DownloadTask],
        destinationDirectory: URL,
        initialURL: String? = nil
    ) async -> Result {
        let clip = initialURL ?? ClipboardLinks.firstDownloadableInput()
        return await withCheckedContinuation { continuation in
            let wc = NewDownloadWindowController(
                initialURL: clip,
                existingTasks: existingTasks,
                destinationDirectory: destinationDirectory
            ) { result in
                Self.active = nil
                continuation.resume(returning: result)
            }
            Self.active = wc
            guard let sheet = wc.window else {
                continuation.resume(returning: .cancel)
                return
            }
            if let parent = parentWindow {
                parent.beginSheet(sheet) { _ in }
            } else {
                sheet.center()
                sheet.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            DispatchQueue.main.async {
                if let field = sheet.contentView?.viewWithTag(1001) as? NSTextField {
                    sheet.makeFirstResponder(field)
                }
            }
        }
    }

    private func buildUI(initialURL: String?) {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let title = NSTextField(labelWithString: L10n.newDownload)
        title.font = .systemFont(ofSize: 22, weight: .bold)

        let headerIcon = NSImageView()
        headerIcon.image = NDMChrome.symbol("arrow.down.circle.fill", pointSize: 22, weight: .semibold)
        headerIcon.contentTintColor = NDMChrome.accent
        headerIcon.imageScaling = .scaleProportionallyDown
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerIcon.widthAnchor.constraint(equalToConstant: 26),
            headerIcon.heightAnchor.constraint(equalToConstant: 26),
        ])
        let headingCopy = NSStackView(views: [title])
        headingCopy.orientation = .vertical
        headingCopy.alignment = .leading
        headingCopy.spacing = 3
        let header = NSStackView(views: [headerIcon, headingCopy])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 11

        urlField.tag = 1001
        urlField.placeholderString = "https://"
        urlField.font = .systemFont(ofSize: 13.5, weight: .medium)
        urlField.focusRingType = .none
        urlField.delegate = self
        urlField.isBordered = false
        urlField.drawsBackground = false
        urlField.isEditable = true
        urlField.isSelectable = true
        urlField.usesSingleLineMode = true
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.translatesAutoresizingMaskIntoConstraints = false

        let linkIcon = NSImageView()
        linkIcon.image = NDMChrome.symbol("link", pointSize: 13, weight: .semibold)
        linkIcon.contentTintColor = .secondaryLabelColor
        linkIcon.imageScaling = .scaleProportionallyDown
        linkIcon.translatesAutoresizingMaskIntoConstraints = false

        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.focusRingType = .none
        clearButton.image = NDMChrome.symbol("xmark.circle.fill", pointSize: 13, weight: .medium)
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.target = self
        clearButton.action = #selector(clearURLClicked)
        clearButton.toolTip = L10n.t("Clear link", "清除链接")
        clearButton.setAccessibilityLabel(L10n.t("Clear link", "清除链接"))
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        urlShell.translatesAutoresizingMaskIntoConstraints = false
        urlShell.onActivate = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.urlField)
        }
        urlShell.addSubview(linkIcon)
        urlShell.addSubview(urlField)
        urlShell.addSubview(clearButton)
        NSLayoutConstraint.activate([
            linkIcon.leadingAnchor.constraint(equalTo: urlShell.leadingAnchor, constant: 14),
            linkIcon.centerYAnchor.constraint(equalTo: urlShell.centerYAnchor),
            linkIcon.widthAnchor.constraint(equalToConstant: 16),
            linkIcon.heightAnchor.constraint(equalToConstant: 16),
            urlField.leadingAnchor.constraint(equalTo: linkIcon.trailingAnchor, constant: 9),
            urlField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            urlField.centerYAnchor.constraint(equalTo: urlShell.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: urlShell.trailingAnchor, constant: -7),
            clearButton.centerYAnchor.constraint(equalTo: urlShell.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 30),
            clearButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        if let initialURL, !initialURL.isEmpty,
           let resolution = ClipboardLinks.resolution(initialURL) {
            // Show the useful result, not the noisy share command, while
            // preserving the recognition state for reassuring feedback.
            urlField.stringValue = resolution.urlString
            didNormalizeShareInput = resolution.wasExtractedFromText
            setStatus(
                resolution.wasExtractedFromText ? L10n.shareTextLinkFound : L10n.clipboardURLFilled,
                symbolName: resolution.wasExtractedFromText ? "wand.and.stars" : "doc.on.clipboard.fill",
                color: NDMChrome.accent
            )
        } else if let initialURL, !initialURL.isEmpty {
            urlField.stringValue = initialURL
            setStatus(L10n.clipboardURLEdited, symbolName: "link", color: .tertiaryLabelColor)
        } else {
            setStatus(L10n.clipboardURLEmpty, symbolName: "doc.on.clipboard", color: .tertiaryLabelColor)
        }
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusRow.setViews([statusIcon, statusLabel], in: .leading)
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 7
        NSLayoutConstraint.activate([
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),
        ])

        if YtDlpTool.isAvailable {
            hintLabel.stringValue = L10n.ytdlpReadyHint
        } else {
            hintLabel.stringValue = L10n.ytdlpMissingHint
        }
        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = .secondaryLabelColor

        let hintIcon = NSImageView()
        hintIcon.image = NDMChrome.symbol("sparkles", pointSize: 11, weight: .medium)
        hintIcon.contentTintColor = .secondaryLabelColor
        hintIcon.imageScaling = .scaleProportionallyDown
        hintRow.setViews([hintIcon, hintLabel], in: .leading)
        hintRow.orientation = .horizontal
        hintRow.alignment = .centerY
        hintRow.spacing = 7
        NSLayoutConstraint.activate([
            hintIcon.widthAnchor.constraint(equalToConstant: 14),
            hintIcon.heightAnchor.constraint(equalToConstant: 14),
        ])

        let cancel = NewDownloadActionButton(title: L10n.cancel, style: .secondary)
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        cancel.keyEquivalent = "\u{1b}"

        downloadButton.target = self
        downloadButton.action = #selector(downloadClicked)
        downloadButton.keyEquivalent = "\r"
        viewExistingButton.target = self
        viewExistingButton.action = #selector(viewExistingClicked)
        viewExistingButton.isHidden = true
        optionsButton.target = self
        optionsButton.action = #selector(optionsClicked)
        optionsButton.isHidden = true
        refreshDownloadEnabled()
        refreshClearButton()

        let destinationIcon = NSImageView()
        destinationIcon.image = NDMChrome.symbol("folder.fill", pointSize: 11.5, weight: .medium)
        destinationIcon.contentTintColor = .secondaryLabelColor
        destinationIcon.imageScaling = .scaleProportionallyDown
        let destinationLabel = NSTextField(labelWithString: L10n.t(
            "Saves to \(destinationDirectory.lastPathComponent)",
            "保存到 \(destinationDirectory.lastPathComponent)"
        ))
        destinationLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        destinationLabel.textColor = .secondaryLabelColor
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        destinationLabel.toolTip = destinationDirectory.path
        let destination = NSStackView(views: [destinationIcon, destinationLabel])
        destination.orientation = .horizontal
        destination.alignment = .centerY
        destination.spacing = 6
        destination.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [destination, NSView(), cancel, viewExistingButton, optionsButton, downloadButton])
        actions.orientation = .horizontal
        actions.spacing = 9
        actions.alignment = .centerY

        let stack = NSStackView(views: [header, urlShell, identityView, statusRow, hintRow, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.setCustomSpacing(16, after: header)
        stack.setCustomSpacing(12, after: urlShell)
        stack.setCustomSpacing(10, after: identityView)
        stack.setCustomSpacing(5, after: statusRow)
        stack.setCustomSpacing(15, after: hintRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            urlShell.widthAnchor.constraint(equalTo: stack.widthAnchor),
            urlShell.heightAnchor.constraint(equalToConstant: 46),
            identityView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            identityView.heightAnchor.constraint(equalToConstant: 118),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancel.heightAnchor.constraint(equalToConstant: 36),
            viewExistingButton.heightAnchor.constraint(equalToConstant: 36),
            optionsButton.heightAnchor.constraint(equalToConstant: 36),
            downloadButton.heightAnchor.constraint(equalToConstant: 36),
            downloadButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
        ])
        refreshLinkIdentity()
    }

    private func refreshDownloadEnabled() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        downloadButton.isEnabled = ClipboardLinks.resolution(raw) != nil
    }

    func controlTextDidChange(_ obj: Notification) {
        let typed = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedResolution = ClipboardLinks.resolution(typed)
        if let typedResolution, typedResolution.wasExtractedFromText {
            // A pasted share message collapses into the clean actionable URL
            // immediately. The Link Lens below carries the platform identity.
            urlField.stringValue = typedResolution.urlString
            didNormalizeShareInput = true
        } else {
            didNormalizeShareInput = false
        }
        refreshDownloadEnabled()
        refreshClearButton()
        refreshLinkIdentity()
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolution = ClipboardLinks.resolution(raw)
        if let matchedTask {
            showDuplicateStatus(matchedTask)
        } else if let resolution {
            let recognizedShare = didNormalizeShareInput || resolution.wasExtractedFromText
            if recognizedShare {
                setStatus(
                    L10n.shareTextLinkFound,
                    symbolName: "wand.and.stars",
                    color: NDMChrome.accent
                )
            } else {
                hideStatus()
            }
        } else {
            hideStatus()
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        urlShell.isFocused = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        urlShell.isFocused = false
    }

    @objc private func clearURLClicked() {
        urlField.stringValue = ""
        didNormalizeShareInput = false
        refreshDownloadEnabled()
        refreshClearButton()
        refreshLinkIdentity()
        hideStatus()
        window?.makeFirstResponder(urlField)
    }

    private func refreshClearButton() {
        clearButton.isHidden = urlField.stringValue.isEmpty
    }

    private func setStatus(_ text: String, symbolName: String, color: NSColor) {
        statusRow.isHidden = false
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusIcon.image = NDMChrome.symbol(symbolName, pointSize: 11.5, weight: .semibold)
        statusIcon.contentTintColor = color
    }

    private func hideStatus() {
        statusRow.isHidden = true
    }

    private func setHint(_ text: String?) {
        hintLabel.stringValue = text ?? ""
        hintRow.isHidden = text == nil
    }

    private func setPreviewVisible(_ visible: Bool) {
        let targetHeight: CGFloat = visible ? 420 : 214
        guard let window, abs(window.contentLayoutRect.height - targetHeight) > 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            window.animator().setContentSize(NSSize(width: 610, height: targetHeight))
        }
    }

    private func refreshLinkIdentity() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        preflightTask?.cancel()
        preparedResult = nil
        readyChoice = nil
        guard let resolution = ClipboardLinks.resolution(raw) else {
            refreshDuplicate(urlStrings: [])
            identityView.clear()
            hideStatus()
            setHint(nil)
            setPreviewVisible(false)
            return
        }
        setPreviewVisible(true)
        let urlString = resolution.urlString
        refreshDuplicate(urlStrings: [urlString])
        let isMediaPage = MediaLinkClassifier.looksLikeMediaPage(urlString)
        if !isMediaPage, let url = URL(string: urlString) {
            setHint(nil)
            identityView.showDirectFileEstimate(url: url)
            preflightTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard let self, !Task.isCancelled else { return }
                self.identityView.showDirectFileLoading(url: url)
                do {
                    let preview = try await RemoteFilePreviewProbe.probe(url: url)
                    guard !Task.isCancelled,
                          ClipboardLinks.resolution(self.urlField.stringValue)?.urlString == urlString else { return }
                    self.identityView.showDirectFilePreview(preview)
                    self.refreshDuplicate(urlStrings: [
                        urlString,
                        preview.resolvedURL.absoluteString,
                    ])
                    if let matchedTask = self.matchedTask {
                        self.showDuplicateStatus(matchedTask)
                    }
                } catch {
                    guard !Task.isCancelled,
                          ClipboardLinks.resolution(self.urlField.stringValue)?.urlString == urlString else { return }
                    self.identityView.showDirectFileFallback(url: url)
                }
            }
            return
        }

        identityView.showIdentity(urlString: urlString)
        setHint(YtDlpTool.isAvailable ? nil : L10n.ytdlpMissingHint)
        guard YtDlpTool.isAvailable, isMediaPage else { return }

        preflightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard let self, !Task.isCancelled else { return }
            self.identityView.showLoading(urlString: urlString)
            do {
                let result = try await MediaPreflightStore.shared.result(for: urlString)
                guard !Task.isCancelled,
                      ClipboardLinks.resolution(self.urlField.stringValue)?.urlString == urlString else { return }
                self.preparedResult = result
                self.readyChoice = self.makeReadyChoice(for: result)
                self.identityView.showPreview(result)
                var identities = [urlString, result.resolvedURL]
                if result.collection == nil {
                    identities.append(result.mediaURL)
                }
                self.refreshDuplicate(urlStrings: identities)
                if let matchedTask = self.matchedTask {
                    self.showDuplicateStatus(matchedTask)
                }
            } catch {
                guard !Task.isCancelled,
                      ClipboardLinks.resolution(self.urlField.stringValue)?.urlString == urlString else { return }
                self.identityView.showFallback(urlString: urlString)
            }
        }
    }

    @objc private func downloadClicked() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolution = ClipboardLinks.resolution(raw) else { return }
        finish(.download(Submission(
            urlString: resolution.urlString,
            preflight: preparedResult,
            readyChoice: matchedTask == nil ? readyChoice : nil
        )))
    }

    @objc private func optionsClicked() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolution = ClipboardLinks.resolution(raw) else { return }
        finish(.download(Submission(
            urlString: resolution.urlString,
            preflight: preparedResult,
            readyChoice: nil
        )))
    }

    @objc private func viewExistingClicked() {
        guard let matchedTask else { return }
        finish(.showExisting(matchedTask.id))
    }

    @objc private func cancelClicked() {
        finish(.cancel)
    }

    func windowWillClose(_ notification: Notification) {
        finish(.cancel)
    }

    private func finish(_ result: Result) {
        guard !didFinish else { return }
        didFinish = true
        preflightTask?.cancel()
        let callback = onFinish
        onFinish = nil
        window?.delegate = nil
        if let sheet = window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            window?.close()
        }
        callback?(result)
    }

    private func refreshDuplicate(urlStrings: [String]) {
        matchedTask = DuplicateDownloadMatcher.bestMatch(
            for: urlStrings,
            in: existingTasks
        )
        let hasMatch = matchedTask != nil
        viewExistingButton.isHidden = !hasMatch
        optionsButton.isHidden = hasMatch || readyChoice == nil
        if hasMatch {
            downloadButton.title = L10n.linkLensDownloadAgain
            downloadButton.toolTip = nil
        } else if let readyChoice {
            downloadButton.title = L10n.linkLensDownloadReadyChoice(
                readyChoice.format.label,
                container: readyChoice.containerLabel
            )
            downloadButton.toolTip = L10n.linkLensReadyChoiceTooltip
        } else {
            downloadButton.title = L10n.linkLensContinue
            downloadButton.toolTip = nil
        }
        downloadButton.invalidateIntrinsicContentSize()
        if let matchedTask {
            showDuplicateStatus(matchedTask)
        }
    }

    private func makeReadyChoice(for result: MediaPreflightResult) -> ReadyChoice? {
        guard result.collection == nil,
              let preference = SiteMediaPreferenceStore.load(for: result.mediaURL),
              let resolution = preference.exactResolution(
                  formatHeights: result.probe.formats.map(\.height),
                  subtitleCodes: result.probe.subtitleTracks.map(\.code)
              ),
              result.probe.formats.indices.contains(resolution.selectedFormatIndex) else {
            return nil
        }
        let format = result.probe.formats[resolution.selectedFormatIndex]
        let container: YtDlpContainerPreference = resolution.container == .compactMKV
            ? .compactMKV
            : .compatibleMP4
        let budget = StorageBudget.media(
            sampleFinalBytes: format.estimatedBytes(for: container),
            sampleComponentBytes: format.estimatedComponentBytes(for: container),
            sampleDurationSeconds: result.probe.durationSeconds
        )
        let confidence = StorageConfidence(
            budget: budget,
            availableBytes: VolumeCapacity.availableBytes(at: destinationDirectory)
        )
        // Tight and unknown states still deserve the full Space Confidence row.
        guard confidence.level == .comfortable else { return nil }

        return ReadyChoice(
            format: format,
            options: YtDlpDownloadOptions(
                container: container,
                subtitleLanguage: resolution.subtitleLanguage
            )
        )
    }

    private func showDuplicateStatus(_ task: DownloadTask) {
        let pageTitle = task.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = !task.filename.isEmpty
            ? task.filename
            : (pageTitle.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.unknown)
        switch task.status {
        case .complete:
            setStatus(
                L10n.linkLensExistingComplete(filename),
                symbolName: "checkmark.circle.fill",
                color: NDMChrome.accent
            )
        case .downloading, .waiting:
            setStatus(
                L10n.linkLensExistingActive(filename),
                symbolName: "arrow.down.circle.fill",
                color: NDMChrome.accent
            )
        case .paused, .incomplete, .error:
            setStatus(
                L10n.linkLensExistingTask(filename),
                symbolName: "clock.fill",
                color: NDMChrome.accent
            )
        }
    }
}

@MainActor
private final class LinkInputShell: NSView {
    var onActivate: (() -> Void)?
    var isFocused = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 11
            layer?.backgroundColor = (isFocused
                ? NDMChrome.searchSurfaceFocused
                : NDMChrome.searchSurface).cgColor
            layer?.borderWidth = isFocused ? 1.5 : 1
            layer?.borderColor = (isFocused
                ? NDMChrome.accent.withAlphaComponent(0.78)
                : NDMChrome.hairline).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }
}

@MainActor
private final class NewDownloadActionButton: NSButton {
    enum Style { case primary, secondary }

    private let actionStyle: Style
    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    init(title: String, style: Style) {
        self.actionStyle = style
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .inline
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        font = .systemFont(ofSize: 12.5, weight: style == .primary ? .semibold : .medium)
        contentTintColor = style == .primary ? .white : .labelColor
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: max(74, base.width + 28), height: 36)
    }

    override var isEnabled: Bool {
        didSet {
            if actionStyle == .secondary {
                contentTintColor = isEnabled ? .labelColor : .tertiaryLabelColor
            }
            needsDisplay = true
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let keyboardFocused = window?.firstResponder === self
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch actionStyle {
            case .primary:
                let fill = isEnabled
                    ? (isHovering ? NDMChrome.accent.withAlphaComponent(0.90) : NDMChrome.accent)
                    : NDMChrome.accent.withAlphaComponent(0.34)
                layer?.backgroundColor = fill.cgColor
                layer?.borderWidth = keyboardFocused ? 1.5 : 0
                layer?.borderColor = NSColor.white.withAlphaComponent(0.76).cgColor
            case .secondary:
                layer?.backgroundColor = (isHovering ? NDMChrome.track : NDMChrome.searchSurface).cgColor
                layer?.borderWidth = keyboardFocused ? 1.5 : 1
                layer?.borderColor = (keyboardFocused
                    ? NDMChrome.accent.withAlphaComponent(0.65)
                    : NDMChrome.hairline).cgColor
            }
            layer?.opacity = isEnabled ? 1 : 0.78
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            self.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.95, y: 0.95))
        }
        super.mouseDown(with: event)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
            ctx.allowsImplicitAnimation = true
            self.layer?.setAffineTransform(.identity)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { needsDisplay = true }
        return resigned
    }
}

@MainActor
private final class LinkLensView: NSView {
    private static var iconCache: [String: NSImage] = [:]
    private let coverView = LinkLensCoverView()
    private let siteLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var artworkTask: Task<Void, Never>?
    private var representedHost = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        coverView.translatesAutoresizingMaskIntoConstraints = false

        siteLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        siteLabel.textColor = NDMChrome.accent
        siteLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        metaLabel.font = .systemFont(ofSize: 11.5)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [siteLabel, titleLabel, metaLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(coverView)
        addSubview(labels)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            coverView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            coverView.centerYAnchor.constraint(equalTo: centerYAnchor),
            coverView.widthAnchor.constraint(equalToConstant: 126),
            coverView.heightAnchor.constraint(equalToConstant: 84),
            labels.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 14),
            labels.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            metaLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        isHidden = true
    }

    /// Do not snapshot semantic NSColors into the layer at construction time.
    /// The Settings window can switch the app between Light and Dark while
    /// this controller remains alive, so AppKit must resolve the colors again
    /// for the view's current effective appearance.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NDMChrome.hairline.cgColor
        layer?.backgroundColor = NDMChrome.searchSurface.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func clear() {
        artworkTask?.cancel()
        representedHost = ""
        spinner.stopAnimation(nil)
        isHidden = true
    }

    func showIdentity(urlString: String) {
        artworkTask?.cancel()
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            clear()
            return
        }
        representedHost = host
        isHidden = false
        let identity = Self.identity(host: host, url: url)
        siteLabel.stringValue = identity.name
        titleLabel.stringValue = identity.detail
        metaLabel.stringValue = identity.meta
        spinner.stopAnimation(nil)
        let symbol = NSImage(
            systemSymbolName: identity.fallbackSymbol,
            accessibilityDescription: identity.name
        )?.withSymbolConfiguration(.init(paletteColors: [identity.accentColor]))
        coverView.setImage(symbol, isArtwork: false, accentColor: identity.accentColor)

        if let cached = Self.iconCache[host] {
            coverView.setImage(cached, isArtwork: false, accentColor: identity.accentColor)
            return
        }

        guard let faviconURL = identity.faviconURL else { return }
        artworkTask = Task { [weak self] in
            guard let self,
                  let image = await LinkLensNetwork.image(from: faviconURL),
                  !Task.isCancelled,
                  representedHost == host else { return }
            image.isTemplate = false
            Self.iconCache[host] = image
            coverView.setImage(image, isArtwork: false, accentColor: identity.accentColor)
        }
    }

    func showLoading(urlString: String) {
        showIdentity(urlString: urlString)
        titleLabel.stringValue = L10n.linkLensRecognizing
        metaLabel.stringValue = L10n.linkLensContinueAnytime
        spinner.startAnimation(nil)
    }

    func showFallback(urlString: String) {
        showIdentity(urlString: urlString)
        metaLabel.stringValue = L10n.linkLensPreviewUnavailable
    }

    func showPreview(_ result: MediaPreflightResult) {
        showIdentity(urlString: result.resolvedURL)
        spinner.stopAnimation(nil)
        if let collection = result.collection, !collection.title.isEmpty {
            titleLabel.stringValue = collection.title
            metaLabel.stringValue = L10n.linkLensCollectionSummary(
                itemCount: collection.items.count,
                isTruncated: collection.isTruncated
            )
        } else if !result.probe.title.isEmpty {
            titleLabel.stringValue = result.probe.title
            metaLabel.stringValue = L10n.linkLensPreviewSummary(
                qualityCount: result.probe.formats.count,
                durationSeconds: result.probe.durationSeconds,
                subtitleCount: result.probe.subtitleTracks.count
            )
        }
        let thumbnail = result.collection?.thumbnailURL
            ?? result.collection?.items.first?.thumbnailURL
            ?? result.probe.thumbnailURL
        guard let raw = thumbnail, let url = URL(string: raw) else { return }
        let host = representedHost
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let self,
                  let image = await LinkLensNetwork.image(from: url),
                  !Task.isCancelled,
                  representedHost == host else { return }
            coverView.setImage(image, isArtwork: true)
        }
    }

    func showDirectFileEstimate(url: URL) {
        artworkTask?.cancel()
        representedHost = url.host?.lowercased() ?? ""
        isHidden = false
        spinner.stopAnimation(nil)
        let filename = DownloadFilename.resolve(url: url)
        siteLabel.stringValue = Self.displayHost(url)
        titleLabel.stringValue = filename
        metaLabel.stringValue = [
            Self.fileTypeDescription(filename: filename, mimeType: nil),
            L10n.t("Checking size and server support…", "正在确认大小与服务器能力…"),
        ].joined(separator: " · ")
        coverView.setImage(
            NDMChrome.fileIcon(filename: filename, pointSize: 48),
            isArtwork: false,
            accentColor: NDMChrome.accent
        )
    }

    func showDirectFileLoading(url: URL) {
        showDirectFileEstimate(url: url)
        spinner.startAnimation(nil)
    }

    func showDirectFilePreview(_ preview: RemoteFilePreview) {
        artworkTask?.cancel()
        representedHost = preview.resolvedURL.host?.lowercased() ?? ""
        isHidden = false
        spinner.stopAnimation(nil)
        siteLabel.stringValue = Self.displayHost(preview.resolvedURL)
        titleLabel.stringValue = preview.filename
        var metadata = [Self.fileTypeDescription(
            filename: preview.filename,
            mimeType: preview.mimeType
        )]
        if let bytes = preview.contentLength, bytes > 0 {
            metadata.append(Self.byteCount(bytes))
        } else {
            metadata.append(L10n.t("Size unavailable", "大小待下载时确认"))
        }
        if preview.acceptsByteRanges {
            metadata.append(L10n.t("Resumable · multi-connection ready", "支持断点续传与多连接"))
        }
        metaLabel.stringValue = metadata.joined(separator: " · ")
        coverView.setImage(
            NDMChrome.fileIcon(filename: preview.filename, pointSize: 48),
            isArtwork: false,
            accentColor: NDMChrome.accent
        )
    }

    func showDirectFileFallback(url: URL) {
        showDirectFileEstimate(url: url)
        spinner.stopAnimation(nil)
        let filename = DownloadFilename.resolve(url: url)
        metaLabel.stringValue = Self.fileTypeDescription(filename: filename, mimeType: nil)
    }

    private static func displayHost(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? L10n.unknown
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func fileTypeDescription(filename: String, mimeType: String?) -> String {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        return type?.localizedDescription
            ?? mimeType?.split(separator: ";", maxSplits: 1).first.map(String.init)
            ?? L10n.t("File", "文件")
    }

    private static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    private static func identity(
        host: String,
        url: URL
    ) -> (
        name: String,
        detail: String,
        meta: String,
        fallbackSymbol: String,
        faviconURL: URL?,
        accentColor: NSColor
    ) {
        let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let isDirectFile = !url.pathExtension.isEmpty
        let fallback = isDirectFile ? "doc.fill" : "globe"
        let mediaDetail = L10n.ytdlpRecognizedVideoLink
        let continueMeta = L10n.linkLensContinueAnytime
        switch SharedLinkResolver.source(forURLString: url.absoluteString) {
        case .youtube:
            return (
                "YouTube",
                mediaDetail,
                continueMeta,
                "play.rectangle.fill",
                URL(string: "https://www.youtube.com/favicon.ico"),
                NSColor(calibratedRed: 0.96, green: 0.12, blue: 0.16, alpha: 1)
            )
        case .bilibili:
            return (
                L10n.bilibiliName,
                mediaDetail,
                continueMeta,
                "play.tv.fill",
                URL(string: "https://www.bilibili.com/favicon.ico"),
                NSColor(calibratedRed: 0.98, green: 0.39, blue: 0.60, alpha: 1)
            )
        case .douyin:
            return (
                L10n.douyinName,
                mediaDetail,
                continueMeta,
                "music.note",
                URL(string: "https://www.douyin.com/favicon.ico"),
                NSColor(calibratedRed: 0.15, green: 0.84, blue: 0.91, alpha: 1)
            )
        case .xiaohongshu:
            return (
                L10n.xiaohongshuName,
                mediaDetail,
                continueMeta,
                "bookmark.fill",
                URL(string: "https://www.xiaohongshu.com/favicon.ico"),
                NSColor(calibratedRed: 0.96, green: 0.15, blue: 0.20, alpha: 1)
            )
        case .tiktok:
            return (
                "TikTok",
                mediaDetail,
                continueMeta,
                "music.note",
                URL(string: "https://www.tiktok.com/favicon.ico"),
                NSColor(calibratedRed: 0.08, green: 0.79, blue: 0.86, alpha: 1)
            )
        case .kuaishou:
            return (
                L10n.t("Kuaishou", "快手"), mediaDetail, continueMeta,
                "camera.aperture",
                URL(string: "https://www.kuaishou.com/favicon.ico"),
                NSColor(calibratedRed: 1.00, green: 0.43, blue: 0.12, alpha: 1)
            )
        case .weibo:
            return (
                L10n.t("Weibo", "微博"), mediaDetail, continueMeta,
                "dot.radiowaves.left.and.right",
                URL(string: "https://weibo.com/favicon.ico"),
                NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.12, alpha: 1)
            )
        case .instagram:
            return (
                "Instagram", mediaDetail, continueMeta,
                "camera.fill",
                URL(string: "https://www.instagram.com/favicon.ico"),
                NSColor(calibratedRed: 0.82, green: 0.17, blue: 0.55, alpha: 1)
            )
        case .x:
            return (
                "X", mediaDetail, continueMeta,
                "bubble.left.and.bubble.right.fill", nil,
                NSColor(calibratedWhite: 0.70, alpha: 1)
            )
        case .facebook:
            return (
                "Facebook", mediaDetail, continueMeta,
                "person.2.fill",
                URL(string: "https://www.facebook.com/favicon.ico"),
                NSColor(calibratedRed: 0.12, green: 0.40, blue: 0.88, alpha: 1)
            )
        case .vimeo:
            return (
                "Vimeo", mediaDetail, continueMeta,
                "play.circle.fill",
                URL(string: "https://vimeo.com/favicon.ico"),
                NSColor(calibratedRed: 0.15, green: 0.65, blue: 0.91, alpha: 1)
            )
        case .twitch:
            return (
                "Twitch", mediaDetail, continueMeta,
                "message.fill",
                URL(string: "https://www.twitch.tv/favicon.ico"),
                NSColor(calibratedRed: 0.56, green: 0.33, blue: 0.93, alpha: 1)
            )
        case .dailymotion:
            return (
                "Dailymotion", mediaDetail, continueMeta,
                "play.square.fill",
                URL(string: "https://www.dailymotion.com/favicon.ico"),
                NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.96, alpha: 1)
            )
        case .web:
            let favicon = URL(string: "\(url.scheme ?? "https")://\(host)/favicon.ico")
            return (
                normalized,
                isDirectFile ? L10n.directFileLink : L10n.ytdlpRecognizedPageLink,
                isDirectFile
                    ? L10n.t("Checking file details…", "正在读取文件信息…")
                    : L10n.t("Checking for downloads…", "正在查找可下载内容…"),
                fallback,
                favicon,
                NDMChrome.accent
            )
        }
    }
}

@MainActor
private final class LinkLensCoverView: NSView {
    private var image: NSImage?
    private var isArtwork = false
    private var accentColor = NDMChrome.accent

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage?, isArtwork: Bool, accentColor: NSColor? = nil) {
        self.image = image
        self.isArtwork = isArtwork
        if let accentColor { self.accentColor = accentColor }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = accentColor.withAlphaComponent(0.11)
        background.setFill()
        bounds.fill()
        guard let image else { return }

        if isArtwork {
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }
            let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let rect = NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let side = min(46, min(bounds.width, bounds.height) * 0.56)
            let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.92)
        }
    }
}

private enum LinkLensNetwork {
    static func image(from url: URL) async -> NSImage? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}

/// Shared pasteboard → URL heuristics for the banner and New Download sheet.
enum ClipboardLinks {
    static func resolution(_ raw: String) -> SharedLinkResolution? {
        SharedLinkResolver.resolve(raw)
    }

    static func firstDownloadableInput() -> String? {
        let pasteboard = NSPasteboard.general
        guard let raw = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              resolution(raw) != nil else {
            return nil
        }
        return raw
    }

    static func looksLikeDownloadURL(_ raw: String) -> Bool {
        resolution(raw) != nil
    }
}
