import Foundation
import NDMCore

/// Coordinates queue of download engines and persists task state (NeatDBHelper role).
public actor DownloadManager {
    public typealias FileRecycler = @Sendable (URL) async throws -> Void

    private let store: DownloadStore
    private var settings: AppSettings
    private let supportRoot: URL
    private let fileRecycler: FileRecycler?
    private let capacityProvider: @Sendable (URL) -> Int64?
    private let sameVolumeProvider: @Sendable (URL, URL) -> Bool
    private var engines: [Int64: DownloadEngine] = [:]
    private var hlsEngines: [Int64: HLSEngine] = [:]
    private var ftpEngines: [Int64: FTPEngine] = [:]
    private var mkvEngines: [Int64: MKVMergeEngine] = [:]
    private var ytDlpEngines: [Int64: YtDlpEngine] = [:]
    private var runningTasks: [Int64: Task<Void, Never>] = [:]
    /// One user-facing transfer rate per task. Every window receives this same
    /// cached one-second sample instead of independently sampling the same byte
    /// counter on slightly different clocks.
    private var presentationSpeedSamplers: [Int64: OneSecondSpeedSampler] = [:]
    private var presentationSpeeds: [Int64: Double] = [:]
    /// Optional UI hook when a download completes successfully.
    public var onTaskCompleted: (@Sendable (DownloadTask) -> Void)?
    /// Optional UI hook when settings change (for ShowPanel push).
    public var onSettingsChanged: (@Sendable (AppSettings) -> Void)?

    public init(
        store: DownloadStore,
        settings: AppSettings,
        supportRoot: URL = DownloadStore.defaultSupportDirectory,
        fileRecycler: FileRecycler? = nil,
        capacityProvider: @escaping @Sendable (URL) -> Int64? = {
            VolumeCapacity.availableBytes(at: $0)
        },
        sameVolumeProvider: @escaping @Sendable (URL, URL) -> Bool = {
            VolumeCapacity.areOnSameVolume($0, $1)
        },
        onTaskCompleted: (@Sendable (DownloadTask) -> Void)? = nil
    ) {
        self.store = store
        self.settings = settings
        self.supportRoot = supportRoot
        self.fileRecycler = fileRecycler
        self.capacityProvider = capacityProvider
        self.sameVolumeProvider = sameVolumeProvider
        self.onTaskCompleted = onTaskCompleted
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
            return progressForPresentation(
                await engine.currentProgress(),
                taskID: taskID
            )
        }
        if let engine = hlsEngines[taskID] {
            return progressForPresentation(
                await engine.currentProgress(),
                taskID: taskID
            )
        }
        if let engine = ftpEngines[taskID] {
            return progressForPresentation(
                await engine.currentProgress(),
                taskID: taskID
            )
        }
        if let engine = mkvEngines[taskID] {
            return progressForPresentation(
                await engine.currentProgress(),
                taskID: taskID
            )
        }
        if let engine = ytDlpEngines[taskID] {
            return progressForPresentation(
                await engine.currentProgress(),
                taskID: taskID
            )
        }
        return nil
    }

    /// Internal for deterministic tests. The raw engine snapshot remains
    /// untouched except for its presentation rate.
    func progressForPresentation(
        _ progress: DownloadProgress,
        taskID: Int64,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> DownloadProgress {
        var sampler = presentationSpeedSamplers[taskID] ?? OneSecondSpeedSampler()
        let isFirstSample = presentationSpeedSamplers[taskID] == nil
        let average = sampler.consume(
            completedBytes: progress.completedBytes,
            reset: isFirstSample,
            now: now
        )
        presentationSpeedSamplers[taskID] = sampler
        if let average {
            presentationSpeeds[taskID] = average
        }

        var presented = progress
        presented.bytesPerSecond = presentationSpeeds[taskID] ?? 0
        return presented
    }

    private func resetPresentationSpeed(taskID: Int64) {
        presentationSpeedSamplers[taskID] = nil
        presentationSpeeds[taskID] = nil
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
        let filename = DownloadFilename.resolve(
            preferred: nil,
            contentDispositionName: nil,
            url: url,
            mimeType: nil,
            pageTitle: pageTitle
        )
        var task = DownloadTask(
            url: urlString,
            method: method,
            filename: filename,
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

    /// Persist an already-finished file (e.g. yt-dlp) as a completed task and
    /// fire the same completion hook as engine-backed downloads.
    @discardableResult
    public func recordCompletedFile(
        url: String,
        fileURL: URL,
        pageTitle: String? = nil,
        linkType: String = "ytdlp"
    ) async throws -> DownloadTask {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        var task = DownloadTask(
            url: url,
            filename: fileURL.lastPathComponent,
            linkType: linkType,
            fileSize: size,
            category: DownloadCategory.infer(filename: fileURL.lastPathComponent, mimeType: nil),
            status: .complete,
            connections: 1,
            lastTry: Date(),
            firstTry: Date(),
            completedAt: Date(),
            resumable: true,
            pageTitle: pageTitle,
            mimeType: "video/mp4",
            folderPath: fileURL.deletingLastPathComponent().path
        )
        task = try store.insert(task)
        onTaskCompleted?(task)
        return task
    }

    /// Create a yt-dlp-backed task that lands in the same download directory as
    /// ordinary downloads, then runs with live progress for the progress window.
    @discardableResult
    public func startYtDlp(
        url: String,
        formatID: String,
        options: YtDlpDownloadOptions = .init(),
        pageTitle: String?,
        estimatedBytes: Int64?,
        estimatedComponentBytes: [Int64] = [],
        preferredFilename: String?
    ) async throws -> DownloadTask {
        if !settings.downloadAllAtOnce, !runningTasks.isEmpty {
            throw ManagerError.queueBusy
        }
        try validateStorage(StorageBudget.media(
            sampleFinalBytes: estimatedBytes,
            sampleComponentBytes: estimatedComponentBytes,
            sampleDurationSeconds: nil
        ))
        let stem: String
        if let preferredFilename, !preferredFilename.isEmpty {
            stem = YtDlpTool.sanitizeFilename(preferredFilename)
        } else if let pageTitle, !pageTitle.isEmpty {
            stem = YtDlpTool.sanitizeFilename(pageTitle)
        } else {
            stem = "video"
        }
        let ext = options.container.fileExtension
        let filename = stem.lowercased().hasSuffix(".\(ext)") ? stem : "\(stem).\(ext)"

        var dest = settings.downloadDirectory
        var task = DownloadTask(
            url: url,
            filename: filename,
            linkType: "ytdlp",
            fileSize: max(0, estimatedBytes ?? 0),
            category: .video,
            status: .downloading,
            connections: max(1, min(32, settings.maxConnections)),
            lastTry: Date(),
            firstTry: Date(),
            resumable: false,
            pageTitle: pageTitle,
            hitTitle: formatID,
            mimeType: options.container.mimeType,
            postData: try? JSONEncoder().encode(options),
            folderPath: dest.path
        )
        if settings.useCategoryFolders {
            dest.appendPathComponent(task.category.rawValue.capitalized, isDirectory: true)
            task.folderPath = dest.path
        }
        task = try store.insert(task)
        let taskID = task.id

        let engine = YtDlpEngine(
            taskID: taskID,
            estimatedBytes: estimatedBytes ?? 0,
            estimatedComponentBytes: estimatedComponentBytes,
            connections: task.connections
        )
        ytDlpEngines[taskID] = engine
        let onComplete = onTaskCompleted
        runningTasks[taskID] = Task {
            await self.runEngine(
                taskID: taskID,
                task: task,
                store: store,
                onComplete: onComplete
            ) {
                try await engine.run(
                    url: url,
                    formatID: formatID,
                    directory: dest,
                    preferredName: stem,
                    options: options
                )
            }
            self.ytDlpEngines[taskID] = nil
        }
        return task
    }

    /// Add a collection as independent, recoverable tasks. Only one entry is
    /// launched automatically at a time so a 32-connection preference cannot
    /// multiply into hundreds of simultaneous sockets for a large playlist.
    @discardableResult
    public func enqueueYtDlpCollection(
        _ items: [YtDlpCollectionItem],
        formatID: String,
        options: YtDlpDownloadOptions = .init(),
        collectionURL: String,
        collectionTitle: String?,
        estimatedSampleBytes: Int64? = nil,
        estimatedSampleComponentBytes: [Int64] = [],
        sampleDurationSeconds: Double? = nil
    ) async throws -> [DownloadTask] {
        try validateStorage(StorageBudget.media(
            sampleFinalBytes: estimatedSampleBytes,
            sampleComponentBytes: estimatedSampleComponentBytes,
            sampleDurationSeconds: sampleDurationSeconds,
            collectionDurations: items.map(\.durationSeconds)
        ))
        let inserted = try insertYtDlpCollection(
            items,
            formatID: formatID,
            options: options,
            collectionURL: collectionURL,
            collectionTitle: collectionTitle
        )
        if runningTasks.isEmpty, let first = inserted.first {
            try await start(taskID: first.id)
        }
        return inserted
    }

    private func validateStorage(_ budget: StorageBudget) throws {
        guard let available = capacityProvider(settings.downloadDirectory),
              let required = budget.peakBytes else { return }
        let confidence = StorageConfidence(
            budget: budget,
            availableBytes: available
        )
        guard confidence.level != .insufficient else {
            throw ManagerError.insufficientStorage(
                requiredBytes: required,
                availableBytes: available
            )
        }
    }

    /// Injectable persistence boundary used by queue tests without launching
    /// the external media process.
    func insertYtDlpCollection(
        _ items: [YtDlpCollectionItem],
        formatID: String,
        options: YtDlpDownloadOptions = .init(),
        collectionURL: String,
        collectionTitle: String?
    ) throws -> [DownloadTask] {
        guard !items.isEmpty else { return [] }
        let width = max(2, String(items.count).count)
        var inserted: [DownloadTask] = []
        inserted.reserveCapacity(items.count)

        for (offset, item) in items.enumerated() {
            let number = String(format: "%0*d", width, offset + 1)
            let cleanTitle = YtDlpTool.sanitizeFilename(item.title)
            let stem = "\(number) - \(cleanTitle)"
            let ext = options.container.fileExtension
            var dest = settings.downloadDirectory
            var task = DownloadTask(
                url: item.url,
                filename: "\(stem).\(ext)",
                linkType: "ytdlp",
                fileSize: 0,
                category: .video,
                status: .waiting,
                connections: max(1, min(32, settings.maxConnections)),
                firstTry: Date(),
                resumable: false,
                pageURL: collectionURL,
                pageTitle: item.title.isEmpty ? collectionTitle : item.title,
                hitTitle: formatID,
                mimeType: options.container.mimeType,
                postData: try? JSONEncoder().encode(options),
                folderPath: dest.path
            )
            if settings.useCategoryFolders {
                dest.appendPathComponent(task.category.rawValue.capitalized, isDirectory: true)
                task.folderPath = dest.path
            }
            task = try store.insert(task)
            inserted.append(task)
        }

        return inserted
    }

    /// Host-side entry for browser extension messages (`handleBrowserDownloadRequest:`).
    public func addFromBridge(_ message: ParsedBridgeMessage) async throws -> DownloadTask {
        let headers = Self.bridgeHeaders(from: message)

        // Link Rescue: when the browser captures a fresh signed URL from the
        // same source page, attach it to the failed task instead of creating a
        // duplicate. The existing task id and partial seg.xN files stay intact,
        // so AppDelegate's normal start call resumes the original download.
        if var task = try linkRescueCandidate(for: message) {
            task.url = message.url
            task.method = message.method
            task.headers = headers
            task.errorText = nil
            task.status = .incomplete
            task.lastTry = Date()
            task.completedAt = nil
            if !message.pageURL.isEmpty {
                task.pageURL = message.pageURL
            } else if !message.referer.isEmpty {
                task.pageURL = message.referer
            }
            if !message.pageTitle.isEmpty { task.pageTitle = message.pageTitle }
            if !message.userAgent.isEmpty { task.userAgent = message.userAgent }
            if !message.contentType.isEmpty { task.mimeType = message.contentType }
            if message.fileSize > 0 { task.fileSize = Int64(message.fileSize) }
            task.postData = message.postData.map { Data($0.utf8) }
            task.alternateURL = message.alternateURL.isEmpty ? nil : message.alternateURL
            if !message.ltype.isEmpty { task.linkType = message.ltype }
            if Self.looksLikeHLS(url: task.url, filename: task.filename) {
                task.linkType = "hls"
            } else if task.alternateURL != nil {
                task.linkType = "media"
            }
            task.category = DownloadCategory.infer(filename: task.filename, mimeType: task.mimeType)
            try store.update(task)
            return task
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

    private func linkRescueCandidate(for message: ParsedBridgeMessage) throws -> DownloadTask? {
        let incomingPage = message.pageURL.isEmpty ? message.referer : message.pageURL
        guard let incomingKey = DuplicateDownloadMatcher.canonicalKey(for: incomingPage) else {
            return nil
        }
        return try store.allDownloads().first { task in
            guard task.status == .error,
                  task.linkType.lowercased() != "ytdlp",
                  let pageURL = task.pageURL,
                  DuplicateDownloadMatcher.canonicalKey(for: pageURL) == incomingKey,
                  let diagnostic = DownloadDiagnostic.fromStoredErrorText(task.errorText) else {
                return false
            }
            switch diagnostic {
            case .linkExpired, .signInRequired:
                // A dual-track task needs a fresh pair; mixing a new video URL
                // with stale audio authorization is worse than adding a new task.
                if task.alternateURL?.isEmpty == false, message.alternateURL.isEmpty {
                    return false
                }
                return true
            default:
                return false
            }
        }
    }

    private static func bridgeHeaders(from message: ParsedBridgeMessage) -> [String] {
        var headers: [String] = []
        if !message.origin.isEmpty { headers.append("Origin: \(message.origin)") }
        if !message.referer.isEmpty { headers.append("Referer: \(message.referer)") }
        if !message.cookies.isEmpty { headers.append("Cookie: \(message.cookies)") }
        if !message.reqContentType.isEmpty { headers.append("Content-Type: \(message.reqContentType)") }
        for (key, value) in message.extraHeaders.sorted(by: { $0.key < $1.key }) {
            headers.append("\(key): \(value)")
        }
        return headers
    }

    /// Fire-and-forget start (UI / bridge). Does not wait for completion.
    public func start(taskID: Int64) async throws {
        if runningTasks[taskID] != nil { return }
        resetPresentationSpeed(taskID: taskID)
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

        // Full re-download of a finished task — wipe stale segments so the engine
        // does not treat the previous merge as already done.
        let redownloadComplete = task.status == .complete
        if redownloadComplete {
            try? FileManager.default.removeItem(at: workDir)
            task.errorText = nil
        }
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // yt-dlp page downloads (retry after complete / error / incomplete).
        if task.linkType.lowercased() == "ytdlp" {
            // yt-dlp tasks created by earlier builds were persisted as one
            // connection. Reapply the current global setting on every start so
            // an old completed row also gets real concurrency when retried.
            task.connections = max(1, min(32, settings.maxConnections))
            let formatID: String
            if let stored = task.hitTitle, !stored.isEmpty {
                formatID = stored
            } else {
                formatID = "bv*+ba/b"
            }
            let preferredStem = (task.filename as NSString).deletingPathExtension
            let options = task.postData
                .flatMap { try? JSONDecoder().decode(YtDlpDownloadOptions.self, from: $0) }
                ?? YtDlpDownloadOptions(
                    container: task.filename.lowercased().hasSuffix(".mkv") ? .compactMKV : .compatibleMP4
                )
            let engine = YtDlpEngine(
                taskID: taskID,
                estimatedBytes: task.fileSize,
                connections: task.connections
            )
            ytDlpEngines[taskID] = engine
            task.status = .downloading
            task.lastTry = Date()
            task.completedAt = nil
            try store.update(task)
            let onComplete = onTaskCompleted
            let pageTitle = task.pageTitle
            let sourceURL = task.url
            runningTasks[taskID] = Task {
                await self.runEngine(
                    taskID: taskID,
                    task: task,
                    store: store,
                    onComplete: onComplete
                ) {
                    try await engine.run(
                        url: sourceURL,
                        formatID: formatID,
                        directory: dest,
                        preferredName: preferredStem.isEmpty ? pageTitle : preferredStem,
                        forceOverwrite: redownloadComplete,
                        options: options
                    )
                }
                self.ytDlpEngines[taskID] = nil
            }
            return
        }

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

        // Replace opaque CDN / branch names before the engine opens the file.
        if !DownloadFilename.isUseful(task.filename) {
            task.filename = DownloadFilename.resolve(
                preferred: task.filename,
                url: url,
                mimeType: task.mimeType,
                pageTitle: task.pageTitle
            )
            task.category = DownloadCategory.infer(filename: task.filename, mimeType: task.mimeType)
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
        task.completedAt = nil
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
                    onComplete: onComplete,
                    deliveryNote: { await engine.currentProgress().deliveryNote }
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
                autoTuneConnections: settings.smartConnectionsEnabled,
                capacityProvider: capacityProvider,
                sameVolumeProvider: sameVolumeProvider
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
        /// Reads a non-fatal delivery note from the engine once it has finished.
        /// Only engines that can degrade a successful delivery supply one.
        deliveryNote: () async -> DeliveryNote? = { nil },
        start: () async throws -> URL
    ) async {
        do {
            let fileURL = try await start()
            // Runtime edits (connections, bandwidth, renewed metadata) may have been
            // persisted while the engine was running. Do not overwrite them with the
            // stale task snapshot captured at start.
            var done = (try? store.allDownloads().first { $0.id == taskID }) ?? task
            done.status = .complete
            done.completedAt = Date()
            let producedCategory = DownloadCategory.infer(
                filename: fileURL.lastPathComponent,
                mimeType: done.mimeType
            )
            // Prefer the on-disk name, but never keep extensionless CDN tokens when
            // we can recover a real name + extension from the page title / MIME.
            var workingURL = fileURL
            let diskName = fileURL.lastPathComponent
            if !DownloadFilename.isUseful(diskName) {
                var recovered = DownloadFilename.resolve(
                    preferred: done.filename,
                    contentDispositionName: nil,
                    url: URL(string: done.url) ?? fileURL,
                    mimeType: done.mimeType,
                    pageTitle: done.pageTitle
                )
                // The engine already produced the real container — HLS in
                // particular remuxes to MP4 — while `recovered` is derived from the
                // request URL, whose extension may be a playlist or nothing at all.
                // Recovery exists to replace a meaningless *stem*; it must never
                // downgrade or drop the extension, or the delivered file stops
                // opening despite holding perfectly good video.
                let diskExtension = fileURL.pathExtension
                if !diskExtension.isEmpty,
                   (recovered as NSString).pathExtension.caseInsensitiveCompare(diskExtension) != .orderedSame {
                    recovered = (recovered as NSString).deletingPathExtension
                        + "." + diskExtension
                }
                if recovered != diskName {
                    let dest = fileURL.deletingLastPathComponent().appendingPathComponent(recovered)
                    let unique = uniqueDestination(dest)
                    if (try? FileManager.default.moveItem(at: fileURL, to: unique)) != nil {
                        workingURL = unique
                    }
                }
            }
            let finalizedURL: URL
            if producedCategory == .video || producedCategory == .audio,
               let naming = try? SmartFinalize.applySmartNaming(
                   primary: workingURL,
                   pageTitle: done.pageTitle
               ) {
                finalizedURL = naming.primaryURL
            } else {
                finalizedURL = workingURL
            }
            done.filename = finalizedURL.lastPathComponent
            done.folderPath = finalizedURL.deletingLastPathComponent().path
            let attrs = try? FileManager.default.attributesOfItem(atPath: finalizedURL.path)
            done.fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? done.fileSize
            done.category = DownloadCategory.infer(filename: done.filename, mimeType: done.mimeType)
            done.resumable = true
            done.errorText = nil
            done.deliveryNote = await deliveryNote()?.storageKey
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
        resetPresentationSpeed(taskID: taskID)
        guard runningTasks.isEmpty,
              let tasks = try? store.allDownloads(),
              let next = Self.queuedCollectionCandidate(in: tasks) else { return }
        Task { try? await self.start(taskID: next.id) }
    }

    /// Finder-style `name (2).ext` when the recovered name already exists.
    private func uniqueDestination(_ url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " (\(index))"
            let name = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    static func queuedCollectionCandidate(in tasks: [DownloadTask]) -> DownloadTask? {
        tasks
            .filter {
                $0.status == .waiting
                    && $0.linkType.lowercased() == "ytdlp"
                    && ($0.pageURL?.isEmpty == false)
            }
            .min { $0.id < $1.id }
    }

    public func pause(taskID: Int64) async {
        // Soft-stop sockets; partial `seg.xN` kept for resume on next start().
        await engines[taskID]?.pause()
        await hlsEngines[taskID]?.pause()
        await ftpEngines[taskID]?.pause()
        await mkvEngines[taskID]?.pause()
        await ytDlpEngines[taskID]?.pause()
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

    /// Resume the head of a persisted collection queue after relaunch. Each
    /// completion schedules the next entry through clearRunning.
    public func resumeQueuedCollectionIfIdle() async {
        guard runningTasks.isEmpty,
              let tasks = try? store.allDownloads(),
              let next = Self.queuedCollectionCandidate(in: tasks) else { return }
        try? await start(taskID: next.id)
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

    public func remove(taskID: Int64, deleteFile: Bool) async throws {
        guard let task = try store.allDownloads().first(where: { $0.id == taskID }) else {
            throw ManagerError.taskNotFound
        }
        let fileURL = deleteFile ? try Self.validatedRemovalURL(for: task) : nil

        // A removed task must not keep writing invisibly. Cancel every engine
        // first, then await the owning task so no late completion can recreate
        // the file after it has been moved to Trash.
        let runningTask = runningTasks[taskID]
        runningTask?.cancel()
        await engines[taskID]?.cancel()
        await hlsEngines[taskID]?.cancel()
        await ftpEngines[taskID]?.cancel()
        await mkvEngines[taskID]?.cancel()
        await ytDlpEngines[taskID]?.cancel()
        if let runningTask {
            await runningTask.value
        }

        // Past this point nothing is running for this task, whatever the row says.
        // A live download's own cancellation path records that, but a stored
        // `downloading` with no engine behind it does not — a crash leaves such
        // rows and nothing resets them at launch. If the removal below fails the
        // row survives, and a task presenting as downloading with no engine has no
        // progress, no speed and no way for the user to stop it. Re-read rather
        // than reusing the snapshot above so a concurrent update is not clobbered.
        if var current = try? store.allDownloads().first(where: { $0.id == taskID }),
           current.status == .downloading {
            current.status = .incomplete
            try? store.update(current)
        }

        // The engines above are already cancelled, and that cannot be undone, so
        // dropping their registrations is correct whether or not the removal goes
        // on to succeed — a cancelled engine must not stay registered.
        defer {
            engines[taskID] = nil
            hlsEngines[taskID] = nil
            ftpEngines[taskID] = nil
            mkvEngines[taskID] = nil
            ytDlpEngines[taskID] = nil
            runningTasks[taskID] = nil
            resetPresentationSpeed(taskID: taskID)
        }

        if let fileURL,
           FileManager.default.fileExists(atPath: fileURL.path) {
            guard let fileRecycler else {
                throw ManagerError.fileRecyclingUnavailable
            }
            try await fileRecycler(fileURL)
        }

        try store.delete(id: taskID)

        // Only now, with the row actually gone, is it safe to discard the resume
        // data. This deliberately does not run on the failure paths above: the
        // work directory holds `segments.bin` and the partial `seg.xN` files, so
        // deleting it while the row survives would leave a task that still
        // advertises itself as resumable with nothing to resume from — the user
        // would be told the removal failed while their partial transfer was
        // already destroyed.
        try? FileManager.default.removeItem(
            at: supportRoot.appendingPathComponent("\(taskID)", isDirectory: true)
        )
    }

    /// Resolve the persisted task destination without trusting filename path
    /// components. Both lexical traversal and symlink escape fail closed.
    static func validatedRemovalURL(for task: DownloadTask) throws -> URL? {
        guard let folderPath = task.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folderPath.isEmpty,
              !task.filename.isEmpty else {
            return nil
        }
        let filename = task.filename
        guard (folderPath as NSString).isAbsolutePath,
              (filename as NSString).lastPathComponent == filename,
              filename != ".",
              filename != ".." else {
            throw ManagerError.unsafeFileLocation
        }

        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let lexicalCandidate = URL(fileURLWithPath: folderPath, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
            .standardizedFileURL
        if let values = try? lexicalCandidate.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]), values.isDirectory == true || values.isSymbolicLink == true {
            throw ManagerError.unsafeFileLocation
        }
        let candidate = lexicalCandidate
            .resolvingSymlinksInPath()
        let folderPrefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        guard candidate.path.hasPrefix(folderPrefix) else {
            throw ManagerError.unsafeFileLocation
        }
        return candidate
    }
}

public enum ManagerError: Error, LocalizedError {
    case invalidURL
    case taskNotFound
    case downloadFailed(String)
    case queueBusy
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case unsafeFileLocation
    case fileRecyclingUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .taskNotFound: return "Task not found"
        case .downloadFailed(let m): return m
        case .queueBusy: return "Another download is active (one-by-one mode)"
        case .insufficientStorage(let required, let available):
            return L10n.storageGuardError(
                requiredBytes: required,
                availableBytes: available
            )
        case .unsafeFileLocation:
            return "The downloaded file is outside its recorded download folder. Nothing was removed."
        case .fileRecyclingUnavailable:
            return "This environment cannot move files to Trash. Nothing was removed."
        }
    }
}
