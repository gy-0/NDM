import AppKit
import NDMCore
import NDMEngine
import NDMBridge

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var mainWindow: MainWindowController?
    private var statusItem: NSStatusItem?
    private var statusSummaryItem: NSMenuItem?
    private var statusTasksSeparator: NSMenuItem?
    private var statusTaskItems: [NSMenuItem] = []
    private var statusPauseAllItem: NSMenuItem?
    private var manager: DownloadManager?
    private var bridge: BrowserBridge?
    private var settings = SettingsStore.load()
    private var waitWindow: WaitWindowController?
    private var browsersWindow: BrowsersWindowController?
    private var settingsWindow: SettingsWindowController?
    private var completionWindow: CompletionWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var terminationCheckInFlight = false
    private var statusPollTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        L10n.apply(settings.languageMode)
        AppearanceApplicator.apply(settings.appearanceMode)
        NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupMainMenu()
                self?.rebuildStatusItemMenu()
                await self?.mainWindow?.reload()
            }
        }
        do {
            let support = DownloadStore.defaultSupportDirectory
            let store = try DownloadStore(directory: support)
            settings.bridgePort = BridgeConstants.port
            let manager = DownloadManager(store: store, settings: settings, supportRoot: support)
            self.manager = manager

            let bridge = BrowserBridge(port: settings.bridgePort)
            bridge.onDownloadMessage = { [weak self] msg in
                Task { @MainActor in
                    await self?.handleBrowserDownloadRequest(msg)
                }
            }
            bridge.onClientCountChanged = { [weak self, weak bridge] count in
                guard count > 0 else { return }
                Task { @MainActor in
                    guard let self, let bridge else { return }
                    for message in BridgeConstants.showPanelMessages(
                        enabled: self.settings.showBrowserMediaPanel
                    ) {
                        bridge.sendToAllClients(message)
                    }
                }
            }
            do {
                try bridge.start()
                self.bridge = bridge
            } catch {
                self.bridge = nil
                let alert = NSAlert()
                alert.messageText = L10n.bridgePortInUse(settings.bridgePort)
                alert.informativeText = L10n.bridgePortInUseBody(
                    settings.bridgePort,
                    error.localizedDescription
                )
                alert.addButton(withTitle: L10n.continueWithoutBridge)
                alert.addButton(withTitle: L10n.quit)
                if alert.runModal() != .alertFirstButtonReturn {
                    NSApp.terminate(nil)
                    return
                }
            }

            if let bridge = self.bridge {
                Task { [weak self, manager, bridge] in
                    await manager.setSettingsChangedHandler { [weak self] next in
                        Task { @MainActor in
                            self?.settings = next
                            AppearanceApplicator.apply(next.appearanceMode)
                            L10n.apply(next.languageMode)
                            for msg in BridgeConstants.showPanelMessages(enabled: next.showBrowserMediaPanel) {
                                self?.bridge?.sendToAllClients(msg)
                            }
                        }
                    }
                    guard let self else { return }
                    for msg in BridgeConstants.showPanelMessages(enabled: self.settings.showBrowserMediaPanel) {
                        bridge.sendToAllClients(msg)
                    }
                }
            } else {
                Task { [weak self, manager] in
                    await manager.setSettingsChangedHandler { [weak self] next in
                        Task { @MainActor in
                            self?.settings = next
                            AppearanceApplicator.apply(next.appearanceMode)
                            L10n.apply(next.languageMode)
                        }
                    }
                }
            }

            let window = MainWindowController(manager: manager)
            window.showWindow(nil)
            mainWindow = window

            setupMainMenu()
            setupStatusItem()
            startStatusPolling()
            NSApp.activate(ignoringOtherApps: true)

            if settings.needsOnboarding {
                presentOnboarding()
            }

            Task { [weak self, manager] in
                await manager.setCompletionHandler { [weak self] task in
                    Task { @MainActor in
                        self?.presentCompletion(for: task)
                    }
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.failedToStart
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager else { return .terminateNow }
        guard !terminationCheckInFlight else { return .terminateLater }
        terminationCheckInFlight = true
        Task { [weak self, manager, weak sender] in
            let active = await manager.hasActiveDownloads()
            guard let self, let sender else { return }
            var shouldTerminate = true
            if active {
                let alert = NSAlert()
                alert.messageText = L10n.downloadsInProgress
                alert.informativeText = L10n.quitWithActiveBody
                alert.addButton(withTitle: L10n.quit)
                alert.addButton(withTitle: L10n.cancel)
                shouldTerminate = alert.runModal() == .alertFirstButtonReturn
            }
            self.terminationCheckInFlight = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusPollTask?.cancel()
        bridge?.stop()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: L10n.aboutNDM, action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.ndmSymbol("info.circle")
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.settingsEllipsis, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.ndmSymbol("gearshape")
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(
            title: L10n.quitNDM,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.ndmSymbol("power")
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L10n.fileMenu)
        add(fileMenu, L10n.newDownloadEllipsis, #selector(newDownload), "n", symbol: "plus.circle")
        add(fileMenu, L10n.browserExtensionEllipsis, #selector(showBrowsers), "b", symbol: "globe")
        fileMenu.addItem(.separator())
        add(fileMenu, L10n.start, #selector(menuStart), "", symbol: "play.fill")
        add(fileMenu, L10n.pause, #selector(menuPause), "", symbol: "pause.fill")
        add(fileMenu, L10n.showProgress, #selector(menuProgress), "i", symbol: "chart.bar.fill")
        add(fileMenu, L10n.propertiesEllipsis, #selector(menuProperties), "i", [.command, .option], symbol: "info.circle")
        add(fileMenu, L10n.copyURL, #selector(menuCopyURL), "c", [.command, .shift], symbol: "doc.on.doc")
        fileMenu.addItem(.separator())
        add(fileMenu, L10n.raceMenuTitle, #selector(showSpeedRace), "", symbol: "flag.checkered")
        fileMenu.addItem(.separator())
        add(fileMenu, L10n.removeEllipsis, #selector(menuDelete), String(UnicodeScalar(8)!), symbol: "trash")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.editMenu)
        let cut = NSMenuItem(title: L10n.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cut.ndmSymbol("scissors")
        let copy = NSMenuItem(title: L10n.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.ndmSymbol("doc.on.doc")
        let paste = NSMenuItem(title: L10n.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.ndmSymbol("doc.on.clipboard")
        let selectAll = NSMenuItem(title: L10n.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAll.ndmSymbol("checkmark.circle")
        editMenu.addItem(cut)
        editMenu.addItem(copy)
        editMenu.addItem(paste)
        editMenu.addItem(selectAll)
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.windowMenu)
        let showMain = NSMenuItem(title: L10n.showMainWindow, action: #selector(showMain), keyEquivalent: "0")
        showMain.keyEquivalentModifierMask = [.command]
        showMain.target = self
        showMain.ndmSymbol("macwindow")
        windowMenu.addItem(showMain)
        let minimize = NSMenuItem(
            title: L10n.minimize,
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        minimize.ndmSymbol("minus.square")
        windowMenu.addItem(minimize)
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ mask: NSEvent.ModifierFlags = [.command],
        symbol: String? = nil
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty {
            item.keyEquivalentModifierMask = mask
        }
        item.target = self
        if let symbol {
            item.ndmSymbol(symbol)
        }
        menu.addItem(item)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = L10n.appName
        statusItem = item
        // Drag a link onto the menu bar icon → download starts. The overlay
        // forwards clicks by not claiming hit-testing outside of drags.
        if let button = item.button {
            let drop = StatusItemDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onDropURL = { [weak self] url in
                self?.mainWindow?.addAndStart(urlString: url)
                self?.mainWindow?.showWindow(nil)
            }
            button.addSubview(drop)
        }
        rebuildStatusItemMenu()
    }

    /// Transparent drop layer over the status item button.
    private final class StatusItemDropView: NSView {
        var onDropURL: ((String) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.URL, .string])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        // Clicks pass through to the status button (menu opens as usual);
        // only drags are consumed here.
        override func mouseDown(with event: NSEvent) {
            (superview as? NSButton)?.performClick(nil)
        }

        override func rightMouseDown(with event: NSEvent) {
            (superview as? NSButton)?.performClick(nil)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let pasteboard = sender.draggingPasteboard
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
               let first = urls.first, first.scheme?.hasPrefix("http") == true || first.scheme == "ftp" {
                onDropURL?(first.absoluteString)
                return true
            }
            if let text = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               text.contains("://"),
               let first = text.components(separatedBy: .whitespacesAndNewlines).first {
                onDropURL?(first)
                return true
            }
            return false
        }
    }

    private func rebuildStatusItemMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        menu.delegate = self
        let summary = NSMenuItem(title: L10n.idle, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        statusSummaryItem = summary
        // Live task rows are inserted here (menuWillOpen / refresh).
        let tasksSeparator = NSMenuItem.separator()
        menu.addItem(tasksSeparator)
        statusTasksSeparator = tasksSeparator
        func addItem(_ title: String, action: Selector, symbol: String) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.ndmSymbol(symbol)
            menu.addItem(menuItem)
            return menuItem
        }
        let pauseAll = addItem(L10n.pauseAll, action: #selector(pauseAllDownloads), symbol: "pause.circle")
        pauseAll.keyEquivalent = "p"
        pauseAll.keyEquivalentModifierMask = [.command, .shift]
        statusPauseAllItem = pauseAll
        _ = addItem(L10n.showMainWindow, action: #selector(showMain), symbol: "macwindow")
        _ = addItem(L10n.newDownloadEllipsis, action: #selector(newDownload), symbol: "plus.circle")
        _ = addItem(L10n.browserExtensionEllipsis, action: #selector(showBrowsers), symbol: "globe")
        _ = addItem(L10n.settingsEllipsis, action: #selector(openSettings), symbol: "gearshape")
        _ = addItem(L10n.aboutNDM, action: #selector(showAbout), symbol: "info.circle")
        if !LicenseStore.isPro {
            _ = addItem(L10n.proMenuTitle, action: #selector(showUpgrade), symbol: "sparkles")
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        quit.ndmSymbol("power")
        menu.addItem(quit)
        item.menu = menu
        refreshStatusItem()
    }

    /// Insert/update the mini-panel task rows above the actions section.
    private func refreshStatusTaskRows() {
        guard let menu = statusItem?.menu, let separator = statusTasksSeparator else { return }
        let tasks = mainWindow?.menuBarTasks() ?? []

        for item in statusTaskItems {
            menu.removeItem(item)
        }
        statusTaskItems.removeAll()

        guard !tasks.isEmpty else {
            statusPauseAllItem?.isHidden = true
            return
        }
        statusPauseAllItem?.isHidden = false

        var insertAt = menu.index(of: separator) + 1
        for task in tasks {
            let item = NSMenuItem(title: "", action: #selector(statusTaskClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = task.taskID
            let row = MenuBarTaskRowView(name: task.name, detail: task.detail, fraction: task.fraction)
            item.view = row
            menu.insertItem(item, at: insertAt)
            statusTaskItems.append(item)
            insertAt += 1
        }
        let trailingSeparator = NSMenuItem.separator()
        menu.insertItem(trailingSeparator, at: insertAt)
        statusTaskItems.append(trailingSeparator)
    }

    @objc private func statusTaskClicked(_ sender: NSMenuItem) {
        guard let taskID = sender.representedObject as? Int64 else { return }
        mainWindow?.showProgress(for: taskID)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func pauseAllDownloads() {
        mainWindow?.pauseAllActive()
    }

    @objc private func showSpeedRace() {
        SpeedRaceWindowController.present()
    }

    @objc private func showUpgrade() {
        UpgradeWindowController.present { [weak self] in
            self?.rebuildStatusItemMenu()
        }
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            self.refreshStatusItem()
        }
    }

    private func startStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.refreshStatusItem()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func refreshStatusItem() {
        let snapshot = mainWindow?.statusBarSnapshot() ?? (activeCount: 0, bytesPerSecond: 0)
        let activeCount = snapshot.activeCount
        let bytesPerSecond = snapshot.bytesPerSecond
        guard let button = statusItem?.button else { return }
        button.image = NDMChrome.symbol("arrow.down.circle", pointSize: 13, weight: .medium)
        button.imagePosition = activeCount == 0 ? .imageOnly : .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        if activeCount == 0 {
            // Quiet when idle — just the outline, no text shouting.
            button.title = ""
            statusSummaryItem?.title = bridge == nil ? L10n.idleBridgeOff : L10n.idle
            refreshStatusTaskRows()
            refreshDockTile(activeCount: 0, fraction: 0)
            return
        }
        let speedText: String
        if bytesPerSecond > 0 {
            speedText = TaskPresentationFormatting.speed(bytesPerSecond, status: .downloading)
        } else {
            speedText = "…"
        }
        button.title = " \(speedText)"
        statusSummaryItem?.title = L10n.activeSummary(activeCount, speedText)
        refreshStatusTaskRows()
        refreshDockTile(
            activeCount: activeCount,
            fraction: mainWindow?.dockProgressSnapshot() ?? 0
        )
    }

    // MARK: - Dock progress

    private var dockProgressView: DockProgressView?

    /// Aggregate progress bar over the Dock icon while downloading;
    /// removed (back to the plain icon) the moment everything is done.
    private func refreshDockTile(activeCount: Int, fraction: Double) {
        let tile = NSApp.dockTile
        if activeCount == 0 {
            if dockProgressView != nil {
                tile.contentView = nil
                dockProgressView = nil
                tile.badgeLabel = nil
                tile.display()
            }
            return
        }
        let view: DockProgressView
        if let existing = dockProgressView {
            view = existing
        } else {
            view = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            tile.contentView = view
            dockProgressView = view
        }
        view.fraction = fraction
        tile.badgeLabel = "\(activeCount)"
        tile.display()
    }

    private final class DockProgressView: NSView {
        var fraction: Double = 0 {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            NSApp.applicationIconImage.draw(in: bounds)
            let barRect = NSRect(
                x: bounds.width * 0.16,
                y: bounds.height * 0.10,
                width: bounds.width * 0.68,
                height: bounds.height * 0.09
            )
            let track = NSBezierPath(roundedRect: barRect, xRadius: barRect.height / 2, yRadius: barRect.height / 2)
            NSColor.white.withAlphaComponent(0.9).setFill()
            track.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            track.stroke()
            var fillRect = barRect.insetBy(dx: 1.5, dy: 1.5)
            fillRect.size.width = max(fillRect.height, fillRect.width * CGFloat(min(1, max(0, fraction))))
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: fillRect.height / 2, yRadius: fillRect.height / 2)
            NSColor.controlAccentColor.setFill()
            fill.fill()
        }
    }

    @objc private func showMain() {
        mainWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentOnboarding() {
        let wc = OnboardingWindowController()
        wc.onInstallExtension = { [weak self] in
            self?.showBrowsers()
        }
        wc.onStartTestDownload = { [weak self] url in
            self?.mainWindow?.addAndStart(urlString: url)
        }
        wc.onFinished = { [weak self] in
            guard let self else { return }
            self.settings.onboardingCompleted = true
            SettingsStore.save(self.settings)
            Task { await self.manager?.updateSettings(self.settings) }
            self.onboardingWindow = nil
        }
        onboardingWindow = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func newDownload() {
        mainWindow?.showWindow(nil)
        mainWindow?.promptNewURL()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showBrowsers() {
        let wc = BrowsersWindowController(bridgeRunning: bridge != nil)
        browsersWindow = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = L10n.appName
        alert.informativeText = L10n.aboutBody(
            dataPath: "~/Library/Application Support/dev.ndm.open",
            bridge: "ws://127.0.0.1:\(BridgeConstants.port)/download"
        )
        alert.runModal()
    }

    @objc private func openSettings() {
        mainWindow?.showWindow(nil)
        Task { @MainActor in
            guard let manager else { return }
            let settings = await manager.currentSettings()
            if let existing = settingsWindow {
                existing.showWindow(nil)
                return
            }
            let wc = SettingsWindowController(manager: manager, settings: settings)
            settingsWindow = wc
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func menuStart() { mainWindow?.menuStartSelected() }
    @objc private func menuPause() { mainWindow?.menuPauseSelected() }
    @objc private func menuDelete() { mainWindow?.menuDeleteSelected() }
    @objc private func menuProgress() { mainWindow?.menuShowProgressSelected() }
    @objc private func menuProperties() { mainWindow?.menuShowPropertiesSelected() }
    @objc private func menuCopyURL() { mainWindow?.menuCopyURLSelected() }

    private func presentCompletion(for task: DownloadTask) {
        Task { await mainWindow?.reload() }
        guard settings.showCompletionDialog else { return }

        // Progress window already open → complete in place. A modal alert would
        // freeze that window and make Close look broken.
        if mainWindow?.presentCompletionInProgressWindow(for: task) == true {
            return
        }

        let wc = CompletionWindowController(task: task) { [weak self] in
            self?.completionWindow = nil
        }
        completionWindow = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// "SwiftUI Masterclass · Week 3" + "1080p" → a safe media filename.
    static func mediaFilename(pageTitle: String, qualityLabel: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = pageTitle
            .components(separatedBy: unsafe)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "video" : String(cleaned.prefix(120))
        return "\(base) (\(qualityLabel)).mp4"
    }

    /// One task row in the menu bar mini panel: name · percent/ETA · thin bar.
    @MainActor
    private final class MenuBarTaskRowView: NSView {
        init(name: String, detail: String, fraction: Double) {
            super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            nameLabel.lineBreakMode = .byTruncatingMiddle
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.alignment = .right
            detailLabel.setContentHuggingPriority(.required, for: .horizontal)
            let bar = NSProgressIndicator()
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = fraction
            bar.controlSize = .small
            bar.style = .bar
            for view in [nameLabel, detailLabel, bar] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
                heightAnchor.constraint(equalToConstant: 44),
                nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                detailLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
                detailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 10),
                detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                bar.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
                bar.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: detailLabel.trailingAnchor),
                bar.heightAnchor.constraint(equalToConstant: 4),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func mouseUp(with event: NSEvent) {
            if let item = enclosingMenuItem, let menu = item.menu {
                menu.cancelTracking()
                _ = item.target?.perform(item.action, with: item)
            }
        }
    }

    private func handleBrowserDownloadRequest(_ msg: ParsedBridgeMessage) async {
        guard let manager else { return }
        bridge?.sendToAllClients(BridgeConstants.waiting)
        defer { bridge?.sendToAllClients(BridgeConstants.noWaiting) }

        var accepted = msg
        if settings.confirmBrowserDownloads {
            let decision = await withCheckedContinuation { (cont: CheckedContinuation<WaitWindowController.Result, Never>) in
                let wc = WaitWindowController(message: msg) { result in
                    cont.resume(returning: result)
                }
                self.waitWindow = wc
                wc.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            waitWindow = nil
            switch decision {
            case .cancel:
                return
            case .download(let url):
                accepted.url = url
            }
        }

        // HLS master with several renditions → the quality picker decides,
        // not "highest bandwidth silently wins". Any probe failure falls through.
        if accepted.ltype.lowercased() == "hls" || accepted.url.lowercased().contains(".m3u8") {
            var probeHeaders: [String: String] = [:]
            if !accepted.referer.isEmpty { probeHeaders["Referer"] = accepted.referer }
            if !accepted.origin.isEmpty { probeHeaders["Origin"] = accepted.origin }
            if !accepted.cookies.isEmpty { probeHeaders["Cookie"] = accepted.cookies }
            if let probe = await HLSMasterProbe.probe(
                urlString: accepted.url,
                headers: probeHeaders,
                userAgent: accepted.userAgent.isEmpty ? nil : accepted.userAgent
            ) {
                let title = accepted.pageTitle.isEmpty ? accepted.filename : accepted.pageTitle
                switch await QualityPickerWindowController.choose(probe: probe, title: title) {
                case .cancel:
                    return
                case .download(let option):
                    if let resolved = HLSPlaylist.resolveURL(option.variant.uri, against: probe.masterURL) {
                        accepted.url = resolved.absoluteString
                        accepted.ltype = "hls"
                        if accepted.filename.isEmpty, !accepted.pageTitle.isEmpty {
                            accepted.filename = Self.mediaFilename(
                                pageTitle: accepted.pageTitle,
                                qualityLabel: option.label
                            )
                        }
                    }
                }
            }
        }

        do {
            let task = try await manager.addFromBridge(accepted)
            // Show progress first so capture → window is immediate.
            mainWindow?.showProgress(for: task.id)
            try await manager.start(taskID: task.id)
            await mainWindow?.reload()
        } catch {
            NSLog("handleBrowserDownloadRequest failed: \(error.localizedDescription)")
            let diag = DownloadDiagnostic.classify(error)
            let alert = NSAlert()
            alert.messageText = diag.title
            alert.informativeText = "\(diag.message)\n(\(diag.rawLabel))"
            alert.runModal()
        }
    }
}
