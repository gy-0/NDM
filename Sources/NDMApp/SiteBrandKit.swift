import AppKit
import NDMCore

/// How a third-party site mark should be rendered.
///
/// - `compactIcon`: glyph-only — lists, charts, sidebar chips, and other tight slots.
/// - `wordmark`: full brand lockup (icon + wordmark) — New Download Link Lens brand row.
enum SiteBrandPresentation: Equatable, Sendable {
    case compactIcon
    case wordmark
}

/// High-quality bundled site brand art (SVG) with a clear compact-vs-wordmark split.
///
/// Compact icons: Simple Icons (CC0). Wordmarks: Wikimedia Commons tracings of
/// official brand assets (YouTube / Bilibili / TikTok / Facebook), used only to
/// identify the linked service in-product.
@MainActor
enum SiteBrandKit {
    private static var cache: [String: NSImage] = [:]

    static func image(
        for source: SharedLinkResolution.Source,
        presentation: SiteBrandPresentation,
        appearance: NSAppearance? = nil
    ) -> NSImage? {
        guard source != .web else { return nil }
        let dark = prefersDark(appearance)
        let key = "\(source.rawValue).\(presentation).\(dark ? "dark" : "light")"
        if let cached = cache[key] { return cached }

        let loaded: NSImage?
        switch presentation {
        case .compactIcon:
            loaded = loadSVG(named: "\(source.rawValue)-icon").map {
                normalized($0, height: 64)
            }
        case .wordmark:
            loaded = wordmarkImage(for: source, dark: dark)
        }
        if let loaded {
            cache[key] = loaded
        }
        return loaded
    }

    static func displayName(for source: SharedLinkResolution.Source) -> String {
        switch source {
        case .youtube: return "YouTube"
        case .bilibili: return L10n.bilibiliName
        case .douyin: return L10n.douyinName
        case .xiaohongshu: return L10n.xiaohongshuName
        case .tiktok: return "TikTok"
        case .kuaishou: return L10n.t("Kuaishou", "快手")
        case .weibo: return L10n.t("Weibo", "微博")
        case .instagram: return "Instagram"
        case .x: return "X"
        case .facebook: return "Facebook"
        case .vimeo: return "Vimeo"
        case .twitch: return "Twitch"
        case .dailymotion: return "Dailymotion"
        case .web: return ""
        }
    }

    static func accentColor(for source: SharedLinkResolution.Source) -> NSColor {
        switch source {
        case .youtube:
            return NSColor(calibratedRed: 0.96, green: 0.12, blue: 0.16, alpha: 1)
        case .bilibili:
            return NSColor(calibratedRed: 0.02, green: 0.71, blue: 0.95, alpha: 1)
        case .douyin:
            return NSColor(calibratedRed: 0.15, green: 0.84, blue: 0.91, alpha: 1)
        case .xiaohongshu:
            return NSColor(calibratedRed: 0.96, green: 0.15, blue: 0.20, alpha: 1)
        case .tiktok:
            return NSColor(calibratedRed: 0.08, green: 0.79, blue: 0.86, alpha: 1)
        case .kuaishou:
            return NSColor(calibratedRed: 1.00, green: 0.43, blue: 0.12, alpha: 1)
        case .weibo:
            return NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.12, alpha: 1)
        case .instagram:
            return NSColor(calibratedRed: 0.82, green: 0.17, blue: 0.55, alpha: 1)
        case .x:
            return NSColor(calibratedWhite: 0.70, alpha: 1)
        case .facebook:
            return NSColor(calibratedRed: 0.12, green: 0.40, blue: 0.88, alpha: 1)
        case .vimeo:
            return NSColor(calibratedRed: 0.15, green: 0.65, blue: 0.91, alpha: 1)
        case .twitch:
            return NSColor(calibratedRed: 0.56, green: 0.33, blue: 0.93, alpha: 1)
        case .dailymotion:
            return NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.96, alpha: 1)
        case .web:
            return NDMChrome.accent
        }
    }

    static func fallbackSymbolName(for source: SharedLinkResolution.Source, isDirectFile: Bool) -> String {
        switch source {
        case .youtube: return "play.rectangle.fill"
        case .bilibili: return "play.tv.fill"
        case .douyin, .tiktok: return "music.note"
        case .xiaohongshu: return "bookmark.fill"
        case .kuaishou: return "camera.aperture"
        case .weibo: return "dot.radiowaves.left.and.right"
        case .instagram: return "camera.fill"
        case .x: return "bubble.left.and.bubble.right.fill"
        case .facebook: return "person.2.fill"
        case .vimeo: return "play.circle.fill"
        case .twitch: return "message.fill"
        case .dailymotion: return "play.square.fill"
        case .web: return isDirectFile ? "doc.fill" : "globe"
        }
    }

    // MARK: - Private

    private static func wordmarkImage(
        for source: SharedLinkResolution.Source,
        dark: Bool
    ) -> NSImage? {
        let base = "\(source.rawValue)-wordmark"
        if dark, let darkMark = loadSVG(named: "\(base)-dark") {
            return normalized(darkMark, height: 36)
        }
        if let mark = loadSVG(named: base) {
            return normalized(mark, height: 36)
        }
        // No dedicated wordmark SVG — compose glyph + official name.
        guard let icon = loadSVG(named: "\(source.rawValue)-icon").map({
            normalized($0, height: 32)
        }) else { return nil }
        return composedWordmark(
            icon: icon,
            title: displayName(for: source),
            dark: dark
        )
    }

    private static func composedWordmark(icon: NSImage, title: String, dark: Bool) -> NSImage {
        let height: CGFloat = 36
        let iconSide: CGFloat = 28
        let spacing: CGFloat = 10
        let textColor: NSColor = dark
            ? NSColor(calibratedWhite: 0.96, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: textColor,
        ]
        let titleSize = (title as NSString).size(withAttributes: attrs)
        let width = iconSide + spacing + ceil(titleSize.width)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let iconRect = NSRect(
                x: 0,
                y: (rect.height - iconSide) / 2,
                width: iconSide,
                height: iconSide
            )
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            let textOrigin = NSPoint(
                x: iconSide + spacing,
                y: (rect.height - titleSize.height) / 2
            )
            (title as NSString).draw(at: textOrigin, withAttributes: attrs)
            return true
        }
        return image
    }

    private static func loadSVG(named name: String) -> NSImage? {
        // `.process("Resources")` flattens `SiteBrands/` into the bundle root;
        // keep the subdirectory lookup for `.copy`-style layouts.
        let url =
            Bundle.module.url(forResource: name, withExtension: "svg")
            ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "SiteBrands")
        guard let url,
              let image = NSImage(contentsOf: url),
              image.isValid,
              image.size.width > 0,
              image.size.height > 0 else { return nil }
        return image
    }

    private static func normalized(_ image: NSImage, height: CGFloat) -> NSImage {
        let sourceSize = image.size
        guard sourceSize.height > 0, sourceSize.width > 0 else { return image }
        let aspect = sourceSize.width / sourceSize.height
        let size = NSSize(width: max(1, height * aspect), height: height)
        let rendered = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return rendered
    }

    private static func prefersDark(_ appearance: NSAppearance?) -> Bool {
        let resolved = appearance ?? NSApp.effectiveAppearance
        return resolved.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
