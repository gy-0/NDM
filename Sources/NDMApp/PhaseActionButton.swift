import AppKit
import NDMCore

/// The primary action button doubles as the phase's stage — the Appllama
/// "button is the state" pattern.
///
/// While a transfer runs, the button stops being a static "Pause" pill and
/// becomes a living verb: its label reads the current stage (识别中 / 下载中 /
/// 合并中 / 字幕整理 / 整理中), a small animated glyph inside the pill plays
/// that stage's own motion (particles gathering, light streaming, discs
/// fusing, polish pulsing), and a soft light sweep travels across the pill's
/// surface so the whole button reads as alive. Clicking it still pauses,
/// exactly as before.
///
/// When no phase is active the button returns to its ordinary
/// icon + label shape (Pause / Resume / Open / …).
@MainActor
final class PhaseActionButton: InspectorActionButton {
    private let phaseGlyph = PhaseGlyphView()
    /// A soft light band sweeping the pill's surface while a transfer runs —
    /// the whole button moves, not just a corner icon.
    private let shimmer = CAGradientLayer()
    private var shimmerAnimation: CAAnimation?
    private var phaseActive = false
    private var restingTitle: String = ""
    private var restingSymbol: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        shimmer.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.28).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        shimmer.locations = [0, 0.5, 1]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.isHidden = true
        layer?.addSublayer(shimmer)

        phaseGlyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phaseGlyph)
        NSLayoutConstraint.activate([
            phaseGlyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            phaseGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            phaseGlyph.widthAnchor.constraint(equalToConstant: 16),
            phaseGlyph.heightAnchor.constraint(equalToConstant: 16),
        ])
        phaseGlyph.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Shimmer is a light band wider than the pill that slides across it.
        // Keep its frame in sync with the resolved bounds.
        shimmer.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width * 3, height: bounds.height)
        shimmer.cornerRadius = bounds.height / 2
        if shimmerAnimation == nil, !shimmer.isHidden {
            startShimmer()
        }
    }

    /// Put the button into "phase" mode: verb label + live animated glyph +
    /// a light sweep across the pill. The tint follows the filled pill
    /// (white label ink) so the motion reads as part of the button, not as a
    /// separate badge.
    func setPhase(_ phase: DownloadPhase?, title: String? = nil) {
        phaseActive = true
        let verb = PhaseVerb.live(status: .downloading, phase: phase, error: nil)
        let label = title ?? verb.title
        self.title = label
        self.image = nil
        self.toolTip = L10n.pause
        self.setAccessibilityLabel(label)
        setAccessibilityValue(L10n.pause)
        // Filled pill ink is white in both appearances — the motion reads as
        // part of the button, not as a separate badge.
        phaseGlyph.setVerb(verb, color: .white)
        phaseGlyph.isHidden = false
        startShimmer()
        needsDisplay = true
    }

    /// Restore the ordinary icon + label shape.
    func setIdle(title: String, symbol: String) {
        phaseActive = false
        restingTitle = title
        restingSymbol = symbol
        self.title = title
        self.image = NDMChrome.symbol(symbol, pointSize: 12, weight: .semibold)
        self.imagePosition = .imageLeading
        self.imageHugsTitle = true
        self.toolTip = title
        self.setAccessibilityLabel(title)
        setAccessibilityValue(nil)
        phaseGlyph.isHidden = true
        stopShimmer()
        needsDisplay = true
    }

    var isPhaseActive: Bool { phaseActive }

    // MARK: Shimmer

    private func startShimmer() {
        if shimmer.isHidden {
            shimmer.isHidden = false
            // Re-run layout so the frame matches current bounds before animating.
            shimmer.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width * 3, height: bounds.height)
            shimmer.cornerRadius = bounds.height / 2
        }
        guard shimmerAnimation == nil,
              NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else { return }
        // Slide the light band from one side of the pill to the other, then
        // loop — one continuous sweep, no pop.
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -bounds.width
        sweep.toValue = bounds.width * 2
        sweep.duration = 1.4
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmer.add(sweep, forKey: "shimmerSweep")
        shimmerAnimation = sweep
    }

    private func stopShimmer() {
        shimmer.removeAnimation(forKey: "shimmerSweep")
        shimmerAnimation = nil
        shimmer.isHidden = true
    }
}
