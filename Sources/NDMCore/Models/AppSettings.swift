import Foundation

/// Quiet Finder appearance preference. Default follows macOS System Settings.
public enum AppearanceMode: String, Codable, Sendable, Equatable, CaseIterable {
    case system
    case light
    case dark

    public var settingsTitle: String {
        switch self {
        case .system: return L10n.t("System", "跟随系统")
        case .light: return L10n.t("Light", "浅色")
        case .dark: return L10n.t("Dark", "深色")
        }
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var downloadDirectory: URL
    public var maxConnections: Int
    public var downloadAllAtOnce: Bool
    public var showCompletionDialog: Bool
    public var launchAtLogin: Bool
    public var useCategoryFolders: Bool
    public var customUserAgent: String?
    public var useCustomUserAgent: Bool
    public var httpProxy: ProxySettings?
    public var httpsProxy: ProxySettings?
    public var ftpProxy: ProxySettings?
    public var socksProxy: SocksProxySettings?
    public var bridgePort: UInt16
    /// Global bandwidth cap in bytes/sec (`BandWidthLimit`; 0 = unlimited).
    public var bandwidthLimitBytesPerSecond: Int64
    /// Push `ShowPanel*=1|0` to browser extensions (media floating panel).
    public var showBrowserMediaPanel: Bool
    /// Confirm each browser-captured download before starting (`NeatWaitWindow`).
    public var confirmBrowserDownloads: Bool
    /// Window chrome: System (default) / Light / Dark.
    public var appearanceMode: AppearanceMode
    /// UI language: System (default) / English / 简体中文.
    public var languageMode: AppLanguageMode
    /// Smart connection tuning: start low, double while it pays off, explain why.
    /// Optional for backward-compatible decoding of older settings files —
    /// read through `smartConnectionsEnabled` (default on).
    public var smartConnections: Bool?
    /// First-run onboarding shown? Optional for backward-compatible decoding.
    public var onboardingCompleted: Bool?
    /// Offer to download links found on the clipboard when the app activates.
    public var clipboardWatch: Bool?

    public var smartConnectionsEnabled: Bool { smartConnections ?? true }
    public var needsOnboarding: Bool { !(onboardingCompleted ?? false) }
    public var clipboardWatchEnabled: Bool { clipboardWatch ?? true }

    public init(
        downloadDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
        maxConnections: Int = 8,
        downloadAllAtOnce: Bool = true,
        showCompletionDialog: Bool = true,
        launchAtLogin: Bool = false,
        useCategoryFolders: Bool = true,
        customUserAgent: String? = nil,
        useCustomUserAgent: Bool = false,
        httpProxy: ProxySettings? = nil,
        httpsProxy: ProxySettings? = nil,
        ftpProxy: ProxySettings? = nil,
        socksProxy: SocksProxySettings? = nil,
        bridgePort: UInt16 = 10_007,
        bandwidthLimitBytesPerSecond: Int64 = 0,
        showBrowserMediaPanel: Bool = true,
        confirmBrowserDownloads: Bool = false,
        appearanceMode: AppearanceMode = .system,
        languageMode: AppLanguageMode = .system,
        smartConnections: Bool? = true
    ) {
        self.downloadDirectory = downloadDirectory
        self.maxConnections = maxConnections
        self.downloadAllAtOnce = downloadAllAtOnce
        self.showCompletionDialog = showCompletionDialog
        self.launchAtLogin = launchAtLogin
        self.useCategoryFolders = useCategoryFolders
        self.customUserAgent = customUserAgent
        self.useCustomUserAgent = useCustomUserAgent
        self.httpProxy = httpProxy
        self.httpsProxy = httpsProxy
        self.ftpProxy = ftpProxy
        self.socksProxy = socksProxy
        self.bridgePort = bridgePort
        self.bandwidthLimitBytesPerSecond = bandwidthLimitBytesPerSecond
        self.showBrowserMediaPanel = showBrowserMediaPanel
        self.confirmBrowserDownloads = confirmBrowserDownloads
        self.appearanceMode = appearanceMode
        self.languageMode = languageMode
        self.smartConnections = smartConnections
    }
}

public struct ProxySettings: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var username: String?
    public var password: String?
    public var enabled: Bool

    public init(host: String, port: UInt16, username: String? = nil, password: String? = nil, enabled: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.enabled = enabled
    }
}

public struct SocksProxySettings: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var version: SocksVersion
    public var username: String?
    public var password: String?
    public var enabled: Bool

    public init(
        host: String,
        port: UInt16,
        version: SocksVersion = .v5,
        username: String? = nil,
        password: String? = nil,
        enabled: Bool = false
    ) {
        self.host = host
        self.port = port
        self.version = version
        self.username = username
        self.password = password
        self.enabled = enabled
    }
}

public enum SocksVersion: Int, Codable, Sendable {
    case v4 = 4
    case v5 = 5
}

public struct AuthCredential: Identifiable, Codable, Sendable, Equatable {
    public var id: Int64
    public var target: String
    public var protocolName: String
    public var username: String
    public var password: String

    public init(id: Int64 = 0, target: String, protocolName: String, username: String, password: String) {
        self.id = id
        self.target = target
        self.protocolName = protocolName
        self.username = username
        self.password = password
    }
}
