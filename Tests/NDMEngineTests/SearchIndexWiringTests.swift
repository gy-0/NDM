import XCTest
@testable import NDMCore
@testable import NDMEngine

/// The one step of C2 that changes existing wiring, so the guarantees are pinned
/// rather than assumed: content becomes findable, a removed download stops being
/// findable, and index trouble never costs a download.
private enum WiringRecycleFailure: Error {
    case denied
}

final class SearchIndexWiringTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private var downloads: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-wiring-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager(
        index: SearchIndexStore?,
        recycler: DownloadManager.FileRecycler? = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) throws -> (DownloadManager, DownloadStore) {
        let store = try DownloadStore(directory: support)
        let settings = AppSettings(
            downloadDirectory: downloads,
            maxConnections: 2,
            useCategoryFolders: false
        )
        let manager = DownloadManager(
            store: store,
            settings: settings,
            supportRoot: support,
            fileRecycler: recycler,
            searchIndex: index
        )
        return (manager, store)
    }

    private func insertTask(_ store: DownloadStore, filename: String = "讲座.mp4") throws -> DownloadTask {
        try store.insert(DownloadTask(
            url: "https://www.bilibili.com/video/BV1",
            filename: filename,
            status: .complete,
            pageURL: "https://www.bilibili.com/video/BV1",
            pageTitle: "深度学习公开课",
            folderPath: downloads.path
        ))
    }

    // MARK: - Becoming findable

    func testATranscriptBecomesSearchable() async throws {
        let index = try SearchIndexStore(directory: support)
        let (manager, store) = try makeManager(index: index)
        let task = try insertTask(store)

        await manager.indexTranscript(taskID: task.id, segments: [
            TranscriptSegment(start: 0, end: 3, text: "开场先讲背景"),
            TranscriptSegment(start: 12.5, end: 16, text: "这里讲到本地转写"),
        ])

        let groups = try InboxSearch(index: index).search("转写")
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.taskID, task.id)
        XCTAssertTrue(group.hasSpokenMatch)
        XCTAssertEqual(group.snippets.first?.startSeconds, 12.5)
    }

    /// Indexing the transcript must not cost the download its name and title: both go
    /// in together because a task's entries are replaced wholesale.
    func testTranscriptIndexingKeepsMetadataSearchable() async throws {
        let index = try SearchIndexStore(directory: support)
        let (manager, store) = try makeManager(index: index)
        let task = try insertTask(store)

        await manager.indexTranscript(taskID: task.id, segments: [
            TranscriptSegment(start: 0, end: 3, text: "内容里讲转写"),
        ])

        let search = InboxSearch(index: index)
        XCTAssertEqual(try search.search("公开课").count, 1, "the title must still match")
        XCTAssertEqual(try search.search("讲座").count, 1, "the filename must still match")
        XCTAssertEqual(try search.search("bilibili").count, 1, "the site must still match")
    }

    /// A download with no transcript can only be found by what it is called, and that
    /// baseline is what makes a search box worth opening.
    func testMetadataOnlyMatchesAreLabelledHonestly() async throws {
        let index = try SearchIndexStore(directory: support)
        let (manager, store) = try makeManager(index: index)
        let task = try insertTask(store)
        await manager.indexTranscript(taskID: task.id, segments: [])

        let groups = try InboxSearch(index: index).search("公开课")
        let group = try XCTUnwrap(groups.first)
        XCTAssertTrue(group.isMetadataOnly)
        XCTAssertFalse(group.hasSpokenMatch)
    }

    /// Re-running a transcript must not double every line in the results.
    func testReindexingTheSameTaskDoesNotDuplicate() async throws {
        let index = try SearchIndexStore(directory: support)
        let (manager, store) = try makeManager(index: index)
        let task = try insertTask(store)
        let segments = [TranscriptSegment(start: 0, end: 3, text: "讲到本地转写")]

        await manager.indexTranscript(taskID: task.id, segments: segments)
        await manager.indexTranscript(taskID: task.id, segments: segments)
        await manager.indexTranscript(taskID: task.id, segments: segments)

        let groups = try InboxSearch(index: index).search("转写")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.totalSnippetCount, 1)
    }

    func testIndexingAnUnknownTaskIsRecordedRatherThanCrashing() async throws {
        let index = try SearchIndexStore(directory: support)
        let (manager, _) = try makeManager(index: index)
        await manager.indexTranscript(taskID: 9999, segments: [
            TranscriptSegment(start: 0, end: 1, text: "孤儿内容"),
        ])
        let failures = await manager.searchIndexFailures()
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(try InboxSearch(index: index).search("孤儿").isEmpty)
    }

    // MARK: - Ceasing to be findable

    /// A privacy requirement, not housekeeping: search must not keep serving content
    /// the user believes they erased.
    func testRemovingADownloadMakesItUnsearchable() async throws {
        let index = try SearchIndexStore(directory: support)
        let (manager, store) = try makeManager(index: index)
        let task = try insertTask(store)
        await manager.indexTranscript(taskID: task.id, segments: [
            TranscriptSegment(start: 0, end: 3, text: "机密内容不该留下"),
        ])
        XCTAssertEqual(try InboxSearch(index: index).search("机密").count, 1)

        try await manager.remove(taskID: task.id, deleteFile: false)

        XCTAssertTrue(
            try InboxSearch(index: index).search("机密").isEmpty,
            "a deleted download must not remain findable"
        )
        XCTAssertTrue(try index.indexedTaskIDs().isEmpty)
    }

    func testRemovingOneDownloadLeavesOthersSearchable() async throws {
        let index = try SearchIndexStore(directory: support)
        let (manager, store) = try makeManager(index: index)
        let keep = try insertTask(store, filename: "保留.mp4")
        let drop = try insertTask(store, filename: "删除.mp4")
        await manager.indexTranscript(taskID: keep.id, segments: [
            TranscriptSegment(start: 0, end: 2, text: "保留这条转写"),
        ])
        await manager.indexTranscript(taskID: drop.id, segments: [
            TranscriptSegment(start: 0, end: 2, text: "删掉那条转写"),
        ])

        try await manager.remove(taskID: drop.id, deleteFile: false)

        let groups = try InboxSearch(index: index).search("转写")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.taskID, keep.id)
    }

    /// A07's lesson applied to the index: the irreversible step happens only after the
    /// row is really gone. A removal that fails must leave the index intact, or a
    /// retry would search a hole.
    func testAFailedRemovalLeavesTheIndexIntact() async throws {
        let index = try SearchIndexStore(directory: support)
        let file = downloads.appendingPathComponent("讲座.mp4")
        try Data("payload".utf8).write(to: file)
        let (manager, store) = try makeManager(
            index: index,
            recycler: { _ in throw WiringRecycleFailure.denied }
        )
        let task = try insertTask(store)
        await manager.indexTranscript(taskID: task.id, segments: [
            TranscriptSegment(start: 0, end: 2, text: "仍然应该搜得到的转写"),
        ])

        do {
            try await manager.remove(taskID: task.id, deleteFile: true)
            XCTFail("expected the recycler to fail")
        } catch WiringRecycleFailure.denied {
            // Expected.
        }

        XCTAssertEqual(
            try InboxSearch(index: index).search("转写").count,
            1,
            "the task still exists, so its index entries must too"
        )
    }

    // MARK: - Never costing a download

    /// Search is derived data. Its absence must be invisible to downloading.
    func testEverythingWorksWithNoIndexAtAll() async throws {
        let (manager, store) = try makeManager(index: nil)
        let task = try insertTask(store)
        await manager.indexTranscript(taskID: task.id, segments: [
            TranscriptSegment(start: 0, end: 2, text: "没有索引也不该崩"),
        ])
        let failures = await manager.searchIndexFailures()
        XCTAssertTrue(failures.isEmpty, "no index is not a failure")
        try await manager.remove(taskID: task.id, deleteFile: false)
        let remaining = try await manager.task(id: task.id)
        XCTAssertNil(remaining, "removal must succeed without an index")
    }

    /// Failures are recorded rather than thrown or swallowed — thrown would cost the
    /// user a download, swallowed would hide a silently degraded search.
    func testIndexFailuresAreVisibleWithoutBeingFatal() async throws {
        let index = try SearchIndexStore(directory: support)
        let (manager, _) = try makeManager(index: index)
        await manager.indexTranscript(taskID: 4242, segments: [
            TranscriptSegment(start: 0, end: 1, text: "内容"),
        ])
        let failures = await manager.searchIndexFailures()
        XCTAssertFalse(failures.isEmpty, "a real problem must leave a trace")
        XCTAssertTrue(
            failures.contains { $0.contains("4242") },
            "the trace must say which task, got \(failures)"
        )
    }
}
