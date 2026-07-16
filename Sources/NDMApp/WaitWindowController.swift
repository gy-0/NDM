import AppKit
import NDMCore

/// Confirm browser-captured download before start.
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
    private let metaLabel = NSTextField(wrappingLabelWithString: "")
    private var didFinish = false

    init(message: ParsedBridgeMessage, completion: @escaping (Result) -> Void) {
        self.message = message
        self.completion = completion
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.confirmDownload
        NDMChrome.applyWindowChrome(window)
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        titleLabel.stringValue = message.pageTitle.isEmpty ? L10n.downloadFromBrowser : message.pageTitle
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        urlField.stringValue = message.url
        urlField.isEditable = true
        urlField.isSelectable = true
        urlField.lineBreakMode = .byTruncatingMiddle

        var parts: [String] = []
        if !message.filename.isEmpty { parts.append(message.filename) }
        if message.fileSize > 0 {
            parts.append(TaskPresentationFormatting.byteCount(Int64(message.fileSize)))
        }
        if let kind = TaskPresentationFormatting.linkTypeTitle(message.ltype) {
            parts.append(kind)
        }
        if !message.alternateURL.isEmpty {
            parts.append(L10n.includesAudioTrack)
        }
        metaLabel.stringValue = parts.isEmpty ? L10n.capturedByBetterNDM : parts.joined(separator: " · ")
        metaLabel.font = .systemFont(ofSize: 12)
        metaLabel.textColor = .secondaryLabelColor

        let ok = NSButton(title: L10n.download, target: self, action: #selector(okClicked))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: L10n.cancel, target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [NSView(), cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fill

        let stack = NSStackView(views: [titleLabel, metaLabel, urlField, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            urlField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            metaLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ok.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
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
        if !didFinish {
            finish(.cancel)
        }
    }

    private func finish(_ result: Result) {
        guard !didFinish else { return }
        didFinish = true
        completion(result)
    }
}
