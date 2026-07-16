import AppKit
import NDMCore
import NDMEngine
import NDMBridge

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?
    private var statusItem: NSStatusItem?
    private var statusSummaryItem: NSMenuItem?
    private var manager: DownloadManager?
    private var bridge: BrowserBridge?
    private var settings = SettingsStore.load()
    private var waitWindow: WaitWindowController?
    private var browsersWindow: BrowsersWindowController?
    private var settingsWindow: SettingsWindowController?
    private var completionWindow: CompletionWindowController?
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
        rebuildStatusItemMenu()
    }

    private func rebuildStatusItemMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let summary = NSMenuItem(title: L10n.idle, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        statusSummaryItem = summary
        menu.addItem(.separator())
        func addItem(_ title: String, action: Selector, symbol: String) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.ndmSymbol(symbol)
            menu.addItem(menuItem)
        }
        addItem(L10n.showMainWindow, action: #selector(showMain), symbol: "macwindow")
        addItem(L10n.newDownloadEllipsis, action: #selector(newDownload), symbol: "plus.circle")
        addItem(L10n.browserExtensionEllipsis, action: #selector(showBrowsers), symbol: "globe")
        addItem(L10n.settingsEllipsis, action: #selector(openSettings), symbol: "gearshape")
        addItem(L10n.aboutNDM, action: #selector(showAbout), symbol: "info.circle")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        quit.ndmSymbol("power")
        menu.addItem(quit)
        item.menu = menu
        refreshStatusItem()
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
        if activeCount == 0 {
            statusItem?.button?.title = L10n.appName
            statusSummaryItem?.title = bridge == nil ? L10n.idleBridgeOff : L10n.idle
            return
        }
        let speedText: String
        if bytesPerSecond > 0 {
            speedText = TaskPresentationFormatting.speed(bytesPerSecond, status: .downloading)
        } else {
            speedText = "…"
        }
        statusItem?.button?.title = "\(L10n.appName) \(activeCount)"
        statusSummaryItem?.title = L10n.activeSummary(activeCount, speedText)
    }

    @objc private func showMain() {
        mainWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        do {
            let task = try await manager.addFromBridge(accepted)
            // Show progress first so capture → window is immediate.
            mainWindow?.showProgress(for: task.id)
            try await manager.start(taskID: task.id)
            await mainWindow?.reload()
        } catch {
            NSLog("handleBrowserDownloadRequest failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = L10n.downloadFailed
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
