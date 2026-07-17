import AppKit
import NDMCore

/// Lightweight “working…” sheet — never a floating panel that steals z-order.
@MainActor
final class WorkingPanelController: NSWindowController {
    private static var retained: WorkingPanelController?
    private let label = NSTextField(labelWithString: "")
    private weak var parentWindow: NSWindow?

    init(message: String) {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 88),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.appName
        window.isFloatingPanel = false
        window.isReleasedWhenClosed = false
        window.representedURL = nil
        NDMChrome.applySheetChrome(window)
        super.init(window: window)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        label.stringValue = message
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        guard let content = window.contentView else { return }
        content.addSubview(spinner)
        content.addSubview(label)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func show(_ message: String, on parent: NSWindow?) -> WorkingPanelController {
        retained?.dismiss()
        let wc = WorkingPanelController(message: message)
        wc.parentWindow = parent
        retained = wc
        guard let sheet = wc.window else { return wc }
        if let parent {
            parent.beginSheet(sheet) { _ in }
        } else {
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
        return wc
    }

    func update(message: String) {
        label.stringValue = message
        label.toolTip = message
    }

    func dismiss() {
        if Self.retained === self { Self.retained = nil }
        if let sheet = window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            window?.orderOut(nil)
            close()
        }
    }
}
