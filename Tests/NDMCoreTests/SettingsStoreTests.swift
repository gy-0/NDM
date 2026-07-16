import XCTest
@testable import NDMCore

final class SettingsStoreTests: XCTestCase {
    func testRoundTrip() {
        var s = AppSettings()
        s.maxConnections = 16
        s.useCategoryFolders = false
        s.downloadDirectory = URL(fileURLWithPath: "/tmp/ndm-test-dl")
        SettingsStore.save(s)
        let loaded = SettingsStore.load()
        XCTAssertEqual(loaded.maxConnections, 16)
        XCTAssertEqual(loaded.useCategoryFolders, false)
        XCTAssertEqual(loaded.downloadDirectory.path, "/tmp/ndm-test-dl")
    }
}
