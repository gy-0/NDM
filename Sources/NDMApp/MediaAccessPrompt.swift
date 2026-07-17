import AppKit
import NDMCore
import NDMEngine

/// Converts restricted-site access into a normal, guided macOS flow. No
/// account credentials are collected; the resolver reads only the existing
/// site access state from the browser the user explicitly selects.
@MainActor
enum MediaAccessPrompt {
    private struct BrowserChoice {
        var title: String
        var identifier: String
        var applicationPath: String
    }

    static func choose(parentWindow: NSWindow?) async -> YtDlpCookieSource? {
        let choices = installedBrowsers()
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        popup.addItems(withTitles: choices.map(\.title))

        let hint = NSTextField(wrappingLabelWithString: L10n.mediaAccessHint)
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 300

        let accessory = NSStackView(views: [popup, hint])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 300, height: 64)

        let alert = NSAlert()
        alert.messageText = L10n.mediaAccessTitle
        alert.informativeText = L10n.mediaAccessBody
        alert.alertStyle = .informational
        alert.accessoryView = accessory
        alert.addButton(withTitle: L10n.mediaAccessUseBrowser)
        alert.addButton(withTitle: L10n.mediaAccessChooseFile)
        alert.addButton(withTitle: L10n.cancel)

        let response = await present(alert, on: parentWindow)
        if response == .alertFirstButtonReturn,
           choices.indices.contains(popup.indexOfSelectedItem) {
            return .browser(choices[popup.indexOfSelectedItem].identifier)
        }
        guard response == .alertSecondButtonReturn else { return nil }

        let panel = NSOpenPanel()
        panel.title = L10n.mediaAccessFileTitle
        panel.prompt = L10n.mediaAccessImport
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        let result = await panel.begin()
        guard result == .OK, let url = panel.url else { return nil }
        return .file(url.path)
    }

    private static func present(_ alert: NSAlert, on parent: NSWindow?) async -> NSApplication.ModalResponse {
        if let parent {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
            }
        }
        return alert.runModal()
    }

    private static func installedBrowsers() -> [BrowserChoice] {
        let candidates = [
            BrowserChoice(title: "Safari", identifier: "safari", applicationPath: "/Applications/Safari.app"),
            BrowserChoice(title: "Google Chrome", identifier: "chrome", applicationPath: "/Applications/Google Chrome.app"),
            BrowserChoice(title: "Firefox", identifier: "firefox", applicationPath: "/Applications/Firefox.app"),
            BrowserChoice(title: "Microsoft Edge", identifier: "edge", applicationPath: "/Applications/Microsoft Edge.app"),
            BrowserChoice(title: "Brave", identifier: "brave", applicationPath: "/Applications/Brave Browser.app"),
        ]
        let installed = candidates.filter {
            FileManager.default.fileExists(atPath: $0.applicationPath)
        }
        return installed.isEmpty ? [candidates[0]] : installed
    }
}
