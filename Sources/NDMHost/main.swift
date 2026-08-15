import Foundation
import Network
import NDMCore
import NDMEngine
import NDMBridge

let port = NWEndpoint.Port(rawValue: UInt16(ProcessInfo.processInfo.environment["NDM_HOST_PORT"] ?? "51874") ?? 51874)!
let queue = DispatchQueue(label: "ndm.host")

let environment = ProcessInfo.processInfo.environment
let support: URL
if let override = environment["NDM_SUPPORT_DIR"], !override.isEmpty {
    support = URL(fileURLWithPath: override, isDirectory: true)
} else {
    support = DownloadStore.defaultSupportDirectory
}
let store: DownloadStore
do {
    store = try DownloadStore(directory: support)
    try store.recoverInterruptedTasks()
} catch {
    FileHandle.standardError.write(Data("NDMHost: cannot open store: \(error)\n".utf8))
    exit(1)
}

var currentSettings = SettingsStore.load()
if let rawBridgePort = environment["NDM_BRIDGE_PORT"], let bridgePort = UInt16(rawBridgePort) {
    currentSettings.bridgePort = bridgePort
}

let manager = DownloadManager(
    store: store,
    settings: currentSettings,
    supportRoot: support,
    fileRecycler: { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }
)

enum HostRequestError: LocalizedError {
    case collectionUnavailable

    var errorDescription: String? {
        switch self {
        case .collectionUnavailable:
            return "没有可加入队列的合集条目，请重新解析后再试"
        }
    }
}

final class Hub: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func add(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
    }

    func remove(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    func send(_ data: Data) {
        lock.lock()
        let all = Array(connections.values)
        lock.unlock()
        for connection in all {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }
}

let hub = Hub()

func embeddedFilename(in rawURL: String) -> String? {
    guard let url = URL(string: rawURL),
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
        return nil
    }
    for item in items {
        let key = item.name.lowercased()
        guard key.contains("filename") || key.contains("disposition") || key == "rscd" else { continue }
        let decoded = (item.value ?? "").removingPercentEncoding ?? item.value ?? ""
        if key.contains("filename"), !decoded.isEmpty {
            return (decoded as NSString).lastPathComponent
        }
        for field in decoded.split(separator: ";") {
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0].lowercased().contains("filename") else { continue }
            var value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.lowercased().hasPrefix("utf-8''") { value.removeFirst(7) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            value = value.removingPercentEncoding ?? value
            if !value.isEmpty { return (value as NSString).lastPathComponent }
        }
    }
    return nil
}

func applyFilename(_ filename: String, to task: inout DownloadTask, overrideDirectory: URL? = nil) {
    let clean = DownloadFilename.sanitize(filename)
    guard !clean.isEmpty else { return }
    task.filename = clean
    task.category = DownloadCategory.infer(filename: clean, mimeType: task.mimeType)
    task.folderPath = DownloadDestinationPolicy.directory(
        defaultDirectory: currentSettings.downloadDirectory,
        override: overrideDirectory,
        category: task.category,
        organizeByCategory: currentSettings.useCategoryFolders
    ).path
}

// Older desktop builds classified opaque signed CDN paths as media pages before
// looking at the embedded filename. Repair only unambiguous ordinary files so a
// retry does not send an installer or document through yt-dlp again.
if let persisted = try? store.allDownloads() {
    for var task in persisted where task.linkType.lowercased() == "ytdlp" {
        let filename = embeddedFilename(in: task.url)
        guard MediaLinkClassifier.looksLikeOrdinaryFileDownload(
            task.url,
            suggestedFilename: filename ?? task.filename
        ) else { continue }
        task.linkType = "normal"
        if let filename { applyFilename(filename, to: &task) }
        try? store.update(task)
    }
}

Task {
    await manager.setCompletionHandler { _ in
        Task {
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        }
    }
}

// Start Browser WebSocket Bridge for Chrome / Edge / Firefox extensions
let bridge = BrowserBridge(port: currentSettings.bridgePort)
bridge.onDownloadMessage = { msg in
    Task {
        do {
            var headerList: [String] = []
            if !msg.cookies.isEmpty { headerList.append("Cookie: \(msg.cookies)") }
            if !msg.userAgent.isEmpty { headerList.append("User-Agent: \(msg.userAgent)") }
            if !msg.referer.isEmpty { headerList.append("Referer: \(msg.referer)") }
            for (k, v) in msg.extraHeaders {
                headerList.append("\(k): \(v)")
            }

            var ltype = msg.ltype
            let capturedFilename = msg.filename.isEmpty ? embeddedFilename(in: msg.url) : msg.filename
            let ordinaryFile = MediaLinkClassifier.looksLikeOrdinaryFileDownload(
                msg.url,
                suggestedFilename: capturedFilename
            )
            if !ordinaryFile && (ltype.lowercased() == "media-page" || MediaLinkClassifier.looksLikeMediaPage(msg.url) || msg.url.contains("youtube.com") || msg.url.contains("youtu.be") || msg.url.contains("bilibili.com")) {
                broadcast([
                    "op": "openMediaComposer",
                    "url": msg.url,
                    "pageTitle": msg.pageTitle
                ])
                return
            } else if ordinaryFile {
                ltype = "normal"
            }

            var task = try await manager.addURL(
                msg.url,
                connections: currentSettings.maxConnections,
                pageURL: msg.pageURL.isEmpty ? nil : msg.pageURL,
                pageTitle: msg.pageTitle.isEmpty ? nil : msg.pageTitle,
                headers: headerList,
                method: msg.method,
                ltype: ltype
            )
            if let capturedFilename, !capturedFilename.isEmpty {
                applyFilename(capturedFilename, to: &task)
                try? store.update(task)
            }
            try? await manager.start(taskID: task.id)
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        } catch {
            FileHandle.standardError.write(Data("NDMHost: browser bridge error: \(error)\n".utf8))
        }
    }
}
bridge.onClientCountChanged = { count in
    guard count > 0 else { return }
    for message in BridgeConstants.showPanelMessages(enabled: currentSettings.showBrowserMediaPanel) {
        bridge.sendToAllClients(message)
    }
}
do {
    try bridge.start()
    FileHandle.standardError.write(Data("NDMHost: Browser bridge listening on port \(currentSettings.bridgePort)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("NDMHost: Browser bridge failed to start on port \(currentSettings.bridgePort): \(error)\n".utf8))
}

var legacyBridge: BrowserBridge? = nil
if currentSettings.bridgePort != BridgeConstants.legacyNeatPort {
    let leg = BrowserBridge(port: BridgeConstants.legacyNeatPort)
    leg.onDownloadMessage = bridge.onDownloadMessage
    leg.onClientCountChanged = bridge.onClientCountChanged
    do {
        try leg.start()
        legacyBridge = leg
        FileHandle.standardError.write(Data("NDMHost: Legacy browser bridge listening on port \(BridgeConstants.legacyNeatPort)\n".utf8))
    } catch {
        // Port 10007 might be busy
    }
}

func jsonObject(_ value: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: value, options: [])) ?? Data("{}".utf8)
}

func sendJSON(_ connection: NWConnection, _ value: Any) {
    var data = jsonObject(value)
    data.append(0x0A)
    connection.send(content: data, completion: .contentProcessed { _ in })
}

func broadcast(_ value: Any) {
    var data = jsonObject(value)
    data.append(0x0A)
    hub.send(data)
}

func settingsJSON(_ s: AppSettings) -> [String: Any] {
    var dict: [String: Any] = [
        "downloadDirectory": s.downloadDirectory.path,
        "maxConnections": s.maxConnections,
        "bandwidthLimitBytesPerSecond": NSNumber(value: s.bandwidthLimitBytesPerSecond),
        "useCategoryFolders": s.useCategoryFolders,
        "downloadAllAtOnce": s.downloadAllAtOnce,
        "smartConnections": s.smartConnectionsEnabled,
        "bridgePort": NSNumber(value: s.bridgePort)
    ]
    if let http = s.httpProxy {
        dict["httpProxyHost"] = http.host
        dict["httpProxyPort"] = Int(http.port)
        dict["httpProxyEnabled"] = http.enabled
    }
    if let socks = s.socksProxy {
        dict["socksProxyHost"] = socks.host
        dict["socksProxyPort"] = Int(socks.port)
        dict["socksProxyEnabled"] = socks.enabled
    }
    return dict
}

func taskJSON(_ task: DownloadTask, progress: DownloadProgress?) -> [String: Any] {
    let completed = progress?.completedBytes ?? (task.status == .complete ? task.fileSize : 0)
    let speed = progress?.bytesPerSecond ?? 0
    // Persisted terminal states are authoritative. A completed/failed/paused
    // task can briefly retain its last in-memory progress object; surfacing
    // that stale `.downloading` value makes the shell lie. The only promotion
    // we need is the real startup race where persistence still says waiting.
    let liveStatus = progress?.status
    let status = task.status == .waiting && liveStatus == .downloading
        ? DownloadStatus.downloading.rawValue
        : task.status.rawValue
    let phase = status == DownloadStatus.downloading.rawValue ? progress?.phase?.rawValue : nil
    let connections = progress.map {
        $0.currentConnections > 0 ? $0.currentConnections : task.connections
    } ?? task.connections
    let segments = (progress?.segmentStates ?? []).map { segment in
        [
            "id": segment.id,
            "fraction": segment.fractionCompleted as Double
        ] as [String: Any]
    }
    let source = URL(string: task.pageURL ?? task.url)?.host
    // For yt-dlp tasks hitTitle stores the selected formatID, not a title.
    let displayTitle: String
    if task.linkType.lowercased() == "ytdlp" {
        displayTitle = task.pageTitle ?? task.filename
    } else {
        displayTitle = task.hitTitle ?? task.pageTitle ?? task.filename
    }
    var row: [String: Any] = [
        "id": NSNumber(value: task.id),
        "filename": task.filename,
        "title": displayTitle,
        "url": task.url,
        "category": task.category.rawValue,
        "status": status,
        "fileSize": NSNumber(value: progress?.totalBytes ?? task.fileSize),
        "completedBytes": NSNumber(value: completed),
        "progressFraction": progress?.fractionCompleted ?? (task.status == .complete ? 1 : 0),
        "bytesPerSecond": speed,
        "connections": connections,
        "segments": segments,
        "folderPath": task.folderPath ?? ""
    ]
    if let source { row["source"] = source }
    if let pageURL = task.pageURL { row["pageURL"] = pageURL }
    if let thumbnailURL = task.thumbnailURL { row["thumbnailURL"] = thumbnailURL }
    if let phase { row["phase"] = phase }
    if let data = task.postData,
       let options = try? JSONDecoder().decode(YtDlpDownloadOptions.self, from: data) {
        row["mediaOptions"] = [
            "container": options.container.rawValue,
            "subtitleLanguage": options.subtitleLanguage ?? ""
        ] as [String: Any]
        if let collectionID = options.collectionID, !collectionID.isEmpty {
            row["collection"] = [
                "id": collectionID,
                "title": options.collectionTitle ?? "",
                "index": options.collectionIndex ?? 0,
                "count": options.collectionCount ?? 0
            ] as [String: Any]
        }
    }
    if let errorText = task.errorText {
        row["errorText"] = errorText
        if let diagnostic = DownloadDiagnostic.fromStoredErrorText(errorText) {
            row["diagnostic"] = [
                "title": diagnostic.title,
                "message": diagnostic.message(hasSavedData: completed > 0),
                "summary": diagnostic.rowSummary(hasSavedData: completed > 0),
                "primaryAction": diagnostic.primaryAction.rawValue
            ]
        }
    }
    return row
}

/// Browser-session retries stay deliberately uncached, but they still need
/// the same collection-aware preparation as the default MediaPreflightStore.
/// This keeps a cookie-gated playlist from becoming a misleading single item.
func prepareMediaWithBrowserSession(url: String, browser: String) async throws -> MediaPreflightResult {
    let expanded = await ShortLinkExpander.expand(url)
    let source: YtDlpCookieSource = .browser(browser)
    let isCollection = MediaLinkClassifier.looksLikeCollectionURL(expanded.resolvedURL)
    let collection = isCollection
        ? try? await YtDlpTool.probeCollection(url: expanded.resolvedURL, cookieSource: source)
        : nil

    var mediaURL = expanded.resolvedURL
    let probe: YtDlpProbe
    if isCollection,
       !MediaLinkClassifier.hasExplicitSingleMedia(expanded.resolvedURL),
       let first = collection?.items.first {
        mediaURL = first.url
        probe = try await YtDlpTool.probe(url: first.url, cookieSource: source)
    } else {
        do {
            probe = try await YtDlpTool.probe(url: expanded.resolvedURL, cookieSource: source)
        } catch {
            guard let first = collection?.items.first else { throw error }
            mediaURL = first.url
            probe = try await YtDlpTool.probe(url: first.url, cookieSource: source)
        }
    }

    return MediaPreflightResult(
        originalURL: expanded.originalURL,
        resolvedURL: expanded.resolvedURL,
        mediaURL: mediaURL,
        didExpandShortLink: expanded.didExpand,
        probe: probe,
        collection: collection
    )
}

func snapshot(activeOnly: Bool = false) async -> [[String: Any]] {
    let tasks = (try? await manager.listTasks()) ?? []
    let newest = tasks.sorted {
        let left = $0.mostRecentActivity ?? .distantPast
        let right = $1.mostRecentActivity ?? .distantPast
        return left == right ? $0.id > $1.id : left > right
    }
    var rows: [[String: Any]] = []
    for task in newest {
        let progress = await manager.progress(taskID: task.id)
        if activeOnly {
            // A newly-created task may still be persisted as `.waiting` while
            // its in-memory engine is already transferring. Filter by the live
            // status when it exists so the 4 Hz partial stream never strands
            // the renderer on the stale queued row.
            let status = progress?.status ?? task.status
            guard status == .downloading || status == .waiting else { continue }
        }
        rows.append(taskJSON(task, progress: progress))
    }
    return rows
}

func duplicateJSON(for urlStrings: [String]) async -> [String: Any]? {
    let tasks = (try? await manager.listTasks()) ?? []
    guard let match = DuplicateDownloadMatcher.bestMatch(for: urlStrings, in: tasks) else {
        return nil
    }
    return taskJSON(match, progress: await manager.progress(taskID: match.id))
}

func handle(request: [String: Any], connection: NWConnection) async {
    let id = request["id"] as? Int ?? 0
    let op = request["op"] as? String ?? ""
    do {
        switch op {
        case "ping":
            sendJSON(connection, ["id": id, "ok": true, "engine": "NDMHost"])
        case "list":
            sendJSON(connection, ["id": id, "ok": true, "tasks": await snapshot()])
        case "findDuplicate":
            let urls = (request["urls"] as? [String])
                ?? (request["url"] as? String).map { [$0] }
                ?? []
            var response: [String: Any] = ["id": id, "ok": true]
            if let duplicate = await duplicateJSON(for: urls) {
                response["duplicate"] = duplicate
            }
            sendJSON(connection, response)
        case "getSettings":
            sendJSON(connection, ["id": id, "ok": true, "settings": settingsJSON(currentSettings)])
        case "updateSettings":
            if let dir = request["downloadDirectory"] as? String, !dir.isEmpty {
                currentSettings.downloadDirectory = URL(fileURLWithPath: dir)
            }
            if let conns = request["maxConnections"] as? Int, conns > 0 {
                currentSettings.maxConnections = conns
            }
            if let speed = request["bandwidthLimitBytesPerSecond"] as? Int64 ?? (request["bandwidthLimitBytesPerSecond"] as? Int).map(Int64.init) {
                currentSettings.bandwidthLimitBytesPerSecond = speed
            }
            if let catFolders = request["useCategoryFolders"] as? Bool {
                currentSettings.useCategoryFolders = catFolders
            }
            if let httpHost = request["httpProxyHost"] as? String {
                let port = UInt16(request["httpProxyPort"] as? Int ?? 8080)
                let enabled = request["httpProxyEnabled"] as? Bool ?? true
                currentSettings.httpProxy = httpHost.isEmpty ? nil : ProxySettings(host: httpHost, port: port, enabled: enabled)
            }
            if let socksHost = request["socksProxyHost"] as? String {
                let port = UInt16(request["socksProxyPort"] as? Int ?? 1080)
                let enabled = request["socksProxyEnabled"] as? Bool ?? true
                currentSettings.socksProxy = socksHost.isEmpty ? nil : SocksProxySettings(host: socksHost, port: port, version: .v5, enabled: enabled)
            }
            SettingsStore.save(currentSettings)
            await manager.updateSettings(currentSettings)
            sendJSON(connection, ["id": id, "ok": true, "settings": settingsJSON(currentSettings)])
        case "probeMedia":
            guard let url = request["url"] as? String, !url.isEmpty else {
                throw ManagerError.invalidURL
            }
            do {
                let probe: YtDlpProbe
                var prepared: MediaPreflightResult?
                if let browser = request["cookieBrowser"] as? String,
                   ["chrome", "firefox", "safari", "edge", "brave", "chromium"].contains(browser) {
                    // Browser-cookie access is an explicit retry chosen by the user.
                    // Keep the default probe private and cacheable; never read a
                    // browser profile unless this request includes that choice.
                    let preflight = try await prepareMediaWithBrowserSession(url: url, browser: browser)
                    prepared = preflight
                    probe = preflight.probe
                } else {
                    // Reuse the engine's session cache so reopening the same page is
                    // instant and simultaneous UI/browser probes share one yt-dlp job.
                    let preflight = try await MediaPreflightStore.shared.result(for: url)
                    prepared = preflight
                    probe = preflight.probe
                }
                let formats = probe.formats.map { f in
                    [
                        "id": f.id,
                        "label": f.label,
                        "height": f.height,
                        "approximateBytes": NSNumber(value: f.approximateBytes ?? 0),
                        "componentBytes": f.componentBytes.map { NSNumber(value: $0) },
                        "compactApproximateBytes": NSNumber(value: f.compactApproximateBytes ?? f.approximateBytes ?? 0),
                        "compactComponentBytes": (f.compactComponentBytes.isEmpty ? f.componentBytes : f.compactComponentBytes).map { NSNumber(value: $0) },
                        "containerHint": f.containerHint,
                        "isVideo": f.isVideo
                    ] as [String: Any]
                }
                let subtitles = probe.subtitleTracks.map { track in
                    [
                        "code": track.code,
                        "displayName": track.displayName,
                        "isAutomatic": track.isAutomatic
                    ] as [String: Any]
                }
                var response: [String: Any] = [
                    "id": id,
                    "ok": true,
                    "title": probe.title,
                    "duration": probe.durationSeconds ?? 0,
                    "thumbnailURL": probe.thumbnailURL ?? "",
                    "formats": formats,
                    "subtitles": subtitles,
                    "mediaURL": prepared?.mediaURL ?? url
                ]
                if let collection = prepared?.collection {
                    response["collection"] = [
                        "title": collection.title,
                        "itemCount": collection.totalCount,
                        "availableItemCount": collection.items.count,
                        "isTruncated": collection.isTruncated,
                        "thumbnailURL": collection.thumbnailURL ?? ""
                    ] as [String: Any]
                }
                if let prepared {
                    var currentURLs = [prepared.mediaURL]
                    if prepared.collection == nil
                        || MediaLinkClassifier.hasExplicitSingleMedia(prepared.resolvedURL) {
                        currentURLs.append(prepared.resolvedURL)
                    }
                    if let duplicate = await duplicateJSON(for: currentURLs) {
                        response["duplicateCurrent"] = duplicate
                    }
                    if prepared.collection != nil,
                       let duplicate = await duplicateJSON(for: [prepared.resolvedURL]) {
                        response["duplicateCollection"] = duplicate
                    }
                }
                sendJSON(connection, response)
            } catch {
                let errorKind: String
                switch YtDlpTool.accessIssue(error: error) {
                case .browserSessionRequired: errorKind = "browserSessionRequired"
                case .browserDataUnavailable: errorKind = "browserDataUnavailable"
                case nil: errorKind = "probeFailed"
                }
                sendJSON(connection, [
                    "id": id,
                    "ok": false,
                    "error": error.localizedDescription,
                    "errorKind": errorKind
                ])
            }
        case "checkStorage":
            guard let folderPath = request["folderPath"] as? String, !folderPath.isEmpty else {
                throw ManagerError.invalidURL
            }
            let budget: StorageBudget
            if request["collectionScope"] as? String == "all",
               let url = request["url"] as? String,
               let formatID = request["formatID"] as? String {
                let prepared = try await MediaPreflightStore.shared.result(for: url)
                guard let format = prepared.probe.formats.first(where: { $0.id == formatID }),
                      let collection = prepared.collection else {
                    throw ManagerError.invalidURL
                }
                let container: YtDlpContainerPreference = request["container"] as? String == "compactMKV"
                    ? .compactMKV
                    : .compatibleMP4
                budget = StorageBudget.media(
                    sampleFinalBytes: format.estimatedBytes(for: container),
                    sampleComponentBytes: format.estimatedComponentBytes(for: container),
                    sampleDurationSeconds: prepared.probe.durationSeconds,
                    collectionDurations: collection.items.map(\.durationSeconds)
                )
            } else {
                let finalBytes = request["finalBytes"] as? Int64
                    ?? (request["finalBytes"] as? Int).map(Int64.init)
                let componentBytes = (request["componentBytes"] as? [NSNumber])?.map(\.int64Value) ?? []
                budget = StorageBudget.media(
                    sampleFinalBytes: finalBytes,
                    sampleComponentBytes: componentBytes,
                    sampleDurationSeconds: nil
                )
            }
            let available = VolumeCapacity.availableBytes(at: URL(fileURLWithPath: folderPath, isDirectory: true))
            let confidence = StorageConfidence(budget: budget, availableBytes: available)
            let level: String
            switch confidence.level {
            case .unknown: level = "unknown"
            case .comfortable: level = "comfortable"
            case .tight: level = "tight"
            case .insufficient: level = "insufficient"
            }
            sendJSON(connection, [
                "id": id,
                "ok": true,
                "level": level,
                "peakBytes": NSNumber(value: budget.peakBytes ?? 0),
                "finalBytes": NSNumber(value: budget.finalBytes ?? 0),
                "isCollectionEstimate": budget.isCollectionEstimate,
                "availableBytes": NSNumber(value: available ?? 0),
                "projectedFreeBytes": NSNumber(value: confidence.projectedFreeBytes ?? 0),
                "shortfallBytes": NSNumber(value: confidence.shortfallBytes)
            ])
        case "addMedia":
            guard let url = request["url"] as? String, !url.isEmpty,
                  let requestedFormatID = request["formatID"] as? String, !requestedFormatID.isEmpty else {
                throw ManagerError.invalidURL
            }
            let allowedBrowsers = ["chrome", "firefox", "safari", "edge", "brave", "chromium"]
            let cookieBrowser = (request["cookieBrowser"] as? String).flatMap {
                allowedBrowsers.contains($0) ? $0 : nil
            }
            let prepared: MediaPreflightResult
            if let cookieBrowser {
                prepared = try await prepareMediaWithBrowserSession(url: url, browser: cookieBrowser)
            } else {
                prepared = try await MediaPreflightStore.shared.result(for: url)
            }
            guard let format = prepared.probe.formats.first(where: { $0.id == requestedFormatID }) else {
                throw ManagerError.invalidURL
            }
            let container: YtDlpContainerPreference = request["container"] as? String == "compactMKV"
                ? .compactMKV
                : .compatibleMP4
            let subtitleLanguage = (request["subtitleLanguage"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let options = YtDlpDownloadOptions(
                container: container,
                subtitleLanguage: subtitleLanguage,
                cookieSource: cookieBrowser.map { .browser($0) }
            )
            let destination = (request["folderPath"] as? String).flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
            }
            let scope = request["collectionScope"] as? String ?? "current"
            if scope == "all" {
                guard let collection = prepared.collection, !collection.items.isEmpty else {
                    throw HostRequestError.collectionUnavailable
                }
                let tasks = try await manager.enqueueYtDlpCollection(
                    collection.items,
                    formatID: format.collectionSelector(for: container),
                    options: options,
                    collectionURL: prepared.resolvedURL,
                    collectionTitle: collection.title,
                    collectionThumbnailURL: collection.thumbnailURL,
                    estimatedSampleBytes: format.estimatedBytes(for: container),
                    estimatedSampleComponentBytes: format.estimatedComponentBytes(for: container),
                    sampleDurationSeconds: prepared.probe.durationSeconds,
                    destinationDirectory: destination
                )
                var rows: [[String: Any]] = []
                rows.reserveCapacity(tasks.count)
                for task in tasks {
                    rows.append(taskJSON(task, progress: await manager.progress(taskID: task.id)))
                }
                guard let first = rows.first else { throw HostRequestError.collectionUnavailable }
                sendJSON(connection, ["id": id, "ok": true, "task": first, "tasks": rows])
                broadcast(["op": "snapshot", "tasks": await snapshot()])
            } else {
                let preferredFilename = request["filename"] as? String
                let task = try await manager.startYtDlp(
                    url: prepared.mediaURL,
                    formatID: format.selector(for: container),
                    options: options,
                    pageTitle: prepared.probe.title,
                    pageURL: prepared.resolvedURL,
                    thumbnailURL: prepared.probe.thumbnailURL ?? prepared.collection?.thumbnailURL,
                    estimatedBytes: format.estimatedBytes(for: container),
                    estimatedComponentBytes: format.estimatedComponentBytes(for: container),
                    preferredFilename: preferredFilename,
                    destinationDirectory: destination
                )
                let row = taskJSON(task, progress: await manager.progress(taskID: task.id))
                sendJSON(connection, ["id": id, "ok": true, "task": row, "tasks": [row]])
                broadcast(["op": "snapshot", "tasks": await snapshot()])
            }
        case "add":
            guard let url = request["url"] as? String, !url.isEmpty else {
                throw ManagerError.invalidURL
            }
            let connections = request["connections"] as? Int
            let pageURL = request["pageURL"] as? String
            let pageTitle = request["pageTitle"] as? String
            let thumbnailURL = request["thumbnailURL"] as? String
            let formatID = request["formatID"] as? String
            var ltype = request["ltype"] as? String ?? "normal"
            if formatID != nil || MediaLinkClassifier.looksLikeMediaPage(url) || url.contains("youtube.com") || url.contains("youtu.be") || url.contains("bilibili.com") {
                ltype = "ytdlp"
            }
            var destinationDirectory: URL? = nil
            if let folderPath = request["folderPath"] as? String, !folderPath.isEmpty {
                destinationDirectory = URL(fileURLWithPath: folderPath)
            }
            var task = try await manager.addURL(
                url,
                connections: connections,
                pageURL: pageURL,
                pageTitle: pageTitle,
                ltype: ltype,
                destinationDirectory: destinationDirectory
            )
            if let thumbnailURL, URL(string: thumbnailURL)?.scheme?.lowercased() == "https" {
                task.thumbnailURL = thumbnailURL
                try? store.update(task)
            }
            if let formatID, !formatID.isEmpty {
                task.hitTitle = formatID
                try? store.update(task)
            }
            let explicitFilename = (request["filename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedFilename = explicitFilename?.isEmpty == false ? explicitFilename : embeddedFilename(in: url)
            if let resolvedFilename, !resolvedFilename.isEmpty {
                applyFilename(resolvedFilename, to: &task, overrideDirectory: destinationDirectory)
                try? store.update(task)
            }
            let autoStart = request["autoStart"] as? Bool ?? true
            if autoStart {
                do {
                    try await manager.start(taskID: task.id)
                    task = try await manager.task(id: task.id) ?? task
                } catch ManagerError.queueBusy {
                    // Task sits in the queue; the shell already shows waiting.
                }
            }
            sendJSON(connection, ["id": id, "ok": true, "task": taskJSON(task, progress: nil)])
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        case "pause":
            guard let taskID = request["taskID"] as? Int64 ?? (request["taskID"] as? Int).map(Int64.init) else {
                throw ManagerError.taskNotFound
            }
            await manager.pause(taskID: taskID)
            sendJSON(connection, ["id": id, "ok": true])
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        case "pauseAll":
            let tasks = (try? await manager.listTasks()) ?? []
            for task in tasks where task.status == .downloading || task.status == .waiting {
                await manager.pause(taskID: task.id)
            }
            sendJSON(connection, ["id": id, "ok": true])
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        case "pauseCollection":
            guard let collectionID = request["collectionID"] as? String, !collectionID.isEmpty else {
                throw ManagerError.taskNotFound
            }
            let tasks = ((try? await manager.listTasks()) ?? []).filter { task in
                guard let data = task.postData,
                      let options = try? JSONDecoder().decode(YtDlpDownloadOptions.self, from: data) else { return false }
                return options.collectionID == collectionID
            }
            guard !tasks.isEmpty else { throw ManagerError.taskNotFound }
            for var task in tasks where task.status == .waiting || task.status == .incomplete {
                task.status = .paused
                try? await manager.updateTask(task)
            }
            for task in tasks where task.status == .downloading {
                await manager.pause(taskID: task.id)
            }
            sendJSON(connection, ["id": id, "ok": true])
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        case "resume":
            guard let taskID = request["taskID"] as? Int64 ?? (request["taskID"] as? Int).map(Int64.init) else {
                throw ManagerError.taskNotFound
            }
            try await manager.start(taskID: taskID)
            sendJSON(connection, ["id": id, "ok": true])
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        case "resumeAll":
            let tasks = (try? await manager.listTasks()) ?? []
            for task in tasks where task.status == .paused || task.status == .waiting || task.status == .incomplete {
                try? await manager.start(taskID: task.id)
            }
            sendJSON(connection, ["id": id, "ok": true])
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        case "resumeCollection":
            guard let collectionID = request["collectionID"] as? String, !collectionID.isEmpty else {
                throw ManagerError.taskNotFound
            }
            var tasks = ((try? await manager.listTasks()) ?? []).filter { task in
                guard let data = task.postData,
                      let options = try? JSONDecoder().decode(YtDlpDownloadOptions.self, from: data) else { return false }
                return options.collectionID == collectionID
            }
            guard !tasks.isEmpty else { throw ManagerError.taskNotFound }
            for index in tasks.indices where tasks[index].status == .paused
                || tasks[index].status == .incomplete
                || tasks[index].status == .error {
                tasks[index].status = .waiting
                tasks[index].errorText = nil
                try? await manager.updateTask(tasks[index])
            }
            if !(await manager.hasActiveDownloads()),
               let first = tasks
                .filter({ $0.status == .waiting })
                .min(by: { $0.id < $1.id }) {
                try? await manager.start(taskID: first.id)
            }
            sendJSON(connection, ["id": id, "ok": true])
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        case "restart", "retry":
            guard let taskID = request["taskID"] as? Int64 ?? (request["taskID"] as? Int).map(Int64.init) else {
                throw ManagerError.taskNotFound
            }
            if var task = try await manager.task(id: taskID) {
                await manager.pause(taskID: taskID)
                task.status = .waiting
                task.errorText = nil
                try? store.update(task)
                try? await manager.start(taskID: taskID)
            }
            sendJSON(connection, ["id": id, "ok": true])
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        case "renew":
            guard let taskID = request["taskID"] as? Int64 ?? (request["taskID"] as? Int).map(Int64.init),
                  let newURL = request["url"] as? String, !newURL.isEmpty else {
                throw ManagerError.invalidURL
            }
            try await manager.renewURL(taskID: taskID, newURL: newURL)
            if request["autoStart"] as? Bool ?? true {
                try await manager.start(taskID: taskID)
            }
            guard let task = try await manager.task(id: taskID) else {
                throw ManagerError.taskNotFound
            }
            sendJSON(connection, ["id": id, "ok": true, "task": taskJSON(task, progress: await manager.progress(taskID: taskID))])
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        case "remove":
            guard let taskID = request["taskID"] as? Int64 ?? (request["taskID"] as? Int).map(Int64.init) else {
                throw ManagerError.taskNotFound
            }
            let deleteFile = request["deleteFile"] as? Bool ?? false
            try await manager.remove(taskID: taskID, deleteFile: deleteFile)
            sendJSON(connection, ["id": id, "ok": true])
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        default:
            sendJSON(connection, ["id": id, "ok": false, "error": "unknown op"])
        }
    } catch {
        sendJSON(connection, ["id": id, "ok": false, "error": error.localizedDescription])
    }
}

func serve(_ connection: NWConnection) {
    hub.add(connection)
    var buffer = Data()
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: 0..<newline)
                    buffer.removeSubrange(0...newline)
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        Task { await handle(request: object, connection: connection) }
                    }
                }
            }
            if isComplete || error != nil {
                hub.remove(connection)
                connection.cancel()
                return
            }
            receive()
        }
    }
    receive()
}

let listener: NWListener
do {
    listener = try NWListener(using: .tcp, on: port)
} catch {
    FileHandle.standardError.write(Data("NDMHost: cannot listen: \(error)\n".utf8))
    exit(1)
}
listener.newConnectionHandler = { connection in
    connection.start(queue: queue)
    serve(connection)
}
listener.stateUpdateHandler = { state in
    if case .failed(let error) = state {
        FileHandle.standardError.write(Data("NDMHost: listener failed: \(error)\n".utf8))
        exit(1)
    }
}
listener.start(queue: queue)
FileHandle.standardOutput.write(Data("NDMHost ready 127.0.0.1:\(port)\n".utf8))

Task {
    while true {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if await manager.hasActiveDownloads() {
            broadcast(["op": "snapshot", "partial": true, "tasks": await snapshot(activeOnly: true)])
        }
    }
}

dispatchMain()
