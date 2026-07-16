import XCTest
@testable import NDMBridge
@testable import NDMCore
@testable import NDMEngine
import Foundation

final class BrowserBridgeIntegrationTests: XCTestCase {
    func testWaitingNowaitingAndTaskCreated() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-bridge-\(UUID().uuidString)", isDirectory: true)
        let support = tmp.appendingPathComponent("support", isDirectory: true)
        let dest = tmp.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let store = try DownloadStore(directory: support)
        let settings = AppSettings(
            downloadDirectory: dest,
            maxConnections: 1,
            useCategoryFolders: false,
            confirmBrowserDownloads: false
        )
        let manager = DownloadManager(store: store, settings: settings, supportRoot: support)

        let bridge = BrowserBridge(port: 0)
        let gotWaiting = expectation(description: "waiting")
        let gotNoWaiting = expectation(description: "nowaiting")
        var hostMessages: [String] = []

        bridge.onDownloadMessage = { msg in
            Task {
                // Mirror AppDelegate without Wait UI
                bridge.sendToAllClients(BridgeConstants.waiting)
                do {
                    let task = try await manager.addFromBridge(msg)
                    // Don't actually download remote — just persist
                    _ = task
                } catch {
                    XCTFail(error.localizedDescription)
                }
                bridge.sendToAllClients(BridgeConstants.noWaiting)
            }
        }
        try bridge.start()
        defer { bridge.stop() }
        XCTAssertGreaterThan(bridge.boundPort, 0)

        // Client WebSocket via URLSession
        let url = URL(string: "ws://127.0.0.1:\(bridge.boundPort)/download")!
        var req = URLRequest(url: url)
        req.setValue(BridgeConstants.subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: req)
        task.resume()

        // Receive host pushes
        func receiveLoop() {
            task.receive { result in
                if case .success(let message) = result {
                    if case .string(let text) = message {
                        hostMessages.append(text)
                        if text == BridgeConstants.waiting { gotWaiting.fulfill() }
                        if text == BridgeConstants.noWaiting { gotNoWaiting.fulfill() }
                    }
                    receiveLoop()
                }
            }
        }
        receiveLoop()

        let payload = """
        1:GET\r
        2:https://example.com/file.bin\r
        3:file.bin\r
        6:normal\r
        4:Example\r
        5:https://example.com/\r
        """
        try await task.send(.string(payload))

        await fulfillment(of: [gotWaiting, gotNoWaiting], timeout: 5)

        // Give addFromBridge a moment
        try await Task.sleep(nanoseconds: 200_000_000)
        let tasks = try await manager.listTasks()
        XCTAssertTrue(tasks.contains { $0.url.contains("example.com/file.bin") })
        task.cancel()
    }

    func testShowPanelMessagesArePushedOverWebSocket() async throws {
        let bridge = BrowserBridge(port: 0)
        let connected = expectation(description: "client connected")
        bridge.onClientCountChanged = { count in
            if count == 1 { connected.fulfill() }
        }
        try bridge.start()
        defer { bridge.stop() }

        let url = URL(string: "ws://127.0.0.1:\(bridge.boundPort)/download")!
        var request = URLRequest(url: url)
        request.setValue(BridgeConstants.subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        socket.resume()
        await fulfillment(of: [connected], timeout: 3)
        // An awaited send also exercises a client text frame before host pushes.
        try await socket.send(.string("bridge-ready"))

        let expected = Set(BridgeConstants.showPanelMessages(enabled: true))
        for message in expected { bridge.sendToAllClients(message) }
        var received: Set<String> = []
        for _ in expected {
            if case .string(let text) = try await socket.receive() {
                received.insert(text)
            }
        }
        XCTAssertEqual(received, expected)
        socket.cancel()
    }

    func testConcurrentBroadcastAndStopIsSerialized() throws {
        let bridge = BrowserBridge(port: 0)
        try bridge.start()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            bridge.sendToAllClients("ShowPanelChrome=\(index % 2)")
        }
        bridge.stop()
        XCTAssertEqual(bridge.boundPort, 0)
    }

    func testParseUrlaField() throws {
        let raw = "1:GET\r\n2:https://v.example/video\r\n12:https://v.example/audio\r\nurla:https://v.example/audio2\r\n"
        let msg = try BridgeMessageParser.parse(raw)
        // last urla wins if both present — urla header overwrites 12
        XCTAssertEqual(msg.alternateURL, "https://v.example/audio2")
    }
}
