import AppKit

@main
enum NDMMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // NSApplication.delegate is not our lifetime owner. Keep the @MainActor
        // delegate alive for the complete AppKit run loop; retired crash reports
        // showed MenuBarClientCore calling a stale Swift executor (0x7c8).
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
