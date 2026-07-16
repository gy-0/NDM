import AppKit
import NDMCore

/// Applies Quiet Finder appearance: System / Light / Dark.
@MainActor
enum AppearanceApplicator {
    static func apply(_ mode: AppearanceMode) {
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
