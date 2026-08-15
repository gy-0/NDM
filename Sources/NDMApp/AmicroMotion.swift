import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore

@MainActor
enum AmicroReveal {
    /// `word-reveal` / `fade-up`: opacity 0 → 1, y -15 → 0, scale 0.9 → 1,
    /// staggered by 40 ms with the source cubic.
    static func play(
        _ views: [NSView],
        stagger: TimeInterval = 0.04,
        duration: TimeInterval = 0.5,
        offsetY: CGFloat = -15,
        scale: CGFloat = 0.9
    ) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            views.forEach { $0.alphaValue = 1 }
            return
        }
        let timing = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
        for (index, view) in views.enumerated() {
            view.wantsLayer = true
            view.alphaValue = 0
            view.layer?.setAffineTransform(
                CGAffineTransform(translationX: 0, y: offsetY).scaledBy(x: scale, y: scale)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * stagger) { [weak view] in
                guard let view else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    context.timingFunction = timing
                    context.allowsImplicitAnimation = true
                    view.animator().alphaValue = 1
                    view.layer?.setAffineTransform(.identity)
                }
            }
        }
    }
}

@MainActor
enum AmicroTextMorph {
    /// Native `text-morph`: old text leaves upward while the replacement
    /// arrives from below over 300 ms. Repeated identical values stay still.
    static func set(_ text: String, on label: NSTextField) {
        guard label.stringValue != text else { return }
        guard label.window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            label.stringValue = text
            return
        }
        label.wantsLayer = true
        let transition = CATransition()
        transition.type = .push
        transition.subtype = .fromTop
        transition.duration = 0.30
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        label.layer?.add(transition, forKey: "amicroTextMorph")
        label.stringValue = text
    }
}

/// Determinate native port of Amicro `app-icon-load`. The source demo loops a
/// fake 2 s ring; NDM binds strokeEnd to real bytes so this remains trustworthy.
@MainActor
final class AmicroProgressRingView: NSView, AccentChromeRefreshing {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private var progress: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        for ring in [track, fill] {
            ring.fillColor = NSColor.clear.cgColor
            ring.lineWidth = 4
            ring.lineCap = .round
            layer?.addSublayer(ring)
        }
        fill.strokeEnd = 0
        refreshAccentChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let side = max(0, min(bounds.width, bounds.height) - 6)
        let rect = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        let path = CGPath(ellipseIn: rect, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        fill.frame = bounds
        track.path = path
        fill.path = path
        CATransaction.commit()
    }

    func setProgress(_ value: Double, animated: Bool = true) {
        let target = CGFloat(min(1, max(0, value)))
        guard abs(target - progress) > 0.000_1 else { return }
        let visible = (fill.presentation()?.value(forKeyPath: "strokeEnd") as? NSNumber)
            .map(CGFloat.init(truncating:)) ?? progress
        progress = target
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.strokeEnd = target
        CATransaction.commit()
        guard animated,
              window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            fill.removeAnimation(forKey: "amicroRealProgress")
            return
        }
        let spring = CASpringAnimation(keyPath: "strokeEnd")
        spring.mass = 0.1
        spring.stiffness = 100
        spring.damping = 20
        spring.fromValue = visible
        spring.toValue = target
        spring.duration = spring.settlingDuration
        fill.add(spring, forKey: "amicroRealProgress")
    }

    func refreshAccentChrome() {
        track.strokeColor = NDMChrome.track.cgColor
        fill.strokeColor = NDMChrome.accent.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Native `ripple-effect`: center action plus three 2.2 s expanding rings,
/// staggered by 0.7 s. Used by Paste Anything rather than as decorative chrome.
@MainActor
final class AmicroRippleIconView: NSView, AccentChromeRefreshing {
    private let centerLayer = CALayer()
    private let iconView = NSImageView()
    private var rings: [CAShapeLayer] = []

    init(symbolName: String = "arrow.down.to.line") {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)

        centerLayer.cornerRadius = 26
        layer?.addSublayer(centerLayer)
        for _ in 0..<3 {
            let ring = CAShapeLayer()
            ring.fillColor = NSColor.clear.cgColor
            ring.lineWidth = 1.25
            layer?.insertSublayer(ring, below: centerLayer)
            rings.append(ring)
        }

        iconView.image = NDMChrome.symbol(symbolName, pointSize: 22, weight: .semibold)
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityElement(false)
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
        ])
        refreshAccentChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 82, height: 82) }

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        centerLayer.bounds = CGRect(x: 0, y: 0, width: 52, height: 52)
        centerLayer.position = center
        for ring in rings {
            ring.bounds = CGRect(x: 0, y: 0, width: 52, height: 52)
            ring.position = center
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stop() : start()
    }

    func refreshAccentChrome() {
        centerLayer.backgroundColor = NDMChrome.accent.cgColor
        rings.forEach { $0.strokeColor = NDMChrome.accent.withAlphaComponent(0.48).cgColor }
    }

    private func start() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for (index, ring) in rings.enumerated() {
            guard ring.animation(forKey: "amicroRipple") == nil else { continue }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.3
            scale.toValue = 1.6
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.8
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 2.2
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.7
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(group, forKey: "amicroRipple")
        }
    }

    private func stop() {
        rings.forEach { $0.removeAnimation(forKey: "amicroRipple") }
    }
}

/// Native AppKit ports of the motion primitives from
/// Subhan-code/Amicro--Micro-transitions- (MIT).
///
/// The source IconSwap uses AnimatePresence with opacity 0→1,
/// scale 0.25→1 and blur 4→0 over a 0.3s no-bounce spring. We preserve those
/// visual parameters while rendering SF Symbols through layer-backed NSImageViews.
@MainActor
final class AmicroIconSwapView: NSView {
    private var currentView: NSImageView?
    private var transientViews: [NSImageView] = []
    private var symbolName = ""
    private var pointSize: CGFloat = 13
    private var weight: NSFont.Weight = .medium
    var tintColor: NSColor = .labelColor {
        didSet {
            currentView?.contentTintColor = tintColor
            transientViews.forEach { $0.contentTintColor = tintColor }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setSymbol(
        _ name: String,
        pointSize: CGFloat = 13,
        weight: NSFont.Weight = .medium,
        animated: Bool = true
    ) {
        guard name != symbolName || pointSize != self.pointSize || weight != self.weight else { return }
        symbolName = name
        self.pointSize = pointSize
        self.weight = weight

        guard let image = NDMChrome.symbol(name, pointSize: pointSize, weight: weight) else { return }
        // A status can advance waiting → paused/downloading inside one 300 ms
        // transition. Remove unfinished incoming/blur views before starting the
        // next swap; otherwise the two symbols remain stacked (hourglass + play
        // looked like a flag in the compact progress window).
        transientViews.forEach { view in
            if view !== currentView { view.removeFromSuperview() }
        }
        transientViews.removeAll()
        let next = makeImageView(image)
        let blur = makeImageView(blurredTemplateImage(image, radius: 4) ?? image)
        next.frame = bounds
        blur.frame = bounds
        addSubview(blur)
        addSubview(next)
        transientViews.append(contentsOf: [blur, next])

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion, window != nil else {
            currentView?.removeFromSuperview()
            transientViews.filter { $0 !== next }.forEach { $0.removeFromSuperview() }
            transientViews = []
            currentView = next
            next.alphaValue = 1
            next.layer?.setAffineTransform(.identity)
            return
        }

        let outgoing = currentView
        prepare(view: next, scale: 0.25, opacity: 0)
        prepare(view: blur, scale: 0.25, opacity: 0.72)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.30
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            context.allowsImplicitAnimation = true
            next.animator().alphaValue = 1
            next.layer?.setAffineTransform(.identity)
            blur.animator().alphaValue = 0
            blur.layer?.setAffineTransform(.identity)
            outgoing?.animator().alphaValue = 0
            outgoing?.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.25, y: 0.25))
        } completionHandler: { [weak self, weak next, weak blur, weak outgoing] in
            MainActor.assumeIsolated {
                guard let self, let next else { return }
                outgoing?.removeFromSuperview()
                blur?.removeFromSuperview()
                self.transientViews.removeAll()
                self.currentView = next
                next.alphaValue = 1
                next.layer?.setAffineTransform(.identity)
            }
        }
    }

    override func layout() {
        super.layout()
        currentView?.frame = bounds
        transientViews.forEach { $0.frame = bounds }
    }

    private func makeImageView(_ image: NSImage) -> NSImageView {
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyDown
        view.contentTintColor = tintColor
        view.wantsLayer = true
        view.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return view
    }

    private func prepare(view: NSImageView, scale: CGFloat, opacity: CGFloat) {
        view.alphaValue = opacity
        view.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    }

    private func blurredTemplateImage(_ image: NSImage, radius: Float) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let input = CIImage(bitmapImageRep: bitmap) else { return nil }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input
        filter.radius = radius
        guard let output = filter.outputImage,
              let cgImage = Self.ciContext.createCGImage(output, from: input.extent) else { return nil }
        let result = NSImage(cgImage: cgImage, size: image.size)
        result.isTemplate = true
        return result
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
}

/// Amicro's AppleIconMorph, ported 1:1: a square changes 20%↔50%
/// corner radius while rotating 0→270° over two seconds with easeInOut.
@MainActor
final class AmicroAppleIconMorphView: NSView {
    private let morphLayer = CALayer()
    var tintColor: NSColor = .labelColor {
        didSet { morphLayer.backgroundColor = tintColor.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        morphLayer.backgroundColor = tintColor.cgColor
        layer?.addSublayer(morphLayer)
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height) * 0.58
        morphLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        morphLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        if morphLayer.animation(forKey: "amicroMorph") == nil { start() }
    }

    func start() {
        morphLayer.removeAnimation(forKey: "amicroMorph")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            morphLayer.cornerRadius = morphLayer.bounds.width / 2
            return
        }
        let radius = CAKeyframeAnimation(keyPath: "cornerRadius")
        radius.values = [
            morphLayer.bounds.width * 0.20,
            morphLayer.bounds.width * 0.50,
            morphLayer.bounds.width * 0.50,
            morphLayer.bounds.width * 0.20,
        ]
        let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotation.values = [0, Double.pi / 2, Double.pi, Double.pi * 1.5]
        let group = CAAnimationGroup()
        group.animations = [radius, rotation]
        group.duration = 2
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        morphLayer.add(group, forKey: "amicroMorph")
    }

    func stop() {
        morphLayer.removeAnimation(forKey: "amicroMorph")
    }
}

/// InspectorActionButton with Amicro's contextual icon transition instead of
/// an instantaneous `image` replacement.
@MainActor
final class AmicroIconSwapButton: InspectorActionButton {
    private let swapView = AmicroIconSwapView()
    private let placeholder = NSImage(size: NSSize(width: 16, height: 16))

    convenience init(title: String, symbol: String) {
        self.init(frame: .zero)
        self.title = title
        image = placeholder
        imagePosition = .imageLeading
        imageHugsTitle = true
        swapView.tintColor = contentTintColor ?? .secondaryLabelColor
        swapView.setSymbol(symbol, pointSize: 12, weight: .medium, animated: false)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        swapView.frame = .zero
        addSubview(swapView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ symbol: String, animated: Bool = true) {
        swapView.tintColor = contentTintColor ?? .secondaryLabelColor
        swapView.setSymbol(symbol, pointSize: 12, weight: .medium, animated: animated)
    }

    override func layout() {
        super.layout()
        if let cell = cell as? NSButtonCell {
            swapView.frame = cell.imageRect(forBounds: bounds)
        }
    }
}
