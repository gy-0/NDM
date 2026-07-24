import AppKit

/// One atomic clipboard path for every "Copy URL" surface.
///
/// `setString` after a separate `clearContents` can fail while the pasteboard
/// server is changing ownership. A pasteboard item writes the plain-text and
/// URL representations together, and the read-back keeps the UI from claiming
/// success when nothing was actually committed.
@MainActor
enum DownloadClipboard {
    @discardableResult
    static func copy(_ rawURL: String, to pasteboard: NSPasteboard = .general) -> Bool {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }

        for _ in 0..<2 {
            let item = NSPasteboardItem()
            item.setString(value, forType: .string)
            if let url = URL(string: value), url.scheme != nil {
                item.setString(value, forType: .URL)
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { continue }
            if pasteboard.string(forType: .string) == value
                || pasteboard.string(forType: .URL) == value {
                return true
            }
        }
        return false
    }
}
