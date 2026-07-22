import Foundation
import NDMCore

public extension DownloadDiagnostic {
    /// Map any error surfaced by the download engines to a human diagnostic.
    /// `EngineError.paused` / `.cancelled` never reach the failure path
    /// (DownloadManager routes them to paused/incomplete states first).
    static func classify(_ error: Error) -> DownloadDiagnostic {
        switch error {
        case let engine as EngineError:
            return classify(engine: engine)
        case let ftp as FTPError:
            return classify(ftp: ftp)
        case let url as URLError:
            return fromURLError(url)
        default:
            let ns = error as NSError
            if let disk = fromCocoaError(ns) { return disk }
            if ns.domain == NSURLErrorDomain {
                return fromURLError(URLError(URLError.Code(rawValue: ns.code)))
            }
            return .generic(detail: error.localizedDescription)
        }
    }

    private static func classify(engine: EngineError) -> DownloadDiagnostic {
        switch engine {
        case .httpStatus(let code):
            return fromHTTPStatus(code)
        case .authRequired(let status, _):
            return .signInRequired(status: status)
        case .notResumable:
            return .rangeNotSupported
        case .invalidResponse:
            return .generic(detail: "Invalid HTTP response")
        case .mergeFailed(let message):
            // YtDlpTool throws every resolver failure as `mergeFailed`; only
            // downgrade to generic when the message looks like a yt-dlp
            // resolver/downloader startup problem, not a real mux failure.
            // Real FFmpeg/MKVMerge errors must keep their classification so
            // triage surfaces the correct diagnostic.
            let lowered = message.lowercased()
            let isResolverNoise = lowered.contains("yt-dlp")
                || lowered.contains("no usable video info")
                || lowered.contains("no usable collection info")
                || lowered.contains("aria2c exited")
                || lowered.contains("yt-dlp not found")
                || lowered.contains("no file appeared")
            return isResolverNoise
                ? .generic(detail: message)
                : .mergeFailed(detail: message)
        case .insufficientStorage:
            return .diskFull
        case .cancelled, .paused:
            return .generic(detail: engine.errorDescription ?? "stopped")
        }
    }

    private static func classify(ftp: FTPError) -> DownloadDiagnostic {
        switch ftp {
        case .timeout:
            return .timeout
        case .disconnected:
            return .connectionLost
        case .loginFailed:
            return .signInRequired(status: 401)
        default:
            return .generic(detail: ftp.localizedDescription)
        }
    }
}
