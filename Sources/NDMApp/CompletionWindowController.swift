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

        let title = NSTextField(labelWithString: isMedia ? L10n.readyToPlay : L10n.ready)
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let name = NSTextField(wrappingLabelWithString: task.filename.isEmpty ? L10n.download : task.filename)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Real thumbnail of the finished file (video frame, PDF page, image…),
        // with the file icon as instant placeholder.
        let thumb = NSImageView()
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.image = NDMChrome.fileIcon(filename: task.filename, pointSize: 52)
        thumb.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 92),
            thumb.heightAnchor.constraint(equalToConstant: 56),
        ])
        loadThumbnail(into: thumb)

        let sizeText = task.fileSize > 0
            ? TaskPresentationFormatting.byteCount(task.fileSize)
            : ""
        let path = task.destinationFileURL?.path ?? task.folderPath ?? ""
        let meta = NSTextField(wrappingLabelWithString: [sizeText, path].filter { !$0.isEmpty }.joined(separator: "\n"))
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.maximumNumberOfLines = 3
        metaLabel = meta
        loadMediaDuration()

        let open = NSButton(
            title: isMedia ? L10n.play : L10n.open,
            target: self,
            action: #selector(openClicked)
        )
        NDMChrome.styleMainButton(open)
        open.keyEquivalent = "\r"
        open.controlSize = .regular
        open.image = NDMChrome.symbol(isMedia ? "play.fill" : "arrow.up.forward.app.fill", pointSize: 11)
        open.imagePosition = .imageLeading

        let reveal = NSButton(title: L10n.showInFinder, target: self, action: #selector(revealClicked))
        NDMChrome.styleGhostButton(reveal)
        reveal.controlSize = .regular
        reveal.image = NDMChrome.symbol("folder", pointSize: 11)
        reveal.imagePosition = .imageLeading

        let share = NSButton(title: "", target: self, action: #selector(shareClicked))
        share.isBordered = false
        share.bezelStyle = .inline
        share.controlSize = .regular
        share.image = NDMChrome.symbol("square.and.arrow.up", pointSize: 12, weight: .medium)
        share.imagePosition = .imageOnly
        share.toolTip = L10n.share
        share.setAccessibilityLabel(L10n.share)

        let more = NSButton(title: "", target: self, action: #selector(showMoreActions(_:)))
        more.isBordered = false
        more.bezelStyle = .inline
        more.controlSize = .regular
        more.image = NDMChrome.symbol("ellipsis", pointSize: 12, weight: .semibold)
        more.imagePosition = .imageOnly
        more.toolTip = L10n.moreActions
        more.setAccessibilityLabel(L10n.moreActions)
        more.isHidden = !SmartFinalize.supportsDeliveryRecipes(input: task.destinationFileURL)

        let close = NSButton(title: L10n.close, target: self, action: #selector(closeClicked))
        NDMChrome.styleGhostButton(close)
        close.keyEquivalent = "\u{1b}"

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

        let headerRow = NSStackView(views: [thumb, name])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

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
        arranged.append(contentsOf: [meta, actions])

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
            meta.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

    /// Replace the icon placeholder with a real Quick Look thumbnail.
    private func loadThumbnail(into imageView: NSImageView) {
        guard let fileURL = task.destinationFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 92, height: 56),
            scale: window?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak imageView] rep, _ in
            guard let rep else { return }
            Task { @MainActor in
                imageView?.image = rep.nsImage
                imageView?.imageScaling = .scaleProportionallyUpOrDown
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
}

private final class CompletionDocumentView: NSView {
    override var isFlipped: Bool { true }
}
