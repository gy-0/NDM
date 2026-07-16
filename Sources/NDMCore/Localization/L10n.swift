import Foundation

/// UI language preference. Default follows macOS preferred languages.
public enum AppLanguageMode: String, Codable, Sendable, Equatable, CaseIterable {
    case system
    case english
    case simplifiedChinese

    public var settingsTitle: String {
        switch self {
        case .system: return L10n.t("System", "跟随系统")
        case .english: return L10n.t("English", "English")
        case .simplifiedChinese: return L10n.t("简体中文", "简体中文")
        }
    }
}

/// Lightweight bilingual catalog (EN / 简体中文) for SPM host UI.
/// Call `L10n.apply(_:)` when Settings change; UI should refresh via notification.
public enum L10n: Sendable {
    public static let didChangeNotification = Notification.Name("dev.ndm.open.languageDidChange")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: AppLanguageMode = .system

    public static func apply(_ next: AppLanguageMode) {
        lock.lock()
        mode = next
        lock.unlock()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    public static var currentMode: AppLanguageMode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    /// Resolved language for UI strings.
    public static var usesChinese: Bool {
        switch currentMode {
        case .simplifiedChinese:
            return true
        case .english:
            return false
        case .system:
            guard let preferred = Locale.preferredLanguages.first else { return false }
            return preferred.hasPrefix("zh")
        }
    }

    public static var locale: Locale {
        usesChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
    }

    public static func t(_ english: String, _ chinese: String) -> String {
        usesChinese ? chinese : english
    }

    // MARK: - Common actions

    public static var cancel: String { t("Cancel", "取消") }
    public static var close: String { t("Close", "关闭") }
    public static var save: String { t("Save", "保存") }
    public static var open: String { t("Open", "打开") }
    public static var start: String { t("Start", "开始") }
    public static var pause: String { t("Pause", "暂停") }
    public static var resume: String { t("Resume", "继续") }
    public static var retry: String { t("Retry", "重试") }
    public static var delete: String { t("Delete", "删除") }
    public static var download: String { t("Download", "下载") }
    public static var quit: String { t("Quit", "退出") }
    public static var apply: String { t("Apply", "应用") }
    public static var choose: String { t("Choose…", "选择…") }
    public static var yes: String { t("Yes", "是") }
    public static var no: String { t("No", "否") }
    public static var unknown: String { t("Unknown", "未知") }
    public static var emDash: String { "—" }

    public static var showInFinder: String { t("Show in Finder", "在访达中显示") }
    public static var copyURL: String { t("Copy URL", "复制链接") }
    public static var renewURL: String { t("Renew URL", "更换链接") }
    public static var renewURLEllipsis: String { t("Renew URL…", "更换链接…") }
    public static var renewAndStart: String { t("Renew & Start", "更换并开始") }
    public static var renew: String { t("Renew", "更换") }
    public static var properties: String { t("Properties", "属性") }
    public static var propertiesEllipsis: String { t("Properties…", "属性…") }
    public static var detailsEllipsis: String { t("Details…", "详情…") }
    public static var connectionDetails: String { t("Connection details…", "连接详情…") }
    public static var progressDetails: String { t("Progress Details", "进度详情") }
    public static var showProgress: String { t("Show Progress", "显示进度") }
    public static var removeEllipsis: String { t("Remove…", "移除…") }
    public static var removeTask: String { t("Remove Task", "仅移除任务") }
    public static var removeAndTrash: String { t("Remove & Trash File", "移除并移到废纸篓") }

    // MARK: - Status / sidebar

    public static var status: String { t("Status", "状态") }
    public static var type: String { t("Type", "类型") }
    public static var all: String { t("All", "全部") }
    public static var active: String { t("Active", "进行中") }
    public static var queued: String { t("Queued", "排队中") }
    public static var paused: String { t("Paused", "已暂停") }
    public static var completed: String { t("Completed", "已完成") }
    public static var failed: String { t("Failed", "失败") }
    public static var incomplete: String { t("Incomplete", "未完成") }
    public static var downloading: String { t("Downloading", "下载中") }
    public static var waiting: String { t("Waiting", "等待中") }
    public static var complete: String { t("Complete", "完成") }
    public static var error: String { t("Error", "错误") }

    public static var video: String { t("Video", "视频") }
    public static var audio: String { t("Audio", "音频") }
    public static var document: String { t("Document", "文档") }
    public static var compressed: String { t("Compressed", "压缩包") }
    public static var appCategory: String { t("App", "应用") }
    public static var image: String { t("Image", "图片") }
    public static var other: String { t("Other", "其他") }

    public static var untitled: String { t("Untitled", "未命名") }
    public static var hlsStream: String { t("HLS stream", "HLS 流") }
    public static var multiTrackMedia: String { t("Multi-track media", "多轨媒体") }
    public static var ftp: String { t("FTP", "FTP") }

    // MARK: - Main window

    public static var appName: String { "NDM" }
    public static var new: String { t("New", "新建") }
    public static var newDownload: String { t("New Download", "新建下载") }
    public static var newDownloadEllipsis: String { t("New Download…", "新建下载…") }
    public static var newDownloadTooltip: String { t("Add a new download URL", "添加下载链接") }
    public static var startTooltip: String { t("Start or resume the selected download", "开始或继续所选下载") }
    public static var pauseTooltip: String { t("Pause the selected download", "暂停所选下载") }
    public static var searchDownloads: String { t("Search downloads", "搜索下载") }
    public static var search: String { t("Search", "搜索") }
    public static var browsers: String { t("Browsers", "浏览器") }
    public static var browsersTooltip: String { t("Browser extension setup", "浏览器扩展设置") }
    public static var settings: String { t("Settings", "设置") }
    public static var settingsEllipsis: String { t("Settings…", "设置…") }
    public static var details: String { t("Details", "详情") }
    public static var selectDownloadHint: String { t("Select a download to see actions.", "选择一项下载以查看操作。") }

    public static var emptyNoDownloads: String { t("No downloads yet", "还没有下载任务") }
    public static var emptyDropHint: String {
        t("Press ⌘N or drop a link here to start.", "按 ⌘N 或把链接拖到这里开始。")
    }
    public static var emptyTrySearch: String {
        t("Try another search, or clear the search field.", "试试其他关键词，或清空搜索框。")
    }
    public static var emptyTryFilter: String {
        t("Choose another filter in the sidebar, or add a new download.", "换一个侧栏筛选，或新建下载。")
    }

    public static func emptyNoMatches(_ query: String) -> String {
        t("No matches for “\(query)”", "没有匹配「\(query)」的结果")
    }

    public static func emptyNoFilter(_ filterTitle: String) -> String {
        t("No \(filterTitle.lowercased()) downloads", "没有「\(filterTitle)」下载")
    }

    public static var pasteURLHint: String {
        t("Paste an HTTP, HTTPS, or FTP URL.", "粘贴 HTTP、HTTPS 或 FTP 链接。")
    }

    public static func removeConfirm(_ name: String) -> String {
        t("Remove “\(name)”?", "移除「\(name)」？")
    }

    public static var removeConfirmBody: String {
        t(
            "Remove from the list, or also move the downloaded file to Trash.",
            "从列表移除，或同时把已下载文件移到废纸篓。"
        )
    }

    public static var renewURLBody: String {
        t("Paste a fresh URL. Partial segments are kept.", "粘贴新的链接。已下载分段会保留。")
    }

    public static var renewURLBodyProgress: String {
        t(
            "Paste a fresh URL for this task (keeps partial segments).",
            "为此任务粘贴新链接（保留已下载分段）。"
        )
    }

    public static var somethingWentWrong: String { t("Something went wrong", "出错了") }
    public static var fileNotFound: String { t("File not found", "找不到文件") }
    public static func downloadFallback(_ id: Int64) -> String {
        t("Download \(id)", "下载 \(id)")
    }

    // MARK: - Progress window

    public static var tabDownload: String { t("Download", "下载") }
    public static var tabOptions: String { t("Options", "选项") }
    public static var tabConnections: String { t("Connections", "连接") }
    public static var url: String { t("URL", "链接") }
    public static var size: String { t("Size", "大小") }
    public static var source: String { t("Source", "来源") }
    public static var progress: String { t("Progress", "进度") }
    public static var downloaded: String { t("Downloaded", "已下载") }
    public static var speed: String { t("Speed", "速度") }
    public static var timeLeft: String { t("Time left", "剩余时间") }
    public static var resumable: String { t("Resumable", "可断点续传") }
    public static var segments: String { t("Segments", "分段") }
    public static func segmentsCount(_ n: Int) -> String {
        t("Segments · \(n)", "分段 · \(n)")
    }
    public static var connections: String { t("Connections", "连接") }
    public static var connectionsRange: String { t("Connections (1–32)", "连接数（1–32）") }
    public static var optionsNote: String {
        t(
            "Change connection count while downloading to replan active Range transfers. Renew replaces an expired URL without discarding partial segments.",
            "下载过程中可调整连接数以重新规划 Range 传输。更换链接可替换过期地址，并保留已下载分段。"
        )
    }
    public static func doneTitle(_ filename: String) -> String {
        t("Done · \(filename)", "完成 · \(filename)")
    }
    public static func connectionN(_ n: Int) -> String {
        t("Connection \(n)", "连接 \(n)")
    }

    // MARK: - Completion / Wait / Browsers / Properties

    public static var downloadComplete: String { t("Download Complete", "下载完成") }
    public static var ready: String { t("Ready", "已就绪") }
    public static var confirmDownload: String { t("Confirm Download", "确认下载") }
    public static var downloadFromBrowser: String { t("Download from browser", "来自浏览器的下载") }
    public static var includesAudioTrack: String { t("Includes audio track", "包含音轨") }
    public static var capturedByBetterNDM: String { t("Captured by BetterNDM", "由 BetterNDM 捕获") }

    public static var browserExtension: String { t("Browser Extension", "浏览器扩展") }
    public static var browserExtensionEllipsis: String { t("Browser Extension…", "浏览器扩展…") }
    public static var connectBetterNDM: String { t("Connect BetterNDM", "连接 BetterNDM") }
    public static func bridgeReady(_ endpoint: String) -> String {
        t("Bridge ready · \(endpoint)", "桥接就绪 · \(endpoint)")
    }
    public static func bridgeUnavailable(_ port: UInt16) -> String {
        t("Bridge unavailable · port \(port) is busy", "桥接不可用 · 端口 \(port) 已被占用")
    }
    public static var browsersBody: String {
        t(
            """
            1. Open Chrome, Edge, or Firefox
            2. Load the unpacked BetterNDM extension
            3. Keep NDM running — the extension connects automatically
            4. Captured media shows in the page panel when enabled in Settings → Browser
            """,
            """
            1. 打开 Chrome、Edge 或 Firefox
            2. 以「加载已解压的扩展程序」方式加载 BetterNDM
            3. 保持 NDM 运行 — 扩展会自动连接
            4. 在「设置 → 浏览器」开启后，捕获的媒体会出现在页面浮层
            """
        )
    }
    public static var showExtensionFolder: String { t("Show Extension Folder", "显示扩展文件夹") }
    public static var copyBridgeAddress: String { t("Copy Bridge Address", "复制桥接地址") }
    public static var extensionFolderMissing: String { t("Extension folder not found", "找不到扩展文件夹") }
    public static var extensionFolderHint: String {
        t(
            "Open the NDM project and load reverse/extension/BetterNDM as an unpacked extension.",
            "打开 NDM 项目，将 reverse/extension/BetterNDM 以未打包扩展方式加载。"
        )
    }

    public static var filename: String { t("Filename", "文件名") }
    public static var speedLimitCaption: String {
        t("Speed limit (bytes/s, 0 = unlimited)", "速度限制（字节/秒，0 = 不限制）")
    }
    public static var alternateAudioURL: String { t("Alternate / audio URL", "备用 / 音轨链接") }
    public static var saveLocationPending: String { t("Save location not set yet", "尚未设置保存位置") }

    // MARK: - Settings

    public static var general: String { t("General", "通用") }
    public static var browser: String { t("Browser", "浏览器") }
    public static var network: String { t("Network", "网络") }
    public static var advanced: String { t("Advanced", "高级") }
    public static var appearance: String { t("Appearance", "外观") }
    public static var theme: String { t("Theme", "主题") }
    public static var language: String { t("Language", "语言") }
    public static var languageFootnote: String {
        t(
            "System follows macOS language. Changing language updates menus and windows immediately.",
            "「跟随系统」使用 macOS 语言。更改后菜单和窗口会立即更新。"
        )
    }
    public static var appearanceFootnote: String {
        t(
            "System follows macOS appearance. Light and Dark lock the window chrome.",
            "「跟随系统」使用 macOS 外观。浅色 / 深色会锁定窗口主题。"
        )
    }
    public static var downloads: String { t("Downloads", "下载") }
    public static var behavior: String { t("Behavior", "行为") }
    public static var saveFilesTo: String { t("Save files to", "文件保存到") }
    public static var maxConnectionsCaption: String {
        t("Max connections per download (1–32)", "每个任务最大连接数（1–32）")
    }
    public static var globalSpeedCaption: String {
        t("Global speed limit (bytes/s, 0 = unlimited)", "全局限速（字节/秒，0 = 不限制）")
    }
    public static var organizeCategories: String {
        t("Organize into category subfolders", "按分类放入子文件夹")
    }
    public static var downloadAllAtOnce: String {
        t("Download multiple tasks at once", "同时下载多个任务")
    }
    public static var showCompletionDialog: String {
        t("Show dialog when a download finishes", "下载完成时显示提示")
    }
    public static var showMediaPanel: String {
        t("Show floating media panel in browser", "在浏览器显示媒体浮层")
    }
    public static var confirmBrowserCaptures: String {
        t("Ask before starting browser captures", "捕获前先确认再下载")
    }
    public static var confirmBrowserFootnote: String {
        t(
            "Off by default: captures start downloading immediately. Turn on to review each URL first.",
            "默认关闭：捕获后立即开始下载。开启后可先确认每个链接。"
        )
    }
    public static var identity: String { t("Identity", "标识") }
    public static var useCustomUA: String { t("Use custom User-Agent", "使用自定义 User-Agent") }
    public static var userAgentString: String { t("User-Agent string", "User-Agent 字符串") }
    public static var browserSettingsFootnote: String {
        t(
            "These options are pushed to the browser extension over the local WebSocket bridge.",
            "这些选项会通过本地 WebSocket 桥接推送到浏览器扩展。"
        )
    }
    public static var httpProxy: String { t("HTTP(S) proxy", "HTTP(S) 代理") }
    public static var ftpProxy: String { t("FTP proxy (HTTP CONNECT)", "FTP 代理（HTTP CONNECT）") }
    public static var socksProxy: String { t("SOCKS proxy (overrides HTTP)", "SOCKS 代理（优先于 HTTP）") }
    public static var host: String { t("Host", "主机") }
    public static var version: String { t("Version", "版本") }
    public static var portPlaceholder: String { t("Port", "端口") }
    public static var usernamePlaceholder: String { t("Username", "用户名") }
    public static var passwordPlaceholder: String { t("Password", "密码") }
    public static var migration: String { t("Migration", "迁移") }
    public static var migrationFootnote: String {
        t(
            "Import tasks from the original Neat Download Manager database. Your NDM data stays in ~/Library/Application Support/dev.ndm.open.",
            "从原版 Neat Download Manager 数据库导入任务。NDM 数据仍保存在 ~/Library/Application Support/dev.ndm.open。"
        )
    }
    public static var importLegacyDB: String {
        t("Import Original Neat Database…", "导入原版 Neat 数据库…")
    }
    public static var selectLegacyDB: String { t("Select original neatdb.sqlite", "选择原版 neatdb.sqlite") }
    public static func importedCount(_ n: Int) -> String {
        t("Imported \(n) downloads", "已导入 \(n) 个下载")
    }
    public static var importFailed: String { t("Import failed", "导入失败") }

    // MARK: - Menus / About / bridge

    public static var aboutNDM: String { t("About NDM", "关于 NDM") }
    public static var quitNDM: String { t("Quit NDM", "退出 NDM") }
    public static var fileMenu: String { t("File", "文件") }
    public static var editMenu: String { t("Edit", "编辑") }
    public static var windowMenu: String { t("Window", "窗口") }
    public static var cut: String { t("Cut", "剪切") }
    public static var copy: String { t("Copy", "拷贝") }
    public static var paste: String { t("Paste", "粘贴") }
    public static var selectAll: String { t("Select All", "全选") }
    public static var showMainWindow: String { t("Show Main Window", "显示主窗口") }
    public static var minimize: String { t("Minimize", "最小化") }
    public static var idle: String { t("Idle", "空闲") }
    public static var idleBridgeOff: String { t("Idle · bridge off", "空闲 · 桥接关闭") }
    public static func activeSummary(_ count: Int, _ speed: String) -> String {
        t("\(count) active · \(speed)", "\(count) 个进行中 · \(speed)")
    }
    public static var downloadsInProgress: String { t("Downloads in progress", "仍有下载进行中") }
    public static var quitWithActiveBody: String {
        t(
            "Quit and leave incomplete downloads? You can resume them later.",
            "退出并保留未完成的下载？之后可以继续。"
        )
    }
    public static var failedToStart: String { t("Failed to start NDM", "无法启动 NDM") }
    public static var downloadFailed: String { t("Download failed", "下载失败") }
    public static func bridgePortInUse(_ port: UInt16) -> String {
        t("Browser bridge port \(port) is in use", "浏览器桥接端口 \(port) 已被占用")
    }
    public static func bridgePortInUseBody(_ port: UInt16, _ detail: String) -> String {
        t(
            """
            Another app is already listening on 127.0.0.1:\(port) \
            (usually the original Neat Download Manager).

            Quit that app, then restart NDM if you need BetterNDM.

            NDM will continue without the WebSocket bridge.
            \(detail)
            """,
            """
            已有应用占用 127.0.0.1:\(port) \
            （通常是原版 Neat Download Manager）。

            请退出该应用后重启 NDM，以便使用 BetterNDM。

            NDM 将在没有 WebSocket 桥接的情况下继续运行。
            \(detail)
            """
        )
    }
    public static var continueWithoutBridge: String {
        t("Continue Without Bridge", "不使用桥接继续")
    }
    public static func aboutBody(dataPath: String, bridge: String) -> String {
        t(
            """
            Open-source download manager for macOS.

            Data: \(dataPath)
            Bridge: \(bridge)
            Extension: BetterNDM

            Inspired by Neat Download Manager's download engine behaviour — not a UI clone.
            """,
            """
            面向 macOS 的开源下载工具。

            数据目录：\(dataPath)
            桥接：\(bridge)
            扩展：BetterNDM

            下载引擎行为参考 Neat Download Manager，界面为独立设计，并非 UI 复刻。
            """
        )
    }
}
