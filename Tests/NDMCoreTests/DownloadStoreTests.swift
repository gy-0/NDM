import XCTest
@testable import NDMCore

final class DownloadStoreTests: XCTestCase {
    func testAllDownloadsRetainsTaskOrderAndHeaderOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-download-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try DownloadStore(directory: directory)
        let first = try store.insert(DownloadTask(
            url: "https://example.com/first",
            headers: ["Accept: application/json", "X-Request-ID: one"]
        ))
        let second = try store.insert(DownloadTask(url: "https://example.com/second"))
        let third = try store.insert(DownloadTask(
            url: "https://example.com/third",
            headers: ["Authorization: Bearer token", "X-Request-ID: three"]
        ))

        let downloads = try store.allDownloads()

        XCTAssertEqual(downloads.map(\.id), [third.id, second.id, first.id])
        XCTAssertEqual(downloads.map(\.headers), [
            ["Authorization: Bearer token", "X-Request-ID: three"],
            [],
            ["Accept: application/json", "X-Request-ID: one"],
        ])
    }

    func testRecoverInterruptedTasksPreservesOnlyDurableCollectionQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-download-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try DownloadStore(directory: directory)
        let interrupted = try store.insert(DownloadTask(
            url: "https://example.com/interrupted.bin",
            status: .downloading
        ))
        let ordinaryWaiting = try store.insert(DownloadTask(
            url: "https://example.com/waiting.bin",
            status: .waiting
        ))
        let singleVideoWaiting = try store.insert(DownloadTask(
            url: "https://example.com/watch/1",
            linkType: "ytdlp",
            status: .waiting
        ))
        let collectionWaiting = try store.insert(DownloadTask(
            url: "https://example.com/watch/2",
            linkType: "YTDLP",
            status: .waiting,
            pageURL: "https://example.com/playlist/1"
        ))
        let completed = try store.insert(DownloadTask(
            url: "https://example.com/complete.bin",
            status: .complete
        ))
        let paused = try store.insert(DownloadTask(
            url: "https://example.com/paused.bin",
            status: .paused
        ))
        let failed = try store.insert(DownloadTask(
            url: "https://example.com/failed.bin",
            status: .error
        ))

        XCTAssertEqual(try store.recoverInterruptedTasks(), 3)

        let tasks = try store.allDownloads()
        let statusByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.status) })
        XCTAssertEqual(statusByID[interrupted.id], .incomplete)
        XCTAssertEqual(statusByID[ordinaryWaiting.id], .incomplete)
        XCTAssertEqual(statusByID[singleVideoWaiting.id], .incomplete)
        XCTAssertEqual(statusByID[collectionWaiting.id], .waiting)
        XCTAssertEqual(statusByID[completed.id], .complete)
        XCTAssertEqual(statusByID[paused.id], .paused)
        XCTAssertEqual(statusByID[failed.id], .error)
        XCTAssertEqual(try store.recoverInterruptedTasks(), 0)
    }
}
