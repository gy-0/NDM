import Foundation

/// Persists host settings under `dev.ndm.open` (independent of original prefs domain).
public enum SettingsStore {
    private static let suiteName = "dev.ndm.open"
    private static let key = "AppSettingsJSON"

    private struct DiskSettings: Codable {
        var downloadDirectory: String
        var maxConnections: Int
        var downloadAllAtOnce: Bool
        var showCompletionDialog: Bool
        var launchAtLogin: Bool
        var useCategoryFolders: Bool
        var customUserAgent: String?
        var useCustomUserAgent: Bool
        var httpProxy: ProxySettings?
        var httpsProxy: ProxySettings?
        var ftpProxy: ProxySettings?
        var socksProxy: SocksProxySettings?
        var bridgePort: UInt16
        var bandwidthLimitBytesPerSecond: Int64?
        var showBrowserMediaPanel: Bool?
        var confirmBrowserDownloads: Bool?
        var appearanceMode: String?
        var languageMode: String?
    }

    public static func load() -> AppSettings {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        guard let data = defaults.data(forKey: key),
              let disk = try? JSONDecoder().decode(DiskSettings.self, from: data) else {
            return AppSettings()
        }
        return AppSettings(
            downloadDirectory: URL(fileURLWithPath: disk.downloadDirectory),
            maxConnections: disk.maxConnections,
            downloadAllAtOnce: disk.downloadAllAtOnce,
            showCompletionDialog: disk.showCompletionDialog,
            launchAtLogin: disk.launchAtLogin,
            useCategoryFolders: disk.useCategoryFolders,
            customUserAgent: disk.customUserAgent,
            useCustomUserAgent: disk.useCustomUserAgent,
            httpProxy: disk.httpProxy,
            httpsProxy: disk.httpsProxy,
            ftpProxy: disk.ftpProxy,
            socksProxy: disk.socksProxy,
            bridgePort: disk.bridgePort,
            bandwidthLimitBytesPerSecond: disk.bandwidthLimitBytesPerSecond ?? 0,
            showBrowserMediaPanel: disk.showBrowserMediaPanel ?? true,
            confirmBrowserDownloads: disk.confirmBrowserDownloads ?? false,
            appearanceMode: AppearanceMode(rawValue: disk.appearanceMode ?? "") ?? .system,
            languageMode: AppLanguageMode(rawValue: disk.languageMode ?? "") ?? .system
        )
    }

    public static func save(_ settings: AppSettings) {
        let disk = DiskSettings(
            downloadDirectory: settings.downloadDirectory.path,
            maxConnections: settings.maxConnections,
            downloadAllAtOnce: settings.downloadAllAtOnce,
            showCompletionDialog: settings.showCompletionDialog,
            launchAtLogin: settings.launchAtLogin,
            useCategoryFolders: settings.useCategoryFolders,
            customUserAgent: settings.customUserAgent,
            useCustomUserAgent: settings.useCustomUserAgent,
            httpProxy: settings.httpProxy,
            httpsProxy: settings.httpsProxy,
            ftpProxy: settings.ftpProxy,
            socksProxy: settings.socksProxy,
            bridgePort: settings.bridgePort,
            bandwidthLimitBytesPerSecond: settings.bandwidthLimitBytesPerSecond,
            showBrowserMediaPanel: settings.showBrowserMediaPanel,
            confirmBrowserDownloads: settings.confirmBrowserDownloads,
            appearanceMode: settings.appearanceMode.rawValue,
            languageMode: settings.languageMode.rawValue
        )
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        if let data = try? JSONEncoder().encode(disk) {
            defaults.set(data, forKey: key)
        }
    }
}
