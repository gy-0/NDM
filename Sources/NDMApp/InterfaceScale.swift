import AppKit

/// Semantic content zoom (⌘+ / ⌘− / ⌘0).
///
/// This deliberately does not transform an NSWindow's content view. Transforming
/// the root coordinate system makes fixed split widths and Auto Layout constraints
/// disagree with what is drawn. Consumers listen for `didChangeNotification` and
/// re-lay out only the content that is meaningful to zoom.
@MainActor
enum InterfaceScale {
    static let didChangeNotification = Notification.Name("NDMInterfaceScaleDidChange")

    static let minimum: CGFloat = 0.8
    static let maximum: CGFloat = 1.4
    static let step: CGFloat = 0.1
    static let `default`: CGFloat = 1.0

    private static let suiteName = "dev.ndm.open"
    private static let defaultsKey = "interfaceScale"
    static var current: CGFloat {
        get {
            if let qaScale = QAPreviewOverrides.interfaceScale {
                return clamp(qaScale)
            }
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            let stored = defaults.object(forKey: defaultsKey) as? Double
            let value = CGFloat(stored ?? Double(Self.default))
            return clamp(value)
        }
        set {
            let next = clamp(newValue)
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.set(Double(next), forKey: defaultsKey)
            NotificationCenter.default.post(
                name: didChangeNotification,
                object: nil,
                userInfo: ["scale": next]
            )
        }
    }

    static var canZoomIn: Bool { current + 0.001 < maximum }
    static var canZoomOut: Bool { current - 0.001 > minimum }
    static var isDefault: Bool { abs(current - Self.default) < 0.001 }

    static func zoomIn() {
        guard canZoomIn else { return }
        current = clamp(current + step)
    }

    static func zoomOut() {
        guard canZoomOut else { return }
        current = clamp(current - step)
    }

    static func reset() {
        current = Self.default
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        // Snap to one decimal so repeated +/- doesn't drift.
        let snapped = (value * 10).rounded() / 10
        return min(maximum, max(minimum, snapped))
    }
}
