import XCTest
@testable import NDMCore

final class DownloadPresentationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.apply(.english)
    }

    override func tearDown() {
        L10n.apply(.system)
        super.tearDown()
    }

    func testSegmentFractionRepresentsIndividualConnectionProgress() {
        let quarter = SegmentState(id: 2, start: 1_000, end: 1_399, completed: 100)
        XCTAssertEqual(quarter.length, 400)
        XCTAssertEqual(quarter.fractionCompleted, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(quarter.remainingBytes, 300)
    }

    func testSegmentFractionClampsInvalidOrExcessCounts() {
        let negative = SegmentState(id: 0, start: 0, end: 99, completed: -20)
        XCTAssertEqual(negative.fractionCompleted, 0)
        XCTAssertEqual(negative.remainingBytes, 100)

        let excess = SegmentState(id: 1, start: 100, end: 199, completed: 500)
        XCTAssertEqual(excess.fractionCompleted, 1)
        XCTAssertEqual(excess.remainingBytes, 0)
    }

    func testTaskBuildsCompletedDestinationURL() {
        let task = DownloadTask(
            url: "https://example.com/archive.zip",
            filename: "archive.zip",
            folderPath: "/Users/example/Downloads"
        )
        XCTAssertEqual(task.destinationFileURL?.path, "/Users/example/Downloads/archive.zip")

        var missingFolder = task
        missingFolder.folderPath = nil
        XCTAssertNil(missingFolder.destinationFileURL)
    }

    func testSidebarFilterMatchesStatusGroups() {
        let downloading = DownloadTask(url: "https://a/x", status: .downloading)
        let waiting = DownloadTask(url: "https://a/x", status: .waiting)
        let paused = DownloadTask(url: "https://a/x", status: .paused)
        let incomplete = DownloadTask(url: "https://a/x", status: .incomplete)
        let complete = DownloadTask(url: "https://a/x", status: .complete)
        let failed = DownloadTask(url: "https://a/x", status: .error)

        XCTAssertTrue(SidebarFilter.active.matches(downloading))
        XCTAssertTrue(SidebarFilter.queued.matches(waiting))
        XCTAssertTrue(SidebarFilter.paused.matches(paused))
        XCTAssertTrue(SidebarFilter.paused.matches(incomplete))
        XCTAssertTrue(SidebarFilter.completed.matches(complete))
        XCTAssertTrue(SidebarFilter.failed.matches(failed))
        XCTAssertFalse(SidebarFilter.active.matches(waiting))
        XCTAssertEqual(SidebarFilter.paused.title, "To Resume")
    }

    func testSidebarFilterMatchesCategoriesAndRetryFlags() {
        let video = DownloadTask(url: "https://a/v.mp4", filename: "v.mp4", category: .video, status: .complete)
        let uncategorized = DownloadTask(url: "https://a/file", filename: "file", category: .misc, status: .complete)
        let failed = DownloadTask(url: "https://a/x", status: .error, errorText: "410 Gone")
        XCTAssertTrue(SidebarFilter.video.matches(video))
        XCTAssertFalse(SidebarFilter.document.matches(video))
        XCTAssertTrue(SidebarFilter.other.matches(uncategorized))
        XCTAssertFalse(SidebarFilter.other.matches(video))
        XCTAssertEqual(SidebarFilter.video.section, "Type")
        XCTAssertEqual(SidebarFilter.all.section, "Status")

        let row = TaskRowPresentation.make(task: failed, progress: nil)
        XCTAssertTrue(row.canRetry)
        XCTAssertTrue(row.canRenew)
        XCTAssertEqual(row.statusTitle, "Failed")

        let done = TaskRowPresentation.make(task: video, progress: nil)
        XCTAssertTrue(done.canRetry)
        XCTAssertFalse(done.canOpen) // no folderPath → Open stays off; Retry still on
        let doneWithPath = DownloadTask(
            url: "https://a/v.mp4",
            filename: "v.mp4",
            category: .video,
            status: .complete,
            folderPath: "/tmp"
        )
        XCTAssertTrue(TaskRowPresentation.make(task: doneWithPath, progress: nil).canOpen)
    }

    func testTaskRowPresentationFormatsLiveProgress() {
        let task = DownloadTask(
            url: "https://cdn.example.com/film.mkv",
            filename: "film.mkv",
            fileSize: 1_000,
            status: .downloading,
            connections: 8
        )
        let progress = DownloadProgress(
            taskID: 1,
            totalBytes: 1_000,
            completedBytes: 250,
            bytesPerSecond: 50,
            status: .downloading
        )
        let row = TaskRowPresentation.make(task: task, progress: progress)
        XCTAssertEqual(row.host, "cdn.example.com")
        XCTAssertEqual(row.statusTitle, "Downloading")
        XCTAssertEqual(row.progressText, "25%")
        XCTAssertEqual(row.progressFraction, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(row.primaryAction, .showProgress)
        XCTAssertTrue(row.canPause)
        XCTAssertFalse(row.canStart)
        XCTAssertNotEqual(row.speedText, "—")
        XCTAssertNotEqual(row.etaText, "—")
    }

    func testMediaJourneyKeepsTruthfulBytesAndOneSemanticProgress() {
        defer { L10n.apply(.system) }
        L10n.apply(.english)
        let task = DownloadTask(
            url: "https://www.youtube.com/watch?v=example",
            filename: "film.mp4",
            linkType: "ytdlp",
            fileSize: 1_000,
            status: .downloading
        )
        let progress = DownloadProgress(
            taskID: 2,
            totalBytes: 1_000,
            completedBytes: 1_000,
            bytesPerSecond: 0,
            status: .downloading,
            phase: .merging,
            journeyFraction: 0.972
        )

        XCTAssertNil(progress.remainingTime)
        let row = TaskRowPresentation.make(task: task, progress: progress)
        XCTAssertEqual(row.progressFraction, 0.972, accuracy: 0.000_001)
        XCTAssertEqual(row.progressText, "97%")
        XCTAssertTrue(row.statusDetail.contains(L10n.ytdlpMergingShort))
        XCTAssertEqual(progress.completedBytes, progress.totalBytes)
    }

    func testTaskRowPresentationCompletedPrimaryActionIsOpenWhenDestinationKnown() {
        // Presentation must not probe the filesystem; destination path is enough.
        let task = DownloadTask(
            url: "https://example.com/done.bin",
            filename: "done.bin",
            fileSize: 3,
            status: .complete,
            folderPath: "/Users/example/Downloads"
        )
        let row = TaskRowPresentation.make(task: task, progress: nil)
        XCTAssertEqual(row.primaryAction, .open)
        XCTAssertTrue(row.canOpen)
        XCTAssertTrue(row.canShowInFinder)
        XCTAssertTrue(row.canShowProgress, "completed result pages must remain reopenable")
        XCTAssertTrue(row.isComplete)
        XCTAssertFalse(row.showsProgressBar)
        XCTAssertEqual(row.progressText, "Completed")
        XCTAssertEqual(row.sizeText, TaskPresentationFormatting.byteCount(3))
    }

    func testSearchMatchesFilenameHostAndURL() {
        let task = DownloadTask(
            url: "https://files.example.org/path/report.pdf",
            filename: "Q3-report.pdf",
            status: .complete
        )
        XCTAssertTrue(TaskPresentationFormatting.matchesSearch(task, query: "report"))
        XCTAssertTrue(TaskPresentationFormatting.matchesSearch(task, query: "files.example"))
        XCTAssertTrue(TaskPresentationFormatting.matchesSearch(task, query: "path/report"))
        XCTAssertFalse(TaskPresentationFormatting.matchesSearch(task, query: "video"))
    }

    func testSelectionActionsFollowRowCapabilities() {
        let paused = TaskRowPresentation.make(
            task: DownloadTask(url: "https://a/x", status: .paused),
            progress: nil
        )
        let actions = TaskSelectionActions.make(from: paused)
        XCTAssertTrue(actions.canStart)
        XCTAssertFalse(actions.canPause)
        XCTAssertTrue(actions.canDelete)
        XCTAssertEqual(TaskSelectionActions.make(from: nil), .none)
    }
}
