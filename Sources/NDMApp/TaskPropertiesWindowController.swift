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
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let altURLField = NSTextField(string: "")

    init(manager: DownloadManager, task: DownloadTask) {
        self.manager = manager
        self.task = task
        // Use NSPanel + generic title. A filename title / representedURL makes
        // AppKit route showWindow through QLSeamlessDocumentOpener, which crashes
        // on recent macOS (NSRemoteView / SafariPlatformSupport assertion).
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.properties
        window.representedURL = nil
        window.isFloatingPanel = false
        window.becomesKeyOnlyIfNeeded = false
        window.isReleasedWhenClosed = false
        NDMChrome.applyWindowChrome(window)
        super.init(window: window)
        buildUI()
        load()
        window.center()
    }

    /// Safer than `showWindow:` — avoids QuickLook seamless document opener.
    func present() {
        guard let window else { return }
        window.representedURL = nil
        window.makeKeyAndOrderFront(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let save = NSButton(title: L10n.save, target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: L10n.close, target: self, action: #selector(closeClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [
            label(L10n.url), urlField,
            label(L10n.filename), nameField,
            label(L10n.connectionsRange), connField,
            label(L10n.speedLimitCaption), bwField,
            label(L10n.alternateAudioURL), altURLField,
            statusLabel,
            pathLabel,
            NSStackView(views: [save, cancel]),
        ])
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
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func load() {
        urlField.stringValue = task.url
        nameField.stringValue = task.filename
        connField.stringValue = "\(task.connections)"
        bwField.stringValue = "\(task.bandwidthLimit)"
        altURLField.stringValue = task.alternateURL ?? ""
        let size = task.fileSize > 0 ? TaskPresentationFormatting.byteCount(task.fileSize) : L10n.unknown
        let type = TaskPresentationFormatting.categoryTitle(task.category)
        statusLabel.stringValue = "\(TaskPresentationFormatting.statusTitle(task.status)) · \(type) · \(size)"
        if let path = task.destinationFileURL?.path {
            pathLabel.stringValue = path
        } else if let folder = task.folderPath, !folder.isEmpty {
            pathLabel.stringValue = folder
        } else {
            pathLabel.stringValue = L10n.saveLocationPending
        }
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
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func closeClicked() {
        window?.close()
    }
}
