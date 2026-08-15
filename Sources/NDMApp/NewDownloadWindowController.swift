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
        let destinationDirectoryOverride: URL?
    }

    enum Result {
        case download(Submission)
        case showExisting(Int64)
        case cancel
    }

    private var onFinish: ((Result) -> Void)?
    private let existingTasks: [DownloadTask]
    private let defaultDestinationDirectory: URL
    private var destinationDirectoryOverride: URL?
    private let urlField = NSTextField(string: "")
    private let urlShell = LinkInputShell()
    private let inputIcon = AmicroIconSwapView()
    private let clearButton = NSButton()
    private let statusIcon = NSImageView()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusRow = NSStackView()
    private let hintRow = NSStackView()
    private let downloadButton = NewDownloadActionButton(title: L10n.linkLensContinue, style: .primary)
    private let viewExistingButton = NewDownloadActionButton(title: L10n.linkLensViewExisting, style: .secondary)
    private let optionsButton = NewDownloadActionButton(title: L10n.linkLensOptions, style: .secondary)
    private let destinationButton = NewDownloadActionButton(title: "", style: .secondary)
    private let identityView = LinkLensView()
    private var preflightTask: Task<Void, Never>?
    private var preparedResult: MediaPreflightResult?
    private var matchedTask: DownloadTask?
    private var readyChoice: ReadyChoice?
    private var didNormalizeShareInput = false
    private var hasVisiblePreview = false
    private var layoutReady = false
    private var didFinish = false

    private static var active: NewDownloadWindowController?

    private let mediaQuality: MediaQualityPreference

    init(
        initialURL: String?,
        existingTasks: [DownloadTask],
        destinationDirectory: URL,
        mediaQuality: MediaQualityPreference = .highest,
        onFinish: @escaping (Result) -> Void
    ) {
        self.onFinish = onFinish
        self.existingTasks = existingTasks
        self.defaultDestinationDirectory = destinationDirectory
        self.mediaQuality = mediaQuality
        let hasInitialPreview = initialURL.flatMap(ClipboardLinks.resolution) != nil
        let initialHeight = hasInitialPreview
            ? NewDownloadSheetLayout.contentHeight(
                hasPreview: true,
                showsStatus: true,
                showsHint: false
            )
            : NewDownloadSheetLayout.compactHeight
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: CGFloat(initialHeight)),
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
        mediaQuality: MediaQualityPreference = .highest,
        initialURL: String? = nil
    ) async -> Result {
        let clip = initialURL ?? ClipboardLinks.firstDownloadableInput()
        return await withCheckedContinuation { continuation in
            let wc = NewDownloadWindowController(
                initialURL: clip,
                existingTasks: existingTasks,
                destinationDirectory: destinationDirectory,
                mediaQuality: mediaQuality
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
                if QAPreviewOverrides.showNewDownloadDestinationPicker {
                    // Let the parent sheet finish attaching before asking
                    // AppKit to present the folder chooser above it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        wc.chooseDestinationClicked()
                    }
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
        urlField.placeholderString = L10n.newDownloadInputPlaceholder
        urlField.font = .systemFont(ofSize: 13.5, weight: .medium)
        urlField.focusRingType = .none
        urlField.delegate = self
        urlField.isBordered = false
        urlField.drawsBackground = false
        urlField.isEditable = true
        urlField.isSelectable = true
        urlField.usesSingleLineMode = true
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.setAccessibilityLabel(L10n.newDownloadInputAccessibilityLabel)
        urlField.setAccessibilityHelp(L10n.pasteURLHint)
        urlField.translatesAutoresizingMaskIntoConstraints = false

        inputIcon.tintColor = .secondaryLabelColor
        inputIcon.setSymbol("link", pointSize: 13, weight: .semibold, animated: false)
        inputIcon.translatesAutoresizingMaskIntoConstraints = false

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
        urlShell.addSubview(inputIcon)
        urlShell.addSubview(urlField)
        urlShell.addSubview(clearButton)
        NSLayoutConstraint.activate([
            inputIcon.leadingAnchor.constraint(equalTo: urlShell.leadingAnchor, constant: 14),
            inputIcon.centerYAnchor.constraint(equalTo: urlShell.centerYAnchor),
            inputIcon.widthAnchor.constraint(equalToConstant: 16),
            inputIcon.heightAnchor.constraint(equalToConstant: 16),
            urlField.leadingAnchor.constraint(equalTo: inputIcon.trailingAnchor, constant: 9),
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

        destinationButton.image = NDMChrome.symbol("folder.fill", pointSize: 11.5, weight: .medium)
        destinationButton.imagePosition = .imageLeading
        destinationButton.imageHugsTitle = true
        destinationButton.target = self
        destinationButton.action = #selector(chooseDestinationClicked)
        destinationButton.setAccessibilityHelp(L10n.changeDownloadDestination)
        destinationButton.lineBreakMode = .byTruncatingMiddle
        destinationButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshDestinationButton()

        let actions = NSStackView(views: [destinationButton, NSView(), cancel, viewExistingButton, optionsButton, downloadButton])
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
            destinationButton.heightAnchor.constraint(equalToConstant: 36),
            destinationButton.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            cancel.heightAnchor.constraint(equalToConstant: 36),
            viewExistingButton.heightAnchor.constraint(equalToConstant: 36),
            optionsButton.heightAnchor.constraint(equalToConstant: 36),
            downloadButton.heightAnchor.constraint(equalToConstant: 36),
            downloadButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
        ])
        layoutReady = true
        refreshLinkIdentity()
    }

    private func refreshDownloadEnabled() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolution = ClipboardLinks.resolution(raw)
        downloadButton.isEnabled = resolution != nil
        refreshPrimaryAction(for: resolution?.urlString)
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

    private func setInputRecognized(_ recognized: Bool) {
        inputIcon.tintColor = recognized ? NDMChrome.accent : .secondaryLabelColor
        inputIcon.setSymbol(
            recognized ? "checkmark.circle.fill" : "link",
            pointSize: 13,
            weight: .semibold,
            animated: window?.isVisible == true
        )
    }

    private func setStatus(_ text: String, symbolName: String, color: NSColor) {
        statusRow.isHidden = false
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusIcon.image = NDMChrome.symbol(symbolName, pointSize: 11.5, weight: .semibold)
        statusIcon.contentTintColor = color
        updateSheetHeight()
    }

    private func hideStatus() {
        statusRow.isHidden = true
        updateSheetHeight()
    }

    private func setHint(_ text: String?) {
        hintLabel.stringValue = text ?? ""
        hintRow.isHidden = text == nil
        updateSheetHeight()
    }

    private func setPreviewVisible(_ visible: Bool) {
        hasVisiblePreview = visible
        updateSheetHeight()
    }

    private func updateSheetHeight() {
        guard layoutReady, let window else { return }
        let targetHeight = CGFloat(NewDownloadSheetLayout.contentHeight(
            hasPreview: hasVisiblePreview,
            showsStatus: !statusRow.isHidden,
            showsHint: !hintRow.isHidden
        ))
        guard abs(window.contentLayoutRect.height - targetHeight) > 1 else { return }

        let targetSize = NSSize(width: 610, height: targetHeight)
        guard window.isVisible else {
            window.setContentSize(targetSize)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            window.animator().setContentSize(targetSize)
        }
    }

    private func refreshLinkIdentity() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        preflightTask?.cancel()
        preparedResult = nil
        readyChoice = nil
        guard let resolution = ClipboardLinks.resolution(raw) else {
            setInputRecognized(false)
            refreshDuplicate(urlStrings: [])
            identityView.clear()
            hideStatus()
            setHint(nil)
            setPreviewVisible(false)
            return
        }
        setInputRecognized(true)
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
            readyChoice: matchedTask == nil ? readyChoice : nil,
            destinationDirectoryOverride: destinationDirectoryOverride
        )))
    }

    @objc private func optionsClicked() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolution = ClipboardLinks.resolution(raw) else { return }
        finish(.download(Submission(
            urlString: resolution.urlString,
            preflight: preparedResult,
            readyChoice: nil,
            destinationDirectoryOverride: destinationDirectoryOverride
        )))
    }

    @objc private func chooseDestinationClicked() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.chooseDownloadFolder
        panel.message = L10n.changeDownloadDestination
        panel.prompt = L10n.t("Choose", "选择")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = effectiveDestinationDirectory
        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.destinationDirectoryOverride = folder.standardizedFileURL
            self?.refreshDestinationButton()
        }
        // A second sheet is queued behind New Download instead of appearing.
        // The standard modal folder panel runs its own AppKit event loop, stays
        // interactive above either presentation mode, and returns straight to
        // the intact link preview when dismissed.
        let panelFrame = panel.frame
        let centeredOrigin = NSPoint(
            x: window.frame.midX - panelFrame.width / 2,
            y: window.frame.midY - panelFrame.height / 2
        )
        // `runModal()` initially recenters on the primary display. Move the
        // panel once its modal event loop has created the visible window so it
        // stays with New Download on multi-display setups.
        DispatchQueue.main.async {
            panel.setFrameOrigin(centeredOrigin)
        }
        let response = panel.runModal()
        handleResponse(response)
    }

    private var effectiveDestinationDirectory: URL {
        destinationDirectoryOverride ?? defaultDestinationDirectory
    }

    private func refreshDestinationButton() {
        let folder = effectiveDestinationDirectory
        let shownName = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
        destinationButton.title = L10n.downloadDestination(shownName)
        destinationButton.toolTip = "\(L10n.changeDownloadDestination)\n\(folder.path)"
        destinationButton.setAccessibilityLabel(L10n.downloadDestination(shownName))
        destinationButton.invalidateIntrinsicContentSize()
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
        let currentURL = ClipboardLinks.resolution(
            urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )?.urlString
        refreshPrimaryAction(for: currentURL)
        if let matchedTask {
            showDuplicateStatus(matchedTask)
        }
    }

    private func refreshPrimaryAction(for urlString: String?) {
        let requiresQualityChoice = urlString.map {
            MediaLinkClassifier.looksLikeMediaPage($0)
                || $0.lowercased().contains(".m3u8")
        } ?? false
        let action = NewDownloadPrimaryActionPolicy.action(
            hasDownloadableLink: urlString != nil,
            requiresQualityChoice: requiresQualityChoice,
            hasDuplicate: matchedTask != nil,
            preparedQuality: readyChoice?.format.label,
            preparedContainer: readyChoice?.containerLabel
        )
        switch action {
        case .unavailable:
            // Keep the eventual action visible while disabled so the empty
            // state still teaches users what this sheet does.
            downloadButton.title = L10n.linkLensDownloadFile
            downloadButton.toolTip = nil
        case .downloadFile:
            downloadButton.title = L10n.linkLensDownloadFile
            downloadButton.toolTip = nil
        case .chooseQuality:
            downloadButton.title = L10n.linkLensOptions
            downloadButton.toolTip = nil
        case .downloadPrepared(let quality, let container):
            downloadButton.title = L10n.linkLensDownloadReadyChoice(
                quality,
                container: container
            )
            downloadButton.toolTip = L10n.linkLensReadyChoiceTooltip
        case .downloadAgain:
            downloadButton.title = L10n.linkLensDownloadAgain
            downloadButton.toolTip = nil
        }
        downloadButton.setAccessibilityLabel(downloadButton.title)
        downloadButton.invalidateIntrinsicContentSize()
    }

    private func makeReadyChoice(for result: MediaPreflightResult) -> ReadyChoice? {
        // Honor the global quality preference (Ask / Highest / up-to-cap). This
        // replaces the old "remember the last exact per-site pick" behavior,
        // which made a one-off 240p test stick as the permanent default.
        guard result.collection == nil,
              let index = mediaQuality.autoSelectIndex(
                  heights: result.probe.formats.map(\.height)
              ),
              result.probe.formats.indices.contains(index) else {
            return nil
        }
        let format = result.probe.formats[index]
        let container: YtDlpContainerPreference = .compatibleMP4
        let budget = StorageBudget.media(
            sampleFinalBytes: format.estimatedBytes(for: container),
            sampleComponentBytes: format.estimatedComponentBytes(for: container),
            sampleDurationSeconds: result.probe.durationSeconds
        )
        let confidence = StorageConfidence(
            budget: budget,
            availableBytes: VolumeCapacity.availableBytes(at: effectiveDestinationDirectory)
        )
        // Tight and unknown states still deserve the full Space Confidence row.
        guard confidence.level == .comfortable else { return nil }

        return ReadyChoice(
            format: format,
            options: YtDlpDownloadOptions(
                container: container,
                subtitleLanguage: nil
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
    private let pointerGlow = CAGradientLayer()
    private var magneticOffset = CGPoint.zero

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
        layer?.cornerRadius = NDMChrome.controlCornerRadius
        layer?.masksToBounds = true
        // Amicro `glow-button`: a radial accent highlight follows the pointer.
        pointerGlow.type = .radial
        pointerGlow.locations = [0, 1]
        pointerGlow.opacity = 0
        layer?.addSublayer(pointerGlow)
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
            pointerGlow.frame = bounds
            let glow = actionStyle == .primary
                ? NSColor.white.withAlphaComponent(0.24)
                : NDMChrome.accent.withAlphaComponent(0.18)
            pointerGlow.colors = [glow.cgColor, NSColor.clear.cgColor]
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        setMagneticTransform(scale: 0.95, spring: false)
        super.mouseDown(with: event)
        setMagneticTransform(scale: 1, spring: true)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        pointerGlow.opacity = 1
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let normalized = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        pointerGlow.startPoint = normalized
        pointerGlow.endPoint = CGPoint(x: normalized.x + 0.68, y: normalized.y + 0.68)

        // Amicro `magnetic-button`: source spring 150/15/0.6. The native
        // version uses an 18% pull so the hit target never visually escapes.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        magneticOffset = CGPoint(
            x: (point.x - bounds.midX) * 0.18,
            y: (point.y - bounds.midY) * 0.18
        )
        setMagneticTransform(scale: 1, spring: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        pointerGlow.opacity = 0
        magneticOffset = .zero
        setMagneticTransform(scale: 1, spring: true)
        needsDisplay = true
    }

    private func setMagneticTransform(scale: CGFloat, spring: Bool) {
        guard let layer else { return }
        let target = CATransform3DConcat(
            CATransform3DMakeTranslation(magneticOffset.x, magneticOffset.y, 0),
            CATransform3DMakeScale(scale, scale, 1)
        )
        let source = layer.presentation()?.transform ?? layer.transform
        layer.transform = target
        if spring, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CASpringAnimation(keyPath: "transform")
            animation.mass = 0.6
            animation.stiffness = 150
            animation.damping = 15
            animation.fromValue = NSValue(caTransform3D: source)
            animation.toValue = NSValue(caTransform3D: target)
            animation.duration = animation.settlingDuration
            layer.add(animation, forKey: "amicroMagnetic")
        }
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
    private let brandMarkView = NSImageView()
    private var brandMarkWidthConstraint: NSLayoutConstraint?
    private let siteLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var artworkTask: Task<Void, Never>?
    private var representedHost = ""
    private var representedSource: SharedLinkResolution.Source = .web

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        coverView.translatesAutoresizingMaskIntoConstraints = false

        brandMarkView.imageScaling = .scaleProportionallyUpOrDown
        brandMarkView.imageAlignment = .alignLeft
        brandMarkView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        brandMarkView.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)

        siteLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        siteLabel.textColor = .labelColor
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

        let labels = NSStackView(views: [brandMarkView, siteLabel, titleLabel, metaLabel])
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
            brandMarkView.heightAnchor.constraint(equalToConstant: 18),
            brandMarkView.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
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
        representedSource = .web
        brandMarkView.image = nil
        brandMarkView.isHidden = true
        siteLabel.isHidden = false
        spinner.stopAnimation(nil)
        isHidden = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBrandMark()
    }

    func showIdentity(urlString: String) {
        artworkTask?.cancel()
        coverView.stopShimmer()
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            clear()
            return
        }
        representedHost = host
        isHidden = false
        let identity = Self.identity(host: host, url: url)
        representedSource = identity.source
        applyBrandMark(name: identity.name, source: identity.source)
        titleLabel.stringValue = identity.detail
        metaLabel.stringValue = identity.meta
        spinner.stopAnimation(nil)

        if let brandIcon = SiteBrandKit.image(
            for: identity.source,
            presentation: .compactIcon,
            appearance: effectiveAppearance
        ) {
            coverView.setImage(brandIcon, isArtwork: false, accentColor: identity.accentColor)
            return
        }

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

    private func applyBrandMark(name: String, source: SharedLinkResolution.Source) {
        if let wordmark = SiteBrandKit.image(
            for: source,
            presentation: .wordmark,
            appearance: effectiveAppearance
        ) {
            let height: CGFloat = 18
            let aspect = wordmark.size.width / max(wordmark.size.height, 1)
            brandMarkView.image = wordmark
            brandMarkView.isHidden = false
            siteLabel.isHidden = true
            siteLabel.stringValue = name
            brandMarkView.toolTip = name
            let width = min(max(24, height * aspect), 160)
            if let existing = brandMarkWidthConstraint {
                existing.constant = width
            } else {
                let constraint = brandMarkView.widthAnchor.constraint(equalToConstant: width)
                constraint.isActive = true
                brandMarkWidthConstraint = constraint
            }
        } else {
            brandMarkView.image = nil
            brandMarkView.isHidden = true
            siteLabel.isHidden = false
            siteLabel.stringValue = name
            siteLabel.textColor = source == .web
                ? .secondaryLabelColor
                : SiteBrandKit.accentColor(for: source)
        }
    }

    private func refreshBrandMark() {
        guard !isHidden, !representedHost.isEmpty else { return }
        applyBrandMark(
            name: {
                let branded = SiteBrandKit.displayName(for: representedSource)
                return branded.isEmpty ? siteLabel.stringValue : branded
            }(),
            source: representedSource
        )
        if coverView.showsBrandPlaceholder,
           let brandIcon = SiteBrandKit.image(
            for: representedSource,
            presentation: .compactIcon,
            appearance: effectiveAppearance
           ) {
            coverView.setImage(
                brandIcon,
                isArtwork: false,
                accentColor: SiteBrandKit.accentColor(for: representedSource)
            )
        }
    }

    func showLoading(urlString: String) {
        showIdentity(urlString: urlString)
        titleLabel.stringValue = L10n.linkLensRecognizing
        metaLabel.stringValue = L10n.linkLensContinueAnytime
        coverView.startShimmer()
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
        representedSource = .web
        isHidden = false
        spinner.stopAnimation(nil)
        let filename = DownloadFilename.resolve(url: url)
        applyBrandMark(name: Self.displayHost(url), source: .web)
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
        coverView.startShimmer()
        spinner.startAnimation(nil)
    }

    func showDirectFilePreview(_ preview: RemoteFilePreview) {
        artworkTask?.cancel()
        coverView.stopShimmer()
        representedHost = preview.resolvedURL.host?.lowercased() ?? ""
        representedSource = .web
        isHidden = false
        spinner.stopAnimation(nil)
        applyBrandMark(name: Self.displayHost(preview.resolvedURL), source: .web)
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
        source: SharedLinkResolution.Source,
        name: String,
        detail: String,
        meta: String,
        fallbackSymbol: String,
        faviconURL: URL?,
        accentColor: NSColor
    ) {
        let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let isDirectFile = !url.pathExtension.isEmpty
        let source = SharedLinkResolver.source(forURLString: url.absoluteString)
        let mediaDetail = L10n.ytdlpRecognizedVideoLink
        let continueMeta = L10n.linkLensContinueAnytime
        let accent = SiteBrandKit.accentColor(for: source)
        let symbol = SiteBrandKit.fallbackSymbolName(for: source, isDirectFile: isDirectFile)

        switch source {
        case .web:
            let favicon = URL(string: "\(url.scheme ?? "https")://\(host)/favicon.ico")
            return (
                .web,
                normalized,
                isDirectFile ? L10n.directFileLink : L10n.ytdlpRecognizedPageLink,
                isDirectFile
                    ? L10n.t("Checking file details…", "正在读取文件信息…")
                    : L10n.t("Checking for downloads…", "正在查找可下载内容…"),
                symbol,
                favicon,
                accent
            )
        default:
            return (
                source,
                SiteBrandKit.displayName(for: source),
                mediaDetail,
                continueMeta,
                symbol,
                nil,
                accent
            )
        }
    }
}

@MainActor
private final class LinkLensCoverView: NSView {
    private var image: NSImage?
    private var isArtwork = false
    private var accentColor = NDMChrome.accent
    private let shimmer = CAGradientLayer()

    /// True while the cover is showing a site brand glyph (not video artwork).
    var showsBrandPlaceholder: Bool { image != nil && !isArtwork }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
        shimmer.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.20).cgColor,
            NSColor.clear.cgColor,
        ]
        shimmer.locations = [0, 0.5, 1]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.opacity = 0
        layer?.addSublayer(shimmer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage?, isArtwork: Bool, accentColor: NSColor? = nil) {
        self.image = image
        self.isArtwork = isArtwork
        if let accentColor { self.accentColor = accentColor }
        if isArtwork { stopShimmer() }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        shimmer.frame = CGRect(
            x: -bounds.width * 0.8,
            y: 0,
            width: bounds.width * 0.8,
            height: bounds.height
        )
    }

    /// Amicro `skeleton`: -150% → 150%, 1.6 s ease-in-out.
    func startShimmer() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        shimmer.opacity = 1
        if shimmer.animation(forKey: "amicroSkeleton") != nil { return }
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -bounds.width * 0.7
        sweep.toValue = bounds.width * 2.7
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmer.add(sweep, forKey: "amicroSkeleton")
    }

    func stopShimmer() {
        shimmer.opacity = 0
        shimmer.removeAnimation(forKey: "amicroSkeleton")
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = accentColor.withAlphaComponent(0.11)
        background.setFill()
        bounds.fill()
        guard let image else { return }

        NSGraphicsContext.current?.imageInterpolation = .high
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
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }
            let maxSide = min(52, min(bounds.width, bounds.height) * 0.62)
            let aspect = imageSize.width / imageSize.height
            let size: NSSize
            if aspect >= 1 {
                size = NSSize(width: maxSide, height: maxSide / aspect)
            } else {
                size = NSSize(width: maxSide * aspect, height: maxSide)
            }
            let rect = NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
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
