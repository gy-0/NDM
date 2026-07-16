import Foundation

/// Sidebar filters for the modern main window.
public enum SidebarFilter: String, CaseIterable, Sendable, Equatable {
    case all
    case active
    case queued
    case paused
    case completed
    case failed
    case video
    case audio
    case document
    case compressed
    case application
    case image

    public var title: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .queued: return "Queued"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .compressed: return "Compressed"
        case .application: return "App"
        case .image: return "Image"
        }
    }

    /// Sidebar section header; `nil` means this row is not a section break.
    public var section: String? {
        switch self {
        case .all: return "Status"
        case .video: return "Type"
        default: return nil
        }
    }

    public var isCategory: Bool {
        switch self {
        case .video, .audio, .document, .compressed, .application, .image:
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
            return task.status == .downloading
        case .queued:
            return task.status == .waiting
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
    public var etaText: String
    public var connectionsText: String
    public var urlText: String
    public var errorText: String?
    public var canStart: Bool
    public var canPause: Bool
    public var canRetry: Bool
    public var canRenew: Bool
    public var canOpen: Bool
    public var canShowInFinder: Bool
    public var canShowProgress: Bool
    public var primaryAction: TaskPrimaryAction
    public var segmentStates: [SegmentState]

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
        errorText: String?,
        canStart: Bool,
        canPause: Bool,
        canRetry: Bool,
        canRenew: Bool,
        canOpen: Bool,
        canShowInFinder: Bool,
        canShowProgress: Bool,
        primaryAction: TaskPrimaryAction,
        segmentStates: [SegmentState]
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
        self.errorText = errorText
        self.canStart = canStart
        self.canPause = canPause
        self.canRetry = canRetry
        self.canRenew = canRenew
        self.canOpen = canOpen
        self.canShowInFinder = canShowInFinder
        self.canShowProgress = canShowProgress
        self.primaryAction = primaryAction
        self.segmentStates = segmentStates
    }

    public static func make(task: DownloadTask, progress: DownloadProgress?) -> TaskRowPresentation {
        let host = TaskPresentationFormatting.host(from: task.url)
        let statusTitle = TaskPresentationFormatting.statusTitle(task.status)
        // Do not call FileManager.fileExists here — presentation runs on every
        // UI refresh and synchronous disk probes (Downloads / network / iCloud)
        // stall the main thread. Open/Reveal verify existence at action time.
        let hasDestination = task.destinationFileURL != nil

        let totalBytes = max(task.fileSize, progress?.totalBytes ?? 0)
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
        if task.status == .error {
            errorText = progress?.errorDescription ?? task.errorText
        } else {
            errorText = nil
        }

        let canStart = task.status == .paused
            || task.status == .incomplete
            || task.status == .error
            || task.status == .waiting
        let canPause = task.status == .downloading || task.status == .waiting
        let canRetry = task.status == .error
        let canRenew = task.status == .error || task.status == .paused || task.status == .incomplete
        let canOpen = task.status == .complete && hasDestination
        let canShowInFinder = task.status == .complete && hasDestination
        let canShowProgress = task.status != .complete

        let primary: TaskPrimaryAction
        switch task.status {
        case .complete:
            primary = canOpen ? .open : .none
        case .downloading, .waiting:
            primary = .showProgress
        case .paused, .incomplete, .error:
            primary = .start
        }

        let statusDetail: String
        if let errorText, !errorText.isEmpty {
            statusDetail = errorText
        } else if !host.isEmpty {
            statusDetail = host
        } else {
            statusDetail = statusTitle
        }

        return TaskRowPresentation(
            taskID: task.id,
            filename: task.filename.isEmpty ? "Untitled" : task.filename,
            host: host,
            statusTitle: statusTitle,
            statusDetail: statusDetail,
            progressFraction: fraction,
            progressText: TaskPresentationFormatting.percent(fraction),
            sizeText: TaskPresentationFormatting.sizePair(completed: completedBytes, total: totalBytes),
            speedText: TaskPresentationFormatting.speed(speed, status: task.status),
            etaText: TaskPresentationFormatting.eta(eta, status: task.status),
            connectionsText: "\(task.connections)",
            urlText: task.url,
            errorText: errorText,
            canStart: canStart,
            canPause: canPause,
            canRetry: canRetry,
            canRenew: canRenew,
            canOpen: canOpen,
            canShowInFinder: canShowInFinder,
            canShowProgress: canShowProgress,
            primaryAction: primary,
            // Per-connection detail belongs in the progress window; avoid
            // copying/sorting segment arrays on every main-list refresh.
            segmentStates: []
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
        case .incomplete: return "Incomplete"
        case .complete: return "Completed"
        case .paused: return "Paused"
        case .downloading: return "Downloading"
        case .error: return "Failed"
        case .waiting: return "Queued"
        }
    }

    public static func percent(_ fraction: Double) -> String {
        let clamped = min(1, max(0, fraction))
        return String(format: "%.0f%%", clamped * 100)
    }

    public static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    public static func sizePair(completed: Int64, total: Int64) -> String {
        if total > 0 {
            return "\(byteCount(completed)) / \(byteCount(total))"
        }
        if completed > 0 {
            return byteCount(completed)
        }
        return "—"
    }

    public static func speed(_ bytesPerSecond: Double, status: DownloadStatus) -> String {
        guard status == .downloading, bytesPerSecond > 0 else { return "—" }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return "\(formatted)/s"
    }

    public static func eta(_ interval: TimeInterval?, status: DownloadStatus) -> String {
        guard status == .downloading, let interval, interval.isFinite, interval > 0 else { return "—" }
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
