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
    private let startsCompact: Bool

    var onOpenSettings: (() -> Void)?

    private var allTasks: [DownloadTask] = []
    private var progressByID: [Int64: DownloadProgress] = [:]
    private var displayedRows: [TaskRowPresentation] = []
    private var selectedFilter: SidebarFilter = QAPreviewOverrides.initialFilter ?? .all
    private var searchQuery = ""
    private var selectedTaskID: Int64?
    /// Establish a useful launch focus once, without re-selecting after the
    /// user deliberately clears selection during later one-second refreshes.
    private var hasEstablishedInitialSelection = false

    private let splitController = NSSplitViewController()
    private let sidebarController = SidebarViewController()
    private let listController = TaskListViewController()
    private let inspectorController = InspectorViewController()
    private let fileSharePresenter = FileSharePresenter()

    private var progressWindows: [Int64: ProgressWindowController] = [:]
    private var propsWindow: TaskPropertiesWindowController?
    private var browsersWindow: BrowsersWindowController?
    private var refreshTask: Task<Void, Never>?
    private var previewedFileURL: URL?

    private var startToolbarItem: NSToolbarItem?
    private var pauseToolbarItem: NSToolbarItem?
    private let chromeRoot = NSViewController()
    private let contentToolbar = DesignSuiteToolbarView()
    private var clipboardOffer: SharedLinkResolution?

    init(manager: DownloadManager) {
        self.manager = manager
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
        let availableWidth = max(1, visible.width - 32)
        let availableHeight = max(1, visible.height - 32)
        self.startsCompact = availableWidth < 1060
        // AppKit measures windows in logical points, not Retina backing pixels.
        // 1440 × 960 keeps all three columns comfortably above their minimum
        // thickness (sidebar 215 + list 420 + inspector 360 = 995pt) on a
        // 1728 × 1117-class desktop while still leaving room for the window
        // boundary. The floor below matches `minSize` so the launch frame is
        // never smaller than what the sidebar needs to render fully.
        let preferredFrameSize = QAPreviewOverrides.windowSize
            ?? NSSize(width: 1440, height: 960)
        let initialFrameSize = NSSize(
            width: min(preferredFrameSize.width, availableWidth),
            height: min(preferredFrameSize.height, availableHeight)
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
        // Never make the minimum larger than the active display. On compact
        // screens the inspector launches collapsed and the remaining columns
        // use smaller, still-usable floors.
        window.minSize = NSSize(
            width: min(1060, availableWidth),
            height: min(680, availableHeight)
        )
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
        NotificationCenter.default.addObserver(
            forName: NDMChrome.accentDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.relocalizeChrome()
                self?.window?.contentView?.needsDisplay = true
                self?.window?.contentView?.displayIfNeeded()
            }
        }
        applyContentScale()
        Task { await reload() }
        startAutoRefresh()
    }

    private var hasPlayedEntrance = false

    override func showWindow(_ sender: Any?) {
        guard !hasPlayedEntrance, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            super.showWindow(sender)
            hasPlayedEntrance = true
            return
        }
        hasPlayedEntrance = true
        window?.alphaValue = 0
        super.showWindow(sender)
        guard let window else { return }
        window.contentView?.wantsLayer = true
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.96
        scale.toValue = 1.0
        scale.duration = 0.35
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        window.contentView?.layer?.add(scale, forKey: "entrance")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
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
            self?.rebuildDisplayedRows()
        }
    }

    private func configureSplit() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        // Room for semantic zoom without turning the navigation into a squeeze.
        sidebarItem.minimumThickness = startsCompact ? 180 : 215
        sidebarItem.maximumThickness = 268
        sidebarItem.preferredThicknessFraction = 0.175
        if #available(macOS 11.0, *) {
            sidebarItem.titlebarSeparatorStyle = .none
        }

        let listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = startsCompact ? 320 : 420

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        // Full action labels (especially “Show in Finder”) need a real inspector,
        // not a narrow utility strip.
        inspectorItem.minimumThickness = 360
        inspectorItem.maximumThickness = 450
        inspectorItem.preferredThicknessFraction = 0.30
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = startsCompact
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(260)

        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(listItem)
        splitController.addSplitViewItem(inspectorItem)
        // Bumped so a previously-narrowed sidebar divider (saved before the
        // launch window was made larger) doesn't reappear crushed.
        splitController.splitView.autosaveName = "NDM.MainSplit.v9"
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
            self?.rebuildDisplayedRows()
        }
        listController.onSelectTaskID = { [weak self] taskID in
            self?.selectedTaskID = taskID
            self?.updateInspector()
            self?.updateToolbarEnablement()
        }
        listController.onSelectMultipleTaskIDs = { [weak self] taskIDs in
            self?.inspectorController.showMultiSelection(count: taskIDs.count)
            self?.updateToolbarEnablement()
        }
        listController.onBatchAction = { [weak self] action, taskIDs in
            self?.handleBatchAction(action, taskIDs: taskIDs)
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
            // Persisted waiting tasks are a durable collection queue, not live
            // engines. Asking for progress for every queued item makes large
            // playlists needlessly cross the actor boundary thousands of times.
            for task in allTasks where task.status == .downloading {
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
            rebuildDisplayedRows()
        } catch {
            showAlert(error)
        }
    }

    private func rebuildDisplayedRows() {
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
        if !hasEstablishedInitialSelection, !displayedRows.isEmpty {
            hasEstablishedInitialSelection = true
            let qaPreferredTaskID = QAPreviewOverrides.selectedFilenameContains.flatMap { needle in
                displayedRows.first {
                    $0.filename.localizedCaseInsensitiveContains(needle)
                }?.taskID
            }
            selectedTaskID = selectedTaskID ?? qaPreferredTaskID ?? displayedRows.first?.taskID
            if QAPreviewOverrides.showProgress, let id = selectedTaskID {
                showProgress(for: id)
            }
        }
        // Keep the selected task only while it stays visible. Never select on
        // the user's behalf after the one-time launch focus: this runs from the
        // 1 s auto-refresh, so repeatedly inventing a selection would fight an
        // explicit deselection and silently swap the inspector.
        if let selectedTaskID,
           !displayedRows.contains(where: { $0.taskID == selectedTaskID }) {
            self.selectedTaskID = nil
        }
        listController.update(
            rows: displayedRows,
            selectedTaskID: selectedTaskID,
            emptyTitle: emptyStateTitle(),
            emptySubtitle: emptyStateSubtitle(),
            // Action buttons only for the true first-run empty state,
            // not for empty filter/search results.
            emptyShowsActions: allTasks.isEmpty && searchQuery.isEmpty,
            headerTitle: searchQuery.isEmpty
                ? selectedFilter.title
                : L10n.searchResultsTitle,
            headerMeta: L10n.headerTaskCount(displayedRows.count),
            // Media filters open as a poster wall; general files stay a list.
            preferGallery: selectedFilter == .video || selectedFilter == .image
        )
        updateInspector()
        updateToolbarEnablement()
        let snapshot = statusBarSnapshot()
        // The Now Downloading cinema strip carries live traffic now; a second
        // "N active · speed" chip in the toolbar would say the same thing twice.
        contentToolbar.setActivitySummary(activeCount: 0, bytesPerSecond: 0)
        if snapshot.activeCount > 0 {
            let speed = TaskPresentationFormatting.speed(snapshot.bytesPerSecond, status: .downloading)
            window?.title = "\(L10n.appName) — \(snapshot.activeCount)↓ \(speed)"
        } else {
            window?.title = L10n.appName
        }
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
        // Expand once on the first selection, then never auto-collapse.
        // Auto-collapsing on deselect reflowed the whole content column on
        // every click — in the gallery that reshuffled the poster grid
        // mid-click (4 columns → 3 and back) so the second click landed on a
        // card that had already moved. A stable column with a quiet
        // placeholder when nothing is selected beats a layout that jumps.
        if let inspectorItem = splitController.splitViewItems.last,
           selectedTaskID != nil, inspectorItem.isCollapsed {
            if window?.isVisible == true {
                inspectorItem.animator().isCollapsed = false
            } else {
                inspectorItem.isCollapsed = false
            }
        }
    }

    private func refreshLiveProgress() async {
#if DEBUG
        let signpostID = NDMPerformance.begin("LiveProgressRefresh")
        defer { NDMPerformance.end("LiveProgressRefresh", id: signpostID) }
#endif
        let activeTasks = allTasks.filter { $0.status == .downloading }
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
        rebuildDisplayedRows()
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
        rebuildDisplayedRows()
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
        rebuildDisplayedRows()
    }

    @objc private func openBrowsers() {
        let wc = BrowsersWindowController(bridgeRunning: true)
        browsersWindow = wc
        wc.showWindow(nil)
    }

    @objc private func openSettings() {
        onOpenSettings?()
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
                                formatID: picked.collectionSelector(for: options.container),
                                options: options,
                                collectionURL: preparedResult?.resolvedURL ?? urlString,
                                collectionTitle: collection.title.isEmpty ? nil : collection.title,
                                estimatedSampleBytes: picked.estimatedBytes(for: options.container),
                                estimatedSampleComponentBytes: picked.estimatedComponentBytes(for: options.container),
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
                estimatedBytes: picked.estimatedBytes(for: options.container),
                estimatedComponentBytes: picked.estimatedComponentBytes(for: options.container),
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

    /// One confirmation, one reload — not N of each. `startTask`/`deleteTask`
    /// are single-row helpers with their own progress window / alert per
    /// call, which would spam the user for a multi-selection.
    private func handleBatchAction(_ action: TaskListContextAction, taskIDs: [Int64]) {
        guard !taskIDs.isEmpty else { return }
        switch action {
        case .start, .retry:
            Task {
                for id in taskIDs { try? await manager.start(taskID: id) }
                await reload()
            }
        case .pause:
            Task {
                for id in taskIDs { await manager.pause(taskID: id) }
                await reload()
            }
        case .delete:
            let alert = NSAlert()
            alert.messageText = L10n.removeConfirmMultiple(taskIDs.count)
            alert.informativeText = L10n.removeConfirmBody
            alert.addButton(withTitle: L10n.removeTask)
            alert.addButton(withTitle: L10n.removeAndTrash)
            alert.addButton(withTitle: L10n.cancel)
            let response = alert.runModal()
            let deleteFile: Bool
            switch response {
            case .alertFirstButtonReturn: deleteFile = false
            case .alertSecondButtonReturn: deleteFile = true
            default: return
            }
            Task {
                for id in taskIDs { try? await manager.remove(taskID: id, deleteFile: deleteFile) }
                await reload()
            }
        default:
            break
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
        let vibrancy = NSVisualEffectView()
        vibrancy.material = .sidebar
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .followsWindowActiveState
        view = vibrancy
        let paper = ChromeBox(fill: NDMChrome.sidebarPaperOverlay)
        paper.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(paper)
        NSLayoutConstraint.activate([
            paper.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paper.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paper.topAnchor.constraint(equalTo: view.topAnchor),
            paper.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        tableView.style = .plain
        tableView.floatsGroupRows = false
        tableView.headerView = nil
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
        tableView.scrollRowToVisible(index)
        syncSelectionAppearance()
    }

    private func syncSelectionAppearance() {
        // Walk every row, not just visibleRect: NSTableView keeps prepared row
        // views slightly outside the viewport, and one of those can be the
        // previously selected row — skipping it leaves a stale accent pill
        // that scrolls back in later.
        for row in 0..<rows.count {
            if let rowView = tableView.rowView(
                atRow: row,
                makeIfNecessary: false
            ) as? QuietFinderRowView {
                if case .filter(let filter) = rows[row] {
                    rowView.usesAccentFill = true
                    rowView.forcedSelected = (filter == selected)
                } else {
                    rowView.forcedSelected = false
                }
                rowView.needsDisplay = true
            }
            // Row chrome and cell ink can drift apart: AppKit's emphasized
            // style leaves label/icon white after deselection unless we
            // re-assert colors from the model selection.
            if case .filter(let filter) = rows[row],
               let cell = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
               ) as? SidebarFilterCellView {
                cell.apply(
                    filter: filter,
                    count: counts[filter] ?? 0,
                    selected: filter == selected,
                    scale: contentScale
                )
            }
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
        selected = filter
        // Repaint from the model instead of reloadData(): a reload here would
        // destroy row views while AppKit's mouse-tracking loop still holds
        // them, which is what made fast consecutive clicks drop or revert.
        syncSelectionAppearance()
        onSelectFilter?(filter)
    }
}

/// A quiet accent dot that breathes while there's live traffic to report,
/// and holds still (or sits steady if selected) otherwise. Respects
/// Reduce Motion by simply not animating — the dot itself still communicates
/// "active" without the pulse.
private final class BreathingDotView: NSView {
    private let dot = CALayer()
    private var isAnimating = false

    var color: NSColor = NDMChrome.accent {
        didSet { dot.backgroundColor = color.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
        dot.backgroundColor = color.cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dot.frame = bounds
        dot.cornerRadius = bounds.height / 2
    }

    func setBreathing(_ active: Bool) {
        guard active != isAnimating else { return }
        isAnimating = active
        guard active, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            dot.removeAnimation(forKey: "breathe")
            dot.opacity = 1
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.35
        animation.duration = 1.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(animation, forKey: "breathe")
    }
}

/// Sidebar filter row — ink colors driven by model selection, not AppKit emphasis.
private final class SidebarFilterCellView: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let pulseDot = BreathingDotView()
    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?
    private var appliedFilter: SidebarFilter?
    private var appliedCount = 0
    private var appliedSelected = false
    private var appliedScale: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        pulseDot.translatesAutoresizingMaskIntoConstraints = false
        pulseDot.isHidden = true
        badge.alignment = .right
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(titleLabel)
        addSubview(badge)
        addSubview(pulseDot)
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
            pulseDot.widthAnchor.constraint(equalToConstant: 6),
            pulseDot.heightAnchor.constraint(equalToConstant: 6),
            pulseDot.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -1),
            pulseDot.centerYAnchor.constraint(equalTo: icon.topAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Pin to `.normal` so AppKit never keeps the cell in emphasized/white-ink mode.
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set {
            super.backgroundStyle = .normal
            refreshInk()
        }
    }

    func apply(filter: SidebarFilter, count: Int, selected: Bool, scale: CGFloat) {
        appliedFilter = filter
        appliedCount = count
        appliedSelected = selected
        appliedScale = scale
        refreshInk()
    }

    private func refreshInk() {
        guard let filter = appliedFilter else { return }
        let selected = appliedSelected
        let scale = appliedScale
        let ink: NSColor = selected ? .white : .labelColor
        let muted: NSColor = selected ? NSColor.white.withAlphaComponent(0.78) : .tertiaryLabelColor
        let titleFont = NSFont.systemFont(ofSize: 13.5 * scale, weight: selected ? .semibold : .medium)
        let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5 * scale, weight: .regular)
        iconWidth?.constant = 17 * scale
        iconHeight?.constant = 17 * scale
        icon.image = NDMChrome.symbol(
            NDMChrome.sidebarSymbolName(for: filter),
            pointSize: 13.5 * scale,
            weight: selected ? .semibold : .medium
        )
        icon.contentTintColor = selected ? .white : .secondaryLabelColor
        titleLabel.attributedStringValue = NSAttributedString(
            string: filter.title,
            attributes: [.font: titleFont, .foregroundColor: ink]
        )
        badge.attributedStringValue = NSAttributedString(
            string: "\(appliedCount)",
            attributes: [.font: badgeFont, .foregroundColor: muted]
        )
        // "This app is currently doing something" — a quiet breathing dot on
        // the one row where that's actually true, instead of a static count.
        let showsPulse = filter == .active && appliedCount > 0
        pulseDot.isHidden = !showsPulse
        pulseDot.color = selected ? .white : NDMChrome.accent
        pulseDot.setBreathing(showsPulse)
    }
}

// MARK: - Task list

enum TaskListContextAction {
    case quickLook, open, reveal, share, start, pause, retry, renew, progress, properties, copyURL, delete
}

/// Floating bar that surfaces once more than one row is selected — plain
/// surface + top hairline, matching the app's "no gray box" chrome rather
/// than a bordered card.
private final class BatchActionBarView: NSView {
    var onStart: (() -> Void)?
    var onPause: (() -> Void)?
    var onDelete: (() -> Void)?

    private let countLabel = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: L10n.start, target: nil, action: nil)
    private let pauseButton = NSButton(title: L10n.pause, target: nil, action: nil)
    private let deleteButton = NSButton(title: L10n.removeEllipsis, target: nil, action: nil)
    private let hairline = ChromeBox(fill: NDMChrome.hairline)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        countLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        NDMChrome.styleGhostButton(startButton)
        NDMChrome.styleGhostButton(pauseButton)
        NDMChrome.styleDangerButton(deleteButton)
        startButton.target = self
        startButton.action = #selector(tapStart)
        pauseButton.target = self
        pauseButton.action = #selector(tapPause)
        deleteButton.target = self
        deleteButton.action = #selector(tapDelete)

        let actions = NSStackView(views: [startButton, pauseButton, deleteButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        hairline.translatesAutoresizingMaskIntoConstraints = false

        for view in [countLabel, actions, hairline] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NDMChrome.toolbarSurface.cgColor
    }

    func configure(count: Int, canStart: Bool, canPause: Bool) {
        countLabel.stringValue = L10n.selectedCount(count)
        startButton.isHidden = !canStart
        pauseButton.isHidden = !canPause
    }

    @objc private func tapStart() { onStart?() }
    @objc private func tapPause() { onPause?() }
    @objc private func tapDelete() { onDelete?() }
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
private final class TaskListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    var onSelectTaskID: ((Int64?) -> Void)?
    var onActivateTaskID: ((Int64) -> Void)?
    var onContextAction: ((TaskListContextAction, Int64) -> Void)?
    var onDropURL: ((String) -> Void)?
    var onEmptyNewDownload: (() -> Void)?
    var onSelectMultipleTaskIDs: (([Int64]) -> Void)?
    var onBatchAction: ((TaskListContextAction, [Int64]) -> Void)?

    private let tableView = TaskListTableView()
    private let scrollView = NSScrollView()
    private let heroView = NowDownloadingHeroView()
    private var heroHeight: NSLayoutConstraint?
    // Editorial header — the content column opens with the filter's name in
    // display type, not with a bare file list.
    private let headerTitleLabel = NSTextField(labelWithString: "")
    private let headerMetaLabel = NSTextField(labelWithString: "")
    // Poster-wall gallery — the media view of the same rows. List stays the
    // backbone for general files; video/image filters prefer the wall.
    private let galleryScroll = NSScrollView()
    private let galleryView = GalleryCollectionView()
    private let galleryLayout = NSCollectionViewFlowLayout()
    private let listModeButton = NSButton()
    private let gridModeButton = NSButton()
    private var preferGallery = false
    /// User toggle; nil follows the filter's preference. Reset on filter switch.
    private var galleryOverride: Bool?
    private var isGalleryActive: Bool { galleryOverride ?? preferGallery }
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptySubtitleLabel = NSTextField(labelWithString: "")
    private let emptyStack = NSStackView()
    private let batchBar = BatchActionBarView()
    private var rows: [TaskRowPresentation] = []
    private var selectedTaskID: Int64?
    private var suppressSelectionCallback = false
    private var contextMenuDelegate: ContextMenuDelegate?
    /// Captured while the menu opens — `clickedRow` often clears before the item action runs.
    private var menuContextTaskID: Int64?
    private var emptyActionsRow: NSStackView?
    private var contentScale: CGFloat = InterfaceScale.default
    /// Row index currently under the mouse — managed at controller level
    /// because per-cell NSTrackingArea mouseExited is unreliable during
    /// trackpad/scroll-wheel scrolling.
    private var hoveredRow: Int?

    override func loadView() {
        let root = URLDropView(frame: .zero)
        root.onDropURL = { [weak self] url in self?.onDropURL?(url) }
        root.onHoverChange = { _ in }
        view = root
        root.fill = NDMChrome.contentSurface

        tableView.headerView = nil
        // Plain + custom row paint — inset style fights single-selection redraw.
        tableView.style = .plain
        tableView.rowHeight = 70
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = NDMChrome.contentSurface
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = true
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
        galleryView.menu = tableView.menu
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
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let mark = ChromeBox(fill: NDMChrome.accent, cornerRadius: 14)
        mark.translatesAutoresizingMaskIntoConstraints = false
        let markIcon = NSImageView()
        markIcon.image = NDMChrome.symbol("arrow.down.to.line", pointSize: 22, weight: .semibold)
        markIcon.contentTintColor = .white
        markIcon.translatesAutoresizingMaskIntoConstraints = false
        markIcon.setAccessibilityElement(false)
        mark.setAccessibilityElement(false)
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

        batchBar.onStart = { [weak self] in self?.emitBatchAction(.start) }
        batchBar.onPause = { [weak self] in self?.emitBatchAction(.pause) }
        batchBar.onDelete = { [weak self] in self?.emitBatchAction(.delete) }
        batchBar.translatesAutoresizingMaskIntoConstraints = false
        batchBar.isHidden = true

        heroView.alphaValue = 0
        heroView.onActivateTask = { [weak self] taskID in
            self?.onActivateTaskID?(taskID)
        }
        let heroHeight = heroView.heightAnchor.constraint(equalToConstant: 0)
        self.heroHeight = heroHeight

        headerTitleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        headerTitleLabel.textColor = .labelColor
        headerTitleLabel.lineBreakMode = .byTruncatingTail
        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerMetaLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        headerMetaLabel.textColor = .tertiaryLabelColor
        headerMetaLabel.translatesAutoresizingMaskIntoConstraints = false

        configureModeButton(listModeButton, symbol: "list.bullet", tooltip: L10n.listViewTooltip, action: #selector(chooseListMode))
        configureModeButton(gridModeButton, symbol: "square.grid.2x2", tooltip: L10n.galleryViewTooltip, action: #selector(chooseGalleryMode))

        galleryLayout.minimumInteritemSpacing = 16
        galleryLayout.minimumLineSpacing = 22
        galleryLayout.sectionInset = NSEdgeInsets(top: 8, left: 20, bottom: 24, right: 20)
        galleryView.collectionViewLayout = galleryLayout
        galleryView.dataSource = self
        galleryView.delegate = self
        galleryView.isSelectable = true
        galleryView.allowsMultipleSelection = false
        galleryView.allowsEmptySelection = true
        galleryView.backgroundColors = [NDMChrome.contentSurface]
        galleryView.register(GalleryCardItem.self, forItemWithIdentifier: GalleryCardItem.identifier)
        galleryView.onRightClickItem = { [weak self] index in
            self?.selectGalleryItem(at: index)
        }
        galleryScroll.documentView = galleryView
        galleryScroll.hasVerticalScroller = true
        galleryScroll.autohidesScrollers = true
        galleryScroll.borderType = .noBorder
        galleryScroll.drawsBackground = true
        galleryScroll.backgroundColor = NDMChrome.contentSurface
        galleryScroll.translatesAutoresizingMaskIntoConstraints = false
        galleryScroll.isHidden = true

        view.addSubview(headerTitleLabel)
        view.addSubview(headerMetaLabel)
        view.addSubview(listModeButton)
        view.addSubview(gridModeButton)
        view.addSubview(heroView)
        view.addSubview(scrollView)
        view.addSubview(galleryScroll)
        view.addSubview(emptyStack)
        view.addSubview(batchBar)
        NSLayoutConstraint.activate([
            headerTitleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            headerTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            headerTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerMetaLabel.leadingAnchor, constant: -12),
            headerMetaLabel.firstBaselineAnchor.constraint(equalTo: headerTitleLabel.firstBaselineAnchor),
            headerMetaLabel.trailingAnchor.constraint(equalTo: listModeButton.leadingAnchor, constant: -14),
            listModeButton.centerYAnchor.constraint(equalTo: headerTitleLabel.centerYAnchor),
            listModeButton.trailingAnchor.constraint(equalTo: gridModeButton.leadingAnchor, constant: -2),
            gridModeButton.centerYAnchor.constraint(equalTo: headerTitleLabel.centerYAnchor),
            gridModeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            listModeButton.widthAnchor.constraint(equalToConstant: 28),
            listModeButton.heightAnchor.constraint(equalToConstant: 24),
            gridModeButton.widthAnchor.constraint(equalToConstant: 28),
            gridModeButton.heightAnchor.constraint(equalToConstant: 24),
            heroView.topAnchor.constraint(equalTo: headerTitleLabel.bottomAnchor, constant: 12),
            heroView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            heroView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heroHeight,
            galleryScroll.topAnchor.constraint(equalTo: heroView.bottomAnchor),
            galleryScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            galleryScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            galleryScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: heroView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            batchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            batchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            batchBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            batchBar.heightAnchor.constraint(equalToConstant: 48),
        ])

        // --- Table-level hover tracking --------------------------------
        // A single tracking area on the table view replaces unreliable per-
        // cell tracking areas. `mouseMoved` fires on every pointer movement
        // inside the table; a bounds-change observer covers trackpad/scroll-
        // wheel scrolling while the pointer stays still.
        let hoverArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited,
                      .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tableView.addTrackingArea(hoverArea)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    // MARK: - Gallery mode

    private func configureModeButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NDMChrome.symbol(symbol, pointSize: 13, weight: .medium)
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func chooseListMode() {
        galleryOverride = false
        applyViewMode()
    }

    @objc private func chooseGalleryMode() {
        galleryOverride = true
        applyViewMode()
        galleryView.reloadData()
        syncGallerySelection()
    }

    private var listIsEmpty = false

    /// Visibility + toggle tints only — reloads are the callers' business.
    private func applyViewMode() {
        let gallery = isGalleryActive
        scrollView.isHidden = gallery || listIsEmpty
        galleryScroll.isHidden = !gallery || listIsEmpty
        listModeButton.contentTintColor = gallery ? .tertiaryLabelColor : NDMChrome.accent
        gridModeButton.contentTintColor = gallery ? NDMChrome.accent : .tertiaryLabelColor
    }

    private func selectGalleryItem(at index: Int) {
        guard index < rows.count else { return }
        galleryView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        selectedTaskID = rows[index].taskID
        onSelectTaskID?(selectedTaskID)
    }

    private func syncGallerySelection() {
        guard let selectedTaskID,
              let index = rows.firstIndex(where: { $0.taskID == selectedTaskID }) else {
            galleryView.selectionIndexPaths = []
            return
        }
        galleryView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GalleryCardItem.identifier, for: indexPath)
        guard let card = item as? GalleryCardItem, indexPath.item < rows.count else { return item }
        let row = rows[indexPath.item]
        let cover = CoverArtCache.shared.image(for: row.taskID)
        if cover == nil {
            CoverArtCache.shared.ensureCover(
                taskID: row.taskID,
                remoteURL: nil,
                localFile: row.localFileURL
            )
        }
        card.apply(row, cover: cover)
        card.onActivate = { [weak self] taskID in
            self?.onActivateTaskID?(taskID)
        }
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        let insets = galleryLayout.sectionInset
        let available = collectionView.bounds.width - insets.left - insets.right
        guard available > 100 else { return NSSize(width: 220, height: 180) }
        let columns = max(2, Int(available / 250))
        let width = floor((available - galleryLayout.minimumInteritemSpacing * CGFloat(columns - 1)) / CGFloat(columns))
        return NSSize(width: width, height: floor(width * 9 / 16) + 58)
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, index < rows.count else { return }
        selectedTaskID = rows[index].taskID
        onSelectTaskID?(selectedTaskID)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        // Click-to-switch fires deselect(old) before select(new). Emitting a
        // nil selection in that gap flashes the inspector's empty state, so
        // only report nil if the selection is still empty on the next tick.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isGalleryActive,
                  self.galleryView.selectionIndexPaths.isEmpty else { return }
            self.selectedTaskID = nil
            self.onSelectTaskID?(nil)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        galleryLayout.invalidateLayout()
    }

    /// The list only reports which action was tapped; `MainWindowController`
    /// owns confirmation dialogs and the actual engine calls, same split as
    /// `onContextAction` for single-row actions.
    private func emitBatchAction(_ action: TaskListContextAction) {
        let ids = tableView.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].taskID : nil }
        guard !ids.isEmpty else { return }
        onBatchAction?(action, ids)
    }

    @objc private func emptyNewClicked() {
        onEmptyNewDownload?()
    }

    private func startEmptyFloatAnimation() {
        emptyStack.wantsLayer = true
        guard emptyStack.layer?.animation(forKey: "float") == nil else { return }
        let float = CABasicAnimation(keyPath: "transform.translation.y")
        float.fromValue = -4
        float.toValue = 4
        float.duration = 2.4
        float.autoreverses = true
        float.repeatCount = .infinity
        float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        emptyStack.layer?.add(float, forKey: "float")
    }

    private func stopEmptyFloatAnimation() {
        emptyStack.layer?.removeAnimation(forKey: "float")
    }

    func relocalizeChrome() {
        tableView.menu = makeContextMenu()
        galleryView.menu = tableView.menu
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
        // `reloadData()` invalidates the table's row-height cache without
        // eagerly materializing every row. Calling `noteHeightOfRows` for all
        // rows turns a virtualized table into thousands of AppKit text layers.
        tableView.reloadData()
        view.needsLayout = true
        view.needsDisplay = true
    }

    func update(
        rows: [TaskRowPresentation],
        selectedTaskID: Int64?,
        emptyTitle: String,
        emptySubtitle: String,
        emptyShowsActions: Bool = false,
        headerTitle: String = "",
        headerMeta: String = "",
        preferGallery: Bool = false
    ) {
        headerTitleLabel.stringValue = headerTitle
        headerMetaLabel.stringValue = headerMeta
        if self.preferGallery != preferGallery {
            // Filter context changed — the manual toggle was about the old one.
            self.preferGallery = preferGallery
            galleryOverride = nil
        }
#if DEBUG
        let signpostID = NDMPerformance.begin("TaskListUpdate")
        defer { NDMPerformance.end("TaskListUpdate", id: signpostID) }
#endif
        // The cinema strip owns the primary live transfer — repeating the same
        // task as row #1 directly under it reads as a rendering bug. It leaves
        // the list and returns (with the completion celebration) when done.
        let heroTaskID = updateHero(rows)
        let rows = rows.filter { $0.taskID != heroTaskID }

        let previousRows = self.rows
        let previousIDs = previousRows.map(\.taskID)
        let nextIDs = rows.map(\.taskID)
        self.rows = rows
        self.selectedTaskID = selectedTaskID
        emptyLabel.stringValue = emptyTitle
        emptySubtitleLabel.stringValue = emptySubtitle
        emptyActionsRow?.isHidden = !emptyShowsActions
        let wasEmpty = !emptyStack.isHidden
        let isEmpty = rows.isEmpty && heroTaskID == nil
        listIsEmpty = isEmpty
        if wasEmpty != isEmpty {
            emptyStack.isHidden = !isEmpty
            tableView.isHidden = isEmpty
            if view.window != nil {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.22
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.layer?.add(fade, forKey: "emptyTransition")
            }
        }
        if isEmpty, !wasEmpty {
            startEmptyFloatAnimation()
        } else if !isEmpty {
            stopEmptyFloatAnimation()
        }

        if previousIDs != nextIDs {
            // NSTableView is virtualized. A structural reload is sufficient;
            // explicitly notifying every row height forces AppKit to create and
            // measure all cells (several thousand in real user libraries).
            tableView.reloadData()
        } else if !rows.isEmpty {
            var changedRows = IndexSet()
            var heightChangedRows = IndexSet()
            for index in rows.indices where previousRows[index] != rows[index] {
                changedRows.insert(index)
                if previousRows[index].showsProgressBar != rows[index].showsProgressBar {
                    heightChangedRows.insert(index)
                }
            }
            let visibleRows = visibleRowIndexes()
            let visibleChangedRows = changedRows.intersection(visibleRows)
            if !visibleChangedRows.isEmpty {
                tableView.reloadData(
                    forRowIndexes: visibleChangedRows,
                    columnIndexes: IndexSet(integer: 0)
                )
            }
            let visibleHeightChanges = heightChangedRows.intersection(visibleRows)
            if !visibleHeightChanges.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: visibleHeightChanges)
            }
        }

        for index in rows.indices {
            guard index < previousRows.count,
                  !previousRows[index].isComplete,
                  rows[index].isComplete,
                  previousRows[index].taskID == rows[index].taskID else { continue }
            if let rowView = tableView.rowView(atRow: index, makeIfNecessary: false) as? QuietFinderRowView {
                rowView.celebrateCompletion()
                NSSound(named: .init("Glass"))?.play()
            }
        }

        // A live multi-selection is user intent, not something the periodic
        // progress refresh (which drives this same `update`) gets to collapse
        // back to one row every second.
        if tableView.selectedRowIndexes.count <= 1 {
            applyTableSelection(to: selectedTaskID)
        }

        applyViewMode()
        // Keep the poster wall live without structural churn: same IDs →
        // refresh visible cards in place; new/removed IDs → full reload.
        if isGalleryActive, !isEmpty {
            if previousIDs != nextIDs || galleryView.numberOfItems(inSection: 0) != rows.count {
                galleryView.reloadData()
                syncGallerySelection()
            } else {
                for indexPath in galleryView.indexPathsForVisibleItems() {
                    let index = indexPath.item
                    guard index < rows.count, index < previousRows.count,
                          previousRows[index] != rows[index],
                          let card = galleryView.item(at: indexPath) as? GalleryCardItem else { continue }
                    card.apply(rows[index], cover: CoverArtCache.shared.image(for: rows[index].taskID))
                }
            }
        }
    }

    /// Raise / collapse the Now Downloading cinema strip. The primary slot
    /// goes to the fastest live transfer; everything else is a small "+N".
    /// Returns the task the strip is presenting so the list can exclude it.
    @discardableResult
    private func updateHero(_ rows: [TaskRowPresentation]) -> Int64? {
        let active = rows.filter(\.isDownloading)
        let primary = active.max { $0.speedBytesPerSecond < $1.speedBytesPerSecond }
        heroView.update(primary: primary, activeCount: active.count)
        let targetHeight: CGFloat = primary == nil ? 0 : 150
        guard heroHeight?.constant != targetHeight else { return primary?.taskID }
        guard view.window != nil else {
            heroHeight?.constant = targetHeight
            heroView.alphaValue = targetHeight == 0 ? 0 : 1
            return primary?.taskID
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.9, 0.3, 1)
            ctx.allowsImplicitAnimation = true
            heroHeight?.animator().constant = targetHeight
            heroView.animator().alphaValue = targetHeight == 0 ? 0 : 1
            view.layoutSubtreeIfNeeded()
        }
        return primary?.taskID
    }

    private func visibleRowIndexes() -> IndexSet {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return [] }
        let lower = max(0, visible.location)
        let upper = min(rows.count, NSMaxRange(visible))
        guard lower < upper else { return [] }
        return IndexSet(integersIn: lower..<upper)
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
            let on = tableView.selectedRowIndexes.contains(row)
            guard rowView.forcedSelected != on else { continue }
            rowView.forcedSelected = on
            rowView.needsDisplay = true
        }
    }

    private func refreshCover(for taskID: Int64?) {
        heroView.refreshCover(with: rows)
        if isGalleryActive {
            for indexPath in galleryView.indexPathsForVisibleItems() {
                let index = indexPath.item
                guard index < rows.count,
                      taskID == nil || rows[index].taskID == taskID,
                      let card = galleryView.item(at: indexPath) as? GalleryCardItem else { continue }
                card.apply(rows[index], cover: CoverArtCache.shared.image(for: rows[index].taskID))
            }
        }
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
            view.forcedSelected = tableView.selectedRowIndexes.contains(row)
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
        cell.onHoverAction = { [weak self] action in
            self?.onContextAction?(action, taskID)
        }
        cell.apply(rows[row], scale: contentScale)
        cell.setHovered(row == hoveredRow)
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
        // No category washes: with thousands of rows they read as a muddy
        // rainbow (already killed once in c7213c5); the ambient preview and
        // file icon carry the category.
        rowView.washColor = nil
        // Ambient trailing artwork only when there is a real preview to show.
        // Echoing the leading file icon as a big faint copy adds no
        // information — six rows of ghost icons read as smudge, not design.
        rowView.coverImage = preview
        rowView.needsDisplay = true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if suppressSelectionCallback { return }
        let indexes = tableView.selectedRowIndexes
        updateBatchBar()
        if indexes.count > 1 {
            selectedTaskID = nil
            syncSelectionAppearance()
            onSelectMultipleTaskIDs?(indexes.compactMap { $0 < rows.count ? rows[$0].taskID : nil })
            return
        }
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

    // MARK: - Controller-level hover tracking

    override func mouseMoved(with event: NSEvent) {
        recalculateHoveredRow(from: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        recalculateHoveredRow(from: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        applyHoveredRow(nil)
    }

    @objc private func clipViewBoundsDidChange(_ note: Notification) {
        guard let window = view.window else { return }
        recalculateHoveredRow(from: window.mouseLocationOutsideOfEventStream)
    }

    private func recalculateHoveredRow(from windowPoint: NSPoint) {
        let tablePoint = tableView.convert(windowPoint, from: nil)
        let row = tableView.row(at: tablePoint)
        applyHoveredRow(row >= 0 && row < rows.count ? row : nil)
    }

    private func applyHoveredRow(_ row: Int?) {
        guard hoveredRow != row else { return }
        if let old = hoveredRow {
            if let cell = tableView.view(atColumn: 0, row: old, makeIfNecessary: false) as? TaskRowCellView {
                cell.setHovered(false)
            }
            (tableView.rowView(atRow: old, makeIfNecessary: false) as? QuietFinderRowView)?
                .isHovered = false
        }
        hoveredRow = row
        if let new = row {
            if let cell = tableView.view(atColumn: 0, row: new, makeIfNecessary: false) as? TaskRowCellView {
                cell.setHovered(true)
            }
            (tableView.rowView(atRow: new, makeIfNecessary: false) as? QuietFinderRowView)?
                .isHovered = true
        }
    }

    private func updateBatchBar() {
        let indexes = tableView.selectedRowIndexes
        guard indexes.count > 1 else {
            batchBar.isHidden = true
            return
        }
        let selectedRows = indexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        batchBar.configure(
            count: selectedRows.count,
            canStart: selectedRows.contains { $0.canStart },
            canPause: selectedRows.contains { $0.canPause }
        )
        batchBar.isHidden = false
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

/// A quiet, semantic repair action for expired URLs. The stock rounded button
/// looked like a second primary CTA and its bezel crowded the compact task row.
@MainActor
private final class InlineLinkRepairButton: NSButton {
    private var isHovering = false
    private var scale: CGFloat = 1
    private var tracking: NSTrackingArea?
    private var heightConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        title = L10n.renewURLEllipsis
        image = NDMChrome.symbol("link.badge.plus", pointSize: 11, weight: .semibold)
        imagePosition = .imageLeading
        imageHugsTitle = true
        bezelStyle = .inline
        isBordered = false
        controlSize = .small
        focusRingType = .exterior
        font = .systemFont(ofSize: 12, weight: .semibold)
        contentTintColor = NDMChrome.accent
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        let heightConstraint = heightAnchor.constraint(equalToConstant: 28)
        heightConstraint.isActive = true
        self.heightConstraint = heightConstraint
        setAccessibilityLabel(L10n.renewURLEllipsis)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 14 * scale, height: 28 * scale)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Failed rows already carry red status copy. Keep this action
            // discoverable without repeating a pill-shaped callout down the
            // whole list; hover supplies the only soft surface.
            layer?.backgroundColor = (isHovering
                ? NDMChrome.accent.withAlphaComponent(0.10)
                : NSColor.clear).cgColor
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
            // Do not assign NSControl properties (such as contentTintColor)
            // here. They invalidate this layer again and create a permanent
            // display loop when several failed-task buttons are visible.
        }
    }

    func setContentScale(_ scale: CGFloat) {
        self.scale = scale
        title = L10n.renewURLEllipsis
        image = NDMChrome.symbol("link.badge.plus", pointSize: 11 * scale, weight: .semibold)
        font = .systemFont(ofSize: 12 * scale, weight: .semibold)
        heightConstraint?.constant = 28 * scale
        setAccessibilityLabel(L10n.renewURLEllipsis)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

/// Small icon-only ghost button for a row's hover action rail. Same
/// hover-tint recipe as `InlineLinkRepairButton`: only the layer's
/// background reacts, `contentTintColor` is left alone to avoid the
/// `updateLayer` re-entrancy loop documented there.
private final class HoverIconButton: NSButton {
    private var isHoveringMouse = false
    private var tracking: NSTrackingArea?

    init(symbolName: String, tooltip: String) {
        super.init(frame: .zero)
        bezelStyle = .inline
        isBordered = false
        focusRingType = .exterior
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setIcon(symbolName, tooltip: tooltip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func setIcon(_ symbolName: String, tooltip: String) {
        image = NDMChrome.symbol(symbolName, pointSize: 11.5, weight: .semibold)
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        isHoveringMouse = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHoveringMouse = false
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.backgroundColor = (isHoveringMouse ? NDMChrome.track : NSColor.clear).cgColor
    }
}

@MainActor
private final class TaskRowCellView: NSTableCellView {
    var onInlineRenew: (() -> Void)?
    var onHoverAction: ((TaskListContextAction) -> Void)?

    private let glyph = FileGlyphView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let progressBar = ThinProgressView()
    private let trailingLabel = NSTextField(labelWithString: "")
    private let renewButton = InlineLinkRepairButton()
    // Trailing-edge quick actions, revealed only on hover — the size/speed
    // text is what earns the space the rest of the time.
    private let hoverStack = NSStackView()
    private let hoverPrimaryButton = HoverIconButton(symbolName: "play.fill", tooltip: L10n.start)
    private let hoverRevealButton = HoverIconButton(symbolName: "folder.fill", tooltip: L10n.showInFinder)
    private var isRowHovering = false
    private var isHoverStackVisible = false
    private var hoverPrimaryAction: TaskListContextAction?
    private var hoverShowsReveal = false
    private var isShowingRenew = false
    private var currentTaskID: Int64?
    private var progressHeight: NSLayoutConstraint?
    private var progressTop: NSLayoutConstraint?
    private var titleTop: NSLayoutConstraint?
    private var badgeHeight: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.backgroundColor = NDMChrome.track
        badgeLabel.isBordered = false
        badgeLabel.drawsBackground = true
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 5
        badgeLabel.alignment = .center
        badgeLabel.isHidden = true
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        trailingLabel.alignment = .right
        trailingLabel.textColor = .labelColor
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        renewButton.target = self
        renewButton.action = #selector(renewTapped)
        renewButton.isHidden = true

        hoverPrimaryButton.target = self
        hoverPrimaryButton.action = #selector(hoverPrimaryTapped)
        hoverRevealButton.target = self
        hoverRevealButton.action = #selector(hoverRevealTapped)
        hoverStack.orientation = .horizontal
        hoverStack.spacing = 2
        hoverStack.addArrangedSubview(hoverPrimaryButton)
        hoverStack.addArrangedSubview(hoverRevealButton)
        hoverStack.alphaValue = 0
        hoverStack.isHidden = true

        for view in [glyph, titleLabel, badgeLabel, subtitleLabel, progressBar, trailingLabel, renewButton, hoverStack] {
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

            hoverStack.centerYAnchor.constraint(equalTo: subtitleLabel.centerYAnchor),
            hoverStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

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
    @objc private func hoverPrimaryTapped() {
        guard let action = hoverPrimaryAction else { return }
        onHoverAction?(action)
    }
    @objc private func hoverRevealTapped() { onHoverAction?(.reveal) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Externally driven hover state — the owning `TaskListViewController`
    /// manages which row is hovered via a table-level tracking area and
    /// scroll observation, avoiding the stale-hover problem of per-cell
    /// tracking areas during trackpad scrolling.
    func setHovered(_ hovering: Bool) {
        guard isRowHovering != hovering else { return }
        isRowHovering = hovering
        updateHoverVisibility()
    }

    /// Crossfades the trailing size/speed text against the hover action
    /// icons.
    private func updateHoverVisibility() {
        let hasActions = (hoverPrimaryAction != nil || hoverShowsReveal) && !isShowingRenew
        let shouldShow = isRowHovering && hasActions
        guard shouldShow != isHoverStackVisible else { return }
        isHoverStackVisible = shouldShow
        if shouldShow {
            hoverStack.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                self.hoverStack.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                self.hoverStack.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isHoverStackVisible else { return }
                    self.hoverStack.isHidden = true
                }
            })
        }
    }

    func apply(_ row: TaskRowPresentation, scale: CGFloat) {
        // Reset hover visuals when this cell is recycled for a different task
        // (structural reload / filter change). Same-task refreshes (1 s progress
        // ticks) keep hover intact so the action rail does not flicker away
        // under a stationary pointer.
        if currentTaskID != row.taskID {
            currentTaskID = row.taskID
            isRowHovering = false
            isHoverStackVisible = false
            hoverStack.layer?.removeAllAnimations()
            hoverStack.alphaValue = 0
            hoverStack.isHidden = true
            trailingLabel.layer?.removeAllAnimations()
            trailingLabel.alphaValue = 1
        }

        glyph.setContentScale(scale)
        titleLabel.font = .systemFont(ofSize: 13 * scale, weight: .semibold)
        badgeLabel.font = .systemFont(ofSize: 12 * scale, weight: .bold)
        subtitleLabel.font = .systemFont(ofSize: 12 * scale)
        trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .semibold)
        renewButton.setContentScale(scale)
        titleTop?.constant = 12 * scale
        badgeHeight?.constant = 18 * scale

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
            let check = NSMutableAttributedString(string: "✓ ", attributes: [
                .font: NSFont.systemFont(ofSize: 11 * scale, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            let detail = row.statusDetail.isEmpty || row.statusDetail == L10n.completed
                ? L10n.completed
                : row.statusDetail
            check.append(NSAttributedString(string: detail, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5 * scale),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            subtitleLabel.attributedStringValue = check
        } else {
            subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .regular)
            subtitleLabel.stringValue = row.statusDetail
            subtitleLabel.textColor = .secondaryLabelColor
        }

        let showRenew = row.isFailed && row.canRenew
        renewButton.isHidden = !showRenew
        trailingLabel.isHidden = showRenew
        isShowingRenew = showRenew

        // Priority: an in-flight transfer offers pause; anything else that
        // can still be started offers start/resume. Reveal rides along
        // whenever there's a file on disk to show.
        if row.canPause {
            hoverPrimaryAction = .pause
            hoverPrimaryButton.setIcon("pause.fill", tooltip: L10n.pause)
        } else if row.canStart {
            hoverPrimaryAction = .start
            hoverPrimaryButton.setIcon("play.fill", tooltip: L10n.start)
        } else {
            hoverPrimaryAction = nil
        }
        hoverPrimaryButton.isHidden = hoverPrimaryAction == nil
        hoverShowsReveal = row.canShowInFinder
        hoverRevealButton.isHidden = !hoverShowsReveal
        updateHoverVisibility()

        let showBar = row.isDownloading
        progressBar.isHidden = !showBar
        if !showBar { progressBar.isActive = false }
        progressTop?.constant = showBar ? 7 * scale : 0
        // ThinProgressView owns a fixed 4 pt hairline. Scaling this constraint
        // would fight its internal height constraint.
        progressHeight?.constant = showBar ? 4 : 0
        if showBar {
            progressBar.progress = row.progressFraction
            progressBar.isActive = true
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
        let muted = NSColor.secondaryLabelColor
        let result = NSMutableAttributedString()
        if let sep = summary.range(of: " · ") {
            let head = String(summary[..<sep.lowerBound])
            let rest = String(summary[sep.lowerBound...])
            result.append(NSAttributedString(string: head, attributes: [
                .font: NSFont.systemFont(ofSize: 11 * scale, weight: .medium),
                .foregroundColor: muted,
            ]))
            result.append(NSAttributedString(string: rest, attributes: [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        } else {
            result.append(NSAttributedString(string: summary, attributes: [
                .font: font,
                .foregroundColor: muted,
            ]))
        }
        return result
    }
}

// MARK: - Inspector

/// Crop-filled cover art banner with rounded corners and a single soft
/// shadow — no gradient, no color wash. Only shown when `CoverArtCache` has
/// a real preview; the generic per-extension file glyph stays small and
/// inline instead of being stretched up to hero size.
private final class HeroPreviewView: NSView {
    override var isFlipped: Bool { true }
    static let reflectionHeight: CGFloat = 22
    private let imageLayer = CALayer()
    // Cinema-screen reflection: the cover mirrors faintly beneath the frame,
    // fading fast — the artwork sits on a surface, not on a spec sheet.
    private let reflectionLayer = CALayer()
    private let reflectionMask = CAGradientLayer()

    var image: NSImage? {
        didSet {
            let wasEmpty = oldValue == nil
            imageLayer.contents = image
            reflectionLayer.contents = image
            reflectionLayer.isHidden = image == nil
            updateShadowColor()
            if wasEmpty, image != nil, window != nil { revealEntrance() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.cornerRadius = 12
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)

        reflectionLayer.contentsGravity = .resizeAspectFill
        // Mirror vertically and sample the cover's bottom edge.
        reflectionLayer.transform = CATransform3DMakeScale(1, -1, 1)
        reflectionLayer.cornerRadius = 12
        reflectionLayer.masksToBounds = true
        reflectionLayer.isHidden = true
        reflectionMask.colors = [
            NSColor.white.withAlphaComponent(0.35).cgColor,
            NSColor.clear.cgColor,
        ]
        reflectionMask.startPoint = CGPoint(x: 0.5, y: 0)
        reflectionMask.endPoint = CGPoint(x: 0.5, y: 0.9)
        reflectionLayer.mask = reflectionMask
        layer?.addSublayer(reflectionLayer)
    }

    private func revealEntrance() {
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.92
        scale.toValue = 1.0
        scale.mass = 1
        scale.stiffness = 300
        scale.damping = 20
        scale.initialVelocity = 4
        scale.duration = scale.settlingDuration
        layer?.add(scale, forKey: "reveal")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.25
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: "revealFade")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let screen = NSRect(
            x: 0, y: 0,
            width: bounds.width,
            height: max(0, bounds.height - Self.reflectionHeight)
        )
        imageLayer.frame = screen
        reflectionLayer.frame = NSRect(
            x: 0, y: screen.maxY + 2,
            width: bounds.width,
            height: Self.reflectionHeight - 2
        )
        reflectionMask.frame = reflectionLayer.bounds
        CATransaction.commit()
    }

    private func updateShadowColor() {
        guard let image else {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.18
            return
        }
        if let dominant = NDMChrome.dominantColor(from: image) {
            let anim = CABasicAnimation(keyPath: "shadowColor")
            anim.fromValue = layer?.shadowColor
            anim.toValue = dominant.cgColor
            anim.duration = 0.4
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(anim, forKey: "shadowColor")
            layer?.shadowColor = dominant.cgColor
            layer?.shadowOpacity = 0.35
            layer?.shadowRadius = 20
        } else {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 16
        }
    }
}

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
    private let heroImageView = HeroPreviewView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = ThinProgressView()
    private let kvStack = NSStackView()
    private let primaryButton = InspectorActionButton(title: L10n.start)
    private let secondaryButton = InspectorActionButton(title: L10n.pause)
    private let tertiaryButton = InspectorActionButton(title: L10n.detailsEllipsis)
    private let copyURLButton = InspectorActionButton(title: L10n.copyURL)
    private let moreButton = InspectorActionButton(title: "")
    private let deleteButton = NSButton(title: L10n.removeEllipsis, target: nil, action: nil)
    private let placeholderLabel = NSTextField(wrappingLabelWithString: L10n.selectDownloadHint)
    private let placeholderIcon = NSImageView()
    private let contentStack = NSStackView()
    private let glanceRow = NSStackView()
    private let actionsStack = NSStackView()
    private let actionDivider = ChromeBox(fill: NDMChrome.hairline)
    private let firstActionSeparator = ChromeBox(fill: NDMChrome.hairline)
    private let secondActionSeparator = ChromeBox(fill: NDMChrome.hairline)
    private let completionStackView = CompletionStackView()
    private let audioExtraction = AudioExtractionCoordinator()
    private let audioActionCard = ChromeBox(
        fill: .clear
    )
    private let audioActionIcon = NSImageView()
    private let audioActionTitle = NSTextField(labelWithString: "")
    private let audioActionSubtitle = NSTextField(wrappingLabelWithString: "")
    private let audioActionButton = NSButton()
    private let audioExtractionStatus = AudioExtractionStatusView()
    private let scribeStudioCard = ScribeStudioActionCard()
    // Neutral outlined callout; the red lives in the title ink, not a wash.
    private let diagBox = ChromeBox(
        fill: .clear
    )
    private let diagTitleLabel = NSTextField(wrappingLabelWithString: "")
    private let diagMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let diagRawLabel = NSTextField(labelWithString: "")
    private let tuneBox = ChromeBox(
        fill: .clear
    )
    private let tuneLabel = NSTextField(wrappingLabelWithString: "")
    private var progressButtonShowsConnectionDetails = false
    private var primaryFiresRenew = false
    private var utilityButtonSharesFile = false
    private var currentRow: TaskRowPresentation?
    /// False until `update(row:)` has run once — see the guard there.
    private var hasAppliedRow = false
    /// Forces the next `update(row:)` to actually run even when it targets
    /// the same (possibly nil) row the multi-selection summary left behind.
    private var isShowingMultiSelection = false
    private var contentScale: CGFloat = InterfaceScale.default
    private var actionButtonHeights: [NSLayoutConstraint] = []
    private var iconSizeConstraints: [NSLayoutConstraint] = []
    private var completionResultURL: URL?
    private let atmosphereView = AtmosphereView()
#if DEBUG
    private var qaCompletionSidecarCount = -1
#endif

    override func loadView() {
        view = ChromeBox(fill: NDMChrome.contentSurface)
        view.wantsLayer = true
        view.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
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

        configureAudioActionCard()

        // The file itself leads the inspector. Keep the remaining canvas quiet:
        // a giant decorative file glyph at the bottom looked like unfinished
        // placeholder art and duplicated the real file icon in this header.
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
        diagTitleLabel.textColor = .secondaryLabelColor
        diagTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        diagMessageLabel.font = .systemFont(ofSize: 12)
        diagMessageLabel.textColor = .secondaryLabelColor
        diagMessageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        diagRawLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
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
        tuneLabel.font = .systemFont(ofSize: 12)
        tuneLabel.textColor = .secondaryLabelColor
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
        heroImageView.translatesAutoresizingMaskIntoConstraints = false
        heroImageView.isHidden = true
        // Actions belong with the selected item, directly after its information;
        // they should not float at the bottom of a mostly empty inspector.
        for sub in [
            heroImageView, titleLabel, header, kvStack, completionStackView, progressBar,
            actionDivider, actionsStack, audioActionCard, scribeStudioCard, tuneBox, diagBox,
        ] {
            contentStack.addArrangedSubview(sub)
        }
        contentStack.setCustomSpacing(16, after: heroImageView)
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
        NSLayoutConstraint.activate([
            heroImageView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            // True 16:9 screen plus the reflection strip below it — a squashed
            // cover reads as a bug, not a thumbnail.
            heroImageView.heightAnchor.constraint(
                equalTo: heroImageView.widthAnchor,
                multiplier: 9.0 / 16.0,
                constant: HeroPreviewView.reflectionHeight
            ),
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
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.image = NSImage(
            systemSymbolName: "arrow.down.circle",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            .init(pointSize: 34, weight: .light)
        )
        placeholderIcon.contentTintColor = NDMChrome.accent.withAlphaComponent(0.35)
        atmosphereView.translatesAutoresizingMaskIntoConstraints = false
        let inspectorDocument = InspectorDocumentView()
        inspectorDocument.translatesAutoresizingMaskIntoConstraints = false
        inspectorDocument.addSubview(contentStack)
        let inspectorScrollView = NSScrollView()
        inspectorScrollView.drawsBackground = false
        inspectorScrollView.borderType = .noBorder
        inspectorScrollView.hasVerticalScroller = true
        inspectorScrollView.hasHorizontalScroller = false
        inspectorScrollView.autohidesScrollers = true
        inspectorScrollView.translatesAutoresizingMaskIntoConstraints = false
        inspectorScrollView.documentView = inspectorDocument
        view.addSubview(atmosphereView)
        view.addSubview(inspectorScrollView)
        view.addSubview(placeholderLabel)
        view.addSubview(placeholderIcon)
        NSLayoutConstraint.activate([
            atmosphereView.topAnchor.constraint(equalTo: view.topAnchor),
            atmosphereView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            atmosphereView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            atmosphereView.heightAnchor.constraint(equalToConstant: 280),
            inspectorScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            inspectorScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inspectorScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            inspectorDocument.topAnchor.constraint(equalTo: inspectorScrollView.contentView.topAnchor),
            inspectorDocument.leadingAnchor.constraint(equalTo: inspectorScrollView.contentView.leadingAnchor),
            inspectorDocument.widthAnchor.constraint(equalTo: inspectorScrollView.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: inspectorDocument.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: inspectorDocument.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: inspectorDocument.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: inspectorDocument.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            progressBar.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            kvStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            completionStackView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            actionDivider.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            actionDivider.heightAnchor.constraint(equalToConstant: 1),
            actionsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            audioActionCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            scribeStudioCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
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
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 16),
            placeholderIcon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderIcon.bottomAnchor.constraint(equalTo: placeholderLabel.topAnchor, constant: -10),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ] + iconSizeConstraints)

        NotificationCenter.default.addObserver(
            forName: CoverArtCache.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let taskID = note.userInfo?["taskID"] as? Int64 else { return }
            Task { @MainActor [weak self] in
                guard let self, taskID == self.currentRow?.taskID else { return }
                self.refreshHeaderPreview()
            }
        }
        audioExtraction.onStateChange = { [weak self] state in
            self?.applyAudioExtractionState(state)
        }
        update(row: nil)
    }

    func setContentScale(_ scale: CGFloat) {
        let next = min(InterfaceScale.maximum, max(InterfaceScale.minimum, scale))
        let changed = abs(contentScale - next) > 0.000_1
        contentScale = next
        if !isViewLoaded { _ = view }
        guard changed else { return }

        titleLabel.font = .systemFont(ofSize: 12 * next, weight: .semibold)
        filenameLabel.font = .systemFont(ofSize: 15 * next, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 12 * next)
        placeholderLabel.font = .systemFont(ofSize: 13 * next)
        diagTitleLabel.font = .systemFont(ofSize: 12 * next, weight: .semibold)
        diagMessageLabel.font = .systemFont(ofSize: 12 * next)
        diagRawLabel.font = .monospacedSystemFont(ofSize: 11 * next, weight: .regular)
        tuneLabel.font = .systemFont(ofSize: 12 * next)
        audioActionTitle.font = .systemFont(ofSize: 12.5 * next, weight: .semibold)
        audioActionSubtitle.font = .systemFont(ofSize: 12 * next)
        completionStackView.setContentScale(next)
        scribeStudioCard.setContentScale(next)

        let layoutScale = 1 + (next - 1) * 0.45
        kvStack.spacing = 8 * layoutScale
        contentStack.spacing = 12 * layoutScale
        actionsStack.spacing = 10 * layoutScale
        actionButtonHeights.forEach { $0.constant = 34 * layoutScale }
        moreButton.image = NDMChrome.symbol("ellipsis", pointSize: 12 * layoutScale, weight: .semibold)
        iconSizeConstraints.forEach { $0.constant = 54 * layoutScale }
        update(row: currentRow)
        view.needsLayout = true
    }

    private func configureAudioActionCard() {
        audioActionCard.translatesAutoresizingMaskIntoConstraints = false
        audioActionCard.isHidden = true

        audioActionIcon.image = NDMChrome.symbol("waveform", pointSize: 17, weight: .semibold)
        audioActionIcon.contentTintColor = NDMChrome.accent
        audioActionIcon.imageScaling = .scaleProportionallyDown
        audioActionIcon.translatesAutoresizingMaskIntoConstraints = false
        audioActionIcon.setAccessibilityElement(false)

        audioActionTitle.stringValue = L10n.extractAudio
        audioActionTitle.font = .systemFont(ofSize: 12.5, weight: .semibold)
        audioActionTitle.textColor = .labelColor
        audioActionSubtitle.stringValue = L10n.t(
            "Create an audio copy for listening or transcription.",
            "生成音频副本，便于收听或转写。"
        )
        audioActionSubtitle.font = .systemFont(ofSize: 12)
        audioActionSubtitle.textColor = .secondaryLabelColor
        audioActionSubtitle.maximumNumberOfLines = 2

        audioActionButton.title = L10n.t("Extract", "提取")
        audioActionButton.target = self
        audioActionButton.action = #selector(tapAudioAction)
        audioActionButton.controlSize = .regular
        NDMChrome.styleGhostButton(audioActionButton)
        audioActionButton.image = NDMChrome.symbol("waveform", pointSize: 11.5, weight: .semibold)
        audioActionButton.imagePosition = .imageLeading
        audioActionButton.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let top = NSStackView(views: [audioActionIcon, audioActionTitle, spacer, audioActionButton])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8

        let cardContent = NSStackView(views: [top, audioActionSubtitle, audioExtractionStatus])
        cardContent.orientation = .vertical
        cardContent.alignment = .leading
        cardContent.spacing = 8
        cardContent.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
        cardContent.translatesAutoresizingMaskIntoConstraints = false
        audioActionCard.addSubview(cardContent)
        NSLayoutConstraint.activate([
            cardContent.topAnchor.constraint(equalTo: audioActionCard.topAnchor),
            cardContent.leadingAnchor.constraint(equalTo: audioActionCard.leadingAnchor),
            cardContent.trailingAnchor.constraint(equalTo: audioActionCard.trailingAnchor),
            cardContent.bottomAnchor.constraint(equalTo: audioActionCard.bottomAnchor),
            top.widthAnchor.constraint(equalTo: cardContent.widthAnchor, constant: -24),
            audioActionSubtitle.widthAnchor.constraint(equalTo: cardContent.widthAnchor, constant: -24),
            audioExtractionStatus.widthAnchor.constraint(lessThanOrEqualTo: cardContent.widthAnchor, constant: -24),
            audioActionIcon.widthAnchor.constraint(equalToConstant: 24),
            audioActionIcon.heightAnchor.constraint(equalToConstant: 24),
            audioActionButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func applyAudioExtractionState(_ state: AudioExtractionCoordinator.State) {
        audioExtractionStatus.apply(state)
        switch state {
        case .unavailable:
            audioActionCard.isHidden = true
        case .ready:
            audioActionCard.isHidden = false
            audioActionButton.isEnabled = true
            audioActionButton.title = L10n.t("Extract", "提取")
            audioActionButton.image = NDMChrome.symbol("waveform", pointSize: 11.5, weight: .semibold)
        case .running:
            audioActionCard.isHidden = false
            audioActionButton.isEnabled = false
            audioActionButton.title = L10n.t("Extracting…", "提取中…")
            audioActionButton.image = NDMChrome.symbol("waveform", pointSize: 11.5, weight: .semibold)
        case .succeeded:
            audioActionCard.isHidden = false
            audioActionButton.isEnabled = true
            audioActionButton.title = L10n.t("Show", "显示")
            audioActionButton.image = NDMChrome.symbol("folder", pointSize: 11.5, weight: .semibold)
        case .failed:
            audioActionCard.isHidden = false
            audioActionButton.isEnabled = true
            audioActionButton.title = L10n.t("Retry", "重试")
            audioActionButton.image = NDMChrome.symbol("arrow.clockwise", pointSize: 11.5, weight: .semibold)
        }
        switch state {
        case .unavailable:
            audioActionButton.toolTip = nil
        case .ready:
            audioActionButton.toolTip = L10n.extractAudio
        case .running:
            audioActionButton.toolTip = L10n.extractingAudio
        case .succeeded:
            audioActionButton.toolTip = L10n.showInFinder
        case .failed:
            audioActionButton.toolTip = L10n.extractAudioAgain
        }
        audioActionButton.setAccessibilityLabel(audioActionButton.toolTip ?? audioActionButton.title)
        audioActionCard.invalidateIntrinsicContentSize()
        contentStack.invalidateIntrinsicContentSize()
    }

    @objc private func tapAudioAction() {
        switch audioExtraction.state {
        case .succeeded:
            audioExtraction.revealResult()
        case .ready, .failed:
            audioExtraction.extract()
        case .unavailable, .running:
            break
        }
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
        // No tooltip: a tooltip that just repeats the visible label is noise.
        // Keep the label for VoiceOver, drop the hover bubble.
        button.toolTip = nil
        button.setAccessibilityLabel(title)
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

    private func refreshHeaderPreview() {
        guard let row = currentRow else {
            iconView.image = nil
            iconView.isHidden = false
            heroImageView.isHidden = true
            atmosphereView.setAtmosphere(nil)
            return
        }
        if let preview = CoverArtCache.shared.image(for: row.taskID) {
            heroImageView.image = preview
            heroImageView.isHidden = false
            iconView.isHidden = true
            let dominant = NDMChrome.dominantColor(from: preview)
            atmosphereView.setAtmosphere(dominant)
        } else {
            heroImageView.isHidden = true
            iconView.isHidden = false
            iconView.image = NDMChrome.fileIcon(filename: row.filename, pointSize: 192)
            atmosphereView.setAtmosphere(nil)
        }
    }

    private func fileTypeText(for row: TaskRowPresentation) -> String {
        let ext = (row.filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return L10n.other }
        // UTType.localizedDescription follows the OS language ("MPEG-4 movie"
        // on an English system), which reads as a leak in a Chinese UI. Name
        // the format ourselves: "MP4 视频", "DMG 磁盘映像".
        return L10n.fileTypeDisplay(ext: ext)
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
        audioActionTitle.stringValue = L10n.extractAudio
        audioActionSubtitle.stringValue = L10n.t(
            "Create an audio copy for listening, notes, or transcription.",
            "生成音频副本，方便收听、整理笔记或转写。"
        )
        applyAudioExtractionState(audioExtraction.state)
        completionStackView.relocalize()
        scribeStudioCard.relocalize()
        let row = currentRow
        currentRow = nil
        update(row: row)
    }

    func update(row: TaskRowPresentation?) {
        // First call must always apply: `currentRow` starts nil, so a plain
        // `currentRow != row` guard would swallow the initial empty state and
        // leave the pane showing its as-constructed subviews. Also always
        // apply right after a multi-selection summary, even if `row` is nil
        // again — otherwise "N selected" would linger in the placeholder.
        guard !hasAppliedRow || currentRow != row || isShowingMultiSelection else { return }
        let isTaskSwitch = hasAppliedRow && currentRow?.taskID != row?.taskID
        hasAppliedRow = true
        isShowingMultiSelection = false
        currentRow = row
        if isTaskSwitch, view.window != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentStack.layer?.add(fade, forKey: "switch")
        }
        audioExtraction.apply(
            sourceURL: row?.isComplete == true ? row?.localFileURL : nil
        )
        scribeStudioCard.apply(fileURL: row?.isComplete == true ? row?.localFileURL : nil)
        let hasSelection = row != nil
        placeholderLabel.isHidden = hasSelection
        placeholderIcon.isHidden = hasSelection
        contentStack.isHidden = !hasSelection
        actionsStack.isHidden = !hasSelection
        titleLabel.stringValue = L10n.details.uppercased()
        guard let row else {
            placeholderLabel.stringValue = L10n.selectDownloadHint
            completionResultURL = nil
            completionStackView.apply(nil)
            scribeStudioCard.apply(fileURL: nil)
            refreshHeaderPreview()
            return
        }

        refreshHeaderPreview()

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
            progressBar.isActive = false
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
            progressBar.isActive = row.isDownloading
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
                decorate(primaryButton, title: L10n.renewURL, symbol: "arrow.triangle.2.circlepath", chrome: .primary)
                primaryButton.isEnabled = true
                decorate(secondaryButton, title: L10n.retry, symbol: "arrow.clockwise", chrome: .soft)
                secondaryButton.isEnabled = true
            } else {
                decorate(primaryButton, title: L10n.retry, symbol: "arrow.clockwise", chrome: .primary)
                primaryButton.isEnabled = true
                decorate(secondaryButton, title: L10n.renewURL, symbol: "arrow.triangle.2.circlepath", chrome: .soft)
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
        } else {
            decorate(copyURLButton, title: L10n.copyURL, symbol: "link", chrome: .soft)
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

    /// Multi-selection collapses the single-task inspector to a plain "N
    /// selected" summary — batch actions live in the list's own bottom bar,
    /// not duplicated here.
    func showMultiSelection(count: Int) {
        hasAppliedRow = true
        isShowingMultiSelection = true
        currentRow = nil
        audioExtraction.apply(sourceURL: nil)
        scribeStudioCard.apply(fileURL: nil)
        placeholderLabel.isHidden = false
        placeholderIcon.isHidden = false
        contentStack.isHidden = true
        actionsStack.isHidden = true
        placeholderLabel.stringValue = L10n.selectedCount(count)
        completionResultURL = nil
        completionStackView.apply(nil)
        refreshHeaderPreview()
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

private final class InspectorDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Drop target

private final class URLDropView: NSView {
    var onDropURL: ((String) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var fill: NSColor? {
        didSet { needsDisplay = true }
    }

    private let dropOverlay = DropZoneOverlay()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.URL, .string])
        dropOverlay.translatesAutoresizingMaskIntoConstraints = false
        dropOverlay.isHidden = true
        addSubview(dropOverlay)
        NSLayoutConstraint.activate([
            dropOverlay.topAnchor.constraint(equalTo: topAnchor),
            dropOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill?.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHoverChange?(true)
        dropOverlay.show()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHoverChange?(false)
        dropOverlay.hide()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHoverChange?(false)
        dropOverlay.hide()
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
        dropOverlay.hide()
    }
}

private final class DropZoneOverlay: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.image = NDMChrome.symbol("arrow.down.circle", pointSize: 32, weight: .light)
        iconView.contentTintColor = NDMChrome.accent
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = L10n.t("Drop link to download", "拖放链接开始下载")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 12, dy: 12)
        let path = NSBezierPath(roundedRect: inset, xRadius: 14, yRadius: 14)
        NDMChrome.accent.withAlphaComponent(0.06).setFill()
        path.fill()
        NDMChrome.accent.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 2
        let pattern: [CGFloat] = [8, 5]
        path.setLineDash(pattern, count: 2, phase: 0)
        path.stroke()
    }

    func show() {
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
        })
    }
}
