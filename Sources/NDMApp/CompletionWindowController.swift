import AppKit
import AVFoundation
import NDMCore
import NDMEngine

/// Non-modal completion panel — shown standalone or used as the destination
/// of the progress window's shared-element handoff.
///
/// Cinema layout: a full-bleed dark hero carries the finished file's own
/// artwork with the "Download Complete" headline and an accent underline laid
/// over it; a clean light deck below holds the file identity, the optional
/// sidecar disclosure, and one confident action row.
@MainActor
final class CompletionWindowController: NSWindowController, NSWindowDelegate {
    private let task: DownloadTask
    private let onDismiss: () -> Void
    private let completionStack: CompletionStack?
    private var collapsedWindowHeight: CGFloat = 300
    private let completionStackView = CompletionStackView()
    private let audioExtraction = AudioExtractionCoordinator()
    private let audioStatusView = AudioExtractionStatusView()
    private let fileSharePresenter = FileSharePresenter()
    private var completionExpansionAddedHeight: CGFloat = 0
    private weak var metaLabel: NSTextField?
    private weak var deckStack: NSStackView?
    private var hero: CompletionCinemaHero?
    private weak var openButton: InspectorActionButton?
    private weak var revealButton: InspectorActionButton?
    private weak var shareButton: InspectorActionButton?
    private weak var moreButton: InspectorActionButton?
    private weak var noticeLabel: NSTextField?
    private var hasCelebrated = false
    private var handoffPrepared = false
    /// Resolved asynchronously and folded into the meta line; kept so the line
    /// can be rebuilt in place on a language switch without losing the runtime.
    private var durationText: String?
    private var languageObserver: NSObjectProtocol?
    private var coverObserver: NSObjectProtocol?

    /// The hero holds a fixed cinematic band; only the deck below it grows.
    private let heroHeight: CGFloat = 208

    init(task: DownloadTask, onDismiss: @escaping () -> Void = {}) {
        self.task = task
        self.onDismiss = onDismiss
        self.completionStack = SmartFinalize.completionStack(primary: task.destinationFileURL)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 452, height: collapsedWindowHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.downloadComplete
        NDMChrome.applyWindowChrome(window)
        // The hero runs edge to edge under a transparent titlebar; a custom
        // close puck in the hero replaces the traffic lights.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        completionStackView.onExpansionChanged = { [weak self] expanded in
            self?.resizeForCompletionStack(expanded: expanded)
        }
        buildUI()
        audioExtraction.onStateChange = { [weak self] state in
            self?.audioStatusView.apply(state)
            self?.resizeToFitContent(animate: true)
        }
        audioExtraction.apply(sourceURL: task.destinationFileURL)
        resizeToFitContent(animate: false)
        window.center()
        window.delegate = self
        // Relocalize this panel in place when the language switches live.
        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocalize() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !handoffPrepared, !hasCelebrated else { return }
        hasCelebrated = true
        // Let the window finish its first layout (and any progress-window
        // crossfade begin) before the single completion flourish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            self?.hero?.celebrateCompletion()
        }
    }

    /// Stage the result card before the progress card morphs into it. The hero
    /// is available immediately, while the file details and actions wait until
    /// the shared preview has landed.
    func prepareForAnimatedHandoff(_ preview: CompletionHandoffPreview?) {
        handoffPrepared = true
        deckStack?.alphaValue = 0
        if let preview, preview.isArtwork {
            hero?.showThumbnail(preview.image)
            // Handoff artwork is already CoverArtCache's poster; drop the
            // async ensureCover observer so a late local-frame fallback cannot
            // replace it.
            clearCoverObserver()
        }
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// Destination for the shared visual in screen coordinates.
    func handoffDestinationRect(isArtwork: Bool) -> NSRect? {
        guard let window, let content = window.contentView, let hero else { return nil }
        content.layoutSubtreeIfNeeded()
        let rectInContent = hero.handoffDestinationRect(in: content, isArtwork: isArtwork)
        let rectInWindow = content.convert(rectInContent, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    /// Finish the state change only after the shared preview has arrived.
    func finishAnimatedHandoff() {
        handoffPrepared = false
        guard !hasCelebrated else { return }
        hasCelebrated = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            deckStack?.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                deckStack?.animator().alphaValue = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.hero?.celebrateCompletion()
        }
    }

    private func resizeForCompletionStack(expanded: Bool) {
        guard let window else { return }
        var frame = window.frame
        let oldTop = frame.maxY
        if expanded {
            let requested = completionStackView.expansionHeight
            let visibleFrame = window.screen?.visibleFrame
                ?? NSRect(x: frame.minX, y: 0, width: frame.width, height: frame.maxY)
            let availableBelowTop = max(0, oldTop - visibleFrame.minY - 24)
            let added = min(requested, max(0, availableBelowTop - frame.height))
            completionExpansionAddedHeight = added
            frame.size.height += added
        } else {
            frame.size.height = max(collapsedWindowHeight, frame.height - completionExpansionAddedHeight)
            completionExpansionAddedHeight = 0
        }
        frame.origin.y = oldTop - frame.height
        window.setFrame(
            frame,
            display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    /// Successful finishing work stays silent. Only surface a result when the
    /// user received something other than the usual ready-to-use file.
    private func deliveryNotice() -> String? {
        let ext = (task.filename as NSString).pathExtension.lowercased()
        switch task.linkType.lowercased() {
        case "hls", "m3u8":
            return ext == "mp4" ? nil : L10n.finalizeKeptTS
        case "mkv", "mkva", "mkvv":
            return ext == "mp4" ? nil : L10n.finalizeAudioSidecar
        default:
            return nil
        }
    }

    private func makeDeliveryNotice(_ text: String) -> NSView {
        let icon = NSImageView()
        icon.image = NDMChrome.symbol("info.circle", pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        noticeLabel = label
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 7
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
        ])
        return row
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let isMedia = task.category == .video || task.category == .audio
        let notice = deliveryNotice()

        // MARK: Hero band — dark, edge to edge, thumbnail as backdrop.
        let hero = CompletionCinemaHero(
            title: L10n.downloadComplete,
            filename: task.filename
        )
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.onClose = { [weak self] in self?.closeClicked() }
        self.hero = hero
        loadThumbnail(into: hero)

        // MARK: File identity card.
        let tile = FileGlyphTile(filename: task.filename)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 46),
            tile.heightAnchor.constraint(equalToConstant: 46),
        ])

        let name = NSTextField(labelWithString: task.filename.isEmpty ? L10n.download : task.filename)
        name.font = .systemFont(ofSize: 14.5, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.toolTip = task.filename
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let meta = NSTextField(labelWithString: "")
        meta.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        metaLabel = meta
        updateMetaLabel()
        loadMediaDuration()

        let caption = NSStackView(views: [name, meta])
        caption.orientation = .vertical
        caption.alignment = .leading
        caption.spacing = 3
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fileCard = NSStackView(views: [tile, caption])
        fileCard.orientation = .horizontal
        fileCard.alignment = .centerY
        fileCard.spacing = 13

        // MARK: Action row.
        let open = InspectorActionButton(title: isMedia ? L10n.play : L10n.open, style: .filled)
        open.target = self
        open.action = #selector(openClicked)
        open.keyEquivalent = "\r"
        open.image = NDMChrome.symbol(isMedia ? "play.fill" : "arrow.up.forward.app.fill", pointSize: 12, weight: .semibold)
        open.imagePosition = .imageLeading
        open.imageHugsTitle = true
        open.font = .systemFont(ofSize: 13.5, weight: .semibold)

        let reveal = outlinedButton(title: L10n.showInFinder)
        reveal.target = self
        reveal.action = #selector(revealClicked)
        reveal.image = NDMChrome.symbol("folder", pointSize: 12, weight: .medium)
        reveal.imagePosition = .imageLeading
        reveal.imageHugsTitle = true
        reveal.font = .systemFont(ofSize: 13, weight: .medium)
        reveal.contentTintColor = .labelColor

        let share = outlinedButton(title: "")
        share.target = self
        share.action = #selector(shareClicked)
        share.image = NDMChrome.symbol("square.and.arrow.up", pointSize: 14, weight: .medium)
        share.imagePosition = .imageOnly
        share.contentTintColor = .secondaryLabelColor
        share.usesExactAlignmentRect = true
        share.setAccessibilityLabel(L10n.share)

        let more = outlinedButton(title: "")
        more.target = self
        more.action = #selector(showMoreActions(_:))
        more.image = NDMChrome.symbol("ellipsis", pointSize: 14, weight: .semibold)
        more.imagePosition = .imageOnly
        more.contentTintColor = .secondaryLabelColor
        more.usesExactAlignmentRect = true
        more.setAccessibilityLabel(L10n.moreActions)
        more.isHidden = !SmartFinalize.supportsDeliveryRecipes(input: task.destinationFileURL)

        let fileExists = task.destinationFileURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        open.isEnabled = fileExists
        reveal.isEnabled = fileExists
        share.isEnabled = fileExists
        more.isEnabled = fileExists
        openButton = open
        revealButton = reveal
        shareButton = share
        moreButton = more

        let actions = NSStackView(views: [open, reveal, NSView(), share, more])
        actions.orientation = .horizontal
        actions.spacing = 9
        actions.alignment = .centerY
        NSLayoutConstraint.activate([
            open.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            reveal.widthAnchor.constraint(greaterThanOrEqualToConstant: 128),
            share.widthAnchor.constraint(equalToConstant: 42),
            more.widthAnchor.constraint(equalToConstant: 42),
            open.heightAnchor.constraint(equalToConstant: 38),
            reveal.heightAnchor.constraint(equalToConstant: 38),
            share.heightAnchor.constraint(equalToConstant: 38),
            more.heightAnchor.constraint(equalToConstant: 38),
        ])

        // MARK: Deck assembly (everything under the hero).
        var arranged: [NSView] = [fileCard]

        completionStackView.apply(completionStack)
        let hasSidecars = !(completionStack?.sidecars.isEmpty ?? true)
        if hasSidecars {
            arranged.append(makeHairline())
            arranged.append(completionStackView)
        }
        if let notice {
            arranged.append(makeDeliveryNotice(notice))
        }
        arranged.append(audioStatusView)
        arranged.append(actions)

        let deck = NSStackView(views: arranged)
        deck.orientation = .vertical
        deck.alignment = .leading
        deck.spacing = 14
        deck.setCustomSpacing(16, after: fileCard)
        deck.translatesAutoresizingMaskIntoConstraints = false
        deckStack = deck

        content.addSubview(hero)
        content.addSubview(deck)
        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: content.topAnchor),
            hero.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hero.heightAnchor.constraint(equalToConstant: heroHeight),

            deck.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 20),
            deck.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            deck.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            deck.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),

            fileCard.widthAnchor.constraint(equalTo: deck.widthAnchor),
            caption.widthAnchor.constraint(equalTo: fileCard.widthAnchor, constant: -46 - 13),
            actions.widthAnchor.constraint(equalTo: deck.widthAnchor),
        ])
        if hasSidecars {
            completionStackView.widthAnchor.constraint(equalTo: deck.widthAnchor).isActive = true
        }
        audioStatusView.widthAnchor.constraint(equalTo: deck.widthAnchor).isActive = true
    }

    private func makeHairline() -> NSView {
        let line = ChromeBox(fill: NDMChrome.hairline)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalTo: deckStack?.widthAnchor ?? line.widthAnchor).isActive = deckStack != nil
        return line
    }

    /// Quiet outlined control — hairline pill; hover deepens the ring, not a
    /// rail-style gray cushion (see `usesOutlinedHover`).
    private func outlinedButton(title: String) -> InspectorActionButton {
        let button = InspectorActionButton(title: title, style: .flat)
        button.usesOutlinedHover = true
        button.wantsLayer = true
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NDMChrome.hairline.cgColor
        button.layer?.cornerRadius = 9
        return button
    }

    private func resizeToFitContent(animate: Bool) {
        guard let window, let deckStack else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let deckHeight = deckStack.fittingSize.height
        // Hero band + deck (top gap 20 + deck + bottom gap 20).
        let contentHeight = heroHeight + 20 + deckHeight + 20
        let desiredFrameHeight = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: window.contentLayoutRect.width, height: contentHeight)
        ).height
        let minimum: CGFloat = 300
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maximum = max(minimum, (visibleFrame?.height ?? desiredFrameHeight) - 24)
        let targetHeight = min(max(minimum, desiredFrameHeight), maximum)
        collapsedWindowHeight = targetHeight

        guard abs(window.frame.height - targetHeight) > 0.5 else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = targetHeight
        frame.origin.y = top - targetHeight
        window.setFrame(
            frame,
            display: true,
            animate: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    /// Fill the hero with the same CoverArtCache poster the detail page uses
    /// (yt-dlp thumbnail → disk cache). A raw Quick Look grab on the finished
    /// file often returns a muddy mid-frame and used to overwrite that poster
    /// after the progress handoff had already shown the correct cover.
    private func loadThumbnail(into hero: CompletionCinemaHero) {
        let taskID = task.id
        if let cover = CoverArtCache.shared.image(for: taskID) {
            hero.showThumbnail(cover)
            return
        }
        if coverObserver == nil {
            coverObserver = NotificationCenter.default.addObserver(
                forName: CoverArtCache.didUpdateNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak hero] note in
                MainActor.assumeIsolated {
                    guard let self,
                          let hero,
                          let updatedID = note.userInfo?["taskID"] as? Int64,
                          updatedID == self.task.id,
                          let cover = CoverArtCache.shared.image(for: updatedID) else { return }
                    hero.showThumbnail(cover)
                    self.clearCoverObserver()
                }
            }
        }
        CoverArtCache.shared.ensureCover(
            taskID: taskID,
            remoteURL: nil,
            localFile: task.destinationFileURL
        )
    }

    private func clearCoverObserver() {
        if let coverObserver {
            NotificationCenter.default.removeObserver(coverObserver)
            self.coverObserver = nil
        }
    }

    /// Swap every localized string in place on a live language switch. Nothing
    /// is torn down, so the sidecar disclosure's expansion, the loaded artwork
    /// and the resolved runtime all survive — the way a mature app relocalizes.
    private func relocalize() {
        let isMedia = task.category == .video || task.category == .audio
        window?.title = L10n.downloadComplete
        hero?.setTitle(L10n.downloadComplete)
        openButton?.title = isMedia ? L10n.play : L10n.open
        revealButton?.title = L10n.showInFinder
        shareButton?.setAccessibilityLabel(L10n.share)
        moreButton?.setAccessibilityLabel(L10n.moreActions)
        if let notice = deliveryNotice() { noticeLabel?.stringValue = notice }
        updateMetaLabel()
        completionStackView.relocalize()
        resizeToFitContent(animate: false)
    }

    /// Rebuild the "size · type · duration" line from its parts. The size is
    /// locale-agnostic; the type label and duration are folded in as available.
    private func updateMetaLabel() {
        guard let metaLabel else { return }
        let sizeText = task.fileSize > 0
            ? TaskPresentationFormatting.byteCount(task.fileSize)
            : ""
        let typeText = L10n.fileTypeDisplay(ext: (task.filename as NSString).pathExtension)
        let dateText = TaskPresentationFormatting.activityDate(
            task.completedAt ?? task.lastTry ?? task.firstTry
        )
        metaLabel.stringValue = [sizeText, typeText, durationText, dateText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
    }

    /// Append "42:07" to the meta line for playable media.
    private func loadMediaDuration() {
        guard let fileURL = task.destinationFileURL,
              ["mp4", "mov", "m4v", "m4a", "mp3", "webm", "mkv", "ts"]
                .contains(fileURL.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: fileURL.path) else { return }
        Task { [weak self] in
            let asset = AVURLAsset(url: fileURL)
            guard let duration = try? await asset.load(.duration) else { return }
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return }
            let total = Int(seconds.rounded())
            let text: String
            if total >= 3600 {
                text = String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            } else {
                text = String(format: "%d:%02d", total / 60, total % 60)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.durationText = text
                self.updateMetaLabel()
            }
        }
    }

    @objc private func openClicked() {
        guard let url = destinationFileForAction() else { return }
        if !NSWorkspace.shared.open(url) {
            showActionFailure(message: L10n.openFileFailed, detail: url.path)
        }
    }

    @objc private func revealClicked() {
        guard let url = destinationFileForAction() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func shareClicked(_ sender: NSButton) {
        guard let url = destinationFileForAction() else { return }
        if !fileSharePresenter.present(fileURL: url, from: sender) {
            showActionFailure(message: L10n.fileNotFound, detail: url.path)
        }
    }

    private func destinationFileForAction() -> URL? {
        guard let url = task.destinationFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            openButton?.isEnabled = false
            revealButton?.isEnabled = false
            shareButton?.isEnabled = false
            moreButton?.isEnabled = false
            showActionFailure(
                message: L10n.fileNotFound,
                detail: task.destinationFileURL?.path ?? task.filename
            )
            return nil
        }
        return url
    }

    private func showActionFailure(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func showMoreActions(_ sender: NSButton) {
        let menu = NSMenu()
        switch audioExtraction.state {
        case .unavailable:
            return
        case .ready, .failed:
            let extract = NSMenuItem(
                title: L10n.extractAudio,
                action: #selector(extractAudioClicked),
                keyEquivalent: ""
            )
            extract.image = NDMChrome.symbol("waveform", pointSize: 13, weight: .medium)
            extract.target = self
            menu.addItem(extract)
        case .running:
            let running = NSMenuItem(title: L10n.extractingAudio, action: nil, keyEquivalent: "")
            running.image = NDMChrome.symbol("waveform", pointSize: 13, weight: .medium)
            running.isEnabled = false
            menu.addItem(running)
        case .succeeded:
            let reveal = NSMenuItem(
                title: L10n.showAudioInFinder,
                action: #selector(revealExtractedAudio),
                keyEquivalent: ""
            )
            reveal.image = NDMChrome.symbol("folder", pointSize: 13, weight: .medium)
            reveal.target = self
            menu.addItem(reveal)
            menu.addItem(.separator())
            let again = NSMenuItem(
                title: L10n.extractAudioAgain,
                action: #selector(extractAudioClicked),
                keyEquivalent: ""
            )
            again.image = NDMChrome.symbol("waveform", pointSize: 13, weight: .medium)
            again.target = self
            menu.addItem(again)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 3), in: sender)
    }

    @objc private func extractAudioClicked() {
        audioExtraction.extract()
    }

    @objc private func revealExtractedAudio() {
        audioExtraction.revealResult()
    }

    @objc private func closeClicked() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        clearCoverObserver()
        audioExtraction.cancel()
        onDismiss()
    }
}

// MARK: - Cinema hero

/// A full-bleed dark band: the finished file's own artwork fills it (aspect
/// fill, clipped), a top scrim keeps the white headline legible over any
/// image, and an accent underline plus a translucent close puck sit on top.
@MainActor
final class CompletionCinemaHero: NSView {
    var onClose: (() -> Void)?

    private let backdrop = ThumbnailBackdropView()
    private let restGlyph = NSImageView()
    private let scrim = TopScrimView()
    private let closeButton = HeroCloseButton()
    private let titleLabel = NSTextField(labelWithString: "")

    func setTitle(_ title: String) {
        // A soft shadow travels with the glyphs, so the headline never dissolves
        // into a light patch of the artwork — legibility that doesn't depend on
        // the scrim alone.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        titleLabel.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: NSColor.white,
                .shadow: shadow,
            ]
        )
    }

    init(title: String, filename: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.plateColor.cgColor
        layer?.masksToBounds = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false

        restGlyph.image = Self.glyph(for: filename)
        restGlyph.contentTintColor = NSColor.white.withAlphaComponent(0.16)
        restGlyph.imageScaling = .scaleProportionallyUpOrDown
        restGlyph.translatesAutoresizingMaskIntoConstraints = false
        restGlyph.setAccessibilityElement(false)

        scrim.translatesAutoresizingMaskIntoConstraints = false

        setTitle(title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let underline = ChromeBox(fill: NDMChrome.accent, cornerRadius: 2)
        underline.translatesAutoresizingMaskIntoConstraints = false

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityLabel(L10n.close)

        addSubview(backdrop)
        addSubview(restGlyph)
        addSubview(scrim)
        addSubview(titleLabel)
        addSubview(underline)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            restGlyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            restGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            restGlyph.widthAnchor.constraint(equalToConstant: 60),
            restGlyph.heightAnchor.constraint(equalToConstant: 60),

            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 26),

            underline.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: 2),
            underline.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            underline.widthAnchor.constraint(equalToConstant: 52),
            underline.heightAnchor.constraint(equalToConstant: 4),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showThumbnail(_ image: NSImage) {
        backdrop.setImage(image)
        restGlyph.isHidden = true
    }

    func handoffDestinationRect(in ancestor: NSView, isArtwork: Bool) -> NSRect {
        let target: NSView = isArtwork ? self : restGlyph
        return ancestor.convert(target.bounds, from: target)
    }

    /// One restrained, native-layer completion flourish: a highlight wipes
    /// across the finished artwork and a handful of tiny sparks break outward.
    /// No emoji, looping confetti, sound, or interaction-blocking overlay.
    func celebrateCompletion() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let hostLayer = layer,
              bounds.width > 0,
              bounds.height > 0 else { return }

        let shine = CAGradientLayer()
        shine.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.26).cgColor,
            NSColor.clear.cgColor,
        ]
        shine.locations = [0, 0.5, 1]
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.frame = CGRect(x: -110, y: -30, width: 90, height: bounds.height + 60)
        shine.setAffineTransform(CGAffineTransform(rotationAngle: -0.16))
        hostLayer.addSublayer(shine)

        let wipe = CABasicAnimation(keyPath: "position.x")
        wipe.fromValue = -90
        wipe.toValue = bounds.width + 150
        wipe.duration = 0.72
        wipe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        wipe.fillMode = .forwards
        wipe.isRemovedOnCompletion = false
        shine.add(wipe, forKey: "completionShine")

        let origin = CGPoint(x: bounds.midX, y: bounds.midY - 10)
        let colors = [
            NDMChrome.accent,
            NSColor.white,
            NSColor.systemTeal,
            NSColor.systemYellow,
            NSColor.systemPink,
        ]

        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        ring.position = origin
        ring.path = CGPath(
            ellipseIn: CGRect(x: 1, y: 1, width: 32, height: 32),
            transform: nil
        )
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NDMChrome.accent.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 2
        hostLayer.addSublayer(ring)
        let ringScale = CABasicAnimation(keyPath: "transform.scale")
        ringScale.fromValue = 0.55
        ringScale.toValue = 4.2
        let ringFade = CABasicAnimation(keyPath: "opacity")
        ringFade.fromValue = 0.9
        ringFade.toValue = 0
        let ringBurst = CAAnimationGroup()
        ringBurst.animations = [ringScale, ringFade]
        ringBurst.duration = 0.58
        ringBurst.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ringBurst.fillMode = .forwards
        ringBurst.isRemovedOnCompletion = false
        ring.add(ringBurst, forKey: "completionRing")

        titleLabel.wantsLayer = true
        let titlePop = CAKeyframeAnimation(keyPath: "transform.scale")
        titlePop.values = [0.96, 1.035, 1]
        titlePop.keyTimes = [0, 0.46, 1]
        titlePop.duration = 0.48
        titlePop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        titleLabel.layer?.add(titlePop, forKey: "completionTitlePop")

        for index in 0..<18 {
            let spark = CALayer()
            let width: CGFloat = index.isMultiple(of: 3) ? 4 : 3
            let height: CGFloat = index.isMultiple(of: 2) ? 10 : 7
            spark.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            spark.position = origin
            spark.cornerRadius = width / 2
            spark.backgroundColor = colors[index % colors.count]
                .withAlphaComponent(0.92)
                .cgColor
            hostLayer.addSublayer(spark)

            let angle = (-CGFloat.pi * 0.88)
                + (CGFloat(index) / 13) * CGFloat.pi * 1.76
            let distance: CGFloat = 76 + CGFloat((index * 17) % 64)
            let destination = CGPoint(
                x: origin.x + cos(angle) * distance,
                y: origin.y + sin(angle) * distance + 12
            )
            let path = CGMutablePath()
            path.move(to: origin)
            path.addQuadCurve(
                to: destination,
                control: CGPoint(
                    x: (origin.x + destination.x) / 2,
                    y: max(origin.y, destination.y) + 38
                )
            )

            let flight = CAKeyframeAnimation(keyPath: "position")
            flight.path = path
            flight.calculationMode = .paced

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.08, 0.62, 1]

            let spin = CABasicAnimation(keyPath: "transform.rotation")
            spin.fromValue = 0
            spin.toValue = CGFloat.pi * CGFloat(index.isMultiple(of: 2) ? 2 : -2)

            let burst = CAAnimationGroup()
            burst.animations = [flight, fade, spin]
            burst.duration = 0.82 + Double(index % 4) * 0.045
            burst.beginTime = spark.convertTime(CACurrentMediaTime(), from: nil)
                + Double(index % 3) * 0.018
            burst.timingFunction = CAMediaTimingFunction(name: .easeOut)
            burst.fillMode = .forwards
            burst.isRemovedOnCompletion = false
            spark.add(burst, forKey: "completionBurst")

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                spark.removeFromSuperlayer()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
            shine.removeFromSuperlayer()
            ring.removeFromSuperlayer()
        }
    }

    @objc private func closePressed() {
        onClose?()
    }

    /// Always-dark plate — the cinema canvas holds even in light mode.
    static let plateColor = NSColor(srgbRed: 0.043, green: 0.051, blue: 0.070, alpha: 1)

    private static func glyph(for filename: String) -> NSImage? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let name: String
        switch ext {
        case "dmg", "iso": name = "externaldrive.fill"
        case "pkg", "app", "exe", "msi", "apk": name = "shippingbox.fill"
        case "zip", "rar", "7z", "gz", "tar": name = "archivebox.fill"
        case "mp3", "m4a", "flac", "wav", "aac", "ogg": name = "waveform"
        case "pdf", "doc", "docx", "txt", "rtf", "md", "epub": name = "doc.richtext.fill"
        case "mp4", "mkv", "mov", "m4v", "webm", "avi", "ts": name = "film.fill"
        default: name = "doc.fill"
        }
        let img = NDMChrome.symbol(name, pointSize: 60, weight: .regular)
        img?.isTemplate = true
        return img
    }
}

/// Layer-backed aspect-fill image plate — NSImageView cannot crop-fill.
private final class ThumbnailBackdropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage) {
        var rect = CGRect(origin: .zero, size: image.size)
        layer?.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

/// Vertical scrim: dark at the top so a white headline reads over bright
/// artwork, fading to clear across the upper half.
private final class TopScrimView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Anchored to the headline zone: genuinely dark at the very top so a
        // white title and the close puck read over *any* artwork — bright,
        // busy, or dark — then fades to clear so the cover still shines below.
        gradient.colors = [
            NSColor.black.withAlphaComponent(0.82).cgColor,
            NSColor.black.withAlphaComponent(0.42).cgColor,
            NSColor.clear.cgColor,
        ]
        gradient.locations = [0, 0.30, 0.60]
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }
}

/// Translucent close puck for the hero: a soft dark disc that brightens on
/// hover, with a white glyph — legible on any artwork.
private final class HeroCloseButton: NSButton {
    private var isHovering = false
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.masksToBounds = true
        imagePosition = .imageOnly
        image = NDMChrome.symbol("xmark", pointSize: 12, weight: .bold)
        contentTintColor = .white
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // A denser disc than a hint of tint: the × must read on a bright corner,
        // not just a dark one. A faint ring gives it an edge on either.
        let base: CGFloat = isHovering ? 0.58 : 0.42
        layer?.backgroundColor = NSColor.black.withAlphaComponent(base).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
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
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        needsDisplay = true
    }
}

// MARK: - File glyph tile

/// A small rounded tile carrying a white category glyph on an accent-tinted
/// fill — the file's identity mark beside its name.
@MainActor
final class FileGlyphTile: NSView {
    init(filename: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
        layer?.backgroundColor = Self.tint(for: filename).cgColor

        let glyph = NSImageView()
        glyph.image = Self.glyph(for: filename)
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 22),
            glyph.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func tint(for filename: String) -> NSColor {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "dmg", "iso": return .systemIndigo
        case "pkg", "app", "exe", "msi", "apk": return .systemPurple
        case "zip", "rar", "7z", "gz", "tar": return .systemOrange
        case "pdf", "doc", "docx", "txt", "rtf", "md", "epub": return .systemBlue
        case "mp3", "m4a", "flac", "wav", "aac", "ogg": return .systemPink
        case "mp4", "mkv", "mov", "m4v", "webm", "avi", "ts": return NDMChrome.accent
        default: return .systemGray
        }
    }

    private static func glyph(for filename: String) -> NSImage? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let name: String
        switch ext {
        case "dmg", "iso": name = "externaldrive.fill"
        case "pkg", "app", "exe", "msi", "apk": name = "shippingbox.fill"
        case "zip", "rar", "7z", "gz", "tar": name = "archivebox.fill"
        case "mp3", "m4a", "flac", "wav", "aac", "ogg": name = "waveform"
        case "pdf", "doc", "docx", "txt", "rtf", "md", "epub": name = "doc.richtext.fill"
        case "mp4", "mkv", "mov", "m4v", "webm", "avi", "ts": name = "play.fill"
        default: name = "doc.fill"
        }
        return NDMChrome.symbol(name, pointSize: 22, weight: .semibold)
    }
}
