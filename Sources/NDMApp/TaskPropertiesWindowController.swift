import AppKit
import NDMCore
import NDMEngine

@MainActor
final class TaskPropertiesWindowController: NSWindowController {
    private let manager: DownloadManager
    private var task: DownloadTask
    var taskID: Int64 { task.id }

    private let urlField = NSTextField(string: "")
    private let nameField = NSTextField(string: "")
    private let connField = NSTextField(string: "8")
    private let bwField = NSTextField(string: "0")
    private let statusLabel = NSTextField(labelWithString: "")
    private let altURLField = NSTextField(string: "")

    init(manager: DownloadManager, task: DownloadTask) {
        self.manager = manager
        self.task = task
        // defer: true avoids blocking the menu/toolbar click while the window
        // server allocates backing stores.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "Task Properties — #\(task.id)"
        super.init(window: window)
        buildUI()
        load()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let labels = [
            NSTextField(labelWithString: "URL"),
            urlField,
            NSTextField(labelWithString: "Filename"),
            nameField,
            NSTextField(labelWithString: "Connections (1–32)"),
            connField,
            NSTextField(labelWithString: "Bandwidth limit bytes/s (0=unlimited)"),
            bwField,
            NSTextField(labelWithString: "Alternate URL (urla)"),
            altURLField,
            statusLabel,
        ]
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        let cancel = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        cancel.bezelStyle = .rounded

        let stack = NSStackView(views: labels + [NSStackView(views: [save, cancel])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for f in [urlField, nameField, altURLField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        ])
    }

    private func load() {
        urlField.stringValue = task.url
        nameField.stringValue = task.filename
        connField.stringValue = "\(task.connections)"
        bwField.stringValue = "\(task.bandwidthLimit)"
        altURLField.stringValue = task.alternateURL ?? ""
        statusLabel.stringValue = "Status: \(task.status.rawValue) · Size: \(task.fileSize)"
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func saveClicked() {
        task.url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        task.filename = nameField.stringValue
        task.connections = min(32, max(1, Int(connField.stringValue) ?? task.connections))
        task.bandwidthLimit = Int64(bwField.stringValue) ?? 0
        let alt = altURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        task.alternateURL = alt.isEmpty ? nil : alt
        Task {
            do {
                try await manager.updateTask(task)
                window?.close()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc private func closeClicked() {
        window?.close()
    }
}
