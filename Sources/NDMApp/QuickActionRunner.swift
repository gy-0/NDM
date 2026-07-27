import AppKit
import NDMCore

/// Resolves, illustrates, and executes user-configured completion actions.
@MainActor
enum QuickActionRunner {
    private static let shortcutsURL = URL(fileURLWithPath: "/usr/bin/shortcuts")

    static func appURL(forBundleID bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func icon(for action: QuickAction, pointSize: CGFloat = 18) -> NSImage {
        switch action.kind {
        case .openWithApp(let bundleID):
            if let url = appURL(forBundleID: bundleID) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: pointSize, height: pointSize)
                return icon
            }
        case .shareService(let name):
            if let service = sharingService(named: name, for: representativeFileURL) {
                let icon = service.image
                icon.size = NSSize(width: pointSize, height: pointSize)
                return icon
            }
        case .shortcut:
            break
        }
        return NDMChrome.symbol(action.symbol, pointSize: pointSize - 3, weight: .medium)
            ?? NSImage()
    }

    static func isAvailable(_ action: QuickAction, for file: URL) -> Bool {
        switch action.kind {
        case .openWithApp(let bundleID):
            return appURL(forBundleID: bundleID) != nil
        case .shareService(let name):
            return sharingService(named: name, for: file) != nil
        case .shortcut:
            return FileManager.default.isExecutableFile(atPath: shortcutsURL.path)
        }
    }

    @discardableResult
    static func run(_ action: QuickAction, file: URL) -> Bool {
        switch action.kind {
        case .openWithApp(let bundleID):
            guard let appURL = appURL(forBundleID: bundleID) else { return false }
            NSWorkspace.shared.open(
                [file],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return true
        case .shareService(let name):
            guard let service = sharingService(named: name, for: file) else { return false }
            service.perform(withItems: [file])
            return true
        case .shortcut(let name):
            guard FileManager.default.isExecutableFile(atPath: shortcutsURL.path) else { return false }
            let process = Process()
            process.executableURL = shortcutsURL
            process.arguments = ["run", name, "--input-path", file.path]
            do {
                try process.run()
                return true
            } catch {
                return false
            }
        }
    }

    static func openWithAction(forAppAt appURL: URL) -> QuickAction? {
        guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
        return QuickAction(
            title: L10n.t("Open in \(name)", "用 \(name) 打开"),
            kind: .openWithApp(bundleID: bundleID),
            symbol: "arrow.up.forward.app",
            promoted: true
        )
    }

    static func availableShareServices(for file: URL? = nil) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: [file ?? representativeFileURL])
    }

    private static func sharingService(named name: String, for file: URL) -> NSSharingService? {
        availableShareServices(for: file).first { $0.title == name }
    }

    private static var representativeFileURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NDM Download.mp4")
    }
}
