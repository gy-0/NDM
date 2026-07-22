import AppKit
import AVFoundation
import NDMCore
import NDMEngine
import QuickLookThumbnailing

/// Non-modal completion panel — used only when no progress window is open.
@MainActor
final class CompletionWindowController: NSWindowController, NSWindowDelegate {
    private let task: DownloadTask
    private let onDismiss: () -> Void
    private let completionStack: CompletionStack?
    private var collapsedWindowHeight: CGFloat = 340
    private let completionStackView = CompletionStackView()
    private let audioExtraction = AudioExtractionCoordinator()
    private let audioStatusView = AudioExtractionStatusView()
    private let scribeStudioCard = ScribeStudioActionCard()
    private let fileSharePresenter = FileSharePresenter()
    private var completionExpansionAddedHeight: CGFloat = 0
    private weak var metaLabel: NSTextField?
    private weak var rootStack: NSStackView?

    init(task: DownloadTask, onDismiss: @escaping () -> Void = {}) {
        self.task = task
        self.onDismiss = onDismiss
        self.completionStack = SmartFinalize.completionStack(primary: task.destinationFileURL)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 440,
                height: collapsedWindowHeight
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.downloadComplete
        window.minSize = NSSize(width: 440, height: 300)
        NDMChrome.applyWindowChrome(window)
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
        window.setFrame(frame, display: true, animate: true)
    }

    /// Smart Finalize summary derived from what the engine actually produced.
    /// Returns nil for plain downloads — the card stays quiet for those.
    private func finalizeSteps() -> [String]? {
        let ext = (task.filename as NSString).pathExtension.lowercased()
        var steps: [String] = []
        switch task.linkType.lowercased() {
        case "hls", "m3u8":
            steps = [
                L10n.finalizeMergedSegments,
                ext == "mp4" ? L10n.finalizeRemuxedMP4 : L10n.finalizeKeptTS,
            ]
        case "mkv", "mkva", "mkvv":
            steps = [L10n.finalizeMergedTracks]
            if ext == "mp4" {
                steps.append(L10n.finalizeRemuxedMP4)
            } else {
                steps.append(L10n.finalizeAudioSidecar)
            }
        case "ytdlp":
            steps = [L10n.finalizePlayableMedia]
        default:
            guard task.category == .video || task.category == .audio else { return nil }
            steps = [L10n.finalizePlayableMedia]
        }
        if SmartFinalize.filenameReflectsPageTitle(task.filename, pageTitle: task.pageTitle) {
            let actualStem = (task.filename as NSString).deletingPathExtension
            steps.append(L10n.finalizeNamed(actualStem))
        }
        if completionStack?.artifacts.contains(where: { $0.kind == .subtitle }) == true {
            steps.append(L10n.finalizeSubtitleReady)
        }
        if completionStack?.artifacts.contains(where: { $0.kind == .cover }) == true {
            steps.append(L10n.finalizeCoverReady)
        }
        return steps
    }

    private func makeStepRow(_ text: String, pending: Bool = false) -> NSView {
        let check = NSImageView()
        let symbol = pending ? "circle.dashed" : "checkmark.circle.fill"
        check.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        check.contentTintColor = pending ? .tertiaryLabelColor : NDMChrome.accent
        check.translatesAutoresizingMaskIntoConstraints = false
        check.setAccessibilityElement(false)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = pending ? .secondaryLabelColor : .labelColor
        let row = NSStackView(views: [check, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 7
        NSLayoutConstraint.activate([
            check.widthAnchor.constraint(equalToConstant: 15),
            check.heightAnchor.constraint(equalToConstant: 15),
        ])
        return row
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let steps = finalizeSteps()
        let isMedia = steps != nil

        // A small green "done" check leads the headline — the completion
        // moment earns a beat of success color, not flat label ink.
        let checkBadge = NSImageView()
        checkBadge.image = NDMChrome.symbol("checkmark.circle.fill", pointSize: 20, weight: .semibold)
        checkBadge.contentTintColor = .systemGreen
        checkBadge.translatesAutoresizingMaskIntoConstraints = false
        checkBadge.setAccessibilityElement(false)
        let titleText = NSTextField(labelWithString: isMedia ? L10n.readyToPlay : L10n.ready)
        titleText.font = .systemFont(ofSize: 24, weight: .bold)
        let title = NSStackView(views: [checkBadge, titleText])
        title.orientation = .horizontal
        title.alignment = .centerY
        title.spacing = 8
        NSLayoutConstraint.activate([
            checkBadge.widthAnchor.constraint(equalToConstant: 22),
            checkBadge.heightAnchor.constraint(equalToConstant: 22),
        ])

        let name = NSTextField(wrappingLabelWithString: task.filename.isEmpty ? L10n.download : task.filename)
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 2
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A generous 16:9 hero: a real Quick Look thumbnail for media, or a
        // large category-tinted type glyph on a tinted plate for everything
        // else — no more stamp-sized gray file icon.
        let thumb = CompletionHeroView(filename: task.filename)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 168),
            thumb.heightAnchor.constraint(equalToConstant: 104),
        ])
        loadThumbnail(into: thumb.imageView)

        let sizeText = task.fileSize > 0
            ? TaskPresentationFormatting.byteCount(task.fileSize)
            : ""
        let typeText = L10n.fileTypeDisplay(ext: (task.filename as NSString).pathExtension)
        let meta = NSTextField(labelWithString: [sizeText, typeText].filter { !$0.isEmpty }.joined(separator: "  ·  "))
        meta.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        metaLabel = meta
        loadMediaDuration()

        let open = InspectorActionButton(title: isMedia ? L10n.play : L10n.open)
        open.target = self
        open.action = #selector(openClicked)
        open.keyEquivalent = "\r"
        open.image = NDMChrome.symbol(isMedia ? "play.fill" : "arrow.up.forward.app.fill", pointSize: 12, weight: .semibold)
        open.imagePosition = .imageLeading
        open.imageHugsTitle = true
        open.font = .systemFont(ofSize: 13, weight: .semibold)
        open.contentTintColor = NDMChrome.accent

        let reveal = InspectorActionButton(title: L10n.showInFinder)
        reveal.target = self
        reveal.action = #selector(revealClicked)
        reveal.image = NDMChrome.symbol("folder", pointSize: 12, weight: .medium)
        reveal.imagePosition = .imageLeading
        reveal.imageHugsTitle = true
        reveal.font = .systemFont(ofSize: 13, weight: .medium)
        reveal.contentTintColor = .secondaryLabelColor

        let share = InspectorActionButton(title: "")
        share.target = self
        share.action = #selector(shareClicked)
        share.image = NDMChrome.symbol("square.and.arrow.up", pointSize: 13, weight: .medium)
        share.imagePosition = .imageOnly
        share.contentTintColor = .secondaryLabelColor
        share.setAccessibilityLabel(L10n.share)

        let more = InspectorActionButton(title: "")
        more.target = self
        more.action = #selector(showMoreActions(_:))
        more.image = NDMChrome.symbol("ellipsis", pointSize: 13, weight: .semibold)
        more.imagePosition = .imageOnly
        more.contentTintColor = .secondaryLabelColor
        more.setAccessibilityLabel(L10n.moreActions)
        more.isHidden = !SmartFinalize.supportsDeliveryRecipes(input: task.destinationFileURL)

        let close = InspectorActionButton(title: L10n.close)
        close.target = self
        close.action = #selector(closeClicked)
        close.keyEquivalent = "\u{1b}"
        close.font = .systemFont(ofSize: 13, weight: .medium)
        close.contentTintColor = .secondaryLabelColor

        let fileExists = task.destinationFileURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        open.isEnabled = fileExists
        reveal.isEnabled = fileExists
        share.isEnabled = fileExists
        more.isEnabled = fileExists

        let actions = NSStackView(views: [open, reveal, NSView(), share, more, close])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        NSLayoutConstraint.activate([
            open.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            reveal.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            close.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            // Icon-only actions need the same 32 pt hit target as neighboring
            // controls; a 28 pt target was needlessly fiddly on a trackpad.
            share.widthAnchor.constraint(equalToConstant: 32),
            more.widthAnchor.constraint(equalToConstant: 32),
            open.heightAnchor.constraint(equalToConstant: 32),
            reveal.heightAnchor.constraint(equalToConstant: 32),
            share.heightAnchor.constraint(equalToConstant: 32),
            more.heightAnchor.constraint(equalToConstant: 32),
            close.heightAnchor.constraint(equalToConstant: 32),
        ])

        // Hero on top, then filename + meta beneath it — a poster-and-caption
        // composition, not an icon-beside-text row.
        let caption = NSStackView(views: [name, meta])
        caption.orientation = .vertical
        caption.alignment = .leading
        caption.spacing = 3
        let headerRow = NSStackView(views: [thumb, caption])
        headerRow.orientation = .vertical
        headerRow.alignment = .leading
        headerRow.spacing = 12
        headerRow.setCustomSpacing(14, after: thumb)

        var arranged: [NSView] = [title, headerRow]
        var stepsBoxRef: NSView?
        if let steps {
            let section = NSTextField(labelWithString: L10n.finalizeSectionTitle)
            section.font = .systemFont(ofSize: 10, weight: .semibold)
            // This is a real section heading, not decorative metadata. Using
            // tertiary ink made it nearly disappear in the completion moment.
            section.textColor = .secondaryLabelColor
            // Open checklist — the checkmarks carry the meaning; no box.
            let stepRows: [NSView] = steps.map { makeStepRow($0) }
            let stepsStack = NSStackView(views: [section] + stepRows)
            stepsStack.orientation = .vertical
            stepsStack.alignment = .leading
            stepsStack.spacing = 6
            stepsStack.setCustomSpacing(8, after: section)
            stepsStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 2, right: 0)
            stepsStack.translatesAutoresizingMaskIntoConstraints = false
            arranged.append(stepsStack)
            stepsBoxRef = stepsStack
        }

        completionStackView.apply(completionStack)
        if !(completionStack?.sidecars.isEmpty ?? true) {
            arranged.append(completionStackView)
        }

        arranged.append(audioStatusView)
        scribeStudioCard.apply(fileURL: task.destinationFileURL)
        if !scribeStudioCard.isHidden {
            arranged.append(scribeStudioCard)
        }
        arranged.append(actions)

        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = CompletionDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        content.addSubview(scrollView)
        rootStack = stack
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        if let stepsBoxRef {
            stepsBoxRef.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if !completionStackView.isHidden {
            completionStackView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        audioStatusView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if !scribeStudioCard.isHidden {
            scribeStudioCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func resizeToFitContent(animate: Bool) {
        guard let window, let rootStack else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let contentHeight = rootStack.fittingSize.height + 40
        // `fittingSize` is content-view height, while `NSWindow.frame.height`
        // includes the titlebar. Applying the content number directly to the
        // frame clipped the bottom action row by roughly one titlebar.
        let desiredFrameHeight = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: window.contentLayoutRect.width, height: contentHeight)
        ).height
        let minimum = window.minSize.height > 0 ? window.minSize.height : 240
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maximum = max(minimum, (visibleFrame?.height ?? desiredFrameHeight) - 24)
        let targetHeight = min(max(minimum, desiredFrameHeight), maximum)
        collapsedWindowHeight = targetHeight

        guard abs(window.frame.height - targetHeight) > 0.5 else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = targetHeight
        frame.origin.y = top - targetHeight
        window.setFrame(frame, display: true, animate: animate)
    }

    /// Replace the type glyph with a real Quick Look thumbnail once ready.
    private func loadThumbnail(into imageView: NSImageView) {
        guard let hero = imageView.superview as? CompletionHeroView,
              let fileURL = task.destinationFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 336, height: 208),
            scale: window?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak hero] rep, _ in
            guard let rep else { return }
            Task { @MainActor in
                hero?.showThumbnail(rep.nsImage)
            }
        }
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
                guard let self, let meta = self.metaLabel else { return }
                let lines = meta.stringValue.split(separator: "\n", maxSplits: 1)
                if let first = lines.first {
                    let rest = lines.count > 1 ? "\n" + lines[1] : ""
                    meta.stringValue = "\(first) · \(text)\(rest)"
                } else {
                    meta.stringValue = text
                }
            }
        }
    }

    @objc private func openClicked() {
        guard let url = task.destinationFileURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealClicked() {
        guard let url = task.destinationFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func shareClicked(_ sender: NSButton) {
        _ = fileSharePresenter.present(fileURL: task.destinationFileURL, from: sender)
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
        audioExtraction.cancel()
        onDismiss()
    }

    private var didCelebrate = false

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !didCelebrate, let content = window?.contentView else { return }
        didCelebrate = true
        // A beat of delight, fired from just under the success headline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            CelebrationEffect.burst(
                in: content,
                at: CGPoint(x: content.bounds.midX, y: content.bounds.maxY - 90)
            )
        }
    }
}

private final class CompletionDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Completion hero: a rounded 16:9 plate that shows a real Quick Look
/// thumbnail once it loads, or a large category-tinted type glyph as the
/// resting state — plus a soft drop shadow so the finished file feels like an
/// object, not a list entry.
@MainActor
final class CompletionHeroView: NSView {
    let imageView = NSImageView()
    private let plate = NSView()
    private let glyphView = NSImageView()

    init(filename: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        plate.wantsLayer = true
        plate.layer?.cornerRadius = 12
        plate.layer?.masksToBounds = true
        plate.layer?.borderWidth = 1
        plate.layer?.borderColor = NDMChrome.hairline.cgColor
        plate.translatesAutoresizingMaskIntoConstraints = false

        let tint = Self.tint(for: filename)
        plate.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor

        glyphView.image = Self.glyph(for: filename)
        glyphView.contentTintColor = tint.withAlphaComponent(0.9)
        glyphView.imageScaling = .scaleProportionallyUpOrDown
        glyphView.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true

        addSubview(plate)
        plate.addSubview(glyphView)
        addSubview(imageView)
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            glyphView.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            glyphView.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: 46),
            glyphView.heightAnchor.constraint(equalToConstant: 46),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Reveal the real thumbnail as soon as one is assigned.
        imageView.postsFrameChangedNotifications = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        plate.layer?.borderColor = NDMChrome.hairline.cgColor
    }

    /// Called by the QL callback; flips from glyph to photo.
    func showThumbnail(_ image: NSImage) {
        imageView.image = image
        imageView.isHidden = false
        plate.isHidden = true
    }

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
        case "mp4", "mkv", "mov", "m4v", "webm", "avi", "ts": name = "film.fill"
        default: name = "doc.fill"
        }
        let img = NDMChrome.symbol(name, pointSize: 46, weight: .regular)
        img?.isTemplate = true
        return img
    }
}
