import AppKit

/// Draw a window to a PNG without a display.
///
/// Visual work in this project is verified by capture, not by assertion — but
/// `screencapture` needs a live display, so with the screen asleep it writes an
/// empty file and the discipline quietly stops working. AppKit will render a view
/// into a bitmap regardless, so this is the same verification through a path that
/// does not care whether anyone is looking.
///
/// DEBUG-only, driven by `NDM_QA_RENDER_TO`.
///
/// **Known limitation.** Cover art assigned straight to a layer's `contents`
/// (`HeroPreviewView`) does not appear, through either path. Layout, colour,
/// typography and spacing are faithful; the inspector's poster well renders empty.
/// A live `screencapture` shows it, so an empty poster here is the capture, not the
/// design — do not "fix" it on the strength of one of these renders.
@MainActor
enum QAWindowRenderer {
    /// Renders the frontmost non-panel window, which in QA runs is the one under
    /// test. Returns whether anything was written.
    /// Render through the layer tree.
    ///
    /// `cacheDisplay(in:to:)` replays `draw(_:)` and therefore misses anything whose
    /// image was assigned straight to a layer — which in this app is every piece of
    /// cover art (`HeroPreviewView` sets `imageLayer.contents`). Rendering the layer
    /// tree instead catches those, and nearly cost an afternoon: the inspector's
    /// poster came out blank and read as a design flaw rather than a capture bug.
    private static func renderLayerTree(of view: NSView, bounds: NSRect) -> NSBitmapImageRep? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let pixelWidth = Int(bounds.width * scale)
        let pixelHeight = Int(bounds.height * scale)
        guard pixelWidth > 0, pixelHeight > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The bitmap context is already y-up, which is what `render(in:)` wants;
        // an extra flip here produced a mirrored image on the first attempt.
        context.cgContext.scaleBy(x: scale, y: scale)
        layer.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func renderDrawRect(of view: NSView, bounds: NSRect) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    @discardableResult
    static func renderMainWindow(to path: String) -> Bool {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        // Completion and settings QA sometimes needs the key auxiliary window;
        // default visual runs keep choosing the largest stable surface.
        let window = ProcessInfo.processInfo.environment["NDM_QA_RENDER_KEY_WINDOW"] == "1"
            ? NSApp.keyWindow
            : candidates.max(by: { $0.frame.width < $1.frame.width })
        guard let window,
              let content = window.contentView else {
            FileHandle.standardError.write(Data("QA render: no window\n".utf8))
            return false
        }
        return render(content, to: path)
    }

    @discardableResult
    static func render(_ view: NSView, to path: String) -> Bool {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            FileHandle.standardError.write(Data("QA render: empty bounds\n".utf8))
            return false
        }
        let forceDrawRect = ProcessInfo.processInfo.environment["NDM_QA_RENDER_DRAW_RECT"] == "1"
        let rep = forceDrawRect
            ? renderDrawRect(of: view, bounds: bounds)
            : renderLayerTree(of: view, bounds: bounds) ?? renderDrawRect(of: view, bounds: bounds)
        guard let rep else {
            FileHandle.standardError.write(Data("QA render: no bitmap\n".utf8))
            return false
        }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("QA render: no png\n".utf8))
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(
                Data("QA render: wrote \(Int(bounds.width))x\(Int(bounds.height)) to \(path)\n".utf8)
            )
            return true
        } catch {
            FileHandle.standardError.write(Data("QA render: \(error)\n".utf8))
            return false
        }
    }
}
