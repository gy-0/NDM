import Foundation

/// The follow-up a diagnostic recommends; UI uses it to pick button emphasis.
public enum DiagnosticAction: String, Sendable, Equatable {
    /// Re-fetch a fresh URL from the source page (expired signed links).
    case renew
    /// Plain retry is likely to succeed (transient network problems).
    case retry
    /// User must act in the browser first (sign in again), then retry.
    case openPage
    /// Informational only — nothing to do.
    case none
}

/// A download failure translated into language a person can act on.
///
/// The engine layer classifies raw errors (`DownloadDiagnostic.classify` in
/// NDMEngine) and the manager persists `storageString` into `task.errorText`.
/// Presentation parses it back so the copy always renders in the *current*
/// UI language, and the raw protocol code stays available for power users.
public enum DownloadDiagnostic: Equatable, Sendable {
    /// 403 / 404 / 410 — signed or temporary URLs that stopped working.
    case linkExpired(status: Int)
    /// 401 / 407 — the site (or proxy) wants credentials again.
    case signInRequired(status: Int)
    /// 416 or a server that ignores Range — resume/multi-connection unavailable.
    case rangeNotSupported
    /// 429 — server-side rate limiting.
    case serverThrottled
    /// 5xx — the server is having a bad day; retrying later usually works.
    case serverError(status: Int)
    /// Any other unexpected HTTP status.
    case httpError(status: Int)
    /// No network route at all.
    case offline
    /// Connection timed out.
    case timeout
    /// Transfer started, then the connection dropped.
    case connectionLost
    /// TLS handshake / certificate trouble.
    case sslFailure
    /// Local disk is out of space.
    case diskFull
    /// Segment merge failed after download.
    case mergeFailed(detail: String)
    /// Unclassified failure; carries the original message.
    case generic(detail: String)

    // MARK: - Raw code (corner label for power users)

    /// Short technical label, e.g. `HTTP 403`, `timeout`. Never localized.
    public var rawLabel: String {
        switch self {
        case .linkExpired(let s), .signInRequired(let s),
             .serverError(let s), .httpError(let s):
            return "HTTP \(s)"
        case .rangeNotSupported: return "HTTP 416 / no Range"
        case .serverThrottled: return "HTTP 429"
        case .offline: return "offline"
        case .timeout: return "timeout"
        case .connectionLost: return "connection lost"
        case .sslFailure: return "TLS"
        case .diskFull: return "disk full"
        case .mergeFailed: return "merge"
        case .generic: return "error"
        }
    }

    // MARK: - Human copy (design/NDM-Design-Suite.html §04 is the source of truth)

    /// One-line headline: what happened.
    public var title: String {
        switch self {
        case .linkExpired:
            return L10n.t("This download link has expired", "这个下载地址过期了")
        case .signInRequired:
            return L10n.t("The site wants you to sign in again", "网站要求重新登录")
        case .rangeNotSupported:
            return L10n.t("This server doesn't support segmented download", "该服务器不支持分段下载")
        case .serverThrottled:
            return L10n.t("The server is rate-limiting downloads", "服务器正在限制下载频率")
        case .serverError:
            return L10n.t("The server had a problem", "服务器出了点问题")
        case .httpError(let s):
            return L10n.t("The server refused the request (HTTP \(s))", "服务器拒绝了请求（HTTP \(s)）")
        case .offline:
            return L10n.t("No internet connection", "当前没有网络连接")
        case .timeout:
            return L10n.t("The server took too long to respond", "服务器响应超时")
        case .connectionLost:
            return L10n.t("The connection was interrupted", "连接中断了")
        case .sslFailure:
            return L10n.t("Couldn't establish a secure connection", "无法建立安全连接")
        case .diskFull:
            return L10n.t("Your disk is full", "磁盘空间不足")
        case .mergeFailed:
            return L10n.t("Couldn't assemble the downloaded pieces", "已下载分段合并失败")
        case .generic:
            return L10n.t("Download failed", "下载失败")
        }
    }

    /// Why it happened + what to do next, in plain language.
    public var message: String {
        switch self {
        case .linkExpired:
            return L10n.t(
                "Open the source page and start the download there once. The fresh browser handoff will attach to this same task; downloaded segments stay in place.",
                "打开来源页面并在那里再次开始下载。浏览器取得的新授权会自动接回这个任务，已经下载的分段原样保留。"
            )
        case .signInRequired:
            return L10n.t(
                "Sign in again in your browser, then start the download there once. The fresh browser session will continue this same task instead of creating a duplicate.",
                "请在浏览器重新登录，然后在那里再次开始下载。新的浏览器会话会继续这个任务，不会再创建一条重复记录。"
            )
        case .rangeNotSupported:
            return L10n.t(
                "It doesn't accept resume requests, so multi-connection can't help here. Downloads run on a single steady connection — the speed is whatever the server gives.",
                "它不接受断点续传请求，多连接对它无效。已用单连接稳定下载——速度就是服务器给多少是多少。"
            )
        case .serverThrottled:
            return L10n.t(
                "It answered with “too many requests”. Waiting a minute before retrying usually clears it; lowering connections for this host can also help.",
                "对方返回「请求过多」。通常等一分钟再重试即可；把该站点的连接数调低也有帮助。"
            )
        case .serverError:
            return L10n.t(
                "This is on their side, not yours. These errors are usually temporary — retrying in a bit tends to work.",
                "问题出在服务器一侧，不是你的网络。这类错误通常是暂时的，稍后重试大多能成功。"
            )
        case .httpError:
            return L10n.t(
                "The link may be wrong, region-locked, or require permissions this download doesn't have. Opening the page in your browser shows what the site expects.",
                "链接可能有误、有地区限制，或需要额外权限。在浏览器中打开来源页面可以看到网站的具体要求。"
            )
        case .offline:
            return L10n.t(
                "Check Wi-Fi or your network cable. The download will resume from where it stopped once you're back online.",
                "请检查 Wi-Fi 或网线。恢复联网后，下载会从断点自动继续。"
            )
        case .timeout:
            return L10n.t(
                "The server didn't answer in time. It may be overloaded or far away — retrying often works, and a proxy can help for distant servers.",
                "服务器迟迟没有响应，可能过载或距离太远。重试通常有效；访问远端服务器时使用代理往往更快。"
            )
        case .connectionLost:
            return L10n.t(
                "The transfer was cut off mid-way. Nothing is lost — retry and it resumes from the last byte that made it to disk.",
                "传输中途被切断。已下载内容不会丢失——重试后会从最后落盘的字节继续。"
            )
        case .sslFailure:
            return L10n.t(
                "The server's certificate couldn't be verified. If you're on public Wi-Fi or behind a proxy, that's the usual culprit.",
                "无法验证服务器证书。如果你在公共 Wi-Fi 或代理网络中，通常是它们造成的。"
            )
        case .diskFull:
            return L10n.t(
                "Free up space (or change the download folder in Settings), then retry — the finished part is kept.",
                "请清理磁盘空间（或在设置中更换下载目录）后重试——已完成的部分会保留。"
            )
        case .mergeFailed(let detail):
            return L10n.t(
                "The segments downloaded fine but couldn't be joined. Retrying re-runs just the merge. (\(detail))",
                "分段本身下载完好，但合并失败。重试只会重新执行合并。（\(detail)）"
            )
        case .generic(let detail):
            return L10n.t(
                "Retrying is worth a shot. Technical detail: \(detail)",
                "可以先重试一次。技术细节：\(detail)"
            )
        }
    }

    /// Short inline summary for the task list row: headline + the next step.
    public var rowSummary: String {
        switch self {
        case .linkExpired:
            return L10n.t(
                "Link expired · continue from the source page, segments are kept",
                "链接已过期 · 从来源页面继续，已有分段会保留"
            )
        case .signInRequired:
            return L10n.t(
                "Sign-in expired · continue once from the browser",
                "登录已失效 · 在浏览器重新登录并继续一次"
            )
        case .rangeNotSupported:
            return L10n.t(
                "No resume support · single connection only on this server",
                "不支持断点续传 · 该服务器仅能单连接下载"
            )
        case .serverThrottled:
            return L10n.t("Rate-limited by server · retry in a minute", "服务器限流 · 稍等一分钟再重试")
        case .serverError:
            return L10n.t("Server-side error · usually temporary, retry later", "服务器故障 · 通常是暂时的，稍后重试")
        case .httpError(let s):
            return L10n.t("Request refused (HTTP \(s)) · check the source page", "请求被拒 HTTP \(s) · 检查来源页面")
        case .offline:
            return L10n.t("No internet · resumes automatically when back online", "无网络 · 恢复联网后自动续传")
        case .timeout:
            return L10n.t("Server timed out · retry, or use a proxy", "服务器超时 · 可重试，远端站点建议代理")
        case .connectionLost:
            return L10n.t("Connection dropped · retry resumes from last byte", "连接中断 · 重试将从断点继续")
        case .sslFailure:
            return L10n.t("Secure connection failed · check Wi-Fi / proxy", "安全连接失败 · 检查 Wi-Fi 或代理")
        case .diskFull:
            return L10n.t("Disk full · free space and retry", "磁盘已满 · 清理空间后重试")
        case .mergeFailed:
            return L10n.t("Merge failed · retry re-runs the merge only", "合并失败 · 重试只重新合并")
        case .generic:
            return L10n.t("Failed · retry, details in Inspector", "下载失败 · 可重试，详情见右侧")
        }
    }

    /// The follow-up this diagnostic recommends.
    public var primaryAction: DiagnosticAction {
        switch self {
        case .linkExpired: return .renew
        case .signInRequired: return .openPage
        case .serverThrottled, .serverError, .timeout, .connectionLost,
             .diskFull, .mergeFailed, .generic:
            return .retry
        case .httpError: return .openPage
        case .rangeNotSupported, .offline, .sslFailure: return .none
        }
    }

    // MARK: - Classification helpers (protocol-level; error-object mapping lives in NDMEngine)

    public static func fromHTTPStatus(_ status: Int) -> DownloadDiagnostic {
        switch status {
        case 401, 407: return .signInRequired(status: status)
        case 403, 404, 410: return .linkExpired(status: status)
        case 416: return .rangeNotSupported
        case 429: return .serverThrottled
        case 500...599: return .serverError(status: status)
        default: return .httpError(status: status)
        }
    }

    public static func fromURLError(_ error: URLError) -> DownloadDiagnostic {
        switch error.code {
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            return .offline
        case .timedOut:
            return .timeout
        case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return .connectionLost
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .sslFailure
        default:
            return .generic(detail: error.localizedDescription)
        }
    }

    public static func fromCocoaError(_ error: NSError) -> DownloadDiagnostic? {
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileWriteOutOfSpaceError || error.code == NSFileWriteVolumeReadOnlyError {
            return .diskFull
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) {
            return .diskFull
        }
        return nil
    }

    // MARK: - Persistence (stored in task.errorText; copy re-localizes at render time)

    private static let storagePrefix = "#diag:"

    public var storageString: String {
        let body: String
        switch self {
        case .linkExpired(let s): body = "linkExpired:\(s)"
        case .signInRequired(let s): body = "signInRequired:\(s)"
        case .rangeNotSupported: body = "rangeNotSupported"
        case .serverThrottled: body = "serverThrottled"
        case .serverError(let s): body = "serverError:\(s)"
        case .httpError(let s): body = "httpError:\(s)"
        case .offline: body = "offline"
        case .timeout: body = "timeout"
        case .connectionLost: body = "connectionLost"
        case .sslFailure: body = "sslFailure"
        case .diskFull: body = "diskFull"
        case .mergeFailed(let d): body = "mergeFailed|\(d)"
        case .generic(let d): body = "generic|\(d)"
        }
        return Self.storagePrefix + body
    }

    public init?(storageString: String) {
        guard storageString.hasPrefix(Self.storagePrefix) else { return nil }
        let body = String(storageString.dropFirst(Self.storagePrefix.count))
        let detailSplit = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(detailSplit[0])
        let detail = detailSplit.count > 1 ? String(detailSplit[1]) : ""
        let parts = head.split(separator: ":", maxSplits: 1)
        let kind = parts.first.map(String.init) ?? ""
        let code = parts.count > 1 ? Int(parts[1]) : nil

        switch kind {
        case "linkExpired": self = .linkExpired(status: code ?? 403)
        case "signInRequired": self = .signInRequired(status: code ?? 401)
        case "rangeNotSupported": self = .rangeNotSupported
        case "serverThrottled": self = .serverThrottled
        case "serverError": self = .serverError(status: code ?? 500)
        case "httpError": self = .httpError(status: code ?? 0)
        case "offline": self = .offline
        case "timeout": self = .timeout
        case "connectionLost": self = .connectionLost
        case "sslFailure": self = .sslFailure
        case "diskFull": self = .diskFull
        case "mergeFailed": self = .mergeFailed(detail: detail)
        case "generic": self = .generic(detail: detail)
        default: return nil
        }
    }

    /// Parse persisted `task.errorText`. Returns nil for legacy plain-text errors.
    public static func fromStoredErrorText(_ text: String?) -> DownloadDiagnostic? {
        guard let text else { return nil }
        return DownloadDiagnostic(storageString: text)
    }
}

public extension DownloadTask {
    /// Source page that can mint a fresh browser-authorized media URL for this
    /// failed direct task. Page-level yt-dlp tasks retry their own stable URL
    /// and therefore do not use browser handoff here.
    var browserRescueURL: URL? {
        guard status == .error,
              linkType.lowercased() != "ytdlp",
              let diagnostic = DownloadDiagnostic.fromStoredErrorText(errorText) else {
            return nil
        }
        switch diagnostic {
        case .linkExpired, .signInRequired:
            break
        default:
            return nil
        }
        guard let pageURL,
              let url = URL(string: pageURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
