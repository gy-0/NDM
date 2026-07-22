import XCTest
@testable import NDMCore

final class SettingsStoreTests: XCTestCase {
    func testNewSettingsFollowSystemAppearanceAndLanguage() {
        let settings = AppSettings()
        XCTAssertEqual(settings.appearanceMode, .system)
        XCTAssertEqual(settings.accentTheme, .classicBlue)
        XCTAssertEqual(settings.languageMode, .system)
        XCTAssertTrue(settings.smartConnectionsEnabled)
        XCTAssertTrue(settings.clipboardWatchEnabled)
    }

    func testRoundTrip() {
        let suiteName = "dev.ndm.open.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var s = AppSettings()
        s.maxConnections = 16
        s.useCategoryFolders = false
        s.downloadDirectory = URL(fileURLWithPath: "/tmp/ndm-test-dl")
        s.appearanceMode = .dark
        s.accentTheme = .custom
        s.customAccentHex = "#2C7A6B"
        s.languageMode = .simplifiedChinese
        SettingsStore.save(s, defaults: defaults)
        let loaded = SettingsStore.load(defaults: defaults)
        XCTAssertEqual(loaded.maxConnections, 16)
        XCTAssertEqual(loaded.useCategoryFolders, false)
        XCTAssertEqual(loaded.downloadDirectory.path, "/tmp/ndm-test-dl")
        XCTAssertEqual(loaded.appearanceMode, .dark)
        XCTAssertEqual(loaded.accentTheme, .custom)
        XCTAssertEqual(loaded.customAccentHex, "#2C7A6B")
        XCTAssertEqual(loaded.languageMode, .simplifiedChinese)
    }

    func testLegacyNeatBridgePortMigratesToNDMDedicatedPort() throws {
        let suiteName = "dev.ndm.open.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = AppSettings()
        settings.bridgePort = BridgeConstants.legacyNeatPort
        SettingsStore.save(settings, defaults: defaults)

        XCTAssertEqual(SettingsStore.load(defaults: defaults).bridgePort, BridgeConstants.port)
    }

    func testCustomBridgePortIsPreserved() {
        let suiteName = "dev.ndm.open.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = AppSettings()
        settings.bridgePort = 52_222
        SettingsStore.save(settings, defaults: defaults)

        XCTAssertEqual(SettingsStore.load(defaults: defaults).bridgePort, 52_222)
    }

    func testL10nChinese() {
        L10n.apply(.simplifiedChinese)
        XCTAssertTrue(L10n.usesChinese)
        XCTAssertEqual(L10n.pause, "暂停")
        XCTAssertEqual(L10n.settings, "设置")
        XCTAssertEqual(L10n.share, "分享")
        XCTAssertEqual(L10n.quickLook, "快速查看")
        XCTAssertEqual(L10n.moreActions, "更多操作")
        XCTAssertEqual(L10n.readyToPlay, "下载好了")
        XCTAssertFalse(L10n.finalizeKeptTS.lowercased().contains("ffmpeg"))
        XCTAssertFalse(L10n.finalizeAudioSidecar.lowercased().contains("ffmpeg"))
        XCTAssertEqual(L10n.ytdlpEntireCollection(12), "整个合集 · 12 项")
        XCTAssertEqual(
            L10n.downloadCollection(12, quality: "1080p · MP4"),
            "下载 12 项 · 1080p · MP4"
        )
        XCTAssertEqual(L10n.linkLensViewExisting, "查看现有")
        XCTAssertEqual(L10n.linkLensOptions, "选择画质…")
        XCTAssertEqual(
            L10n.clipboardOffer(source: .douyin, wasExtractedFromText: true),
            "下载抖音分享"
        )
        XCTAssertEqual(
            L10n.linkLensDownloadReadyChoice("1080p", container: "MP4"),
            "下载 1080p · MP4"
        )
        XCTAssertEqual(
            L10n.linkLensExistingComplete("示例.mp4"),
            "已经下载过 · 示例.mp4"
        )
        L10n.apply(.english)
        XCTAssertFalse(L10n.usesChinese)
        XCTAssertEqual(L10n.pause, "Pause")
        XCTAssertEqual(L10n.share, "Share")
        XCTAssertEqual(L10n.quickLook, "Quick Look")
        XCTAssertEqual(L10n.moreActions, "More Actions")
        XCTAssertFalse(L10n.finalizeKeptTS.lowercased().contains("ffmpeg"))
        XCTAssertFalse(L10n.finalizeAudioSidecar.lowercased().contains("ffmpeg"))
        XCTAssertEqual(L10n.ytdlpEntireCollection(12, isTruncated: true), "First 12 items")
        XCTAssertEqual(L10n.linkLensDownloadAgain, "Download again")
        XCTAssertEqual(L10n.linkLensOptions, "Choose quality…")
        XCTAssertEqual(
            L10n.clipboardOffer(source: .youtube, wasExtractedFromText: false),
            "Download YouTube link"
        )
        XCTAssertEqual(
            L10n.clipboardOffer(source: .tiktok, wasExtractedFromText: true),
            "Download TikTok share"
        )
        XCTAssertEqual(
            L10n.linkLensDownloadReadyChoice("1080p", container: "MP4"),
            "Download 1080p · MP4"
        )
        L10n.apply(.system)
    }

    func testStorageConfidenceCopyIsLocalizedAndActionable() {
        defer { L10n.apply(.system) }

        L10n.apply(.simplifiedChinese)
        XCTAssertTrue(L10n.storageComfortable(
            finalBytes: 1_024,
            availableBytes: 8_192,
            isCollection: false
        ).contains("空间充足"))
        XCTAssertTrue(L10n.storageInsufficient(shortfallBytes: 2_048).contains("选择更小画质"))
        XCTAssertTrue(L10n.storageGuardError(
            requiredBytes: 4_096,
            availableBytes: 1_024
        ).contains("更换下载位置"))

        L10n.apply(.english)
        XCTAssertTrue(L10n.storageComfortable(
            finalBytes: 1_024,
            availableBytes: 8_192,
            isCollection: true
        ).contains("Collection"))
        XCTAssertTrue(L10n.storageInsufficient(shortfallBytes: 2_048).contains("smaller quality"))
        XCTAssertTrue(L10n.storageGuardError(
            requiredBytes: 4_096,
            availableBytes: 1_024
        ).contains("change the download location"))
    }
}
