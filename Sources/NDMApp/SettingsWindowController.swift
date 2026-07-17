import AppKit
import UniformTypeIdentifiers
import NDMCore
import NDMEngine

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let manager: DownloadManager
    private var settings: AppSettings

    // General
    private let dirField = NSTextField(string: "")
    private let connField = NSTextField(string: "8")
    private let bwField = NSTextField(string: "0")
    private let smartConnCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let clipboardCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let categoryCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let allAtOnceCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let completeCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let appearancePopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    var onWindowClose: (() -> Void)?

    // Browser
    private let panelCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let confirmCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let uaCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let uaField = NSTextField(string: "")

    // Network
    private let proxyCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let proxyHostField = NSTextField(string: "")
    private let proxyPortField = NSTextField(string: "8080")
    private let proxyUserField = NSTextField(string: "")
    private let proxyPassField = NSSecureTextField(string: "")
    private let ftpProxyCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let ftpHostField = NSTextField(string: "")
    private let ftpPortField = NSTextField(string: "8080")
    private let ftpUserField = NSTextField(string: "")
    private let ftpPassField = NSSecureTextField(string: "")
    private let socksCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let socksHostField = NSTextField(string: "")
    private let socksPortField = NSTextField(string: "1080")
    private let socksUserField = NSTextField(string: "")
    private let socksPassField = NSSecureTextField(string: "")
    private let socksVersionPopup = NSPopUpButton()

    init(manager: DownloadManager, settings: AppSettings) {
        self.manager = manager
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.settings
        window.minSize = NSSize(width: 520, height: 420)
        NDMChrome.applyWindowChrome(window)
        super.init(window: window)
        window.delegate = self
        applyLocalizedChrome()
        buildUI()
        loadFields()
        window.center()
    }

    private func applyLocalizedChrome() {
        categoryCheck.title = L10n.organizeCategories
        allAtOnceCheck.title = L10n.downloadAllAtOnce
        completeCheck.title = L10n.showCompletionDialog
        panelCheck.title = L10n.showMediaPanel
        confirmCheck.title = L10n.confirmBrowserCaptures
        uaCheck.title = L10n.useCustomUA
        proxyCheck.title = L10n.httpProxy
        ftpProxyCheck.title = L10n.ftpProxy
        socksCheck.title = L10n.socksProxy
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        socksVersionPopup.removeAllItems()
        socksVersionPopup.addItems(withTitles: ["SOCKS5", "SOCKS4"])

        let tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false

        tabView.addTabViewItem(makeTab(L10n.general, view: makeGeneralPane()))
        tabView.addTabViewItem(makeTab(L10n.browser, view: makeBrowserPane()))
        tabView.addTabViewItem(makeTab(L10n.network, view: makeNetworkPane()))
        tabView.addTabViewItem(makeTab(L10n.advanced, view: makeAdvancedPane()))

        let save = NSButton(title: L10n.save, target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: L10n.cancel, target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(tabView)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            save.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    private func makeTab(_ title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = view
        item.view = scroll
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            view.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            view.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return item
    }

    private func makeGeneralPane() -> NSView {
        let browse = NSButton(title: L10n.choose, target: self, action: #selector(chooseDir))
        browse.bezelStyle = .rounded
        let dirRow = NSStackView(views: [dirField, browse])
        dirRow.orientation = .horizontal
        dirRow.spacing = 8

        appearancePopup.removeAllItems()
        for mode in AppearanceMode.allCases {
            appearancePopup.addItem(withTitle: mode.settingsTitle)
        }
        languagePopup.removeAllItems()
        for mode in AppLanguageMode.allCases {
            languagePopup.addItem(withTitle: mode.settingsTitle)
        }

        return formStack([
            sectionLabel(L10n.language),
            caption(L10n.t("Interface language", "界面语言")),
            languagePopup,
            footnote(L10n.languageFootnote),
            sectionLabel(L10n.appearance),
            caption(L10n.theme),
            appearancePopup,
            footnote(L10n.appearanceFootnote),
            sectionLabel(L10n.downloads),
            caption(L10n.saveFilesTo),
            dirRow,
            caption(L10n.maxConnectionsCaption),
            connField,
            smartConnCheck,
            footnote(L10n.smartConnectionsFootnote),
            caption(L10n.globalSpeedCaption),
            bwField,
            sectionLabel(L10n.behavior),
            categoryCheck,
            allAtOnceCheck,
            completeCheck,
            clipboardCheck,
        ])
    }

    private func makeBrowserPane() -> NSView {
        return formStack([
            sectionLabel("BetterNDM"),
            panelCheck,
            confirmCheck,
            footnote(L10n.confirmBrowserFootnote),
            sectionLabel(L10n.identity),
            uaCheck,
            caption(L10n.userAgentString),
            uaField,
            footnote(L10n.browserSettingsFootnote),
        ])
    }

    private func makeNetworkPane() -> NSView {
        return formStack([
            sectionLabel("HTTP(S)"),
            proxyCheck,
            caption(L10n.host),
            proxyHostField,
            proxyRow(port: proxyPortField, user: proxyUserField, pass: proxyPassField),
            sectionLabel("FTP"),
            ftpProxyCheck,
            caption(L10n.host),
            ftpHostField,
            proxyRow(port: ftpPortField, user: ftpUserField, pass: ftpPassField),
            sectionLabel("SOCKS"),
            socksCheck,
            caption(L10n.host),
            socksHostField,
            proxyRow(port: socksPortField, user: socksUserField, pass: socksPassField),
            caption(L10n.version),
            socksVersionPopup,
        ])
    }

    private func makeAdvancedPane() -> NSView {
        let importLegacy = NSButton(title: L10n.importLegacyDB, target: self, action: #selector(importLegacy))
        importLegacy.bezelStyle = .rounded
        return formStack([
            sectionLabel(L10n.migration),
            footnote(L10n.migrationFootnote),
            importLegacy,
        ])
    }

    private func proxyRow(port: NSTextField, user: NSTextField, pass: NSSecureTextField) -> NSView {
        port.placeholderString = L10n.portPlaceholder
        user.placeholderString = L10n.usernamePlaceholder
        pass.placeholderString = L10n.passwordPlaceholder
        let row = NSStackView(views: [port, user, pass])
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        return row
    }

    private func formStack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        for field in [dirField, uaField, proxyHostField, ftpHostField, socksHostField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        }
        return container
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func footnote(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.preferredMaxLayoutWidth = 480
        return label
    }

    private func loadFields() {
        dirField.stringValue = settings.downloadDirectory.path
        connField.stringValue = "\(settings.maxConnections)"
        smartConnCheck.title = L10n.smartConnectionsTitle
        smartConnCheck.state = settings.smartConnectionsEnabled ? .on : .off
        bwField.stringValue = "\(settings.bandwidthLimitBytesPerSecond)"
        categoryCheck.state = settings.useCategoryFolders ? .on : .off
        allAtOnceCheck.state = settings.downloadAllAtOnce ? .on : .off
        completeCheck.state = settings.showCompletionDialog ? .on : .off
        clipboardCheck.title = L10n.clipboardWatchTitle
        clipboardCheck.state = settings.clipboardWatchEnabled ? .on : .off
        if let index = AppearanceMode.allCases.firstIndex(of: settings.appearanceMode) {
            appearancePopup.selectItem(at: index)
        }
        if let index = AppLanguageMode.allCases.firstIndex(of: settings.languageMode) {
            languagePopup.selectItem(at: index)
        }
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
        panel.message = L10n.selectLegacyDB
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let n = try await manager.importLegacyDB(from: url)
                let alert = NSAlert()
                alert.messageText = L10n.importedCount(n)
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.importFailed
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func saveClicked() {
        var next = settings
        next.downloadDirectory = URL(fileURLWithPath: dirField.stringValue)
        let requestedConnections = min(32, max(1, Int(connField.stringValue) ?? 8))
        let connectionsCap = LicenseStore.connectionsCap(isPro: LicenseStore.isPro)
        if requestedConnections > connectionsCap {
            UpgradeWindowController.present(
                features: [.connections(requested: requestedConnections)],
                parentWindow: window
            ) { [weak self] in
                self?.connField.stringValue = "\(requestedConnections)"
                self?.saveClicked()
            }
            return
        }
        next.maxConnections = min(requestedConnections, connectionsCap)
        next.smartConnections = smartConnCheck.state == .on
        next.bandwidthLimitBytesPerSecond = Int64(bwField.stringValue) ?? 0
        next.useCategoryFolders = categoryCheck.state == .on
        next.downloadAllAtOnce = allAtOnceCheck.state == .on
        next.showCompletionDialog = completeCheck.state == .on
        next.clipboardWatch = clipboardCheck.state == .on
        let appearanceIndex = appearancePopup.indexOfSelectedItem
        if AppearanceMode.allCases.indices.contains(appearanceIndex) {
            next.appearanceMode = AppearanceMode.allCases[appearanceIndex]
        }
        let languageIndex = languagePopup.indexOfSelectedItem
        if AppLanguageMode.allCases.indices.contains(languageIndex) {
            next.languageMode = AppLanguageMode.allCases[languageIndex]
        }
        next.showBrowserMediaPanel = panelCheck.state == .on
        next.confirmBrowserDownloads = confirmCheck.state == .on
        next.useCustomUserAgent = uaCheck.state == .on
        next.customUserAgent = uaField.stringValue.isEmpty ? nil : uaField.stringValue
        AppearanceApplicator.apply(next.appearanceMode)
        L10n.apply(next.languageMode)
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

    func windowWillClose(_ notification: Notification) {
        onWindowClose?()
        onWindowClose = nil
    }
}
