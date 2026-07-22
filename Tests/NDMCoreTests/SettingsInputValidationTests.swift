import XCTest
@testable import NDMCore

final class SettingsInputValidationTests: XCTestCase {
    func testConnectionCountAcceptsOnlyProductRange() {
        XCTAssertEqual(SettingsInputValidation.connectionCount(" 8 "), 8)
        XCTAssertEqual(SettingsInputValidation.connectionCount("32"), 32)
        XCTAssertNil(SettingsInputValidation.connectionCount("0"))
        XCTAssertNil(SettingsInputValidation.connectionCount("33"))
        XCTAssertNil(SettingsInputValidation.connectionCount("eight"))
    }

    func testBandwidthDoesNotSilentlyTurnInvalidTextIntoUnlimited() {
        XCTAssertEqual(SettingsInputValidation.bandwidthBytesPerSecond("0"), 0)
        XCTAssertEqual(SettingsInputValidation.bandwidthBytesPerSecond(" 1048576 "), 1_048_576)
        XCTAssertNil(SettingsInputValidation.bandwidthBytesPerSecond("-1"))
        XCTAssertNil(SettingsInputValidation.bandwidthBytesPerSecond("fast"))
        XCTAssertNil(SettingsInputValidation.bandwidthBytesPerSecond("999999999999999999999"))
    }

    func testPortRejectsZeroOverflowAndNonNumbers() {
        XCTAssertEqual(SettingsInputValidation.port(" 8080 "), 8_080)
        XCTAssertEqual(SettingsInputValidation.port("65535"), 65_535)
        XCTAssertNil(SettingsInputValidation.port("0"))
        XCTAssertNil(SettingsInputValidation.port("65536"))
        XCTAssertNil(SettingsInputValidation.port("auto"))
    }

    func testNonEmptyTextTrimsBeforeValidation() {
        XCTAssertEqual(SettingsInputValidation.nonEmptyText("  proxy.example  "), "proxy.example")
        XCTAssertNil(SettingsInputValidation.nonEmptyText(" \n\t "))
    }
}
