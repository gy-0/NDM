import AppKit
import NDMCore

/// Applies Quiet Finder appearance: System / Light / Dark.
@MainActor
enum AppearanceApplicator {
    static func apply(_ mode: AppearanceMode, animated: Bool = false) {
        guard animated else {
            setAppearance(mode)
            return
        }
        // Snapshot every visible window's content, swap the appearance beneath
        // the frozen image, then crossfade the old look out — a light↔dark
        // change dissolves instead of snapping.
        var overlays: [NSImageView] = []
        for window in NSApp.windows where window.isVisible && window.contentView != nil {
            guard let contentView = window.contentView,
                  contentView.bounds.width > 0, contentView.bounds.height > 0,
                  let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
            else { continue }
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            let image = NSImage(size: contentView.bounds.size)
            image.addRepresentation(rep)
            let overlay = NSImageView(frame: contentView.bounds)
            overlay.image = image
            overlay.imageScaling = .scaleAxesIndependently
            overlay.autoresizingMask = [.width, .height]
            overlay.wantsLayer = true
            contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlays.append(overlay)
        }

        setAppearance(mode)

        guard !overlays.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlays.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            overlays.forEach { $0.removeFromSuperview() }
        }
    }

    private static func setAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
