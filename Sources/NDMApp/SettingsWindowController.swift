import AppKit
import UniformTypeIdentifiers
import NDMCore
import NDMEngine

@MainActor
final class SettingsWindowController: NSWindowController {
    private let manager: DownloadManager
    private var settings: AppSettings

    private let dirField = NSTextField(string: "")
    private let connField = NSTextField(string: "8")
    private let bwField = NSTextField(string: "0")
    private let categoryCheck = NSButton(checkboxWithTitle: "Use category subfolders", target: nil, action: nil)
    private let allAtOnceCheck = NSButton(checkboxWithTitle: "Download all at once", target: nil, action: nil)
    private let completeCheck = NSButton(checkboxWithTitle: "Show completion dialog", target: nil, action: nil)
    private let panelCheck = NSButton(checkboxWithTitle: "Show browser media panel (ShowPanel=1)", target: nil, action: nil)
    private let confirmCheck = NSButton(checkboxWithTitle: "Confirm browser downloads (Wait window)", target: nil, action: nil)
    private let uaCheck = NSButton(checkboxWithTitle: "Custom User-Agent", target: nil, action: nil)
    private let uaField = NSTextField(string: "")
    private let proxyCheck = NSButton(checkboxWithTitle: "HTTP(S) Proxy", target: nil, action: nil)
    private let proxyHostField = NSTextField(string: "")
    private let proxyPortField = NSTextField(string: "8080")
    private let proxyUserField = NSTextField(string: "")
    private let proxyPassField = NSSecureTextField(string: "")
    private let ftpProxyCheck = NSButton(checkboxWithTitle: "FTP Proxy (HTTP CONNECT)", target: nil, action: nil)
    private let ftpHostField = NSTextField(string: "")
    private let ftpPortField = NSTextField(string: "8080")
    private let ftpUserField = NSTextField(string: "")
    private let ftpPassField = NSSecureTextField(string: "")
    private let socksCheck = NSButton(checkboxWithTitle: "SOCKS Proxy (overrides HTTP)", target: nil, action: nil)
    private let socksHostField = NSTextField(string: "")
    private let socksPortField = NSTextField(string: "1080")
    private let socksUserField = NSTextField(string: "")
    private let socksPassField = NSSecureTextField(string: "")
    private let socksVersionPopup = NSPopUpButton()

    init(manager: DownloadManager, settings: AppSettings) {
        self.manager = manager
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        super.init(window: window)
        buildUI()
        loadFields()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let browse = NSButton(title: "Choose…", target: self, action: #selector(chooseDir))
        browse.bezelStyle = .rounded
        socksVersionPopup.removeAllItems()
        socksVersionPopup.addItems(withTitles: ["SOCKS5", "SOCKS4"])
        let importLegacy = NSButton(title: "Import Original Neat DB…", target: self, action: #selector(importLegacy))
        importLegacy.bezelStyle = .rounded
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded

        let scroll = NSScrollView(frame: content.bounds)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .noBorder
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 900))
        scroll.documentView = doc
        content.addSubview(scroll)

        let grid = NSStackView(views: [
            NSTextField(labelWithString: "Download folder"), dirField, browse,
            NSTextField(labelWithString: "Max connections (1–32)"), connField,
            NSTextField(labelWithString: "Global bandwidth limit bytes/s (0=∞)"), bwField,
            categoryCheck, allAtOnceCheck, completeCheck, panelCheck, confirmCheck,
            uaCheck, uaField,
            proxyCheck,
            NSTextField(labelWithString: "HTTP proxy host / port / user / pass"),
            proxyHostField, proxyPortField, proxyUserField, proxyPassField,
            ftpProxyCheck,
            NSTextField(labelWithString: "FTP proxy host / port / user / pass"),
            ftpHostField, ftpPortField, ftpUserField, ftpPassField,
            socksCheck,
            NSTextField(labelWithString: "SOCKS host / port / user / pass / version"),
            socksHostField, socksPortField, socksUserField, socksPassField, socksVersionPopup,
            importLegacy,
            NSStackView(views: [save, cancel]),
        ])
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 5
        grid.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: doc.topAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -12),
            grid.widthAnchor.constraint(equalToConstant: 476),
        ])
        for f in [dirField, uaField, proxyHostField, proxyUserField, ftpHostField, ftpUserField, socksHostField, socksUserField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 460).isActive = true
        }
    }

    private func loadFields() {
        dirField.stringValue = settings.downloadDirectory.path
        connField.stringValue = "\(settings.maxConnections)"
        bwField.stringValue = "\(settings.bandwidthLimitBytesPerSecond)"
        categoryCheck.state = settings.useCategoryFolders ? .on : .off
        allAtOnceCheck.state = settings.downloadAllAtOnce ? .on : .off
        completeCheck.state = settings.showCompletionDialog ? .on : .off
        panelCheck.state = settings.showBrowserMediaPanel ? .on : .off
        confirmCheck.state = settings.confirmBrowserDownloads ? .on : .off
        uaCheck.state = settings.useCustomUserAgent ? .on : .off
        uaField.stringValue = settings.customUserAgent ?? ""
        proxyCheck.state = (settings.httpProxy?.enabled == true) ? .on : .off
        proxyHostField.stringValue = settings.httpProxy?.host ?? ""
        proxyPortField.stringValue = "\(settings.httpProxy?.port ?? 8080)"
        proxyUserField.stringValue = settings.httpProxy?.username ?? ""
        proxyPassField.stringValue = settings.httpProxy?.password ?? ""
        ftpProxyCheck.state = (settings.ftpProxy?.enabled == true) ? .on : .off
        ftpHostField.stringValue = settings.ftpProxy?.host ?? ""
        ftpPortField.stringValue = "\(settings.ftpProxy?.port ?? 8080)"
        ftpUserField.stringValue = settings.ftpProxy?.username ?? ""
        ftpPassField.stringValue = settings.ftpProxy?.password ?? ""
        socksCheck.state = (settings.socksProxy?.enabled == true) ? .on : .off
        socksHostField.stringValue = settings.socksProxy?.host ?? ""
        socksPortField.stringValue = "\(settings.socksProxy?.port ?? 1080)"
        socksUserField.stringValue = settings.socksProxy?.username ?? ""
        socksPassField.stringValue = settings.socksProxy?.password ?? ""
        socksVersionPopup.selectItem(at: settings.socksProxy?.version == .v4 ? 1 : 0)
    }

    @objc private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.downloadDirectory
        if panel.runModal() == .OK, let url = panel.url {
            dirField.stringValue = url.path
        }
    }

    @objc private func importLegacy() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["sqlite", "db", "sqlite3"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.canChooseDirectories = false
        panel.directoryURL = LegacyDBImporter.defaultOriginalDB.deletingLastPathComponent()
        panel.message = "Select original neatdb.sqlite"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let n = try await manager.importLegacyDB(from: url)
                let alert = NSAlert()
                alert.messageText = "Imported \(n) downloads"
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Import failed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func saveClicked() {
        var next = settings
        next.downloadDirectory = URL(fileURLWithPath: dirField.stringValue)
        next.maxConnections = min(32, max(1, Int(connField.stringValue) ?? 8))
        next.bandwidthLimitBytesPerSecond = Int64(bwField.stringValue) ?? 0
        next.useCategoryFolders = categoryCheck.state == .on
        next.downloadAllAtOnce = allAtOnceCheck.state == .on
        next.showCompletionDialog = completeCheck.state == .on
        next.showBrowserMediaPanel = panelCheck.state == .on
        next.confirmBrowserDownloads = confirmCheck.state == .on
        next.useCustomUserAgent = uaCheck.state == .on
        next.customUserAgent = uaField.stringValue.isEmpty ? nil : uaField.stringValue
        let pport = UInt16(proxyPortField.stringValue) ?? 8080
        next.httpProxy = ProxySettings(
            host: proxyHostField.stringValue,
            port: pport,
            username: proxyUserField.stringValue.isEmpty ? nil : proxyUserField.stringValue,
            password: proxyPassField.stringValue.isEmpty ? nil : proxyPassField.stringValue,
            enabled: proxyCheck.state == .on
        )
        next.httpsProxy = next.httpProxy
        let fport = UInt16(ftpPortField.stringValue) ?? 8080
        next.ftpProxy = ProxySettings(
            host: ftpHostField.stringValue,
            port: fport,
            username: ftpUserField.stringValue.isEmpty ? nil : ftpUserField.stringValue,
            password: ftpPassField.stringValue.isEmpty ? nil : ftpPassField.stringValue,
            enabled: ftpProxyCheck.state == .on
        )
        let sport = UInt16(socksPortField.stringValue) ?? 1080
        next.socksProxy = SocksProxySettings(
            host: socksHostField.stringValue,
            port: sport,
            version: socksVersionPopup.indexOfSelectedItem == 1 ? .v4 : .v5,
            username: socksUserField.stringValue.isEmpty ? nil : socksUserField.stringValue,
            password: socksPassField.stringValue.isEmpty ? nil : socksPassField.stringValue,
            enabled: socksCheck.state == .on
        )
        SettingsStore.save(next)
        Task { await manager.updateSettings(next) }
        settings = next
        window?.close()
    }

    @objc private func cancelClicked() {
        window?.close()
    }
}
