import AppKit
import UniformTypeIdentifiers
import NDMCore

/// Visual chrome — cool neutrals (no warm “paper yellow”) + SF / file icons.
@MainActor
enum NDMChrome {
    /// Window + titlebar + sidebar share one fill so traffic-lights corner doesn’t seam.
    static var sidebarFill: NSColor {
        dynamic(
            light: srgb(0.945, 0.953, 0.969), // #F1F3F7
            dark: srgb(0.086, 0.094, 0.110)   // #16181C
        )
    }

    /// Titlebar and tool strip are subtly brighter than the navigation rail.
    static var toolbarSurface: NSColor {
        dynamic(
            light: srgb(0.977, 0.982, 0.992), // #F9FAFD
            dark: srgb(0.105, 0.112, 0.128)   // #1B1D21
        )
    }

    static var windowFill: NSColor { toolbarSurface }

    /// List / inspector only — slightly lifted so the main column reads as content.
    static var contentSurface: NSColor {
        dynamic(
            light: srgb(0.982, 0.985, 0.992), // #FAFBFD
            dark: srgb(0.118, 0.125, 0.141)   // #1E2024
        )
    }

    static var searchSurface: NSColor {
        dynamic(
            light: NSColor.white.withAlphaComponent(0.86),
            dark: NSColor.white.withAlphaComponent(0.07)
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

    /// List / option track (Design Suite `--track`).
    static var track: NSColor {
        dynamic(
            light: NSColor.black.withAlphaComponent(0.07),
            dark: NSColor.white.withAlphaComponent(0.09)
        )
    }

    /// Selected task row wash (Design Suite `--row-active`).
    static var rowActive: NSColor {
        accent.withAlphaComponent(0.10)
    }

    static var okSoft: NSColor {
        NSColor.systemGreen.withAlphaComponent(0.12)
    }

    static var dangerSoft: NSColor {
        NSColor.systemRed.withAlphaComponent(0.10)
    }

    /// Paint opaque window chrome so wallpaper tint can’t warm the UI.
    static func applyWindowChrome(_ window: NSWindow) {
        window.backgroundColor = windowFill
        window.isOpaque = true
    }

    /// Sheets / pickers — near-white paper (Design Suite `--surface`), not sidebar wash.
    static var sheetSurface: NSColor {
        dynamic(
            light: srgb(0.988, 0.990, 0.994), // #FCFCFD
            dark: srgb(0.141, 0.149, 0.165)   // #24262A
        )
    }

    static func applySheetChrome(_ window: NSWindow) {
        window.backgroundColor = sheetSurface
        window.isOpaque = true
    }

    /// Design Suite `.btn.main` — one confident accent action.
    static func styleMainButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .regular
        button.isBordered = true
        button.font = .systemFont(ofSize: 12.5, weight: .semibold)
        if #available(macOS 11.0, *) {
            button.bezelColor = accent
        }
    }

    /// Design Suite `.btn.ghost` — quiet secondary.
    static func styleGhostButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .regular
        button.isBordered = true
        button.font = .systemFont(ofSize: 12.5, weight: .medium)
    }

    /// Design Suite `.btn.danger` — soft red, not screaming.
    static func styleDangerButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .regular
        button.isBordered = true
        button.font = .systemFont(ofSize: 12.5, weight: .semibold)
        button.contentTintColor = .systemRed
        if #available(macOS 11.0, *) {
            button.bezelColor = dangerSoft
        }
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
        // This bucket mostly contains installers and app packages. A package
        // glyph is clearer than either the generic rounded `app` tile or `⌘`,
        // which reads as a keyboard command / terminal tool.
        case .application: return "shippingbox"
        case .image: return "photo"
        case .other: return "ellipsis.circle"
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

/// Appearance-correct rounded surface. Colors are resolved in `updateLayer()`,
/// which AppKit re-runs whenever the effective appearance flips — this is the
/// fix for "switched to Light but the panel stayed dark": never snapshot a
/// dynamic NSColor into `layer?.backgroundColor` at setup time.
class ChromeBox: NSView {
    var fill: NSColor? {
        didSet { needsDisplay = true }
    }
    var borderColor: NSColor? {
        didSet { needsDisplay = true }
    }
    var cornerRadius: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var borderWidth: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    init(fill: NSColor? = nil, borderColor: NSColor? = nil, cornerRadius: CGFloat = 0, borderWidth: CGFloat = 0) {
        self.fill = fill
        self.borderColor = borderColor
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        super.init(frame: .zero)
        wantsLayer = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill?.cgColor
        layer?.borderColor = borderColor?.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = borderWidth
    }
}

/// Stack view drawing an appearance-correct card behind its content.
final class CardStackView: NSStackView {
    var fill: NSColor? = NDMChrome.dockFill {
        didSet { needsDisplay = true }
    }
    var cardBorderColor: NSColor? = NDMChrome.hairline {
        didSet { needsDisplay = true }
    }
    var cornerRadius: CGFloat = 10 {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        wantsLayer = true
        layer?.backgroundColor = fill?.cgColor
        layer?.borderColor = cardBorderColor?.cgColor
        layer?.borderWidth = cardBorderColor == nil ? 0 : 1
        layer?.cornerRadius = cornerRadius
    }
}

/// Quiet Finder 4px accent progress — replaces chunky system NSProgressIndicator bars.
final class ThinProgressView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    var progress: Double = 0 {
        didSet {
            let clamped = min(1, max(0, progress))
            if clamped != progress { progress = clamped; return }
            updateFill(animated: window != nil)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        fillLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2
        fillLayer.bounds = bounds
        fillLayer.position = CGPoint(x: bounds.minX, y: bounds.midY)
        fillLayer.cornerRadius = bounds.height / 2
        fillLayer.transform = CATransform3DMakeScale(CGFloat(progress), 1, 1)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        trackLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        fillLayer.backgroundColor = NDMChrome.accent.cgColor
    }

    private func updateFill(animated: Bool) {
        guard bounds.width > 0 else { needsLayout = true; return }
        let target = CGFloat(progress)
        let current = (fillLayer.presentation()?.value(forKeyPath: "transform.scale.x") as? NSNumber)
            .map(CGFloat.init(truncating:))
            ?? (fillLayer.value(forKeyPath: "transform.scale.x") as? NSNumber)
                .map(CGFloat.init(truncating:))
            ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.transform = CATransform3DMakeScale(target, 1, 1)
        CATransaction.commit()
        guard animated, abs(target - current) > 0.001 else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = target >= current ? 0.24 : 0.12
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fillLayer.add(animation, forKey: "progress")
    }
}
