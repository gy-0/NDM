import AppKit
import UniformTypeIdentifiers
import NDMCore
import NDMEngine

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private enum Section: Int, CaseIterable {
        case general
        case downloads
        case browser
        case network
        case advanced

        var title: String {
            switch self {
            case .general: return L10n.general
            case .downloads: return L10n.downloads
            case .browser: return L10n.browser
            case .network: return L10n.network
            case .advanced: return L10n.advanced
            }
        }

        var subtitle: String {
            switch self {
            case .general:
                return L10n.t("Language, appearance, and everyday behavior", "语言、外观与日常行为")
            case .downloads:
                return L10n.t("Where files go and how transfers use the network", "文件保存位置与下载性能")
            case .browser:
                return L10n.t("Optional one-click capture from your browser", "可选的浏览器一键接管")
            case .network:
                return L10n.t("Proxy routes for restricted or managed networks", "受限网络与代理连接")
            case .advanced:
                return L10n.t(
                    "Site compatibility and migration tools",
                    "站点兼容性与迁移工具"
                )
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .downloads: return "arrow.down.circle"
            case .browser: return "globe"
            case .network: return "bolt.horizontal"
            case .advanced: return "gearshape.2"
            }
        }
    }

    private let manager: DownloadManager
    private var settings: AppSettings
    private let siteCompatibilityUpdater: SiteCompatibilityUpdater?
    private var navigationButtons: [Section: SettingsNavigationButton] = [:]
    private var panes: [Section: NSView] = [:]
    private var paneConstraints: [NSLayoutConstraint] = []

    private let contentTitle = NSTextField(labelWithString: "")
    private let contentSubtitle = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()

    // General
    private let appearancePopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    private let categorySwitch = NSSwitch()
    private let allAtOnceSwitch = NSSwitch()
    private let completeSwitch = NSSwitch()
    private let clipboardSwitch = NSSwitch()

    // Downloads
    private let dirField = NSTextField(string: "")
    private let connField = NSTextField(string: "8")
    private let bwField = NSTextField(string: "0")
    private let smartConnSwitch = NSSwitch()

    // Browser
    private let panelSwitch = NSSwitch()
    private let confirmSwitch = NSSwitch()
    private let uaSwitch = NSSwitch()
    private let uaField = NSTextField(string: "")

    // Network
    private let proxySwitch = NSSwitch()
    private let proxyHostField = NSTextField(string: "")
    private let proxyPortField = NSTextField(string: "8080")
    private let proxyUserField = NSTextField(string: "")
    private let proxyPassField = NSSecureTextField(string: "")
    private let ftpProxySwitch = NSSwitch()
    private let ftpHostField = NSTextField(string: "")
    private let ftpPortField = NSTextField(string: "8080")
    private let ftpUserField = NSTextField(string: "")
    private let ftpPassField = NSSecureTextField(string: "")
    private let socksSwitch = NSSwitch()
    private let socksHostField = NSTextField(string: "")
    private let socksPortField = NSTextField(string: "1080")
    private let socksUserField = NSTextField(string: "")
    private let socksPassField = NSSecureTextField(string: "")
    private let socksVersionPopup = NSPopUpButton()

    // Advanced
    private let compatibilityStatusLabel = NSTextField(labelWithString: "")
    private let compatibilityDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let compatibilityButton = NSButton()
    private let compatibilitySpinner = NSProgressIndicator()

    var onWindowClose: (() -> Void)?

    init(
        manager: DownloadManager,
        settings: AppSettings,
        siteCompatibilityUpdater: SiteCompatibilityUpdater? = nil
    ) {
        self.manager = manager
        self.settings = settings
        self.siteCompatibilityUpdater = siteCompatibilityUpdater

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.settings
        window.minSize = NSSize(width: 760, height: 560)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        NDMChrome.applyWindowChrome(window)

        super.init(window: window)
        window.delegate = self
        configureControls()
        buildUI()
        loadFields()
        showSection(.general)
        refreshCompatibilityStatus()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureControls() {
        appearancePopup.removeAllItems()
        AppearanceMode.allCases.forEach { appearancePopup.addItem(withTitle: $0.settingsTitle) }
        languagePopup.removeAllItems()
        AppLanguageMode.allCases.forEach { languagePopup.addItem(withTitle: $0.settingsTitle) }
        socksVersionPopup.removeAllItems()
        socksVersionPopup.addItems(withTitles: ["SOCKS5", "SOCKS4"])

        [appearancePopup, languagePopup, socksVersionPopup].forEach {
            $0.controlSize = .large
            $0.font = .systemFont(ofSize: 13, weight: .medium)
        }

        let regularFields: [NSTextField] = [
            dirField, connField, bwField, uaField,
            proxyHostField, proxyPortField, proxyUserField,
            ftpHostField, ftpPortField, ftpUserField,
            socksHostField, socksPortField, socksUserField,
        ]
        regularFields.forEach(styleField)
        [proxyPassField, ftpPassField, socksPassField].forEach(styleField)

        dirField.isEditable = false
        dirField.isSelectable = true
        dirField.lineBreakMode = .byTruncatingMiddle
        connField.alignment = .right
        bwField.alignment = .right
        proxyPortField.alignment = .right
        ftpPortField.alignment = .right
        socksPortField.alignment = .right

        proxyPortField.placeholderString = L10n.portPlaceholder
        ftpPortField.placeholderString = L10n.portPlaceholder
        socksPortField.placeholderString = L10n.portPlaceholder
        proxyUserField.placeholderString = L10n.usernamePlaceholder
        ftpUserField.placeholderString = L10n.usernamePlaceholder
        socksUserField.placeholderString = L10n.usernamePlaceholder
        proxyPassField.placeholderString = L10n.passwordPlaceholder
        ftpPassField.placeholderString = L10n.passwordPlaceholder
        socksPassField.placeholderString = L10n.passwordPlaceholder
        uaField.placeholderString = L10n.userAgentString

        proxySwitch.target = self
        proxySwitch.action = #selector(proxyStateChanged)
        ftpProxySwitch.target = self
        ftpProxySwitch.action = #selector(proxyStateChanged)
        socksSwitch.target = self
        socksSwitch.action = #selector(proxyStateChanged)
        uaSwitch.target = self
        uaSwitch.action = #selector(browserIdentityStateChanged)

        compatibilityStatusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        compatibilityStatusLabel.textColor = .labelColor
        compatibilityStatusLabel.alignment = .right
        compatibilityDetailLabel.font = .systemFont(ofSize: 11.5)
        compatibilityDetailLabel.textColor = .secondaryLabelColor
        compatibilityDetailLabel.alignment = .right
        compatibilityDetailLabel.maximumNumberOfLines = 2
        compatibilityDetailLabel.preferredMaxLayoutWidth = 260
        compatibilityButton.title = L10n.t("Check now", "立即检查")
        compatibilityButton.target = self
        compatibilityButton.action = #selector(checkCompatibilityNow)
        compatibilityButton.controlSize = .large
        NDMChrome.styleGhostButton(compatibilityButton)
        compatibilitySpinner.style = .spinning
        compatibilitySpinner.controlSize = .small
        compatibilitySpinner.isDisplayedWhenStopped = false
    }

    private func styleField(_ field: NSTextField) {
        field.controlSize = .large
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let sidebar = ChromeBox(fill: NDMChrome.sidebarFill)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.setContentHuggingPriority(.required, for: .horizontal)
        sidebar.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Match System Settings: section label lines up with row titles (after icon).
        let sidebarTitle = NSTextField(labelWithString: L10n.settings)
        sidebarTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        sidebarTitle.textColor = .tertiaryLabelColor
        sidebarTitle.alignment = .left
        sidebarTitle.translatesAutoresizingMaskIntoConstraints = false

        // NSStackView kept fighting the full-rail buttons (ambiguous/zero
        // heights collapsed every row onto the same line). Lay the rows out
        // by hand instead: each row is a fixed 32pt band pinned top-to-bottom.
        let navigation = NSView()
        navigation.translatesAutoresizingMaskIntoConstraints = false
        var previousButton: SettingsNavigationButton?
        for section in Section.allCases {
            let button = SettingsNavigationButton(
                title: section.title,
                symbolName: section.symbolName,
                tag: section.rawValue,
                target: self,
                action: #selector(navigationClicked(_:))
            )
            navigationButtons[section] = button
            navigation.addSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: navigation.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: navigation.trailingAnchor),
                button.heightAnchor.constraint(equalToConstant: 32),
                button.topAnchor.constraint(
                    equalTo: previousButton?.bottomAnchor ?? navigation.topAnchor,
                    constant: previousButton == nil ? 0 : 1
                ),
            ])
            previousButton = button
        }
        // Closes the chain so `navigation`'s height is fully determined by
        // its rows (it has no intrinsic size of its own).
        previousButton?.bottomAnchor.constraint(equalTo: navigation.bottomAnchor).isActive = true

        sidebar.addSubview(sidebarTitle)
        sidebar.addSubview(navigation)

        let contentSurface = ChromeBox(fill: NDMChrome.contentSurface)
        contentSurface.translatesAutoresizingMaskIntoConstraints = false

        contentTitle.font = .systemFont(ofSize: 24, weight: .bold)
        contentTitle.textColor = .labelColor
        contentSubtitle.font = .systemFont(ofSize: 13)
        contentSubtitle.textColor = .secondaryLabelColor
        contentSubtitle.maximumNumberOfLines = 2

        let heading = NSStackView(views: [contentTitle, contentSubtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        heading.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: L10n.save, target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        save.controlSize = .large
        NDMChrome.styleMainButton(save)

        let cancel = NSButton(title: L10n.cancel, target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        cancel.controlSize = .large
        NDMChrome.styleGhostButton(cancel)

        let footerHint = NSTextField(labelWithString: L10n.t(
            "Changes apply to new and active downloads when saved.",
            "保存后将应用到新任务和正在进行的任务。"
        ))
        footerHint.font = .systemFont(ofSize: 11.5)
        footerHint.textColor = .tertiaryLabelColor
        footerHint.lineBreakMode = .byTruncatingTail

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [footerHint, footerSpacer, cancel, save])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let footerHairline = ChromeBox(fill: NDMChrome.hairline)
        footerHairline.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(sidebar)
        content.addSubview(contentSurface)
        contentSurface.addSubview(heading)
        contentSurface.addSubview(scrollView)
        contentSurface.addSubview(footerHairline)
        contentSurface.addSubview(footer)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 168),

            // Title aligns with row labels (icon 16 + gap 8 + row inset 8 = 32).
            sidebarTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 48),
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 32),
            sidebarTitle.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            navigation.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 8),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),

            contentSurface.topAnchor.constraint(equalTo: content.topAnchor),
            contentSurface.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentSurface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentSurface.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            heading.topAnchor.constraint(equalTo: contentSurface.safeAreaLayoutGuide.topAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: contentSurface.leadingAnchor, constant: 28),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: contentSurface.trailingAnchor, constant: -28),

            scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: contentSurface.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: contentSurface.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: footerHairline.topAnchor),

            footerHairline.leadingAnchor.constraint(equalTo: contentSurface.leadingAnchor),
            footerHairline.trailingAnchor.constraint(equalTo: contentSurface.trailingAnchor),
            footerHairline.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -13),
            footerHairline.heightAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: contentSurface.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: contentSurface.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: contentSurface.bottomAnchor, constant: -16),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            save.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
        ])

        panes[.general] = makeGeneralPane()
        panes[.downloads] = makeDownloadsPane()
        panes[.browser] = makeBrowserPane()
        panes[.network] = makeNetworkPane()
        panes[.advanced] = makeAdvancedPane()
    }

    @objc private func navigationClicked(_ sender: Any?) {
        let tag = (sender as? NSControl)?.tag ?? -1
        guard let section = Section(rawValue: tag) else { return }
        showSection(section)
    }

    private func showSection(_ section: Section) {
        contentTitle.stringValue = section.title
        contentSubtitle.stringValue = section.subtitle
        for (candidate, button) in navigationButtons {
            button.isSelected = candidate == section
        }

        guard let pane = panes[section] else { return }
        NSLayoutConstraint.deactivate(paneConstraints)
        scrollView.documentView = pane
        pane.translatesAutoresizingMaskIntoConstraints = false
        paneConstraints = [
            pane.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            pane.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ]
        NSLayoutConstraint.activate(paneConstraints)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func makeGeneralPane() -> NSView {
        let interfaceCard = makeCard(
            title: L10n.t("Interface", "界面"),
            subtitle: nil,
            symbolName: "macwindow",
            rows: [
                settingsRow(
                    title: L10n.language,
                    detail: L10n.languageFootnote,
                    control: fixedWidth(languagePopup, 190)
                ),
                settingsRow(
                    title: L10n.appearance,
                    detail: L10n.appearanceFootnote,
                    control: fixedWidth(appearancePopup, 190)
                ),
            ]
        )

        let behaviorCard = makeCard(
            title: L10n.behavior,
            subtitle: nil,
            symbolName: "switch.2",
            rows: [
                toggleRow(title: L10n.organizeCategories, detail: L10n.t(
                    "Create Video, Audio, Documents, and other folders automatically.",
                    "自动建立视频、音频、文档等分类文件夹。"
                ), toggle: categorySwitch),
                toggleRow(title: L10n.downloadAllAtOnce, detail: nil, toggle: allAtOnceSwitch),
                toggleRow(title: L10n.showCompletionDialog, detail: nil, toggle: completeSwitch),
                toggleRow(title: L10n.clipboardWatchTitle, detail: L10n.t(
                    "Prompt only when NDM becomes active; never auto-start.",
                    "仅在切回 NDM 时提示，不会自动开始下载。"
                ), toggle: clipboardSwitch),
            ]
        )
        return paneStack([interfaceCard, behaviorCard])
    }

    private func makeDownloadsPane() -> NSView {
        let choose = NSButton(title: L10n.choose, target: self, action: #selector(chooseDir))
        choose.controlSize = .large
        NDMChrome.styleGhostButton(choose)
        let destinationControl = NSStackView(views: [dirField, choose])
        destinationControl.orientation = .horizontal
        destinationControl.alignment = .centerY
        destinationControl.spacing = 8
        dirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true

        let destinationCard = makeCard(
            title: L10n.t("Destination", "保存位置"),
            subtitle: nil,
            symbolName: "folder",
            rows: [
                settingsRow(title: L10n.saveFilesTo, detail: nil, control: destinationControl),
            ]
        )

        connField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        bwField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let performanceCard = makeCard(
            title: L10n.t("Performance", "下载性能"),
            subtitle: nil,
            symbolName: "speedometer",
            rows: [
                settingsRow(
                    title: L10n.maxConnectionsCaption,
                    detail: L10n.t("Upper limit — not a forced connection count.", "上限，不是始终强制使用的连接数。"),
                    control: connField
                ),
                toggleRow(
                    title: L10n.smartConnectionsTitle,
                    detail: L10n.smartConnectionsFootnote,
                    toggle: smartConnSwitch
                ),
                settingsRow(
                    title: L10n.globalSpeedCaption,
                    detail: L10n.t("Enter 0 for unlimited.", "输入 0 表示不限速。"),
                    control: bwField
                ),
            ]
        )
        return paneStack([destinationCard, performanceCard])
    }

    private func makeBrowserPane() -> NSView {
        let captureCard = makeCard(
            title: L10n.t("Browser capture", "浏览器接管"),
            subtitle: nil,
            symbolName: "globe",
            rows: [
                toggleRow(title: L10n.showMediaPanel, detail: nil, toggle: panelSwitch),
                toggleRow(title: L10n.confirmBrowserCaptures, detail: L10n.confirmBrowserFootnote, toggle: confirmSwitch),
            ]
        )

        uaField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let identityCard = makeCard(
            title: L10n.identity,
            subtitle: nil,
            symbolName: "person.text.rectangle",
            rows: [
                toggleRow(title: L10n.useCustomUA, detail: L10n.t(
                    "Override the browser User-Agent string.",
                    "覆盖浏览器的 User-Agent。"
                ), toggle: uaSwitch),
                settingsRow(title: L10n.userAgentString, detail: nil, control: uaField),
            ]
        )
        return paneStack([captureCard, identityCard])
    }

    private func makeNetworkPane() -> NSView {
        let http = makeProxyCard(
            title: "HTTP(S)",
            subtitle: L10n.t("For web and direct-file downloads.", "用于网页与直链下载。"),
            toggleTitle: L10n.httpProxy,
            toggle: proxySwitch,
            host: proxyHostField,
            port: proxyPortField,
            user: proxyUserField,
            pass: proxyPassField
        )
        let ftp = makeProxyCard(
            title: "FTP",
            subtitle: L10n.t("HTTP CONNECT proxy for FTP transfers.", "用于 FTP 传输的 HTTP CONNECT 代理。"),
            toggleTitle: L10n.ftpProxy,
            toggle: ftpProxySwitch,
            host: ftpHostField,
            port: ftpPortField,
            user: ftpUserField,
            pass: ftpPassField
        )

        socksVersionPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let socks = makeCard(
            title: "SOCKS",
            subtitle: L10n.t("Takes priority over the HTTP proxy when enabled.", "启用后优先于 HTTP 代理。"),
            symbolName: "point.3.connected.trianglepath.dotted",
            rows: [
                toggleRow(title: L10n.socksProxy, detail: nil, toggle: socksSwitch),
                endpointRow(host: socksHostField, port: socksPortField),
                credentialsRow(user: socksUserField, pass: socksPassField),
                settingsRow(title: L10n.version, detail: nil, control: socksVersionPopup),
            ]
        )
        return paneStack([http, ftp, socks])
    }

    private func makeAdvancedPane() -> NSView {
        let statusStack = NSStackView(views: [compatibilityStatusLabel, compatibilityDetailLabel])
        statusStack.orientation = .vertical
        statusStack.alignment = .trailing
        statusStack.spacing = 2

        let updateControls = NSStackView(views: [compatibilitySpinner, compatibilityButton])
        updateControls.orientation = .horizontal
        updateControls.alignment = .centerY
        updateControls.spacing = 8

        let compatibilityCard = makeCard(
            title: L10n.t("Site compatibility", "站点兼容性"),
            subtitle: nil,
            symbolName: "checkmark.shield",
            rows: [
                settingsRow(
                    title: L10n.t("Current status", "当前状态"),
                    detail: nil,
                    control: statusStack
                ),
                settingsRow(
                    title: L10n.t("Compatibility updates", "兼容性更新"),
                    detail: L10n.t(
                        "Only NDM-reviewed and signed updates are accepted.",
                        "只接受经 NDM 审核并签名的更新。"
                    ),
                    control: updateControls
                ),
            ]
        )

        let importLegacy = NSButton(title: L10n.importLegacyDB, target: self, action: #selector(importLegacy))
        importLegacy.controlSize = .large
        NDMChrome.styleGhostButton(importLegacy)
        let migrationCard = makeCard(
            title: L10n.migration,
            subtitle: nil,
            symbolName: "externaldrive.badge.plus",
            rows: [
                settingsRow(
                    title: L10n.t("Existing download library", "已有下载资料"),
                    detail: L10n.t(
                        "Imports a copy; the original database is left untouched.",
                        "导入副本，不改动原数据库。"
                    ),
                    control: importLegacy
                ),
            ]
        )
        return paneStack([compatibilityCard, migrationCard])
    }

    private func refreshCompatibilityStatus() {
        guard let updater = siteCompatibilityUpdater else {
            compatibilityStatusLabel.stringValue = L10n.t("Built in and ready", "已内置，可直接使用")
            compatibilityDetailLabel.stringValue = L10n.t(
                "Compatibility improvements arrive with NDM updates.",
                "兼容性改进会随 NDM 更新一起提供。"
            )
            compatibilityButton.isHidden = true
            return
        }
        Task { [weak self] in
            let snapshot = await updater.snapshot()
            self?.applyCompatibilitySnapshot(snapshot)
        }
    }

    private func applyCompatibilitySnapshot(_ snapshot: SiteCompatibilitySnapshot) {
        compatibilitySpinner.stopAnimation(nil)
        compatibilityButton.isEnabled = true
        compatibilityButton.isHidden = siteCompatibilityUpdater == nil

        let version = snapshot.version.map {
            L10n.t("Version \($0)", "版本 \($0)")
        } ?? L10n.t("Built-in support", "内置支持")
        switch snapshot.phase {
        case .ready:
            compatibilityStatusLabel.stringValue = snapshot.source == .refreshed
                ? L10n.t("Up to date", "已是最新")
                : L10n.t("Built in and ready", "已内置，可直接使用")
            compatibilityDetailLabel.stringValue = version
        case .checking:
            compatibilityStatusLabel.stringValue = L10n.t("Checking…", "正在检查…")
            compatibilityDetailLabel.stringValue = version
            compatibilityButton.isEnabled = false
            compatibilitySpinner.startAnimation(nil)
        case .installing:
            compatibilityStatusLabel.stringValue = L10n.t("Refreshing support…", "正在更新站点支持…")
            compatibilityDetailLabel.stringValue = snapshot.availableVersion.map {
                L10n.t("Preparing version \($0)", "正在准备版本 \($0)")
            } ?? version
            compatibilityButton.isEnabled = false
            compatibilitySpinner.startAnimation(nil)
        case .requiresAppUpdate:
            compatibilityStatusLabel.stringValue = L10n.t("NDM update required", "需要更新 NDM")
            compatibilityDetailLabel.stringValue = L10n.t(
                "A newer app version is needed for the latest site support.",
                "最新版站点支持需要更新的软件版本。"
            )
        case .failed:
            compatibilityStatusLabel.stringValue = L10n.t("Couldn’t check right now", "暂时无法检查")
            compatibilityDetailLabel.stringValue = L10n.t(
                "Built-in support is still active. Try again later.",
                "内置支持仍然可用，可稍后重试。"
            )
        }
    }

    @objc private func checkCompatibilityNow() {
        guard let updater = siteCompatibilityUpdater else { return }
        compatibilityStatusLabel.stringValue = L10n.t("Checking…", "正在检查…")
        compatibilityDetailLabel.stringValue = L10n.t(
            "Looking for reviewed site fixes.",
            "正在查找经过审核的站点修复。"
        )
        compatibilityButton.isEnabled = false
        compatibilitySpinner.startAnimation(nil)
        Task { [weak self] in
            let snapshot = await updater.checkAndInstall()
            self?.applyCompatibilitySnapshot(snapshot)
        }
    }

    private func makeProxyCard(
        title: String,
        subtitle: String?,
        toggleTitle: String,
        toggle: NSSwitch,
        host: NSTextField,
        port: NSTextField,
        user: NSTextField,
        pass: NSSecureTextField
    ) -> NSView {
        makeCard(
            title: title,
            subtitle: subtitle,
            symbolName: "network",
            rows: [
                toggleRow(title: toggleTitle, detail: nil, toggle: toggle),
                endpointRow(host: host, port: port),
                credentialsRow(user: user, pass: pass),
            ]
        )
    }

    private func endpointRow(host: NSTextField, port: NSTextField) -> NSView {
        host.placeholderString = L10n.host
        port.placeholderString = L10n.portPlaceholder
        host.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        port.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let controls = NSStackView(views: [host, port])
        controls.orientation = .horizontal
        controls.spacing = 8
        return settingsRow(
            title: L10n.t("Server", "服务器"),
            detail: L10n.t("Host name and port", "主机名与端口"),
            control: controls
        )
    }

    private func credentialsRow(user: NSTextField, pass: NSSecureTextField) -> NSView {
        user.widthAnchor.constraint(greaterThanOrEqualToConstant: 145).isActive = true
        pass.widthAnchor.constraint(greaterThanOrEqualToConstant: 145).isActive = true
        let controls = NSStackView(views: [user, pass])
        controls.orientation = .horizontal
        controls.spacing = 8
        return settingsRow(
            title: L10n.t("Authentication", "身份验证"),
            detail: L10n.t("Optional username and password", "可选的用户名与密码"),
            control: controls
        )
    }

    private func paneStack(_ cards: [NSView]) -> NSView {
        let container = NSView()
        var previous: NSView?
        for card in cards {
            card.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(card)
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                card.topAnchor.constraint(
                    equalTo: previous?.bottomAnchor ?? container.topAnchor,
                    constant: previous == nil ? 0 : 16
                ),
            ])
            previous = card
        }
        if let previous {
            previous.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24).isActive = true
        } else {
            container.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        return container
    }

    private func makeCard(
        title: String,
        subtitle: String?,
        symbolName: String,
        rows: [NSView]
    ) -> NSView {
        let card = ChromeBox(
            fill: NDMChrome.searchSurface,
            borderColor: NDMChrome.hairline,
            cornerRadius: 14,
            borderWidth: 1
        )
        card.translatesAutoresizingMaskIntoConstraints = false

        let iconBox = ChromeBox(fill: NDMChrome.rowActive, cornerRadius: 10)
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = NDMChrome.symbol(symbolName, pointSize: 16, weight: .semibold)
        icon.contentTintColor = NDMChrome.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 36),
            iconBox.heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
        ])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        let labelViews: [NSView]
        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11.5)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.maximumNumberOfLines = 2
            labelViews = [titleLabel, subtitleLabel]
        } else {
            labelViews = [titleLabel]
        }
        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let header = NSStackView(views: [iconBox, labels])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 11
        header.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.setCustomSpacing(13, after: header)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = divider()
                content.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    private func settingsRow(title: String, detail: String?, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor

        var labelViews: [NSView] = [titleLabel]
        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 11.5)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.maximumNumberOfLines = 3
            detailLabel.preferredMaxLayoutWidth = 310
            labelViews.append(detailLabel)
        }
        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [labels, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        return row
    }

    private func toggleRow(title: String, detail: String?, toggle: NSSwitch) -> NSView {
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        return settingsRow(title: title, detail: detail, control: toggle)
    }

    private func fixedWidth(_ view: NSView, _ width: CGFloat) -> NSView {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    private func divider() -> NSView {
        let line = ChromeBox(fill: NDMChrome.hairline)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func loadFields() {
        dirField.stringValue = settings.downloadDirectory.path
        connField.stringValue = "\(settings.maxConnections)"
        smartConnSwitch.state = settings.smartConnectionsEnabled ? .on : .off
        bwField.stringValue = "\(settings.bandwidthLimitBytesPerSecond)"
        categorySwitch.state = settings.useCategoryFolders ? .on : .off
        allAtOnceSwitch.state = settings.downloadAllAtOnce ? .on : .off
        completeSwitch.state = settings.showCompletionDialog ? .on : .off
        clipboardSwitch.state = settings.clipboardWatchEnabled ? .on : .off

        if let index = AppearanceMode.allCases.firstIndex(of: settings.appearanceMode) {
            appearancePopup.selectItem(at: index)
        }
        if let index = AppLanguageMode.allCases.firstIndex(of: settings.languageMode) {
            languagePopup.selectItem(at: index)
        }

        panelSwitch.state = settings.showBrowserMediaPanel ? .on : .off
        confirmSwitch.state = settings.confirmBrowserDownloads ? .on : .off
        uaSwitch.state = settings.useCustomUserAgent ? .on : .off
        uaField.stringValue = settings.customUserAgent ?? ""

        proxySwitch.state = settings.httpProxy?.enabled == true ? .on : .off
        proxyHostField.stringValue = settings.httpProxy?.host ?? ""
        proxyPortField.stringValue = "\(settings.httpProxy?.port ?? 8080)"
        proxyUserField.stringValue = settings.httpProxy?.username ?? ""
        proxyPassField.stringValue = settings.httpProxy?.password ?? ""

        ftpProxySwitch.state = settings.ftpProxy?.enabled == true ? .on : .off
        ftpHostField.stringValue = settings.ftpProxy?.host ?? ""
        ftpPortField.stringValue = "\(settings.ftpProxy?.port ?? 8080)"
        ftpUserField.stringValue = settings.ftpProxy?.username ?? ""
        ftpPassField.stringValue = settings.ftpProxy?.password ?? ""

        socksSwitch.state = settings.socksProxy?.enabled == true ? .on : .off
        socksHostField.stringValue = settings.socksProxy?.host ?? ""
        socksPortField.stringValue = "\(settings.socksProxy?.port ?? 1080)"
        socksUserField.stringValue = settings.socksProxy?.username ?? ""
        socksPassField.stringValue = settings.socksProxy?.password ?? ""
        socksVersionPopup.selectItem(at: settings.socksProxy?.version == .v4 ? 1 : 0)
        updateEnabledStates()
    }

    @objc private func proxyStateChanged() {
        updateEnabledStates()
    }

    @objc private func browserIdentityStateChanged() {
        updateEnabledStates()
    }

    private func updateEnabledStates() {
        setEnabled(proxySwitch.state == .on, controls: [
            proxyHostField, proxyPortField, proxyUserField, proxyPassField,
        ])
        setEnabled(ftpProxySwitch.state == .on, controls: [
            ftpHostField, ftpPortField, ftpUserField, ftpPassField,
        ])
        setEnabled(socksSwitch.state == .on, controls: [
            socksHostField, socksPortField, socksUserField, socksPassField, socksVersionPopup,
        ])
        uaField.isEnabled = uaSwitch.state == .on
    }

    private func setEnabled(_ enabled: Bool, controls: [NSControl]) {
        controls.forEach { $0.isEnabled = enabled }
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
        next.smartConnections = smartConnSwitch.state == .on
        next.bandwidthLimitBytesPerSecond = Int64(bwField.stringValue) ?? 0
        next.useCategoryFolders = categorySwitch.state == .on
        next.downloadAllAtOnce = allAtOnceSwitch.state == .on
        next.showCompletionDialog = completeSwitch.state == .on
        next.clipboardWatch = clipboardSwitch.state == .on

        let appearanceIndex = appearancePopup.indexOfSelectedItem
        if AppearanceMode.allCases.indices.contains(appearanceIndex) {
            next.appearanceMode = AppearanceMode.allCases[appearanceIndex]
        }
        let languageIndex = languagePopup.indexOfSelectedItem
        if AppLanguageMode.allCases.indices.contains(languageIndex) {
            next.languageMode = AppLanguageMode.allCases[languageIndex]
        }

        next.showBrowserMediaPanel = panelSwitch.state == .on
        next.confirmBrowserDownloads = confirmSwitch.state == .on
        next.useCustomUserAgent = uaSwitch.state == .on
        next.customUserAgent = uaField.stringValue.isEmpty ? nil : uaField.stringValue
        AppearanceApplicator.apply(next.appearanceMode)
        L10n.apply(next.languageMode)

        let pport = UInt16(proxyPortField.stringValue) ?? 8080
        next.httpProxy = ProxySettings(
            host: proxyHostField.stringValue,
            port: pport,
            username: proxyUserField.stringValue.isEmpty ? nil : proxyUserField.stringValue,
            password: proxyPassField.stringValue.isEmpty ? nil : proxyPassField.stringValue,
            enabled: proxySwitch.state == .on
        )
        next.httpsProxy = next.httpProxy

        let fport = UInt16(ftpPortField.stringValue) ?? 8080
        next.ftpProxy = ProxySettings(
            host: ftpHostField.stringValue,
            port: fport,
            username: ftpUserField.stringValue.isEmpty ? nil : ftpUserField.stringValue,
            password: ftpPassField.stringValue.isEmpty ? nil : ftpPassField.stringValue,
            enabled: ftpProxySwitch.state == .on
        )

        let sport = UInt16(socksPortField.stringValue) ?? 1080
        next.socksProxy = SocksProxySettings(
            host: socksHostField.stringValue,
            port: sport,
            version: socksVersionPopup.indexOfSelectedItem == 1 ? .v4 : .v5,
            username: socksUserField.stringValue.isEmpty ? nil : socksUserField.stringValue,
            password: socksPassField.stringValue.isEmpty ? nil : socksPassField.stringValue,
            enabled: socksSwitch.state == .on
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

/// Full-rail sidebar row — selection paints `bounds`, label stays leading.
private final class SettingsNavigationButton: NSControl {
    private let symbolName: String
    private let titleText: String
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    var isSelected = false {
        didSet {
            updateVisualState()
            needsDisplay = true
        }
    }

    override var tag: Int {
        get { storedTag }
        set { storedTag = newValue }
    }
    private var storedTag = 0

    init(
        title: String,
        symbolName: String,
        tag: Int,
        target: AnyObject?,
        action: Selector?
    ) {
        self.symbolName = symbolName
        self.titleText = title
        super.init(frame: .zero)
        self.storedTag = tag
        self.target = target
        self.action = action

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = titleText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isSelectable = false

        addSubview(iconView)
        addSubview(titleLabel)
        // Height is owned by the sidebar layout (32pt bands); don't pin here.
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        updateVisualState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected ? NDMChrome.rowActive : NSColor.clear).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func updateVisualState() {
        let tint: NSColor = isSelected ? NDMChrome.accent : .labelColor
        let weight: NSFont.Weight = isSelected ? .semibold : .regular
        iconView.image = NDMChrome.symbol(symbolName, pointSize: 13, weight: weight)
        iconView.contentTintColor = isSelected ? NDMChrome.accent : .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 13, weight: weight)
        titleLabel.textColor = tint
    }
}
