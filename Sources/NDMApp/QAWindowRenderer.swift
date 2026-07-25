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
@MainActor
enum QAWindowRenderer {
    /// Renders the frontmost non-panel window, which in QA runs is the one under
    /// test. Returns whether anything was written.
    @discardableResult
    static func renderMainWindow(to path: String) -> Bool {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        // Largest visible window: sheets and popovers are smaller by construction.
        guard let window = candidates.max(by: { $0.frame.width < $1.frame.width }),
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
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            FileHandle.standardError.write(Data("QA render: no bitmap\n".utf8))
            return false
        }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
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
