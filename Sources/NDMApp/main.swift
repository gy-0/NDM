import AppKit
import Darwin
import Foundation
import NDMEngine

@main
enum NDMMain {
    /// `NSApplication.delegate` is a weak assign. Keep a process-lifetime retain so
    /// MenuBarClientCore / AppKit callbacks never hit a deallocated Swift object
    /// (historical crash: Bad pointer at 0x7c8 in SerialExecutor.isMainExecutor).
    private static var retainedDelegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.contains("--verify-bundled-tools") {
            let report = MediaToolchain.inspect()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            exit(report.ready && report.allBundled ? 0 : 78)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
