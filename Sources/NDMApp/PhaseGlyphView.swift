import AppKit
import NDMCore

// MARK: - Phase verb (2026-08 design language)

/// The stage of a transfer, named as a verb. Each verb carries its own small
/// motion — the Appllama "button is the state" language, native CALayer form.
@MainActor
enum PhaseVerb {
    case recognizing    // 识别链接 — particles gathering
    case preparing      // 准备下载 — aperture focusing
    case transferring   // 下载中 — light streaming
    case merging        // 合并中 — two shapes fusing
    case subtitles      // 字幕整理 — caption lines stacking
    case finalizing     // 整理中 — polish pulse
    case paused         // 已暂停 — two resting bars
    case waiting        // 排队中 — idle dot
    case incomplete     // 未完成 — idle dot
    case completed      // 已完成 — settled checkmark
    case failed         // 失败 — static alert

    var title: String {
        switch self {
        case .recognizing: return L10n.ytdlpPreparingShort
        case .preparing: return L10n.ytdlpPreparingShort
        case .transferring: return L10n.downloading
        case .merging: return L10n.t("Packaging", "封装中")
        case .subtitles: return L10n.t("Subtitles", "字幕整理")
        case .finalizing: return L10n.t("Finishing", "整理中")
        case .paused: return L10n.paused
        case .waiting: return L10n.queued
        case .incomplete: return L10n.incomplete
        case .completed: return L10n.completed
        case .failed: return L10n.failed
        }
    }

    /// Map a live download state + post-process phase onto a verb.
    static func live(status: DownloadStatus, phase: DownloadPhase?, error: String?) -> PhaseVerb {
        switch status {
        case .downloading:
            switch phase {
            case .preparing: return .preparing
            case .merging: return .merging
            case .subtitles: return .subtitles
            case .finalizing: return .finalizing
            default: return .transferring
            }
        case .paused: return .paused
        case .complete: return .completed
        case .error: return .failed
        case .waiting: return .waiting
        case .incomplete: return .incomplete
        }
    }
}

/// A 14×14 glyph that plays the phase verb's own motion.
///
/// Each verb owns a small native-CALayer choreography:
/// - recognizing / preparing — three particles breathing in (gathering)
/// - transferring — a light streak sweeping with a ghost trail
/// - merging — two discs closing into one
/// - subtitles — caption lines stacking in sequence
/// - finalizing — a polish ring pulsing
/// - paused / waiting / incomplete / completed / failed — static symbols
@MainActor
final class PhaseGlyphView: NSView {
    private var glyphLayer: CALayer?
    private var glyphLayers: [CALayer] = []
    private var lastVerb: PhaseVerb = .waiting
    private var lastColor: NSColor = .labelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Switch the glyph to a verb's motion, tinted with `color`.
    func setVerb(_ verb: PhaseVerb, color: NSColor) {
        lastVerb = verb
        lastColor = color
        showGlyph(verb, color: color)
    }

    func refreshColors() {
        showGlyph(lastVerb, color: lastColor)
    }

    private func showGlyph(_ verb: PhaseVerb, color: NSColor) {
        glyphLayers.forEach { $0.removeAllAnimations() }
        glyphLayer?.removeFromSuperlayer()
        glyphLayer = nil
        glyphLayers = []

        let size = bounds.size == .zero ? NSSize(width: 14, height: 14) : bounds.size
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        layer?.addSublayer(root)
        glyphLayer = root

        switch verb {
        case .recognizing, .preparing:
            // Three particles breathing in — recognition gathering.
            let replicator = CAReplicatorLayer()
            replicator.frame = root.bounds
            replicator.instanceCount = 3
            replicator.instanceDelay = 0.22
            replicator.instanceTransform = CATransform3DMakeTranslation(4.5, 0, 0)
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 3, height: 3)
            dot.position = CGPoint(x: center.x - 4.5, y: center.y)
            dot.backgroundColor = color.cgColor
            dot.cornerRadius = 1.5
            replicator.addSublayer(dot)
            root.addSublayer(replicator)
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.15
            pulse.toValue = 1.0
            pulse.duration = 0.66
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.add(pulse, forKey: "pulse")
            glyphLayers.append(replicator)

        case .transferring:
            // Light streaming — a small streak sweeping the pill.
            let streak = CALayer()
            streak.bounds = CGRect(x: 0, y: 0, width: 5, height: 2.5)
            streak.position = CGPoint(x: -3, y: center.y)
            streak.backgroundColor = color.cgColor
            streak.cornerRadius = 1.25
            root.addSublayer(streak)
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = -3
            sweep.toValue = size.width + 3
            sweep.duration = 1.1
            sweep.repeatCount = .infinity
            streak.add(sweep, forKey: "sweep")
            glyphLayers.append(streak)
            let ghost = CALayer()
            ghost.bounds = CGRect(x: 0, y: 0, width: 5, height: 2.5)
            ghost.position = CGPoint(x: -12, y: center.y)
            ghost.backgroundColor = color.withAlphaComponent(0.45).cgColor
            ghost.cornerRadius = 1.25
            root.addSublayer(ghost)
            let ghostSweep = CABasicAnimation(keyPath: "position.x")
            ghostSweep.fromValue = -12
            ghostSweep.toValue = size.width + 12
            ghostSweep.duration = 1.1
            ghostSweep.repeatCount = .infinity
            ghost.add(ghostSweep, forKey: "sweep")
            glyphLayers.append(ghost)

        case .merging:
            // Two discs closing into one — the merge itself.
            let left = CALayer()
            left.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
            left.position = CGPoint(x: center.x - 5, y: center.y)
            left.backgroundColor = color.cgColor
            left.cornerRadius = 2.5
            root.addSublayer(left)
            let right = CALayer()
            right.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
            right.position = CGPoint(x: center.x + 5, y: center.y)
            right.backgroundColor = color.cgColor
            right.cornerRadius = 2.5
            root.addSublayer(right)
            let close = CAKeyframeAnimation(keyPath: "position.x")
            close.values = [center.x - 5, center.x]
            close.keyTimes = [0, 1]
            close.duration = 0.55
            close.autoreverses = true
            close.repeatCount = .infinity
            left.add(close, forKey: "merge")
            let closeR = CAKeyframeAnimation(keyPath: "position.x")
            closeR.values = [center.x + 5, center.x]
            closeR.keyTimes = [0, 1]
            closeR.duration = 0.55
            closeR.autoreverses = true
            closeR.repeatCount = .infinity
            right.add(closeR, forKey: "merge")
            glyphLayers.append(contentsOf: [left, right])

        case .subtitles:
            // Caption lines stacking in.
            for (i, w) in [CGFloat(8), 11, 6].enumerated() {
                let line = CALayer()
                line.bounds = CGRect(x: 0, y: 0, width: w, height: 1.6)
                line.position = CGPoint(x: center.x - 1, y: center.y + CGFloat(i - 1) * 4)
                line.backgroundColor = color.cgColor
                line.cornerRadius = 0.8
                line.opacity = 0.25
                root.addSublayer(line)
                let inAni = CABasicAnimation(keyPath: "opacity")
                inAni.fromValue = 0.25
                inAni.toValue = 1.0
                inAni.duration = 0.4
                inAni.autoreverses = true
                inAni.repeatCount = .infinity
                inAni.beginTime = CACurrentMediaTime() + Double(i) * 0.28
                line.add(inAni, forKey: "stack")
                glyphLayers.append(line)
            }

        case .finalizing:
            // A polish ring pulsing — work is being finished.
            let ring = CAShapeLayer()
            let path = CGMutablePath()
            path.addArc(center: center, radius: 5, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ring.path = path
            ring.strokeColor = color.cgColor
            ring.fillColor = NSColor.clear.cgColor
            ring.lineWidth = 1.6
            ring.lineCap = .round
            root.addSublayer(ring)
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.6
            pulse.toValue = 1.15
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.45
            fade.toValue = 1.0
            fade.duration = 0.7
            fade.autoreverses = true
            fade.repeatCount = .infinity
            ring.add(pulse, forKey: "pulse")
            ring.add(fade, forKey: "fade")
            glyphLayers.append(ring)

        case .paused:
            // Two resting bars — paused, not broken.
            for x in [center.x - 3.5, center.x + 3.5] {
                let bar = CALayer()
                bar.bounds = CGRect(x: 0, y: 0, width: 2.6, height: 8)
                bar.position = CGPoint(x: x, y: center.y)
                bar.backgroundColor = color.cgColor
                bar.cornerRadius = 1.3
                root.addSublayer(bar)
                glyphLayers.append(bar)
            }

        case .waiting, .incomplete:
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
            dot.position = center
            dot.backgroundColor = color.withAlphaComponent(0.6).cgColor
            dot.cornerRadius = 2.5
            root.addSublayer(dot)
            glyphLayers.append(dot)

        case .completed:
            // A settled checkmark — done, resting.
            let check = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x - 4, y: center.y - 0.5))
            path.addLine(to: CGPoint(x: center.x - 1, y: center.y + 2.5))
            path.addLine(to: CGPoint(x: center.x + 4, y: center.y - 3))
            check.path = path
            check.strokeColor = color.cgColor
            check.fillColor = NSColor.clear.cgColor
            check.lineWidth = 1.8
            check.lineCap = .round
            check.lineJoin = .round
            root.addSublayer(check)
            glyphLayers.append(check)

        case .failed:
            let exclaim = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x, y: center.y + 3))
            path.addLine(to: CGPoint(x: center.x, y: center.y - 1))
            exclaim.path = path
            exclaim.strokeColor = color.cgColor
            exclaim.fillColor = NSColor.clear.cgColor
            exclaim.lineWidth = 1.8
            exclaim.lineCap = .round
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 1.8, height: 1.8)
            dot.position = CGPoint(x: center.x, y: center.y - 4.5)
            dot.backgroundColor = color.cgColor
            dot.cornerRadius = 0.9
            root.addSublayer(exclaim)
            root.addSublayer(dot)
            glyphLayers.append(contentsOf: [exclaim, dot])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }
}
