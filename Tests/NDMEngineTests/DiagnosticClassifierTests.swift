import XCTest
@testable import NDMEngine
@testable import NDMCore

final class DiagnosticClassifierTests: XCTestCase {
    func testEngineErrorClassification() {
        XCTAssertEqual(DownloadDiagnostic.classify(EngineError.httpStatus(403)), .linkExpired(status: 403))
        XCTAssertEqual(DownloadDiagnostic.classify(EngineError.httpStatus(503)), .serverError(status: 503))
        XCTAssertEqual(
            DownloadDiagnostic.classify(EngineError.authRequired(status: 401, challenge: nil)),
            .signInRequired(status: 401)
        )
        XCTAssertEqual(DownloadDiagnostic.classify(EngineError.notResumable), .rangeNotSupported)
        XCTAssertEqual(
            DownloadDiagnostic.classify(EngineError.mergeFailed("boom")),
            .mergeFailed(detail: "boom")
        )
    }

    func testFTPErrorClassification() {
        XCTAssertEqual(DownloadDiagnostic.classify(FTPError.timeout), .timeout)
        XCTAssertEqual(DownloadDiagnostic.classify(FTPError.disconnected), .connectionLost)
        XCTAssertEqual(DownloadDiagnostic.classify(FTPError.loginFailed(530)), .signInRequired(status: 401))
    }

    func testFoundationErrorClassification() {
        XCTAssertEqual(DownloadDiagnostic.classify(URLError(.timedOut)), .timeout)
        XCTAssertEqual(DownloadDiagnostic.classify(URLError(.notConnectedToInternet)), .offline)
        let diskFull = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        XCTAssertEqual(DownloadDiagnostic.classify(diskFull), .diskFull)
        // NSError bridged URL errors still classify.
        let bridged = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        XCTAssertEqual(DownloadDiagnostic.classify(bridged), .connectionLost)
    }
}
