import AppKit
import ObjectiveC
import UniformTypeIdentifiers
import NDMCore

/// Views that cache accent into CALayers / tints (not just `draw` / `updateLayer`).
@MainActor
protocol AccentChromeRefreshing: AnyObject {
    func refreshAccentChrome()
}

private var ndmAccentBezelAssociationKey: UInt8 = 0

/// Visual chrome — cool neutrals (no warm “paper yellow”) + SF / file icons.
@MainActor
enum NDMChrome {
    static let accentDidChangeNotification = Notification.Name("NDMAccentThemeDidChange")
    private(set) static var accentTheme: AccentTheme = .classicBlue
    private(set) static var customAccentHex = "#2563EB"

    static func applyAccentTheme(_ theme: AccentTheme, customHex: String? = nil) {
        let normalizedCustom = normalizedHex(customHex) ?? customAccentHex
        guard accentTheme != theme || customAccentHex != normalizedCustom else { return }
        accentTheme = theme
        customAccentHex = normalizedCustom
        NotificationCenter.default.post(name: accentDidChangeNotification, object: nil)
        // Accent is a static token; AppKit will not invalidate layer-backed
        // controls that painted the previous color. Push a full chrome refresh
        // so toolbar New, progress fills, and accent bezels update immediately.
        propagateAccentRefresh()
    }

    /// Walk every open window and refresh accent-dependent chrome in place.
    static func propagateAccentRefresh() {
        for window in NSApp.windows {
            refreshAccent(in: window.contentView)
            if let toolbar = window.toolbar {
                for item in toolbar.items {
                    if let view = item.view {
                        refreshAccent(in: view)
                    }
                }
            }
        }
    }

    private static func refreshAccent(in root: NSView?) {
        guard let root else { return }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            view.needsDisplay = true
            if let refreshing = view as? AccentChromeRefreshing {
                refreshing.refreshAccentChrome()
            }
            if let button = view as? NSButton,
               objc_getAssociatedObject(button, &ndmAccentBezelAssociationKey) as? Bool == true {
                if #available(macOS 11.0, *) {
                    button.bezelColor = accent
                }
            }
            stack.append(contentsOf: view.subviews)
        }
    }

    /// Window + titlebar + sidebar share one fill so traffic-lights corner doesn’t seam.
    /// The rails recede so the list can be the subject. Light mode used to make
    /// all three panes the same #FAFBFD — "one seamless paper canvas" — which
    /// reads as a single flat sheet with no figure and no ground. Sampling the
    /// window found four identical values top to bottom. Dark mode always had
    /// this ramp (#0A0C11 rail vs #12161E content); light mode simply lost it.
    ///
    /// 2026-08 design-language pass: the light ramp tilts warm-neutral (R−B > 0),
    /// the way a warm lamp over the window would read — cool blue-grey paper is
    /// the exact "cold, hard" signal the previous direction measured and rejected.
    static var sidebarFill: NSColor {
        dynamic(
            light: srgb(0.957, 0.950, 0.941), // #F4F2F0 — recessed rail, warm paper
            dark: srgb(0.039, 0.047, 0.067)   // #0A0C11
        )
    }

    /// Painted over the sidebar's vibrancy view. Light: opaque paper so the
    /// window reads as one continuous sheet (the system "sidebar gray" is
    /// exactly the old-macOS look we are killing). Dark: fully clear — the
    /// Obsidian canvas keeps its behind-window glass.
    static var sidebarPaperOverlay: NSColor {
        dynamic(
            light: srgb(0.957, 0.950, 0.941),
            dark: .clear
        )
    }

    /// Titlebar and tool strip are subtly brighter than the navigation rail.
    /// Between the rail and the content: the tool strip belongs to the frame, but
    /// sits nearer the surface than the navigation does.
    static var toolbarSurface: NSColor {
        dynamic(
            light: srgb(0.976, 0.969, 0.960), // #F9F7F5 — warm tool strip
            dark: srgb(0.059, 0.071, 0.098)   // #0F1219
        )
    }

    static var windowFill: NSColor { toolbarSurface }

    /// List / inspector only — slightly lifted so the main column reads as content.
    /// The rail fill, for the inspector as well as the sidebar. Both are chrome
    /// *about* the content rather than the content itself, so the window reads as a
    /// bright sheet held in a recessed frame rather than as one undifferentiated
    /// plane.
    static var railSurface: NSColor { sidebarFill }

    /// The subject. Brightest thing in the window, so the eye lands on the list
    /// rather than on the chrome around it.
    static var contentSurface: NSColor {
        dynamic(
            light: srgb(1.0, 0.998, 0.994),   // #FFFFFE — warm white, not blue-white
            dark: srgb(0.071, 0.086, 0.118)   // #12161E
        )
    }

    static var searchSurface: NSColor {
        dynamic(
            light: srgb(1.0, 0.998, 0.994).withAlphaComponent(0.86),
            dark: NSColor.white.withAlphaComponent(0.07)
        )
    }

    /// A hair brighter than `searchSurface` — the only focus feedback the
    /// search capsule gets. No ring, no accent-colored stroke.
    static var searchSurfaceFocused: NSColor {
        dynamic(
            light: srgb(1.0, 0.998, 0.994).withAlphaComponent(0.98),
            dark: NSColor.white.withAlphaComponent(0.11)
        )
    }

    /// A restrained accent. It is reserved for primary actions, selection and
    /// progress; neutral surfaces remain the visual majority of the app.
    static var accent: NSColor {
        accent(for: accentTheme)
    }

    static func accent(for theme: AccentTheme) -> NSColor {
        switch theme {
        case .classicBlue:
            return dynamic(
                light: srgb(0.118, 0.365, 0.855), // #1E5DDA — original NDM blue, refined
                dark: srgb(0.420, 0.671, 1.0)     // #6BABFF — light source on the cinema canvas
            )
        case .indigo:
            return dynamic(
                light: srgb(0.310, 0.275, 0.898), // #4F46E5
                dark: srgb(0.506, 0.549, 0.973)   // #818CF8
            )
        case .graphite:
            return dynamic(
                light: srgb(0.278, 0.333, 0.412), // #475569
                dark: srgb(0.580, 0.639, 0.722)   // #94A3B8
            )
        case .jade:
            return dynamic(
                light: srgb(0.059, 0.463, 0.431), // #0F766E
                dark: srgb(0.369, 0.918, 0.831)   // #5EEAD4
            )
        case .violet:
            return dynamic(
                light: srgb(0.486, 0.227, 0.929), // #7C3AED
                dark: srgb(0.769, 0.710, 0.992)   // #C4B5FD
            )
        case .rose:
            return dynamic(
                light: srgb(0.745, 0.196, 0.388), // #BE3263
                dark: srgb(0.984, 0.447, 0.616)   // #FB729D
            )
        case .amber:
            return dynamic(
                light: srgb(0.718, 0.408, 0.035), // #B76809
                dark: srgb(0.961, 0.620, 0.184)   // #F59E2F
            )
        case .custom:
            return color(hex: customAccentHex) ?? srgb(0.118, 0.365, 0.855)
        }
    }

    static func accent(for theme: AccentTheme, customHex: String?) -> NSColor {
        theme == .custom
            ? (color(hex: customHex) ?? accent(for: .classicBlue))
            : accent(for: theme)
    }

    static func color(hex: String?) -> NSColor? {
        guard let normalized = normalizedHex(hex) else { return nil }
        let value = UInt32(normalized.dropFirst(), radix: 16) ?? 0
        return srgb(
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255
        )
    }

    static func hexString(for color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func normalizedHex(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if !value.hasPrefix("#") { value = "#" + value }
        guard value.count == 7,
              value.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
        return value.uppercased()
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

    /// List / option track (Design Suite `--track`). Also the standard
    /// hover wash for toolbar tools and chip controls.
    static var track: NSColor {
        dynamic(
            light: NSColor.black.withAlphaComponent(0.07),
            dark: NSColor.white.withAlphaComponent(0.09)
        )
    }

    /// One step denser than `track` — pressed state for flat chip controls.
    /// Keeps feedback tactile without a dramatic scale squash.
    static var controlPressed: NSColor {
        dynamic(
            light: NSColor.black.withAlphaComponent(0.11),
            dark: NSColor.white.withAlphaComponent(0.14)
        )
    }

    /// Ultra-light wash for inspector-rail text actions (icon + label, pipe
    /// separators). Must stay quieter than `track` so hover never reads as a
    /// gray card behind toolbar-style copy.
    static var railHover: NSColor {
        // Accent, not neutral. A grey wash behind a control is the "grey box" this
        // design language rules out, and it says nothing: grey is what a disabled
        // thing looks like. A whisper of the accent says *this responds*, and it
        // follows the user's accent theme for free.
        accentWash(light: 0.07, dark: 0.10)
    }

    /// A barely-there accent tint, for hover and pressed states.
    ///
    /// One helper rather than scattered `accent.withAlphaComponent(...)` so the
    /// whole app's feedback moves together when these are tuned.
    static func accentWash(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return accent.withAlphaComponent(isDark ? dark : light)
        }
    }

    /// Pressed step for rail text actions — one notch deeper than hover.
    static var railPressed: NSColor {
        accentWash(light: 0.13, dark: 0.17)
    }

    /// Soft accent wash for the primary rail action (Open / Pause / …).
    static var railAccentHover: NSColor {
        accent.withAlphaComponent(0.06)
    }

    /// Pressed accent wash for the primary rail action.
    static var railAccentPressed: NSColor {
        accent.withAlphaComponent(0.10)
    }

    // MARK: Action control metrics (flat 4–6 system)
    //
    // Rail text actions stay tight (radius 4) so hover never reads as a card.
    // Filled / outlined sheet controls share radius 6 — never half-height
    // capsules, never a one-off 8–9 that fights the rail.
    //
    // 2026-08 design-language pass: primary filled actions graduate to true
    // capsules (pill buttons). Rail text actions stay square-ish — the
    // "technical instrument" surface keeps its tight geometry while the
    // confident actions get the soft pill language from the Appllama reference.

    /// Flat text-rail hover pad radius.
    static let railCornerRadius: CGFloat = 4
    /// Filled primary + outlined secondary action radius.
    static let controlCornerRadius: CGFloat = 6
    /// Compact inspector / progress text-rail hit height.
    static let railActionHeight: CGFloat = 28
    /// Sheet action row height (completion / progress primaries).
    static let sheetActionHeight: CGFloat = 36
    /// Filled primary action pill height — capsules use half this as radius.
    static let primaryPillHeight: CGFloat = 32
    /// Filled primary actions are true capsules (radius = half height).
    static var primaryPillRadius: CGFloat { primaryPillHeight / 2 }

    /// Selected task row wash (Design Suite `--row-active`).
    static var rowActive: NSColor {
        accent.withAlphaComponent(0.10)
    }

    /// Pressed accent wash for primary flat chip actions.
    static var rowActivePressed: NSColor {
        accent.withAlphaComponent(0.16)
    }

    static var okSoft: NSColor {
        NSColor.systemGreen.withAlphaComponent(0.12)
    }

    static var dangerSoft: NSColor {
        NSColor.systemRed.withAlphaComponent(0.10)
    }

    /// Paint opaque window chrome so wallpaper tint can’t warm the UI.
    /// Build a spring in the units a designer actually reasons in.
    ///
    /// `CASpringAnimation` is parameterised by stiffness, damping and mass, which
    /// are three numbers with no independent meaning — you cannot look at
    /// `damping: 14` and know whether it will wobble. SwiftUI exposes the two that
    /// do mean something, and so does this:
    ///
    /// * `response` — how long one oscillation takes. Perceived speed.
    /// * `dampingFraction` — 1.0 stops dead, below 1.0 overshoots. Perceived life.
    ///
    /// The house values come from measurement rather than taste. Disassembling a
    /// reference app people describe as feeling good (see
    /// `docs/DESIGN-DIRECTION.md`) puts every one of its springs at
    /// response 0.28–0.53 with dampingFraction 0.78–0.86: fast, and overshooting
    /// exactly once. NDM's three hand-tuned springs converted to the same units
    /// were 0.391, 0.577 and 0.597 — all of them looser than anything in the
    /// reference, which is the arithmetic behind a bounce that read as a glitch.
    static func spring(
        keyPath: String,
        response: CGFloat = springResponse,
        dampingFraction: CGFloat = springDamping,
        mass: CGFloat = 1
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = mass
        // stiffness = m(2π/response)², damping = 2ζ√(km) — the standard inversion.
        let omega = (2 * CGFloat.pi) / max(response, 0.01)
        animation.stiffness = mass * omega * omega
        animation.damping = 2 * dampingFraction * sqrt(animation.stiffness * mass)
        return animation
    }

    /// One oscillation, in seconds. Everything in the app arrives at this speed.
    static let springResponse: CGFloat = 0.34
    /// Just under 1, so motion overshoots once and settles. Never a wobble.
    static let springDamping: CGFloat = 0.80

    static func applyWindowChrome(_ window: NSWindow) {
        window.backgroundColor = windowFill
        window.isOpaque = true
    }

    /// One-shot entrance: a quiet fade with a short upward settle, tuned to the
    /// house curve (`easeOut`, 0.08–0.25s) so new content lands instead of
    /// popping. Deliberately not a spring: an entrance is arrival, not a bounce,
    /// and a spring here would read as a glitch against the Hero morph.
    ///
    /// Reduce Motion turns the whole thing off — motion is a preference, not a
    /// requirement to read the interface.
    static func playEntrance(
        on view: NSView,
        offset: CGFloat = 7,
        duration: TimeInterval = 0.22
    ) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.opacity = 0
        layer.transform = CATransform3DMakeTranslation(0, offset, 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { [weak view] in
            guard let layer = view?.layer else { return }
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
        }
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Sheets / pickers — near-white paper (Design Suite `--surface`), not sidebar wash.
    static var sheetSurface: NSColor {
        dynamic(
            light: srgb(0.993, 0.990, 0.986), // #FDFCFB — warm paper sheet
            dark: srgb(0.098, 0.114, 0.153)   // #191D27
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
            objc_setAssociatedObject(
                button,
                &ndmAccentBezelAssociationKey,
                true,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
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
        case .paused: return "arrow.clockwise.circle"
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

    /// Extract the visually dominant color from an image via k=1 area-average
    /// on a tiny resample. Returns nil for grayscale-dominant images.
    static func dominantColor(from image: NSImage) -> NSColor? {
        let size = NSSize(width: 32, height: 32)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.bitmapData else { return nil }
        var totalR = 0.0, totalG = 0.0, totalB = 0.0, count = 0.0
        let stride = bitmap.bytesPerRow
        for y in 0..<32 {
            for x in 0..<32 {
                let offset = y * stride + x * 4
                let a = CGFloat(data[offset + 3]) / 255
                guard a > 0.3 else { continue }
                totalR += CGFloat(data[offset]) / 255
                totalG += CGFloat(data[offset + 1]) / 255
                totalB += CGFloat(data[offset + 2]) / 255
                count += 1
            }
        }
        guard count > 100 else { return nil }
        let r = totalR / count, g = totalG / count, b = totalB / count
        let maxC = max(r, g, b), minC = min(r, g, b)
        let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
        guard saturation > 0.08 else { return nil }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
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
final class ThinProgressView: NSView, AccentChromeRefreshing {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    /// Shared smoother key. When set, list / hero / window / inspector all
    /// chase the same display progress for a given download.
    private(set) var smoothTaskID: Int64?

    /// Fires whenever the smoothed display value moves (for percent labels).
    var onDisplayedProgressChange: ((Double) -> Void)?

    private(set) var displayedProgress: Double = 0

    var progress: Double = 0 {
        didSet {
            let clamped = min(1, max(0, progress))
            if clamped != progress { progress = clamped; return }
            publishTarget(clamped, reset: false)
            refreshActiveAnimation()
        }
    }

    private var observation: SmoothProgressCenter.ObservationToken?
    private var localTracker = SmoothProgressTracker()
    private var localTimer: Timer?
    private var localLastTick: TimeInterval = 0
    private var didCelebrate = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        fillLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(L10n.progress)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
        updateAccessibilityValue()
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observation?.cancel()
        localTimer?.invalidate()
    }

    /// Preferred entry for task-scoped UI: shares one chase across surfaces,
    /// and reseeds when the view switches to a different download.
    func setSmoothProgress(taskID: Int64, target: Double, complete: Bool = false) {
        let clamped = min(1, max(0, target))
        let switched = smoothTaskID != taskID
        if switched {
            observation?.cancel()
            observation = nil
            didCelebrate = false
            smoothTaskID = taskID
            stopLocalTimer()
            _ = SmoothProgressCenter.shared.setTarget(
                taskID: taskID,
                clamped,
                complete: complete,
                reset: true
            )
            observation = SmoothProgressCenter.shared.observe(taskID: taskID, seed: clamped) { [weak self] display in
                self?.applyDisplayedProgress(display)
            }
            applyDisplayedProgress(clamped)
        }
        let next = complete ? 1.0 : clamped
        if abs(progress - next) > 0.000_000_1 {
            progress = next
        } else {
            publishTarget(next, reset: false)
        }
    }

    func clearSmoothProgress() {
        observation?.cancel()
        observation = nil
        smoothTaskID = nil
        stopLocalTimer()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2
        fillLayer.bounds = bounds
        fillLayer.position = CGPoint(x: bounds.minX, y: bounds.midY)
        fillLayer.cornerRadius = bounds.height / 2
        fillLayer.transform = CATransform3DMakeScale(CGFloat(displayedProgress), 1, 1)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    func refreshAccentChrome() {
        refreshColors()
    }

    var isActive: Bool = false {
        didSet {
            guard oldValue != isActive else { return }
            refreshActiveAnimation()
        }
    }

    private func publishTarget(_ target: Double, reset: Bool) {
        let complete = target >= 0.999
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if let smoothTaskID {
                _ = SmoothProgressCenter.shared.setTarget(
                    taskID: smoothTaskID,
                    target,
                    complete: complete,
                    reset: true
                )
            } else {
                localTracker.reset(to: target)
                stopLocalTimer()
            }
            applyDisplayedProgress(target)
            return
        }

        if let smoothTaskID {
            _ = SmoothProgressCenter.shared.setTarget(
                taskID: smoothTaskID,
                target,
                complete: complete,
                reset: reset
            )
            if observation == nil {
                observation = SmoothProgressCenter.shared.observe(taskID: smoothTaskID, seed: target) { [weak self] display in
                    self?.applyDisplayedProgress(display)
                }
            }
        } else {
            localTracker.setTarget(target, complete: complete)
            if !localTracker.isSettled {
                ensureLocalTimer()
            } else {
                applyDisplayedProgress(localTracker.display)
            }
        }
    }

    private func ensureLocalTimer() {
        guard localTimer == nil else { return }
        localLastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickLocal()
        }
        RunLoop.main.add(timer, forMode: .common)
        localTimer = timer
    }

    private func stopLocalTimer() {
        localTimer?.invalidate()
        localTimer = nil
    }

    private func tickLocal() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, max(0, now - localLastTick))
        localLastTick = now
        let value = localTracker.advance(by: dt)
        applyDisplayedProgress(value)
        if localTracker.isSettled {
            stopLocalTimer()
        }
    }

    private func applyDisplayedProgress(_ value: Double) {
        let clamped = min(1, max(0, value))
        let previous = displayedProgress
        guard abs(clamped - previous) > 0.000_05 || (clamped >= 0.999 && !didCelebrate) else {
            return
        }
        displayedProgress = clamped
        updateAccessibilityValue()
        updateFill(from: previous, to: clamped)
        onDisplayedProgressChange?(clamped)
    }

    private func refreshActiveAnimation() {
        guard isActive,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            fillLayer.removeAnimation(forKey: "breathe")
            fillLayer.opacity = 1.0
            return
        }
        guard fillLayer.animation(forKey: "breathe") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.55
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fillLayer.add(pulse, forKey: "breathe")
    }

    private func refreshColors() {
        trackLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        fillLayer.backgroundColor = NDMChrome.accent.cgColor
        // Obsidian Cinema: on the dark canvas the accent fill is a light
        // source — a soft bloom, not a flat bar. Light mode stays matte.
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        fillLayer.shadowColor = NDMChrome.accent.cgColor
        fillLayer.shadowOpacity = isDark ? 0.6 : 0
        fillLayer.shadowRadius = 5
        fillLayer.shadowOffset = .zero
    }

    private func updateAccessibilityValue() {
        let percent = min(100, max(0, displayedProgress * 100))
        setAccessibilityValue(percent)
        setAccessibilityValueDescription(String(format: "%.0f%%", percent))
    }

    private func updateFill(from previous: Double, to target: Double) {
        guard bounds.width > 0 else { needsLayout = true; return }
        let visibleScale = fillLayer.presentation()?.transform.m11 ?? CGFloat(previous)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.removeAnimation(forKey: "progress")
        fillLayer.transform = CATransform3DMakeScale(CGFloat(target), 1, 1)
        CATransaction.commit()

        // Amicro ProgressIndicator port. The source component follows progress
        // with useSpring(stiffness: 100, damping: 30, restDelta: 0.001).
        // Continue from the presentation layer so frequent engine samples remain
        // interruptible instead of snapping back to the previous model value.
        if window != nil,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           abs(CGFloat(target) - visibleScale) > 0.000_5 {
            let spring = CASpringAnimation(keyPath: "transform.scale.x")
            spring.fromValue = visibleScale
            spring.toValue = CGFloat(target)
            spring.mass = 1
            spring.stiffness = 100
            spring.damping = 30
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            fillLayer.add(spring, forKey: "progress")
        }

        guard target >= 0.999,
              !didCelebrate,
              previous < 0.999,
              window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return
        }
        didCelebrate = true
        let spring = NDMChrome.spring(keyPath: "transform.scale.x")
        spring.fromValue = previous
        spring.toValue = 1.0
        spring.initialVelocity = 8
        spring.duration = spring.settlingDuration
        fillLayer.add(spring, forKey: "progress")

        let flash = CABasicAnimation(keyPath: "backgroundColor")
        flash.fromValue = NDMChrome.accent.cgColor
        flash.toValue = NDMChrome.accent.withAlphaComponent(0.7).cgColor
        flash.duration = 0.3
        flash.autoreverses = true
        flash.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fillLayer.add(flash, forKey: "completionFlash")
    }
}

/// Radial ambient glow derived from cover art's dominant color.
/// Paints a soft halo behind the hero preview in the inspector.
final class AtmosphereView: NSView {
    private let glowLayer = CAGradientLayer()
    private var currentColor: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.3)
        glowLayer.endPoint = CGPoint(x: 1, y: 1)
        glowLayer.locations = [0, 0.55, 1]
        layer?.addSublayer(glowLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.frame = bounds
        CATransaction.commit()
    }

    func setAtmosphere(_ color: NSColor?, animated: Bool = true) {
        guard currentColor != color else { return }
        currentColor = color
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alpha: CGFloat = isDark ? 0.14 : 0.08
        let clear = NSColor.clear.cgColor
        if let color {
            let glow = color.withAlphaComponent(alpha).cgColor
            let mid = color.withAlphaComponent(alpha * 0.4).cgColor
            if animated {
                let anim = CABasicAnimation(keyPath: "colors")
                anim.fromValue = glowLayer.colors
                anim.toValue = [glow, mid, clear]
                anim.duration = 0.5
                anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                glowLayer.add(anim, forKey: "atmosphere")
            }
            glowLayer.colors = [glow, mid, clear]
        } else {
            if animated {
                let anim = CABasicAnimation(keyPath: "colors")
                anim.fromValue = glowLayer.colors
                anim.toValue = [clear, clear, clear]
                anim.duration = 0.35
                anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                glowLayer.add(anim, forKey: "atmosphere")
            }
            glowLayer.colors = [clear, clear, clear]
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let saved = currentColor
        currentColor = nil
        setAtmosphere(saved, animated: false)
    }
}

/// Circular arc progress indicator. A thin track + accent stroke.
final class ProgressRingView: NSView, AccentChromeRefreshing {
    /// Off when a numeral sits inside the ring — the check would draw over it.
    var showsCheckmark = true

    /// Indeterminate "working" mode for byte-less phases (merging, embedding
    /// subtitles, finalizing). A spinning arc says "active, not frozen" —
    /// far better than a progress bar stuck at 98% with 0 KB/s.
    var isWorking: Bool = false {
        didSet {
            guard oldValue != isWorking else { return }
            if isWorking { startAnimation() }
            needsDisplay = true
        }
    }
    private var workingAngle: CGFloat = -.pi / 2

    private var progressTracker = SmoothProgressTracker()
    private var displayedCheck: CGFloat = 0
    private var hasCompleted = false
    private var fillColor: NSColor = NDMChrome.accent
    private var animTimer: Timer?
    private var lastTickUptime: TimeInterval = 0
    /// Optional shared smoother key — keep in sync with ThinProgressView / percent labels.
    var smoothTaskID: Int64? {
        didSet {
            guard oldValue != smoothTaskID else { return }
            observation?.cancel()
            observation = nil
            if let smoothTaskID {
                observation = SmoothProgressCenter.shared.observe(taskID: smoothTaskID, seed: progress) { [weak self] display in
                    self?.applySharedDisplay(display)
                }
            }
        }
    }
    private var observation: SmoothProgressCenter.ObservationToken?
    var onDisplayedProgressChange: ((Double) -> Void)?

    var progress: Double = 0 {
        didSet {
            let clamped = min(1, max(0, progress))
            if clamped != progress { progress = clamped; return }

            if let smoothTaskID {
                _ = SmoothProgressCenter.shared.setTarget(
                    taskID: smoothTaskID,
                    clamped,
                    complete: clamped >= 0.999
                )
                if observation == nil {
                    observation = SmoothProgressCenter.shared.observe(taskID: smoothTaskID, seed: clamped) { [weak self] display in
                        self?.applySharedDisplay(display)
                    }
                }
            } else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window == nil {
                progressTracker.reset(to: clamped)
                onDisplayedProgressChange?(clamped)
                needsDisplay = true
            } else {
                progressTracker.setTarget(clamped, complete: clamped >= 0.999)
                startAnimation()
            }

            if clamped >= 1, !hasCompleted {
                hasCompleted = true
                startAnimation()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.fillColor = NDMChrome.accent
                    self?.burstConfetti()
                }
            }
        }
    }

    private func applySharedDisplay(_ display: Double) {
        progressTracker.reset(to: display)
        onDisplayedProgressChange?(display)
        needsDisplay = true
        if hasCompleted, showsCheckmark, display >= 0.98, displayedCheck < 1 {
            startAnimation()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 3
        let lineWidth: CGFloat = 3.5

        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)

        // Track ring
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.12).cgColor)
        ctx.addArc(center: center, radius: radius,
                   startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        ctx.strokePath()

        // Indeterminate spinner for byte-less post-processing phases.
        if isWorking, !hasCompleted {
            ctx.setStrokeColor(fillColor.cgColor)
            let sweep: CGFloat = .pi * 0.55
            ctx.addArc(center: center, radius: radius,
                       startAngle: workingAngle, endAngle: workingAngle + sweep,
                       clockwise: false)
            ctx.strokePath()
        } else if progressTracker.display > 0.001 {
            // Fill arc
            ctx.setStrokeColor(fillColor.cgColor)
            let endAngle = -.pi / 2 + CGFloat(progressTracker.display) * 2 * .pi
            ctx.addArc(center: center, radius: radius,
                       startAngle: -.pi / 2, endAngle: endAngle, clockwise: false)
            ctx.strokePath()
        }

        // Checkmark
        if displayedCheck > 0.01 {
            let size = radius * 0.38
            let pts: [(CGFloat, CGFloat)] = [
                (center.x - size * 0.55, center.y + size * 0.05),
                (center.x - size * 0.1, center.y + size * 0.45),
                (center.x + size * 0.55, center.y - size * 0.35),
            ]
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.5)
            ctx.setLineJoin(.round)

            let totalLen: CGFloat = 2.0
            var drawn: CGFloat = 0
            let target = displayedCheck * totalLen

            ctx.beginPath()
            ctx.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
            for i in 1..<pts.count {
                let dx = pts[i].0 - pts[i - 1].0
                let dy = pts[i].1 - pts[i - 1].1
                let segLen: CGFloat = 1.0
                let remain = target - drawn
                if remain <= 0 { break }
                if remain >= segLen {
                    ctx.addLine(to: CGPoint(x: pts[i].0, y: pts[i].1))
                } else {
                    let t = remain / segLen
                    ctx.addLine(to: CGPoint(
                        x: pts[i - 1].0 + dx * t,
                        y: pts[i - 1].1 + dy * t
                    ))
                }
                drawn += segLen
            }
            ctx.strokePath()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func refreshAccentChrome() {
        fillColor = NDMChrome.accent
        needsDisplay = true
    }

    private func startAnimation() {
        guard animTimer == nil else { return }
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    private func tick() {
        var dirty = false
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, max(0, now - lastTickUptime))
        lastTickUptime = now

        // Shared-center bindings are driven externally; only advance the
        // local tracker when this ring owns its own chase.
        if smoothTaskID == nil, !progressTracker.isSettled {
            let value = progressTracker.advance(by: dt)
            onDisplayedProgressChange?(value)
            dirty = true
        }

        if isWorking, !hasCompleted {
            // ~1.1 rev/sec; wraps to stay in range.
            workingAngle += 0.12
            if workingAngle > .pi * 4 { workingAngle -= .pi * 4 }
            dirty = true
        }

        if hasCompleted, showsCheckmark, progressTracker.display >= 0.98, displayedCheck < 1 {
            displayedCheck += 0.04
            if displayedCheck > 1 { displayedCheck = 1 }
            dirty = true
        }

        if dirty {
            needsDisplay = true
            return
        }

        let chasing = smoothTaskID == nil && !progressTracker.isSettled
        let checking = hasCompleted && showsCheckmark && displayedCheck < 1
        if !chasing && !checking && !(isWorking && !hasCompleted) {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    private func burstConfetti() {
        wantsLayer = true
        guard let root = layer else { return }
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        emitter.emitterSize = CGSize(width: 4, height: 4)
        emitter.emitterShape = .point
        emitter.renderMode = .additive

        let colors: [CGColor] = [
            NDMChrome.accent.cgColor,
            NDMChrome.accent.withAlphaComponent(0.7).cgColor,
            NSColor.systemYellow.cgColor,
            NSColor.systemCyan.cgColor,
            NSColor.white.cgColor,
        ]

        emitter.emitterCells = colors.map { color in
            let cell = CAEmitterCell()
            cell.birthRate = 30
            cell.lifetime = 0.8
            cell.velocity = 120
            cell.velocityRange = 40
            cell.emissionRange = .pi * 2
            cell.scale = 0.04
            cell.scaleRange = 0.02
            cell.alphaSpeed = -1.2
            cell.color = color
            cell.contents = Self.confettiDot
            return cell
        }

        root.addSublayer(emitter)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            emitter.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            emitter.removeFromSuperlayer()
        }
    }

    private static let confettiDot: CGImage? = {
        let size = 8
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }()
}

/// Live download speed sparkline — a smooth bezier curve with accent fill.
final class SpeedSparklineView: NSView, AccentChromeRefreshing {
    private let lineLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let peakLabel = NSTextField(labelWithString: "")
    private var samples: [Double] = []
    private var smoothed: Double = 0
    /// Sticky Y ceiling: snaps up to a new peak instantly, decays slowly.
    /// Without it every sample rescales the whole chart and the curve
    /// "breathes" — unreadable as a trend.
    private var ceiling: Double = 0
    private let maxSamples = 60

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        lineLayer.fillColor = nil
        lineLayer.lineCap = .round
        lineLayer.lineJoin = .round
        fillLayer.strokeColor = nil
        fillLayer.lineJoin = .round
        root.addSublayer(fillLayer)
        root.addSublayer(lineLayer)
        self.layer = root
        self.wantsLayer = true

        peakLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        peakLabel.textColor = .tertiaryLabelColor
        peakLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(peakLabel)
        NSLayoutConstraint.activate([
            peakLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            peakLabel.topAnchor.constraint(equalTo: topAnchor, constant: 1),
        ])
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func addSample(_ bytesPerSecond: Double) {
        // Light exponential smoothing: the curve should show the trend, not
        // reproduce every scheduler hiccup as a spike.
        smoothed = smoothed == 0 ? bytesPerSecond : smoothed * 0.65 + bytesPerSecond * 0.35
        samples.append(smoothed)
        if samples.count > maxSamples { samples.removeFirst() }
        redraw()
    }

    func reset() {
        samples.removeAll()
        smoothed = 0
        ceiling = 0
        lineLayer.path = nil
        fillLayer.path = nil
        peakLabel.stringValue = ""
    }

    override func layout() {
        super.layout()
        redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    func refreshAccentChrome() {
        refreshColors()
    }

    private func refreshColors() {
        lineLayer.strokeColor = NDMChrome.accent.cgColor
        lineLayer.lineWidth = 1.5
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        fillLayer.fillColor = NDMChrome.accent.withAlphaComponent(isDark ? 0.10 : 0.06).cgColor
    }

    private func redraw() {
        guard bounds.width > 0, samples.count >= 2 else { return }
        let peak = samples.max() ?? 0
        // All-zero samples would render as a flat line on the floor plus a
        // meaningless "Peak —" tag; show nothing until there is real traffic.
        guard peak > 0 else {
            lineLayer.path = nil
            fillLayer.path = nil
            peakLabel.stringValue = ""
            return
        }
        // Rise instantly to a new peak; give back headroom at ~1%/sample.
        ceiling = max(peak, ceiling * 0.99, 1)
        let ceiling = self.ceiling
        let w = bounds.width
        let h = bounds.height - 2
        let step = w / CGFloat(maxSamples - 1)
        let offset = CGFloat(maxSamples - samples.count) * step

        let line = CGMutablePath()
        let fill = CGMutablePath()

        // Bottom-left origin (non-flipped layer): faster = higher on screen,
        // fill hangs below the curve. The old formula drew the whole chart
        // upside down.
        func y(for value: Double) -> CGFloat {
            1 + CGFloat(value / ceiling) * (h - 4)
        }

        let firstY = y(for: samples[0])
        line.move(to: CGPoint(x: offset, y: firstY))
        fill.move(to: CGPoint(x: offset, y: -1))
        fill.addLine(to: CGPoint(x: offset, y: firstY))

        for i in 1..<samples.count {
            let x = offset + CGFloat(i) * step
            let py = y(for: samples[i])
            let prevX = offset + CGFloat(i - 1) * step
            let prevY = y(for: samples[i - 1])
            let midX = (prevX + x) / 2
            line.addCurve(to: CGPoint(x: x, y: py),
                          control1: CGPoint(x: midX, y: prevY),
                          control2: CGPoint(x: midX, y: py))
            fill.addCurve(to: CGPoint(x: x, y: py),
                          control1: CGPoint(x: midX, y: prevY),
                          control2: CGPoint(x: midX, y: py))
        }

        let lastX = offset + CGFloat(samples.count - 1) * step
        fill.addLine(to: CGPoint(x: lastX, y: -1))
        fill.closeSubpath()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineLayer.path = line
        fillLayer.path = fill
        CATransaction.commit()

        peakLabel.stringValue = "Peak " + TaskPresentationFormatting.speed(peak, status: .downloading)
    }
}
