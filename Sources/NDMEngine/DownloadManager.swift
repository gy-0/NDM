import Foundation
import NDMCore

/// Coordinates queue of download engines and persists task state (NeatDBHelper role).
public actor DownloadManager {
    private let store: DownloadStore
    private var settings: AppSettings
    private let supportRoot: URL
    private var engines: [Int64: DownloadEngine] = [:]
    private var hlsEngines: [Int64: HLSEngine] = [:]
    private var ftpEngines: [Int64: FTPEngine] = [:]
    private var mkvEngines: [Int64: MKVMergeEngine] = [:]
    private var runningTasks: [Int64: Task<Void, Never>] = [:]
    /// Optional UI hook when a download completes successfully.
    public var onTaskCompleted: (@Sendable (DownloadTask) -> Void)?
    /// Optional UI hook when settings change (for ShowPanel push).
    public var onSettingsChanged: (@Sendable (AppSettings) -> Void)?

    public init(store: DownloadStore, settings: AppSettings, supportRoot: URL = DownloadStore.defaultSupportDirectory) {
        self.store = store
        self.settings = settings
        self.supportRoot = supportRoot
    }

    public func updateSettings(_ settings: AppSettings) {
        self.settings = settings
        onSettingsChanged?(settings)
    }

    public func setCompletionHandler(_ handler: (@Sendable (DownloadTask) -> Void)?) {
        onTaskCompleted = handler
    }

    public func setSettingsChangedHandler(_ handler: (@Sendable (AppSettings) -> Void)?) {
        onSettingsChanged = handler
    }

    public func listTasks() throws -> [DownloadTask] {
        try store.allDownloads()
    }

    public func progress(taskID: Int64) async -> DownloadProgress? {
        if let engine = engines[taskID] {
            return await engine.currentProgress()
        }
        if let engine = hlsEngines[taskID] {
            return await engine.currentProgress()
        }
        if let engine = ftpEngines[taskID] {
            return await engine.currentProgress()
        }
        if let engine = mkvEngines[taskID] {
            return await engine.currentProgress()
        }
        return nil
    }

    public func addURL(
        _ urlString: String,
        connections: Int? = nil,
        pageURL: String? = nil,
        pageTitle: String? = nil,
        headers: [String] = [],
        method: String = "GET",
        ltype: String = "normal"
    ) async throws -> DownloadTask {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "ftp" else {
            throw ManagerError.invalidURL
        }
        var resolvedType = ltype
        if resolvedType == "normal", Self.looksLikeHLS(url: urlString, filename: url.lastPathComponent) {
            resolvedType = "hls"
        }
        var task = DownloadTask(
            url: urlString,
            method: method,
            filename: url.lastPathComponent.isEmpty ? "download.bin" : url.lastPathComponent,
            linkType: resolvedType,
            connections: connections ?? settings.maxConnections,
            lastTry: Date(),
            firstTry: Date(),
            userAgent: settings.useCustomUserAgent ? settings.customUserAgent : nil,
            pageURL: pageURL,
            pageTitle: pageTitle,
            folderPath: settings.downloadDirectory.path,
            headers: headers
        )
        task.category = DownloadCategory.infer(filename: task.filename, mimeType: nil)
        task = try store.insert(task)
        return task
    }

    /// Host-side entry for browser extension messages (`handleBrowserDownloadRequest:`).
    public func addFromBridge(_ message: ParsedBridgeMessage) async throws -> DownloadTask {
        var headers: [String] = []
        if !message.origin.isEmpty { headers.append("Origin: \(message.origin)") }
        if !message.referer.isEmpty { headers.append("Referer: \(message.referer)") }
        if !message.cookies.isEmpty { headers.append("Cookie: \(message.cookies)") }
        if !message.reqContentType.isEmpty { headers.append("Content-Type: \(message.reqContentType)") }
        for (k, v) in message.extraHeaders {
            headers.append("\(k): \(v)")
        }
        var task = try await addURL(
            message.url,
            pageURL: message.pageURL.isEmpty ? message.referer : message.pageURL,
            pageTitle: message.pageTitle,
            headers: headers,
            method: message.method,
            ltype: message.ltype
        )
        if !message.filename.isEmpty {
            task.filename = message.filename
            if Self.looksLikeHLS(url: task.url, filename: task.filename) {
                task.linkType = "hls"
            }
        }
        if message.fileSize > 0 {
            task.fileSize = Int64(message.fileSize)
        }
        if !message.contentType.isEmpty {
            task.mimeType = message.contentType
        }
        if let post = message.postData {
            task.postData = Data(post.utf8)
        }
        if !message.alternateURL.isEmpty {
            task.alternateURL = message.alternateURL
            if task.linkType.lowercased() == "media" || task.linkType.lowercased() == "normal" {
                task.linkType = "media"
            }
        }
        if !message.userAgent.isEmpty {
            task.userAgent = message.userAgent
        }
        task.category = DownloadCategory.infer(filename: task.filename, mimeType: task.mimeType)
        try store.update(task)
        return task
    }

    /// Fire-and-forget start (UI / bridge). Does not wait for completion.
    public func start(taskID: Int64) async throws {
        if runningTasks[taskID] != nil { return }
        // One-by-one queue (original radioOneByOne): wait until no other engine is active.
        if !settings.downloadAllAtOnce, !runningTasks.isEmpty {
            throw ManagerError.queueBusy
        }
        let tasks = try store.allDownloads()
        guard var task = tasks.first(where: { $0.id == taskID }) else {
            throw ManagerError.taskNotFound
        }
        guard let url = URL(string: task.url) else { throw ManagerError.invalidURL }

        var dest = settings.downloadDirectory
        if settings.useCategoryFolders {
            dest.appendPathComponent(task.category.rawValue.capitalized, isDirectory: true)
        }

        // Per-task work dir: Application Support/.../<id>/  (original layout)
        let workDir = supportRoot.appendingPathComponent("\(taskID)", isDirectory: true)

        var headerMap: [String: String] = [:]
        for line in task.headers {
            if let idx = line.firstIndex(of: ":") {
                let name = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headerMap[name] = value
            }
        }

        var username = url.user
        var password = url.password
        if username == nil, let host = url.host,
           let cred = try? store.auth(forHost: host) {
            username = cred.username
            password = cred.password
        }

        let request = DownloadRequest(
            url: url,
            method: task.method,
            headers: headerMap,
            body: task.postData,
            userAgent: task.userAgent ?? (settings.useCustomUserAgent ? settings.customUserAgent : nil),
            connections: task.connections > 0 ? task.connections : settings.maxConnections,
            bandwidthLimitBytesPerSecond: task.bandwidthLimit,
            destinationDirectory: dest,
            suggestedFilename: task.filename.isEmpty ? nil : task.filename,
            pageURL: task.pageURL.flatMap(URL.init(string:)),
            pageTitle: task.pageTitle,
            username: username,
            password: password
        )

        let scheme = url.scheme?.lowercased() ?? ""
        let useFTP = scheme == "ftp"
        let useHLS = !useFTP && Self.isHLS(task)
        let useMKV = !useFTP && !useHLS
            && !(task.alternateURL ?? "").isEmpty
            && (task.linkType.lowercased() == "media" || (task.alternateURL ?? "").contains("://"))
        task.status = .downloading
        task.lastTry = Date()
        try store.update(task)

        let onComplete = onTaskCompleted
        if useFTP {
            let engine = FTPEngine(
                taskID: taskID,
                request: request,
                workDirectory: workDir,
                ftpProxy: settings.ftpProxy
            )
            ftpEngines[taskID] = engine
            runningTasks[taskID] = Task { [store] in
                await self.runEngine(
                    taskID: taskID,
                    task: task,
                    store: store,
                    onComplete: onComplete
                ) {
                    try await engine.start()
                }
            }
        } else if useMKV, let audioStr = task.alternateURL, let audioURL = URL(string: audioStr) {
            var audioReq = request
            audioReq.url = audioURL
            audioReq.suggestedFilename = "audio.bin"
            let engine = MKVMergeEngine(
                taskID: taskID,
                videoRequest: request,
                audioRequest: audioReq,
                workDirectory: workDir,
                httpProxy: settings.httpProxy,
                socksProxy: settings.socksProxy,
                globalBandwidthLimit: settings.bandwidthLimitBytesPerSecond
            )
            mkvEngines[taskID] = engine
            runningTasks[taskID] = Task { [store] in
                await self.runEngine(
                    taskID: taskID,
                    task: task,
                    store: store,
                    onComplete: onComplete
                ) {
                    try await engine.start()
                }
            }
        } else if useHLS {
            let engine = HLSEngine(
                taskID: taskID,
                request: request,
                workDirectory: workDir,
                httpProxy: settings.httpProxy,
                socksProxy: settings.socksProxy
            )
            hlsEngines[taskID] = engine
            runningTasks[taskID] = Task { [store] in
                await self.runEngine(
                    taskID: taskID,
                    task: task,
                    store: store,
                    onComplete: onComplete
                ) {
                    try await engine.start()
                }
            }
        } else {
            let engine = DownloadEngine(
                taskID: taskID,
                request: request,
                workDirectory: workDir,
                httpProxy: settings.httpProxy,
                socksProxy: settings.socksProxy,
                globalBandwidthLimit: settings.bandwidthLimitBytesPerSecond,
                autoTuneConnections: settings.smartConnectionsEnabled
            )
            engines[taskID] = engine
            runningTasks[taskID] = Task { [store] in
                await self.runEngine(
                    taskID: taskID,
                    task: task,
                    store: store,
                    onComplete: onComplete
                ) {
                    try await engine.start()
                }
            }
        }
    }

    private func runEngine(
        taskID: Int64,
        task: DownloadTask,
        store: DownloadStore,
        onComplete: (@Sendable (DownloadTask) -> Void)?,
        start: () async throws -> URL
    ) async {
        do {
            let fileURL = try await start()
            // Runtime edits (connections, bandwidth, renewed metadata) may have been
            // persisted while the engine was running. Do not overwrite them with the
            // stale task snapshot captured at start.
            var done = (try? store.allDownloads().first { $0.id == taskID }) ?? task
            done.status = .complete
            done.filename = fileURL.lastPathComponent
            done.folderPath = fileURL.deletingLastPathComponent().path
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            done.fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? done.fileSize
            done.category = DownloadCategory.infer(filename: done.filename, mimeType: done.mimeType)
            done.resumable = true
            done.errorText = nil
            try? store.update(done)
            onComplete?(done)
        } catch {
            var failed = (try? store.allDownloads().first { $0.id == taskID }) ?? task
            if case .paused = error as? EngineError {
                failed.status = .paused
            } else if case .cancelled = error as? EngineError {
                failed.status = .incomplete
            } else {
                failed.status = .error
            }
            if failed.status == .error {
                // Persist the structured diagnostic key; presentation re-localizes
                // it at render time (see DownloadDiagnostic.fromStoredErrorText).
                failed.errorText = DownloadDiagnostic.classify(error).storageString
            } else {
                failed.errorText = error.localizedDescription
            }
            try? store.update(failed)
        }
        clearRunning(taskID)
    }

    private static func isHLS(_ task: DownloadTask) -> Bool {
        if task.linkType.lowercased() == "hls" { return true }
        return looksLikeHLS(url: task.url, filename: task.filename)
    }

    private static func looksLikeHLS(url: String, filename: String) -> Bool {
        let name = filename.lowercased()
        let u = url.lowercased()
        return name.hasSuffix(".m3u8") || u.contains(".m3u8")
    }

    /// Await until the download finishes (tests / CLI).
    public func startAndWait(taskID: Int64) async throws {
        try await start(taskID: taskID)
        while runningTasks[taskID] != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let tasks = try store.allDownloads()
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        if task.status == .error {
            let stored = task.errorText
            let readable = DownloadDiagnostic.fromStoredErrorText(stored)
                .map { "\($0.title) [\($0.rawLabel)]" }
            throw ManagerError.downloadFailed(readable ?? stored ?? "error")
        }
        if task.status == .paused {
            throw EngineError.paused
        }
    }

    private func clearRunning(_ taskID: Int64) {
        runningTasks[taskID] = nil
    }

    public func pause(taskID: Int64) async {
        // Soft-stop sockets; partial `seg.xN` kept for resume on next start().
        await engines[taskID]?.pause()
        await hlsEngines[taskID]?.pause()
        await ftpEngines[taskID]?.pause()
        await mkvEngines[taskID]?.pause()
        // Let the engine task finish with EngineError.paused and update DB.
    }

    /// A06 — apply new connection count to a running/paused task (persisted + engine replan).
    public func applyConnections(taskID: Int64, count: Int) async throws {
        let n = max(1, min(count, 32))
        guard var task = try task(id: taskID) else { throw ManagerError.taskNotFound }
        task.connections = n
        try store.update(task)
        try await engines[taskID]?.applyConnectionsCount(n)
    }

    /// A08 — renew expired URL while keeping task id / partial segments.
    public func renewURL(taskID: Int64, newURL: String) throws {
        guard var task = try task(id: taskID) else { throw ManagerError.taskNotFound }
        guard URL(string: newURL) != nil else { throw ManagerError.invalidURL }
        task.url = newURL
        task.errorText = nil
        if task.status == .error { task.status = .incomplete }
        try store.update(task)
    }

    /// D08 — import rows from original Neat DB.
    public func importLegacyDB(from url: URL) throws -> Int {
        try LegacyDBImporter.importDownloads(from: url, into: store)
    }

    public func currentSettings() -> AppSettings { settings }

    public func hasActiveDownloads() -> Bool {
        !runningTasks.isEmpty
    }

    public func updateTask(_ task: DownloadTask) throws {
        try store.update(task)
    }

    public func task(id: Int64) throws -> DownloadTask? {
        try store.allDownloads().first { $0.id == id }
    }

    public func allAuths() throws -> [AuthCredential] {
        try store.allAuths()
    }

    public func saveAuth(_ auth: AuthCredential) throws -> AuthCredential {
        try store.insertAuth(auth)
    }

    public func deleteAuth(id: Int64) throws {
        try store.deleteAuth(id: id)
    }

    public func remove(taskID: Int64, deleteFile: Bool) throws {
        if deleteFile {
            let tasks = try store.allDownloads()
            if let t = tasks.first(where: { $0.id == taskID }),
               let folder = t.folderPath {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(t.filename)
                try? FileManager.default.removeItem(at: url)
            }
            try? FileManager.default.removeItem(at: supportRoot.appendingPathComponent("\(taskID)"))
        }
        try store.delete(id: taskID)
        engines[taskID] = nil
        hlsEngines[taskID] = nil
        ftpEngines[taskID] = nil
        mkvEngines[taskID] = nil
    }
}

public enum ManagerError: Error, LocalizedError {
    case invalidURL
    case taskNotFound
    case downloadFailed(String)
    case queueBusy

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .taskNotFound: return "Task not found"
        case .downloadFailed(let m): return m
        case .queueBusy: return "Another download is active (one-by-one mode)"
        }
    }
}
