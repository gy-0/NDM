import AppKit
import NDMCore
import NDMEngine
import NDMBridge

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?
    private var statusItem: NSStatusItem?
    private var manager: DownloadManager?
    private var bridge: BrowserBridge?
    private var settings = SettingsStore.load()
    private var waitWindow: WaitWindowController?
    private var browsersWindow: BrowsersWindowController?
    private var terminationCheckInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                alert.messageText = "Browser bridge port \(settings.bridgePort) is in use"
                alert.informativeText = """
                Another app is already listening on 127.0.0.1:\(settings.bridgePort) \
                (usually the original Neat Download Manager).

                Quit that app, then restart NDM if you need BetterNDM.

                NDM will continue without the WebSocket bridge.
                \(error.localizedDescription)
                """
                alert.addButton(withTitle: "Continue Without Bridge")
                alert.addButton(withTitle: "Quit")
                if alert.runModal() != .alertFirstButtonReturn {
                    NSApp.terminate(nil)
                    return
                }
            }

            // Observe settings changes for ShowPanel push, then push initial state.
            if let bridge = self.bridge {
                Task { [weak self, manager, bridge] in
                    await manager.setSettingsChangedHandler { [weak self] next in
                        Task { @MainActor in
                            self?.settings = next
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
                        }
                    }
                }
            }

            let window = MainWindowController(manager: manager)
            window.showWindow(nil)
            mainWindow = window

            setupMainMenu()
            setupStatusItem()
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
            alert.messageText = "Failed to start NDM"
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
                alert.messageText = "Downloads in progress"
                alert.informativeText = "Quit and leave incomplete downloads? You can resume later from segments.bin."
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")
                shouldTerminate = alert.runModal() == .alertFirstButtonReturn
            }
            self.terminationCheckInFlight = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
    }

    /// SPM / pure AppKit apps do not get Xcode's default MainMenu.nib.
    /// Without Edit → Paste, ⌘V never reaches NSAlert / NSTextField first responders.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "About NDM", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit NDM",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newDownload = NSMenuItem(
            title: "New Download…",
            action: #selector(newDownload),
            keyEquivalent: "n"
        )
        newDownload.target = self
        fileMenu.addItem(newDownload)
        let browsers = NSMenuItem(
            title: "Browser Extension…",
            action: #selector(showBrowsers),
            keyEquivalent: "b"
        )
        browsers.target = self
        fileMenu.addItem(browsers)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // Leave target nil so Cut/Copy/Paste/Select All go to the first responder
        // (e.g. the New Download URL field inside an NSAlert).
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let showMain = NSMenuItem(
            title: "Show Main Window",
            action: #selector(showMain),
            keyEquivalent: "0"
        )
        showMain.keyEquivalentModifierMask = [.command]
        showMain.target = self
        windowMenu.addItem(showMain)
        windowMenu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "NDM"
        let menu = NSMenu()
        func addItem(_ title: String, action: Selector) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menu.addItem(menuItem)
        }
        addItem("Show Main Window", action: #selector(showMain))
        addItem("New Download…", action: #selector(newDownload))
        addItem("Browser Extension…", action: #selector(showBrowsers))
        addItem("Settings…", action: #selector(openSettings))
        addItem("About NDM", action: #selector(showAbout))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
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
        let wc = BrowsersWindowController()
        browsersWindow = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "NDM"
        alert.informativeText = """
        Clean-room open-source download manager.
        Behaviour aligned with Neat Download Manager 1.3 specs under reverse/.
        Bundle data: ~/Library/Application Support/dev.ndm.open
        Bridge: ws://127.0.0.1:10007/download (BetterNDM)
        """
        alert.runModal()
    }

    @objc private func openSettings() {
        mainWindow?.showWindow(nil)
        Task { @MainActor in
            if let manager {
                let settings = await manager.currentSettings()
                let wc = SettingsWindowController(manager: manager, settings: settings)
                wc.showWindow(nil)
            }
        }
    }

    private func presentCompletion(for task: DownloadTask) {
        guard settings.showCompletionDialog else { return }
        let alert = NSAlert()
        alert.messageText = "Download Complete"
        alert.informativeText = "\(task.filename) is ready."

        let fileURL = task.destinationFileURL
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Show in Finder")
        let closeButton = alert.addButton(withTitle: "Close")
        closeButton.keyEquivalent = "\u{1b}"

        let fileExists = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        alert.buttons[0].isEnabled = fileExists
        alert.buttons[1].isEnabled = fileExists

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let fileURL else { break }
            if !NSWorkspace.shared.open(fileURL) {
                let error = NSAlert()
                error.messageText = "Could Not Open Download"
                error.informativeText = "The file is available at \(fileURL.path)."
                error.addButton(withTitle: "Show in Finder")
                error.addButton(withTitle: "Close")
                if error.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
        case .alertSecondButtonReturn:
            if let fileURL {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        default:
            break
        }
        Task { await mainWindow?.reload() }
    }

    /// Mirrors `AppDelegate handleBrowserDownloadRequest:`.
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
            try await manager.start(taskID: task.id)
            await mainWindow?.reload()
            mainWindow?.showProgress(for: task.id)
        } catch {
            NSLog("handleBrowserDownloadRequest failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Download failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
