import AppKit

/// A short, joyful completion burst: emoji confetti fired from a point plus a
/// soft "pop". Deliberately brief — a beat of delight, not a parade.
@MainActor
enum CelebrationEffect {
    private static let emojis = ["🎉", "🎊", "✨", "🥳", "⭐️"]

    /// Fire confetti from `point` (in `host`'s coordinates) and play the pop.
    static func burst(in host: NSView, at point: CGPoint, playSound: Bool = true) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if playSound { pop() }
            return
        }
        host.wantsLayer = true
        guard let root = host.layer else { return }

        let emitter = CAEmitterLayer()
        emitter.emitterPosition = point
        emitter.emitterSize = CGSize(width: 8, height: 8)
        emitter.emitterShape = .point
        emitter.beginTime = CACurrentMediaTime()
        emitter.emitterCells = emojis.map { cell(for: $0) }
        root.addSublayer(emitter)

        // A tight, upward-biased pop: emit for a moment, then stop and clean up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            emitter.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            emitter.removeFromSuperlayer()
        }
        if playSound { pop() }
    }

    private static func pop() {
        // The system "Pop" — a light, satisfying tick that isn't alarming.
        (NSSound(named: "Pop") ?? NSSound(named: "Glass"))?.play()
    }

    private static func cell(for emoji: String) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image(for: emoji)
        cell.birthRate = 14
        cell.lifetime = 1.3
        cell.velocity = 200
        cell.velocityRange = 70
        // Fan upward (−90° is up in this coordinate space) with spread.
        cell.emissionLongitude = -.pi / 2
        cell.emissionRange = .pi / 3.2
        cell.yAcceleration = 420      // gravity pulls the confetti back down
        cell.spin = 3
        cell.spinRange = 5
        cell.scale = 0.5
        cell.scaleRange = 0.2
        cell.scaleSpeed = -0.15
        cell.alphaSpeed = -0.7
        return cell
    }

    private static var imageCache: [String: CGImage] = [:]

    private static func image(for emoji: String) -> CGImage? {
        if let cached = imageCache[emoji] { return cached }
        let size = NSSize(width: 44, height: 44)
        let image = NSImage(size: size)
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34),
        ]
        (emoji as NSString).draw(
            at: NSPoint(x: 4, y: 2),
            withAttributes: attributes
        )
        image.unlockFocus()
        guard let cg = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else { return nil }
        imageCache[emoji] = cg
        return cg
    }
}
