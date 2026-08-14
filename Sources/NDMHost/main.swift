import Foundation
import Network
import NDMCore
import NDMEngine
import NDMBridge

let port = NWEndpoint.Port(rawValue: UInt16(ProcessInfo.processInfo.environment["NDM_HOST_PORT"] ?? "51874") ?? 51874)!
let queue = DispatchQueue(label: "ndm.host")

let support = DownloadStore.defaultSupportDirectory
let store: DownloadStore
do {
    store = try DownloadStore(directory: support)
    try store.recoverInterruptedTasks()
} catch {
    FileHandle.standardError.write(Data("NDMHost: cannot open store: \(error)\n".utf8))
    exit(1)
}

var currentSettings = SettingsStore.load()

let manager = DownloadManager(
    store: store,
    settings: currentSettings,
    supportRoot: support,
    fileRecycler: { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }
)

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

            var task = try await manager.addURL(
                msg.url,
                connections: currentSettings.maxConnections,
                pageURL: msg.pageURL.isEmpty ? nil : msg.pageURL,
                pageTitle: msg.pageTitle.isEmpty ? nil : msg.pageTitle,
                headers: headerList,
                method: msg.method,
                ltype: msg.ltype
            )
            if !msg.filename.isEmpty {
                task.filename = msg.filename
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
    let status = progress?.status.rawValue ?? task.status.rawValue
    let phase = progress?.phase?.rawValue
    let connections = progress?.currentConnections ?? task.connections
    let segments = (progress?.segmentStates ?? []).map { segment in
        [
            "id": segment.id,
            "fraction": segment.fractionCompleted as Double
        ] as [String: Any]
    }
    let source = URL(string: task.pageURL ?? task.url)?.host
    var row: [String: Any] = [
        "id": NSNumber(value: task.id),
        "filename": task.filename,
        "title": task.hitTitle ?? task.pageTitle ?? task.filename,
        "url": task.url,
        "category": task.category.rawValue,
        "status": status,
        "fileSize": NSNumber(value: progress?.totalBytes ?? task.fileSize),
        "completedBytes": NSNumber(value: completed),
        "bytesPerSecond": speed,
        "connections": connections,
        "segments": segments,
        "folderPath": task.folderPath ?? ""
    ]
    if let source { row["source"] = source }
    if let phase { row["phase"] = phase }
    if let errorText = task.errorText { row["errorText"] = errorText }
    return row
}

func snapshot() async -> [[String: Any]] {
    let tasks = (try? await manager.listTasks()) ?? []
    let newest = tasks.sorted { $0.id > $1.id }
    let active = newest.filter { $0.status == .downloading || $0.status == .paused || $0.status == .waiting }
    var picked: [DownloadTask] = []
    var seen = Set<Int64>()
    for task in active + newest {
        if seen.insert(task.id).inserted { picked.append(task) }
        if picked.count >= 200 { break }
    }
    var rows: [[String: Any]] = []
    for task in picked {
        let progress = await manager.progress(taskID: task.id)
        rows.append(taskJSON(task, progress: progress))
    }
    return rows
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
                let probe = try await YtDlpTool.probe(url: url)
                let formats = probe.formats.map { f in
                    [
                        "id": f.id,
                        "label": f.label,
                        "height": f.height,
                        "approximateBytes": NSNumber(value: f.approximateBytes ?? 0),
                        "containerHint": f.containerHint,
                        "isVideo": f.isVideo
                    ] as [String: Any]
                }
                sendJSON(connection, [
                    "id": id,
                    "ok": true,
                    "title": probe.title,
                    "duration": probe.durationSeconds ?? 0,
                    "formats": formats
                ])
            } catch {
                sendJSON(connection, ["id": id, "ok": false, "error": error.localizedDescription])
            }
        case "add":
            guard let url = request["url"] as? String, !url.isEmpty else {
                throw ManagerError.invalidURL
            }
            let connections = request["connections"] as? Int
            let pageURL = request["pageURL"] as? String
            let pageTitle = request["pageTitle"] as? String
            var destinationDirectory: URL? = nil
            if let folderPath = request["folderPath"] as? String, !folderPath.isEmpty {
                destinationDirectory = URL(fileURLWithPath: folderPath)
            }
            var task = try await manager.addURL(
                url,
                connections: connections,
                pageURL: pageURL,
                pageTitle: pageTitle,
                destinationDirectory: destinationDirectory
            )
            if let customFilename = request["filename"] as? String, !customFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                task.filename = customFilename.trimmingCharacters(in: .whitespacesAndNewlines)
                task.category = DownloadCategory.infer(filename: task.filename, mimeType: nil)
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
            broadcast(["op": "snapshot", "tasks": await snapshot()])
        }
    }
}

dispatchMain()
