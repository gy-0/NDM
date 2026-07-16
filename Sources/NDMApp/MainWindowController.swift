import AppKit
import NDMCore
import NDMEngine

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let manager: DownloadManager

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

    private var progressWindows: [Int64: ProgressWindowController] = [:]
    private var settingsWindow: SettingsWindowController?
    private var propsWindow: TaskPropertiesWindowController?
    private var browsersWindow: BrowsersWindowController?
    private var refreshTask: Task<Void, Never>?

    private var startToolbarItem: NSToolbarItem?
    private var pauseToolbarItem: NSToolbarItem?

    init(manager: DownloadManager) {
        self.manager = manager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.appName
        window.minSize = NSSize(width: 880, height: 520)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        NDMChrome.applyWindowChrome(window)
        window.center()
        super.init(window: window)
        window.contentViewController = splitController
        NDMChrome.applyLayerFill(splitController.view, NDMChrome.windowFill)
        configureSplit()
        configureToolbar()
        wireCallbacks()
        NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.relocalizeChrome()
            }
        }
        Task { await reload() }
        startAutoRefresh()
    }

    /// Refresh toolbar / inspector chrome after language switch.
    func relocalizeChrome() {
        window?.title = L10n.appName
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func configureSplit() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 168
        sidebarItem.maximumThickness = 240
        if #available(macOS 11.0, *) {
            // Keep sidebar material continuous under the traffic lights.
            sidebarItem.titlebarSeparatorStyle = .none
        }

        let listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = 420

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        // Fixed width — long filenames must truncate inside, never shove the split.
        inspectorItem.minimumThickness = 300
        inspectorItem.maximumThickness = 300
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = false
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(260)

        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(listItem)
        splitController.addSplitViewItem(inspectorItem)
        splitController.splitView.autosaveName = "NDM.MainSplit"
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "NDM.MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
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
    }

    // MARK: - Data

    func reload() async {
        do {
            allTasks = try await manager.listTasks()
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
            emptySubtitle: emptyStateSubtitle()
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

    @objc func menuStartSelected() { startSelected() }
    @objc func menuPauseSelected() { pauseSelected() }
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
        if let inspectorItem = splitController.splitViewItems.last {
            let shouldCollapse = selectedTaskID == nil && displayedRows.isEmpty
            if inspectorItem.isCollapsed != shouldCollapse {
                inspectorItem.animator().isCollapsed = shouldCollapse
            }
        }
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let hasActive = self.allTasks.contains {
                    $0.status == .downloading || $0.status == .waiting
                }
                if hasActive {
                    await self.reload()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Actions

    @objc func promptNewURL() {
        let alert = NSAlert()
        alert.messageText = L10n.newDownload
        alert.informativeText = L10n.pasteURLHint
        alert.addButton(withTitle: L10n.download)
        alert.addButton(withTitle: L10n.cancel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://"
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        alert.accessoryView = field
        // Layout first, then force key focus — accessory fields often lose
        // first-responder to the default button without this.
        alert.layout()
        alert.window.initialFirstResponder = field
        _ = alert.window.makeFirstResponder(field)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        startURL(url)
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
            let wc = SettingsWindowController(manager: manager, settings: settings)
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

    private func startURL(_ urlString: String) {
        Task {
            do {
                let task = try await manager.addURL(urlString)
                selectedTaskID = task.id
                selectedFilter = .active
                // Open progress immediately — don't wait for start()/reload().
                showProgress(for: task.id)
                try await manager.start(taskID: task.id)
                await reload()
            } catch {
                showAlert(error)
                await reload()
            }
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
        let current = allTasks.first(where: { $0.id == id })?.url ?? ""
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

    private func revealTaskFile(_ id: Int64) {
        guard let task = allTasks.first(where: { $0.id == id }),
              let url = task.destinationFileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert(message: L10n.fileNotFound, detail: url.path)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func showProperties(for id: Int64) {
        guard let task = allTasks.first(where: { $0.id == id }) else { return }
        // Open after the current menu/toolbar event finishes. Showing a window
        // synchronously from an NSMenu action commonly stalls for a beat.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let existing = self.propsWindow, existing.taskID == id {
                existing.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            let wc = TaskPropertiesWindowController(manager: self.manager, task: task)
            self.propsWindow = wc
            wc.showWindow(nil)
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
        case .open:
            openTaskFile(taskID)
        case .reveal:
            revealTaskFile(taskID)
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
        view = NSView()
        NDMChrome.applyLayerFill(view, NDMChrome.sidebarFill)
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.allowsEmptySelection = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("filter"))
        tableView.addTableColumn(col)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NDMChrome.sidebarFill
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func update(counts: [SidebarFilter: Int], selected: SidebarFilter) {
        self.counts = counts
        self.selected = selected
        tableView.reloadData()
        if let index = rows.firstIndex(of: .filter(selected)) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            return label
        case .filter(let filter):
            let count = counts[filter] ?? 0
            let cell = NSTableCellView()
            let icon = NSImageView()
            icon.image = NDMChrome.symbol(NDMChrome.sidebarSymbolName(for: filter), pointSize: 13)
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            let title = NSTextField(labelWithString: filter.title)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.translatesAutoresizingMaskIntoConstraints = false
            let badge = NSTextField(labelWithString: "\(count)")
            badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            badge.textColor = .tertiaryLabelColor
            badge.alignment = .right
            badge.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.addSubview(title)
            cell.addSubview(badge)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
            ])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .filter(let filter) = rows[row] else { return }
        selected = filter
        onSelectFilter?(filter)
    }
}

// MARK: - Task list

enum TaskListContextAction {
    case open, reveal, start, pause, retry, renew, progress, properties, copyURL, delete
}

@MainActor
private final class TaskListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelectTaskID: ((Int64?) -> Void)?
    var onActivateTaskID: ((Int64) -> Void)?
    var onContextAction: ((TaskListContextAction, Int64) -> Void)?
    var onDropURL: ((String) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptySubtitleLabel = NSTextField(labelWithString: "")
    private let emptyStack = NSStackView()
    private var rows: [TaskRowPresentation] = []
    private var contextMenuDelegate: ContextMenuDelegate?

    override func loadView() {
        let root = URLDropView(frame: .zero)
        root.onDropURL = { [weak self] url in self?.onDropURL?(url) }
        root.onHoverChange = { [weak self] hovering in
            self?.scrollView.layer?.borderWidth = hovering ? 2 : 0
            self?.scrollView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
        view = root
        NDMChrome.applyLayerFill(root, NDMChrome.contentSurface)

        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 72
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = NDMChrome.contentSurface
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.target = self
        tableView.menu = makeContextMenu()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        tableView.addTableColumn(col)

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

        emptyLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptySubtitleLabel.font = .systemFont(ofSize: 13)
        emptySubtitleLabel.textColor = .tertiaryLabelColor
        emptySubtitleLabel.alignment = .center
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 8
        emptyStack.addArrangedSubview(emptyLabel)
        emptyStack.addArrangedSubview(emptySubtitleLabel)
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

    func relocalizeChrome() {
        tableView.menu = makeContextMenu()
    }

    func update(
        rows: [TaskRowPresentation],
        selectedTaskID: Int64?,
        emptyTitle: String,
        emptySubtitle: String
    ) {
        self.rows = rows
        emptyLabel.stringValue = emptyTitle
        emptySubtitleLabel.stringValue = emptySubtitle
        emptyStack.isHidden = !rows.isEmpty
        tableView.isHidden = rows.isEmpty
        tableView.reloadData()
        if let selectedTaskID, let index = rows.firstIndex(where: { $0.taskID == selectedTaskID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 72 }
        return rows[row].showsProgressBar ? 72 : 56
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("TaskRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? TaskRowCellView) ?? TaskRowCellView()
        cell.identifier = id
        cell.apply(rows[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0, row < rows.count {
            onSelectTaskID?(rows[row].taskID)
        } else {
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
        let specs: [(String, Selector, String?, String)?] = [
            (L10n.open, #selector(ctxOpen), "o", "doc.fill"),
            (L10n.showInFinder, #selector(ctxReveal), "r", "folder.fill"),
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
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count else {
            menu.items.forEach { $0.isEnabled = false }
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let presentation = rows[row]
        for item in menu.items {
            switch item.action {
            case #selector(ctxOpen): item.isEnabled = presentation.canOpen
            case #selector(ctxReveal): item.isEnabled = presentation.canShowInFinder
            case #selector(ctxRetry):
                item.isEnabled = presentation.canRetry
                item.title = L10n.retry
            case #selector(ctxRenew): item.isEnabled = presentation.canRenew
            case #selector(ctxStart):
                item.isEnabled = presentation.canStart && !presentation.canRetry
            case #selector(ctxPause): item.isEnabled = presentation.canPause
            case #selector(ctxProgress): item.isEnabled = presentation.canShowProgress
            case #selector(ctxProperties), #selector(ctxDelete), #selector(ctxCopyURL): item.isEnabled = true
            default: break
            }
        }
    }

    private func currentContextTaskID() -> Int64? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count else { return nil }
        return rows[row].taskID
    }

    @objc func delete(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        onContextAction?(.delete, rows[row].taskID)
    }

    @objc private func ctxOpen() { if let id = currentContextTaskID() { onContextAction?(.open, id) } }
    @objc private func ctxReveal() { if let id = currentContextTaskID() { onContextAction?(.reveal, id) } }
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
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let trailingLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private var progressHeight: NSLayoutConstraint?
    private var progressTop: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.style = .bar
        trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        trailingLabel.alignment = .right
        trailingLabel.textColor = .secondaryLabelColor
        metaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.alignment = .right
        metaLabel.lineBreakMode = .byTruncatingTail

        for view in [iconView, titleLabel, subtitleLabel, progressBar, trailingLabel, metaLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let barTop = progressBar.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 7)
        let barHeight = progressBar.heightAnchor.constraint(equalToConstant: 4)
        progressTop = barTop
        progressHeight = barHeight
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingLabel.leadingAnchor, constant: -12),

            trailingLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            trailingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: metaLabel.leadingAnchor, constant: -12),

            metaLabel.centerYAnchor.constraint(equalTo: subtitleLabel.centerYAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            metaLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),

            barTop,
            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progressBar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -11),
            barHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: TaskRowPresentation) {
        iconView.image = NDMChrome.fileIcon(filename: row.filename, pointSize: 36)
        titleLabel.stringValue = row.filename
        if let error = row.errorText, !error.isEmpty {
            subtitleLabel.stringValue = "\(row.statusTitle) · \(error)"
            subtitleLabel.textColor = .secondaryLabelColor
        } else if row.host.isEmpty {
            subtitleLabel.stringValue = row.statusTitle
            subtitleLabel.textColor = .secondaryLabelColor
        } else {
            subtitleLabel.stringValue = "\(row.statusTitle) · \(row.host)"
            subtitleLabel.textColor = .secondaryLabelColor
        }

        let showBar = row.showsProgressBar
        progressBar.isHidden = !showBar
        progressTop?.constant = showBar ? 8 : 0
        progressHeight?.constant = showBar ? 6 : 0
        if showBar {
            progressBar.doubleValue = row.progressFraction
            trailingLabel.stringValue = row.progressText
            metaLabel.stringValue = [row.sizeText, row.speedText, row.etaText]
                .filter { $0 != "—" && $0 != L10n.emDash }
                .joined(separator: "  ·  ")
        } else {
            // Quiet Finder: completed rows lead with size, not a candy status chip.
            trailingLabel.stringValue = row.sizeText
            metaLabel.stringValue = ""
        }
        trailingLabel.textColor = .secondaryLabelColor
        trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        if metaLabel.stringValue.isEmpty && showBar {
            metaLabel.stringValue = row.sizeText
        }
    }
}

// MARK: - Inspector

/// B glance + A Get Info; docked action grid; width locked so text never expands the split.
@MainActor
private final class InspectorViewController: NSViewController {
    var onAction: ((TaskListContextAction) -> Void)?

    private let titleLabel = NSTextField(labelWithString: L10n.details)
    private let glanceValueLabel = NSTextField(labelWithString: "")
    private let glanceUnitLabel = NSTextField(labelWithString: "")
    private let glanceCaptionLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let kvStack = NSStackView()
    private let primaryButton = NSButton(title: L10n.start, target: nil, action: nil)
    private let secondaryButton = NSButton(title: L10n.pause, target: nil, action: nil)
    private let tertiaryButton = NSButton(title: L10n.detailsEllipsis, target: nil, action: nil)
    private let copyURLButton = NSButton(title: L10n.copyURL, target: nil, action: nil)
    private let deleteButton = NSButton(title: L10n.removeEllipsis, target: nil, action: nil)
    private let placeholderLabel = NSTextField(wrappingLabelWithString: L10n.selectDownloadHint)
    private let contentStack = NSStackView()
    private let glanceRow = NSStackView()
    private let actionDock = NSView()
    private var progressButtonShowsConnectionDetails = false
    private var currentRow: TaskRowPresentation?

    override func loadView() {
        view = NSView()
        NDMChrome.applyLayerFill(view, NDMChrome.contentSurface)

        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .tertiaryLabelColor

        glanceValueLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
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
        filenameLabel.maximumNumberOfLines = 2
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.cell?.wraps = true
        filenameLabel.cell?.truncatesLastVisibleLine = true
        filenameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filenameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filenameLabel.toolTip = nil

        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.style = .bar

        kvStack.orientation = .vertical
        kvStack.alignment = .leading
        kvStack.spacing = 8

        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stylePrimary(primaryButton)
        styleSecondary(secondaryButton)
        styleSoft(tertiaryButton)
        styleSoft(copyURLButton)
        styleSoft(deleteButton)

        primaryButton.action = #selector(tapPrimary)
        secondaryButton.action = #selector(tapSecondary)
        tertiaryButton.action = #selector(tapProgress)
        copyURLButton.action = #selector(tapCopyURL)
        deleteButton.action = #selector(tapDelete)

        let nameBlock = NSStackView(views: [filenameLabel, statusLabel])
        nameBlock.orientation = .vertical
        nameBlock.alignment = .leading
        nameBlock.spacing = 2
        nameBlock.setHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [iconView, nameBlock])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        let glanceBlock = NSStackView(views: [glanceRow, glanceCaptionLabel])
        glanceBlock.orientation = .vertical
        glanceBlock.alignment = .leading
        glanceBlock.spacing = 4

        // Main pair side-by-side; soft trio in one row — less mechanical than a ladder.
        let primaryRow = NSStackView(views: [primaryButton, secondaryButton])
        primaryRow.orientation = .horizontal
        primaryRow.alignment = .centerY
        primaryRow.spacing = 8
        primaryRow.distribution = .fillEqually

        let softRow = NSStackView(views: [tertiaryButton, copyURLButton, deleteButton])
        softRow.orientation = .horizontal
        softRow.alignment = .centerY
        softRow.spacing = 6
        softRow.distribution = .fillEqually

        let dockStack = NSStackView(views: [primaryRow, softRow])
        dockStack.orientation = .vertical
        dockStack.alignment = .leading
        dockStack.spacing = 8
        dockStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        dockStack.translatesAutoresizingMaskIntoConstraints = false

        actionDock.wantsLayer = true
        actionDock.layer?.cornerRadius = 10
        actionDock.layer?.borderWidth = 1
        actionDock.translatesAutoresizingMaskIntoConstraints = false
        actionDock.addSubview(dockStack)
        refreshDockChrome()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 14, right: 14)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for sub in [titleLabel, glanceBlock, header, progressBar, kvStack, actionDock] {
            contentStack.addArrangedSubview(sub)
        }
        contentStack.setCustomSpacing(14, after: glanceBlock)
        contentStack.setCustomSpacing(16, after: kvStack)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            nameBlock.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -46),
            progressBar.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            progressBar.heightAnchor.constraint(equalToConstant: 4),
            kvStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            actionDock.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            dockStack.topAnchor.constraint(equalTo: actionDock.topAnchor),
            dockStack.leadingAnchor.constraint(equalTo: actionDock.leadingAnchor),
            dockStack.trailingAnchor.constraint(equalTo: actionDock.trailingAnchor),
            dockStack.bottomAnchor.constraint(equalTo: actionDock.bottomAnchor),
            primaryRow.widthAnchor.constraint(equalTo: dockStack.widthAnchor, constant: -24),
            softRow.widthAnchor.constraint(equalTo: dockStack.widthAnchor, constant: -24),
            primaryButton.heightAnchor.constraint(equalToConstant: 32),
            secondaryButton.heightAnchor.constraint(equalToConstant: 32),
            tertiaryButton.heightAnchor.constraint(equalToConstant: 44),
            copyURLButton.heightAnchor.constraint(equalToConstant: 44),
            deleteButton.heightAnchor.constraint(equalToConstant: 44),
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
        update(row: nil)
    }

    private func refreshDockChrome() {
        actionDock.wantsLayer = true
        actionDock.layer?.backgroundColor = NDMChrome.dockFill.cgColor
        actionDock.layer?.borderColor = NDMChrome.hairline.cgColor
    }

    private func stylePrimary(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .regular
        button.imagePosition = .imageLeading
        button.isBordered = true
        button.target = self
        button.keyEquivalent = "\r"
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        if #available(macOS 11.0, *) {
            button.bezelColor = NDMChrome.accent
        }
    }

    private func styleSecondary(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.imagePosition = .imageLeading
        button.isBordered = true
        button.target = self
        button.font = .systemFont(ofSize: 12, weight: .medium)
        (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    }

    private func styleSoft(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .small
        button.imagePosition = .imageAbove
        button.isBordered = true
        button.target = self
        button.font = .systemFont(ofSize: 10, weight: .medium)
        (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    }

    private enum ActionChrome {
        case primary(symbol: String)
        case secondary(symbol: String)
        case soft(symbol: String)
    }

    private func decorate(_ button: NSButton, title: String, chrome: ActionChrome) {
        button.title = title
        button.toolTip = title
        switch chrome {
        case .primary(let symbol):
            button.image = NDMChrome.symbol(symbol, pointSize: 11, weight: .semibold)
            button.imagePosition = .imageLeading
        case .secondary(let symbol):
            button.image = NDMChrome.symbol(symbol, pointSize: 11, weight: .medium)
            button.imagePosition = .imageLeading
        case .soft(let symbol):
            button.image = NDMChrome.symbol(symbol, pointSize: 11, weight: .medium)
            button.imagePosition = .imageAbove
        }
    }

    private func makeKVRow(key: String, value: String) -> NSView {
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 11)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
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
        row.spacing = 8
        row.distribution = .fill
        NSLayoutConstraint.activate([
            keyLabel.widthAnchor.constraint(equalToConstant: 48),
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
        update(row: currentRow)
    }

    func update(row: TaskRowPresentation?) {
        currentRow = row
        let hasSelection = row != nil
        placeholderLabel.isHidden = hasSelection
        contentStack.isHidden = !hasSelection
        titleLabel.stringValue = L10n.details.uppercased()
        refreshDockChrome()
        guard let row else { return }

        iconView.image = NDMChrome.fileIcon(filename: row.filename, pointSize: 36)
        filenameLabel.stringValue = row.filename
        filenameLabel.toolTip = row.filename
        statusLabel.stringValue = row.statusTitle

        if row.isComplete {
            let split = Self.splitMagnitude(row.sizeText)
            applyGlance(value: split.0, unit: split.1, caption: L10n.size)
            progressBar.isHidden = true
            var pairs: [(String, String)] = [(L10n.size, row.sizeText)]
            if !row.host.isEmpty { pairs.append((L10n.source, row.host)) }
            reloadKV(pairs)
        } else {
            let split = Self.splitMagnitude(row.progressText)
            applyGlance(value: split.0, unit: split.1, caption: L10n.progress)
            progressBar.isHidden = false
            progressBar.doubleValue = row.progressFraction
            var pairs: [(String, String)] = [
                (L10n.progress, row.progressText),
                (L10n.size, row.sizeText),
            ]
            if row.speedText != L10n.emDash && row.speedText != "—" {
                pairs.append((L10n.speed, row.speedText))
            }
            if row.etaText != L10n.emDash && row.etaText != "—" {
                pairs.append((L10n.timeLeft, row.etaText))
            }
            if !row.host.isEmpty { pairs.append((L10n.source, row.host)) }
            reloadKV(pairs)
        }

        if row.canOpen {
            decorate(primaryButton, title: L10n.open, chrome: .primary(symbol: "arrow.up.forward.app"))
            primaryButton.isEnabled = true
            decorate(secondaryButton, title: L10n.showInFinder, chrome: .secondary(symbol: "folder"))
            secondaryButton.isEnabled = row.canShowInFinder
            secondaryButton.isHidden = false
            decorate(tertiaryButton, title: L10n.properties, chrome: .soft(symbol: "info.circle"))
            tertiaryButton.isEnabled = true
            progressButtonShowsConnectionDetails = false
        } else if row.canRetry {
            decorate(primaryButton, title: L10n.retry, chrome: .primary(symbol: "arrow.clockwise"))
            primaryButton.isEnabled = true
            decorate(secondaryButton, title: L10n.renew, chrome: .secondary(symbol: "link"))
            secondaryButton.isEnabled = row.canRenew
            secondaryButton.isHidden = false
            decorate(tertiaryButton, title: L10n.details, chrome: .soft(symbol: "chart.bar"))
            tertiaryButton.isEnabled = row.canShowProgress
            progressButtonShowsConnectionDetails = true
        } else if row.canPause {
            decorate(primaryButton, title: L10n.pause, chrome: .primary(symbol: "pause.fill"))
            primaryButton.isEnabled = true
            decorate(secondaryButton, title: L10n.progress, chrome: .secondary(symbol: "chart.bar"))
            secondaryButton.isEnabled = row.canShowProgress
            secondaryButton.isHidden = false
            decorate(tertiaryButton, title: L10n.properties, chrome: .soft(symbol: "info.circle"))
            tertiaryButton.isEnabled = true
            progressButtonShowsConnectionDetails = false
        } else {
            decorate(primaryButton, title: L10n.start, chrome: .primary(symbol: "play.fill"))
            primaryButton.isEnabled = row.canStart
            if row.canRenew {
                decorate(secondaryButton, title: L10n.renew, chrome: .secondary(symbol: "link"))
                secondaryButton.isEnabled = true
            } else {
                decorate(secondaryButton, title: L10n.progress, chrome: .secondary(symbol: "chart.bar"))
                secondaryButton.isEnabled = row.canShowProgress
            }
            secondaryButton.isHidden = false
            decorate(tertiaryButton, title: L10n.properties, chrome: .soft(symbol: "info.circle"))
            tertiaryButton.isEnabled = true
            progressButtonShowsConnectionDetails = false
        }

        decorate(copyURLButton, title: L10n.copy, chrome: .soft(symbol: "doc.on.doc"))
        copyURLButton.toolTip = L10n.copyURL
        decorate(deleteButton, title: L10n.delete, chrome: .soft(symbol: "trash"))
        deleteButton.toolTip = L10n.removeEllipsis
    }

    @objc private func tapPrimary() {
        guard let row = currentRow else { return }
        if row.canOpen {
            onAction?(.open)
        } else if row.canRetry {
            onAction?(.retry)
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

    @objc private func tapCopyURL() { onAction?(.copyURL) }
    @objc private func tapDelete() { onAction?(.delete) }
}

// MARK: - Drop target

private final class URLDropView: NSView {
    var onDropURL: ((String) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.URL, .string])
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
        if let str = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           str.contains("://"),
           let first = str.components(separatedBy: .whitespacesAndNewlines).first {
            onDropURL?(first)
            return true
        }
        return false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onHoverChange?(false)
    }
}
