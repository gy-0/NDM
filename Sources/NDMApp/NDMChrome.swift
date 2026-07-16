import AppKit
import UniformTypeIdentifiers
import NDMCore

/// Visual chrome — cool neutrals (no warm “paper yellow”) + SF / file icons.
@MainActor
enum NDMChrome {
    /// Window + titlebar + sidebar share one fill so traffic-lights corner doesn’t seam.
    static var sidebarFill: NSColor {
        dynamic(
            light: srgb(0.910, 0.922, 0.941), // #E8EBF0
            dark: srgb(0.086, 0.094, 0.110)   // #16181C
        )
    }

    /// Alias — must match sidebarFill (transparent titlebar reveals this under the lights).
    static var windowFill: NSColor { sidebarFill }

    /// List / inspector only — slightly lifted so the main column reads as content.
    static var contentSurface: NSColor {
        dynamic(
            light: srgb(0.965, 0.969, 0.980), // #F6F7FA
            dark: srgb(0.118, 0.125, 0.141)   // #1E2024
        )
    }

    /// Accent — clean blue, same family as Quiet Finder (not dusty teal/olive).
    static var accent: NSColor {
        dynamic(
            light: srgb(0.145, 0.388, 0.922), // #2563EB
            dark: srgb(0.380, 0.647, 1.0)     // #61A5FF
        )
    }

    static var hairline: NSColor {
        dynamic(
            light: NSColor.black.withAlphaComponent(0.08),
            dark: NSColor.white.withAlphaComponent(0.10)
        )
    }

    static var dockFill: NSColor {
        dynamic(
            light: NSColor.black.withAlphaComponent(0.035),
            dark: NSColor.white.withAlphaComponent(0.06)
        )
    }

    /// Paint opaque window chrome so wallpaper tint can’t warm the UI.
    static func applyWindowChrome(_ window: NSWindow) {
        window.backgroundColor = windowFill
        window.isOpaque = true
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .line
        }
    }

    static func applyLayerFill(_ view: NSView, _ color: NSColor) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
    }

    static func symbol(
        _ name: String,
        pointSize: CGFloat = 13,
        weight: NSFont.Weight = .medium
    ) -> NSImage? {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return base?.withSymbolConfiguration(config)
    }

    /// Finder-style document icon from filename extension.
    static func fileIcon(filename: String, pointSize: CGFloat = 36) -> NSImage {
        let ext = (filename as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: pointSize, height: pointSize)
        copy.isTemplate = false
        return copy
    }

    static func sidebarSymbolName(for filter: SidebarFilter) -> String {
        switch filter {
        case .all: return "tray.full"
        case .active: return "arrow.down.circle"
        case .queued: return "clock"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .video: return "film"
        case .audio: return "music.note"
        case .document: return "doc.text"
        case .compressed: return "archivebox"
        case .application: return "app"
        case .image: return "photo"
        }
    }

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

extension NSMenuItem {
    @MainActor
    func ndmSymbol(_ name: String) {
        image = NDMChrome.symbol(name, pointSize: 13, weight: .regular)
    }
}
