import AppKit
import NDMCore

/// Browser extension setup for NDM Relay.
@MainActor
final class BrowsersWindowController: NSWindowController {
    private let statusLabel = NSTextField(labelWithString: "")

    init(bridgeRunning: Bool = true) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.browserExtension
        NDMChrome.applyWindowChrome(window)
        super.init(window: window)
        buildUI(bridgeRunning: bridgeRunning)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(bridgeRunning: Bool) {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: L10n.connectNDMRelay)
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        if bridgeRunning {
            statusLabel.stringValue = L10n.bridgeReady(BridgeConstants.endpoint)
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = L10n.bridgeUnavailable(BridgeConstants.port)
            statusLabel.textColor = .tertiaryLabelColor
        }

        let body = NSTextField(wrappingLabelWithString: L10n.browsersBody)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .labelColor

        let openFolder = NSButton(title: L10n.showExtensionFolder, target: self, action: #selector(reveal))
        openFolder.bezelStyle = .rounded
        let copyEndpoint = NSButton(
            title: L10n.copyBridgeAddress,
            target: self,
            action: #selector(copyEndpoint(_:))
        )
        copyEndpoint.bezelStyle = .rounded
        let close = NSButton(title: L10n.close, target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [openFolder, copyEndpoint, NSView(), close])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, statusLabel, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func reveal() {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("extension/NDMRelay"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("NDM-clean/extension/NDMRelay"),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("extension/NDMRelay"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        NDMDialog.present(
            title: L10n.extensionFolderMissing,
            body: L10n.extensionFolderHint,
            subject: .caution,
            host: window
        )
    }

    @objc private func copyEndpoint(_ sender: NSButton) {
        let originalTitle = sender.title
        let originalImage = sender.image
        let originalTint = sender.contentTintColor
        let succeeded = DownloadClipboard.copy(BridgeConstants.endpoint)
        sender.title = succeeded ? L10n.copiedToClipboard : L10n.copyFailed
        sender.image = NDMChrome.symbol(
            succeeded ? "checkmark" : "exclamationmark.triangle",
            pointSize: 12,
            weight: .semibold
        )
        sender.contentTintColor = succeeded ? .systemGreen : .systemOrange
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak sender] in
            guard let sender else { return }
            sender.title = originalTitle
            sender.image = originalImage
            sender.contentTintColor = originalTint
        }
    }

    @objc private func closeClicked() { window?.close() }
}
