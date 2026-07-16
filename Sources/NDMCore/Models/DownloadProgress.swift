import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public var taskID: Int64
    public var totalBytes: Int64
    public var completedBytes: Int64
    public var bytesPerSecond: Double
    public var segmentStates: [SegmentState]
    public var status: DownloadStatus
    public var errorDescription: String?

    public init(
        taskID: Int64,
        totalBytes: Int64 = 0,
        completedBytes: Int64 = 0,
        bytesPerSecond: Double = 0,
        segmentStates: [SegmentState] = [],
        status: DownloadStatus = .waiting,
        errorDescription: String? = nil
    ) {
        self.taskID = taskID
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.bytesPerSecond = bytesPerSecond
        self.segmentStates = segmentStates
        self.status = status
        self.errorDescription = errorDescription
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    public var remainingTime: TimeInterval? {
        guard bytesPerSecond > 0, totalBytes > completedBytes else { return nil }
        return Double(totalBytes - completedBytes) / bytesPerSecond
    }
}

public struct SegmentState: Sendable, Equatable, Identifiable {
    public var id: Int
    public var start: Int64
    public var end: Int64
    public var completed: Int64
    public var isFinished: Bool

    public init(id: Int, start: Int64, end: Int64, completed: Int64 = 0, isFinished: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.completed = completed
        self.isFinished = isFinished
    }

    public var length: Int64 { max(0, end - start + 1) }

    /// Real progress for this connection's byte range.
    ///
    /// Keep this separate from the whole-file progress: the UI uses one of
    /// these values for every live Range connection rather than painting a
    /// connection as a single categorical colour.
    public var fractionCompleted: Double {
        guard length > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(length)))
    }

    public var remainingBytes: Int64 {
        max(0, length - min(length, max(0, completed)))
    }
}

public struct DownloadRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var userAgent: String?
    public var connections: Int
    public var bandwidthLimitBytesPerSecond: Int64
    public var destinationDirectory: URL
    public var suggestedFilename: String?
    public var pageURL: URL?
    public var pageTitle: String?
    public var username: String?
    public var password: String?

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        userAgent: String? = nil,
        connections: Int = 8,
        bandwidthLimitBytesPerSecond: Int64 = 0,
        destinationDirectory: URL,
        suggestedFilename: String? = nil,
        pageURL: URL? = nil,
        pageTitle: String? = nil,
        username: String? = nil,
        password: String? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.userAgent = userAgent
        self.connections = connections
        self.bandwidthLimitBytesPerSecond = bandwidthLimitBytesPerSecond
        self.destinationDirectory = destinationDirectory
        self.suggestedFilename = suggestedFilename
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.username = username
        self.password = password
    }
}
