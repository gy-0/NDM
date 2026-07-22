import AppKit
import Foundation

/// AppKit boundary for recoverable deletion. NDMEngine only receives this as
/// an injected async closure, so filesystem safety stays testable without
/// making the engine depend on AppKit.
@MainActor
enum AppFileRecycler {
    static func recycle(_ url: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([url]) { relocatedURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let wasRecycled = relocatedURLs.keys.contains {
                    $0.standardizedFileURL == url.standardizedFileURL
                }
                guard wasRecycled else {
                    continuation.resume(throwing: AppFileRecycleError.notRecycled(url))
                    return
                }
                continuation.resume()
            }
        }
    }
}

private enum AppFileRecycleError: LocalizedError {
    case notRecycled(URL)

    var errorDescription: String? {
        switch self {
        case .notRecycled(let url):
            return "The file could not be moved to Trash: \(url.lastPathComponent)"
        }
    }
}
