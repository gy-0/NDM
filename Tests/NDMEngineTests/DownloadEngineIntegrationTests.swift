import XCTest
@testable import NDMEngine
@testable import NDMCore

final class DownloadEngineIntegrationTests: XCTestCase {
    func testMultiConnectionDownloadAndMerge() async throws {
        // ~256 KiB patterned payload
        var payload = Data(count: 256 * 1024)
        for i in 0..<payload.count { payload[i] = UInt8(i % 251) }

        let server = LocalRangeServer(payload: payload)
        try server.start()
        defer { server.stop() }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-integ-\(UUID().uuidString)", isDirectory: true)
        let support = tmp.appendingPathComponent("support", isDirectory: true)
        let dest = tmp.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let store = try DownloadStore(directory: support)
        let settings = AppSettings(downloadDirectory: dest, maxConnections: 4, useCategoryFolders: false)
        let manager = DownloadManager(store: store, settings: settings, supportRoot: support)

        let task = try await manager.addURL(server.baseURL.absoluteString, connections: 4)
        try await manager.startAndWait(taskID: task.id)

        let tasks = try await manager.listTasks()
        let done = try XCTUnwrap(tasks.first(where: { $0.id == task.id }))
        XCTAssertEqual(done.status, .complete)

        let fileURL = dest.appendingPathComponent(done.filename)
        let data = try Data(contentsOf: fileURL)
        XCTAssertEqual(data, payload)
    }

    func testResumeAfterPartialSegment() async throws {
        var payload = Data(count: 128 * 1024)
        for i in 0..<payload.count { payload[i] = UInt8((i * 7) % 251) }

        let server = LocalRangeServer(payload: payload)
        try server.start()
        defer { server.stop() }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-resume-\(UUID().uuidString)", isDirectory: true)
        let support = tmp.appendingPathComponent("support", isDirectory: true)
        let dest = tmp.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let store = try DownloadStore(directory: support)
        let settings = AppSettings(downloadDirectory: dest, maxConnections: 2, useCategoryFolders: false)
        let manager = DownloadManager(store: store, settings: settings, supportRoot: support)

        let task = try await manager.addURL(server.baseURL.absoluteString, connections: 2)
        let work = support.appendingPathComponent("\(task.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // Pre-seed segments.bin + partial seg.x0 (first half incomplete)
        let segs = SegmentFileFormat.planEqualSegments(totalBytes: Int64(payload.count), connections: 2)
        try SegmentFileFormat.serialize(segs).write(to: work.appendingPathComponent("segments.bin"))
        let half = segs[0].length / 2
        let partial = payload.subdata(in: Int(segs[0].start)..<Int(segs[0].start + half))
        try partial.write(to: SegmentFileFormat.segmentFileURL(id: 0, in: work))

        try await manager.startAndWait(taskID: task.id)

        let tasks = try await manager.listTasks()
        let done = try XCTUnwrap(tasks.first(where: { $0.id == task.id }))
        XCTAssertEqual(done.status, .complete)
        let fileURL = dest.appendingPathComponent(done.filename)
        XCTAssertEqual(try Data(contentsOf: fileURL), payload)
    }

    func testApplyConnectionsReplansActiveRangeTransfers() async throws {
        var payload = Data(count: 2 * 1024 * 1024)
        for i in 0..<payload.count { payload[i] = UInt8((i * 13) % 251) }

        // Delay bodies so Apply lands after the two-connection round issued its
        // actual Range requests, but before those transfers finish.
        let server = LocalRangeServer(payload: payload, responseDelay: 0.35)
        try server.start()
        defer { server.stop() }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-live-replan-\(UUID().uuidString)", isDirectory: true)
        let support = tmp.appendingPathComponent("support", isDirectory: true)
        let dest = tmp.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let store = try DownloadStore(directory: support)
        let settings = AppSettings(downloadDirectory: dest, maxConnections: 2, useCategoryFolders: false)
        let manager = DownloadManager(store: store, settings: settings, supportRoot: support)
        let task = try await manager.addURL(server.baseURL.absoluteString, connections: 2)

        try await manager.start(taskID: task.id)
        try await waitUntil(timeout: 5) { server.recordedRanges.count >= 3 }
        let rangesBeforeApply = server.recordedRanges
        XCTAssertTrue(rangesBeforeApply.contains { $0.contains("bytes=0-524287") })

        try await manager.applyConnections(taskID: task.id, count: 4)
        try await manager.startAndWait(taskID: task.id)

        let rangesAfterApply = server.recordedRanges
        XCTAssertGreaterThan(rangesAfterApply.count, rangesBeforeApply.count)
        XCTAssertGreaterThanOrEqual(Set(rangesAfterApply).count, 5)

        let tasks = try await manager.listTasks()
        let done = try XCTUnwrap(tasks.first { $0.id == task.id })
        XCTAssertEqual(done.status, .complete)
        XCTAssertEqual(done.connections, 4)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent(done.filename)), payload)

        let work = support.appendingPathComponent("\(task.id)", isDirectory: true)
        let persisted = try XCTUnwrap(try SegmentFileFormat.loadSegmentsBin(from: work))
        XCTAssertGreaterThanOrEqual(persisted.count, 5) // completed bootstrap prefix + four live holes
        let log = try String(contentsOf: work.appendingPathComponent("LogFile.txt"), encoding: .utf8)
        XCTAssertTrue(log.contains("cancelling active Range round for live replan"))
        XCTAssertTrue(log.contains("Replanned active transfers: MaxAllowedConnection = 4"))
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "DownloadEngineIntegrationTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for live Range requests",
        ])
    }
}
