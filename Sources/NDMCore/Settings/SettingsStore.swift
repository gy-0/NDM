import Foundation

/// Persists host settings in this app's standard bundle preferences domain.
public enum SettingsStore {
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
        var accentTheme: String?
        var customAccentHex: String?
        var languageMode: String?
        var smartConnections: Bool?
        var onboardingCompleted: Bool?
        var clipboardWatch: Bool?
    }

    public static func load() -> AppSettings {
        load(defaults: .standard)
    }

    /// Internal injection point keeps tests out of the production preferences domain.
    static func load(defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let disk = try? JSONDecoder().decode(DiskSettings.self, from: data) else {
            return AppSettings()
        }
        var settings = AppSettings(
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
            accentTheme: AccentTheme(rawValue: disk.accentTheme ?? "") ?? .classicBlue,
            customAccentHex: disk.customAccentHex,
            languageMode: AppLanguageMode(rawValue: disk.languageMode ?? "") ?? .system,
            smartConnections: disk.smartConnections ?? true
        )
        settings.onboardingCompleted = disk.onboardingCompleted
        settings.clipboardWatch = disk.clipboardWatch
        return settings
    }

    public static func save(_ settings: AppSettings) {
        save(settings, defaults: .standard)
    }

    /// Internal injection point keeps tests out of the production preferences domain.
    static func save(_ settings: AppSettings, defaults: UserDefaults) {
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
            accentTheme: settings.accentTheme.rawValue,
            customAccentHex: settings.customAccentHex,
            languageMode: settings.languageMode.rawValue,
            smartConnections: settings.smartConnections,
            onboardingCompleted: settings.onboardingCompleted,
            clipboardWatch: settings.clipboardWatch
        )
        if let data = try? JSONEncoder().encode(disk) {
            defaults.set(data, forKey: key)
            defaults.synchronize()
        }
    }

    /// Mark first-run complete without rewriting unrelated settings.
    public static func markOnboardingCompleted() {
        var settings = load()
        settings.onboardingCompleted = true
        save(settings)
    }
}
