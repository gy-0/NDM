import AppKit
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
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let downloadButton = NSButton(title: L10n.linkLensContinue, target: nil, action: nil)
    private let viewExistingButton = NSButton(title: L10n.linkLensViewExisting, target: nil, action: nil)
    private let optionsButton = NSButton(title: L10n.linkLensOptions, target: nil, action: nil)
    private let identityView = LinkLensView()
    private var preflightTask: Task<Void, Never>?
    private var preparedResult: MediaPreflightResult?
    private var matchedTask: DownloadTask?
    private var readyChoice: ReadyChoice?
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
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 382),
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
        let clip = initialURL ?? ClipboardLinks.firstDownloadableURL()
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

        let title = NSTextField(labelWithString: L10n.newDownload)
        title.font = .systemFont(ofSize: 17, weight: .bold)

        let lede = NSTextField(wrappingLabelWithString: L10n.newDownloadLede)
        lede.font = .systemFont(ofSize: 12.5)
        lede.textColor = .secondaryLabelColor

        urlField.tag = 1001
        urlField.placeholderString = "https://"
        urlField.font = .systemFont(ofSize: 13)
        urlField.focusRingType = .none
        urlField.delegate = self
        urlField.bezelStyle = .roundedBezel
        urlField.isEditable = true
        urlField.isSelectable = true
        urlField.usesSingleLineMode = true
        urlField.lineBreakMode = .byTruncatingMiddle
        if let initialURL, !initialURL.isEmpty {
            urlField.stringValue = initialURL
            statusLabel.stringValue = L10n.clipboardURLFilled
            statusLabel.textColor = NDMChrome.accent
        } else {
            statusLabel.stringValue = L10n.clipboardURLEmpty
            statusLabel.textColor = .tertiaryLabelColor
        }
        statusLabel.font = .systemFont(ofSize: 11)

        if YtDlpTool.isAvailable {
            hintLabel.stringValue = L10n.ytdlpReadyHint
        } else {
            hintLabel.stringValue = L10n.ytdlpMissingHint
        }
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        let cancel = NSButton(title: L10n.cancel, target: self, action: #selector(cancelClicked))
        NDMChrome.styleGhostButton(cancel)
        cancel.keyEquivalent = "\u{1b}"

        downloadButton.target = self
        downloadButton.action = #selector(downloadClicked)
        NDMChrome.styleMainButton(downloadButton)
        downloadButton.keyEquivalent = "\r"
        viewExistingButton.target = self
        viewExistingButton.action = #selector(viewExistingClicked)
        NDMChrome.styleGhostButton(viewExistingButton)
        viewExistingButton.isHidden = true
        optionsButton.target = self
        optionsButton.action = #selector(optionsClicked)
        NDMChrome.styleGhostButton(optionsButton)
        optionsButton.isHidden = true
        refreshDownloadEnabled()
        refreshLinkIdentity()

        let actions = NSStackView(views: [NSView(), cancel, viewExistingButton, optionsButton, downloadButton])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.alignment = .centerY

        let stack = NSStackView(views: [title, lede, urlField, identityView, statusLabel, hintLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(14, after: lede)
        stack.setCustomSpacing(6, after: urlField)
        stack.setCustomSpacing(6, after: identityView)
        stack.setCustomSpacing(12, after: hintLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            lede.widthAnchor.constraint(equalTo: stack.widthAnchor),
            urlField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            urlField.heightAnchor.constraint(equalToConstant: 30),
            identityView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            identityView.heightAnchor.constraint(equalToConstant: 104),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancel.heightAnchor.constraint(equalToConstant: 28),
            viewExistingButton.heightAnchor.constraint(equalToConstant: 28),
            optionsButton.heightAnchor.constraint(equalToConstant: 28),
            downloadButton.heightAnchor.constraint(equalToConstant: 28),
            downloadButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
        ])
    }

    private func refreshDownloadEnabled() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        downloadButton.isEnabled = ClipboardLinks.resolution(raw) != nil
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshDownloadEnabled()
        refreshLinkIdentity()
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolution = ClipboardLinks.resolution(raw)
        if let matchedTask {
            showDuplicateStatus(matchedTask)
        } else if let resolution {
            statusLabel.stringValue = resolution.wasExtractedFromText
                ? L10n.shareTextLinkFound
                : L10n.urlReadyToDownload
            statusLabel.textColor = NDMChrome.accent
        } else {
            statusLabel.stringValue = L10n.clipboardURLEdited
            statusLabel.textColor = .tertiaryLabelColor
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
            return
        }
        let urlString = resolution.urlString
        refreshDuplicate(urlStrings: [urlString])
        identityView.showIdentity(urlString: urlString)
        guard YtDlpTool.isAvailable,
              MediaLinkClassifier.looksLikeMediaPage(urlString) else { return }

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
        let budget = StorageBudget.media(
            sampleFinalBytes: format.approximateBytes,
            sampleComponentBytes: format.componentBytes,
            sampleDurationSeconds: result.probe.durationSeconds
        )
        let confidence = StorageConfidence(
            budget: budget,
            availableBytes: VolumeCapacity.availableBytes(at: destinationDirectory)
        )
        // Tight and unknown states still deserve the full Space Confidence row.
        guard confidence.level == .comfortable else { return nil }

        let container: YtDlpContainerPreference = resolution.container == .compactMKV
            ? .compactMKV
            : .compatibleMP4
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
            statusLabel.stringValue = L10n.linkLensExistingComplete(filename)
        case .downloading, .waiting:
            statusLabel.stringValue = L10n.linkLensExistingActive(filename)
        case .paused, .incomplete, .error:
            statusLabel.stringValue = L10n.linkLensExistingTask(filename)
        }
        statusLabel.textColor = NDMChrome.accent
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
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        metaLabel.font = .systemFont(ofSize: 11)
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
            coverView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            coverView.centerYAnchor.constraint(equalTo: centerYAnchor),
            coverView.widthAnchor.constraint(equalToConstant: 112),
            coverView.heightAnchor.constraint(equalToConstant: 76),
            labels.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 13),
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
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NDMChrome.hairline.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.72)
            .cgColor
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
        coverView.setImage(NSImage(
            systemSymbolName: identity.fallbackSymbol,
            accessibilityDescription: identity.name
        ), isArtwork: false)

        if let cached = Self.iconCache[host] {
            coverView.setImage(cached, isArtwork: false)
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
            coverView.setImage(image, isArtwork: false)
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

    private static func identity(
        host: String,
        url: URL
    ) -> (name: String, detail: String, meta: String, fallbackSymbol: String, faviconURL: URL?) {
        let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let isDirectFile = !url.pathExtension.isEmpty
        let fallback = isDirectFile ? "doc.fill" : "play.rectangle.fill"
        if normalized == "youtu.be" || normalized.hasSuffix("youtube.com") {
            return (
                "YouTube",
                L10n.ytdlpRecognizedVideoLink,
                L10n.linkLensContinueAnytime,
                "play.rectangle.fill",
                URL(string: "https://www.youtube.com/favicon.ico")
            )
        }
        if normalized == "b23.tv" || normalized.hasSuffix("bilibili.com") {
            return (
                L10n.bilibiliName,
                L10n.ytdlpRecognizedVideoLink,
                L10n.linkLensContinueAnytime,
                "play.rectangle.fill",
                URL(string: "https://www.bilibili.com/favicon.ico")
            )
        }
        if normalized.hasSuffix("douyin.com") || normalized.hasSuffix("iesdouyin.com") {
            return (
                L10n.douyinName,
                L10n.ytdlpRecognizedVideoLink,
                L10n.linkLensContinueAnytime,
                "play.rectangle.fill",
                URL(string: "https://www.douyin.com/favicon.ico")
            )
        }
        if normalized == "xhslink.com" || normalized.hasSuffix("xiaohongshu.com") {
            return (
                L10n.xiaohongshuName,
                L10n.ytdlpRecognizedVideoLink,
                L10n.linkLensContinueAnytime,
                "play.rectangle.fill",
                URL(string: "https://www.xiaohongshu.com/favicon.ico")
            )
        }
        if normalized.hasSuffix("tiktok.com") {
            return (
                "TikTok",
                L10n.ytdlpRecognizedVideoLink,
                L10n.linkLensContinueAnytime,
                "play.rectangle.fill",
                URL(string: "https://www.tiktok.com/favicon.ico")
            )
        }
        let favicon = URL(string: "\(url.scheme ?? "https")://\(host)/favicon.ico")
        return (
            normalized,
            isDirectFile ? L10n.directFileLink : L10n.ytdlpRecognizedPageLink,
            isDirectFile ? L10n.urlReadyToDownload : L10n.linkLensContinueAnytime,
            fallback,
            favicon
        )
    }
}

@MainActor
private final class LinkLensCoverView: NSView {
    private var image: NSImage?
    private var isArtwork = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage?, isArtwork: Bool) {
        self.image = image
        self.isArtwork = isArtwork
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NDMChrome.accent.withAlphaComponent(0.09)
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
            let side = min(38, min(bounds.width, bounds.height) * 0.52)
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

    static func firstDownloadableURL() -> String? {
        let pasteboard = NSPasteboard.general
        guard let raw = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let resolution = resolution(raw) else {
            return nil
        }
        return resolution.urlString
    }

    static func looksLikeDownloadURL(_ raw: String) -> Bool {
        resolution(raw) != nil
    }
}
