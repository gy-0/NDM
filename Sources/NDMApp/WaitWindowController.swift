import AppKit
import NDMCore

/// `NeatWaitWindow` — confirm browser-captured download before start.
@MainActor
final class WaitWindowController: NSWindowController, NSWindowDelegate {
    enum Result {
        case download(url: String)
        case cancel
    }

    private let message: ParsedBridgeMessage
    private let completion: (Result) -> Void
    private let urlField = NSTextField(string: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private var didFinish = false

    init(message: ParsedBridgeMessage, completion: @escaping (Result) -> Void) {
        self.message = message
        self.completion = completion
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "New Download from Browser"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        titleLabel.stringValue = message.pageTitle.isEmpty ? "Confirm download" : message.pageTitle
        titleLabel.font = .boldSystemFont(ofSize: 13)
        urlField.stringValue = message.url
        urlField.isEditable = true
        urlField.lineBreakMode = .byTruncatingMiddle

        let info = NSTextField(labelWithString: [
            message.filename.isEmpty ? nil : "File: \(message.filename)",
            message.ltype == "normal" ? nil : "Type: \(message.ltype)",
            message.alternateURL.isEmpty ? nil : "Audio track: yes",
        ].compactMap { $0 }.joined(separator: " · "))
        info.textColor = .secondaryLabelColor

        let ok = NSButton(title: "Download", target: self, action: #selector(okClicked))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded

        let stack = NSStackView(views: [titleLabel, urlField, info, NSStackView(views: [ok, cancel])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            urlField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func okClicked() {
        let url = urlField.stringValue.isEmpty ? message.url : urlField.stringValue
        finish(.download(url: url))
        window?.close()
    }

    @objc private func cancelClicked() {
        finish(.cancel)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing with the title-bar button must resume the checked continuation too.
        finish(.cancel)
    }

    private func finish(_ result: Result) {
        guard !didFinish else { return }
        didFinish = true
        completion(result)
    }
}
