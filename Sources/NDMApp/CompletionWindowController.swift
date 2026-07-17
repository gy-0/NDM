import AppKit
import AVFoundation
import NDMCore
import QuickLookThumbnailing

/// Non-modal completion panel — used only when no progress window is open.
@MainActor
final class CompletionWindowController: NSWindowController, NSWindowDelegate {
    private let task: DownloadTask
    private let onDismiss: () -> Void
    private weak var metaLabel: NSTextField?

    init(task: DownloadTask, onDismiss: @escaping () -> Void = {}) {
        self.task = task
        self.onDismiss = onDismiss
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.downloadComplete
        NDMChrome.applyWindowChrome(window)
        super.init(window: window)
        buildUI()
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Smart Finalize summary derived from what the engine actually produced.
    /// Returns nil for plain downloads — the card stays quiet for those.
    private func finalizeSteps() -> [String]? {
        let ext = (task.filename as NSString).pathExtension.lowercased()
        switch task.linkType.lowercased() {
        case "hls", "m3u8":
            return [
                L10n.finalizeMergedSegments,
                ext == "mp4" ? L10n.finalizeRemuxedMP4 : L10n.finalizeKeptTS,
            ]
        case "mkv", "mkva", "mkvv":
            var steps = [L10n.finalizeMergedTracks]
            if ext == "mp4" {
                steps.append(L10n.finalizeRemuxedMP4)
            }
            return steps
        default:
            return nil
        }
    }

    private func makeStepRow(_ text: String) -> NSView {
        let check = NSImageView()
        check.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: nil
        )
        check.contentTintColor = .systemGreen
        check.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
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
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        open.controlSize = .large

        let reveal = NSButton(title: L10n.showInFinder, target: self, action: #selector(revealClicked))
        reveal.bezelStyle = .rounded
        reveal.controlSize = .large

        let close = NSButton(title: L10n.close, target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.controlSize = .large

        let fileExists = task.destinationFileURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        open.isEnabled = fileExists
        reveal.isEnabled = fileExists

        let actions = NSStackView(views: [open, reveal, close])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.distribution = .fillEqually

        let headerRow = NSStackView(views: [thumb, name])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

        var arranged: [NSView] = [title, headerRow]
        var stepsBoxRef: NSView?
        if let steps {
            let stepRows = steps.map(makeStepRow)
            let stepsStack = NSStackView(views: stepRows)
            stepsStack.orientation = .vertical
            stepsStack.alignment = .leading
            stepsStack.spacing = 6
            stepsStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            stepsStack.translatesAutoresizingMaskIntoConstraints = false
            let stepsBox = ChromeBox(
                fill: NDMChrome.dockFill,
                borderColor: NDMChrome.hairline,
                cornerRadius: 9,
                borderWidth: 1
            )
            stepsBox.translatesAutoresizingMaskIntoConstraints = false
            stepsBox.addSubview(stepsStack)
            NSLayoutConstraint.activate([
                stepsStack.topAnchor.constraint(equalTo: stepsBox.topAnchor),
                stepsStack.leadingAnchor.constraint(equalTo: stepsBox.leadingAnchor),
                stepsStack.trailingAnchor.constraint(equalTo: stepsBox.trailingAnchor),
                stepsStack.bottomAnchor.constraint(equalTo: stepsBox.bottomAnchor),
            ])
            arranged.append(stepsBox)
            stepsBoxRef = stepsBox
        }
        arranged.append(contentsOf: [meta, actions])

        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            meta.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        if let stepsBoxRef {
            stepsBoxRef.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
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

    @objc private func closeClicked() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onDismiss()
    }
}
