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

    static var accentTheme: AccentTheme? {
        guard isEnabled, let raw = environment["NDM_QA_ACCENT_THEME"] else { return nil }
        return AccentTheme(rawValue: raw)
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

    /// Keeps live QA downloads out of the user's real Downloads directory.
    static var downloadDirectory: URL? {
        guard isEnabled,
              let path = environment["NDM_QA_DOWNLOAD_ROOT"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var bridgePort: UInt16? {
        guard isEnabled,
              let raw = environment["NDM_QA_BRIDGE_PORT"] else { return nil }
        return UInt16(raw)
    }

    static var maxConnections: Int? {
        guard isEnabled,
              let raw = environment["NDM_QA_MAX_CONNECTIONS"],
              let value = Int(raw) else { return nil }
        return min(32, max(1, value))
    }

    static var windowSize: NSSize? {
        guard isEnabled,
              let widthRaw = environment["NDM_QA_WINDOW_WIDTH"],
              let heightRaw = environment["NDM_QA_WINDOW_HEIGHT"],
              let width = Double(widthRaw),
              let height = Double(heightRaw) else { return nil }
        return NSSize(width: max(960, width), height: max(620, height))
    }

    static var performanceTaskCount: Int? {
        guard isEnabled,
              let raw = environment["NDM_QA_TASK_COUNT"],
              let count = Int(raw),
              count > 0 else { return nil }
        return min(count, 10_000)
    }

    /// Lets visual QA open a deterministic inspector state without synthetic
    /// clicks or Accessibility permission. The match stays debug-only and is
    /// intentionally fuzzy so localized fixture names remain easy to target.
    static var selectedFilenameContains: String? {
        guard isEnabled,
              let value = environment["NDM_QA_SELECTED_FILENAME_CONTAINS"],
              !value.isEmpty else { return nil }
        return value
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

    static var showMediaAccess: Bool {
        isEnabled && environment["NDM_QA_SHOW_MEDIA_ACCESS"] == "1"
    }

    static var showSettings: Bool {
        isEnabled && environment["NDM_QA_SHOW_SETTINGS"] == "1"
    }

    static var settingsSection: String? {
        guard isEnabled,
              let value = environment["NDM_QA_SETTINGS_SECTION"],
              !value.isEmpty else { return nil }
        return value
    }

    static var showNewDownload: Bool {
        isEnabled && environment["NDM_QA_SHOW_NEW_DOWNLOAD"] == "1"
    }

    /// Opens the progress window for the initially selected task (pair with
    /// `NDM_QA_SELECTED_FILENAME_CONTAINS` for a deterministic target).
    static var showProgress: Bool {
        isEnabled && environment["NDM_QA_SHOW_PROGRESS"] == "1"
    }

    /// Deterministically exercises the narrow interval where the completed
    /// result is already visible but the shared-element handoff is still
    /// running. This remains debug-only and is used to catch window-revival
    /// races without timing an Accessibility click by hand.
    static var dismissCompletionDuringHandoff: Bool {
        isEnabled && environment["NDM_QA_DISMISS_COMPLETION_DURING_HANDOFF"] == "1"
    }

    /// Launch with a sidebar filter preselected, e.g. `NDM_QA_FILTER=video`.
    static var initialFilter: SidebarFilter? {
        guard isEnabled, let raw = environment["NDM_QA_FILTER"] else { return nil }
        return SidebarFilter(rawValue: raw)
    }

    static var showMediaPreparation: Bool {
        isEnabled && environment["NDM_QA_SHOW_MEDIA_PREPARATION"] == "1"
    }

    static var includeFailure: Bool {
        isEnabled && environment["NDM_QA_INCLUDE_FAILURE"] == "1"
    }

    static var mediaAccessURL: String {
        environment["NDM_QA_MEDIA_ACCESS_URL"]
            ?? "https://www.douyin.com/video/7480000000000000000"
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
    static let accentTheme: AccentTheme? = nil
    static let interfaceScale: CGFloat? = nil
    static let clipboardText: String? = nil
    static let supportDirectory: URL? = nil
    static let downloadDirectory: URL? = nil
    static let bridgePort: UInt16? = nil
    static let maxConnections: Int? = nil
    static let windowSize: NSSize? = nil
    static let performanceTaskCount: Int? = nil
    static let selectedFilenameContains: String? = nil
    static let showUpgrade = false
    static let showCompletion = false
    static let showOnboarding = false
    static let showMediaAccess = false
    static let showSettings = false
    static let settingsSection: String? = nil
    static let showNewDownload = false
    static let showProgress = false
    static let dismissCompletionDuringHandoff = false
    static let initialFilter: SidebarFilter? = nil
    static let showMediaPreparation = false
    static let includeFailure = false
    static let mediaAccessURL = "https://www.douyin.com/video/7480000000000000000"
    static let upgradeFeatures: [ProFeature] = []
#endif

    static func apply(to settings: inout AppSettings) {
        guard isEnabled else { return }
        if let appearanceMode { settings.appearanceMode = appearanceMode }
        if let languageMode { settings.languageMode = languageMode }
        if let accentTheme { settings.accentTheme = accentTheme }
        if let bridgePort { settings.bridgePort = bridgePort }
        if let downloadDirectory { settings.downloadDirectory = downloadDirectory }
        if let maxConnections { settings.maxConnections = maxConnections }
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
        let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        // Real, isolated files make the completed-result inspector truthful in
        // visual QA: the app discovers these through the same on-disk path used
        // in production, rather than a UI-only fixture.
        let resultFiles: [(String, String)] = [
            ("大模型中转站，怎么便宜？.mp4", "qa video"),
            ("大模型中转站，怎么便宜？.zh-Hans.srt", "1\n00:00:00,000 --> 00:00:02,000\n测试字幕\n"),
            ("大模型中转站，怎么便宜？.en.vtt", "WEBVTT\n\n00:00.000 --> 00:02.000\nQA subtitle\n"),
            ("大模型中转站，怎么便宜？.webp", "qa cover"),
            ("大模型中转站，怎么便宜？.info.json", "{\"qa\":true}"),
        ]
        for (name, contents) in resultFiles {
            try Data(contents.utf8).write(
                to: folderURL.appendingPathComponent(name),
                options: .atomic
            )
        }
        let now = Date(timeIntervalSince1970: 1_752_700_000)
        if let count = performanceTaskCount {
            let categories: [(DownloadCategory, String, String)] = [
                (.video, "mp4", "video/mp4"),
                (.document, "pdf", "application/pdf"),
                (.compressed, "zip", "application/zip"),
                (.audio, "flac", "audio/flac"),
                (.application, "dmg", "application/x-apple-diskimage"),
                (.misc, "bin", "application/octet-stream"),
            ]
            for index in 0..<count {
                let descriptor = categories[index % categories.count]
                let number = String(format: "%04d", index + 1)
                let sample = DownloadTask(
                    url: "https://qa.example.com/files/performance-\(number).\(descriptor.1)",
                    filename: "性能样本 \(number).\(descriptor.1)",
                    fileSize: Int64(64_000 + (index % 500) * 37_000),
                    category: descriptor.0,
                    status: .complete,
                    lastTry: now.addingTimeInterval(TimeInterval(-index)),
                    firstTry: now.addingTimeInterval(TimeInterval(-index - 12)),
                    mimeType: descriptor.2,
                    folderPath: folder
                )
                _ = try store.insert(sample)
            }
            return
        }
        var samples: [DownloadTask] = [
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
        if includeFailure {
            samples.insert(
                DownloadTask(
                    url: "https://cdn.example.com/expired/design-preview.mp4",
                    filename: "品牌设计提案 4K.mp4",
                    fileSize: 128_400_000,
                    category: .video,
                    status: .error,
                    lastTry: now,
                    firstTry: now.addingTimeInterval(-18),
                    pageURL: "https://example.com/watch/design-preview",
                    pageTitle: "品牌设计提案",
                    mimeType: "video/mp4",
                    errorText: DownloadDiagnostic.linkExpired(status: 403).storageString,
                    folderPath: folder
                ),
                at: samples.index(before: samples.endIndex)
            )
        }
        for sample in samples {
            _ = try store.insert(sample)
        }
#endif
    }
}
