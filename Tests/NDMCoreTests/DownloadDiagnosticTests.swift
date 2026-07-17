import XCTest
@testable import NDMCore

final class DownloadDiagnosticTests: XCTestCase {
    private var savedLanguage: AppLanguageMode!

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.currentMode
    }

    override func tearDown() {
        L10n.apply(savedLanguage)
        super.tearDown()
    }

    // MARK: - HTTP classification

    func testHTTPStatusClassification() {
        XCTAssertEqual(DownloadDiagnostic.fromHTTPStatus(403), .linkExpired(status: 403))
        XCTAssertEqual(DownloadDiagnostic.fromHTTPStatus(404), .linkExpired(status: 404))
        XCTAssertEqual(DownloadDiagnostic.fromHTTPStatus(410), .linkExpired(status: 410))
        XCTAssertEqual(DownloadDiagnostic.fromHTTPStatus(401), .signInRequired(status: 401))
        XCTAssertEqual(DownloadDiagnostic.fromHTTPStatus(407), .signInRequired(status: 407))
        XCTAssertEqual(DownloadDiagnostic.fromHTTPStatus(416), .rangeNotSupported)
        XCTAssertEqual(DownloadDiagnostic.fromHTTPStatus(429), .serverThrottled)
        XCTAssertEqual(DownloadDiagnostic.fromHTTPStatus(503), .serverError(status: 503))
        XCTAssertEqual(DownloadDiagnostic.fromHTTPStatus(418), .httpError(status: 418))
    }

    func testURLErrorClassification() {
        XCTAssertEqual(DownloadDiagnostic.fromURLError(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(DownloadDiagnostic.fromURLError(URLError(.timedOut)), .timeout)
        XCTAssertEqual(DownloadDiagnostic.fromURLError(URLError(.networkConnectionLost)), .connectionLost)
        XCTAssertEqual(DownloadDiagnostic.fromURLError(URLError(.secureConnectionFailed)), .sslFailure)
    }

    func testDiskFullClassification() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(DownloadDiagnostic.fromCocoaError(cocoa), .diskFull)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        XCTAssertEqual(DownloadDiagnostic.fromCocoaError(posix), .diskFull)
        let other = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        XCTAssertNil(DownloadDiagnostic.fromCocoaError(other))
    }

    // MARK: - Storage round-trip

    func testStorageRoundTripAllCases() {
        let cases: [DownloadDiagnostic] = [
            .linkExpired(status: 403),
            .signInRequired(status: 407),
            .rangeNotSupported,
            .serverThrottled,
            .serverError(status: 502),
            .httpError(status: 418),
            .offline,
            .timeout,
            .connectionLost,
            .sslFailure,
            .diskFull,
            .mergeFailed(detail: "ffmpeg exited 1"),
            .generic(detail: "weird: thing | with separators"),
        ]
        for diag in cases {
            let stored = diag.storageString
            XCTAssertEqual(DownloadDiagnostic(storageString: stored), diag, "round-trip failed for \(stored)")
        }
    }

    func testLegacyPlainTextIsNotParsed() {
        XCTAssertNil(DownloadDiagnostic.fromStoredErrorText("410 Gone"))
        XCTAssertNil(DownloadDiagnostic.fromStoredErrorText(nil))
        XCTAssertNil(DownloadDiagnostic.fromStoredErrorText("#diag:someFutureCase:9"))
    }

    // MARK: - Copy renders in the current UI language

    func testCopyFollowsLanguage() {
        let diag = DownloadDiagnostic.linkExpired(status: 403)

        L10n.apply(.english)
        XCTAssertEqual(diag.title, "This download link has expired")
        XCTAssertTrue(diag.rowSummary.hasPrefix("Link expired"))

        L10n.apply(.simplifiedChinese)
        XCTAssertEqual(diag.title, "这个下载地址过期了")
        XCTAssertTrue(diag.rowSummary.hasPrefix("链接已过期"))

        // Raw label never localizes.
        XCTAssertEqual(diag.rawLabel, "HTTP 403")
    }

    func testEveryCaseHasNonEmptyCopy() {
        let cases: [DownloadDiagnostic] = [
            .linkExpired(status: 403), .signInRequired(status: 401), .rangeNotSupported,
            .serverThrottled, .serverError(status: 500), .httpError(status: 418),
            .offline, .timeout, .connectionLost, .sslFailure, .diskFull,
            .mergeFailed(detail: "d"), .generic(detail: "d"),
        ]
        for mode in [AppLanguageMode.english, .simplifiedChinese] {
            L10n.apply(mode)
            for diag in cases {
                XCTAssertFalse(diag.title.isEmpty)
                XCTAssertFalse(diag.message.isEmpty)
                XCTAssertFalse(diag.rowSummary.isEmpty)
                XCTAssertFalse(diag.rawLabel.isEmpty)
                XCTAssertTrue(diag.rowSummary.contains(" · "), "row summary should be headline · hint")
            }
        }
    }

    // MARK: - Presentation integration

    func testPresentationRendersStoredDiagnostic() {
        L10n.apply(.simplifiedChinese)
        let task = DownloadTask(
            url: "https://cdn.example.com/file.zip",
            status: .error,
            errorText: DownloadDiagnostic.linkExpired(status: 403).storageString
        )
        let row = TaskRowPresentation.make(task: task, progress: nil)
        XCTAssertEqual(row.diagnostic, .linkExpired(status: 403))
        XCTAssertEqual(row.errorText, DownloadDiagnostic.linkExpired(status: 403).rowSummary)
        XCTAssertEqual(row.statusDetail, DownloadDiagnostic.linkExpired(status: 403).rowSummary)
        XCTAssertEqual(row.diagnostic?.primaryAction, .renew)
        XCTAssertTrue(row.canRenew)
    }

    func testBrowserRescueURLOnlyAppearsForRecoverableDirectFailures() {
        var task = DownloadTask(
            url: "https://cdn.example.com/file.zip?expired",
            linkType: "normal",
            status: .error,
            pageURL: "https://example.com/download/42",
            errorText: DownloadDiagnostic.linkExpired(status: 403).storageString
        )
        XCTAssertEqual(task.browserRescueURL?.absoluteString, "https://example.com/download/42")

        task.errorText = DownloadDiagnostic.signInRequired(status: 401).storageString
        XCTAssertNotNil(task.browserRescueURL)

        task.errorText = DownloadDiagnostic.diskFull.storageString
        XCTAssertNil(task.browserRescueURL)

        task.errorText = DownloadDiagnostic.linkExpired(status: 403).storageString
        task.linkType = "ytdlp"
        XCTAssertNil(task.browserRescueURL)

        task.linkType = "normal"
        task.status = .complete
        XCTAssertNil(task.browserRescueURL)
    }

    func testPresentationPassesThroughLegacyError() {
        let task = DownloadTask(url: "https://a/x", status: .error, errorText: "410 Gone")
        let row = TaskRowPresentation.make(task: task, progress: nil)
        XCTAssertNil(row.diagnostic)
        XCTAssertEqual(row.errorText, "410 Gone")
    }
}
