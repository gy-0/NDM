import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import NDMCore
import NDMEngine

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private enum Section: Int, CaseIterable {
        case general
        case appearance
        case downloads
        case browser
        case network
        case advanced

        var title: String {
            switch self {
            case .general: return L10n.general
            case .appearance: return L10n.appearance
            case .downloads: return L10n.downloads
            case .browser: return L10n.browser
            case .network: return L10n.network
            case .advanced: return L10n.advanced
            }
        }

        var subtitle: String {
            switch self {
            case .general:
                return L10n.t("Language and app behavior", "语言与软件行为")
            case .appearance:
                return L10n.t("Theme and color", "主题与颜色")
            case .downloads:
                return L10n.t("Files and transfer limits", "文件与传输限制")
            case .browser:
                return L10n.t("Browser integration", "浏览器集成")
            case .network:
                return L10n.t("Proxy settings", "代理设置")
            case .advanced:
                return L10n.t("Compatibility and data", "兼容性与数据")
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .appearance: return "paintpalette"
            case .downloads: return "arrow.down.circle"
            // Browser integration is an extension bridge, not "the web" — the
            // globe was also the card icon inside this very pane, reading as a
            // duplicate. A puzzle piece says "extension" unambiguously.
            case .browser: return "puzzlepiece.extension.fill"
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
    private var currentSection: Section = .general
    private let sidebarTitle = NSTextField(labelWithString: L10n.settings)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)

    private let contentTitle = NSTextField(labelWithString: "")
    private let contentSubtitle = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let footerHint = NSTextField(labelWithString: "")

    // General
    private let appearancePopup = SettingsPopupButton()
    private let accentPopup = SettingsPopupButton()
    private let customAccentColorWell = NSColorWell()
    private let languagePopup = SettingsPopupButton()
    private let categorySwitch = SettingsAccentSwitch()
    private let allAtOnceSwitch = SettingsAccentSwitch()
    private let completeSwitch = SettingsAccentSwitch()
    private let clipboardSwitch = SettingsAccentSwitch()
    private let launchAtLoginSwitch = SettingsAccentSwitch()

    // Downloads
    private let dirField = NSTextField(string: "")
    private let connField = NSTextField(string: "8")
    private let bwField = NSTextField(string: "5")
    private let speedLimitPopup = SettingsPopupButton()
    private let speedLimitCustomStack = NSStackView()
    private let speedLimitControl = NSStackView()
    private let speedLimitUnitLabel = NSTextField(labelWithString: "MB/s")
    private let smartConnSwitch = SettingsAccentSwitch()
    private let mediaQualityPopup = SettingsPopupButton()
    private let quickActionsListStack = NSStackView()
    private var draftQuickActions: [QuickAction]
    private var quickActionsWidthConstraints: [NSLayoutConstraint] = []

    private static let speedLimitPresets: [Int64] = [
        0, 1_000_000, 5_000_000, 10_000_000, 50_000_000,
    ]
    private static let customSpeedLimitTag = -1

    // Browser
    private let panelSwitch = SettingsAccentSwitch()
    private let confirmSwitch = SettingsAccentSwitch()
    private let uaSwitch = SettingsAccentSwitch()
    private let uaField = NSTextField(string: "")

    // Network
    private let proxySwitch = SettingsAccentSwitch()
    private let proxyHostField = NSTextField(string: "")
    private let proxyPortField = NSTextField(string: "8080")
    private let proxyUserField = NSTextField(string: "")
    private let proxyPassField = NSSecureTextField(string: "")
    private let ftpProxySwitch = SettingsAccentSwitch()
    private let ftpHostField = NSTextField(string: "")
    private let ftpPortField = NSTextField(string: "8080")
    private let ftpUserField = NSTextField(string: "")
    private let ftpPassField = NSSecureTextField(string: "")
    private let socksSwitch = SettingsAccentSwitch()
    private let socksHostField = NSTextField(string: "")
    private let socksPortField = NSTextField(string: "1080")
    private let socksUserField = NSTextField(string: "")
    private let socksPassField = NSSecureTextField(string: "")
    private let socksVersionPopup = SettingsPopupButton()

    // Advanced
    private let compatibilityStatusLabel = NSTextField(labelWithString: "")
    private let compatibilityDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let compatibilityButton = NSButton()
    private let compatibilitySpinner = NSProgressIndicator()

    private struct ValidationIssue {
        let field: NSTextField?
        let message: String
    }

    var onWindowClose: (() -> Void)?

    init(
        manager: DownloadManager,
        settings: AppSettings,
        siteCompatibilityUpdater: SiteCompatibilityUpdater? = nil,
        initialSectionName: String? = nil
    ) {
        self.manager = manager
        self.settings = settings
        self.draftQuickActions = settings.completionQuickActions
        self.siteCompatibilityUpdater = siteCompatibilityUpdater

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.settings
        window.minSize = NSSize(width: 820, height: 600)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        NDMChrome.applyWindowChrome(window)

        super.init(window: window)
        window.delegate = self
        configureControls()
        buildUI()
        loadFields()
        showSection(Self.section(named: initialSectionName) ?? .general)
        if QAPreviewOverrides.showQuickActions {
            DispatchQueue.main.async { [weak self] in
                self?.scrollToQuickActionsForQA()
            }
        }
        refreshCompatibilityStatus()
        window.center()

        // Language applies live from the appearance pane — relocalize the whole
        // settings window in place so it isn't left half-English.
        NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relocalizeContent() }
        }
    }

    /// Rebuild every localized string in place after a live language switch.
    private func relocalizeContent() {
        window?.title = L10n.settings
        sidebarTitle.stringValue = L10n.settings
        saveButton.title = L10n.save
        cancelButton.title = L10n.cancel
        footerHint.stringValue = defaultFooterHint
        reloadSpeedLimitPopupTitles()
        for (section, button) in navigationButtons {
            button.updateTitle(section.title)
        }
        // Rebuild the panes so their inline row/card labels pick up the new
        // language; shared controls keep their state, and re-showing restores
        // the current section and its heading text.
        panes[.general] = makeGeneralPane()
        panes[.appearance] = makeAppearancePane()
        panes[.downloads] = makeDownloadsPane()
        panes[.browser] = makeBrowserPane()
        panes[.network] = makeNetworkPane()
        panes[.advanced] = makeAdvancedPane()
        loadFields()
        showSection(currentSection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func section(named name: String?) -> Section? {
        switch name?.lowercased() {
        case "general": return .general
        case "appearance": return .appearance
        case "downloads": return .downloads
        case "browser": return .browser
        case "network": return .network
        case "advanced": return .advanced
        default: return nil
        }
    }

    private func configureControls() {
        appearancePopup.removeAllItems()
        AppearanceMode.allCases.forEach { appearancePopup.addItem(withTitle: $0.settingsTitle) }
        accentPopup.removeAllItems()
        for theme in AccentTheme.allCases {
            accentPopup.addItem(withTitle: theme.settingsTitle)
            accentPopup.lastItem?.image = Self.accentSwatch(
                color: NDMChrome.accent(for: theme, customHex: settings.customAccentHex)
            )
        }
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceSelectionChanged)
        accentPopup.target = self
        accentPopup.action = #selector(accentSelectionChanged)
        // The well is now an off-screen holder for the chosen custom color;
        // the visible interaction is the system color panel (see
        // openCustomAccentPanel). No target/action or layout needed.
        customAccentColorWell.setAccessibilityLabel(L10n.t("Custom accent color", "自定义强调色"))
        languagePopup.removeAllItems()
        AppLanguageMode.allCases.forEach { languagePopup.addItem(withTitle: $0.settingsTitle) }
        languagePopup.target = self
        languagePopup.action = #selector(languageSelectionChanged)

        mediaQualityPopup.removeAllItems()
        MediaQualityPreference.presetCases.forEach {
            mediaQualityPopup.addItem(withTitle: $0.settingsTitle)
        }
        socksVersionPopup.removeAllItems()
        socksVersionPopup.addItems(withTitles: ["SOCKS5", "SOCKS4"])

        reloadSpeedLimitPopupTitles()
        speedLimitPopup.target = self
        speedLimitPopup.action = #selector(speedLimitSelectionChanged)
        speedLimitPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        speedLimitUnitLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        speedLimitUnitLabel.textColor = .secondaryLabelColor
        speedLimitCustomStack.orientation = .horizontal
        speedLimitCustomStack.alignment = .centerY
        speedLimitCustomStack.spacing = 6
        speedLimitCustomStack.addArrangedSubview(bwField)
        speedLimitCustomStack.addArrangedSubview(speedLimitUnitLabel)
        speedLimitControl.orientation = .horizontal
        speedLimitControl.alignment = .centerY
        speedLimitControl.spacing = 8
        speedLimitControl.addArrangedSubview(speedLimitPopup)
        speedLimitControl.addArrangedSubview(speedLimitCustomStack)

        [appearancePopup, accentPopup, languagePopup, socksVersionPopup].forEach {
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
        (regularFields + [proxyPassField, ftpPassField, socksPassField]).forEach {
            $0.delegate = self
        }

        dirField.isEditable = false
        dirField.isSelectable = true
        dirField.lineBreakMode = .byTruncatingMiddle
        connField.alignment = .right
        bwField.alignment = .right
        bwField.widthAnchor.constraint(equalToConstant: 78).isActive = true
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

        dirField.setAccessibilityLabel(L10n.saveFilesTo)
        connField.setAccessibilityLabel(L10n.maxConnectionsCaption)
        bwField.setAccessibilityLabel(L10n.globalSpeedCaption)
        speedLimitPopup.setAccessibilityLabel(L10n.globalSpeedCaption)
        uaField.setAccessibilityLabel(L10n.userAgentString)

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
        compatibilityDetailLabel.font = .systemFont(ofSize: 12)
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

    private func reloadSpeedLimitPopupTitles() {
        let selectedTag = speedLimitPopup.selectedItem?.tag
        speedLimitPopup.removeAllItems()
        let titles = [
            L10n.t("Unlimited", "不限速"),
            "1 MB/s",
            "5 MB/s",
            "10 MB/s",
            "50 MB/s",
        ]
        for (title, value) in zip(titles, Self.speedLimitPresets) {
            speedLimitPopup.addItem(withTitle: title)
            speedLimitPopup.lastItem?.tag = Int(value)
        }
        speedLimitPopup.addItem(withTitle: L10n.t("Custom…", "自定义…"))
        speedLimitPopup.lastItem?.tag = Self.customSpeedLimitTag
        if let selectedTag {
            speedLimitPopup.selectItem(withTag: selectedTag)
        }
        speedLimitUnitLabel.stringValue = "MB/s"
    }

    private func loadBandwidthLimit(_ bytesPerSecond: Int64) {
        if Self.speedLimitPresets.contains(bytesPerSecond) {
            speedLimitPopup.selectItem(withTag: Int(bytesPerSecond))
        } else {
            speedLimitPopup.selectItem(withTag: Self.customSpeedLimitTag)
            let formatter = NumberFormatter()
            formatter.locale = L10n.locale
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 6
            formatter.usesGroupingSeparator = false
            bwField.stringValue = formatter.string(
                from: NSNumber(value: Double(bytesPerSecond) / 1_000_000)
            ) ?? String(Double(bytesPerSecond) / 1_000_000)
        }
        updateSpeedLimitControlVisibility()
    }

    private func selectedBandwidthLimit() -> Int64? {
        guard let tag = speedLimitPopup.selectedItem?.tag else { return nil }
        if tag != Self.customSpeedLimitTag { return Int64(tag) }
        return SettingsInputValidation.bandwidthMegabytesPerSecond(bwField.stringValue)
    }

    private func updateSpeedLimitControlVisibility() {
        speedLimitCustomStack.isHidden = speedLimitPopup.selectedItem?.tag != Self.customSpeedLimitTag
    }

    @objc private func speedLimitSelectionChanged() {
        updateSpeedLimitControlVisibility()
        if speedLimitPopup.selectedItem?.tag == Self.customSpeedLimitTag,
           bwField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bwField.stringValue = "5"
        }
        updateValidationState()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let sidebar = ChromeBox(fill: NDMChrome.sidebarFill)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.setContentHuggingPriority(.required, for: .horizontal)
        sidebar.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Match System Settings: section label lines up with row titles (after icon).
        sidebarTitle.font = .systemFont(ofSize: 19, weight: .bold)
        sidebarTitle.textColor = .labelColor
        sidebarTitle.alignment = .left
        sidebarTitle.translatesAutoresizingMaskIntoConstraints = false

        // NSStackView kept fighting the full-rail buttons (ambiguous/zero
        // heights collapsed every row onto the same line). Lay the rows out
        // by hand instead: each row is a fixed band pinned top-to-bottom.
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
            button.onMoveSelection = { [weak self] offset in
                self?.moveSelection(from: section, offset: offset)
            }
            navigationButtons[section] = button
            navigation.addSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: navigation.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: navigation.trailingAnchor),
                button.heightAnchor.constraint(equalToConstant: 44),
                button.topAnchor.constraint(
                    equalTo: previousButton?.bottomAnchor ?? navigation.topAnchor,
                    constant: previousButton == nil ? 0 : 4
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

        saveButton.title = L10n.save
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"
        saveButton.controlSize = .large
        NDMChrome.styleMainButton(saveButton)

        let cancel = cancelButton
        cancel.title = L10n.cancel
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        cancel.keyEquivalent = "\u{1b}"
        cancel.controlSize = .large
        NDMChrome.styleGhostButton(cancel)

        footerHint.stringValue = defaultFooterHint
        footerHint.font = .systemFont(ofSize: 12)
        footerHint.textColor = .tertiaryLabelColor
        footerHint.lineBreakMode = .byTruncatingTail

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [footerHint, footerSpacer, cancel, saveButton])
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
            // Match the main window's 215 pt navigation rail closely enough
            // that Settings feels like the same product, not a miniature
            // utility window with a squeezed source list.
            sidebar.widthAnchor.constraint(equalToConstant: 212),

            sidebarTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 48),
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 28),
            sidebarTitle.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),

            navigation.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 18),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),

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
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
        ])

        panes[.general] = makeGeneralPane()
        panes[.appearance] = makeAppearancePane()
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
        currentSection = section
        contentTitle.stringValue = section.title
        contentSubtitle.stringValue = section.subtitle
        for (candidate, button) in navigationButtons {
            button.isSelected = candidate == section
        }

        guard let pane = panes[section] else { return }
        let isSwitch = scrollView.documentView !== pane
        NSLayoutConstraint.deactivate(paneConstraints)
        scrollView.documentView = pane
        if isSwitch, window?.isVisible == true {
            // A quick, quiet crossfade — just enough to soften the swap, not a
            // full theatrical dissolve of the whole content area.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.10
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.contentView.layer?.add(fade, forKey: "section")
        }
        pane.translatesAutoresizingMaskIntoConstraints = false
        paneConstraints = [
            pane.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            pane.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ]
        NSLayoutConstraint.activate(paneConstraints)
        resetScrollPosition(for: pane)
        // The first section switch happens before the settings window has
        // completed its first layout pass. Reassert the top position on the
        // next run-loop turn, but only if this pane is still current.
        DispatchQueue.main.async { [weak self, weak pane] in
            guard let self, let pane, self.scrollView.documentView === pane else { return }
            self.resetScrollPosition(for: pane)
        }
    }

    private func resetScrollPosition(for pane: NSView) {
        scrollView.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
        scrollView.contentView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scrollToQuickActionsForQA() {
        guard currentSection == .downloads,
              let pane = scrollView.documentView else { return }
        pane.layoutSubtreeIfNeeded()
        let maximumY = max(0, pane.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func moveSelection(from section: Section, offset: Int) {
        let sections = Section.allCases
        guard let index = sections.firstIndex(of: section) else { return }
        let nextIndex = min(sections.index(before: sections.endIndex), max(sections.startIndex, index + offset))
        let next = sections[nextIndex]
        showSection(next)
        if let button = navigationButtons[next] {
            window?.makeFirstResponder(button)
        }
    }

    private func makeGeneralPane() -> NSView {
        let appCard = makeCard(
            title: "NDM",
            subtitle: nil,
            symbolName: "macwindow",
            rows: [
                settingsRow(
                    title: L10n.language,
                    detail: L10n.languageFootnote,
                    control: fixedWidth(languagePopup, 190)
                ),
                toggleRow(
                    title: L10n.t("Open NDM at login", "登录时打开 NDM"),
                    detail: nil,
                    toggle: launchAtLoginSwitch
                ),
                toggleRow(title: L10n.clipboardWatchTitle, detail: L10n.t(
                    "Show a prompt when NDM becomes active.",
                    "切回 NDM 时显示提示。"
                ), toggle: clipboardSwitch),
                toggleRow(title: L10n.showCompletionDialog, detail: nil, toggle: completeSwitch),
            ]
        )
        return paneStack([appCard])
    }

    private func makeAppearancePane() -> NSView {
        appearancePopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
        accentPopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        // The accent row is just the menu now. Picking "自定义…" opens the
        // color panel directly — no permanent "Custom" label + color well
        // sitting in the row getting in the way when a preset is chosen.
        let accentControls = NSStackView(views: [accentPopup])
        accentControls.orientation = .horizontal
        accentControls.alignment = .centerY
        accentControls.spacing = 8

        let themeCard = makeCard(
            title: L10n.t("Theme", "主题"),
            subtitle: nil,
            symbolName: "paintpalette",
            rows: [
                settingsRow(
                    title: L10n.t("Mode", "模式"),
                    detail: L10n.appearanceFootnote,
                    control: appearancePopup
                ),
                settingsRow(
                    title: L10n.t("Accent color", "强调色"),
                    detail: nil,
                    control: accentControls
                ),
            ]
        )
        return paneStack([themeCard])
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
            title: L10n.t("Files", "文件"),
            subtitle: nil,
            symbolName: "folder",
            rows: [
                settingsRow(title: L10n.saveFilesTo, detail: nil, control: destinationControl),
                toggleRow(title: L10n.organizeCategories, detail: L10n.t(
                    "Create folders for videos, audio, documents, and other file types.",
                    "按视频、音频、文档等类型建立文件夹。"
                ), toggle: categorySwitch),
            ]
        )

        connField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let performanceCard = makeCard(
            title: L10n.t("Transfers", "传输"),
            subtitle: nil,
            symbolName: "speedometer",
            rows: [
                toggleRow(title: L10n.downloadAllAtOnce, detail: nil, toggle: allAtOnceSwitch),
                settingsRow(
                    title: L10n.maxConnectionsCaption,
                    detail: L10n.t("Upper limit — not a forced connection count.", "上限，不是始终强制使用的连接数。"),
                    control: connField
                ),
                { let row = toggleRow(
                    title: L10n.smartConnectionsTitle,
                    detail: L10n.smartConnectionsFootnote,
                    toggle: smartConnSwitch
                ); row.toolTip = L10n.smartConnectionsDetail; return row }(),
                settingsRow(
                    title: L10n.globalSpeedCaption,
                    detail: L10n.t(
                        "Choose a common cap, or enter a custom speed in MB/s.",
                        "选择常用档位，或用 MB/s 输入自定义速度。"
                    ),
                    control: speedLimitControl
                ),
            ]
        )
        mediaQualityPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let videoCard = makeCard(
            title: L10n.t("Video", "视频"),
            subtitle: nil,
            symbolName: "film",
            rows: [
                settingsRow(
                    title: L10n.t("Quality", "画质"),
                    detail: L10n.t(
                        "How to pick video quality. \"Ask\" opens the picker; a cap uses the best at or below it and only asks when nothing fits.",
                        "如何选择视频清晰度。「每次询问」会弹出选择器；设定上限则自动选不超过该档的最高画质，仅当没有匹配时才询问。"
                    ),
                    control: mediaQualityPopup
                ),
            ]
        )
        return paneStack([destinationCard, performanceCard, videoCard, makeCompletionActionsCard()])
    }

    private func makeCompletionActionsCard() -> NSView {
        quickActionsListStack.orientation = .vertical
        quickActionsListStack.alignment = .leading
        quickActionsListStack.spacing = 0

        let addButton = NSButton(
            title: L10n.t("Add Action…", "添加动作…"),
            target: self,
            action: #selector(showAddQuickActionMenu(_:))
        )
        addButton.image = NDMChrome.symbol("plus", pointSize: 11, weight: .semibold)
        addButton.imagePosition = .imageLeading
        addButton.controlSize = .large
        NDMChrome.styleGhostButton(addButton)

        let addRow = NSStackView(views: [NSView(), addButton])
        addRow.orientation = .horizontal
        addRow.alignment = .centerY

        let container = NSStackView(views: [quickActionsListStack, addRow])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 12
        NSLayoutConstraint.deactivate(quickActionsWidthConstraints)
        quickActionsWidthConstraints = [
            addRow.widthAnchor.constraint(equalTo: container.widthAnchor),
            quickActionsListStack.widthAnchor.constraint(equalTo: container.widthAnchor),
        ]
        NSLayoutConstraint.activate(quickActionsWidthConstraints)

        let card = makeCard(
            title: L10n.t("Completion Actions", "完成动作"),
            subtitle: L10n.t(
                "Open finished files in an app, share them, or run a Shortcut. Pin up to two actions beside the standard buttons.",
                "用 App 打开成品、系统分享，或运行快捷指令。最多可将两个动作固定在常用按钮旁。"
            ),
            symbolName: "bolt.badge.automatic",
            rows: [container]
        )
        reloadQuickActionsList()
        return card
    }

    private func reloadQuickActionsList() {
        quickActionsListStack.arrangedSubviews.forEach {
            quickActionsListStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !draftQuickActions.isEmpty else {
            let empty = NSTextField(labelWithString: L10n.t("No custom actions yet.", "还没有自定义动作。"))
            empty.font = .systemFont(ofSize: 12.5)
            empty.textColor = .tertiaryLabelColor
            quickActionsListStack.addArrangedSubview(empty)
            return
        }
        for (index, action) in draftQuickActions.enumerated() {
            let row = quickActionRow(action, index: index, total: draftQuickActions.count)
            quickActionsListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: quickActionsListStack.widthAnchor).isActive = true
        }
    }

    private func quickActionRow(_ action: QuickAction, index: Int, total: Int) -> NSView {
        let iconView = NSImageView(image: QuickActionRunner.icon(for: action, pointSize: 22))
        iconView.imageScaling = .scaleProportionallyDown

        let titleLabel = NSTextField(labelWithString: action.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        let kindLabel = NSTextField(labelWithString: quickActionKindLabel(action.kind))
        kindLabel.font = .systemFont(ofSize: 11)
        kindLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, kindLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let promote = NSButton(
            checkboxWithTitle: L10n.t("Pin", "固定"),
            target: self,
            action: #selector(toggleQuickActionPromoted(_:))
        )
        promote.state = action.promoted ? .on : .off
        promote.identifier = NSUserInterfaceItemIdentifier(action.id.uuidString)
        promote.toolTip = L10n.t(
            "Show beside the standard completion buttons",
            "显示在下载完成页的常用按钮旁"
        )

        let more = NSButton(title: "", target: self, action: #selector(showQuickActionRowMenu(_:)))
        more.image = NDMChrome.symbol("ellipsis.circle", pointSize: 14, weight: .medium)
        more.imagePosition = .imageOnly
        more.isBordered = false
        more.contentTintColor = .secondaryLabelColor
        more.identifier = NSUserInterfaceItemIdentifier(action.id.uuidString)
        more.toolTip = L10n.t("Manage this action", "管理此动作")
        more.setAccessibilityLabel(L10n.t("Manage \(action.title)", "管理“\(action.title)”"))

        let row = NSStackView(views: [iconView, labels, NSView(), promote, more])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            more.widthAnchor.constraint(equalToConstant: 30),
            more.heightAnchor.constraint(equalToConstant: 30),
        ])
        return row
    }

    @objc private func showQuickActionRowMenu(_ sender: NSButton) {
        guard let index = quickActionIndex(for: sender),
              let id = sender.identifier?.rawValue else { return }
        let menu = NSMenu()
        let up = NSMenuItem(
            title: L10n.t("Move Up", "上移"),
            action: #selector(moveQuickActionUpFromMenu(_:)),
            keyEquivalent: ""
        )
        up.target = self
        up.image = NDMChrome.symbol("chevron.up", pointSize: 11, weight: .semibold)
        up.representedObject = id
        up.isEnabled = index > 0
        menu.addItem(up)

        let down = NSMenuItem(
            title: L10n.t("Move Down", "下移"),
            action: #selector(moveQuickActionDownFromMenu(_:)),
            keyEquivalent: ""
        )
        down.target = self
        down.image = NDMChrome.symbol("chevron.down", pointSize: 11, weight: .semibold)
        down.representedObject = id
        down.isEnabled = index < draftQuickActions.count - 1
        menu.addItem(down)
        menu.addItem(.separator())

        let remove = NSMenuItem(
            title: L10n.t("Remove Action", "移除动作"),
            action: #selector(removeQuickActionFromMenu(_:)),
            keyEquivalent: ""
        )
        remove.target = self
        remove.image = NDMChrome.symbol("trash", pointSize: 11, weight: .medium)
        remove.representedObject = id
        menu.addItem(remove)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 3), in: sender)
    }

    private func quickActionKindLabel(_ kind: QuickAction.Kind) -> String {
        switch kind {
        case .openWithApp: return L10n.t("Open with app", "用 App 打开")
        case .shareService: return L10n.t("System share", "系统分享")
        case .shortcut: return L10n.t("Shortcut", "快捷指令")
        }
    }

    @objc private func showAddQuickActionMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let openWith = NSMenuItem(
            title: L10n.t("Open with App…", "用 App 打开…"),
            action: #selector(addOpenWithQuickAction),
            keyEquivalent: ""
        )
        openWith.target = self
        openWith.ndmSymbol("app.badge")
        menu.addItem(openWith)

        let share = NSMenuItem(title: L10n.t("System Share", "系统分享"), action: nil, keyEquivalent: "")
        share.ndmSymbol("square.and.arrow.up")
        share.submenu = shareServicesMenu()
        menu.addItem(share)

        let shortcut = NSMenuItem(
            title: L10n.t("Shortcut…", "快捷指令…"),
            action: #selector(addShortcutQuickAction),
            keyEquivalent: ""
        )
        shortcut.target = self
        shortcut.ndmSymbol("wand.and.stars")
        menu.addItem(shortcut)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 3), in: sender)
    }

    private func shareServicesMenu() -> NSMenu {
        let menu = NSMenu()
        let services = QuickActionRunner.availableShareServices()
        guard !services.isEmpty else {
            let item = NSMenuItem(
                title: L10n.t("No share services available", "没有可用的分享服务"),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }
        for service in services {
            let item = NSMenuItem(
                title: service.title,
                action: #selector(addShareServiceQuickAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.image = service.image
            item.representedObject = service.title
            menu.addItem(item)
        }
        return menu
    }

    @objc private func addOpenWithQuickAction() {
        let panel = NSOpenPanel()
        panel.message = L10n.t(
            "Choose an app for finished downloads",
            "选择用来打开下载成品的 App"
        )
        panel.prompt = L10n.t("Add", "添加")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK,
              let appURL = panel.url,
              let action = QuickActionRunner.openWithAction(forAppAt: appURL) else { return }
        appendQuickAction(action)
    }

    @objc private func addShareServiceQuickAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        appendQuickAction(QuickAction(
            title: name,
            kind: .shareService(named: name),
            symbol: "square.and.arrow.up"
        ))
    }

    @objc private func addShortcutQuickAction() {
        let field = NSTextField(string: "")
        field.placeholderString = L10n.t("Shortcut name", "快捷指令名称")
        field.controlSize = .large
        field.bezelStyle = .roundedBezel
        NDMDialog.present(
            title: L10n.t("Run a Shortcut", "运行快捷指令"),
            body: L10n.t(
                "Enter its exact name from the Shortcuts app.",
                "输入它在「快捷指令」App 中的准确名称。"
            ),
            buttons: [
                NDMDialog.Button(L10n.t("Add", "添加")),
                NDMDialog.Button(L10n.cancel, isCancel: true),
            ],
            accessory: field,
            host: window
        ) { [weak self, weak field] result in
            guard result.buttonIndex == 0, let self, let field else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self.appendQuickAction(QuickAction(
                title: name,
                kind: .shortcut(named: name),
                symbol: "wand.and.stars"
            ))
        }
    }

    private func appendQuickAction(_ action: QuickAction) {
        guard !draftQuickActions.contains(where: { $0.kind == action.kind }) else { return }
        draftQuickActions.append(action)
        reloadQuickActionsList()
    }

    @objc private func toggleQuickActionPromoted(_ sender: NSButton) {
        guard let index = quickActionIndex(for: sender) else { return }
        draftQuickActions[index].promoted = sender.state == .on
        reloadQuickActionsList()
    }

    @objc private func removeQuickActionFromMenu(_ sender: NSMenuItem) {
        guard let index = quickActionIndex(for: sender) else { return }
        draftQuickActions.remove(at: index)
        reloadQuickActionsList()
    }

    @objc private func moveQuickActionUpFromMenu(_ sender: NSMenuItem) {
        moveQuickAction(sender, offset: -1)
    }

    @objc private func moveQuickActionDownFromMenu(_ sender: NSMenuItem) {
        moveQuickAction(sender, offset: 1)
    }

    private func moveQuickAction(_ sender: NSMenuItem, offset: Int) {
        guard let index = quickActionIndex(for: sender) else { return }
        let destination = index + offset
        guard draftQuickActions.indices.contains(destination) else { return }
        draftQuickActions.swapAt(index, destination)
        reloadQuickActionsList()
    }

    private func quickActionIndex(for sender: NSButton) -> Int? {
        guard let id = sender.identifier?.rawValue else { return nil }
        return draftQuickActions.firstIndex { $0.id.uuidString == id }
    }

    private func quickActionIndex(for sender: NSMenuItem) -> Int? {
        guard let id = sender.representedObject as? String else { return nil }
        return draftQuickActions.firstIndex { $0.id.uuidString == id }
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
        toggle: SettingsAccentSwitch,
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
        host.setAccessibilityLabel(L10n.host)
        port.setAccessibilityLabel(L10n.t("Port", "端口"))
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
        user.setAccessibilityLabel(L10n.t("Username", "用户名"))
        pass.setAccessibilityLabel(L10n.t("Password", "密码"))
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
        let container = SettingsPaneDocumentView()
        var previous: NSView?
        for card in cards {
            card.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(card)
            let fillAvailableWidth = card.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -8
            )
            fillAvailableWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                fillAvailableWidth,
                card.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
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

    private static func accentSwatch(color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 13, height: 13), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let border = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 1
            border.stroke()
            return true
        }
    }

    private func makeCard(
        title: String,
        subtitle: String?,
        symbolName: String,
        rows: [NSView]
    ) -> NSView {
        let card = ChromeBox(
            fill: .clear
        )
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NDMChrome.symbol(symbolName, pointSize: 14, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        let labelViews: [NSView]
        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 12.5)
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

        let header = NSStackView(views: [icon, labels])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.setCustomSpacing(10, after: header)
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
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    private func settingsRow(title: String, detail: String?, control: NSView) -> NSView {
        (control as? NSControl)?.setAccessibilityLabel(title)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor

        var labelViews: [NSView] = [titleLabel]
        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 12)
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

    private func toggleRow(title: String, detail: String?, toggle: SettingsAccentSwitch) -> NSView {
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
        if let qi = MediaQualityPreference.presetCases.firstIndex(of: settings.mediaQualityPreference) {
            mediaQualityPopup.selectItem(at: qi)
        }
        loadBandwidthLimit(settings.bandwidthLimitBytesPerSecond)
        categorySwitch.state = settings.useCategoryFolders ? .on : .off
        allAtOnceSwitch.state = settings.downloadAllAtOnce ? .on : .off
        completeSwitch.state = settings.showCompletionDialog ? .on : .off
        clipboardSwitch.state = settings.clipboardWatchEnabled ? .on : .off
        launchAtLoginSwitch.state = settings.launchAtLogin ? .on : .off

        if let index = AppearanceMode.allCases.firstIndex(of: settings.appearanceMode) {
            appearancePopup.selectItem(at: index)
        }
        if let index = AccentTheme.allCases.firstIndex(of: settings.accentTheme) {
            accentPopup.selectItem(at: index)
        }
        customAccentColorWell.color = NDMChrome.color(hex: settings.customAccentHex)
            ?? NDMChrome.accent(for: .classicBlue)
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
        refreshAccentControls()
        updateEnabledStates()
    }

    @objc private func appearanceSelectionChanged() {
        commitAppearanceLive()
    }

    @objc private func languageSelectionChanged() {
        commitAppearanceLive()
    }

    @objc private func accentSelectionChanged() {
        let themes = AccentTheme.allCases
        let index = accentPopup.indexOfSelectedItem
        let isCustom = themes.indices.contains(index) && themes[index] == .custom
        if isCustom {
            // Selecting "自定义…" opens the system color panel right away —
            // that IS the interaction, not a separate well to hunt for.
            openCustomAccentPanel()
        }
        commitAppearanceLive()
    }

    private func openCustomAccentPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NDMChrome.accent(for: .custom, customHex: settings.customAccentHex)
        panel.setTarget(self)
        panel.setAction(#selector(customAccentPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func customAccentPanelChanged(_ sender: NSColorPanel) {
        guard let customIndex = AccentTheme.allCases.firstIndex(of: .custom) else { return }
        customAccentColorWell.color = sender.color
        accentPopup.selectItem(at: customIndex)
        accentPopup.item(at: customIndex)?.image = Self.accentSwatch(color: sender.color)
        commitAppearanceLive()
    }

    /// Theme, accent, and language apply the instant they're picked — no Save
    /// round-trip. Each of these fields is validation-free, so we can persist
    /// them independently of the rest of the form. Other panes (downloads,
    /// network) still commit on Save.
    private func commitAppearanceLive() {
        var next = settings
        let appearanceIndex = appearancePopup.indexOfSelectedItem
        if AppearanceMode.allCases.indices.contains(appearanceIndex) {
            next.appearanceMode = AppearanceMode.allCases[appearanceIndex]
        }
        let accentIndex = accentPopup.indexOfSelectedItem
        if AccentTheme.allCases.indices.contains(accentIndex) {
            next.accentTheme = AccentTheme.allCases[accentIndex]
        }
        if next.accentTheme == .custom {
            next.customAccentHex = NDMChrome.hexString(for: customAccentColorWell.color) ?? next.customAccentHex
        }
        let languageIndex = languagePopup.indexOfSelectedItem
        if AppLanguageMode.allCases.indices.contains(languageIndex) {
            next.languageMode = AppLanguageMode.allCases[languageIndex]
        }
        let appearanceChanged = settings.appearanceMode != next.appearanceMode
        settings = next
        AppearanceApplicator.apply(next.appearanceMode, animated: appearanceChanged)
        NDMChrome.applyAccentTheme(next.accentTheme, customHex: next.customAccentHex)
        L10n.apply(next.languageMode)
        // Refresh the accent swatches in the popup to the new theme colors.
        for (index, theme) in AccentTheme.allCases.enumerated() {
            accentPopup.item(at: index)?.image = Self.accentSwatch(
                color: NDMChrome.accent(for: theme, customHex: next.customAccentHex)
            )
        }
        SettingsStore.save(next)
        Task { await manager.updateSettings(next) }
    }

    private func refreshAccentControls() {
        let themes = AccentTheme.allCases
        let selectedIndex = accentPopup.indexOfSelectedItem
        let isCustom = selectedIndex >= 0 && selectedIndex < themes.count
            && themes[selectedIndex] == .custom
        customAccentColorWell.isHidden = !isCustom
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
        updateValidationState()
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
            updateValidationState()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        updateValidationState()
    }

    private var defaultFooterHint: String {
        L10n.t(
            "Changes apply to new and active downloads when saved.",
            "保存后将应用到新任务和正在进行的任务。"
        )
    }

    private func trimmed(_ field: NSTextField) -> String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstValidationIssue() -> ValidationIssue? {
        let directory = trimmed(dirField)
        guard !directory.isEmpty, directory.hasPrefix("/") else {
            return ValidationIssue(
                field: dirField,
                message: L10n.t("Choose an absolute download folder.", "请选择一个有效的绝对下载目录。")
            )
        }

        guard SettingsInputValidation.connectionCount(connField.stringValue) != nil else {
            return ValidationIssue(
                field: connField,
                message: L10n.t("Connections must be a whole number from 1 to 32.", "连接数必须是 1 到 32 之间的整数。")
            )
        }

        guard selectedBandwidthLimit() != nil else {
            return ValidationIssue(
                field: bwField,
                message: L10n.t(
                    "Enter a custom speed greater than 0 MB/s.",
                    "请输入大于 0 MB/s 的自定义速度。"
                )
            )
        }

        if uaSwitch.state == .on, trimmed(uaField).isEmpty {
            return ValidationIssue(
                field: uaField,
                message: L10n.t("Enter a User-Agent string or turn this option off.", "请输入 User-Agent，或关闭此选项。")
            )
        }

        let endpoints: [(Bool, String, NSTextField, NSTextField)] = [
            (proxySwitch.state == .on, "HTTP(S)", proxyHostField, proxyPortField),
            (ftpProxySwitch.state == .on, "FTP", ftpHostField, ftpPortField),
            (socksSwitch.state == .on, "SOCKS", socksHostField, socksPortField),
        ]
        for (enabled, name, host, port) in endpoints where enabled {
            if trimmed(host).isEmpty {
                return ValidationIssue(
                    field: host,
                    message: L10n.t("Enter the \(name) proxy host.", "请输入 \(name) 代理主机。")
                )
            }
            guard SettingsInputValidation.port(port.stringValue) != nil else {
                return ValidationIssue(
                    field: port,
                    message: L10n.t("The \(name) port must be from 1 to 65535.", "\(name) 端口必须是 1 到 65535 之间的整数。")
                )
            }
        }
        return nil
    }

    private func updateValidationState() {
        guard isWindowLoaded else { return }
        if let issue = firstValidationIssue() {
            saveButton.isEnabled = false
            footerHint.stringValue = issue.message
            footerHint.textColor = .systemRed
            footerHint.setAccessibilityLabel(L10n.error)
            footerHint.setAccessibilityValue(issue.message)
        } else {
            saveButton.isEnabled = true
            footerHint.stringValue = defaultFooterHint
            footerHint.textColor = .tertiaryLabelColor
            footerHint.setAccessibilityLabel(defaultFooterHint)
            footerHint.setAccessibilityValue(nil)
        }
    }

    private func presentValidationIssue(_ issue: ValidationIssue) {
        updateValidationState()
        NSSound.beep()
        guard let field = issue.field else { return }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
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
                NDMDialog.present(
                    title: L10n.importedCount(n),
                    subject: .info,
                    host: self.window
                )
            } catch {
                NDMDialog.present(
                    title: L10n.importFailed,
                    body: error.localizedDescription,
                    subject: .failure,
                    host: self.window
                )
            }
        }
    }

    @objc private func saveClicked() {
        if let issue = firstValidationIssue() {
            presentValidationIssue(issue)
            return
        }
        var next = settings
        next.downloadDirectory = URL(fileURLWithPath: trimmed(dirField))
        let requestedConnections = SettingsInputValidation.connectionCount(connField.stringValue)!
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
        let qi = mediaQualityPopup.indexOfSelectedItem
        if MediaQualityPreference.presetCases.indices.contains(qi) {
            next.mediaQuality = MediaQualityPreference.presetCases[qi]
        }
        next.bandwidthLimitBytesPerSecond = selectedBandwidthLimit()!
        next.useCategoryFolders = categorySwitch.state == .on
        next.downloadAllAtOnce = allAtOnceSwitch.state == .on
        next.showCompletionDialog = completeSwitch.state == .on
        next.quickActions = draftQuickActions
        next.clipboardWatch = clipboardSwitch.state == .on
        next.launchAtLogin = launchAtLoginSwitch.state == .on

        let appearanceIndex = appearancePopup.indexOfSelectedItem
        if AppearanceMode.allCases.indices.contains(appearanceIndex) {
            next.appearanceMode = AppearanceMode.allCases[appearanceIndex]
        }
        let accentIndex = accentPopup.indexOfSelectedItem
        if AccentTheme.allCases.indices.contains(accentIndex) {
            next.accentTheme = AccentTheme.allCases[accentIndex]
        }
        if next.accentTheme == .custom {
            next.customAccentHex = NDMChrome.hexString(for: customAccentColorWell.color)
        }
        let languageIndex = languagePopup.indexOfSelectedItem
        if AppLanguageMode.allCases.indices.contains(languageIndex) {
            next.languageMode = AppLanguageMode.allCases[languageIndex]
        }

        next.showBrowserMediaPanel = panelSwitch.state == .on
        next.confirmBrowserDownloads = confirmSwitch.state == .on
        next.useCustomUserAgent = uaSwitch.state == .on
        next.customUserAgent = trimmed(uaField).isEmpty ? nil : trimmed(uaField)
        AppearanceApplicator.apply(next.appearanceMode)
        NDMChrome.applyAccentTheme(next.accentTheme, customHex: next.customAccentHex)
        L10n.apply(next.languageMode)

        let pport = SettingsInputValidation.port(proxyPortField.stringValue)
            ?? settings.httpProxy?.port ?? 8080
        next.httpProxy = ProxySettings(
            host: proxyHostField.stringValue,
            port: pport,
            username: proxyUserField.stringValue.isEmpty ? nil : proxyUserField.stringValue,
            password: proxyPassField.stringValue.isEmpty ? nil : proxyPassField.stringValue,
            enabled: proxySwitch.state == .on
        )
        next.httpsProxy = next.httpProxy

        let fport = SettingsInputValidation.port(ftpPortField.stringValue)
            ?? settings.ftpProxy?.port ?? 8080
        next.ftpProxy = ProxySettings(
            host: ftpHostField.stringValue,
            port: fport,
            username: ftpUserField.stringValue.isEmpty ? nil : ftpUserField.stringValue,
            password: ftpPassField.stringValue.isEmpty ? nil : ftpPassField.stringValue,
            enabled: ftpProxySwitch.state == .on
        )

        let sport = SettingsInputValidation.port(socksPortField.stringValue)
            ?? settings.socksProxy?.port ?? 1080
        next.socksProxy = SocksProxySettings(
            host: socksHostField.stringValue,
            port: sport,
            version: socksVersionPopup.indexOfSelectedItem == 1 ? .v4 : .v5,
            username: socksUserField.stringValue.isEmpty ? nil : socksUserField.stringValue,
            password: socksPassField.stringValue.isEmpty ? nil : socksPassField.stringValue,
            enabled: socksSwitch.state == .on
        )

        if next.launchAtLogin != settings.launchAtLogin {
            do {
                if next.launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NDMDialog.present(
                    title: L10n.t(
                        "Couldn’t change login settings",
                        "无法更改登录项设置"
                    ),
                    body: error.localizedDescription,
                    subject: .failure,
                    host: window
                )
                return
            }
        }

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

/// Scroll documents use a top-left origin so every section opens against the
/// same top edge, including the very first section shown before window layout.
private final class SettingsPaneDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A native-behaving toggle with NDM-owned color. `NSSwitch` always inherits
/// the Mac's global accent, which made a Jade/Violet NDM still show blue
/// controls. Keeping this as an `NSButton` preserves target/action, keyboard
/// activation, state, focus, and accessibility while the small visual surface
/// follows the product theme.
private final class SettingsAccentSwitch: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        setButtonType(.toggle)
        bezelStyle = .inline
        isBordered = false
        allowsMixedState = false
        focusRingType = .none
        // AppKit does not expose an AXSwitch role on our macOS 13 deployment
        // target; a toggle button with the checkbox role preserves the same
        // on/off semantics for VoiceOver.
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(0)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 26) }
    override var acceptsFirstResponder: Bool { true }

    override func setNextState() {
        super.setNextState()
        setAccessibilityValue(state == .on ? 1 : 0)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackRect = bounds.insetBy(dx: 1, dy: 2)
        let track = NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackRect.height / 2,
            yRadius: trackRect.height / 2
        )
        let on = state == .on
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let trackColor = on
            ? NDMChrome.accent
            : NSColor(calibratedWhite: isDark ? 0.34 : 0.82, alpha: 1)
        trackColor.withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        track.fill()

        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.75).setStroke()
            track.lineWidth = 2
            track.stroke()
        } else if !on {
            NDMChrome.hairline.setStroke()
            track.lineWidth = 1
            track.stroke()
        }

        let thumbSide = trackRect.height - 4
        let thumbX = on
            ? trackRect.maxX - thumbSide - 2
            : trackRect.minX + 2
        let thumbRect = NSRect(
            x: thumbX,
            y: trackRect.midY - thumbSide / 2,
            width: thumbSide,
            height: thumbSide
        )
        let thumb = NSBezierPath(ovalIn: thumbRect)
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.72).setFill()
        thumb.fill()
    }
}

/// Full-rail sidebar row — selection paints `bounds`, label stays leading.
private final class SettingsNavigationButton: NSButton, AccentChromeRefreshing {
    override func becomeFirstResponder() -> Bool {
        adoptFocusRingPolicy(super.becomeFirstResponder())
    }

    private let symbolName: String
    private let titleText: String
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    var onMoveSelection: ((Int) -> Void)?

    var isSelected = false {
        didSet {
            updateVisualState()
            state = isSelected ? .on : .off
            setAccessibilityValue(isSelected ? 1 : 0)
            needsDisplay = true
        }
    }

    private var isHovering = false {
        didSet { if oldValue != isHovering { needsDisplay = true } }
    }

    func updateTitle(_ title: String) {
        titleLabel.stringValue = title
        setAccessibilityLabel(title)
    }

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
        self.tag = tag
        self.target = target
        self.action = action
        self.title = ""
        isBordered = false
        bezelStyle = .inline
        // Ring only for keyboard focus — see FocusRingPolicy.
        focusRingType = .none
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = titleText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isSelectable = false
        titleLabel.setAccessibilityElement(false)

        addSubview(iconView)
        addSubview(titleLabel)
        // Height is owned by the sidebar layout; don't pin here.
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
        updateVisualState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg: NSColor
            if isSelected {
                bg = NDMChrome.rowActive
            } else if isHovering {
                bg = NDMChrome.railHover
            } else {
                bg = .clear
            }
            layer?.backgroundColor = bg.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { if $0.owner === self { removeTrackingArea($0) } }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126:
            onMoveSelection?(-1)
        case 124, 125:
            onMoveSelection?(1)
        default:
            super.keyDown(with: event)
        }
    }

    private func updateVisualState() {
        let tint: NSColor = isSelected ? NDMChrome.accent : .labelColor
        let weight: NSFont.Weight = isSelected ? .semibold : .regular
        iconView.image = NDMChrome.symbol(symbolName, pointSize: 15, weight: weight)
        iconView.contentTintColor = isSelected ? NDMChrome.accent : .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 14.5, weight: weight)
        titleLabel.textColor = tint
    }

    func refreshAccentChrome() {
        updateVisualState()
        needsDisplay = true
    }
}

/// A native pop-up menu with one visual owner. AppKit's large bordered pop-up
/// paints a saturated arrow segment of its own; in the settings cards that
/// segment was heavier than every surrounding control. Retain native menu,
/// keyboard and accessibility behavior, but draw a quiet shell and chevron.
private final class SettingsPopupButton: NSPopUpButton {
    override func becomeFirstResponder() -> Bool {
        adoptFocusRingPolicy(super.becomeFirstResponder())
    }

    private let chevronView = NSImageView()

    init() {
        super.init(frame: .zero, pullsDown: false)
        controlSize = .regular
        bezelStyle = .inline
        isBordered = false
        alignment = .left
        // Ring only for keyboard focus — see FocusRingPolicy.
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        if let popUpCell = cell as? NSPopUpButtonCell {
            popUpCell.arrowPosition = .noArrow
        }

        chevronView.image = NDMChrome.symbol("chevron.up.chevron.down", pointSize: 10, weight: .semibold)
        chevronView.contentTintColor = .secondaryLabelColor
        chevronView.imageScaling = .scaleProportionallyDown
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.setAccessibilityElement(false)
        addSubview(chevronView)
        NSLayoutConstraint.activate([
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 13),
            chevronView.heightAnchor.constraint(equalToConstant: 13),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NDMChrome.searchSurface.cgColor
            layer?.borderColor = NDMChrome.hairline.cgColor
        }
    }
}
