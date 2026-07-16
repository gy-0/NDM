import AppKit

/// Browser extension install guide (`NeatBrowsersWindow`).
@MainActor
final class BrowsersWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Browser Extension"
        window.center()
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Connect BetterNDM")
        title.font = .boldSystemFont(ofSize: 15)
        let body = NSTextField(wrappingLabelWithString: """
        NDM listens on ws://127.0.0.1:10007/download (subprotocol neatextension.v1).

        1. Open Chrome / Edge / Firefox
        2. Load unpacked extension from:
           reverse/extension/BetterNDM/
        3. Keep NDM running — the extension auto-connects
        4. Captured media appears in the page panel when ShowPanel=1
        """)
        body.font = .systemFont(ofSize: 12)

        let openFolder = NSButton(title: "Reveal BetterNDM Folder", target: self, action: #selector(reveal))
        openFolder.bezelStyle = .rounded
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded

        let stack = NSStackView(views: [title, body, NSStackView(views: [openFolder, close])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func reveal() {
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("NDM/reverse/extension/BetterNDM"),
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("reverse/extension/BetterNDM"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("reverse/extension/BetterNDM"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let alert = NSAlert()
        alert.messageText = "BetterNDM folder not found"
        alert.informativeText = "Clone/open the NDM repo and load reverse/extension/BetterNDM as an unpacked extension."
        alert.runModal()
    }

    @objc private func closeClicked() { window?.close() }
}
