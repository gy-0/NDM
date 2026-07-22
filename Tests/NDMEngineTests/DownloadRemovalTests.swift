import Foundation
import XCTest
@testable import NDMCore
@testable import NDMEngine

final class DownloadRemovalTests: XCTestCase {
    func testRemoveRejectsTraversalAndLeavesTaskAndOutsideFileUntouched() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("important.txt")
        try Data("keep me".utf8).write(to: outside)
        let recorder = LockedRecycleRecorder()
        let manager = DownloadManager(
            store: fixture.store,
            settings: fixture.settings,
            supportRoot: fixture.support,
            fileRecycler: { url in recorder.record(url) }
        )
        let task = try fixture.store.insert(DownloadTask(
            url: "https://example.com/file",
            filename: "../important.txt",
            status: .complete,
            folderPath: fixture.downloads.path
        ))

        do {
            try await manager.remove(taskID: task.id, deleteFile: true)
            XCTFail("Expected traversal to fail closed")
        } catch ManagerError.unsafeFileLocation {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: outside), Data("keep me".utf8))
        XCTAssertTrue(recorder.urls.isEmpty)
        let retainedTask = try await manager.task(id: task.id)
        XCTAssertNotNil(retainedTask)
    }

    func testRemoveRejectsSymlinkThatEscapesDownloadFolder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside.txt")
        let link = fixture.downloads.appendingPathComponent("download.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let recorder = LockedRecycleRecorder()
        let manager = DownloadManager(
            store: fixture.store,
            settings: fixture.settings,
            supportRoot: fixture.support,
            fileRecycler: { url in recorder.record(url) }
        )
        let task = try fixture.store.insert(DownloadTask(
            url: "https://example.com/file",
            filename: link.lastPathComponent,
            status: .complete,
            folderPath: fixture.downloads.path
        ))

        do {
            try await manager.remove(taskID: task.id, deleteFile: true)
            XCTFail("Expected symlink escape to fail closed")
        } catch ManagerError.unsafeFileLocation {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(recorder.urls.isEmpty)
        let retainedTask = try await manager.task(id: task.id)
        XCTAssertNotNil(retainedTask)
    }

    func testRemoveUsesInjectedRecyclerBeforeDeletingTask() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.downloads.appendingPathComponent("finished.bin")
        let recycled = fixture.root.appendingPathComponent("recycled.bin")
        try Data("payload".utf8).write(to: file)
        let recorder = LockedRecycleRecorder()
        let manager = DownloadManager(
            store: fixture.store,
            settings: fixture.settings,
            supportRoot: fixture.support,
            fileRecycler: { url in
                recorder.record(url)
                try FileManager.default.moveItem(at: url, to: recycled)
            }
        )
        let task = try fixture.store.insert(DownloadTask(
            url: "https://example.com/file",
            filename: file.lastPathComponent,
            status: .complete,
            folderPath: fixture.downloads.path
        ))

        try await manager.remove(taskID: task.id, deleteFile: true)

        XCTAssertEqual(recorder.urls, [file.standardizedFileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: recycled), Data("payload".utf8))
        let removedTask = try await manager.task(id: task.id)
        XCTAssertNil(removedTask)
    }

    func testRecyclerFailureKeepsTaskAndFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.downloads.appendingPathComponent("finished.bin")
        try Data("payload".utf8).write(to: file)
        let manager = DownloadManager(
            store: fixture.store,
            settings: fixture.settings,
            supportRoot: fixture.support,
            fileRecycler: { _ in throw RecycleFailure.denied }
        )
        let task = try fixture.store.insert(DownloadTask(
            url: "https://example.com/file",
            filename: file.lastPathComponent,
            status: .complete,
            folderPath: fixture.downloads.path
        ))

        do {
            try await manager.remove(taskID: task.id, deleteFile: true)
            XCTFail("Expected recycler failure")
        } catch RecycleFailure.denied {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let retainedTask = try await manager.task(id: task.id)
        XCTAssertNotNil(retainedTask)
    }

    func testRemovingActiveDownloadCancelsAndAwaitsItBeforeDeletingRecord() async throws {
        let payload = Data(repeating: 0x5A, count: 2 * 1_024 * 1_024)
        let server = LocalRangeServer(
            payload: payload,
            rangeResponseDelay: { _ in 4 }
        )
        try server.start()
        defer { server.stop() }
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = DownloadManager(
            store: fixture.store,
            settings: fixture.settings,
            supportRoot: fixture.support
        )
        let task = try await manager.addURL(server.baseURL.absoluteString, connections: 2)
        try await manager.start(taskID: task.id)
        try await waitUntil(timeout: 2) { !server.recordedRanges.isEmpty }

        let started = Date()
        try await manager.remove(taskID: task.id, deleteFile: false)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2, "Removal waited for the server instead of cancelling the engine")
        let hasActiveDownloads = await manager.hasActiveDownloads()
        let removedTask = try await manager.task(id: task.id)
        XCTAssertFalse(hasActiveDownloads)
        XCTAssertNil(removedTask)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.downloads.appendingPathComponent(task.filename).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.support.appendingPathComponent("\(task.id)").path
        ))
    }

    private func makeFixture() throws -> RemovalFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-remove-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let store = try DownloadStore(directory: support)
        let settings = AppSettings(
            downloadDirectory: downloads,
            maxConnections: 2,
            useCategoryFolders: false
        )
        return RemovalFixture(
            root: root,
            support: support,
            downloads: downloads,
            store: store,
            settings: settings
        )
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
        throw NSError(domain: "DownloadRemovalTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for an active range request",
        ])
    }
}

private struct RemovalFixture {
    let root: URL
    let support: URL
    let downloads: URL
    let store: DownloadStore
    let settings: AppSettings
}

private final class LockedRecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ url: URL) {
        lock.lock()
        storage.append(url.standardizedFileURL)
        lock.unlock()
    }
}

private enum RecycleFailure: Error {
    case denied
}
