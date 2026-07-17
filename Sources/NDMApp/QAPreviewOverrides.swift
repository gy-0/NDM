import AppKit
import NDMCore

/// Deterministic visual states for the standalone debug preview only.
/// Release builds always return nil/false and cannot be influenced by these
/// environment variables.
enum QAPreviewOverrides {
#if DEBUG
    private static let environment = ProcessInfo.processInfo.environment

    static var isEnabled: Bool { environment["NDM_QA_MODE"] == "1" }

    static var appearanceMode: AppearanceMode? {
        guard isEnabled, let raw = environment["NDM_QA_APPEARANCE"] else { return nil }
        return AppearanceMode(rawValue: raw)
    }

    static var languageMode: AppLanguageMode? {
        guard isEnabled, let raw = environment["NDM_QA_LANGUAGE"] else { return nil }
        return AppLanguageMode(rawValue: raw)
    }

    static var interfaceScale: CGFloat? {
        guard isEnabled,
              let raw = environment["NDM_QA_SCALE"],
              let value = Double(raw) else { return nil }
        return CGFloat(value)
    }

    static var clipboardText: String? {
        guard isEnabled,
              let value = environment["NDM_QA_CLIPBOARD_TEXT"],
              !value.isEmpty else { return nil }
        return value
    }

    static var supportDirectory: URL? {
        guard isEnabled,
              let path = environment["NDM_QA_SUPPORT_ROOT"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var bridgePort: UInt16? {
        guard isEnabled,
              let raw = environment["NDM_QA_BRIDGE_PORT"] else { return nil }
        return UInt16(raw)
    }

    static var windowSize: NSSize? {
        guard isEnabled,
              let widthRaw = environment["NDM_QA_WINDOW_WIDTH"],
              let heightRaw = environment["NDM_QA_WINDOW_HEIGHT"],
              let width = Double(widthRaw),
              let height = Double(heightRaw) else { return nil }
        return NSSize(width: max(960, width), height: max(620, height))
    }

    static var showUpgrade: Bool {
        isEnabled && environment["NDM_QA_SHOW_UPGRADE"] == "1"
    }

    static var showCompletion: Bool {
        isEnabled && environment["NDM_QA_SHOW_COMPLETION"] == "1"
    }

    static var showOnboarding: Bool {
        isEnabled && environment["NDM_QA_SHOW_ONBOARDING"] == "1"
    }

    static var upgradeFeatures: [ProFeature] {
        guard isEnabled else { return [] }
        switch environment["NDM_QA_UPGRADE_CONTEXT"] {
        case "connections": return [.connections(requested: 32)]
        case "4k": return [.ultraHD(height: 2160)]
        case "collection": return [.collection(itemCount: 24), .ultraHD(height: 2160), .subtitles]
        case "subtitles": return [.subtitles]
        default: return []
        }
    }
#else
    static let isEnabled = false
    static let appearanceMode: AppearanceMode? = nil
    static let languageMode: AppLanguageMode? = nil
    static let interfaceScale: CGFloat? = nil
    static let clipboardText: String? = nil
    static let supportDirectory: URL? = nil
    static let bridgePort: UInt16? = nil
    static let windowSize: NSSize? = nil
    static let showUpgrade = false
    static let showCompletion = false
    static let showOnboarding = false
    static let upgradeFeatures: [ProFeature] = []
#endif

    static func apply(to settings: inout AppSettings) {
        guard isEnabled else { return }
        if let appearanceMode { settings.appearanceMode = appearanceMode }
        if let languageMode { settings.languageMode = languageMode }
        if let bridgePort { settings.bridgePort = bridgePort }
        settings.clipboardWatch = true
        settings.onboardingCompleted = !showOnboarding
        if showCompletion { settings.showCompletionDialog = true }
    }

    /// Populate only an empty, isolated QA database with realistic file rows.
    /// This lets visual QA cover the selected list row and inspector artwork
    /// without reading or mutating the user's real downloads.
    static func seedPreviewTasks(in store: DownloadStore) throws {
#if DEBUG
        guard isEnabled, try store.allDownloads().isEmpty else { return }
        let folder = "/tmp/ndm-magic-qa-files"
        let now = Date(timeIntervalSince1970: 1_752_700_000)
        let samples: [DownloadTask] = [
            DownloadTask(
                url: "https://www.bilibili.com/video/BV1Preview",
                filename: "大模型中转站，怎么便宜？.mp4",
                fileSize: 67_600_000,
                category: .video,
                status: .complete,
                lastTry: now,
                firstTry: now.addingTimeInterval(-82),
                pageURL: "https://www.bilibili.com/video/BV1Preview",
                pageTitle: "大模型中转站，怎么便宜？",
                mimeType: "video/mp4",
                folderPath: folder
            ),
            DownloadTask(
                url: "https://example.com/Android-17.mp4",
                filename: "Android 17 全新原生视觉设计.mp4",
                fileSize: 787_000,
                category: .video,
                status: .complete,
                lastTry: now,
                firstTry: now.addingTimeInterval(-31),
                pageURL: "https://example.com/Android-17.mp4",
                mimeType: "video/mp4",
                folderPath: folder
            ),
            DownloadTask(
                url: "https://example.com/AI-report.pdf",
                filename: "用 AI 帮我谷重做公司官网.pdf",
                fileSize: 15_900_000,
                category: .document,
                status: .complete,
                lastTry: now,
                firstTry: now.addingTimeInterval(-44),
                mimeType: "application/pdf",
                folderPath: folder
            ),
            DownloadTask(
                url: "https://example.com/NDM_3.2.0_macOS.zip",
                filename: "NDM_3.2.0_macOS.zip",
                fileSize: 45_300_000,
                category: .compressed,
                status: .complete,
                lastTry: now,
                firstTry: now.addingTimeInterval(-29),
                mimeType: "application/zip",
                folderPath: folder
            ),
            DownloadTask(
                url: "https://example.com/夜曲.flac",
                filename: "夜曲 (Live) - 周杰伦.flac",
                fileSize: 28_500_000,
                category: .audio,
                status: .complete,
                lastTry: now,
                firstTry: now.addingTimeInterval(-53),
                mimeType: "audio/flac",
                folderPath: folder
            ),
            DownloadTask(
                url: "https://raw.githubusercontent.com/example/logger.js",
                filename: "logger.js",
                fileSize: 3_200,
                category: .misc,
                status: .complete,
                lastTry: now,
                firstTry: now.addingTimeInterval(-2),
                mimeType: "text/javascript",
                folderPath: folder
            ),
            // Inserted last so the inspector opens on the disk-image state.
            DownloadTask(
                url: "https://dldir1.qq.com/TencentVideo.dmg",
                filename: "TencentVideo2.175.0.55797.dmg",
                fileSize: 262_700_000,
                category: .application,
                status: .complete,
                lastTry: now,
                firstTry: now.addingTimeInterval(-96),
                pageURL: "https://dldir1.qq.com/TencentVideo.dmg",
                mimeType: "application/x-apple-diskimage",
                folderPath: folder
            ),
        ]
        for sample in samples {
            _ = try store.insert(sample)
        }
#endif
    }
}
