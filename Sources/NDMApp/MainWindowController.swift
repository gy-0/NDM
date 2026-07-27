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
    /// Live multi-selection, mirrored from the list so ⌘C copies all of it rather
    /// than just the anchor row.
    private var multiSelectedTaskIDs: [Int64] = []
    private var scheduledStartTimer: Timer?
    /// Establish a useful launch focus once, without re-selecting after the
    /// user deliberately clears selection during later one-second refreshes.
    private var hasEstablishedInitialSelection = false

    private let splitController = NSSplitViewController()
    private let sidebarController = SidebarViewController()
    private let listController = TaskListViewController()
    private let inspectorController = InspectorViewController()
    private let fileSharePresenter = FileSharePresenter()

    private var progressWindows: [Int64: ProgressWindowController] = [:]
    /// Browser-captured session cards have their own newest-first visual
    /// stack. Ordinary progress windows must never consume one of these slots.
    private var quietProgressWindowOrder: [Int64] = []
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
        // Floor, not a preference. 200 + 300 + 320 = 820 is every pane at its
        // minimum simultaneously, so the window can always hold all three and a
        // toggle never has to grow it; the rest is breathing room. Height only has
        // to fit the toolbar, a couple of rows and the batch bar.
        window.minSize = NSSize(
            width: min(840, availableWidth),
            height: min(520, availableHeight)
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
                // Token refresh walks the view tree; also re-apply imperative
                // selection ink / inspector chrome that caches accent tints.
                self?.sidebarController.refreshAccentChrome()
                self?.listController.refreshAccentChrome()
                self?.inspectorController.refreshAccentChrome()
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
        contentToolbar.onContextAction = { [weak self] action in
            self?.performToolbarContextAction(action)
        }
        contentToolbar.onToggleSidebar = { [weak self] in
            guard let item = self?.splitController.splitViewItems.first else { return }
            item.animator().isCollapsed.toggle()
        }
        contentToolbar.onToggleInspector = { [weak self] in
            guard let item = self?.splitController.splitViewItems.last else { return }
            item.animator().isCollapsed.toggle()
        }
        contentToolbar.onClipboardOffer = { [weak self] in
            self?.openClipboardOffer()
        }
        contentToolbar.onSearch = { [weak self] query in
            self?.searchQuery = query
            self?.rebuildDisplayedRows()
        }
    }

    /// Known and deliberately accepted: on a narrow window, revealing a collapsed
    /// rail widens the window by that rail's width instead of taking the space back
    /// from the list.
    ///
    /// Collapsing hands the rail's width to the list; revealing does not take it
    /// back, so `NSSplitViewController` finds the width by growing the window. The
    /// growth is always exactly the rail plus one divider (338pt here), and nothing
    /// else in the layout moves.
    ///
    /// Measured with the split view's autosave cleared before every run — without
    /// that it is unreproducible, because the autosave is rewritten on each launch
    /// and one run's saved geometry biases the next:
    ///
    ///      840 → 1178      1000 → 1338      1100 → 1100
    ///      900 → 1238      1060 → 1060      1440 → 1440
    ///
    /// The boundary sits somewhere between 1000 and 1060, and is *not* a round
    /// number we control. Ruled out by experiment: `holdingPriority`,
    /// `collapseBehavior = .preferResizingSiblingsWithFixedSplitView` (whose name is
    /// this exact contract), `preferredThicknessFraction`, and the autosaved layout
    /// itself. Each was tried against the measurements above and none moved them, so
    /// the decision lives inside AppKit somewhere we cannot reach from here.
    ///
    /// Worth knowing if you do try again: the inspector's effective minimum is its
    /// content's fitting width, 332pt, not the 320 in `minimumThickness`.
    ///
    /// It *can* be prevented by restoring the frame inside the same run-loop turn,
    /// but only by giving up `animator()` — the growth lands at the end of the
    /// animation, too late to correct invisibly. That trade was made and then
    /// deliberately reversed: the slide is worth more than a defect you have to
    /// narrow the window to meet. Reproduce with
    /// `NDM_QA_PROBE_INSPECTOR_TOGGLE=asis` (`=min` to start from the floor), delete
    /// `NSSplitView Subview Frames NDM.MainSplit.v9` from defaults between runs, and
    /// check the animation still exists afterwards.
    private func configureSplit() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        // Room for semantic zoom without turning the navigation into a squeeze.
        sidebarItem.minimumThickness = startsCompact ? 180 : 200
        sidebarItem.maximumThickness = 268
        sidebarItem.preferredThicknessFraction = 0.175
        // Holding priority decides *which pane pays* when the split view has to
        // find or shed width. Both rails hold on; the list is the only one that
        // yields. Without this the list simply keeps whatever a collapse handed it
        // — measured at the minimum window: collapsing the inspector took the list
        // from 300 to 638, and re-expanding grew the window from 840 to 1178 rather
        // than taking those points back.
        if #available(macOS 11.0, *) {
            sidebarItem.titlebarSeparatorStyle = .none
        }

        let listItem = NSSplitViewItem(viewController: listController)
        // The list is the pane that yields. Its old 420 floor meant that opening
        // the inspector could not be paid for out of the window, so AppKit paid for
        // it by making the window wider — the user had already chosen that width.
        // Every combination of panes now fits inside `minSize`, so a toggle
        // redistributes space instead of resizing the window.
        listItem.minimumThickness = startsCompact ? 260 : 300

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        // Full action labels (especially “Show in Finder”) need a real inspector,
        // not a narrow utility strip.
        inspectorItem.minimumThickness = 320
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

    /// Pane widths, for the toggle probe's log line.
    fileprivate func paneWidthsDescription() -> String {
        splitController.splitViewItems
            .map { item in
                item.isCollapsed
                    ? "—"
                    : String(format: "%.0f", item.viewController.view.frame.width)
            }
            .joined(separator: "/")
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
            self?.multiSelectedTaskIDs = []
            self?.selectedTaskID = taskID
            self?.updateInspector()
            self?.updateToolbarEnablement()
        }
        listController.onSelectMultipleTaskIDs = { [weak self] taskIDs in
            self?.multiSelectedTaskIDs = taskIDs
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
        inspectorController.onCopyURL = { [weak self] in
            guard let self, let id = self.selectedTaskID else { return false }
            return self.copyURL(for: id)
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
        let row = selectedRow()
        let actions = TaskSelectionActions.make(from: row)
        startToolbarItem?.isEnabled = actions.canStart
        pauseToolbarItem?.isEnabled = actions.canPause

        // Contextual command group: what you can do to the selected task
        // appears next to New. Empty selection keeps the toolbar clean.
        var context: [(ToolbarContextAction, String, String)] = []
        if let row {
            if actions.canPause {
                context.append((.pause, L10n.pause, "pause.fill"))
            }
            if actions.canStart {
                context.append((.resume, row.isFailed ? L10n.retry : L10n.resume,
                                row.isFailed ? "arrow.clockwise" : "play.fill"))
            }
            if actions.canRetry, !actions.canStart {
                context.append((.retry, L10n.retry, "arrow.clockwise"))
            }
            // Toolbar stays quiet unless the failure specifically needs a fresh URL.
            if actions.canRenew, row.needsLinkRenew {
                context.append((.renew, L10n.renewURL, "link"))
            }
            if actions.canOpen {
                context.append((.open, L10n.open, "arrow.up.forward.app.fill"))
            }
            if actions.canShowInFinder {
                context.append((.reveal, L10n.showInFinder, "folder.fill"))
            }
        }
        contentToolbar.setContextActions(context)
    }

    private func performToolbarContextAction(_ action: ToolbarContextAction) {
        guard let id = selectedTaskID else { return }
        switch action {
        case .pause: pauseSelected()
        case .resume: startSelected()
        case .retry: startTask(id)
        case .renew: renewURL(for: id)
        case .open: openTaskFile(id)
        case .reveal: revealTaskFile(id)
        case .delete: deleteTask(id)
        }
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
            // Appointments that came due while the app was closed fire now rather
            // than being silently forgotten — the machine being off is the normal
            // case for an overnight schedule.
            Task { [weak self] in
                guard let self else { return }
                let started = await self.manager.startDueScheduledTasks()
                if !started.isEmpty { await self.reload() }
                self.rescheduleScheduledStartTimer()
            }
            let qaPreferredTaskID = QAPreviewOverrides.selectedFilenameContains.flatMap { needle in
                displayedRows.first {
                    $0.filename.localizedCaseInsensitiveContains(needle)
                }?.taskID
            }
            selectedTaskID = selectedTaskID ?? qaPreferredTaskID ?? displayedRows.first?.taskID
            if QAPreviewOverrides.showProgress, let id = selectedTaskID {
                showProgress(for: id)
            }
            if let qaSearch = QAPreviewOverrides.searchQuery, searchQuery.isEmpty {
                searchQuery = qaSearch
                contentToolbar.setSearchQuery(qaSearch)
                rebuildDisplayedRows()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let w = self?.window else { return }
                    NSLog("QA search width: %.0f x %.0f", w.frame.width, w.frame.height)
                }
            }
            if QAPreviewOverrides.probeInspectorToggle {
                // Reproduce the reported gesture exactly: shrink to the minimum with
                // the inspector open, then toggle it twice through the same animator
                // path the toolbar button uses. The earlier probe assigned
                // `isCollapsed` directly and never resized first, which is why it
                // reported success on a window that still grows in practice.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, let window = self.window,
                          let item = self.splitController.splitViewItems.last else { return }
                    // `=min` shrinks to the window minimum first (the reported
                    // gesture); anything else probes the size as launched.
                    if ProcessInfo.processInfo.environment["NDM_QA_PROBE_INSPECTOR_TOGGLE"] == "min" {
                        var frame = window.frame
                        frame.size = NSSize(
                            width: window.minSize.width,
                            height: window.minSize.height
                        )
                        window.setFrame(frame, display: true)
                    }
                    self.splitController.view.layoutSubtreeIfNeeded()
                    NSLog("QA probe: at minimum %.0f | panes %@ | fitting s=%.0f l=%.0f i=%.0f",
                          window.frame.width, self.paneWidthsDescription(),
                          self.sidebarController.view.fittingSize.width,
                          self.listController.view.fittingSize.width,
                          self.inspectorController.view.fittingSize.width)
                    guard let sidebar = self.splitController.splitViewItems.first else { return }
                    @MainActor func step(_ label: String) {
                        NSLog("QA probe: %@ %.0f | panes %@",
                              label, window.frame.width, self.paneWidthsDescription())
                    }
                    item.animator().isCollapsed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        step("inspector off")
                        item.animator().isCollapsed = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            step("inspector on ")
                            sidebar.animator().isCollapsed = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                step("sidebar off  ")
                                sidebar.animator().isCollapsed = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    step("sidebar on   ")
                                }
                            }
                        }
                    }
                }
            }
            if QAPreviewOverrides.showRemoveConfirm, let id = selectedTaskID {
                DispatchQueue.main.async { [weak self] in self?.deleteTask(id) }
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
                return TaskPresentationFormatting.isMoreRecentlyActive(a, than: b)
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
        guard let id = selectedTaskID else { return }
        _ = copyURL(for: id, reportFailure: true)
    }

    @discardableResult
    private func copyURL(for taskID: Int64, reportFailure: Bool = false) -> Bool {
        guard let url = allTasks.first(where: { $0.id == taskID })?.url else {
            if reportFailure {
                showAlert(message: L10n.copyFailed, detail: L10n.copyFailedDetail)
            }
            return false
        }
        let succeeded = DownloadClipboard.copy(url)
        if reportFailure, !succeeded {
            showAlert(message: L10n.copyFailed, detail: L10n.copyFailedDetail)
        }
        return succeeded
    }

    /// Wake exactly when the next appointment falls due, and not before.
    ///
    /// A one-second poll would work and would also be 3,600 wake-ups to start a
    /// download an hour from now. `nextScheduledWakeUp` gives the one moment worth
    /// waiting for; the timer is rebuilt whenever the set of appointments changes.
    /// Capped so a date years out still re-checks periodically — clocks change,
    /// machines sleep, and a timer scheduled for 2029 will not survive either.
    private func rescheduleScheduledStartTimer() {
        scheduledStartTimer?.invalidate()
        scheduledStartTimer = nil
        Task { [weak self] in
            guard let self else { return }
            guard let next = await self.manager.nextScheduledWakeUp() else { return }
            let delay = min(max(next.timeIntervalSinceNow, 1), 15 * 60)
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let started = await self.manager.startDueScheduledTasks()
                    if !started.isEmpty { await self.reload() }
                    self.rescheduleScheduledStartTimer()
                }
            }
            // Fire while menus are open too; a scheduled start should not wait for
            // the user to dismiss a context menu.
            RunLoop.main.add(timer, forMode: .common)
            self.scheduledStartTimer = timer
        }
    }

    /// Park a download until a chosen time, or release one already parked.
    ///
    /// Toggling rather than two menu items: a task is either waiting on a clock or
    /// it is not, and the menu already relabels itself to say which.
    private func toggleSchedule(for taskID: Int64) {
        let row = displayedRows.first(where: { $0.taskID == taskID })
        if row?.isScheduled == true {
            Task {
                try? await manager.schedule(taskID: taskID, at: nil)
                await reload()
            }
            return
        }
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        picker.minDate = Date()
        NDMDialog.present(
            title: L10n.scheduleTitle,
            body: L10n.scheduleBody,
            subject: row.map { .file(name: $0.filename, cover: CoverArtCache.shared.image(for: taskID)) }
                ?? .info,
            buttons: [
                NDMDialog.Button(L10n.scheduleConfirm),
                NDMDialog.Button(L10n.cancel, isCancel: true),
            ],
            accessory: picker,
            host: window
        ) { [weak self] result in
            guard let self, result.buttonIndex == 0 else { return }
            let when = picker.dateValue
            Task {
                try? await self.manager.schedule(taskID: taskID, at: when)
                await self.reload()
                self.rescheduleScheduledStartTimer()
            }
        }
    }

    /// Everything the user currently has selected, single or multiple.
    private func selectedTaskIDs() -> [Int64] {
        if !multiSelectedTaskIDs.isEmpty { return multiSelectedTaskIDs }
        return selectedTaskID.map { [$0] } ?? []
    }

    /// Put the finished files themselves on the pasteboard.
    ///
    /// Writing the file URLs (not a string) is what makes ⌘V work in Finder, the
    /// Dock, Mail and every other app that accepts files — the same thing Finder's
    /// own ⌘C does. A path string would paste as text and copy nothing.
    @discardableResult
    private func copyFiles(for taskIDs: [Int64]) -> Bool {
        let urls = taskIDs
            .compactMap { id in allTasks.first(where: { $0.id == id }) }
            .compactMap(\.destinationFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            showAlert(message: L10n.copyFailed, detail: L10n.fileNotFound)
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls as [NSURL]) else {
            showAlert(message: L10n.copyFailed, detail: L10n.copyFailedDetail)
            return false
        }
        return true
    }

    /// ⌘C with the list focused. The Edit menu's Copy is wired to the standard
    /// `copy:` action, so it arrives here through the responder chain — and a text
    /// field being edited still gets its own copy first, which is correct.
    @objc func copy(_ sender: Any?) {
        let ids = selectedTaskIDs()
        guard !ids.isEmpty else { return }
        copyFiles(for: ids)
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
                // The manager's user-facing speed target still changes only
                // once per completed second. A lighter 250 ms pickup while
                // active lets the main hero, title and menu snapshot receive
                // that shared target promptly instead of visibly trailing the
                // compact progress window by another whole second.
                let hasActiveTransfer = self.allTasks.contains {
                    $0.status == .downloading
                }
                try? await Task.sleep(
                    nanoseconds: hasActiveTransfer ? 250_000_000 : 1_000_000_000
                )
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
                mediaQuality: currentSettings.mediaQualityPreference,
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

    func showProgress(for taskID: Int64, quietly: Bool = false) {
        if let existing = progressWindows[taskID] {
            if quietly, quietProgressWindowOrder.contains(taskID) {
                quietProgressWindowOrder.removeAll { $0 == taskID }
                quietProgressWindowOrder.append(taskID)
                reflowQuietProgressWindows()
            } else if !quietly, quietProgressWindowOrder.contains(taskID) {
                quietProgressWindowOrder.removeAll { $0 == taskID }
                existing.promoteToInteractivePresentation()
                reflowQuietProgressWindows()
            }
            // A user explicitly choosing "Show Progress" should promote even
            // a browser-created quiet card into a key, interactive window.
            existing.presentWindow(activating: !quietly)
            return
        }
        let name = allTasks.first(where: { $0.id == taskID })?.filename
            ?? displayedRows.first(where: { $0.taskID == taskID })?.filename
            ?? L10n.downloadFallback(taskID)
        let wc = ProgressWindowController(
            manager: manager,
            taskID: taskID,
            filename: name,
            quietlyPresented: quietly
        )
        wc.onWindowClose = { [weak self] in
            guard let self else { return }
            self.progressWindows.removeValue(forKey: taskID)
            self.quietProgressWindowOrder.removeAll { $0 == taskID }
            self.reflowQuietProgressWindows()
        }
        progressWindows[taskID] = wc
        if quietly {
            quietProgressWindowOrder.removeAll { $0 == taskID }
            quietProgressWindowOrder.append(taskID)
            reflowQuietProgressWindows()
        }
        wc.presentWindow()
    }

    /// New captures occupy centered slot zero; older cards cascade slightly
    /// away from it. Reflowing on every close removes dead gaps and makes the
    /// next-most-recent task the immediately reachable card.
    private func reflowQuietProgressWindows() {
        quietProgressWindowOrder.removeAll { progressWindows[$0] == nil }
        for (index, taskID) in quietProgressWindowOrder.reversed().enumerated() {
            progressWindows[taskID]?.positionInQuietStack(index: index)
        }
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
                                focusStartedDownload(first.id)
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
                try await manager.start(taskID: task.id)
                await reload()
                focusStartedDownload(task.id)
            } catch {
                showAlert(error)
                await reload()
            }
        }
    }

    /// Bring a freshly-started, app-initiated download into view in the main
    /// window instead of popping the standalone progress window. The user is
    /// already here — the Now Downloading hero and the list row carry the
    /// state with better UI. (Browser-initiated downloads still use the small
    /// window, handled in AppDelegate, since the app may not be frontmost.)
    private func focusStartedDownload(_ taskID: Int64) {
        selectedTaskID = taskID
        // Make sure the task is not hidden behind a filter/search the user set
        // earlier, so the hero + row are actually visible.
        if let task = allTasks.first(where: { $0.id == taskID }), !selectedFilter.matches(task) {
            selectedFilter = .all
        }
        if !searchQuery.isEmpty {
            searchQuery = ""
            contentToolbar.setSearchQuery("")
        }
        sidebarController.update(counts: SidebarFilter.counts(in: allTasks), selected: selectedFilter)
        rebuildDisplayedRows()
        listController.revealTask(taskID)
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
            focusStartedDownload(task.id)
        } catch {
            showAlert(error)
        }
    }

    private func startTask(_ id: Int64) {
        Task {
            do {
                selectedTaskID = id
                try await manager.start(taskID: id)
                await reload()
                focusStartedDownload(id)
            } catch {
                showAlert(error)
                await reload()
            }
        }
    }

    private func deleteTask(_ id: Int64) {
        let name = allTasks.first(where: { $0.id == id })?.filename ?? L10n.t("this download", "此下载")
        NDMDialog.present(
            title: L10n.removeConfirm(name),
            body: L10n.removeConfirmBody,
            subject: .file(name: name, cover: CoverArtCache.shared.image(for: id)),
            buttons: [
                NDMDialog.Button(L10n.remove, isDestructive: true),
                NDMDialog.Button(L10n.cancel, isCancel: true),
            ],
            option: NDMDialog.Option(title: L10n.alsoTrashFile),
            host: window
        ) { [weak self] result in
            guard let self, result.buttonIndex == 0 else { return }
            let deleteFile = result.optionIsOn
            Task {
                do {
                    try await self.manager.remove(taskID: id, deleteFile: deleteFile)
                    if self.selectedTaskID == id { self.selectedTaskID = nil }
                    await self.reload()
                } catch {
                    self.showAlert(error)
                }
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
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = current
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        NDMDialog.present(
            title: L10n.renewURL,
            body: L10n.renewURLBody,
            subject: .caution,
            buttons: [
                NDMDialog.Button(L10n.renewAndStart),
                NDMDialog.Button(L10n.cancel, isCancel: true),
            ],
            accessory: field,
            host: window
        ) { [weak self] result in
            guard let self, result.buttonIndex == 0 else { return }
            let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return }
            Task {
                do {
                    try await self.manager.renewURL(taskID: id, newURL: url)
                    self.selectedTaskID = id
                    try await self.manager.start(taskID: id)
                    await self.reload()
                    self.focusStartedDownload(id)
                } catch {
                    self.showAlert(error)
                    await self.reload()
                }
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
        if !NSWorkspace.shared.open(url) {
            showAlert(message: L10n.openFileFailed, detail: url.path)
        }
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
        if !fileSharePresenter.present(fileURL: url, from: source) {
            showAlert(message: L10n.fileNotFound, detail: url.path)
        }
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
            _ = copyURL(for: taskID, reportFailure: true)
        case .copyFile:
            copyFiles(for: [taskID])
        case .schedule:
            toggleSchedule(for: taskID)
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
        case .copyFile:
            // One pasteboard write for the whole selection, so ⌘V in Finder
            // produces every file at once rather than only the last one.
            copyFiles(for: taskIDs)
        case .delete:
            NDMDialog.present(
                title: L10n.removeConfirmMultiple(taskIDs.count),
                body: L10n.removeConfirmBody,
                subject: .caution,
                buttons: [
                    NDMDialog.Button(L10n.remove, isDestructive: true),
                    NDMDialog.Button(L10n.cancel, isCancel: true),
                ],
                option: NDMDialog.Option(title: L10n.alsoTrashFile),
                host: window
            ) { [weak self] result in
                guard let self, result.buttonIndex == 0 else { return }
                let deleteFile = result.optionIsOn
                Task {
                    for id in taskIDs {
                        try? await self.manager.remove(taskID: id, deleteFile: deleteFile)
                    }
                    await self.reload()
                }
            }
        default:
            break
        }
    }

    private func showAlert(_ error: Error) {
        showAlert(message: L10n.somethingWentWrong, detail: error.localizedDescription)
    }

    private func showAlert(message: String, detail: String) {
        NDMDialog.present(
            title: message,
            body: detail,
            subject: .failure,
            host: window
        )
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

        // Row-level hover, same approach as the task list: one tracking area
        // on the table + a scroll observer, because per-cell tracking areas
        // drop mouseExited during trackpad scrolling.
        let hoverArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tableView.addTrackingArea(hoverArea)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sidebarClipBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    // MARK: - Hover

    private var hoveredRow: Int?

    override func mouseMoved(with event: NSEvent) { recalcHover(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { recalcHover(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { applyHover(nil) }

    @objc private func sidebarClipBoundsChanged(_ note: Notification) {
        guard let window = view.window else { return }
        recalcHover(window.mouseLocationOutsideOfEventStream)
    }

    private func recalcHover(_ windowPoint: NSPoint) {
        let point = tableView.convert(windowPoint, from: nil)
        let row = tableView.row(at: point)
        // Headers are not hoverable.
        if row >= 0, row < rows.count, case .filter = rows[row] {
            applyHover(row)
        } else {
            applyHover(nil)
        }
    }

    private func applyHover(_ row: Int?) {
        guard hoveredRow != row else { return }
        if let old = hoveredRow {
            (tableView.rowView(atRow: old, makeIfNecessary: false) as? QuietFinderRowView)?.isHovered = false
        }
        hoveredRow = row
        if let new = row {
            (tableView.rowView(atRow: new, makeIfNecessary: false) as? QuietFinderRowView)?.isHovered = true
        }
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

    func refreshAccentChrome() {
        guard isViewLoaded else { return }
        syncSelectionAppearance()
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
private final class SidebarFilterCellView: NSTableCellView, AccentChromeRefreshing {
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
        // Accent ink on the soft accent pill — the selected row glows in the
        // theme color instead of inverting to white on a solid slab.
        let ink: NSColor = selected ? NDMChrome.accent : .labelColor
        let muted: NSColor = selected ? NDMChrome.accent.withAlphaComponent(0.75) : .tertiaryLabelColor
        let titleFont = NSFont.systemFont(ofSize: 13.5 * scale, weight: selected ? .semibold : .medium)
        let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5 * scale, weight: .regular)
        iconWidth?.constant = 17 * scale
        iconHeight?.constant = 17 * scale
        icon.image = NDMChrome.symbol(
            NDMChrome.sidebarSymbolName(for: filter),
            pointSize: 13.5 * scale,
            weight: selected ? .semibold : .medium
        )
        icon.contentTintColor = selected ? NDMChrome.accent : .secondaryLabelColor
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
        pulseDot.color = NDMChrome.accent
        pulseDot.setBreathing(showsPulse)
    }

    func refreshAccentChrome() {
        refreshInk()
    }
}

// MARK: - Task list

enum TaskListContextAction {
    case quickLook, open, reveal, share, start, pause, retry, renew, progress, properties, copyURL, copyFile, schedule, delete
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
    /// Clipping shell whose height animates as concurrent heroes appear/leave.
    private let heroContainer = NSView()
    /// Vertical stack of Now Downloading heroes — one card per live transfer.
    private let heroStack = NSStackView()
    private var heroViews: [NowDownloadingHeroView] = []
    private var heroHeight: NSLayoutConstraint?
    private var heroTaskIDs: Set<Int64> = []
    private var heroOrderedIDs: [Int64] = []
    /// Shared-element morph when a Hero settles into its list row.
    private let heroLandingAnimator = HeroListLandingAnimator()
    private var heroLandingCoveredRow: Int?
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
            let fresh = note.userInfo?["fresh"] as? Bool ?? false
            Task { @MainActor [weak self] in
                self?.refreshCover(for: taskID, fresh: fresh)
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
        // This label carries whatever the user typed into the search field. Left
        // unbounded it grows a single very long line, and because the window takes
        // its `contentMinSize` from the content's fitting size, that *forces the
        // window wider*. Worse, `emptyStack` is a direct subview rather than an
        // arranged one, so hiding it does not remove it from layout: a long query
        // resized the window even when the search had results and this was never on
        // screen. Wrap it, cap it, and let it be compressed.
        // Wrap to two lines and clip the tail. Middle-truncating a *sentence*
        // deletes the only part carrying information — "没有匹配「…」的结果" keeps the
        // grammar and loses the query, which is precisely backwards. Two lines is
        // also a hard ceiling, so this can no longer grow the window vertically
        // either.
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        emptySubtitleLabel.font = .systemFont(ofSize: 13)
        emptySubtitleLabel.textColor = .secondaryLabelColor
        emptySubtitleLabel.alignment = .center
        emptySubtitleLabel.maximumNumberOfLines = 3
        emptySubtitleLabel.lineBreakMode = .byTruncatingTail
        emptySubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        // A hard ceiling as well as low compression resistance: the empty state is
        // a message, and no message is allowed to be the thing that decides how
        // wide this window can be.
        emptyStack.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        batchBar.onStart = { [weak self] in self?.emitBatchAction(.start) }
        batchBar.onPause = { [weak self] in self?.emitBatchAction(.pause) }
        batchBar.onDelete = { [weak self] in self?.emitBatchAction(.delete) }
        batchBar.translatesAutoresizingMaskIntoConstraints = false
        batchBar.isHidden = true

        heroContainer.translatesAutoresizingMaskIntoConstraints = false
        heroContainer.wantsLayer = true
        heroContainer.layer?.masksToBounds = true
        heroContainer.alphaValue = 0

        heroStack.orientation = .vertical
        heroStack.alignment = .width
        heroStack.spacing = 0
        heroStack.distribution = .fill
        heroStack.translatesAutoresizingMaskIntoConstraints = false
        heroContainer.addSubview(heroStack)
        let heroHeight = heroContainer.heightAnchor.constraint(equalToConstant: 0)
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
        view.addSubview(heroContainer)
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
            heroContainer.topAnchor.constraint(equalTo: headerTitleLabel.bottomAnchor, constant: 12),
            heroContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            heroContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heroHeight,
            heroStack.topAnchor.constraint(equalTo: heroContainer.topAnchor),
            heroStack.leadingAnchor.constraint(equalTo: heroContainer.leadingAnchor),
            heroStack.trailingAnchor.constraint(equalTo: heroContainer.trailingAnchor),
            galleryScroll.topAnchor.constraint(equalTo: heroContainer.bottomAnchor),
            galleryScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            galleryScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            galleryScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: heroContainer.bottomAnchor),
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

    func refreshAccentChrome() {
        guard isViewLoaded else { return }
        // Visible row chrome / empty-state primary already refresh via the
        // hierarchy walk; re-sync selection pills so forcedSelected rows redraw.
        syncSelectionAppearance()
        syncHeroSelection()
        for row in 0..<tableView.numberOfRows {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? TaskRowCellView {
                cell.refreshAccentChrome()
            }
        }
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
        // The cinema strip owns every live transfer — repeating them as list
        // rows underneath would mix two visual languages for the same work.
        // Completed / queued / failed tasks remain in the table below.
        let previousHeroIDs = heroTaskIDs
        let previousHeroOrdered = heroOrderedIDs
        let previousRows = self.rows
        let nextHeroIDs = Set(rows.filter(\.isDownloading).map(\.taskID))
        let landedFromHero = previousHeroIDs.subtracting(nextHeroIDs)

        // Decide reveal intent before collapsing the strip, so we only suppress
        // height animation when a Hero→list morph will actually run.
        let provisionalListRows = rows.filter { !nextHeroIDs.contains($0.taskID) }
        let earlyScrollAnchor = scrollAnchorBeforeStructuralUpdate(
            previousRows: previousRows,
            structuralChange: !landedFromHero.isEmpty
                || previousRows.map(\.taskID) != provisionalListRows.map(\.taskID)
        )
        let wasViewingTop = isViewingListTop(
            previousRows: previousRows,
            scrollAnchor: earlyScrollAnchor
        )
        let revealLandingID = isGalleryActive
            ? nil
            : heroLandingRevealTaskID(
                landedFromHero: landedFromHero,
                rows: provisionalListRows,
                selectedTaskID: selectedTaskID,
                wasViewingTop: wasViewingTop
            )

        // Capture landing geometry *before* heroes are reassigned / collapsed.
        let landingSource: HeroListLandingSource? = {
            guard let revealLandingID else { return nil }
            return captureHeroLandingSource(
                landedFromHero: landedFromHero,
                previousOrdered: previousHeroOrdered,
                preferredTaskID: revealLandingID
            )
        }()

        // Cover the live Hero with a frozen snapshot *before* height collapses.
        // Otherwise the user sees the cinema card snap away (height twitch) and
        // the list jump up — then the morph "pops" back in. Cover first, morph later.
        if let landingSource {
            heroLandingAnimator.installCover(in: view, source: landingSource)
        }

        // When a landing is about to run, postpone the strip's collapse entirely
        // rather than making it instant: instant is what put the list's whole 150pt
        // shift into one frame, which is the snap seen at the completion moment.
        let heroIDs = updateHero(rows, deferHeightCollapse: landingSource != nil)
        let rows = provisionalListRows

        let previousIDs = previousRows.map(\.taskID)
        let nextIDs = rows.map(\.taskID)
        let scrollAnchor = earlyScrollAnchor
        self.rows = rows
        self.selectedTaskID = selectedTaskID
        emptyLabel.stringValue = emptyTitle
        emptySubtitleLabel.stringValue = emptySubtitle
        emptyActionsRow?.isHidden = !emptyShowsActions
        let wasEmpty = !emptyStack.isHidden
        let isEmpty = rows.isEmpty && heroIDs.isEmpty
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
            // A mid-flight morph must not leave a covered ghost row after a
            // filter / sort / other structural change. Fade rather than yank: this
            // fires whenever a second download finishes while the first is still
            // landing (the source capture declines to build one while a morph runs),
            // and an instant teardown there was a hard visible snap.
            if heroLandingAnimator.isRunning,
               landingSource?.taskID != heroLandingAnimator.animatingTaskID {
                abandonHeroLanding()
            }
            // NSTableView is virtualized. A structural reload is sufficient;
            // explicitly notifying every row height forces AppKit to create and
            // measure all cells (several thousand in real user libraries).
            // Decide the *final* pin before reload. Hero→list completion inserts
            // at the top: restoring the pre-reload anchor would keep the old
            // first row under the eye (a downward jump), and a later
            // scrollRowToVisible would bounce back up. One target, one set.
            let revealID = revealLandingID
            let scrollPin: ListPin? = revealID.map { ListPin.reveal(taskID: $0) }
                ?? scrollAnchor.map { ListPin.anchor(taskID: $0.taskID, offset: $0.offset) }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                tableView.reloadData()
                applyListPin(scrollPin, in: rows)
            }

            // After the one-shot pin, morph the finishing Hero into its row.
            // If we installed a cover but won't morph (edge case), tear it down
            // so a frozen snapshot never sticks on screen.
            if let landingSource, revealID == landingSource.taskID {
                startHeroListLanding(source: landingSource, rows: rows)
            } else {
                if landingSource != nil || heroLandingAnimator.isRunning {
                    abandonHeroLanding()
                }
                if let revealID,
                   NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    fadeInLandedRow(taskID: revealID)
                }
            }
        } else {
            // Cover was installed but the list did not restructure, so there is no
            // row to morph into. The frozen hero is already on screen — fade it.
            if landingSource != nil {
                abandonHeroLanding()
            }
            if !rows.isEmpty {
                var changedRows = IndexSet()
                var heightChangedRows = IndexSet()
                for index in rows.indices where previousRows[index] != rows[index] {
                    changedRows.insert(index)
                    if previousRows[index].showsProgressBar != rows[index].showsProgressBar {
                        heightChangedRows.insert(index)
                    }
                }
                var visibleRows = visibleRowIndexes()
                // A landing row is deliberately hidden while the overlay covers it.
                // Reloading it mid-morph rebuilds the cell, which loses that hidden
                // state and shows the live row *underneath* the frozen snapshot —
                // two copies of the same card for the rest of the morph. The row is
                // repainted at handoff anyway.
                if let covered = heroLandingCoveredRow {
                    visibleRows.remove(covered)
                }
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
        }

        for index in rows.indices {
            guard index < previousRows.count,
                  !previousRows[index].isComplete,
                  rows[index].isComplete,
                  previousRows[index].taskID == rows[index].taskID else { continue }
            // Skip celebrate while a Hero→list morph owns this row (no spring after land).
            if heroLandingAnimator.animatingTaskID == rows[index].taskID { continue }
            if let rowView = tableView.rowView(atRow: index, makeIfNecessary: false) as? QuietFinderRowView {
                rowView.celebrateCompletion()
            }
            // Completing in place is the other way a file becomes real; it needs the
            // same nudge as a landing to get its poster.
            requestPoster(for: index)
        }

        // A live multi-selection is user intent, not something the periodic
        // progress refresh (which drives this same `update`) gets to collapse
        // back to one row every second.
        if tableView.selectedRowIndexes.count <= 1 {
            applyTableSelection(to: selectedTaskID)
        }
        syncHeroSelection()

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

    /// Preserve the task under the user's eye when a newly completed/retried
    /// item moves to the front. Keeping only the clip view's pixel offset makes
    /// the visible content silently change identity after every structural
    /// reload, which is especially disorienting in long download histories.
    /// Hero→list completions may override this via `heroLandingRevealTaskID`.
    private func scrollAnchorBeforeStructuralUpdate(
        previousRows: [TaskRowPresentation],
        structuralChange: Bool
    ) -> (taskID: Int64, offset: CGFloat)? {
        guard structuralChange,
              !previousRows.isEmpty,
              !scrollView.isHidden,
              tableView.numberOfRows == previousRows.count else { return nil }
        let visible = tableView.visibleRect
        guard visible.height > 0 else { return nil }
        let probe = NSPoint(x: visible.midX, y: visible.minY + 1)
        let row = tableView.row(at: probe)
        guard row >= 0, row < previousRows.count else { return nil }
        let offset = visible.minY - tableView.rect(ofRow: row).minY
        return (previousRows[row].taskID, offset)
    }

    /// What the list should do about scrolling after a structural reload.
    private enum ListPin {
        /// Hold this task where it already was on screen.
        case anchor(taskID: Int64, offset: CGFloat)
        /// Make sure this task is visible, moving as little as possible.
        case reveal(taskID: Int64)

        var taskID: Int64 {
            switch self {
            case .anchor(let taskID, _), .reveal(let taskID): return taskID
            }
        }
    }

    /// Apply a pin in exactly one scroll set.
    ///
    /// `reveal` used to mean "put the row at offset 0", which is only harmless when
    /// the row is already at the top. Under any other sort a finished download can
    /// land far down the list, and forcing it to the viewport top threw the whole
    /// list — the lurch reported as 列表跳动. `ListScrollGeometry` resolves the
    /// minimum move instead, so the common case (row 0, user at the top) costs
    /// nothing at all.
    private func applyListPin(_ pin: ListPin?, in rows: [TaskRowPresentation]) {
        guard let pin,
              let row = rows.firstIndex(where: { $0.taskID == pin.taskID }) else { return }
        tableView.layoutSubtreeIfNeeded()
        let rowRect = tableView.rect(ofRow: row)
        let geometry = ListScrollGeometry(
            currentY: scrollView.contentView.bounds.origin.y,
            viewportHeight: scrollView.contentView.bounds.height,
            contentHeight: tableView.bounds.height
        )
        let target: ListScrollTarget
        switch pin {
        case .anchor(_, let offset):
            target = .anchor(rowMinY: rowRect.minY, offset: offset)
        case .reveal:
            target = .reveal(rowMinY: rowRect.minY, rowHeight: rowRect.height)
        }
        // Setting the same offset again is a no-op to AppKit but not to the eye when
        // a morph is mid-flight; skip it outright.
        guard !geometry.isSettled(for: target) else { return }
        var origin = scrollView.contentView.bounds.origin
        origin.y = geometry.scrollY(for: target)
        // Caller wraps this in a zero-duration context so the pin is not animated
        // (avoids a visible down-then-up after reloadData re-pins the old top).
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// A completed or paused download leaves the Hero strip and reappears in
    /// the table (usually as row 0). Return that task when we should pin it
    /// into view instead of restoring the pre-reload scroll anchor.
    private func heroLandingRevealTaskID(
        landedFromHero: Set<Int64>,
        rows: [TaskRowPresentation],
        selectedTaskID: Int64?,
        wasViewingTop: Bool
    ) -> Int64? {
        // A paused row exposes Start / Resume (`canStart`), while an incomplete
        // or failed row uses Retry / Renew. That makes this the precise paused
        // state without adding presentation-only task status plumbing.
        let landedVisible = rows.filter {
            landedFromHero.contains($0.taskID) && ($0.isComplete || $0.canStart)
        }
        guard !landedVisible.isEmpty else { return nil }

        // The task the user was already watching just finished — always reveal.
        if let selectedTaskID,
           landedFromHero.contains(selectedTaskID),
           rows.contains(where: { $0.taskID == selectedTaskID }) {
            return selectedTaskID
        }

        // Watching the Hero / top of the list: bring the new first row into view.
        // Deep in history: leave the scroll anchor alone.
        guard wasViewingTop else { return nil }
        return landedVisible.first?.taskID
    }

    /// Snapshot the finishing Hero before `updateHero` reassigns the strip.
    /// Only one card animates even if several leave in the same tick.
    private func captureHeroLandingSource(
        landedFromHero: Set<Int64>,
        previousOrdered: [Int64],
        preferredTaskID: Int64
    ) -> HeroListLandingSource? {
        guard landedFromHero.contains(preferredTaskID),
              view.window != nil,
              !isGalleryActive,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !heroLandingAnimator.isRunning,
              let index = previousOrdered.firstIndex(of: preferredTaskID),
              index < heroViews.count else { return nil }
        let hero = heroViews[index]
        guard !hero.isHidden else { return nil }
        return hero.captureListLandingSource(in: view)
    }

    /// After the one-shot scroll pin, morph the pre-installed Hero cover into
    /// the landed row. Cover must already be on screen (see `installCover`
    /// before `updateHero`); this only drives destination geometry + ease.
    private func startHeroListLanding(
        source: HeroListLandingSource,
        rows: [TaskRowPresentation]
    ) {
        // Every bail-out below happens with the frozen cover already on screen, so
        // all of them fade instead of vanishing.
        guard heroLandingAnimator.animatingTaskID == source.taskID,
              let rowIndex = rows.firstIndex(where: { $0.taskID == source.taskID }) else {
            abandonHeroLanding()
            return
        }

        view.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()

        // Aim at where the row will be once the strip has closed, not where it is
        // now. The two then animate together over one duration — the list rises to
        // meet the card — instead of the strip closing afterwards and leaving its
        // 150pt hole on screen for the whole morph.
        let captured: (cell: TaskRowCellView, row: QuietFinderRowView, destination: HeroListLandingDestination)?
        captured = withPostCollapseLayout {
            guard let cell = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: true)
                    as? TaskRowCellView,
                  let rowView = tableView.rowView(atRow: rowIndex, makeIfNecessary: true)
                    as? QuietFinderRowView,
                  let destination = cell.captureLandingDestination(in: view, taskID: source.taskID)
            else { return nil }
            return (cell, rowView, destination)
        }
        guard let captured else {
            abandonHeroLanding()
            return
        }

        // Live row stays invisible until the overlay hands off — no spring bounce.
        clearHeroLandingCover()
        captured.cell.setLandingCovered(true)
        captured.row.alphaValue = 0
        heroLandingCoveredRow = rowIndex

        // One duration drives both animations, QA slow-motion included — scaling only
        // the morph would desync the strip from the card.
        let morph = Self.heroLandingDuration * (QAPreviewOverrides.heroLandingDurationScale ?? 1)
        // Start the strip closing now, on the morph's clock and curve.
        flushDeferredHeroHeight(duration: morph)
        heroLandingAnimator.morphToDestination(
            captured.destination,
            duration: morph,
            onReveal: { [weak self] in
                MainActor.assumeIsolated {
                    self?.handOffHeroLandingRow(taskID: source.taskID)
                }
            },
            completion: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Soft land only — no celebrate spring (that was a second bounce).
                    if self.heroLandingCoveredRow != nil {
                        self.handOffHeroLandingRow(taskID: source.taskID)
                    }
                    // Belt and braces: if the strip somehow never got flushed above,
                    // it must not be left standing at full height with nothing in it.
                    self.flushDeferredHeroHeight()
                }
            }
        )
    }

    /// One duration for the whole landing: the card's flight and the strip's close.
    private static let heroLandingDuration: TimeInterval = 0.46

    /// Swap overlay → live row mid-morph so the handoff never flashes empty.
    private func handOffHeroLandingRow(taskID: Int64) {
        guard let rowIndex = rows.firstIndex(where: { $0.taskID == taskID }) else { return }
        if let cell = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false)
            as? TaskRowCellView {
            cell.setLandingCovered(false)
        }
        if let rowView = tableView.rowView(atRow: rowIndex, makeIfNecessary: false) {
            rowView.alphaValue = 1
        }
        heroLandingCoveredRow = nil
        // A poster that arrived mid-landing was held back so the handoff stayed
        // invisible. The row is its own again — let it dissolve in now.
        if pendingPosterReveals.contains(taskID) {
            refreshCover(for: taskID, fresh: true)
        } else {
            requestPoster(for: rowIndex)
        }
    }

    /// Ask for a row's poster at a moment the file is certainly on disk.
    ///
    /// The row's own first paint happens as the task completes, which can be before
    /// delivery has finished moving the file into place; that attempt finds nothing
    /// and backs off. Nothing else retries, so without this nudge the reveal only
    /// ever appeared after a relaunch.
    private func requestPoster(for row: Int) {
        guard row < rows.count else { return }
        let item = rows[row]
        guard item.isComplete,
              CoverArtCache.shared.image(for: item.taskID) == nil,
              let localFile = item.localFileURL else { return }
        CoverArtCache.shared.ensureCover(
            taskID: item.taskID,
            remoteURL: nil,
            localFile: localFile
        )
    }

    private func clearHeroLandingCover() {
        if let row = heroLandingCoveredRow {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? TaskRowCellView {
                cell.setLandingCovered(false)
            }
            if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) {
                rowView.alphaValue = 1
            }
        }
        heroLandingCoveredRow = nil
    }

    /// Reduce Motion: brief fade instead of the shared-element morph.
    private func fadeInLandedRow(taskID: Int64) {
        guard let rowIndex = rows.firstIndex(where: { $0.taskID == taskID }),
              let rowView = tableView.rowView(atRow: rowIndex, makeIfNecessary: true) else {
            return
        }
        rowView.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            rowView.animator().alphaValue = 1
        }
    }

    private func isViewingListTop(
        previousRows: [TaskRowPresentation],
        scrollAnchor: (taskID: Int64, offset: CGFloat)?
    ) -> Bool {
        if previousRows.isEmpty { return true }
        if !scrollView.isHidden,
           scrollView.contentView.bounds.origin.y <= max(8, tableView.rowHeight * 0.35) {
            return true
        }
        if let scrollAnchor,
           let index = previousRows.firstIndex(where: { $0.taskID == scrollAnchor.taskID }),
           index <= 1 {
            return true
        }
        return false
    }

    /// Raise / collapse the Now Downloading cinema strip(s). Every live
    /// transfer gets its own hero card — concurrent downloads no longer mix
    /// a featured strip with ordinary progress rows. Returns the task IDs
    /// currently on stage so the list can exclude them.
    ///
    /// When `deferHeightCollapse` is true the strip keeps its current height and the
    /// target is remembered in `deferredHeroHeight` for a landing to flush later.
    @discardableResult
    private func updateHero(
        _ rows: [TaskRowPresentation],
        heightAnimated: Bool = true,
        deferHeightCollapse: Bool = false
    ) -> Set<Int64> {
        let active = rows.filter(\.isDownloading)
        heroOrderedIDs = active.map(\.taskID)
        heroTaskIDs = Set(heroOrderedIDs)
        ensureHeroCapacity(active.count)

        for (index, hero) in heroViews.enumerated() {
            if index < active.count {
                hero.isHidden = false
                // Each card is self-contained — no "+N more" eyebrow.
                hero.update(primary: active[index], activeCount: 1)
                hero.setSelected(active[index].taskID == selectedTaskID)
            } else {
                hero.isHidden = true
                hero.update(primary: nil, activeCount: 0)
                hero.setSelected(false)
            }
        }

        let targetHeight: CGFloat = CGFloat(active.count) * Self.heroCardHeight
        let targetAlpha: CGFloat = active.isEmpty ? 0 : 1
        guard heroHeight?.constant != targetHeight else { return heroTaskIDs }
        // A landing owns the layout until the card is down. Remember where the strip
        // has to end up and leave it alone for now.
        if deferHeightCollapse {
            deferredHeroHeight = (targetHeight, targetAlpha)
            return heroTaskIDs
        }
        guard view.window != nil, heightAnimated else {
            heroHeight?.constant = targetHeight
            heroContainer.alphaValue = targetAlpha
            return heroTaskIDs
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.9, 0.3, 1)
            ctx.allowsImplicitAnimation = true
            heroHeight?.animator().constant = targetHeight
            heroContainer.animator().alphaValue = targetAlpha
            view.layoutSubtreeIfNeeded()
        }
        return heroTaskIDs
    }

    /// Hero height that a landing has postponed, and the alpha that goes with it.
    ///
    /// Collapsing the strip is what moves the list. During a Hero → row morph it
    /// must not happen at all: the frozen cover hides the hero card's own
    /// disappearance but nothing hides the 150pt the list jumps to close the gap,
    /// and making that jump instant only compressed it into a single frame — which is
    /// the snap measured at the completion moment. So the morph runs with the strip
    /// still occupying its space, nothing around the card moves, and the collapse is
    /// flushed (animated) once the card is down.
    private var deferredHeroHeight: (height: CGFloat, alpha: CGFloat)?

    /// Give up on a landing: fade the frozen cover out, put the live row back, and
    /// still close the strip. Every bail-out goes through here so the postponed
    /// collapse cannot be forgotten and leave an empty full-height Hero behind.
    private func abandonHeroLanding() {
        heroLandingAnimator.abortGracefully { [weak self] in
            self?.clearHeroLandingCover()
        }
        flushDeferredHeroHeight()
    }

    /// Lay the list out as it will be once the postponed Hero collapse has happened,
    /// run `body` against that geometry, then put the layout back.
    ///
    /// Nothing is drawn between the two passes — this all happens inside one turn of
    /// the run loop — so it costs two layouts and no flicker. It exists so the morph
    /// can be aimed at where the row will *end up*, which lets the strip close at the
    /// same time as the card flies instead of afterwards. Closing it afterwards is
    /// correct but leaves a 150pt hole on screen for the length of the morph.
    private func withPostCollapseLayout<T>(_ body: () -> T) -> T {
        guard let pending = deferredHeroHeight,
              let heroHeight,
              heroHeight.constant != pending.height else { return body() }
        let original = heroHeight.constant
        heroHeight.constant = pending.height
        view.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        let result = body()
        heroHeight.constant = original
        view.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        return result
    }

    /// Close the Hero strip that a landing postponed.
    ///
    /// Idempotent, and called from every way a landing can end — normal completion,
    /// graceful abort, a destination that could not be captured — because leaving it
    /// unflushed would strand the strip at full height with nothing in it.
    ///
    /// `duration` is matched to the morph when the two run together, so the list rises
    /// to meet the card and both arrive on the same frame.
    private func flushDeferredHeroHeight(duration: TimeInterval = 0.32) {
        guard let pending = deferredHeroHeight else { return }
        deferredHeroHeight = nil
        guard heroHeight?.constant != pending.height else { return }
        guard view.window != nil, duration > 0 else {
            heroHeight?.constant = pending.height
            heroContainer.alphaValue = pending.alpha
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            // Same curve as the morph: they are one movement, not two that happen to
            // overlap.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.58, 1.0)
            ctx.allowsImplicitAnimation = true
            heroHeight?.animator().constant = pending.height
            heroContainer.animator().alphaValue = pending.alpha
            view.layoutSubtreeIfNeeded()
        }
    }

    private static let heroCardHeight: CGFloat = 150

    private func ensureHeroCapacity(_ count: Int) {
        while heroViews.count < count {
            let hero = makeHeroView()
            hero.heightAnchor.constraint(equalToConstant: Self.heroCardHeight).isActive = true
            heroStack.addArrangedSubview(hero)
            heroViews.append(hero)
        }
    }

    private func makeHeroView() -> NowDownloadingHeroView {
        let hero = NowDownloadingHeroView()
        hero.onSelectTask = { [weak self] taskID in
            self?.selectHeroTask(taskID)
        }
        hero.onActivateTask = { [weak self] taskID in
            self?.onActivateTaskID?(taskID)
        }
        hero.onContextAction = { [weak self] action, taskID in
            self?.onContextAction?(action, taskID)
        }
        return hero
    }

    private func selectHeroTask(_ taskID: Int64) {
        selectedTaskID = taskID
        applyTableSelection(to: nil)
        syncHeroSelection()
        onSelectTaskID?(taskID)
    }

    private func syncHeroSelection() {
        for (index, hero) in heroViews.enumerated() where !hero.isHidden {
            let id = index < heroOrderedIDs.count ? heroOrderedIDs[index] : nil
            hero.setSelected(id == selectedTaskID)
        }
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
        if heroTaskIDs.contains(taskID) {
            selectHeroTask(taskID)
            return
        }
        applyTableSelection(to: taskID)
        syncHeroSelection()
        guard let index = rows.firstIndex(where: { $0.taskID == taskID }) else { return }
        tableView.scrollRowToVisible(index)
    }

    func selectAdjacentRow(offset: Int) -> Bool {
        // Heroes sit above the table — arrow keys walk them first, then the list.
        if !heroOrderedIDs.isEmpty {
            if let currentHero = selectedTaskID.flatMap({ id in heroOrderedIDs.firstIndex(where: { $0 == id }) }) {
                let next = currentHero + offset
                if next >= 0, next < heroOrderedIDs.count {
                    selectHeroTask(heroOrderedIDs[next])
                    return true
                }
                if next >= heroOrderedIDs.count, !rows.isEmpty, offset > 0 {
                    let taskID = rows[0].taskID
                    selectedTaskID = taskID
                    applyTableSelection(to: taskID)
                    syncHeroSelection()
                    tableView.scrollRowToVisible(0)
                    onSelectTaskID?(taskID)
                    return true
                }
                return false
            }
            if selectedTaskID == nil || rows.firstIndex(where: { $0.taskID == selectedTaskID }) == nil {
                if offset < 0 {
                    selectHeroTask(heroOrderedIDs[heroOrderedIDs.count - 1])
                    return true
                }
                if offset > 0, rows.isEmpty {
                    selectHeroTask(heroOrderedIDs[0])
                    return true
                }
                // Stepping up from the first table row lands on the last hero.
                if offset < 0, let first = rows.first, selectedTaskID == first.taskID {
                    selectHeroTask(heroOrderedIDs[heroOrderedIDs.count - 1])
                    return true
                }
            }
        }

        guard !rows.isEmpty else {
            if offset < 0, let last = heroOrderedIDs.last {
                selectHeroTask(last)
                return true
            }
            if offset > 0, let first = heroOrderedIDs.first {
                selectHeroTask(first)
                return true
            }
            return false
        }
        let current = selectedTaskID.flatMap { id in rows.firstIndex(where: { $0.taskID == id }) }
            ?? (tableView.selectedRow >= 0 ? tableView.selectedRow : nil)
        let next: Int
        if let current {
            if current == 0, offset < 0, let last = heroOrderedIDs.last {
                selectHeroTask(last)
                return true
            }
            next = min(rows.count - 1, max(0, current + offset))
            guard next != current else { return false }
        } else {
            // No selection yet: step into the list from the matching end.
            next = offset >= 0 ? 0 : rows.count - 1
        }
        let taskID = rows[next].taskID
        selectedTaskID = taskID
        applyTableSelection(to: taskID)
        syncHeroSelection()
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

    /// Tasks whose poster arrived while a landing still had their row covered.
    ///
    /// The reveal must never run under the overlay: the handoff at t=1 is invisible
    /// precisely because the frozen card and the live row are identical, and swapping
    /// the icon for a poster underneath would break that. Held here and released by
    /// `handOffHeroLandingRow`.
    private var pendingPosterReveals: Set<Int64> = []

    /// Arm the poster dissolve for a task whose artwork was just generated.
    ///
    /// Returns true when the row should be repainted right after, which is what
    /// supplies the image the transition dissolves *to*. Only ever called for `fresh`
    /// artwork — see `CoverArtCache.finishLoad` — because a cover read back from disk
    /// is not news and must not animate.
    @discardableResult
    private func armPosterReveal(taskID: Int64) -> Bool {
        guard let row = rows.firstIndex(where: { $0.taskID == taskID }),
              CoverArtCache.shared.image(for: taskID) != nil else { return false }
        // Covered by a landing: the overlay is showing the old icon and the handoff
        // is only invisible while the two match. Wait for it.
        //
        // Keyed on the covered row alone, deliberately. `animatingTaskID` is still set
        // while the handoff runs — it is cleared after `onReveal` — so testing it here
        // would defer the reveal a second time from inside the very callback meant to
        // release it, and the poster would never appear at all.
        if heroLandingCoveredRow == row {
            pendingPosterReveals.insert(taskID)
            return false
        }
        pendingPosterReveals.remove(taskID)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? TaskRowCellView else { return false }
        cell.armPosterReveal()
        return true
    }

    private func refreshCover(for taskID: Int64?, fresh: Bool = false) {
        for (index, hero) in heroViews.enumerated() where !hero.isHidden {
            if let taskID {
                guard index < heroOrderedIDs.count, heroOrderedIDs[index] == taskID else { continue }
                hero.refreshCover()
            } else {
                hero.refreshCover()
            }
        }
        if isGalleryActive {
            for indexPath in galleryView.indexPathsForVisibleItems() {
                let index = indexPath.item
                guard index < rows.count,
                      taskID == nil || rows[index].taskID == taskID,
                      let card = galleryView.item(at: indexPath) as? GalleryCardItem else { continue }
                card.apply(rows[index], cover: CoverArtCache.shared.image(for: rows[index].taskID))
            }
        }
        // Arm the dissolve before the repaint below, never after: the transition
        // captures what is on screen at the moment it is added, and the repaint is
        // what supplies the poster it dissolves to.
        var deferredRow: Int?
        if fresh, let taskID {
            if !armPosterReveal(taskID: taskID), pendingPosterReveals.contains(taskID) {
                // Held for the handoff. The repaint has to wait with it: painting the
                // poster into a covered cell now would make it appear the instant the
                // overlay lifts, which is the snap the deferral exists to avoid — and
                // it also breaks the handoff, which is only invisible while the frozen
                // card and the live row still match.
                deferredRow = rows.firstIndex(where: { $0.taskID == taskID })
            }
        }
        for row in 0..<rows.count {
            if let taskID, rows[row].taskID != taskID { continue }
            if row == deferredRow { continue }
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
        if rows[row].isDownloading {
            return 92 * contentScale
        }
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
        // Which file types earn a trailing preview at all.
        //
        // The test is "does this file contain something worth looking at", not "can
        // Quick Look produce a bitmap" — it can produce one for a .zip too, and a
        // washed-out generic archive icon bleeding across the row is noise. Video and
        // images have frames, PDFs have a first page, audio usually has cover art.
        // Everything else stays quiet and keeps only its leading glyph.
        let usesContentBackdrop = [
            "mp4", "mkv", "mov", "m4v", "webm", "avi", "ts",
            "png", "jpg", "jpeg", "gif", "webp", "heic",
            "pdf",
            "mp3", "m4a", "flac", "aac", "wav", "aiff", "alac", "ogg",
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
        rowView.washColor = item.isDownloading ? NDMChrome.accent : nil
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
            syncHeroSelection()
            onSelectMultipleTaskIDs?(indexes.compactMap { $0 < rows.count ? rows[$0].taskID : nil })
            return
        }
        let row = tableView.selectedRow
        if row >= 0, row < rows.count {
            selectedTaskID = rows[row].taskID
            syncSelectionAppearance()
            syncHeroSelection()
            onSelectTaskID?(rows[row].taskID)
        } else {
            selectedTaskID = nil
            syncSelectionAppearance()
            syncHeroSelection()
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
        // Grouped by what the user is trying to do, rather than by the order the
        // actions happened to be written in: look at it → take it somewhere →
        // control the transfer → inspect it → destroy it. Copy File carries ⌘C so
        // the menu advertises the shortcut that also works with the list focused.
        let specs: [(String, Selector, String?, String)?] = [
            (L10n.open, #selector(ctxOpen), "o", "doc.fill"),
            (L10n.showInFinder, #selector(ctxReveal), "r", "folder.fill"),
            nil,
            (L10n.copyFile, #selector(ctxCopyFile), "c", "doc.on.doc.fill"),
            (L10n.copyURL, #selector(ctxCopyURL), nil, "link"),
            (L10n.share, #selector(ctxShare), nil, "square.and.arrow.up"),
            nil,
            (L10n.start, #selector(ctxStart), nil, "play.fill"),
            (L10n.pause, #selector(ctxPause), nil, "pause.fill"),
            (L10n.retry, #selector(ctxRetry), nil, "arrow.clockwise"),
            (L10n.renewURLEllipsis, #selector(ctxRenew), nil, "arrow.triangle.2.circlepath"),
            (L10n.scheduleEllipsis, #selector(ctxSchedule), nil, "clock"),
            nil,
            (L10n.progressDetails, #selector(ctxProgress), nil, "chart.bar.fill"),
            (L10n.propertiesEllipsis, #selector(ctxProperties), nil, "info.circle"),
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
            case #selector(ctxSchedule):
                item.isEnabled = !presentation.isComplete
                item.title = presentation.isScheduled ? L10n.cancelSchedule : L10n.scheduleEllipsis
            case #selector(ctxProgress):
                item.isEnabled = presentation.canShowProgress
                item.title = presentation.isComplete ? L10n.resultDetails : L10n.progressDetails
                item.ndmSymbol(presentation.isComplete ? "sparkles.rectangle.stack" : "chart.bar.fill")
            // There is no file to put on the pasteboard until one has been delivered.
            case #selector(ctxCopyFile):
                item.isEnabled = presentation.canShowInFinder
                item.title = tableView.selectedRowIndexes.count > 1
                    ? L10n.copyFiles
                    : L10n.copyFile
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
    @objc private func ctxSchedule() { if let id = currentContextTaskID() { onContextAction?(.schedule, id) } }
    @objc private func ctxCopyURL() { if let id = currentContextTaskID() { onContextAction?(.copyURL, id) } }
    /// Copying is the one context action that is genuinely useful on a whole
    /// selection, so it routes through the batch path when there is one.
    @objc private func ctxCopyFile() {
        if tableView.selectedRowIndexes.count > 1 {
            emitBatchAction(.copyFile)
        } else if let id = currentContextTaskID() {
            onContextAction?(.copyFile, id)
        }
    }
    @objc private func ctxDelete() { if let id = currentContextTaskID() { onContextAction?(.delete, id) } }
}

private final class ContextMenuDelegate: NSObject, NSMenuDelegate {
    private let handler: (NSMenu) -> Void
    init(handler: @escaping (NSMenu) -> Void) { self.handler = handler }
    func menuNeedsUpdate(_ menu: NSMenu) { handler(menu) }
}

/// Small icon-only ghost button for a row's hover action rail. Quiet hover
/// tint only — do not assign `contentTintColor` from `updateLayer`, or AppKit
/// can re-invalidate the layer into a permanent display loop.
private final class HoverIconButton: NSButton {
    override func becomeFirstResponder() -> Bool {
        adoptFocusRingPolicy(super.becomeFirstResponder())
    }

    private var isHoveringMouse = false
    private var tracking: NSTrackingArea?

    init(symbolName: String, tooltip: String) {
        super.init(frame: .zero)
        bezelStyle = .inline
        isBordered = false
        // Ring only for keyboard focus — see FocusRingPolicy.
        focusRingType = .none
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = NDMChrome.controlCornerRadius
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
private final class TaskRowCellView: NSTableCellView, AccentChromeRefreshing {
    var onHoverAction: ((TaskListContextAction) -> Void)?

    private let glyph = FileGlyphView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let progressBar = ThinProgressView()
    private let trailingLabel = NSTextField(labelWithString: "")
    // Trailing-edge quick actions, revealed only on hover — the size/speed
    // text is what earns the space the rest of the time. Link renew stays in
    // the context / inspector menus so it never crowds filename + size.
    private let hoverStack = NSStackView()
    private let hoverPrimaryButton = HoverIconButton(symbolName: "play.fill", tooltip: L10n.start)
    private let hoverRevealButton = HoverIconButton(symbolName: "folder.fill", tooltip: L10n.showInFinder)
    private var isRowHovering = false
    private var isHoverStackVisible = false
    private var hoverPrimaryAction: TaskListContextAction?
    private var hoverShowsReveal = false
    private var currentTaskID: Int64?
    private var currentRow: TaskRowPresentation?
    private var progressHeight: NSLayoutConstraint?
    private var progressTop: NSLayoutConstraint?
    private var titleTop: NSLayoutConstraint?
    private var badgeHeight: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
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
        // `lineBreakMode` alone does not truncate a label that is allowed to wrap:
        // AppKit wraps first and only truncates the final line, which at narrow
        // widths broke a date across two rows ("2025年7月16 / 日 14:06"). One line,
        // then an ellipsis.
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        trailingLabel.alignment = .right
        trailingLabel.textColor = .labelColor
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

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

        for view in [glyph, titleLabel, badgeLabel, subtitleLabel, progressBar, trailingLabel, hoverStack] {
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

            hoverStack.centerYAnchor.constraint(equalTo: subtitleLabel.centerYAnchor),
            hoverStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingLabel.leadingAnchor, constant: -10),

            barTop,
            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            progressBar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            barHeight,
        ])
    }

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
        let hasActions = hoverPrimaryAction != nil || hoverShowsReveal
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
        currentRow = row

        let liveScale = row.isDownloading ? scale * 1.22 : scale
        glyph.setContentScale(liveScale)
        titleLabel.font = .systemFont(
            ofSize: (row.isDownloading ? 14 : 13) * scale,
            weight: .semibold
        )
        badgeLabel.font = .systemFont(ofSize: 12 * scale, weight: .bold)
        subtitleLabel.font = .systemFont(ofSize: 12 * scale)
        trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .semibold)
        titleTop?.constant = (row.isDownloading ? 15 : 12) * scale
        badgeHeight?.constant = 18 * scale

        let cover = CoverArtCache.shared.image(for: row.taskID)
        glyph.apply(filename: row.filename, cover: cover)
        titleLabel.stringValue = row.filename
        titleLabel.textColor = .labelColor
        trailingLabel.textColor = .labelColor
        trailingLabel.isHidden = false

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
            let datedDetail = row.activityDateText.isEmpty
                ? detail
                : "\(detail) · \(row.activityDateText)"
            check.append(NSAttributedString(string: datedDetail, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5 * scale),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            subtitleLabel.attributedStringValue = check
        } else if let note = row.scheduleNote {
            // A parked download's own status ("未完成 · 上周二") says nothing about
            // the only thing the user wants to know, which is when it will start.
            // Accent-tinted because this row is going to act on its own.
            subtitleLabel.font = .systemFont(ofSize: 11.5 * scale, weight: .medium)
            subtitleLabel.stringValue = note
            subtitleLabel.textColor = NDMChrome.accent
        } else {
            subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .regular)
            let addsDate = !row.isDownloading && !row.isQueued && !row.activityDateText.isEmpty
            subtitleLabel.stringValue = addsDate
                ? "\(row.statusDetail) · \(row.activityDateText)"
                : row.statusDetail
            subtitleLabel.textColor = .secondaryLabelColor
        }

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
        if !showBar {
            progressBar.isActive = false
            progressBar.clearSmoothProgress()
            progressBar.onDisplayedProgressChange = nil
        }
        progressTop?.constant = showBar ? 7 * scale : 0
        // ThinProgressView owns a fixed 4 pt hairline. Scaling this constraint
        // would fight its internal height constraint.
        progressHeight?.constant = showBar ? 4 : 0
        if showBar {
            progressBar.setSmoothProgress(
                taskID: row.taskID,
                target: row.progressFraction,
                complete: row.isComplete
            )
            progressBar.isActive = true
            progressBar.onDisplayedProgressChange = { [weak self] display in
                self?.updateTrailingProgressText(display: display)
            }
            updateTrailingProgressText(display: progressBar.displayedProgress)
            trailingLabel.font = .monospacedDigitSystemFont(
                ofSize: 16 * scale,
                weight: .medium
            )
            trailingLabel.textColor = NDMChrome.accent
        } else {
            trailingLabel.stringValue = row.sizeText
            trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .semibold)
            trailingLabel.textColor = .secondaryLabelColor
        }
    }

    private func updateTrailingProgressText(display: Double) {
        guard let row = currentRow, row.isDownloading else { return }
        let percent = TaskPresentationFormatting.percent(display)
        let speed = row.speedText
        if speed != L10n.emDash && speed != "—" {
            trailingLabel.stringValue = "\(speed) · \(percent)"
        } else {
            trailingLabel.stringValue = percent
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

    func refreshAccentChrome() {
        if !progressBar.isHidden {
            trailingLabel.textColor = NDMChrome.accent
        }
    }

    /// Hide live cell content while the Hero landing overlay owns the pixels.
    /// Dissolve this row's icon into the file's real poster on the next `apply`.
    /// See `FileGlyphView.armPosterReveal`.
    func armPosterReveal() {
        glyph.armPosterReveal()
    }

    func setLandingCovered(_ covered: Bool) {
        let alpha: CGFloat = covered ? 0 : 1
        for view in [glyph, titleLabel, badgeLabel, subtitleLabel, progressBar, trailingLabel, hoverStack] {
            view.alphaValue = alpha
        }
    }

    /// Destination geometry for Hero → row morph, converted into `host`.
    func captureLandingDestination(in host: NSView, taskID: Int64) -> HeroListLandingDestination? {
        layoutSubtreeIfNeeded()
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let rowView = superview
        let rowFrame: NSRect
        if let rowView {
            rowFrame = host.convert(rowView.bounds, from: rowView)
        } else {
            rowFrame = host.convert(bounds, from: self)
        }
        return HeroListLandingDestination(
            taskID: taskID,
            rowFrame: rowFrame,
            glyphFrame: host.convert(glyph.bounds, from: glyph),
            nameFrame: host.convert(titleLabel.bounds, from: titleLabel),
            statusFrame: host.convert(subtitleLabel.bounds, from: subtitleLabel),
            nameSnapshot: Self.snapshot(of: titleLabel),
            statusSnapshot: Self.snapshot(of: subtitleLabel)
        )
    }

    private static func snapshot(of view: NSView) -> NSImage? {
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0.5,
              view.bounds.height > 0.5,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        representation.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        return image
    }
}

// MARK: - Inspector

/// Crop-filled cover art with rounded corners and a quiet neutral drop
/// shadow — no reflection strip, no ambient color wash. Only shown when
/// `CoverArtCache` has a real preview; the generic per-extension file glyph
/// stays small and inline instead of being stretched up to hero size.
private final class HeroPreviewView: NSView {
    override var isFlipped: Bool { true }
    private let imageLayer = CALayer()
    private let cornerRadius: CGFloat = 12

    var image: NSImage? {
        didSet {
            let wasEmpty = oldValue == nil
            imageLayer.contents = image
            if wasEmpty, image != nil, window != nil { revealEntrance() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Host must stay fully clear. An opaque root layer behind a rounded
        // image sublayer shows as light-gray L-corners at every cut.
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        // Quiet lift only — a large / dominant-colored shadow reads as a dirty
        // horizontal band on the inspector's white surface.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.10
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.backgroundColor = NSColor.clear.cgColor
        imageLayer.cornerRadius = cornerRadius
        imageLayer.masksToBounds = true
        if #available(macOS 10.15, *) {
            imageLayer.cornerCurve = .continuous
        }
        layer?.addSublayer(imageLayer)
    }

    private func revealEntrance() {
        let scale = NDMChrome.spring(keyPath: "transform.scale")
        scale.fromValue = 0.92
        scale.toValue = 1.0
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

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // AppKit may re-paint an opaque fill onto layer-backed views; keep the
        // host transparent so square corners never peek past the cover.
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        // Shadow silhouette must match the rounded cover — a rectangular
        // shadowPath (or none) draws square plates under each corner.
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        CATransaction.commit()
    }
}

/// Flat Get Info inspector with a quiet, file-derived ambient preview.
@MainActor
private final class InspectorViewController: NSViewController {
    var onAction: ((TaskListContextAction) -> Void)?
    var onShare: ((NSView) -> Void)?
    var onCopyURL: (() -> Bool)?

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
        view = ChromeBox(fill: NDMChrome.railSurface)
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

        // Rail actions are custom flat controls (`InspectorActionButton`) —
        // do not apply AppKit `.rounded` main/ghost bezels; they fight the
        // shared 4–6 radius + rail hover metrics.
        for button in [primaryButton, secondaryButton, tertiaryButton, copyURLButton] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.controlSize = .regular
        }
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
            $0.heightAnchor.constraint(equalToConstant: NDMChrome.railActionHeight)
        }
        self.actionButtonHeights = actionButtonHeights
        iconSizeConstraints = [
            iconView.widthAnchor.constraint(equalToConstant: 54),
            iconView.heightAnchor.constraint(equalToConstant: 54),
        ]
        NSLayoutConstraint.activate([
            heroImageView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            // True 16:9 cover — a squashed frame reads as a bug, not a thumbnail.
            heroImageView.heightAnchor.constraint(
                equalTo: heroImageView.widthAnchor,
                multiplier: 9.0 / 16.0
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
            firstActionSeparator.heightAnchor.constraint(equalToConstant: 16),
            secondActionSeparator.widthAnchor.constraint(equalToConstant: 1),
            secondActionSeparator.heightAnchor.constraint(equalToConstant: 16),
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
        actionButtonHeights.forEach { $0.constant = NDMChrome.railActionHeight * layoutScale }
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
        if let action = button as? InspectorActionButton {
            // Primary rail action earns a soft accent wash; secondaries stay
            // neutral with a quieter hover deepen.
            action.prefersAccentHover = chrome == .primary
            action.usesOutlinedHover = false
            action.noteRestingTint()
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
            // No ambient color wash under the cover — a radial tint behind the
            // transparent scroll reads as a dirty strip below the thumbnail.
            atmosphereView.setAtmosphere(nil)
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

    func refreshAccentChrome() {
        placeholderIcon.contentTintColor = NDMChrome.accent.withAlphaComponent(0.35)
        audioActionIcon.contentTintColor = NDMChrome.accent
        let row = currentRow
        currentRow = nil
        hasAppliedRow = false
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
            progressBar.clearSmoothProgress()
            var pairs: [(String, String)] = [(L10n.size, row.sizeText)]
            if !row.activityDateText.isEmpty {
                pairs.append((L10n.downloadTime, row.activityDateText))
            }
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
            if row.isDownloading {
                progressBar.setSmoothProgress(
                    taskID: row.taskID,
                    target: row.progressFraction,
                    complete: row.isComplete
                )
            } else {
                progressBar.clearSmoothProgress()
            }
            progressBar.isActive = row.isDownloading
            var pairs: [(String, String)] = [(L10n.size, row.sizeText)]
            if row.speedText != L10n.emDash && row.speedText != "—" {
                pairs.append((L10n.speed, row.speedText))
            }
            if row.etaText != L10n.emDash && row.etaText != "—" {
                pairs.append((L10n.timeLeft, row.etaText))
            }
            if row.isDownloading, !row.connectionsText.isEmpty {
                pairs.append((L10n.connections, row.connectionsText))
            }
            if !row.activityDateText.isEmpty {
                pairs.append((L10n.lastAttempt, row.activityDateText))
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
            primaryFiresRenew = false
        } else if row.canRetry {
            // Only promote "Update Link" when the diagnostic says the URL is stale.
            // Generic failures keep Retry primary; renew stays in … / context menus.
            primaryFiresRenew = row.needsLinkRenew && row.canRenew
            if primaryFiresRenew {
                decorate(primaryButton, title: L10n.renewURL, symbol: "arrow.triangle.2.circlepath", chrome: .primary)
                primaryButton.isEnabled = true
                decorate(secondaryButton, title: L10n.retry, symbol: "arrow.clockwise", chrome: .soft)
                secondaryButton.isEnabled = true
            } else {
                decorate(primaryButton, title: L10n.retry, symbol: "arrow.clockwise", chrome: .primary)
                primaryButton.isEnabled = true
                decorate(secondaryButton, title: L10n.detailsEllipsis, symbol: "info.circle", chrome: .soft)
                secondaryButton.isEnabled = row.canShowProgress
            }
            progressButtonShowsConnectionDetails = true
        } else if row.canPause {
            decorate(primaryButton, title: L10n.pause, symbol: "pause.fill", chrome: .primary)
            primaryButton.isEnabled = true
            decorate(secondaryButton, title: L10n.detailsEllipsis, symbol: "info.circle", chrome: .soft)
            secondaryButton.isEnabled = row.canShowProgress
            progressButtonShowsConnectionDetails = true
            primaryFiresRenew = false
        } else {
            decorate(primaryButton, title: L10n.start, symbol: "play.fill", chrome: .primary)
            primaryButton.isEnabled = row.canStart
            decorate(secondaryButton, title: L10n.detailsEllipsis, symbol: "info.circle", chrome: .soft)
            secondaryButton.isEnabled = row.canShowProgress
            progressButtonShowsConnectionDetails = false
            primaryFiresRenew = false
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
            let succeeded = onCopyURL?() ?? false
            flashCopyResult(copyURLButton, succeeded: succeeded)
        }
    }

    /// Momentary confirmation after a verified pasteboard read-back.
    private func flashCopyResult(_ button: InspectorActionButton, succeeded: Bool) {
        let title = button.title
        let image = button.image
        let tint = button.contentTintColor
        button.title = succeeded ? L10n.copiedToClipboard : L10n.copyFailed
        button.image = NDMChrome.symbol(
            succeeded ? "checkmark" : "exclamationmark.triangle",
            pointSize: 12,
            weight: .semibold
        )
        button.contentTintColor = succeeded ? .systemGreen : .systemOrange
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak button] in
            guard let button else { return }
            button.title = title
            button.image = image
            button.contentTintColor = tint
        }
    }

    @objc private func tapMore() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if utilityButtonSharesFile {
            addMoreItem(menu, title: L10n.quickLook, selector: #selector(moreQuickLook), symbol: "eye")
            addMoreItem(menu, title: L10n.copyURL, selector: #selector(moreCopyURL), symbol: "link")
        }
        if let row = currentRow, row.canRenew, !row.isComplete {
            // Secondary home for renew when it is not the primary CTA.
            addMoreItem(menu, title: L10n.renewURLEllipsis, selector: #selector(moreRenew), symbol: "link")
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
    @objc private func moreRenew() { onAction?(.renew) }
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
