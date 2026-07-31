import AppKit
import NDMCore
import NDMEngine
import NDMBridge

@MainActor
private final class BrowserMediaPreparationCancellation {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?
    private var statusItem: NSStatusItem?
    private var statusSummaryItem: NSMenuItem?
    private var statusTasksSeparator: NSMenuItem?
    private var statusTaskItems: [NSMenuItem] = []
    private var statusPauseAllItem: NSMenuItem?
    private var manager: DownloadManager?
    private var siteCompatibilityUpdater: SiteCompatibilityUpdater?
    private var bridge: BrowserBridge?
    private var settings: AppSettings = {
        var value = SettingsStore.load()
        QAPreviewOverrides.apply(to: &value)
        return value
    }()
    private var waitWindow: WaitWindowController?
    /// The in-flight browser media preparation, so a newer "download with NDM"
    /// can supersede a picker/probe still waiting on the previous capture.
    private var currentBrowserMediaCancellation: BrowserMediaPreparationCancellation?
    private var browsersWindow: BrowsersWindowController?
    private var aboutWindow: AboutWindowController?
    private var settingsWindow: SettingsWindowController?
    /// Standalone results can overlap when several app-initiated downloads
    /// finish together. Keep every controller alive until its own window
    /// closes; a single slot made earlier results disappear or lose callbacks.
    private var completionWindows: [Int64: CompletionWindowController] = [:]
    private var completionWindowOrder: [Int64] = []
    private var onboardingWindow: OnboardingWindowController?
    private var terminationCheckInFlight = false
    private var statusPollTask: Task<Void, Never>?
    private var lastPasteboardChangeCount = -1
    private var languageRebuildScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Focus rings answer "where will my next keystroke go". Someone who just
        // clicked already knows; someone tabbing has no other way to find out.
        FocusRingPolicy.install()
        L10n.apply(settings.languageMode)
        AppearanceApplicator.apply(settings.appearanceMode)
        NDMChrome.applyAccentTheme(settings.accentTheme, customHex: settings.customAccentHex)
        NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on OperationQueue.main → already on the main thread.
            MainActor.assumeIsolated {
                self?.scheduleLocalizedMenuRebuild()
            }
        }
        do {
            let support = QAPreviewOverrides.supportDirectory
                ?? DownloadStore.defaultSupportDirectory
            CoverArtCache.shared.configure(supportRoot: support)
            let store = try DownloadStore(directory: support)
            // Engines are process-local. Reconcile stale runtime states before
            // the first list render so a crashed download cannot trigger a
            // perpetual one-second structural refresh after relaunch.
            try store.recoverInterruptedTasks()
            try QAPreviewOverrides.seedPreviewTasks(in: store)
            settings.bridgePort = QAPreviewOverrides.bridgePort
                ?? BridgeConstants.port
            let manager = DownloadManager(
                store: store,
                settings: settings,
                supportRoot: support,
                fileRecycler: { url in
                    try await AppFileRecycler.recycle(url)
                },
                onTaskCompleted: { [weak self] task in
                    Task { @MainActor in
                        self?.presentCompletion(for: task)
                    }
                }
            )
            self.manager = manager
            // Keep tool resolution and the updater on the same root, so a
            // refreshed yt-dlp is found in QA-isolated runs too.
            YtDlpTool.siteCompatibilitySupportRoot = support
            let siteCompatibilityUpdater = SiteCompatibilityUpdater.configured(supportRoot: support)
            self.siteCompatibilityUpdater = siteCompatibilityUpdater
            if let siteCompatibilityUpdater {
                Task { await siteCompatibilityUpdater.refreshIfNeeded() }
            }

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
                // Not fatal and not worth interrupting launch: the app runs fine
                // without the bridge, and the Browsers window already shows a
                // persistent "bridge unavailable · port busy" status.
                self.bridge = nil
                NSLog("Browser bridge unavailable on port %d: %@",
                      Int(settings.bridgePort), error.localizedDescription)
            }

            if let bridge = self.bridge {
                Task { [weak self, manager, bridge] in
                    await manager.setSettingsChangedHandler { [weak self] next in
                        Task { @MainActor in
                            var effective = next
                            QAPreviewOverrides.apply(to: &effective)
                            self?.settings = effective
                            AppearanceApplicator.apply(effective.appearanceMode)
                            NDMChrome.applyAccentTheme(effective.accentTheme, customHex: effective.customAccentHex)
                            L10n.apply(effective.languageMode)
                            self?.refreshClipboardOfferFromPasteboard()
                            for msg in BridgeConstants.showPanelMessages(enabled: effective.showBrowserMediaPanel) {
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
                            var effective = next
                            QAPreviewOverrides.apply(to: &effective)
                            self?.settings = effective
                            AppearanceApplicator.apply(effective.appearanceMode)
                            NDMChrome.applyAccentTheme(effective.accentTheme, customHex: effective.customAccentHex)
                            L10n.apply(effective.languageMode)
                            self?.refreshClipboardOfferFromPasteboard()
                        }
                    }
                }
            }

            let window = MainWindowController(manager: manager)
            window.onOpenSettings = { [weak self] in
                self?.openSettings()
            }
            window.showWindow(nil)
            mainWindow = window
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshClipboardOfferFromPasteboard()
                }
            }
            refreshClipboardOfferFromPasteboard()
            Task { await manager.resumeQueuedCollectionIfIdle() }

            setupMainMenu()
            NSApp.activate(ignoringOtherApps: true)

            // Dev/screenshot escape hatch — Design Suite comparison needs a clean main window.
            if ProcessInfo.processInfo.environment["NDM_SKIP_ONBOARDING"] == "1" {
                settings.onboardingCompleted = true
                if !QAPreviewOverrides.isEnabled {
                    SettingsStore.save(settings)
                }
            }
            if settings.needsOnboarding || QAPreviewOverrides.showOnboarding {
                presentOnboarding()
            }
            if QAPreviewOverrides.showUpgrade {
                DispatchQueue.main.async {
                    UpgradeWindowController.present(features: QAPreviewOverrides.upgradeFeatures)
                }
            }
            if QAPreviewOverrides.showCompletion,
               let task = try? store.allDownloads().first(where: {
                   $0.pageURL?.contains("bilibili.com/video/BV1Preview") == true
               }) {
                DispatchQueue.main.async { [weak self] in
                    self?.presentCompletion(for: task)
                }
            }
            if let renderPath = QAPreviewOverrides.renderToPath {
                // Give the window one full layout + a beat for async covers, then
                // draw it offscreen and quit. No display server involvement.
                // Long enough for async cover art to land; a render that catches
                // the loading state documents the loading state, not the design.
                let settle = ProcessInfo.processInfo.environment["NDM_QA_RENDER_DELAY"]
                    .flatMap(Double.init) ?? 5.0
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    QAWindowRenderer.renderMainWindow(to: renderPath)
                    NSApp.terminate(nil)
                }
            }
            if QAPreviewOverrides.showAbout {
                DispatchQueue.main.async { [weak self] in
                    self?.showAbout()
                }
            }
            if QAPreviewOverrides.showMediaAccess {
                Task { @MainActor [weak self] in
                    _ = await MediaAccessPrompt.choose(
                        pageURL: QAPreviewOverrides.mediaAccessURL,
                        parentWindow: self?.mainWindow?.window
                    )
                }
            }
            if QAPreviewOverrides.showSettings {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.presentSettings(manager: manager, settings: self.settings)
                }
            }
            if QAPreviewOverrides.showNewDownload {
                DispatchQueue.main.async { [weak self] in
                    self?.mainWindow?.promptNewURLWithPrefill(QAPreviewOverrides.clipboardText)
                }
            }
            if QAPreviewOverrides.showMediaPreparation {
                DispatchQueue.main.async { [weak self] in
                    _ = WorkingPanelController.schedule(
                        stage: .readingMedia,
                        on: self?.mainWindow?.window,
                        delayNanoseconds: 0,
                        onCancel: {}
                    )
                }
            }

            // Defer status item past the first event-loop turn. Creating
            // NSStatusItem synchronously during didFinishLaunching races
            // MenuBarClientCore's executor checks on macOS 26/27 (0x7c8).
            DispatchQueue.main.async { [weak self] in
                self?.setupStatusItem()
                self?.startStatusPolling()
            }

        } catch {
            // No window exists yet, so this one is legitimately app-modal.
            NDMDialog.runModal(
                title: L10n.failedToStart,
                body: error.localizedDescription,
                subject: .failure
            )
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
                // Synchronous on purpose: AppKit is waiting on the reply below.
                shouldTerminate = NDMDialog.runModal(
                    title: L10n.downloadsInProgress,
                    body: L10n.quitWithActiveBody,
                    subject: .caution,
                    buttons: [
                        NDMDialog.Button(L10n.quit, isDestructive: true),
                        NDMDialog.Button(L10n.cancel, isCancel: true),
                    ]
                ).buttonIndex == 0
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

    /// Reads only the current pasteboard text, only after activation/settings
    /// changes, and only once per changeCount. Nothing is uploaded or retained.
    private func refreshClipboardOfferFromPasteboard() {
        guard settings.clipboardWatchEnabled else {
            // Re-enabling should reconsider the current clipboard immediately.
            lastPasteboardChangeCount = -1
            mainWindow?.clearClipboardOffer()
            return
        }
        if let qaText = QAPreviewOverrides.clipboardText {
            _ = mainWindow?.offerClipboardText(qaText)
            return
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount
        guard let raw = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            mainWindow?.clearClipboardOffer()
            return
        }
        _ = mainWindow?.offerClipboardText(raw)
    }

    /// Live language switch is driven from the Settings language popup.
    /// Reassigning `NSApp.mainMenu` / the status menu while that popup's menu
    /// tracking is still unwinding re-enters MenuBarClientCore and traps in
    /// SerialExecutor.isMainExecutor (0x7c8) on macOS 26/27. Defer the rebuild
    /// to a clean runloop turn, past menu-tracking teardown, and coalesce
    /// rapid switches into one rebuild.
    private func scheduleLocalizedMenuRebuild() {
        guard !languageRebuildScheduled else { return }
        languageRebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.languageRebuildScheduled = false
            self.setupMainMenu()
            self.rebuildStatusItemMenu()
            Task { @MainActor [weak self] in
                await self?.mainWindow?.reload()
            }
        }
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
        add(fileMenu, L10n.quickLook, #selector(menuQuickLook), "y", symbol: "eye")
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
        editMenu.addItem(.separator())
        let find = NSMenuItem(title: L10n.search, action: #selector(menuFocusSearch), keyEquivalent: "f")
        find.target = self
        find.ndmSymbol("magnifyingglass")
        editMenu.addItem(find)
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L10n.viewMenu)
        let zoomIn = NSMenuItem(title: L10n.zoomIn, action: #selector(zoomInInterface), keyEquivalent: "+")
        zoomIn.target = self
        zoomIn.ndmSymbol("plus.magnifyingglass")
        let zoomOut = NSMenuItem(title: L10n.zoomOut, action: #selector(zoomOutInterface), keyEquivalent: "-")
        zoomOut.target = self
        zoomOut.ndmSymbol("minus.magnifyingglass")
        let actual = NSMenuItem(title: L10n.actualSize, action: #selector(resetInterfaceScale), keyEquivalent: "0")
        actual.target = self
        actual.ndmSymbol("1.magnifyingglass")
        viewMenu.addItem(zoomIn)
        viewMenu.addItem(zoomOut)
        viewMenu.addItem(actual)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.windowMenu)
        // ⌘0 is Actual Size (View); show main window without stealing that chord.
        let showMain = NSMenuItem(title: L10n.showMainWindow, action: #selector(showMain), keyEquivalent: "")
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
            if let text = pasteboard.string(forType: .string),
               let resolution = SharedLinkResolver.resolve(text) {
                onDropURL?(resolution.urlString)
                return true
            }
            return false
        }
    }

    private func rebuildStatusItemMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        // Do not set `menu.delegate` to this `@MainActor` object (or any MainActor
        // closure). MenuBarClientCore on macOS 26/27 can trap in
        // SerialExecutor.isMainExecutor (0x7c8) when entering that thunk.
        // Status polling keeps the menu title/rows fresh instead.
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

    @objc private func showUpgrade() {
        UpgradeWindowController.present { [weak self] in
            self?.rebuildStatusItemMenu()
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
            NDMChrome.accent.setFill()
            fill.fill()
        }
    }

    @objc private func zoomInInterface() {
        InterfaceScale.zoomIn()
    }

    @objc private func zoomOutInterface() {
        InterfaceScale.zoomOut()
    }

    @objc private func resetInterfaceScale() {
        InterfaceScale.reset()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomInInterface):
            return InterfaceScale.canZoomIn
        case #selector(zoomOutInterface):
            return InterfaceScale.canZoomOut
        case #selector(resetInterfaceScale):
            return !InterfaceScale.isDefault
        case #selector(menuDelete):
            return !isEditingText && NSApp.keyWindow?.sheetParent == nil
        default:
            return true
        }
    }

    /// Text editing and attached sheets own ⌘Delete. The File-menu shortcut
    /// must never reach the selected download behind the active field editor.
    private var isEditingText: Bool {
        guard let window = NSApp.keyWindow else { return false }
        if window.sheetParent != nil { return true }
        return window.firstResponder is NSTextView
            || window.firstResponder is NSTextField
    }

    @objc private func showMain() {
        mainWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentOnboarding() {
        let wc = OnboardingWindowController()
        wc.onTryLink = { [weak self] text in
            guard let self else { return }
            self.mainWindow?.showWindow(nil)
            self.mainWindow?.promptNewURLWithPrefill(text)
            NSApp.activate(ignoringOtherApps: true)
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
        if let existing = aboutWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let wc = AboutWindowController(
            dataPath: "~/Library/Application Support/dev.ndm.open",
            bridgeEndpoint: BridgeConstants.endpoint
        )
        aboutWindow = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        mainWindow?.showWindow(nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let manager else { return }
            let settings = await manager.currentSettings()
            if let existing = settingsWindow {
                existing.showWindow(nil)
                existing.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            presentSettings(manager: manager, settings: settings)
        }
    }

    private func presentSettings(manager: DownloadManager, settings: AppSettings) {
        if let existing = settingsWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let wc = SettingsWindowController(
            manager: manager,
            settings: settings,
            siteCompatibilityUpdater: siteCompatibilityUpdater,
            initialSectionName: QAPreviewOverrides.settingsSection
        )
        settingsWindow = wc
        wc.onWindowClose = { [weak self, weak wc] in
            guard let self else { return }
            if self.settingsWindow === wc { self.settingsWindow = nil }
        }
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func menuStart() { mainWindow?.menuStartSelected() }
    @objc private func menuPause() { mainWindow?.menuPauseSelected() }
    @objc private func menuFocusSearch() { mainWindow?.menuFocusSearch() }
    @objc private func menuDelete() {
        guard !isEditingText else { return }
        mainWindow?.menuDeleteSelected()
    }
    @objc private func menuProgress() { mainWindow?.menuShowProgressSelected() }
    @objc private func menuProperties() { mainWindow?.menuShowPropertiesSelected() }
    @objc private func menuCopyURL() { mainWindow?.menuCopyURLSelected() }
    @objc private func menuQuickLook() { mainWindow?.menuQuickLookSelected() }

    private func presentCompletion(for task: DownloadTask) {
        Task { await mainWindow?.reload() }
        guard settings.showCompletionDialog else { return }

        // Progress window already open → complete in place. A modal alert would
        // freeze that window and make Close look broken. This includes the
        // browser's quiet session card, so do not bounce the Dock or activate
        // the app before giving the in-place handoff a chance.
        if mainWindow?.presentCompletionInProgressWindow(for: task) == true {
            return
        }

        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }

        // A completed task can be retried while its old result is still open.
        // Replace only that task's stale result; never disturb other files.
        completionWindows[task.id]?.window?.close()

        weak var weakController: CompletionWindowController?
        let wc = CompletionWindowController(task: task) { [weak self] in
            guard let self else { return }
            if self.completionWindows[task.id] === weakController {
                self.completionWindows.removeValue(forKey: task.id)
                self.completionWindowOrder.removeAll { $0 == task.id }
            }
        }
        weakController = wc
        positionStandaloneCompletionWindow(wc.window)
        completionWindows[task.id] = wc
        completionWindowOrder.removeAll { $0 == task.id }
        completionWindowOrder.append(task.id)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Preserve the centered first result, then use a restrained native-style
    /// cascade so simultaneous completions remain individually reachable
    /// instead of occupying the exact same pixels.
    private func positionStandaloneCompletionWindow(_ window: NSWindow?) {
        guard let window, !completionWindowOrder.isEmpty else { return }
        let previous = completionWindowOrder.reversed().compactMap {
            completionWindows[$0]?.window
        }.first { $0.isVisible }
        guard let previous else { return }

        var frame = window.frame
        frame.origin.x = previous.frame.minX + 24
        frame.origin.y = previous.frame.minY - 24
        let visible = previous.screen?.visibleFrame
            ?? window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        if let visible {
            if frame.maxX > visible.maxX - 12 {
                frame.origin.x = max(visible.minX + 12, previous.frame.minX - 24)
            }
            if frame.minY < visible.minY + 12 {
                frame.origin.y = min(
                    visible.maxY - frame.height - 12,
                    previous.frame.minY + 24
                )
            }
        }
        window.setFrame(frame, display: false)
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
        // The user just clicked "download with NDM" in their browser. Keep the
        // library window where it is; only the lightweight session card will
        // appear once the task is accepted.
        supersedeInFlightBrowserMedia()
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

        // Prefer yt-dlp for media sniffs whose PAGE is a site yt-dlp maintains
        // an extractor for (YouTube, X, Bilibili, Douyin, TikTok, …). Do not
        // rewrite ordinary file captures — resource-shelf rows and direct
        // .dmg/.pdf/.zip links must keep their own URL even on those sites.
        if YtDlpTool.isAvailable,
           !accepted.pageURL.isEmpty,
           SharedLinkResolver.source(forURLString: accepted.pageURL) != .web,
           MediaLinkClassifier.shouldPreferPageResolver(
               url: accepted.url,
               ltype: accepted.ltype,
               pageURL: accepted.pageURL
           ) {
            var viaPage = accepted
            viaPage.url = accepted.pageURL
            viaPage.ltype = "media-page"
            _ = await handleBrowserMediaPage(viaPage, manager: manager)
            return
        }

        // A site-integrated action sends a canonical video page URL rather
        // than one of the many short-lived MP4/TS requests observed by the
        // browser. Resolve it through the same quality flow as a pasted link;
        // treating the page itself as an ordinary file was the old bug.
        if accepted.ltype.lowercased() == "media-page",
           MediaLinkClassifier.looksLikeMediaPage(accepted.url) {
            _ = await handleBrowserMediaPage(accepted, manager: manager)
            return
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
            mainWindow?.showProgress(for: task.id, quietly: true)
            try await manager.start(taskID: task.id)
            await mainWindow?.reload()
        } catch {
            NSLog("handleBrowserDownloadRequest failed: \(error.localizedDescription)")
            let diag = DownloadDiagnostic.classify(error)
            NDMDialog.present(
                title: diag.title,
                body: "\(diag.message)\n(\(diag.rawLabel))",
                subject: .failure,
                host: mainWindow?.window
            )
        }
    }

    /// Resolves canonical X/YouTube (and other yt-dlp-supported) pages sent by
    /// NDM Relay. A return means the request was consumed, including cancel.
    /// Cancel a browser media probe still running and close any quality picker
    /// still waiting, so the newest capture wins.
    private func supersedeInFlightBrowserMedia() {
        currentBrowserMediaCancellation?.cancel()
        currentBrowserMediaCancellation = nil
        YtDlpQualityPickerWindowController.dismissActive()
        QualityPickerWindowController.dismissActive()
    }

    private func handleBrowserMediaPage(
        _ message: ParsedBridgeMessage,
        manager: DownloadManager
    ) async -> Bool {
        guard YtDlpTool.isAvailable else {
            showBrowserMediaAlert(
                message: L10n.advancedVideo,
                detail: L10n.ytdlpMissingHint
            )
            return true
        }

        let cancellation = BrowserMediaPreparationCancellation()
        currentBrowserMediaCancellation = cancellation
        var working: WorkingPanelController? = WorkingPanelController.schedule(
            stage: .readingMedia,
            on: mainWindow?.window,
            onCancel: { cancellation.cancel() }
        )
        var mediaURL = message.url
        var probe: YtDlpProbe?
        var collection: YtDlpCollectionProbe?
        var cookieSource: YtDlpCookieSource?

        while probe == nil {
            do {
                if let cookieSource {
                    probe = try await YtDlpTool.probe(
                        url: mediaURL,
                        cookieSource: cookieSource
                    )
                } else {
                    let prepared = try await MediaPreflightStore.shared.result(for: message.url)
                    mediaURL = prepared.mediaURL
                    probe = prepared.probe
                    collection = prepared.collection
                }
                guard !cancellation.isCancelled else {
                    working?.dismiss()
                    return true
                }
                working?.update(stage: .preparingOptions)
            } catch {
                guard !cancellation.isCancelled else {
                    working?.dismiss()
                    return true
                }
                working?.dismiss()
                working = nil
                guard YtDlpTool.accessIssue(error: error) != nil else {
                    NSLog("Browser media recognition failed for %@: %@", message.url, error.localizedDescription)
                    showBrowserMediaAlert(
                        message: L10n.mediaRecognitionFailed,
                        detail: L10n.mediaRecognitionFailedBody
                    )
                    return true
                }
                let previousSource = cookieSource
                guard let selected = await MediaAccessPrompt.choose(
                    pageURL: mediaURL,
                    parentWindow: mainWindow?.window,
                    previousSource: previousSource,
                    retrying: previousSource != nil
                ) else {
                    return true
                }
                cookieSource = selected
                working = WorkingPanelController.schedule(
                    stage: .readingMedia,
                    on: mainWindow?.window,
                    onCancel: { cancellation.cancel() }
                )
            }
        }

        working?.dismiss()
        guard !cancellation.isCancelled, let probe else { return true }
        guard !probe.formats.isEmpty else {
            showBrowserMediaAlert(
                message: L10n.mediaRecognitionFailed,
                detail: L10n.mediaRecognitionFailedBody
            )
            return true
        }

        let currentSettings = await manager.currentSettings()
        // Honor the global quality preference: highest / up-to-cap auto-picks
        // and skips the sheet; only "ask" (or a cap with nothing matching)
        // opens the picker.
        let choice: YtDlpQualityPickerWindowController.Choice
        if collection == nil,
           let index = currentSettings.mediaQualityPreference.autoSelectIndex(
               heights: probe.formats.map(\.height)),
           probe.formats.indices.contains(index) {
            working?.dismiss()
            choice = .download(
                probe.formats[index],
                YtDlpDownloadOptions(container: .compatibleMP4, subtitleLanguage: nil),
                .single
            )
        } else {
            choice = await YtDlpQualityPickerWindowController.choose(
                url: mediaURL,
                probe: probe,
                collection: collection,
                cookieSource: cookieSource,
                destinationDirectory: currentSettings.downloadDirectory,
                parentWindow: mainWindow?.window
            )
        }
        do {
            switch choice {
            case .cancel:
                return true
            case .download(let picked, let options, let scope):
                switch scope {
                case .single:
                    let task = try await manager.startYtDlp(
                        url: mediaURL,
                        formatID: picked.selector(for: options.container),
                        options: options,
                        pageTitle: probe.title.isEmpty ? nil : probe.title,
                        estimatedBytes: picked.estimatedBytes(for: options.container),
                        estimatedComponentBytes: picked.estimatedComponentBytes(for: options.container),
                        preferredFilename: probe.title.isEmpty ? nil : probe.title
                    )
                    if let thumbnail = probe.thumbnailURL {
                        CoverArtCache.shared.prefetchRemote(
                            taskID: task.id,
                            urlString: thumbnail
                        )
                    }
                    await mainWindow?.reload()
                    mainWindow?.showProgress(for: task.id, quietly: true)
                case .collection(let selectedCollection):
                    let tasks = try await manager.enqueueYtDlpCollection(
                        selectedCollection.items,
                        formatID: picked.collectionSelector(for: options.container),
                        options: options,
                        collectionURL: message.url,
                        collectionTitle: selectedCollection.title.isEmpty ? nil : selectedCollection.title,
                        estimatedSampleBytes: picked.estimatedBytes(for: options.container),
                        estimatedSampleComponentBytes: picked.estimatedComponentBytes(for: options.container),
                        sampleDurationSeconds: probe.durationSeconds
                    )
                    for (task, item) in zip(tasks, selectedCollection.items) {
                        if let thumbnail = item.thumbnailURL {
                            CoverArtCache.shared.prefetchRemote(
                                taskID: task.id,
                                urlString: thumbnail
                            )
                        }
                    }
                    await mainWindow?.reload()
                    if let first = tasks.first {
                        mainWindow?.showProgress(for: first.id, quietly: true)
                    }
                }
            }
        } catch {
            let diagnostic = DownloadDiagnostic.classify(error)
            showBrowserMediaAlert(
                message: diagnostic.title,
                detail: "\(diagnostic.message)\n(\(diagnostic.rawLabel))"
            )
        }
        return true
    }

    private func showBrowserMediaAlert(message: String, detail: String) {
        NDMDialog.present(
            title: message,
            body: detail,
            subject: .caution,
            host: mainWindow?.window
        )
    }
}
