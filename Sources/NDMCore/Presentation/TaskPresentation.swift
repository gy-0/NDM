import Foundation

/// Sidebar filters for the modern main window.
public enum SidebarFilter: String, CaseIterable, Sendable, Equatable {
    case all
    case active
    case queued
    case paused
    case completed
    case failed

    public var title: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .queued: return "Queued"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
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
        self.canOpen = canOpen
        self.canShowInFinder = canShowInFinder
        self.canShowProgress = canShowProgress
        self.primaryAction = primaryAction
        self.segmentStates = segmentStates
    }

    public static func make(task: DownloadTask, progress: DownloadProgress?) -> TaskRowPresentation {
        let host = TaskPresentationFormatting.host(from: task.url)
        let statusTitle = TaskPresentationFormatting.statusTitle(task.status)
        let fileExists = task.destinationFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        let totalBytes = max(task.fileSize, progress?.totalBytes ?? 0)
        let completedBytes: Int64
        let fraction: Double
        let speed: Double
        let eta: TimeInterval?
        let segments: [SegmentState]

        if task.status == .complete {
            completedBytes = totalBytes
            fraction = 1
            speed = 0
            eta = nil
            segments = progress?.segmentStates ?? []
        } else if let progress {
            completedBytes = progress.completedBytes
            fraction = progress.fractionCompleted
            speed = progress.bytesPerSecond
            eta = progress.remainingTime
            segments = progress.segmentStates
        } else {
            completedBytes = 0
            fraction = 0
            speed = 0
            eta = nil
            segments = []
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
        let canOpen = task.status == .complete && fileExists
        let canShowInFinder = task.status == .complete && fileExists
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
            canOpen: canOpen,
            canShowInFinder: canShowInFinder,
            canShowProgress: canShowProgress,
            primaryAction: primary,
            segmentStates: segments.sorted { $0.id < $1.id }
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
    public var canDelete: Bool
    public var canShowProgress: Bool
    public var canShowProperties: Bool
    public var canOpen: Bool
    public var canShowInFinder: Bool

    public static let none = TaskSelectionActions(
        canStart: false,
        canPause: false,
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
            canDelete: true,
            canShowProgress: row.canShowProgress,
            canShowProperties: true,
            canOpen: row.canOpen,
            canShowInFinder: row.canShowInFinder
        )
    }
}
