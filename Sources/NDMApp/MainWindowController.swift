import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import NDMCore
import NDMEngine

@MainActor
private final class MediaPreparationCancellation {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate,
    @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private let manager: DownloadManager
    private let siteCompatibilityUpdater: SiteCompatibilityUpdater?

    private var allTasks: [DownloadTask] = []
    private var progressByID: [Int64: DownloadProgress] = [:]
    private var displayedRows: [TaskRowPresentation] = []
    private var selectedFilter: SidebarFilter = .all
    private var searchQuery = ""
    private var selectedTaskID: Int64?

    private let splitController = NSSplitViewController()
    private let sidebarController = SidebarViewController()
    private let listController = TaskListViewController()
    private let inspectorController = InspectorViewController()
    private let fileSharePresenter = FileSharePresenter()

    private var progressWindows: [Int64: ProgressWindowController] = [:]
    private var settingsWindow: SettingsWindowController?
    private var propsWindow: TaskPropertiesWindowController?
    private var browsersWindow: BrowsersWindowController?
    private var refreshTask: Task<Void, Never>?
    private var previewedFileURL: URL?

    private var startToolbarItem: NSToolbarItem?
    private var pauseToolbarItem: NSToolbarItem?
    private let chromeRoot = NSViewController()
    private let contentToolbar = DesignSuiteToolbarView()
    private var clipboardOffer: SharedLinkResolution?

    init(
        manager: DownloadManager,
        siteCompatibilityUpdater: SiteCompatibilityUpdater? = nil
    ) {
        self.manager = manager
        self.siteCompatibilityUpdater = siteCompatibilityUpdater
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
        // AppKit measures windows in logical points, not Retina backing pixels.
        // 1440 × 960 keeps all three columns comfortably above their minimum
        // thickness (sidebar 215 + list 420 + inspector 360 = 995pt) on a
        // 1728 × 1117-class desktop while still leaving room for the window
        // boundary. The floor below matches `minSize` so the launch frame is
        // never smaller than what the sidebar needs to render fully.
        let preferredFrameSize = QAPreviewOverrides.windowSize
            ?? NSSize(width: 1440, height: 960)
        let initialFrameSize = NSSize(
            width: min(preferredFrameSize.width, max(1060, visible.width - 32)),
            height: min(preferredFrameSize.height, max(680, visible.height - 32))
        )
        let styleMask: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
        ]
        let initialFrame = NSRect(origin: .zero, size: initialFrameSize)
        let initialContentRect = NSWindow.contentRect(
            forFrameRect: initialFrame,
            styleMask: styleMask
        )
        let window = NSWindow(
            contentRect: initialContentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        // Keep the requested number as the outer window size. Passing it
        // directly as `contentRect` makes the actual window taller than asked.
        window.setFrame(initialFrame, display: false)
        window.title = L10n.appName
        // Must stay >= the sum of the split view's minimum thicknesses
        // (215 + 420 + 360 = 995pt, plus divider hairlines) so the sidebar
        // can never be squeezed to the point of clipping its content.
        window.minSize = NSSize(width: 1060, height: 680)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        NDMChrome.applyWindowChrome(window)
        window.center()
        super.init(window: window)
        // Design Suite: tool chips live in a content toolbar under the titlebar,
        // not as lonely icon-only NSToolbar items.
        installChromeRoot()
        configureSplit()
        // `contentViewController` assignment above resizes the window to the
        // Auto Layout content's *fitting* size (effectively its minimum,
        // since nothing pins an ideal width/height) — which silently collapses
        // the window to `minSize` before the split view even has its items.
        // Reassert the intended launch frame now that chrome + split items
        // exist, so the sidebar/list/inspector actually get their fair share
        // instead of opening crushed to their floor. Re-center too, since
        // restoring `initialFrame`'s zero origin would otherwise undo the
        // earlier `center()` and pin the window to the bottom-left corner.
        window.setFrame(initialFrame, display: false)
        window.center()
        // Design Suite has no icon NSToolbar — only the in-content tool strip.
        window.toolbar = nil
        wireCallbacks()
        wireContentToolbar()
        NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.relocalizeChrome()
            }
        }
        NotificationCenter.default.addObserver(
            forName: InterfaceScale.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyContentScale()
            }
        }
        applyContentScale()
        Task { await reload() }
        startAutoRefresh()
    }

    /// Refresh toolbar / inspector chrome after language switch.
    func relocalizeChrome() {
        window?.title = L10n.appName
        contentToolbar.relocalize()
        sidebarController.relocalizeChrome()
        if let toolbar = window?.toolbar {
            for item in toolbar.items {
                switch item.itemIdentifier {
                case .ndmNewDownload:
                    item.label = L10n.new
                    item.paletteLabel = L10n.newDownload
                    item.toolTip = L10n.newDownloadTooltip
                case .ndmStart:
                    item.label = L10n.start
                    item.paletteLabel = L10n.start
                    item.toolTip = L10n.startTooltip
                case .ndmPause:
                    item.label = L10n.pause
                    item.paletteLabel = L10n.pause
                    item.toolTip = L10n.pauseTooltip
                case .ndmSearch:
                    item.label = L10n.search
                    if let field = item.view as? NSSearchField {
                        field.placeholderString = L10n.searchDownloads
                    }
                case .ndmBrowsers:
                    item.label = L10n.browsers
                    item.paletteLabel = L10n.browsers
                    item.toolTip = L10n.browsersTooltip
                case .ndmSettings:
                    item.label = L10n.settings
                    item.paletteLabel = L10n.settings
                default:
                    break
                }
            }
        }
        listController.relocalizeChrome()
        inspectorController.relocalizeChrome()
        Task { await reload() }
    }

    private func applyContentScale() {
        let scale = InterfaceScale.current
        contentToolbar.setContentScale(scale)
        sidebarController.setContentScale(scale)
        listController.setContentScale(scale)
        inspectorController.setContentScale(scale)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func installChromeRoot() {
        let root = NSView()
        chromeRoot.view = root
        contentToolbar.translatesAutoresizingMaskIntoConstraints = false
        splitController.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentToolbar)
        chromeRoot.addChild(splitController)
        root.addSubview(splitController.view)
        // fullSizeContentView: pin tools below the titlebar (Design Suite order),
        // never under the traffic lights.
        NSLayoutConstraint.activate([
            contentToolbar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            contentToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentToolbar.heightAnchor.constraint(equalToConstant: 62),
            splitController.view.topAnchor.constraint(equalTo: contentToolbar.bottomAnchor),
            splitController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentViewController = chromeRoot
    }

    private func wireContentToolbar() {
        contentToolbar.onNew = { [weak self] in self?.promptNewURL() }
        contentToolbar.onPause = { [weak self] in self?.pauseSelected() }
        contentToolbar.onResume = { [weak self] in self?.startSelected() }
        contentToolbar.onClipboardOffer = { [weak self] in
            self?.openClipboardOffer()
        }
        contentToolbar.onSearch = { [weak self] query in
            self?.searchQuery = query
            self?.rebuildDisplayedRows(preserveSelection: true)
        }
    }

    private func configureSplit() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        // Room for semantic zoom without turning the navigation into a squeeze.
        sidebarItem.minimumThickness = 215
        sidebarItem.maximumThickness = 268
        sidebarItem.preferredThicknessFraction = 0.175
        if #available(macOS 11.0, *) {
            sidebarItem.titlebarSeparatorStyle = .none
        }

        let listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = 420

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        // Full action labels (especially “Show in Finder”) need a real inspector,
        // not a narrow utility strip.
        inspectorItem.minimumThickness = 360
        inspectorItem.maximumThickness = 450
        inspectorItem.preferredThicknessFraction = 0.30
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = false
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(260)

        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(listItem)
        splitController.addSplitViewItem(inspectorItem)
        // Bumped so a previously-narrowed sidebar divider (saved before the
        // launch window was made larger) doesn't reappear crushed.
        splitController.splitView.autosaveName = "NDM.MainSplit.v8"
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "NDM.MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private func wireCallbacks() {
        sidebarController.onSelectFilter = { [weak self] filter in
            self?.selectedFilter = filter
            self?.rebuildDisplayedRows(preserveSelection: true)
        }
        listController.onSelectTaskID = { [weak self] taskID in
            self?.selectedTaskID = taskID
            self?.updateInspector()
            self?.updateToolbarEnablement()
        }
        listController.onActivateTaskID = { [weak self] taskID in
            self?.performPrimaryAction(for: taskID)
        }
        listController.onContextAction = { [weak self] action, taskID in
            self?.handleContextAction(action, taskID: taskID)
        }
        listController.onDropURL = { [weak self] url in
            self?.startURL(url)
        }
        inspectorController.onAction = { [weak self] action in
            guard let self, let id = self.selectedTaskID else { return }
            self.handleContextAction(action, taskID: id)
        }
        inspectorController.onShare = { [weak self] anchor in
            guard let self, let id = self.selectedTaskID else { return }
            self.shareTaskFile(id, from: anchor)
        }
        listController.onEmptyNewDownload = { [weak self] in
            self?.promptNewURL()
        }
    }

    // MARK: - Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .ndmNewDownload,
            .ndmStart,
            .ndmPause,
            .flexibleSpace,
            .ndmSearch,
            .ndmBrowsers,
            .ndmSettings,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .ndmNewDownload:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.new
            item.paletteLabel = L10n.newDownload
            item.toolTip = L10n.newDownloadTooltip
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.newDownload)
            item.target = self
            item.action = #selector(promptNewURL)
            return item
        case .ndmStart:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.start
            item.paletteLabel = L10n.start
            item.toolTip = L10n.startTooltip
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: L10n.start)
            item.target = self
            item.action = #selector(startSelected)
            startToolbarItem = item
            return item
        case .ndmPause:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.pause
            item.paletteLabel = L10n.pause
            item.toolTip = L10n.pauseTooltip
            item.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: L10n.pause)
            item.target = self
            item.action = #selector(pauseSelected)
            pauseToolbarItem = item
            return item
        case .ndmSearch:
            let field = NSSearchField()
            field.placeholderString = L10n.searchDownloads
            field.target = self
            field.action = #selector(searchChanged(_:))
            field.sendsSearchStringImmediately = true
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
            field.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.search
            item.view = field
            return item
        case .ndmBrowsers:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.browsers
            item.paletteLabel = L10n.browsers
            item.toolTip = L10n.browsersTooltip
            item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: L10n.browsers)
            item.target = self
            item.action = #selector(openBrowsers)
            return item
        case .ndmSettings:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.settings
            item.paletteLabel = L10n.settings
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.settings)
            item.target = self
            item.action = #selector(openSettings)
            return item
        default:
            return nil
        }
    }

    private func updateToolbarEnablement() {
        let actions = TaskSelectionActions.make(from: selectedRow())
        startToolbarItem?.isEnabled = actions.canStart
        pauseToolbarItem?.isEnabled = actions.canPause
        contentToolbar.setResumeEnabled(actions.canStart)
        contentToolbar.setPauseEnabled(actions.canPause)
    }

    // MARK: - Data

    func reload() async {
#if DEBUG
        let signpostID = NDMPerformance.begin("StructuralReload")
        defer { NDMPerformance.end("StructuralReload", id: signpostID) }
#endif
        do {
            allTasks = try await manager.listTasks()
            if let clipboardOffer,
               DuplicateDownloadMatcher.bestMatch(
                   for: [clipboardOffer.urlString],
                   in: allTasks
               ) != nil {
                clearClipboardOffer()
            }
            var nextProgress: [Int64: DownloadProgress] = [:]
            for task in allTasks where task.status == .downloading || task.status == .waiting {
                if let progress = await manager.progress(taskID: task.id) {
                    nextProgress[task.id] = progress
                }
            }
            // Keep last known progress for paused/error inspector segments when still useful.
            for (id, progress) in progressByID {
                if nextProgress[id] == nil,
                   let task = allTasks.first(where: { $0.id == id }),
                   task.status != .complete {
                    nextProgress[id] = progress
                }
            }
            progressByID = nextProgress
            sidebarController.update(counts: SidebarFilter.counts(in: allTasks), selected: selectedFilter)
            rebuildDisplayedRows(preserveSelection: true)
        } catch {
            showAlert(error)
        }
    }

    private func rebuildDisplayedRows(preserveSelection: Bool) {
#if DEBUG
        let signpostID = NDMPerformance.begin("PresentationRebuild")
        defer { NDMPerformance.end("PresentationRebuild", id: signpostID) }
#endif
        let filtered = TaskPresentationFormatting.filteredTasks(
            allTasks,
            filter: selectedFilter,
            search: searchQuery
        )
        displayedRows = filtered.map { task in
            TaskRowPresentation.make(task: task, progress: progressByID[task.id])
        }
        if preserveSelection, let selectedTaskID,
           displayedRows.contains(where: { $0.taskID == selectedTaskID }) {
            // keep
        } else if let first = displayedRows.first {
            selectedTaskID = first.taskID
        } else {
            selectedTaskID = nil
        }
        listController.update(
            rows: displayedRows,
            selectedTaskID: selectedTaskID,
            emptyTitle: emptyStateTitle(),
            emptySubtitle: emptyStateSubtitle(),
            // Action buttons only for the true first-run empty state,
            // not for empty filter/search results.
            emptyShowsActions: allTasks.isEmpty && searchQuery.isEmpty
        )
        updateInspector()
        updateToolbarEnablement()
    }

    private func emptyStateTitle() -> String {
        if allTasks.isEmpty {
            return L10n.emptyNoDownloads
        }
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.emptyNoMatches(searchQuery)
        }
        return L10n.emptyNoFilter(selectedFilter.title)
    }

    private func emptyStateSubtitle() -> String {
        if allTasks.isEmpty {
            return L10n.emptyDropHint
        }
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.emptyTrySearch
        }
        return L10n.emptyTryFilter
    }

    /// Snapshot for the menu-bar status item.
    func statusBarSnapshot() -> (activeCount: Int, bytesPerSecond: Double) {
        let active = allTasks.filter { $0.status == .downloading || $0.status == .waiting }
        let speed = active.reduce(0.0) { partial, task in
            partial + (progressByID[task.id]?.bytesPerSecond ?? 0)
        }
        return (active.count, speed)
    }

    /// Aggregate fraction across active downloads (Dock progress bar).
    func dockProgressSnapshot() -> Double {
        let active = allTasks.filter { $0.status == .downloading || $0.status == .waiting }
        var total: Int64 = 0
        var done: Int64 = 0
        for task in active {
            let progress = progressByID[task.id]
            let bytes = max(task.fileSize, progress?.totalBytes ?? 0)
            guard bytes > 0 else { continue }
            total += bytes
            let fraction = progress?.fractionCompleted ?? 0
            done += min(bytes, Int64((Double(bytes) * fraction).rounded(.down)))
        }
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    /// Per-task rows for the menu bar mini panel (active first, capped).
    struct MenuBarTask {
        var taskID: Int64
        var name: String
        var fraction: Double
        var detail: String
    }

    func menuBarTasks(limit: Int = 4) -> [MenuBarTask] {
        allTasks
            .filter { $0.status == .downloading || $0.status == .waiting }
            .sorted { a, b in
                // Downloading before queued, then most recent first.
                if (a.status == .downloading) != (b.status == .downloading) {
                    return a.status == .downloading
                }
                return a.id > b.id
            }
            .prefix(limit)
            .map { task in
                let progress = progressByID[task.id]
                let fraction = progress?.fractionCompleted ?? 0
                var parts: [String] = []
                if task.status == .waiting {
                    parts.append(L10n.queued)
                } else {
                    parts.append(TaskPresentationFormatting.percent(fraction))
                    let eta = TaskPresentationFormatting.eta(progress?.remainingTime, status: task.status)
                    if eta != L10n.emDash { parts.append(eta) }
                }
                return MenuBarTask(
                    taskID: task.id,
                    name: task.filename.isEmpty ? L10n.untitled : task.filename,
                    fraction: fraction,
                    detail: parts.joined(separator: " · ")
                )
            }
    }

    /// Pause every downloading/queued task (menu bar "Pause All").
    func pauseAllActive() {
        let ids = allTasks
            .filter { $0.status == .downloading || $0.status == .waiting }
            .map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            for id in ids {
                await manager.pause(taskID: id)
            }
            await reload()
        }
    }

    @objc func menuStartSelected() { startSelected() }
    @objc func menuPauseSelected() { pauseSelected() }
    @objc func menuFocusSearch() {
        window?.makeKeyAndOrderFront(nil)
        _ = contentToolbar.focusSearch()
    }
    @objc func menuDeleteSelected() {
        guard let id = selectedTaskID else { return }
        deleteTask(id)
    }
    @objc func menuShowProgressSelected() {
        guard let id = selectedTaskID else { return }
        showProgress(for: id)
    }
    @objc func menuShowPropertiesSelected() {
        guard let id = selectedTaskID else { return }
        showProperties(for: id)
    }
    @objc func menuQuickLookSelected() {
        guard let id = selectedTaskID else { return }
        toggleQuickLook(for: id)
    }
    @objc func menuCopyURLSelected() {
        guard let id = selectedTaskID,
              let url = allTasks.first(where: { $0.id == id })?.url,
              !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    private func selectedRow() -> TaskRowPresentation? {
        guard let selectedTaskID else { return nil }
        return displayedRows.first(where: { $0.taskID == selectedTaskID })
    }

    private func updateInspector() {
        inspectorController.update(row: selectedRow())
        syncQuickLookWithSelectionIfVisible()
        if let inspectorItem = splitController.splitViewItems.last {
            let shouldCollapse = selectedTaskID == nil && displayedRows.isEmpty
            if inspectorItem.isCollapsed != shouldCollapse {
                inspectorItem.animator().isCollapsed = shouldCollapse
            }
        }
    }

    private func refreshLiveProgress() async {
#if DEBUG
        let signpostID = NDMPerformance.begin("LiveProgressRefresh")
        defer { NDMPerformance.end("LiveProgressRefresh", id: signpostID) }
#endif
        let activeTasks = allTasks.filter {
            $0.status == .downloading || $0.status == .waiting
        }
        guard !activeTasks.isEmpty else { return }

        var nextProgress = progressByID
        var needsStructuralReload = false
        for task in activeTasks {
            guard let progress = await manager.progress(taskID: task.id) else {
                // A disappearing engine commonly means completion/error. Read the
                // persisted snapshot once rather than rebuilding every tick.
                needsStructuralReload = true
                continue
            }
            nextProgress[task.id] = progress
            if progress.status != task.status {
                needsStructuralReload = true
            }
        }
        if needsStructuralReload {
            await reload()
            return
        }
        guard nextProgress != progressByID else { return }
        progressByID = nextProgress
        rebuildDisplayedRows(preserveSelection: true)
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshLiveProgress()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Actions

    @objc func promptNewURL() {
        presentNewDownload(initialURL: nil)
    }

    func promptNewURLWithPrefill(_ prefilledText: String?) {
        presentNewDownload(initialURL: prefilledText)
    }

    private func presentNewDownload(initialURL: String?) {
        let parent = window
        Task { @MainActor in
            let currentSettings = await manager.currentSettings()
            switch await NewDownloadWindowController.present(
                on: parent,
                existingTasks: allTasks,
                destinationDirectory: currentSettings.downloadDirectory,
                initialURL: initialURL
            ) {
            case .download(let submission):
                startURL(
                    submission.urlString,
                    preflight: submission.preflight,
                    readyChoice: submission.readyChoice
                )
            case .showExisting(let taskID):
                focusExistingTask(taskID)
            case .cancel:
                return
            }
        }
    }

    /// Offers a newly copied link without downloading behind the user's back.
    /// Returns false for unrelated text and anything already in the inbox.
    @discardableResult
    func offerClipboardText(_ rawText: String) -> Bool {
        guard let offer = ClipboardDownloadOfferResolver.offer(
            for: rawText,
            existingTasks: allTasks
        ) else {
            clearClipboardOffer()
            return false
        }
        clipboardOffer = offer
        contentToolbar.setClipboardOffer(offer)
        return true
    }

    func clearClipboardOffer() {
        clipboardOffer = nil
        contentToolbar.setClipboardOffer(nil)
    }

    private func openClipboardOffer() {
        guard let offer = clipboardOffer else { return }
        clearClipboardOffer()
        presentNewDownload(initialURL: offer.inputText)
    }

    private func focusExistingTask(_ taskID: Int64) {
        guard allTasks.contains(where: { $0.id == taskID }) else { return }
        selectedFilter = .all
        searchQuery = ""
        selectedTaskID = taskID
        contentToolbar.setSearchQuery("")
        sidebarController.update(
            counts: SidebarFilter.counts(in: allTasks),
            selected: .all
        )
        rebuildDisplayedRows(preserveSelection: true)
        listController.revealTask(taskID)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func startSelected() {
        guard let id = selectedTaskID else { return }
        startTask(id)
    }

    @objc private func pauseSelected() {
        guard let id = selectedTaskID else { return }
        Task {
            await manager.pause(taskID: id)
            await reload()
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        rebuildDisplayedRows(preserveSelection: true)
    }

    @objc private func openBrowsers() {
        let wc = BrowsersWindowController(bridgeRunning: true)
        browsersWindow = wc
        wc.showWindow(nil)
    }

    @objc private func openSettings() {
        Task {
            let settings = await manager.currentSettings()
            let wc = SettingsWindowController(
                manager: manager,
                settings: settings,
                siteCompatibilityUpdater: siteCompatibilityUpdater
            )
            settingsWindow = wc
            wc.showWindow(nil)
        }
    }

    func showProgress(for taskID: Int64) {
        if let existing = progressWindows[taskID] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let name = allTasks.first(where: { $0.id == taskID })?.filename
            ?? displayedRows.first(where: { $0.taskID == taskID })?.filename
            ?? L10n.downloadFallback(taskID)
        let wc = ProgressWindowController(manager: manager, taskID: taskID, filename: name)
        wc.onWindowClose = { [weak self] in
            self?.progressWindows.removeValue(forKey: taskID)
        }
        progressWindows[taskID] = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// If a progress window is already open for this task, morph it into the
    /// completion UI instead of stacking a modal alert on top.
    @discardableResult
    func presentCompletionInProgressWindow(for task: DownloadTask) -> Bool {
        guard let wc = progressWindows[task.id] else { return false }
        wc.presentCompleted(task: task)
        return true
    }

    /// Public entry for onboarding / external callers — same path as ⌘N.
    func addAndStart(urlString: String) {
        startURL(urlString)
    }

    private func startURL(
        _ urlString: String,
        preflight: MediaPreflightResult? = nil,
        readyChoice: NewDownloadWindowController.ReadyChoice? = nil
    ) {
        let parent = window
        let cancellation = MediaPreparationCancellation()
        Task {
            var preparedResult = preflight
            var effectiveURL = preflight?.mediaURL ?? urlString
            var working: WorkingPanelController?
            defer { working?.dismiss() }

            if MediaPreparationPlan.shouldResolveSharedLink(
                urlString,
                hasPreparedMetadata: preflight != nil
            ) {
                working = WorkingPanelController.schedule(
                    stage: .resolvingLink,
                    on: parent,
                    onCancel: { cancellation.cancel() }
                )
                let expanded = await ShortLinkExpander.expand(urlString)
                guard !cancellation.isCancelled else { return }
                effectiveURL = expanded.resolvedURL
            }

            var urlToAdd = effectiveURL
            var ltype = "normal"
            // Manually pasted master playlists get the same quality picker
            // as browser captures; a failed HLS probe falls back to media
            // recognition (or the plain path), never to a raw page download.
            var handledAsHLS = false
            if effectiveURL.lowercased().contains(".m3u8") {
                if let working {
                    working.update(stage: .readingMedia)
                } else {
                    working = WorkingPanelController.schedule(
                        stage: .readingMedia,
                        on: parent,
                        onCancel: { cancellation.cancel() }
                    )
                }
                let hlsProbe = await HLSMasterProbe.probe(urlString: effectiveURL)
                guard !cancellation.isCancelled else { return }
                if let hlsProbe {
                    working?.dismiss()
                    working = nil
                    handledAsHLS = true
                    switch await QualityPickerWindowController.choose(probe: hlsProbe, title: "") {
                    case .cancel:
                        return
                    case .download(let option):
                        if let resolved = HLSPlaylist.resolveURL(
                            option.variant.uri,
                            against: hlsProbe.masterURL
                        ) {
                            urlToAdd = resolved.absoluteString
                            ltype = "hls"
                        }
                    }
                }
            }
            if !handledAsHLS, MediaLinkClassifier.looksLikeMediaPage(effectiveURL) {
                guard YtDlpTool.isAvailable else {
                    working?.dismiss()
                    showAlert(message: L10n.advancedVideo, detail: L10n.ytdlpMissingHint)
                    return
                }
                // Probe can take a few seconds. If the site requires a browser
                // session, turn that resolver error into one guided retry.
                var cookieSource: YtDlpCookieSource?
                var resolvedProbe: YtDlpProbe? = preflight?.probe
                while resolvedProbe == nil {
                    if let working {
                        working.update(stage: .readingMedia)
                    } else {
                        working = WorkingPanelController.schedule(
                            stage: .readingMedia,
                            on: parent,
                            onCancel: { cancellation.cancel() }
                        )
                    }
                    do {
                        if cookieSource == nil {
                            let prepared = try await MediaPreflightStore.shared.result(for: effectiveURL)
                            preparedResult = prepared
                            effectiveURL = prepared.mediaURL
                            resolvedProbe = prepared.probe
                        } else {
                            resolvedProbe = try await YtDlpTool.probe(
                                url: effectiveURL,
                                cookieSource: cookieSource
                            )
                        }
                        guard !cancellation.isCancelled else { return }
                        working?.update(stage: .preparingOptions)
                        working?.dismiss()
                        working = nil
                    } catch {
                        guard !cancellation.isCancelled else { return }
                        working?.dismiss()
                        working = nil
                        guard YtDlpTool.accessIssue(error: error) != nil else {
                            NSLog("Media recognition failed for %@: %@", effectiveURL, error.localizedDescription)
                            showAlert(
                                message: L10n.mediaRecognitionFailed,
                                detail: L10n.mediaRecognitionFailedBody
                            )
                            return
                        }
                        let previousSource = cookieSource
                        guard let selected = await MediaAccessPrompt.choose(
                            pageURL: effectiveURL,
                            parentWindow: parent,
                            previousSource: previousSource,
                            retrying: previousSource != nil
                        ) else {
                            return
                        }
                        guard !cancellation.isCancelled else { return }
                        cookieSource = selected
                    }
                }
                guard let probe = resolvedProbe else { return }
                guard !probe.formats.isEmpty else {
                    showAlert(
                        message: L10n.mediaRecognitionFailed,
                        detail: L10n.mediaRecognitionFailedBody
                    )
                    return
                }
                if let readyChoice, preparedResult?.collection == nil {
                    await launchSingleMedia(
                        url: effectiveURL,
                        probe: probe,
                        picked: readyChoice.format,
                        options: readyChoice.options
                    )
                    return
                }
                let currentSettings = await manager.currentSettings()
                switch await YtDlpQualityPickerWindowController.choose(
                    url: effectiveURL,
                    probe: probe,
                    collection: preparedResult?.collection,
                    cookieSource: cookieSource,
                    destinationDirectory: currentSettings.downloadDirectory,
                    parentWindow: parent
                ) {
                case .cancel:
                    return
                case .download(let picked, let options, let scope):
                    // Same path as ordinary downloads: list row + progress window.
                    // Probe sheet is only for the short metadata fetch.
                    do {
                        if case .collection(let collection) = scope {
                            let tasks = try await manager.enqueueYtDlpCollection(
                                collection.items,
                                formatID: picked.selector(for: options.container),
                                options: options,
                                collectionURL: preparedResult?.resolvedURL ?? urlString,
                                collectionTitle: collection.title.isEmpty ? nil : collection.title,
                                estimatedSampleBytes: picked.approximateBytes,
                                estimatedSampleComponentBytes: picked.componentBytes,
                                sampleDurationSeconds: probe.durationSeconds
                            )
                            for (task, item) in zip(tasks, collection.items) {
                                if let thumbnail = item.thumbnailURL {
                                    CoverArtCache.shared.prefetchRemote(
                                        taskID: task.id,
                                        urlString: thumbnail
                                    )
                                }
                            }
                            if let first = tasks.first {
                                selectedTaskID = first.id
                            }
                            await reload()
                            if let first = tasks.first {
                                showProgress(for: first.id)
                            }
                            return
                        }
                        await launchSingleMedia(
                            url: effectiveURL,
                            probe: probe,
                            picked: picked,
                            options: options
                        )
                        return
                    } catch {
                        showAlert(error)
                        return
                    }
                }
            }
            working?.dismiss()
            guard !cancellation.isCancelled else { return }
            do {
                let task = try await manager.addURL(urlToAdd, ltype: ltype)
                selectedTaskID = task.id
                showProgress(for: task.id)
                try await manager.start(taskID: task.id)
                await reload()
            } catch {
                showAlert(error)
                await reload()
            }
        }
    }

    private func launchSingleMedia(
        url: String,
        probe: YtDlpProbe,
        picked: YtDlpFormat,
        options: YtDlpDownloadOptions
    ) async {
        do {
            let task = try await manager.startYtDlp(
                url: url,
                formatID: picked.selector(for: options.container),
                options: options,
                pageTitle: probe.title.isEmpty ? nil : probe.title,
                estimatedBytes: picked.approximateBytes,
                estimatedComponentBytes: picked.componentBytes,
                preferredFilename: probe.title.isEmpty ? nil : probe.title
            )
            if let thumb = probe.thumbnailURL {
                CoverArtCache.shared.prefetchRemote(
                    taskID: task.id,
                    urlString: thumb
                )
            }
            selectedTaskID = task.id
            await reload()
            showProgress(for: task.id)
        } catch {
            showAlert(error)
        }
    }

    private func startTask(_ id: Int64) {
        Task {
            do {
                selectedTaskID = id
                showProgress(for: id)
                try await manager.start(taskID: id)
                await reload()
            } catch {
                showAlert(error)
                await reload()
            }
        }
    }

    private func deleteTask(_ id: Int64) {
        let name = allTasks.first(where: { $0.id == id })?.filename ?? L10n.t("this download", "此下载")
        let alert = NSAlert()
        alert.messageText = L10n.removeConfirm(name)
        alert.informativeText = L10n.removeConfirmBody
        alert.addButton(withTitle: L10n.removeTask)
        alert.addButton(withTitle: L10n.removeAndTrash)
        alert.addButton(withTitle: L10n.cancel)
        let response = alert.runModal()
        let deleteFile: Bool
        switch response {
        case .alertFirstButtonReturn:
            deleteFile = false
        case .alertSecondButtonReturn:
            deleteFile = true
        default:
            return
        }
        Task {
            do {
                try await manager.remove(taskID: id, deleteFile: deleteFile)
                if selectedTaskID == id { selectedTaskID = nil }
                await reload()
            } catch {
                showAlert(error)
            }
        }
    }

    private func renewURL(for id: Int64) {
        let task = allTasks.first(where: { $0.id == id })
        if let sourceURL = task?.browserRescueURL {
            NSWorkspace.shared.open(sourceURL)
            return
        }
        let current = task?.url ?? ""
        let alert = NSAlert()
        alert.messageText = L10n.renewURL
        alert.informativeText = L10n.renewURLBody
        alert.addButton(withTitle: L10n.renewAndStart)
        alert.addButton(withTitle: L10n.cancel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = current
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        alert.accessoryView = field
        alert.layout()
        alert.window.initialFirstResponder = field
        _ = alert.window.makeFirstResponder(field)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        Task {
            do {
                try await manager.renewURL(taskID: id, newURL: url)
                selectedTaskID = id
                showProgress(for: id)
                try await manager.start(taskID: id)
                await reload()
            } catch {
                showAlert(error)
                await reload()
            }
        }
    }

    private func openTaskFile(_ id: Int64) {
        guard let task = allTasks.first(where: { $0.id == id }),
              let url = task.destinationFileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert(message: L10n.fileNotFound, detail: url.path)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func existingFileURL(for id: Int64) -> URL? {
        guard let task = allTasks.first(where: { $0.id == id }),
              let url = task.destinationFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func toggleQuickLook(for id: Int64) {
        guard let url = existingFileURL(for: id) else {
            if let missing = allTasks.first(where: { $0.id == id })?.destinationFileURL {
                showAlert(message: L10n.fileNotFound, detail: missing.path)
            }
            return
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, previewedFileURL == url {
            panel.orderOut(nil)
            return
        }
        previewedFileURL = url
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    private func syncQuickLookWithSelectionIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else { return }
        guard let id = selectedTaskID,
              let url = existingFileURL(for: id) else {
            previewedFileURL = nil
            panel.orderOut(nil)
            return
        }
        guard previewedFileURL != url else { return }
        previewedFileURL = url
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        previewedFileURL != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewedFileURL == nil ? 0 : 1
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        previewedFileURL as NSURL?
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 123, 126: // Left / Up
            return listController.selectAdjacentRow(offset: -1)
        case 124, 125: // Right / Down
            return listController.selectAdjacentRow(offset: 1)
        default:
            return false
        }
    }

    private func revealTaskFile(_ id: Int64) {
        guard let task = allTasks.first(where: { $0.id == id }),
              let url = task.destinationFileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert(message: L10n.fileNotFound, detail: url.path)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func shareTaskFile(_ id: Int64, from anchor: NSView? = nil) {
        guard let task = allTasks.first(where: { $0.id == id }),
              let url = task.destinationFileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert(message: L10n.fileNotFound, detail: url.path)
            return
        }
        let source = anchor ?? inspectorController.view
        _ = fileSharePresenter.present(fileURL: url, from: source)
    }

    private func showProperties(for id: Int64) {
        guard let task = allTasks.first(where: { $0.id == id }) else { return }
        // Defer past the context-menu tracking runloop. Do not use showWindow: —
        // with a filename-like title AppKit hands off to QLSeamlessDocumentOpener
        // and can abort via NSRemoteView on macOS 26+.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let existing = self.propsWindow, existing.taskID == id {
                existing.present()
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            let wc = TaskPropertiesWindowController(manager: self.manager, task: task)
            self.propsWindow = wc
            wc.present()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func performPrimaryAction(for taskID: Int64) {
        guard let row = displayedRows.first(where: { $0.taskID == taskID })
                ?? allTasks.first(where: { $0.id == taskID }).map({
                    TaskRowPresentation.make(task: $0, progress: progressByID[$0.id])
                }) else { return }
        switch row.primaryAction {
        case .open:
            openTaskFile(taskID)
        case .showProgress:
            showProgress(for: taskID)
        case .start:
            startTask(taskID)
        case .none:
            break
        }
    }

    private func handleContextAction(_ action: TaskListContextAction, taskID: Int64) {
        selectedTaskID = taskID
        updateInspector()
        updateToolbarEnablement()
        switch action {
        case .quickLook:
            toggleQuickLook(for: taskID)
        case .open:
            openTaskFile(taskID)
        case .reveal:
            revealTaskFile(taskID)
        case .share:
            shareTaskFile(taskID)
        case .start, .retry:
            startTask(taskID)
        case .pause:
            Task {
                await manager.pause(taskID: taskID)
                await reload()
            }
        case .renew:
            renewURL(for: taskID)
        case .progress:
            showProgress(for: taskID)
        case .properties:
            showProperties(for: taskID)
        case .copyURL:
            if let url = allTasks.first(where: { $0.id == taskID })?.url, !url.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        case .delete:
            deleteTask(taskID)
        }
    }

    private func showAlert(_ error: Error) {
        showAlert(message: L10n.somethingWentWrong, detail: error.localizedDescription)
    }

    private func showAlert(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

// MARK: - Toolbar identifiers

private extension NSToolbarItem.Identifier {
    static let ndmNewDownload = NSToolbarItem.Identifier("ndm.new")
    static let ndmStart = NSToolbarItem.Identifier("ndm.start")
    static let ndmPause = NSToolbarItem.Identifier("ndm.pause")
    static let ndmSearch = NSToolbarItem.Identifier("ndm.search")
    static let ndmBrowsers = NSToolbarItem.Identifier("ndm.browsers")
    static let ndmSettings = NSToolbarItem.Identifier("ndm.settings")
}

// MARK: - Sidebar

private enum SidebarRow: Equatable {
    case header(String)
    case filter(SidebarFilter)
}

@MainActor
private final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelectFilter: ((SidebarFilter) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var counts: [SidebarFilter: Int] = [:]
    private var selected: SidebarFilter = .all
    private var rows: [SidebarRow] = []
    /// Ignore selection callbacks while we sync table selection from model.
    private var suppressSelectionCallback = false
    private var contentScale: CGFloat = InterfaceScale.default

    private static func buildRows() -> [SidebarRow] {
        var rows: [SidebarRow] = []
        for filter in SidebarFilter.allCases {
            if let section = filter.section {
                rows.append(.header(section))
            }
            rows.append(.filter(filter))
        }
        return rows
    }

    override func loadView() {
        rows = SidebarViewController.buildRows()
        // Deliberate navigation rail from the approved concept, rather than an
        // unstyled transparent source list.
        view = ChromeBox(fill: NDMChrome.sidebarFill)
        // Plain (not sourceList) so Quiet Finder accent pills aren't fought by system chrome.
        tableView.style = .plain
        tableView.floatsGroupRows = false
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("filter"))
        tableView.addTableColumn(col)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func setContentScale(_ scale: CGFloat) {
        let next = min(InterfaceScale.maximum, max(InterfaceScale.minimum, scale))
        // Navigation participates in zoom, but more gently than content rows;
        // otherwise the rail turns into oversized system-looking controls.
        let effectiveScale = 1 + (next - 1) * 0.70
        let changed = abs(contentScale - effectiveScale) > 0.000_1
        contentScale = effectiveScale
        if !isViewLoaded { _ = view }
        // `loadView()` starts with a safe fallback; always apply the designed
        // 40 pt rhythm, including the first call at the default 100% scale.
        tableView.rowHeight = 40 * contentScale
        guard changed else { return }
        tableView.reloadData()
        applyTableSelection(to: selected)
    }

    func relocalizeChrome() {
        rows = SidebarViewController.buildRows()
        if isViewLoaded {
            tableView.reloadData()
            applyTableSelection(to: selected)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = QuietFinderRowView()
        if case .filter(let filter) = rows[row] {
            view.usesAccentFill = true
            view.forcedSelected = (filter == selected)
        } else {
            view.usesAccentFill = false
            view.forcedSelected = false
        }
        return view
    }

    func update(counts: [SidebarFilter: Int], selected: SidebarFilter) {
        let previousCounts = self.counts
        let previousSelected = self.selected
        guard previousCounts != counts || previousSelected != selected else { return }

        self.counts = counts
        self.selected = selected
        guard tableView.numberOfRows == rows.count else {
            tableView.reloadData()
            applyTableSelection(to: selected)
            return
        }

        var changedRows = IndexSet()
        for (index, row) in rows.enumerated() {
            guard case .filter(let filter) = row else { continue }
            if previousCounts[filter] != counts[filter]
                || filter == previousSelected
                || filter == selected {
                changedRows.insert(index)
            }
        }
        if !changedRows.isEmpty {
            tableView.reloadData(
                forRowIndexes: changedRows,
                columnIndexes: IndexSet(integer: 0)
            )
        }
        applyTableSelection(to: selected)
    }

    private func applyTableSelection(to filter: SidebarFilter) {
        guard let index = rows.firstIndex(of: .filter(filter)) else { return }
        if tableView.selectedRow == index {
            syncSelectionAppearance()
            return
        }
        suppressSelectionCallback = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        suppressSelectionCallback = false
        syncSelectionAppearance()
    }

    private func syncSelectionAppearance() {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            guard row < rows.count,
                  let rowView = tableView.rowView(
                    atRow: row,
                    makeIfNecessary: false
                  ) as? QuietFinderRowView else {
                continue
            }
            if case .filter(let filter) = rows[row] {
                rowView.usesAccentFill = true
                rowView.forcedSelected = (filter == selected)
            } else {
                rowView.forcedSelected = false
            }
            rowView.needsDisplay = true
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 30 * contentScale
        case .filter: return 40 * contentScale
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("SidebarHeader")
            let label = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
                ?? NSTextField(labelWithString: "")
            label.identifier = id
            label.attributedStringValue = NSAttributedString(
                string: title.uppercased(),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10 * contentScale, weight: .semibold),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .kern: 0.7 * contentScale,
                ]
            )
            return label
        case .filter(let filter):
            let id = NSUserInterfaceItemIdentifier("SidebarFilter")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SidebarFilterCellView)
                ?? SidebarFilterCellView()
            cell.identifier = id
            cell.apply(
                filter: filter,
                count: counts[filter] ?? 0,
                selected: filter == selected,
                scale: contentScale
            )
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if suppressSelectionCallback { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .filter(let filter) = rows[row] else { return }
        guard filter != selected else {
            syncSelectionAppearance()
            return
        }
        let previousSelected = selected
        selected = filter
        var changedRows = IndexSet()
        if let oldIndex = rows.firstIndex(of: .filter(previousSelected)) {
            changedRows.insert(oldIndex)
        }
        changedRows.insert(row)
        if tableView.numberOfRows == rows.count {
            tableView.reloadData(
                forRowIndexes: changedRows,
                columnIndexes: IndexSet(integer: 0)
            )
        }
        syncSelectionAppearance()
        onSelectFilter?(filter)
    }
}

/// Sidebar filter row — ink colors driven by model selection, not stale cell reuse.
private final class SidebarFilterCellView: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.alignment = .right
        badge.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        addSubview(icon)
        addSubview(titleLabel)
        addSubview(badge)
        let iconWidth = icon.widthAnchor.constraint(equalToConstant: 16)
        let iconHeight = icon.heightAnchor.constraint(equalToConstant: 16)
        self.iconWidth = iconWidth
        self.iconHeight = iconHeight
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconHeight,
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(filter: SidebarFilter, count: Int, selected: Bool, scale: CGFloat) {
        let ink: NSColor = selected ? .white : .labelColor
        let muted: NSColor = selected ? NSColor.white.withAlphaComponent(0.78) : .tertiaryLabelColor
        iconWidth?.constant = 17 * scale
        iconHeight?.constant = 17 * scale
        icon.image = NDMChrome.symbol(
            NDMChrome.sidebarSymbolName(for: filter),
            pointSize: 13.5 * scale,
            weight: selected ? .semibold : .medium
        )
        icon.contentTintColor = selected ? .white : .secondaryLabelColor
        titleLabel.stringValue = filter.title
        titleLabel.font = .systemFont(ofSize: 13.5 * scale, weight: selected ? .semibold : .medium)
        titleLabel.textColor = ink
        badge.stringValue = "\(count)"
        badge.font = .monospacedDigitSystemFont(ofSize: 11.5 * scale, weight: .regular)
        badge.textColor = muted
    }
}

// MARK: - Task list

enum TaskListContextAction {
    case quickLook, open, reveal, share, start, pause, retry, renew, progress, properties, copyURL, delete
}

private final class TaskListTableView: NSTableView {
    var onQuickLook: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection(disallowedModifiers).isEmpty,
           onQuickLook?() == true {
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class TaskListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelectTaskID: ((Int64?) -> Void)?
    var onActivateTaskID: ((Int64) -> Void)?
    var onContextAction: ((TaskListContextAction, Int64) -> Void)?
    var onDropURL: ((String) -> Void)?
    var onEmptyNewDownload: (() -> Void)?

    private let tableView = TaskListTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptySubtitleLabel = NSTextField(labelWithString: "")
    private let emptyStack = NSStackView()
    private var rows: [TaskRowPresentation] = []
    private var selectedTaskID: Int64?
    private var suppressSelectionCallback = false
    private var contextMenuDelegate: ContextMenuDelegate?
    /// Captured while the menu opens — `clickedRow` often clears before the item action runs.
    private var menuContextTaskID: Int64?
    private var emptyActionsRow: NSStackView?
    private var contentScale: CGFloat = InterfaceScale.default

    override func loadView() {
        let root = URLDropView(frame: .zero)
        root.onDropURL = { [weak self] url in self?.onDropURL?(url) }
        root.onHoverChange = { [weak self] hovering in
            self?.scrollView.layer?.borderWidth = hovering ? 2 : 0
            self?.scrollView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
        view = root
        root.fill = NDMChrome.contentSurface

        tableView.headerView = nil
        // Plain + custom row paint — inset style fights single-selection redraw.
        tableView.style = .plain
        tableView.rowHeight = 70
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = NDMChrome.contentSurface
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.target = self
        tableView.onQuickLook = { [weak self] in
            guard let self, let taskID = self.selectedTaskID else { return false }
            self.onContextAction?(.quickLook, taskID)
            return true
        }
        tableView.menu = makeContextMenu()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        tableView.addTableColumn(col)

        NotificationCenter.default.addObserver(
            forName: CoverArtCache.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let taskID = note.userInfo?["taskID"] as? Int64
            Task { @MainActor [weak self] in
                self?.refreshCover(for: taskID)
            }
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NDMChrome.contentSurface
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 0
        scrollView.layer?.borderWidth = 0
        scrollView.layer?.borderColor = NDMChrome.accent.cgColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let mark = ChromeBox(fill: NDMChrome.accent, cornerRadius: 14)
        mark.translatesAutoresizingMaskIntoConstraints = false
        let markIcon = NSImageView()
        markIcon.image = NDMChrome.symbol("arrow.down.to.line", pointSize: 22, weight: .semibold)
        markIcon.contentTintColor = .white
        markIcon.translatesAutoresizingMaskIntoConstraints = false
        mark.addSubview(markIcon)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 52),
            mark.heightAnchor.constraint(equalToConstant: 52),
            markIcon.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            markIcon.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
        ])

        emptyLabel.font = .systemFont(ofSize: 20, weight: .bold)
        emptyLabel.textColor = .labelColor
        emptyLabel.alignment = .center
        emptySubtitleLabel.font = .systemFont(ofSize: 13)
        emptySubtitleLabel.textColor = .secondaryLabelColor
        emptySubtitleLabel.alignment = .center
        emptySubtitleLabel.maximumNumberOfLines = 3
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 10
        emptyStack.addArrangedSubview(mark)
        emptyStack.addArrangedSubview(emptyLabel)
        emptyStack.addArrangedSubview(emptySubtitleLabel)
        emptyStack.setCustomSpacing(18, after: mark)

        let newButton = NSButton(title: L10n.newDownloadEllipsis, target: self, action: #selector(emptyNewClicked))
        NDMChrome.styleMainButton(newButton)
        newButton.controlSize = .large
        let emptyActions = NSStackView(views: [newButton])
        emptyActions.orientation = .horizontal
        emptyActions.spacing = 10
        emptyActionsRow = emptyActions
        emptyStack.setCustomSpacing(22, after: emptySubtitleLabel)
        emptyStack.addArrangedSubview(emptyActions)

        emptyStack.isHidden = true
        emptyStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        view.addSubview(emptyStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    @objc private func emptyNewClicked() {
        onEmptyNewDownload?()
    }

    func relocalizeChrome() {
        tableView.menu = makeContextMenu()
    }

    /// Zoom task content while the titlebar, toolbar, sidebar, inspector, and
    /// window geometry remain stable.
    func setContentScale(_ scale: CGFloat) {
        let next = min(InterfaceScale.maximum, max(InterfaceScale.minimum, scale))
        let changed = abs(contentScale - next) > 0.000_1
        contentScale = next
        if !isViewLoaded { _ = view }
        guard changed else { return }

        tableView.rowHeight = 70 * next
        emptyLabel.font = .systemFont(ofSize: 20 * next, weight: .bold)
        emptySubtitleLabel.font = .systemFont(ofSize: 13 * next)
        if tableView.numberOfRows > 0 {
            let all = IndexSet(integersIn: 0..<tableView.numberOfRows)
            tableView.reloadData(forRowIndexes: all, columnIndexes: IndexSet(integer: 0))
            tableView.noteHeightOfRows(withIndexesChanged: all)
        }
        view.needsLayout = true
        view.needsDisplay = true
    }

    func update(
        rows: [TaskRowPresentation],
        selectedTaskID: Int64?,
        emptyTitle: String,
        emptySubtitle: String,
        emptyShowsActions: Bool = false
    ) {
#if DEBUG
        let signpostID = NDMPerformance.begin("TaskListUpdate")
        defer { NDMPerformance.end("TaskListUpdate", id: signpostID) }
#endif
        let previousRows = self.rows
        let previousIDs = previousRows.map(\.taskID)
        let nextIDs = rows.map(\.taskID)
        self.rows = rows
        self.selectedTaskID = selectedTaskID
        emptyLabel.stringValue = emptyTitle
        emptySubtitleLabel.stringValue = emptySubtitle
        emptyActionsRow?.isHidden = !emptyShowsActions
        emptyStack.isHidden = !rows.isEmpty
        tableView.isHidden = rows.isEmpty

        if previousIDs != nextIDs {
            tableView.reloadData()
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        } else if !rows.isEmpty {
            var changedRows = IndexSet()
            var heightChangedRows = IndexSet()
            for index in rows.indices where previousRows[index] != rows[index] {
                changedRows.insert(index)
                if previousRows[index].showsProgressBar != rows[index].showsProgressBar {
                    heightChangedRows.insert(index)
                }
            }
            if !changedRows.isEmpty {
                tableView.reloadData(
                    forRowIndexes: changedRows,
                    columnIndexes: IndexSet(integer: 0)
                )
            }
            if !heightChangedRows.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: heightChangedRows)
            }
        }

        applyTableSelection(to: selectedTaskID)
    }

    func revealTask(_ taskID: Int64) {
        applyTableSelection(to: taskID)
        guard let index = rows.firstIndex(where: { $0.taskID == taskID }) else { return }
        tableView.scrollRowToVisible(index)
    }

    func selectAdjacentRow(offset: Int) -> Bool {
        guard !rows.isEmpty else { return false }
        let current = selectedTaskID.flatMap { id in rows.firstIndex(where: { $0.taskID == id }) }
            ?? (tableView.selectedRow >= 0 ? tableView.selectedRow : nil)
        let next: Int
        if let current {
            next = min(rows.count - 1, max(0, current + offset))
            guard next != current else { return false }
        } else {
            // No selection yet: step into the list from the matching end.
            next = offset >= 0 ? 0 : rows.count - 1
        }
        let taskID = rows[next].taskID
        selectedTaskID = taskID
        applyTableSelection(to: taskID)
        tableView.scrollRowToVisible(next)
        onSelectTaskID?(taskID)
        return true
    }

    private func applyTableSelection(to taskID: Int64?) {
        suppressSelectionCallback = true
        defer {
            suppressSelectionCallback = false
            syncSelectionAppearance()
        }
        guard let taskID, let index = rows.firstIndex(where: { $0.taskID == taskID }) else {
            if tableView.selectedRow != -1 {
                tableView.deselectAll(nil)
            }
            return
        }
        if tableView.selectedRow != index {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func syncSelectionAppearance() {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            guard row < rows.count,
                  let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? QuietFinderRowView else {
                continue
            }
            let on = (rows[row].taskID == selectedTaskID)
            guard rowView.forcedSelected != on else { continue }
            rowView.forcedSelected = on
            rowView.needsDisplay = true
        }
    }

    private func refreshCover(for taskID: Int64?) {
        for row in 0..<rows.count {
            if let taskID, rows[row].taskID != taskID { continue }
            if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? QuietFinderRowView {
                applyArtwork(to: rowView, item: rows[row])
            }
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TaskRowCellView {
                cell.apply(rows[row], scale: contentScale)
            }
            if taskID != nil { break }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 70 * contentScale }
        return (rows[row].showsProgressBar ? 74 : 66) * contentScale
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = QuietFinderRowView()
        view.usesAccentFill = false
        if row < rows.count {
            let item = rows[row]
            view.forcedSelected = (item.taskID == selectedTaskID)
            applyArtwork(to: view, item: item)
        }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("TaskRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? TaskRowCellView) ?? TaskRowCellView()
        cell.identifier = id
        let taskID = rows[row].taskID
        cell.onInlineRenew = { [weak self] in
            self?.onContextAction?(.renew, taskID)
        }
        cell.apply(rows[row], scale: contentScale)
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? QuietFinderRowView {
            applyArtwork(to: rowView, item: rows[row])
        }
        return cell
    }

    private func applyArtwork(to rowView: QuietFinderRowView, item: TaskRowPresentation) {
        let ext = (item.filename as NSString).pathExtension.lowercased()
        let usesContentBackdrop = [
            "mp4", "mkv", "mov", "m4v", "webm", "avi", "ts",
            "png", "jpg", "jpeg", "gif", "webp", "heic",
        ].contains(ext)
        let preview = CoverArtCache.shared.image(for: item.taskID)
        if preview == nil, usesContentBackdrop {
            CoverArtCache.shared.ensureCover(
                taskID: item.taskID,
                remoteURL: nil,
                localFile: item.localFileURL
            )
        }
        rowView.artworkStyle = usesContentBackdrop ? .fullBleed : .ambient
        rowView.washColor = nil
        if usesContentBackdrop {
            rowView.coverImage = preview
        } else {
            rowView.coverImage = preview ?? NDMChrome.fileIcon(filename: item.filename, pointSize: 128)
        }
        rowView.needsDisplay = true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if suppressSelectionCallback { return }
        let row = tableView.selectedRow
        if row >= 0, row < rows.count {
            selectedTaskID = rows[row].taskID
            syncSelectionAppearance()
            onSelectTaskID?(rows[row].taskID)
        } else {
            selectedTaskID = nil
            syncSelectionAppearance()
            onSelectTaskID?(nil)
        }
    }

    @objc private func doubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        onActivateTaskID?(rows[row].taskID)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let delegate = ContextMenuDelegate { [weak self] menu in
            self?.configureContextMenu(menu)
        }
        contextMenuDelegate = delegate
        menu.delegate = delegate
        let quickLook = NSMenuItem(
            title: L10n.quickLook,
            action: #selector(ctxQuickLook),
            keyEquivalent: " "
        )
        quickLook.keyEquivalentModifierMask = []
        quickLook.target = self
        quickLook.ndmSymbol("eye")
        menu.addItem(quickLook)
        let specs: [(String, Selector, String?, String)?] = [
            (L10n.open, #selector(ctxOpen), "o", "doc.fill"),
            (L10n.showInFinder, #selector(ctxReveal), "r", "folder.fill"),
            (L10n.share, #selector(ctxShare), nil, "square.and.arrow.up"),
            nil,
            (L10n.retry, #selector(ctxRetry), nil, "arrow.clockwise"),
            (L10n.renewURLEllipsis, #selector(ctxRenew), nil, "link"),
            (L10n.start, #selector(ctxStart), nil, "play.fill"),
            (L10n.pause, #selector(ctxPause), nil, "pause.fill"),
            (L10n.progressDetails, #selector(ctxProgress), nil, "chart.bar.fill"),
            (L10n.propertiesEllipsis, #selector(ctxProperties), nil, "info.circle"),
            (L10n.copyURL, #selector(ctxCopyURL), nil, "doc.on.doc"),
            nil,
            (L10n.delete, #selector(ctxDelete), "\u{8}", "trash"),
        ]
        for spec in specs {
            if let spec {
                let menuItem = NSMenuItem(title: spec.0, action: spec.1, keyEquivalent: spec.2 ?? "")
                menuItem.target = self
                menuItem.ndmSymbol(spec.3)
                menu.addItem(menuItem)
            } else {
                menu.addItem(.separator())
            }
        }
        return menu
    }

    private func configureContextMenu(_ menu: NSMenu) {
        guard let row = resolveContextRowIndex() else {
            menuContextTaskID = nil
            menu.items.forEach { $0.isEnabled = false }
            return
        }
        menuContextTaskID = rows[row].taskID
        selectedTaskID = rows[row].taskID
        applyTableSelection(to: selectedTaskID)
        onSelectTaskID?(selectedTaskID)
        let presentation = rows[row]
        for item in menu.items {
            switch item.action {
            case #selector(ctxQuickLook): item.isEnabled = presentation.canOpen
            case #selector(ctxOpen): item.isEnabled = presentation.canOpen
            case #selector(ctxReveal): item.isEnabled = presentation.canShowInFinder
            case #selector(ctxShare): item.isEnabled = presentation.canOpen
            case #selector(ctxRetry):
                item.isEnabled = presentation.canRetry
                item.title = L10n.retry
            case #selector(ctxRenew): item.isEnabled = presentation.canRenew
            case #selector(ctxStart):
                // Start/Resume for paused & waiting; Retry covers error + incomplete.
                item.isEnabled = presentation.canStart && !presentation.canRetry
                item.title = presentation.isQueued ? L10n.start : L10n.resume
            case #selector(ctxPause): item.isEnabled = presentation.canPause
            case #selector(ctxProgress):
                item.isEnabled = presentation.canShowProgress
                item.title = presentation.isComplete ? L10n.resultDetails : L10n.progressDetails
                item.ndmSymbol(presentation.isComplete ? "sparkles.rectangle.stack" : "chart.bar.fill")
            case #selector(ctxProperties), #selector(ctxDelete), #selector(ctxCopyURL): item.isEnabled = true
            default: break
            }
        }
    }

    private func resolveContextRowIndex() -> Int? {
        if tableView.clickedRow >= 0, tableView.clickedRow < rows.count {
            return tableView.clickedRow
        }
        if let id = selectedTaskID, let idx = rows.firstIndex(where: { $0.taskID == id }) {
            return idx
        }
        let selected = tableView.selectedRow
        if selected >= 0, selected < rows.count {
            return selected
        }
        // Last resort: row under the mouse (custom cell views sometimes skip clickedRow).
        if let window = tableView.window {
            let point = tableView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let row = tableView.row(at: point)
            if row >= 0, row < rows.count { return row }
        }
        return nil
    }

    private func currentContextTaskID() -> Int64? {
        if let id = menuContextTaskID { return id }
        guard let row = resolveContextRowIndex() else { return nil }
        return rows[row].taskID
    }

    @objc func delete(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        onContextAction?(.delete, rows[row].taskID)
    }

    @objc private func ctxQuickLook() { if let id = currentContextTaskID() { onContextAction?(.quickLook, id) } }
    @objc private func ctxOpen() { if let id = currentContextTaskID() { onContextAction?(.open, id) } }
    @objc private func ctxReveal() { if let id = currentContextTaskID() { onContextAction?(.reveal, id) } }
    @objc private func ctxShare() { if let id = currentContextTaskID() { onContextAction?(.share, id) } }
    @objc private func ctxRetry() { if let id = currentContextTaskID() { onContextAction?(.retry, id) } }
    @objc private func ctxRenew() { if let id = currentContextTaskID() { onContextAction?(.renew, id) } }
    @objc private func ctxStart() { if let id = currentContextTaskID() { onContextAction?(.start, id) } }
    @objc private func ctxPause() { if let id = currentContextTaskID() { onContextAction?(.pause, id) } }
    @objc private func ctxProgress() { if let id = currentContextTaskID() { onContextAction?(.progress, id) } }
    @objc private func ctxProperties() { if let id = currentContextTaskID() { onContextAction?(.properties, id) } }
    @objc private func ctxCopyURL() { if let id = currentContextTaskID() { onContextAction?(.copyURL, id) } }
    @objc private func ctxDelete() { if let id = currentContextTaskID() { onContextAction?(.delete, id) } }
}

private final class ContextMenuDelegate: NSObject, NSMenuDelegate {
    private let handler: (NSMenu) -> Void
    init(handler: @escaping (NSMenu) -> Void) { self.handler = handler }
    func menuNeedsUpdate(_ menu: NSMenu) { handler(menu) }
}

@MainActor
private final class TaskRowCellView: NSTableCellView {
    var onInlineRenew: (() -> Void)?

    private let glyph = FileGlyphView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let progressBar = ThinProgressView()
    private let trailingLabel = NSTextField(labelWithString: "")
    private let renewButton = NSButton(title: L10n.renew, target: nil, action: nil)
    private var progressHeight: NSLayoutConstraint?
    private var progressTop: NSLayoutConstraint?
    private var titleTop: NSLayoutConstraint?
    private var badgeHeight: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .systemGreen
        badgeLabel.backgroundColor = NDMChrome.okSoft
        badgeLabel.isBordered = false
        badgeLabel.drawsBackground = true
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 5
        badgeLabel.alignment = .center
        badgeLabel.isHidden = true
        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        trailingLabel.alignment = .right
        trailingLabel.textColor = .labelColor
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        renewButton.bezelStyle = .rounded
        renewButton.controlSize = .small
        renewButton.font = .systemFont(ofSize: 11.5, weight: .semibold)
        renewButton.target = self
        renewButton.action = #selector(renewTapped)
        renewButton.isHidden = true
        if #available(macOS 11.0, *) {
            renewButton.bezelColor = NDMChrome.accent
        }

        for view in [glyph, titleLabel, badgeLabel, subtitleLabel, progressBar, trailingLabel, renewButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let titleTop = titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        let badgeHeight = badgeLabel.heightAnchor.constraint(equalToConstant: 16)
        let barTop = progressBar.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 6)
        let barHeight = progressBar.heightAnchor.constraint(equalToConstant: 4)
        self.titleTop = titleTop
        self.badgeHeight = badgeHeight
        progressTop = barTop
        progressHeight = barHeight
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleTop,
            titleLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingLabel.leadingAnchor, constant: -10),

            badgeLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            badgeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            badgeHeight,
            badgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingLabel.leadingAnchor, constant: -8),

            trailingLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            trailingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            renewButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            renewButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            barTop,
            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            progressBar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            barHeight,
        ])
    }

    @objc private func renewTapped() { onInlineRenew?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: TaskRowPresentation, scale: CGFloat) {
        glyph.setContentScale(scale)
        titleLabel.font = .systemFont(ofSize: 13 * scale, weight: .semibold)
        badgeLabel.font = .systemFont(ofSize: 10 * scale, weight: .bold)
        subtitleLabel.font = .systemFont(ofSize: 11.5 * scale)
        trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .semibold)
        renewButton.font = .systemFont(ofSize: 11.5 * scale, weight: .semibold)
        titleTop?.constant = 12 * scale
        badgeHeight?.constant = 16 * scale

        let cover = CoverArtCache.shared.image(for: row.taskID)
        glyph.apply(filename: row.filename, cover: cover)
        titleLabel.stringValue = row.filename
        titleLabel.textColor = .labelColor
        trailingLabel.textColor = .labelColor

        if let badge = row.mediaBadge {
            badgeLabel.stringValue = " \(badge) "
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }

        if row.isFailed, let error = row.errorText, !error.isEmpty {
            subtitleLabel.attributedStringValue = Self.errorSubtitle(error, scale: scale)
        } else if row.isComplete {
            let head = NSMutableAttributedString(string: L10n.completed, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5 * scale, weight: .semibold),
                .foregroundColor: NSColor.systemGreen,
            ])
            if !row.statusDetail.isEmpty, row.statusDetail != L10n.completed {
                head.append(NSAttributedString(string: " · \(row.statusDetail)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5 * scale),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            subtitleLabel.attributedStringValue = head
        } else {
            subtitleLabel.stringValue = row.statusDetail
            subtitleLabel.textColor = .secondaryLabelColor
        }

        let showRenew = row.isFailed && row.canRenew
        renewButton.isHidden = !showRenew
        trailingLabel.isHidden = showRenew

        let showBar = row.isDownloading
        progressBar.isHidden = !showBar
        progressTop?.constant = showBar ? 7 * scale : 0
        // ThinProgressView owns a fixed 4 pt hairline. Scaling this constraint
        // would fight its internal height constraint.
        progressHeight?.constant = showBar ? 4 : 0
        if showBar {
            progressBar.progress = row.progressFraction
            // Design Suite: bold speed leads; percent is secondary.
            let speed = row.speedText
            if speed != L10n.emDash && speed != "—" {
                trailingLabel.stringValue = "\(speed) · \(row.progressText)"
            } else {
                trailingLabel.stringValue = row.progressText
            }
            trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .bold)
            trailingLabel.textColor = .labelColor
        } else if !showRenew {
            trailingLabel.stringValue = row.sizeText
            trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .semibold)
            trailingLabel.textColor = .secondaryLabelColor
        }
    }

    private static func errorSubtitle(_ summary: String, scale: CGFloat) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11 * scale)
        let result = NSMutableAttributedString()
        if let sep = summary.range(of: " · ") {
            let head = String(summary[..<sep.lowerBound])
            let rest = String(summary[sep.lowerBound...])
            result.append(NSAttributedString(string: head, attributes: [
                .font: NSFont.systemFont(ofSize: 11 * scale, weight: .semibold),
                .foregroundColor: NSColor.systemRed,
            ]))
            result.append(NSAttributedString(string: rest, attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        } else {
            result.append(NSAttributedString(string: summary, attributes: [
                .font: font,
                .foregroundColor: NSColor.systemRed,
            ]))
        }
        return result
    }
}

// MARK: - Inspector

/// Flat Get Info inspector with a quiet, file-derived ambient preview.
@MainActor
private final class InspectorViewController: NSViewController {
    var onAction: ((TaskListContextAction) -> Void)?
    var onShare: ((NSView) -> Void)?

    private let titleLabel = NSTextField(labelWithString: L10n.details)
    private let glanceValueLabel = NSTextField(labelWithString: "")
    private let glanceUnitLabel = NSTextField(labelWithString: "")
    private let glanceCaptionLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = ThinProgressView()
    private let kvStack = NSStackView()
    private let primaryButton = NSButton(title: L10n.start, target: nil, action: nil)
    private let secondaryButton = NSButton(title: L10n.pause, target: nil, action: nil)
    private let tertiaryButton = NSButton(title: L10n.detailsEllipsis, target: nil, action: nil)
    private let copyURLButton = NSButton(title: L10n.copyURL, target: nil, action: nil)
    private let moreButton = NSButton(title: "", target: nil, action: nil)
    private let deleteButton = NSButton(title: L10n.removeEllipsis, target: nil, action: nil)
    private let placeholderLabel = NSTextField(wrappingLabelWithString: L10n.selectDownloadHint)
    private let contentStack = NSStackView()
    private let glanceRow = NSStackView()
    private let actionsStack = NSStackView()
    private let actionDivider = ChromeBox(fill: NDMChrome.hairline)
    private let firstActionSeparator = ChromeBox(fill: NDMChrome.hairline)
    private let secondActionSeparator = ChromeBox(fill: NDMChrome.hairline)
    private let ambientArtifactView = InspectorArtifactView()
    private let completionStackView = CompletionStackView()
    private let diagBox = ChromeBox(
        fill: NSColor.systemRed.withAlphaComponent(0.08),
        cornerRadius: 8
    )
    private let diagTitleLabel = NSTextField(wrappingLabelWithString: "")
    private let diagMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let diagRawLabel = NSTextField(labelWithString: "")
    private let tuneBox = ChromeBox(
        fill: NDMChrome.okSoft,
        borderColor: NSColor.systemGreen.withAlphaComponent(0.22),
        cornerRadius: 9,
        borderWidth: 1
    )
    private let tuneLabel = NSTextField(wrappingLabelWithString: "")
    private var progressButtonShowsConnectionDetails = false
    private var primaryFiresRenew = false
    private var utilityButtonSharesFile = false
    private var currentRow: TaskRowPresentation?
    private var contentScale: CGFloat = InterfaceScale.default
    private var actionButtonHeights: [NSLayoutConstraint] = []
    private var iconSizeConstraints: [NSLayoutConstraint] = []
    private var ambientHeightConstraint: NSLayoutConstraint?
    private var completionResultURL: URL?
#if DEBUG
    private var qaCompletionSidecarCount = -1
#endif

    override func loadView() {
        view = ChromeBox(fill: NDMChrome.contentSurface)
        view.wantsLayer = true
        view.layer?.masksToBounds = true

        ambientArtifactView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .tertiaryLabelColor

        glanceValueLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        glanceValueLabel.textColor = .labelColor
        glanceValueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        glanceUnitLabel.font = .systemFont(ofSize: 15, weight: .medium)
        glanceUnitLabel.textColor = .labelColor
        glanceCaptionLabel.font = .systemFont(ofSize: 12, weight: .regular)
        glanceCaptionLabel.textColor = .secondaryLabelColor

        glanceRow.orientation = .horizontal
        glanceRow.alignment = .firstBaseline
        glanceRow.spacing = 4
        glanceRow.addArrangedSubview(glanceValueLabel)
        glanceRow.addArrangedSubview(glanceUnitLabel)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        filenameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        filenameLabel.alignment = .left
        filenameLabel.maximumNumberOfLines = 1
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.usesSingleLineMode = true
        filenameLabel.cell?.wraps = false
        filenameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filenameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filenameLabel.toolTip = nil

        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        kvStack.orientation = .vertical
        kvStack.alignment = .leading
        kvStack.spacing = 8

        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NDMChrome.styleMainButton(primaryButton)
        NDMChrome.styleGhostButton(secondaryButton)
        NDMChrome.styleGhostButton(tertiaryButton)
        NDMChrome.styleGhostButton(copyURLButton)
        NDMChrome.styleDangerButton(deleteButton)
        primaryButton.keyEquivalent = "\r"

        primaryButton.action = #selector(tapPrimary)
        primaryButton.target = self
        secondaryButton.action = #selector(tapSecondary)
        secondaryButton.target = self
        tertiaryButton.action = #selector(tapProgress)
        tertiaryButton.target = self
        copyURLButton.action = #selector(tapCopyURL)
        copyURLButton.target = self
        moreButton.action = #selector(tapMore)
        moreButton.target = self
        moreButton.isBordered = false
        moreButton.bezelStyle = .inline
        moreButton.imagePosition = .imageOnly
        moreButton.toolTip = L10n.moreActions
        moreButton.setAccessibilityLabel(L10n.moreActions)
        deleteButton.action = #selector(tapDelete)
        deleteButton.target = self

        // The file itself leads the inspector. A quiet, bounded type mark uses
        // the otherwise empty lower-right corner without becoming a fake player.
        filenameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 12)
        let nameBlock = NSStackView(views: [filenameLabel, statusLabel])
        nameBlock.orientation = .vertical
        nameBlock.alignment = .leading
        nameBlock.spacing = 3
        nameBlock.setHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [iconView, nameBlock])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        nameBlock.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Third-concept action rail: native, flat and direct. Separators create
        // rhythm without turning each action into a bordered form control.
        tertiaryButton.isHidden = true
        deleteButton.isHidden = true

        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = 10
        actionsStack.distribution = .fill
        actionsStack.addArrangedSubview(primaryButton)
        actionsStack.addArrangedSubview(firstActionSeparator)
        actionsStack.addArrangedSubview(secondaryButton)
        actionsStack.addArrangedSubview(secondActionSeparator)
        actionsStack.addArrangedSubview(copyURLButton)
        actionsStack.addArrangedSubview(moreButton)

        // Diagnostic note — headline + plain-language explanation + raw code.
        diagTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        diagTitleLabel.textColor = .labelColor
        diagTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        diagMessageLabel.font = .systemFont(ofSize: 11)
        diagMessageLabel.textColor = .secondaryLabelColor
        diagMessageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        diagRawLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        diagRawLabel.textColor = .tertiaryLabelColor
        let diagStack = NSStackView(views: [diagTitleLabel, diagMessageLabel, diagRawLabel])
        diagStack.orientation = .vertical
        diagStack.alignment = .leading
        diagStack.spacing = 5
        diagStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        diagStack.translatesAutoresizingMaskIntoConstraints = false
        diagBox.translatesAutoresizingMaskIntoConstraints = false
        diagBox.addSubview(diagStack)

        // "为什么这么快" — smart tuning transparency note (green, quiet).
        tuneLabel.font = .systemFont(ofSize: 11)
        tuneLabel.textColor = .labelColor
        tuneLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tuneStack = NSStackView(views: [tuneLabel])
        tuneStack.orientation = .vertical
        tuneStack.alignment = .leading
        tuneStack.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        tuneStack.translatesAutoresizingMaskIntoConstraints = false
        tuneBox.translatesAutoresizingMaskIntoConstraints = false
        tuneBox.addSubview(tuneStack)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 12, right: 14)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        // Actions belong with the selected item, directly after its information;
        // they should not float at the bottom of a mostly empty inspector.
        for sub in [titleLabel, header, kvStack, completionStackView, progressBar, actionDivider, actionsStack, tuneBox, diagBox] {
            contentStack.addArrangedSubview(sub)
        }
        contentStack.setCustomSpacing(14, after: titleLabel)
        contentStack.setCustomSpacing(14, after: header)
        contentStack.setCustomSpacing(14, after: progressBar)
        contentStack.setCustomSpacing(10, after: actionDivider)
        glanceRow.isHidden = true
        glanceCaptionLabel.isHidden = true
        let actionButtonHeights = [primaryButton, secondaryButton, copyURLButton, moreButton].map {
            $0.heightAnchor.constraint(equalToConstant: 34)
        }
        self.actionButtonHeights = actionButtonHeights
        iconSizeConstraints = [
            iconView.widthAnchor.constraint(equalToConstant: 54),
            iconView.heightAnchor.constraint(equalToConstant: 54),
        ]
        ambientHeightConstraint = ambientArtifactView.heightAnchor.constraint(equalToConstant: 230)
        NSLayoutConstraint.activate([
            diagBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            diagStack.topAnchor.constraint(equalTo: diagBox.topAnchor),
            diagStack.leadingAnchor.constraint(equalTo: diagBox.leadingAnchor),
            diagStack.trailingAnchor.constraint(equalTo: diagBox.trailingAnchor),
            diagStack.bottomAnchor.constraint(equalTo: diagBox.bottomAnchor),
            diagTitleLabel.widthAnchor.constraint(equalTo: diagStack.widthAnchor, constant: -24),
            diagMessageLabel.widthAnchor.constraint(equalTo: diagStack.widthAnchor, constant: -24),
            tuneBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            tuneStack.topAnchor.constraint(equalTo: tuneBox.topAnchor),
            tuneStack.leadingAnchor.constraint(equalTo: tuneBox.leadingAnchor),
            tuneStack.trailingAnchor.constraint(equalTo: tuneBox.trailingAnchor),
            tuneStack.bottomAnchor.constraint(equalTo: tuneBox.bottomAnchor),
            tuneLabel.widthAnchor.constraint(equalTo: tuneStack.widthAnchor, constant: -24),
        ])
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ambientArtifactView)
        view.addSubview(contentStack)
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            ambientArtifactView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ambientArtifactView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ambientArtifactView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: view.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            progressBar.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            kvStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            completionStackView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            actionDivider.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            actionDivider.heightAnchor.constraint(equalToConstant: 1),
            actionsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            firstActionSeparator.widthAnchor.constraint(equalToConstant: 1),
            firstActionSeparator.heightAnchor.constraint(equalToConstant: 22),
            secondActionSeparator.widthAnchor.constraint(equalToConstant: 1),
            secondActionSeparator.heightAnchor.constraint(equalToConstant: 22),
            moreButton.widthAnchor.constraint(equalToConstant: 28),
            actionButtonHeights[0],
            actionButtonHeights[1],
            actionButtonHeights[2],
            actionButtonHeights[3],
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            ambientHeightConstraint!,
        ] + iconSizeConstraints)

        NotificationCenter.default.addObserver(
            forName: CoverArtCache.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let taskID = note.userInfo?["taskID"] as? Int64 else { return }
            Task { @MainActor [weak self] in
                guard let self, taskID == self.currentRow?.taskID else { return }
                self.refreshAmbientPreview()
            }
        }
        update(row: nil)
    }

    func setContentScale(_ scale: CGFloat) {
        let next = min(InterfaceScale.maximum, max(InterfaceScale.minimum, scale))
        let changed = abs(contentScale - next) > 0.000_1
        contentScale = next
        if !isViewLoaded { _ = view }
        guard changed else { return }

        titleLabel.font = .systemFont(ofSize: 10 * next, weight: .semibold)
        filenameLabel.font = .systemFont(ofSize: 15 * next, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 12 * next)
        placeholderLabel.font = .systemFont(ofSize: 13 * next)
        diagTitleLabel.font = .systemFont(ofSize: 12 * next, weight: .semibold)
        diagMessageLabel.font = .systemFont(ofSize: 11 * next)
        diagRawLabel.font = .monospacedSystemFont(ofSize: 9 * next, weight: .regular)
        tuneLabel.font = .systemFont(ofSize: 11 * next)
        completionStackView.setContentScale(next)

        let layoutScale = 1 + (next - 1) * 0.45
        kvStack.spacing = 8 * layoutScale
        contentStack.spacing = 12 * layoutScale
        actionsStack.spacing = 10 * layoutScale
        actionButtonHeights.forEach { $0.constant = 34 * layoutScale }
        moreButton.image = NDMChrome.symbol("ellipsis", pointSize: 12 * layoutScale, weight: .semibold)
        iconSizeConstraints.forEach { $0.constant = 54 * layoutScale }
        ambientHeightConstraint?.constant = 230 * layoutScale
        ambientArtifactView.setContentScale(next)
        update(row: currentRow)
        view.needsLayout = true
    }

    private enum ActionChrome {
        case primary
        case soft
    }

    private func decorate(
        _ button: NSButton,
        title: String,
        symbol: String,
        chrome: ActionChrome
    ) {
        button.title = title
        button.toolTip = title
        button.isBordered = false
        button.bezelStyle = .inline
        button.controlSize = .regular
        button.image = NDMChrome.symbol(
            symbol,
            pointSize: 12.5 * (1 + (contentScale - 1) * 0.45),
            weight: chrome == .primary ? .semibold : .medium
        )
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        let buttonScale = 1 + (contentScale - 1) * 0.52
        switch chrome {
        case .primary:
            button.font = .systemFont(ofSize: 12.5 * buttonScale, weight: .semibold)
            button.contentTintColor = NDMChrome.accent
        case .soft:
            button.font = .systemFont(ofSize: 12.5 * buttonScale, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
        }
    }

    private func refreshAmbientPreview() {
        guard let row = currentRow else {
            iconView.image = nil
            ambientArtifactView.apply(image: nil, filename: "")
            return
        }
        let preview = CoverArtCache.shared.image(for: row.taskID)
        let image = preview ?? NDMChrome.fileIcon(filename: row.filename, pointSize: 192)
        iconView.image = image
        // The small header icon stays literal. The ambient mark is decorative,
        // bounded, and intentionally non-interactive.
        ambientArtifactView.apply(
            image: preview,
            filename: row.filename
        )
    }

    private func fileTypeText(for row: TaskRowPresentation) -> String {
        let ext = (row.filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return L10n.other }
        return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
    }

    private func locationText(for row: TaskRowPresentation) -> String? {
        guard let folder = row.localFileURL?.deletingLastPathComponent() else { return nil }
        let name = folder.lastPathComponent
        return name.isEmpty ? folder.path : name
    }

    private func makeKVRow(key: String, value: String) -> NSView {
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 11 * contentScale)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12 * contentScale, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.maximumNumberOfLines = 1
        valueLabel.usesSingleLineMode = true
        valueLabel.toolTip = value
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [keyLabel, valueLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.distribution = .fill
        NSLayoutConstraint.activate([
            keyLabel.widthAnchor.constraint(equalToConstant: 64),
        ])
        return row
    }

    private func reloadKV(_ pairs: [(String, String)]) {
        kvStack.arrangedSubviews.forEach {
            kvStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for pair in pairs where !pair.1.isEmpty {
            kvStack.addArrangedSubview(makeKVRow(key: pair.0, value: pair.1))
        }
    }

    private func applyGlance(value: String, unit: String, caption: String) {
        glanceValueLabel.stringValue = value
        glanceUnitLabel.stringValue = unit
        glanceUnitLabel.isHidden = unit.isEmpty
        glanceCaptionLabel.stringValue = caption
    }

    /// Split `"20.1 MB"` / `"37%"` into glance magnitude + unit.
    private static func splitMagnitude(_ text: String) -> (String, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("%") { return (trimmed, "") }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        return (trimmed, "")
    }

    func relocalizeChrome() {
        titleLabel.stringValue = L10n.details.uppercased()
        placeholderLabel.stringValue = L10n.selectDownloadHint
        completionStackView.relocalize()
        let row = currentRow
        currentRow = nil
        update(row: row)
    }

    func update(row: TaskRowPresentation?) {
        guard currentRow != row else { return }
        currentRow = row
        let hasSelection = row != nil
        placeholderLabel.isHidden = hasSelection
        contentStack.isHidden = !hasSelection
        actionsStack.isHidden = !hasSelection
        ambientArtifactView.isHidden = !hasSelection
        titleLabel.stringValue = L10n.details.uppercased()
        guard let row else {
            completionResultURL = nil
            completionStackView.apply(nil)
            refreshAmbientPreview()
            return
        }

        refreshAmbientPreview()

        filenameLabel.stringValue = row.filename
        filenameLabel.toolTip = row.filename
        // Design Suite: "host · Downloading" under the title — not a giant glance.
        if row.host.isEmpty {
            statusLabel.stringValue = row.statusTitle
        } else {
            statusLabel.stringValue = "\(row.host) · \(row.statusTitle)"
        }
        glanceValueLabel.isHidden = true
        glanceUnitLabel.isHidden = true
        glanceCaptionLabel.isHidden = true

        if let diag = row.diagnostic {
            diagTitleLabel.stringValue = diag.title
            diagMessageLabel.stringValue = diag.message
            diagRawLabel.stringValue = diag.rawLabel
            diagRawLabel.isHidden = diag.rawLabel.isEmpty
            diagBox.isHidden = false
        } else if let error = row.errorText, !error.isEmpty {
            diagTitleLabel.stringValue = L10n.downloadFailed
            diagMessageLabel.stringValue = error
            diagRawLabel.stringValue = ""
            diagRawLabel.isHidden = true
            diagBox.isHidden = false
        } else {
            diagBox.isHidden = true
        }

        if let note = row.tuningNote {
            tuneLabel.stringValue = "\(L10n.whySoFastPrefix)\(note)"
            tuneBox.isHidden = false
        } else {
            tuneBox.isHidden = true
        }

        if row.isComplete {
            // The sidecar discovery walks the download directory; do it once
            // per selected result instead of on every one-second refresh.
            if completionResultURL != row.localFileURL {
                let discoveredCompletion = SmartFinalize.completionStack(primary: row.localFileURL)
                completionResultURL = row.localFileURL
                completionStackView.apply(discoveredCompletion)
                completionStackView.setContentScale(contentScale)
#if DEBUG
                qaCompletionSidecarCount = discoveredCompletion?.sidecars.count ?? -1
#endif
            }
#if DEBUG
            if QAPreviewOverrides.isEnabled {
                statusLabel.stringValue = "QA成果\(qaCompletionSidecarCount) · " + statusLabel.stringValue
            }
#endif
            progressBar.isHidden = true
            var pairs: [(String, String)] = [(L10n.size, row.sizeText)]
            if !row.host.isEmpty { pairs.append((L10n.source, row.host)) }
            pairs.append((L10n.type, fileTypeText(for: row)))
            if let location = locationText(for: row) {
                pairs.append((L10n.location, location))
            }
            reloadKV(pairs)
        } else {
            completionResultURL = nil
            completionStackView.apply(nil)
            progressBar.isHidden = !row.isDownloading
            progressBar.progress = row.progressFraction
            var pairs: [(String, String)] = [(L10n.size, row.sizeText)]
            if row.speedText != L10n.emDash && row.speedText != "—" {
                pairs.append((L10n.speed, row.speedText))
            }
            if row.etaText != L10n.emDash && row.etaText != "—" {
                pairs.append((L10n.timeLeft, row.etaText))
            }
            if row.isDownloading, let n = Int(row.connectionsText), n > 0 {
                pairs.append((L10n.connections, "\(n) / \(n)"))
            }
            pairs.append((L10n.type, fileTypeText(for: row)))
            reloadKV(pairs)
        }

        tertiaryButton.isHidden = true
        utilityButtonSharesFile = row.canOpen
        // Flat utility rail from the selected third concept.
        if row.canOpen {
            decorate(primaryButton, title: L10n.open, symbol: "arrow.up.forward.app", chrome: .primary)
            primaryButton.isEnabled = true
            decorate(secondaryButton, title: L10n.showInFinder, symbol: "folder", chrome: .soft)
            secondaryButton.isEnabled = row.canShowInFinder
            progressButtonShowsConnectionDetails = false
        } else if row.canRetry {
            primaryFiresRenew = row.diagnostic?.primaryAction == .renew && row.canRenew
            if primaryFiresRenew {
                decorate(primaryButton, title: L10n.renew, symbol: "arrow.triangle.2.circlepath", chrome: .primary)
                primaryButton.isEnabled = true
                decorate(secondaryButton, title: L10n.retry, symbol: "arrow.clockwise", chrome: .soft)
                secondaryButton.isEnabled = true
            } else {
                decorate(primaryButton, title: L10n.retry, symbol: "arrow.clockwise", chrome: .primary)
                primaryButton.isEnabled = true
                decorate(secondaryButton, title: L10n.renew, symbol: "arrow.triangle.2.circlepath", chrome: .soft)
                secondaryButton.isEnabled = row.canRenew
            }
            progressButtonShowsConnectionDetails = true
        } else if row.canPause {
            decorate(primaryButton, title: L10n.pause, symbol: "pause.fill", chrome: .primary)
            primaryButton.isEnabled = true
            decorate(secondaryButton, title: L10n.detailsEllipsis, symbol: "info.circle", chrome: .soft)
            secondaryButton.isEnabled = row.canShowProgress
            progressButtonShowsConnectionDetails = true
        } else {
            decorate(primaryButton, title: L10n.start, symbol: "play.fill", chrome: .primary)
            primaryButton.isEnabled = row.canStart
            decorate(secondaryButton, title: L10n.detailsEllipsis, symbol: "info.circle", chrome: .soft)
            secondaryButton.isEnabled = row.canShowProgress
            progressButtonShowsConnectionDetails = false
        }

        if utilityButtonSharesFile {
            decorate(copyURLButton, title: L10n.share, symbol: "square.and.arrow.up", chrome: .soft)
            copyURLButton.toolTip = L10n.share
        } else {
            decorate(copyURLButton, title: L10n.copyURL, symbol: "link", chrome: .soft)
            copyURLButton.toolTip = L10n.copyURL
        }
        moreButton.image = NDMChrome.symbol(
            "ellipsis",
            pointSize: 12 * (1 + (contentScale - 1) * 0.45),
            weight: .semibold
        )
        moreButton.toolTip = L10n.moreActions
        moreButton.setAccessibilityLabel(L10n.moreActions)
        deleteButton.isHidden = true
    }

    @objc private func tapPrimary() {
        guard let row = currentRow else { return }
        if row.canOpen {
            onAction?(.open)
        } else if row.canRetry {
            onAction?(primaryFiresRenew ? .renew : .retry)
        } else if row.canPause {
            onAction?(.pause)
        } else {
            onAction?(.start)
        }
    }

    @objc private func tapSecondary() {
        guard let row = currentRow else { return }
        if row.isComplete {
            onAction?(.reveal)
        } else if row.canRetry && primaryFiresRenew {
            onAction?(.retry)
        } else if row.canRenew && (row.canRetry || !row.canPause) {
            onAction?(.renew)
        } else if row.canShowProgress {
            onAction?(.progress)
        }
    }

    @objc private func tapProgress() {
        guard let row = currentRow else { return }
        if progressButtonShowsConnectionDetails, row.canShowProgress {
            onAction?(.progress)
        } else if row.canShowProgress && (row.canRetry || row.canPause) {
            onAction?(.progress)
        } else {
            onAction?(.properties)
        }
    }

    @objc private func tapCopyURL() {
        if utilityButtonSharesFile {
            onShare?(copyURLButton)
        } else {
            onAction?(.copyURL)
        }
    }

    @objc private func tapMore() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if utilityButtonSharesFile {
            addMoreItem(menu, title: L10n.quickLook, selector: #selector(moreQuickLook), symbol: "eye")
            addMoreItem(menu, title: L10n.copyURL, selector: #selector(moreCopyURL), symbol: "link")
        }
        addMoreItem(menu, title: L10n.propertiesEllipsis, selector: #selector(moreProperties), symbol: "info.circle")
        menu.addItem(.separator())
        addMoreItem(menu, title: L10n.removeEllipsis, selector: #selector(moreDelete), symbol: "trash")
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: moreButton.bounds.minX, y: moreButton.bounds.maxY + 4),
            in: moreButton
        )
    }

    private func addMoreItem(_ menu: NSMenu, title: String, selector: Selector, symbol: String) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.ndmSymbol(symbol)
        item.isEnabled = true
        menu.addItem(item)
    }

    @objc private func moreQuickLook() { onAction?(.quickLook) }
    @objc private func moreCopyURL() { onAction?(.copyURL) }
    @objc private func moreProperties() { onAction?(.properties) }
    @objc private func moreDelete() { onAction?(.delete) }
    @objc private func tapDelete() { onAction?(.delete) }
}

// MARK: - Drop target

private final class URLDropView: NSView {
    var onDropURL: ((String) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    /// Appearance-correct background (resolved in updateLayer, never snapshotted).
    var fill: NSColor? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.URL, .string])
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill?.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHoverChange?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHoverChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHoverChange?(false)
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            onDropURL?(first.absoluteString)
            return true
        }
        if let text = pb.string(forType: .string),
           let resolution = SharedLinkResolver.resolve(text) {
            onDropURL?(resolution.urlString)
            return true
        }
        return false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onHoverChange?(false)
    }
}
