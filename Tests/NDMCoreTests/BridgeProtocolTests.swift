import XCTest
@testable import NDMCore

final class BridgeProtocolTests: XCTestCase {
    func testParseBetterNDMShape() throws {
        let raw = [
            "1:GET",
            "2:https://example.com/file.zip",
            "6:normal",
            "4:Title",
            "Origin: https://example.com",
            "Referer: https://example.com/page",
            "5:https://example.com/page",
            "Cookie: a=b",
            "7:12345",
            "8:application/zip",
            "",
        ].joined(separator: "\r\n")
        let msg = try BridgeMessageParser.parse(raw)
        XCTAssertEqual(msg.method, "GET")
        XCTAssertEqual(msg.url, "https://example.com/file.zip")
        XCTAssertEqual(msg.ltype, "normal")
        XCTAssertEqual(msg.pageTitle, "Title")
        XCTAssertEqual(msg.origin, "https://example.com")
        XCTAssertEqual(msg.cookies, "a=b")
        XCTAssertEqual(msg.fileSize, 12345)
        XCTAssertEqual(msg.contentType, "application/zip")
    }

    func testConstantsMatchOriginal() {
        XCTAssertEqual(BridgeConstants.port, 10_007)
        XCTAssertEqual(BridgeConstants.subprotocol, "neatextension.v1")
        XCTAssertEqual(BridgeConstants.waiting, "waiting")
    }
}
