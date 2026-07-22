import Foundation

/// Sidebar filters for the modern main window.
public enum SidebarFilter: String, CaseIterable, Sendable, Equatable {
    case all
    case active
    case paused
    case completed
    case failed
    case video
    case audio
    case document
    case compressed
    case application
    case image
    case other

    public var title: String {
        switch self {
        case .all: return L10n.all
        case .active: return L10n.active
        // This bucket combines explicitly paused and interrupted/incomplete
        // work, so an action-oriented label is truthful for both states.
        case .paused: return L10n.toResume
        case .completed: return L10n.completed
        case .failed: return L10n.failed
        case .video: return L10n.video
        case .audio: return L10n.audio
        case .document: return L10n.document
        case .compressed: return L10n.compressed
        case .application: return L10n.appCategory
        case .image: return L10n.image
        case .other: return L10n.other
        }
    }

    /// Sidebar section header; `nil` means this row is not a section break.
    public var section: String? {
        switch self {
        case .all: return L10n.status
        case .video: return L10n.type
        default: return nil
        }
    }

    public var isCategory: Bool {
        switch self {
        case .video, .audio, .document, .compressed, .application, .image, .other:
            return true
        default:
            return false
        }
    }

    public func matches(_ task: DownloadTask) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            // Queued (waiting for its turn in one-by-one mode) is "in
            // progress" from the user's view — no separate 排队中 filter.
            return task.status == .downloading || task.status == .waiting
        case .paused:
            return task.status == .paused || task.status == .incomplete
        case .completed:
            return task.status == .complete
        case .failed:
            return task.status == .error
        case .video:
            return task.category == .video
        case .audio:
            return task.category == .audio
        case .document:
            return task.category == .document
        case .compressed:
            return task.category == .compressed
        case .application:
            return task.category == .application
        case .image:
            return task.category == .image
        case .other:
            return task.category == .misc
        }
    }

    public static func counts(in tasks: [DownloadTask]) -> [SidebarFilter: Int] {
        var result: [SidebarFilter: Int] = [:]
        for filter in SidebarFilter.allCases {
            result[filter] = tasks.filter(filter.matches).count
        }
        return result
    }
}

/// Which primary gesture (double-click) should run for a task.
public enum TaskPrimaryAction: String, Sendable, Equatable {
    case open
    case showProgress
    case start
    case none
}

/// Pure presentation for one download row / inspector snapshot.
public struct TaskRowPresentation: Equatable, Sendable {
    public var taskID: Int64
    public var filename: String
    public var host: String
    public var statusTitle: String
    public var statusDetail: String
    public var progressFraction: Double
    public var progressText: String
    public var sizeText: String
    public var speedText: String
    /// Raw transfer rate for animated displays (0 when not downloading).
    public var speedBytesPerSecond: Double
    /// True during byte-less yt-dlp post-processing (merge / subtitles /
    /// finalize) — surfaces let the UI show a "working" state instead of a
    /// frozen bar at 98% with 0 KB/s.
    public var isFinalizing: Bool = false
    public var etaText: String
    public var connectionsText: String
    public var urlText: String
    /// Local destination used only for native preview generation in the UI.
    public var localFileURL: URL?
    public var errorText: String?
    /// Parsed human diagnostic when the stored error is structured (`#diag:`);
    /// nil for legacy plain-text errors and non-error states.
    public var diagnostic: DownloadDiagnostic?
    /// "Why is it this fast" — smart connection tuning note while downloading.
    public var tuningNote: String?
    public var canStart: Bool
    public var canPause: Bool
    public var canRetry: Bool
    public var canRenew: Bool
    public var canOpen: Bool
    public var canShowInFinder: Bool
    public var canShowProgress: Bool
    public var isComplete: Bool
    public var primaryAction: TaskPrimaryAction
    public var segmentStates: [SegmentState]
    /// Design Suite badge, e.g. "HLS → MP4". Nil when not applicable.
    public var mediaBadge: String?
    /// True while downloading — list trailing leads with bold speed.
    public var isDownloading: Bool
    public var isFailed: Bool
    public var isQueued: Bool

    /// Completed downloads don't need a progress bar in list / inspector.
    public var showsProgressBar: Bool { isDownloading || isQueued }

    public init(
        taskID: Int64,
        filename: String,
        host: String,
        statusTitle: String,
        statusDetail: String,
        progressFraction: Double,
        progressText: String,
        sizeText: String,
        speedText: String,
        etaText: String,
        connectionsText: String,
        urlText: String,
        localFileURL: URL? = nil,
        errorText: String?,
        diagnostic: DownloadDiagnostic? = nil,
        tuningNote: String? = nil,
        canStart: Bool,
        canPause: Bool,
        canRetry: Bool,
        canRenew: Bool,
        canOpen: Bool,
        canShowInFinder: Bool,
        canShowProgress: Bool,
        isComplete: Bool,
        primaryAction: TaskPrimaryAction,
        segmentStates: [SegmentState],
        mediaBadge: String? = nil,
        isDownloading: Bool = false,
        isFailed: Bool = false,
        isQueued: Bool = false,
        speedBytesPerSecond: Double = 0,
        isFinalizing: Bool = false
    ) {
        self.taskID = taskID
        self.filename = filename
        self.host = host
        self.statusTitle = statusTitle
        self.statusDetail = statusDetail
        self.progressFraction = progressFraction
        self.progressText = progressText
        self.sizeText = sizeText
        self.speedText = speedText
        self.etaText = etaText
        self.connectionsText = connectionsText
        self.urlText = urlText
        self.localFileURL = localFileURL
        self.errorText = errorText
        self.diagnostic = diagnostic
        self.tuningNote = tuningNote
        self.canStart = canStart
        self.canPause = canPause
        self.canRetry = canRetry
        self.canRenew = canRenew
        self.canOpen = canOpen
        self.canShowInFinder = canShowInFinder
        self.canShowProgress = canShowProgress
        self.isComplete = isComplete
        self.primaryAction = primaryAction
        self.segmentStates = segmentStates
        self.mediaBadge = mediaBadge
        self.isDownloading = isDownloading
        self.isFailed = isFailed
        self.isQueued = isQueued
        self.speedBytesPerSecond = speedBytesPerSecond
        self.isFinalizing = isFinalizing
    }

    public static func make(task: DownloadTask, progress: DownloadProgress?) -> TaskRowPresentation {
        let host = TaskPresentationFormatting.host(from: task.url)
        let statusTitle = TaskPresentationFormatting.statusTitle(task.status)
        // Do not call FileManager.fileExists here — presentation runs on every
        // UI refresh and synchronous disk probes (Downloads / network / iCloud)
        // stall the main thread. Open/Reveal verify existence at action time.
        let hasDestination = task.destinationFileURL != nil

        let isYtDlp = task.linkType.lowercased() == "ytdlp"
        let totalBytes = isYtDlp && (progress?.totalBytes ?? 0) > 0
            ? (progress?.totalBytes ?? 0)
            : max(task.fileSize, progress?.totalBytes ?? 0)
        let completedBytes: Int64
        let fraction: Double
        let speed: Double
        let eta: TimeInterval?

        if task.status == .complete {
            completedBytes = totalBytes
            fraction = 1
            speed = 0
            eta = nil
        } else if let progress {
            completedBytes = progress.completedBytes
            fraction = progress.fractionCompleted
            speed = progress.bytesPerSecond
            eta = progress.remainingTime
        } else {
            completedBytes = 0
            fraction = 0
            speed = 0
            eta = nil
        }

        let errorText: String?
        let diagnostic: DownloadDiagnostic?
        if task.status == .error {
            let stored = progress?.errorDescription ?? task.errorText
            diagnostic = DownloadDiagnostic.fromStoredErrorText(stored)
            // Rows show the human summary; legacy plain-text errors pass through.
            errorText = diagnostic?.rowSummary ?? stored
        } else {
            errorText = nil
            diagnostic = nil
        }

        let canStart = task.status == .paused
            || task.status == .incomplete
            || task.status == .error
            || task.status == .waiting
        let canPause = task.status == .downloading || task.status == .waiting
        // Incomplete / error / complete all expose Retry — completed re-runs the
        // download (overwrite). Paused / waiting keep using Start / Resume.
        let canRetry = task.status == .error
            || task.status == .incomplete
            || task.status == .complete
        let canRenew = task.status == .error || task.status == .paused || task.status == .incomplete
            || task.status == .complete
        let canOpen = task.status == .complete && hasDestination
        let canShowInFinder = task.status == .complete && hasDestination
        // The same window becomes the completed result page after a task
        // finishes, so users must be able to reopen it later for subtitles and
        // Delivery Recipes — not only while bytes are moving.
        let canShowProgress = true

        let primary: TaskPrimaryAction
        switch task.status {
        case .complete:
            primary = canOpen ? .open : .none
        case .downloading, .waiting:
            primary = .showProgress
        case .paused, .incomplete, .error:
            primary = .start
        }

        let ext = (task.filename as NSString).pathExtension.lowercased()
        let isHLS = ["hls", "m3u8"].contains(task.linkType.lowercased())
        let mediaBadge: String? = (task.status == .complete && isHLS && ext == "mp4")
            ? L10n.hlsToMp4Badge
            : nil

        // Design Suite subtitles — every line answers "how's it going".
        // Completed rows: UI already prefixes "Completed ·", so detail must NOT repeat it.
        let statusDetail: String
        if let errorText, !errorText.isEmpty {
            statusDetail = errorText
        } else if task.status == .complete {
            if mediaBadge != nil {
                statusDetail = L10n.completedReadyToShare
            } else {
                statusDetail = ""
            }
        } else if task.status == .waiting {
            statusDetail = L10n.queuedWillStart
        } else if task.status == .downloading {
            var parts: [String] = []
            if progress?.phase == .preparing {
                parts.append(L10n.ytdlpPreparingShort)
            } else if progress?.phase == .merging {
                parts.append(L10n.ytdlpMergingShort)
            } else if progress?.phase == .subtitles {
                parts.append(L10n.ytdlpPreparingSubtitlesShort)
            } else if progress?.phase == .finalizing {
                parts.append(L10n.ytdlpFinalizingShort)
            } else if isYtDlp {
                parts.append(TaskPresentationFormatting.byteCount(completedBytes))
                if task.fileSize > 0 { parts.append(L10n.estimatedSize(task.fileSize)) }
            } else {
                parts.append(TaskPresentationFormatting.sizePair(completed: completedBytes, total: totalBytes))
            }
            if task.connections > 1 {
                parts.append(L10n.connectionsCount(task.connections))
            }
            let etaText = TaskPresentationFormatting.eta(eta, status: task.status)
            if etaText != L10n.emDash && etaText != "—" {
                parts.append("≈ \(etaText)")
            }
            statusDetail = parts.joined(separator: " · ")
        } else {
            statusDetail = statusTitle
        }

        let sizeText: String
        if task.status == .complete, totalBytes > 0 {
            sizeText = TaskPresentationFormatting.byteCount(totalBytes)
        } else if isYtDlp, task.fileSize > 0 {
            sizeText = L10n.estimatedSize(task.fileSize)
        } else {
            sizeText = TaskPresentationFormatting.sizePair(completed: completedBytes, total: totalBytes)
        }

        return TaskRowPresentation(
            taskID: task.id,
            filename: task.filename.isEmpty ? L10n.untitled : task.filename,
            host: host,
            statusTitle: statusTitle,
            statusDetail: statusDetail,
            progressFraction: fraction,
            progressText: task.status == .complete ? L10n.completed : TaskPresentationFormatting.percent(fraction),
            sizeText: sizeText,
            speedText: TaskPresentationFormatting.speed(speed, status: task.status),
            etaText: TaskPresentationFormatting.eta(eta, status: task.status),
            connectionsText: "\(task.connections)",
            urlText: task.url,
            localFileURL: task.destinationFileURL,
            errorText: errorText,
            diagnostic: diagnostic,
            tuningNote: task.status == .downloading ? progress?.tuning?.inspectorNote : nil,
            canStart: canStart,
            canPause: canPause,
            canRetry: canRetry,
            canRenew: canRenew,
            canOpen: canOpen,
            canShowInFinder: canShowInFinder,
            canShowProgress: canShowProgress,
            isComplete: task.status == .complete,
            primaryAction: primary,
            // Carry live segments only while downloading — the Now Downloading
            // hero renders them as a parallel-connection strip. Idle rows keep
            // this empty so list diffing stays cheap.
            segmentStates: task.status == .downloading ? (progress?.segmentStates ?? []) : [],
            mediaBadge: mediaBadge,
            isDownloading: task.status == .downloading,
            isFailed: task.status == .error,
            isQueued: task.status == .waiting,
            speedBytesPerSecond: task.status == .downloading ? speed : 0,
            isFinalizing: task.status == .downloading
                && [.merging, .subtitles, .finalizing].contains(progress?.phase)
        )
    }
}

public enum TaskPresentationFormatting {
    public static func host(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            return ""
        }
        return host
    }

    public static func statusTitle(_ status: DownloadStatus) -> String {
        switch status {
        case .incomplete: return L10n.incomplete
        case .complete: return L10n.completed
        case .paused: return L10n.paused
        case .downloading: return L10n.downloading
        case .error: return L10n.failed
        case .waiting: return L10n.queued
        }
    }

    public static func categoryTitle(_ category: DownloadCategory) -> String {
        switch category {
        case .video: return L10n.video
        case .audio: return L10n.audio
        case .document: return L10n.document
        case .compressed: return L10n.compressed
        case .application: return L10n.appCategory
        case .image: return L10n.image
        case .misc: return L10n.other
        }
    }

    public static func linkTypeTitle(_ ltype: String) -> String? {
        switch ltype.lowercased() {
        case "", "normal": return nil
        case "hls", "m3u8": return L10n.hlsStream
        case "mkv", "mkva", "mkvv": return L10n.multiTrackMedia
        case "ftp": return L10n.ftp
        default: return ltype.uppercased()
        }
    }

    public static func percent(_ fraction: Double) -> String {
        let clamped = min(1, max(0, fraction))
        return String(format: "%.0f%%", clamped * 100)
    }

    public static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = .useAll
        formatter.includesUnit = true
        formatter.isAdaptive = true
        // "0 KB", never the spelled-out "Zero KB" in list rows.
        formatter.allowsNonnumericFormatting = false
        // ByteCountFormatter picks unit labels from the process locale; keep numeric style consistent.
        return formatter.string(fromByteCount: max(0, bytes))
    }

    public static func sizePair(completed: Int64, total: Int64) -> String {
        if total > 0 {
            return "\(byteCount(completed)) / \(byteCount(total))"
        }
        if completed > 0 {
            return byteCount(completed)
        }
        return L10n.emDash
    }

    public static func speed(_ bytesPerSecond: Double, status: DownloadStatus) -> String {
        guard status == .downloading, bytesPerSecond > 0 else { return L10n.emDash }
        let formatted = byteCount(Int64(bytesPerSecond))
        return L10n.usesChinese ? "\(formatted)/秒" : "\(formatted)/s"
    }

    public static func eta(_ interval: TimeInterval?, status: DownloadStatus) -> String {
        guard status == .downloading, let interval, interval.isFinite, interval > 0 else { return L10n.emDash }
        if L10n.usesChinese {
            if interval < 60 {
                return String(format: "%.0f秒", interval)
            }
            if interval < 3600 {
                let minutes = Int(interval) / 60
                let seconds = Int(interval) % 60
                return "\(minutes)分 \(String(format: "%02d", seconds))秒"
            }
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            return "\(hours)小时 \(String(format: "%02d", minutes))分"
        }
        if interval < 60 {
            return String(format: "%.0fs", interval)
        }
        if interval < 3600 {
            let minutes = Int(interval) / 60
            let seconds = Int(interval) % 60
            return String(format: "%dm %02ds", minutes, seconds)
        }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return String(format: "%dh %02dm", hours, minutes)
    }

    public static func matchesSearch(_ task: DownloadTask, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let q = trimmed.lowercased()
        if task.filename.lowercased().contains(q) { return true }
        if task.url.lowercased().contains(q) { return true }
        if let host = URL(string: task.url)?.host?.lowercased(), host.contains(q) { return true }
        if let page = task.pageTitle?.lowercased(), page.contains(q) { return true }
        return false
    }

    public static func filteredTasks(
        _ tasks: [DownloadTask],
        filter: SidebarFilter,
        search: String
    ) -> [DownloadTask] {
        tasks.filter { filter.matches($0) && matchesSearch($0, query: search) }
    }
}

/// Toolbar / selection enablement derived from the current selection.
public struct TaskSelectionActions: Equatable, Sendable {
    public var canStart: Bool
    public var canPause: Bool
    public var canRetry: Bool
    public var canRenew: Bool
    public var canDelete: Bool
    public var canShowProgress: Bool
    public var canShowProperties: Bool
    public var canOpen: Bool
    public var canShowInFinder: Bool

    public static let none = TaskSelectionActions(
        canStart: false,
        canPause: false,
        canRetry: false,
        canRenew: false,
        canDelete: false,
        canShowProgress: false,
        canShowProperties: false,
        canOpen: false,
        canShowInFinder: false
    )

    public static func make(from row: TaskRowPresentation?) -> TaskSelectionActions {
        guard let row else { return .none }
        return TaskSelectionActions(
            canStart: row.canStart,
            canPause: row.canPause,
            canRetry: row.canRetry,
            canRenew: row.canRenew,
            canDelete: true,
            canShowProgress: row.canShowProgress,
            canShowProperties: true,
            canOpen: row.canOpen,
            canShowInFinder: row.canShowInFinder
        )
    }
}
