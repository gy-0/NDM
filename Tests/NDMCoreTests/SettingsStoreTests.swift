import XCTest
@testable import NDMCore

final class SettingsStoreTests: XCTestCase {
    func testRoundTrip() {
        var s = AppSettings()
        s.maxConnections = 16
        s.useCategoryFolders = false
        s.downloadDirectory = URL(fileURLWithPath: "/tmp/ndm-test-dl")
        s.appearanceMode = .dark
        s.languageMode = .simplifiedChinese
        SettingsStore.save(s)
        let loaded = SettingsStore.load()
        XCTAssertEqual(loaded.maxConnections, 16)
        XCTAssertEqual(loaded.useCategoryFolders, false)
        XCTAssertEqual(loaded.downloadDirectory.path, "/tmp/ndm-test-dl")
        XCTAssertEqual(loaded.appearanceMode, .dark)
        XCTAssertEqual(loaded.languageMode, .simplifiedChinese)
    }

    func testL10nChinese() {
        L10n.apply(.simplifiedChinese)
        XCTAssertTrue(L10n.usesChinese)
        XCTAssertEqual(L10n.pause, "暂停")
        XCTAssertEqual(L10n.settings, "设置")
        L10n.apply(.english)
        XCTAssertFalse(L10n.usesChinese)
        XCTAssertEqual(L10n.pause, "Pause")
        L10n.apply(.system)
    }
}
