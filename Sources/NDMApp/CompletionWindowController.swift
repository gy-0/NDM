import AppKit
import NDMCore

/// Non-modal completion panel — used only when no progress window is open.
@MainActor
final class CompletionWindowController: NSWindowController, NSWindowDelegate {
    private let task: DownloadTask
    private let onDismiss: () -> Void

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

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: L10n.ready)
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let name = NSTextField(wrappingLabelWithString: task.filename.isEmpty ? L10n.download : task.filename)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle

        let sizeText = task.fileSize > 0
            ? TaskPresentationFormatting.byteCount(task.fileSize)
            : ""
        let path = task.destinationFileURL?.path ?? task.folderPath ?? ""
        let meta = NSTextField(wrappingLabelWithString: [sizeText, path].filter { !$0.isEmpty }.joined(separator: "\n"))
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.maximumNumberOfLines = 3

        let open = NSButton(title: L10n.open, target: self, action: #selector(openClicked))
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

        let stack = NSStackView(views: [title, name, meta, actions])
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
            name.widthAnchor.constraint(equalTo: stack.widthAnchor),
            meta.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
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
