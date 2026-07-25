import AppKit
import NDMCore

/// Destination geometry for Hero → list-row landing (host coordinates).
struct HeroListLandingDestination {
    let taskID: Int64
    let rowFrame: NSRect
    let glyphFrame: NSRect
    let nameFrame: NSRect
    let statusFrame: NSRect
    let nameSnapshot: NSImage?
    let statusSnapshot: NSImage?
}

/// In-window shared-element morph: a finished Now Downloading hero settles
/// into its Quiet Finder list row. Lives as a temporary overlay — the live
/// hero and row never get stretched.
///
/// Contract with the caller:
/// 1. `installCover` **before** any Hero height / table layout change, so the
///    user never sees the live card collapse.
/// 2. Collapse + reload + one scroll pin underneath the cover.
/// 3. `morphToDestination` with the settled row geometry — straight ease-in-out,
///    no spring, no arc lift, no secondary correction.
@MainActor
final class HeroListLandingAnimator {
    private weak var hostView: NSView?
    private var overlay: NSView?
    private var rootLayer: CALayer?
    private var finishWorkItem: DispatchWorkItem?
    private var revealWorkItem: DispatchWorkItem?
    private var completionHandler: (() -> Void)?

    private var source: HeroListLandingSource?
    private var plateLayer: CALayer?
    private var chromeLayer: CALayer?
    private var coverLayer: CALayer?
    private var nameFromLayer: CALayer?
    private var nameToLayer: CALayer?
    private var eyebrowLayer: CALayer?
    private var speedLayer: CALayer?
    private var progressLayer: CALayer?
    private var statusLayer: CALayer?
    private var outlineLayer: CAShapeLayer?

    var isRunning: Bool { overlay != nil }
    private(set) var animatingTaskID: Int64?

    /// Soft ease-in-out — never spring / never overshoot.
    private static let morphTiming = CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.58, 1.0)

    func cancel() {
        finishWorkItem?.cancel()
        finishWorkItem = nil
        revealWorkItem?.cancel()
        revealWorkItem = nil
        tearDownOverlay()
        let handler = completionHandler
        completionHandler = nil
        animatingTaskID = nil
        handler?()
    }

    /// Freeze a snapshot of the finishing Hero **before** layout collapses.
    /// Must run while the live card is still at its cinema size.
    func installCover(in host: NSView, source: HeroListLandingSource) {
        cancelWithoutCallback()
        hostView = host
        animatingTaskID = source.taskID
        self.source = source

        let overlay = LandingOverlayView(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layerContentsRedrawPolicy = .onSetNeedsDisplay
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay

        let root = CALayer()
        root.frame = overlay.bounds
        root.masksToBounds = false
        overlay.layer = root
        rootLayer = root

        let scale = host.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        buildFrozenLayers(source: source, scale: scale, in: root)
    }

    /// Animate the installed cover into the settled list row.
    /// Call only after Hero height + table reload + scroll pin have settled once.
    func morphToDestination(
        _ destination: HeroListLandingDestination,
        duration: TimeInterval = 0.46,
        onReveal: (() -> Void)? = nil,
        completion: @escaping () -> Void
    ) {
        guard let source,
              animatingTaskID == source.taskID,
              overlay != nil,
              let plate = plateLayer else {
            completion()
            return
        }
        completionHandler = completion

        let schedule = HeroLandingSchedule(duration: duration)
        let destPlate = destination.rowFrame.insetBy(dx: 6, dy: 2)

        // Destination text layers may not exist yet (built at cover time).
        ensureDestinationLayers(destination: destination)

        animateMorph(
            plate: plate,
            chrome: chromeLayer,
            cover: coverLayer,
            nameFrom: nameFromLayer,
            nameTo: nameToLayer,
            eyebrow: eyebrowLayer,
            speed: speedLayer,
            progress: progressLayer,
            status: statusLayer,
            outline: outlineLayer,
            source: source,
            destination: destination,
            destPlate: destPlate,
            schedule: schedule
        )

        // Crossfade live row in late — after the morph has mostly settled. Both
        // deadlines come from the schedule, which measures from the animation's
        // begin time rather than from this call; scheduling them from `now` left
        // the teardown ~3ms after the last animated frame, and one busy frame then
        // yanked the still-opaque cover — the "pop".
        let revealWork = DispatchWorkItem { [weak self] in
            guard self?.animatingTaskID == source.taskID else { return }
            self?.revealWorkItem = nil
            onReveal?()
        }
        revealWorkItem = revealWork
        DispatchQueue.main.asyncAfter(deadline: .now() + schedule.revealAt, execute: revealWork)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finishWorkItem = nil
            self.tearDownOverlay()
            let handler = self.completionHandler
            self.completionHandler = nil
            self.animatingTaskID = nil
            handler?()
        }
        finishWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + schedule.teardownAt, execute: work)
    }

    /// Convenience: cover + morph in one call (when layout is already settled).
    func run(
        in host: NSView,
        source: HeroListLandingSource,
        destination: HeroListLandingDestination,
        duration: TimeInterval = 0.46,
        onReveal: (() -> Void)? = nil,
        completion: @escaping () -> Void
    ) {
        installCover(in: host, source: source)
        morphToDestination(
            destination,
            duration: duration,
            onReveal: onReveal,
            completion: completion
        )
    }

    private func cancelWithoutCallback() {
        finishWorkItem?.cancel()
        finishWorkItem = nil
        revealWorkItem?.cancel()
        revealWorkItem = nil
        tearDownOverlay()
        completionHandler = nil
        animatingTaskID = nil
    }

    private func tearDownOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
        rootLayer = nil
        source = nil
        plateLayer = nil
        chromeLayer = nil
        coverLayer = nil
        nameFromLayer = nil
        nameToLayer = nil
        eyebrowLayer = nil
        speedLayer = nil
        progressLayer = nil
        statusLayer = nil
        outlineLayer = nil
    }

    private func buildFrozenLayers(
        source: HeroListLandingSource,
        scale: CGFloat,
        in root: CALayer
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let plate = CALayer()
        plate.backgroundColor = NDMChrome.contentSurface.cgColor
        plate.cornerRadius = 14
        plate.masksToBounds = true
        plate.frame = source.heroFrame
        plate.shadowColor = NSColor.black.cgColor
        plate.shadowOpacity = 0.16
        plate.shadowRadius = 16
        plate.shadowOffset = CGSize(width: 0, height: -5)
        root.addSublayer(plate)
        plateLayer = plate

        if let image = source.heroSnapshot.flatMap(Self.cgImage) {
            let chrome = CALayer()
            chrome.contents = image
            chrome.contentsGravity = .resize
            chrome.contentsScale = scale
            chrome.frame = source.heroFrame
            chrome.masksToBounds = true
            root.addSublayer(chrome)
            chromeLayer = chrome
        }

        if let image = Self.cgImage(from: source.coverImage) {
            let cover = CALayer()
            cover.contents = image
            cover.contentsGravity = .resizeAspectFill
            cover.contentsScale = scale
            cover.frame = source.coverFrame
            cover.cornerRadius = source.isArtwork
                ? min(10, source.coverFrame.height * 0.12)
                : 9
            cover.masksToBounds = true
            cover.shadowColor = NSColor.black.cgColor
            cover.shadowOpacity = 0.2
            cover.shadowRadius = 10
            cover.shadowOffset = CGSize(width: 0, height: -3)
            root.addSublayer(cover)
            coverLayer = cover
        }

        if let image = Self.makeTextSnapshot(
            string: source.filename,
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: .labelColor,
            size: source.nameFrame.size
        ).flatMap(Self.cgImage) {
            let nameFrom = CALayer()
            nameFrom.contents = image
            nameFrom.contentsGravity = .resizeAspect
            nameFrom.contentsScale = scale
            nameFrom.frame = source.nameFrame
            root.addSublayer(nameFrom)
            nameFromLayer = nameFrom
        }

        if let image = source.eyebrowSnapshot.flatMap(Self.cgImage) {
            let eyebrow = CALayer()
            eyebrow.contents = image
            eyebrow.contentsGravity = .resizeAspect
            eyebrow.contentsScale = scale
            eyebrow.frame = source.eyebrowFrame
            root.addSublayer(eyebrow)
            eyebrowLayer = eyebrow
        }

        if let image = source.speedSnapshot.flatMap(Self.cgImage) {
            let speed = CALayer()
            speed.contents = image
            speed.contentsGravity = .resizeAspect
            speed.contentsScale = scale
            speed.frame = source.speedFrame
            root.addSublayer(speed)
            speedLayer = speed
        }

        if let image = source.progressSnapshot.flatMap(Self.cgImage) {
            let progress = CALayer()
            progress.contents = image
            progress.contentsGravity = .resize
            progress.contentsScale = scale
            progress.frame = source.progressFrame
            progress.cornerRadius = 2
            progress.masksToBounds = true
            root.addSublayer(progress)
            progressLayer = progress
        }

        CATransaction.commit()
    }

    private func ensureDestinationLayers(destination: HeroListLandingDestination) {
        guard let root = rootLayer, let source else { return }
        let scale = hostView?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if nameToLayer == nil {
            let image = (destination.nameSnapshot ?? Self.makeTextSnapshot(
                string: source.filename,
                font: .systemFont(ofSize: 13, weight: .semibold),
                color: .labelColor,
                size: destination.nameFrame.size
            )).flatMap(Self.cgImage)
            if let image {
                let nameTo = CALayer()
                nameTo.contents = image
                nameTo.contentsGravity = .resizeAspect
                nameTo.contentsScale = scale
                nameTo.frame = source.nameFrame
                nameTo.opacity = 0
                root.addSublayer(nameTo)
                nameToLayer = nameTo
            }
        }

        if statusLayer == nil, let image = destination.statusSnapshot.flatMap(Self.cgImage) {
            let status = CALayer()
            status.contents = image
            status.contentsGravity = .resizeAspect
            status.contentsScale = scale
            status.frame = destination.statusFrame
            status.opacity = 0
            root.addSublayer(status)
            statusLayer = status
        }

        if outlineLayer == nil, let cover = coverLayer {
            let outline = CAShapeLayer()
            let destGlyphInset = destination.glyphFrame.insetBy(dx: -3, dy: -3)
            outline.path = CGPath(
                roundedRect: destGlyphInset,
                cornerWidth: 11,
                cornerHeight: 11,
                transform: nil
            )
            outline.fillColor = NSColor.clear.cgColor
            outline.strokeColor = NDMChrome.accent.withAlphaComponent(0.55).cgColor
            outline.lineWidth = 1.25
            outline.opacity = 0
            root.insertSublayer(outline, below: cover)
            outlineLayer = outline
        }

        CATransaction.commit()
    }

    private func animateMorph(
        plate: CALayer,
        chrome: CALayer?,
        cover: CALayer?,
        nameFrom: CALayer?,
        nameTo: CALayer?,
        eyebrow: CALayer?,
        speed: CALayer?,
        progress: CALayer?,
        status: CALayer?,
        outline: CAShapeLayer?,
        source: HeroListLandingSource,
        destination: HeroListLandingDestination,
        destPlate: NSRect,
        schedule: HeroLandingSchedule
    ) {
        // One frame out, so the group cannot start mid-commit. The wall-clock
        // reveal/teardown timers are derived from the same offset.
        let begin = CACurrentMediaTime() + schedule.beginOffset
        let duration = schedule.duration
        let timing = Self.morphTiming

        // Commit final model values; presentation interpolates from current freeze.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = destPlate
        plate.cornerRadius = 10
        plate.shadowOpacity = 0
        plate.opacity = 0
        chrome?.opacity = 0
        if let cover {
            cover.frame = destination.glyphFrame
            cover.cornerRadius = 9
            cover.shadowOpacity = 0
            cover.opacity = 0
        }
        if let nameFrom {
            nameFrom.frame = destination.nameFrame
            nameFrom.opacity = 0
        }
        if let nameTo {
            nameTo.frame = destination.nameFrame
            nameTo.opacity = 0
        }
        eyebrow?.opacity = 0
        speed?.opacity = 0
        progress?.opacity = 0
        if let status {
            status.frame = destination.statusFrame
            status.opacity = 0
        }
        outline?.opacity = 0
        CATransaction.commit()

        func boundsAnim(from: NSSize, to: NSSize) -> CABasicAnimation {
            let anim = CABasicAnimation(keyPath: "bounds")
            anim.fromValue = NSValue(rect: CGRect(origin: .zero, size: from))
            anim.toValue = NSValue(rect: CGRect(origin: .zero, size: to))
            return anim
        }

        func positionAnim(from: NSRect, to: NSRect) -> CABasicAnimation {
            let anim = CABasicAnimation(keyPath: "position")
            anim.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
            anim.toValue = NSValue(point: CGPoint(x: to.midX, y: to.midY))
            return anim
        }

        func apply(_ group: CAAnimationGroup, to layer: CALayer, key: String) {
            group.duration = duration
            group.beginTime = begin
            group.timingFunction = timing
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: key)
        }

        // Plate — shrink in place along a straight path.
        let plateGroup = CAAnimationGroup()
        let platePos = positionAnim(from: source.heroFrame, to: destPlate)
        let plateBounds = boundsAnim(from: source.heroFrame.size, to: destPlate.size)
        let plateRadius = CABasicAnimation(keyPath: "cornerRadius")
        plateRadius.fromValue = 14
        plateRadius.toValue = 10
        let plateShadow = CABasicAnimation(keyPath: "shadowOpacity")
        plateShadow.fromValue = 0.16
        plateShadow.toValue = 0
        plateGroup.animations = [platePos, plateBounds, plateRadius, plateShadow]
        apply(plateGroup, to: plate, key: "plateMorph")

        let plateFade = CAKeyframeAnimation(keyPath: "opacity")
        plateFade.values = [1, 1, 0]
        plateFade.keyTimes = [0, 0.78, 0.92]
        plateFade.duration = duration
        plateFade.beginTime = begin
        plateFade.timingFunction = timing
        plateFade.fillMode = .both
        plateFade.isRemovedOnCompletion = false
        plate.add(plateFade, forKey: "plateFade")

        // Full-hero chrome dissolves early so big numerals don't squash.
        if let chrome {
            let chromeFade = CAKeyframeAnimation(keyPath: "opacity")
            chromeFade.values = [1, 0.7, 0]
            chromeFade.keyTimes = [0, 0.22, 0.4]
            let chromeGroup = CAAnimationGroup()
            chromeGroup.animations = [chromeFade]
            chromeGroup.duration = duration
            chromeGroup.beginTime = begin
            chromeGroup.timingFunction = CAMediaTimingFunction(name: .easeIn)
            chromeGroup.fillMode = .both
            chromeGroup.isRemovedOnCompletion = false
            chrome.add(chromeGroup, forKey: "chromeOut")
        }

        // Cover — enduring shared element, straight morph into the glyph.
        if let cover {
            let coverGroup = CAAnimationGroup()
            let coverPos = positionAnim(from: source.coverFrame, to: destination.glyphFrame)
            let coverBounds = boundsAnim(from: source.coverFrame.size, to: destination.glyphFrame.size)
            let coverRadius = CABasicAnimation(keyPath: "cornerRadius")
            coverRadius.fromValue = source.isArtwork
                ? min(10, source.coverFrame.height * 0.12)
                : 9
            coverRadius.toValue = 9
            let coverShadow = CABasicAnimation(keyPath: "shadowOpacity")
            coverShadow.fromValue = 0.2
            coverShadow.toValue = 0
            let coverFade = CAKeyframeAnimation(keyPath: "opacity")
            coverFade.values = [1, 1, 0]
            coverFade.keyTimes = [0, 0.86, 1]
            coverGroup.animations = [coverPos, coverBounds, coverRadius, coverShadow, coverFade]
            apply(coverGroup, to: cover, key: "coverMorph")
        }

        // Filename — hold source type, crossfade into row type.
        if let nameFrom {
            let nameFromGroup = CAAnimationGroup()
            let nameFromPos = positionAnim(from: source.nameFrame, to: destination.nameFrame)
            let nameFromBounds = boundsAnim(from: source.nameFrame.size, to: destination.nameFrame.size)
            let nameFromFade = CAKeyframeAnimation(keyPath: "opacity")
            nameFromFade.values = [1, 1, 0]
            nameFromFade.keyTimes = [0, 0.55, 0.78]
            nameFromGroup.animations = [nameFromPos, nameFromBounds, nameFromFade]
            apply(nameFromGroup, to: nameFrom, key: "nameFrom")
        }

        if let nameTo {
            let nameToGroup = CAAnimationGroup()
            let nameToPos = positionAnim(from: source.nameFrame, to: destination.nameFrame)
            let nameToBounds = boundsAnim(from: source.nameFrame.size, to: destination.nameFrame.size)
            let nameToFade = CAKeyframeAnimation(keyPath: "opacity")
            nameToFade.values = [0, 0, 1, 1, 0]
            nameToFade.keyTimes = [0, 0.5, 0.68, 0.86, 1]
            nameToGroup.animations = [nameToPos, nameToBounds, nameToFade]
            apply(nameToGroup, to: nameTo, key: "nameTo")
        }

        // Ephemeral hero chrome — fade, no motion.
        for (layer, key) in [
            (eyebrow, "eyebrow"),
            (speed, "speed"),
            (progress, "progress"),
        ] {
            guard let layer else { continue }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 0.35, 0]
            fade.keyTimes = [0, 0.18, 0.34]
            fade.duration = duration
            fade.beginTime = begin
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fade.fillMode = .both
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: key)
        }

        if let status {
            let statusFade = CAKeyframeAnimation(keyPath: "opacity")
            statusFade.values = [0, 0, 1, 1, 0]
            statusFade.keyTimes = [0, 0.58, 0.72, 0.88, 1]
            statusFade.duration = duration
            statusFade.beginTime = begin
            statusFade.timingFunction = timing
            statusFade.fillMode = .both
            statusFade.isRemovedOnCompletion = false
            status.add(statusFade, forKey: "statusIn")
        }

        if let outline {
            let outlineFade = CAKeyframeAnimation(keyPath: "opacity")
            outlineFade.values = [0, 0, 0.55, 0]
            outlineFade.keyTimes = [0, 0.62, 0.8, 1]
            outlineFade.duration = duration
            outlineFade.beginTime = begin
            outlineFade.timingFunction = timing
            outlineFade.fillMode = .both
            outlineFade.isRemovedOnCompletion = false
            outline.add(outlineFade, forKey: "outline")
        }
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func makeTextSnapshot(
        string: String,
        font: NSFont,
        color: NSColor,
        size: NSSize
    ) -> NSImage? {
        guard size.width > 0.5, size.height > 0.5, !string.isEmpty else { return nil }
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        field.frame = NSRect(origin: .zero, size: size)
        guard let representation = field.bitmapImageRepForCachingDisplay(in: field.bounds) else {
            return nil
        }
        representation.size = size
        field.cacheDisplay(in: field.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }
}

/// Click-through host so the morph never steals interaction from the list.
private final class LandingOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
