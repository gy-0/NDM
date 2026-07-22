import AppKit
import UniformTypeIdentifiers
import NDMCore

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
    }

    /// Window + titlebar + sidebar share one fill so traffic-lights corner doesn’t seam.
    /// Obsidian Cinema: the dark ramp is deep space blue-black, not system gray —
    /// covers and accent light are the bright objects on this canvas.
    static var sidebarFill: NSColor {
        dynamic(
            light: srgb(0.945, 0.953, 0.969), // #F1F3F7
            dark: srgb(0.039, 0.047, 0.067)   // #0A0C11
        )
    }

    /// Titlebar and tool strip are subtly brighter than the navigation rail.
    static var toolbarSurface: NSColor {
        dynamic(
            light: srgb(0.977, 0.982, 0.992), // #F9FAFD
            dark: srgb(0.059, 0.071, 0.098)   // #0F1219
        )
    }

    static var windowFill: NSColor { toolbarSurface }

    /// List / inspector only — slightly lifted so the main column reads as content.
    static var contentSurface: NSColor {
        dynamic(
            light: srgb(0.982, 0.985, 0.992), // #FAFBFD
            dark: srgb(0.071, 0.086, 0.118)   // #12161E
        )
    }

    static var searchSurface: NSColor {
        dynamic(
            light: NSColor.white.withAlphaComponent(0.86),
            dark: NSColor.white.withAlphaComponent(0.07)
        )
    }

    /// A hair brighter than `searchSurface` — the only focus feedback the
    /// search capsule gets. No ring, no accent-colored stroke.
    static var searchSurfaceFocused: NSColor {
        dynamic(
            light: NSColor.white.withAlphaComponent(0.98),
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
final class ThinProgressView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    var progress: Double = 0 {
        didSet {
            let clamped = min(1, max(0, progress))
            if clamped != progress { progress = clamped; return }
            updateAccessibilityValue()
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

    var isActive: Bool = false {
        didSet {
            guard oldValue != isActive else { return }
            if isActive {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.55
                pulse.duration = 1.2
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fillLayer.add(pulse, forKey: "breathe")
            } else {
                fillLayer.removeAnimation(forKey: "breathe")
                fillLayer.opacity = 1.0
            }
        }
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
        let percent = min(100, max(0, progress * 100))
        setAccessibilityValue(percent)
        setAccessibilityValueDescription(String(format: "%.0f%%", percent))
    }

    private var didCelebrate = false

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

        if target >= 1.0, !didCelebrate, current < 1.0 {
            didCelebrate = true
            let spring = CASpringAnimation(keyPath: "transform.scale.x")
            spring.fromValue = current
            spring.toValue = 1.0
            spring.mass = 1.0
            spring.stiffness = 340
            spring.damping = 22
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
            return
        }

        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = target >= current ? 0.24 : 0.12
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fillLayer.add(animation, forKey: "progress")
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
final class ProgressRingView: NSView {
    /// Off when a numeral sits inside the ring — the check would draw over it.
    var showsCheckmark = true
    private var targetProgress: CGFloat = 0
    private var displayedProgress: CGFloat = 0
    private var displayedCheck: CGFloat = 0
    private var hasCompleted = false
    private var fillColor: NSColor = NDMChrome.accent
    private var animTimer: Timer?

    var progress: Double = 0 {
        didSet {
            let clamped = CGFloat(min(1, max(0, progress)))
            guard abs(clamped - targetProgress) > 0.001 || (clamped >= 1 && !hasCompleted) else { return }
            targetProgress = clamped

            if targetProgress >= 1, !hasCompleted {
                hasCompleted = true
                startAnimation()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.fillColor = NDMChrome.accent
                    self?.burstConfetti()
                }
                return
            }

            if window != nil {
                startAnimation()
            } else {
                displayedProgress = targetProgress
                needsDisplay = true
            }
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

        // Fill arc
        if displayedProgress > 0.001 {
            ctx.setStrokeColor(fillColor.cgColor)
            let endAngle = -.pi / 2 + displayedProgress * 2 * .pi
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

    private func startAnimation() {
        guard animTimer == nil else { return }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        var dirty = false
        let ease: CGFloat = 0.15

        if abs(displayedProgress - targetProgress) > 0.001 {
            displayedProgress += (targetProgress - displayedProgress) * ease
            if abs(displayedProgress - targetProgress) < 0.002 {
                displayedProgress = targetProgress
            }
            dirty = true
        }

        if hasCompleted, showsCheckmark, displayedProgress >= 0.98, displayedCheck < 1 {
            displayedCheck += 0.04
            if displayedCheck > 1 { displayedCheck = 1 }
            dirty = true
        }

        if dirty {
            needsDisplay = true
        } else {
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
final class SpeedSparklineView: NSView {
    private let lineLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let peakLabel = NSTextField(labelWithString: "")
    private var samples: [Double] = []
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
        samples.append(bytesPerSecond)
        if samples.count > maxSamples { samples.removeFirst() }
        redraw()
    }

    func reset() {
        samples.removeAll()
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
        let ceiling = max(peak, 1)
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
