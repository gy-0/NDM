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
        window.title = "NDM"
        window.minSize = NSSize(width: 880, height: 520)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.center()
        super.init(window: window)
        window.contentViewController = splitController
        configureSplit()
        configureToolbar()
        wireCallbacks()
        Task { await reload() }
        startAutoRefresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func configureSplit() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 168
        sidebarItem.maximumThickness = 240

        let listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = 420

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 360
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
            item.label = "New"
            item.paletteLabel = "New Download"
            item.toolTip = "Add a new download URL"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Download")
            item.target = self
            item.action = #selector(promptNewURL)
            return item
        case .ndmStart:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Start"
            item.paletteLabel = "Start"
            item.toolTip = "Start or resume the selected download"
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start")
            item.target = self
            item.action = #selector(startSelected)
            startToolbarItem = item
            return item
        case .ndmPause:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Pause"
            item.paletteLabel = "Pause"
            item.toolTip = "Pause the selected download"
            item.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
            item.target = self
            item.action = #selector(pauseSelected)
            pauseToolbarItem = item
            return item
        case .ndmSearch:
            let field = NSSearchField()
            field.placeholderString = "Search downloads"
            field.target = self
            field.action = #selector(searchChanged(_:))
            field.sendsSearchStringImmediately = true
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
            field.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.view = field
            return item
        case .ndmBrowsers:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Browsers"
            item.paletteLabel = "Browsers"
            item.toolTip = "Browser extension setup"
            item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Browsers")
            item.target = self
            item.action = #selector(openBrowsers)
            return item
        case .ndmSettings:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Settings"
            item.paletteLabel = "Settings"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
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
        listController.update(rows: displayedRows, selectedTaskID: selectedTaskID, emptyTitle: emptyStateTitle())
        updateInspector()
        updateToolbarEnablement()
    }

    private func emptyStateTitle() -> String {
        if allTasks.isEmpty {
            return "No downloads yet"
        }
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matches for “\(searchQuery)”"
        }
        return "No \(selectedFilter.title.lowercased()) downloads"
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
        alert.messageText = "New Download"
        alert.informativeText = "Paste an HTTP, HTTPS, or FTP URL."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
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
        let wc = BrowsersWindowController()
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
            return
        }
        let name = allTasks.first(where: { $0.id == taskID })?.filename
            ?? displayedRows.first(where: { $0.taskID == taskID })?.filename
            ?? "Download \(taskID)"
        let wc = ProgressWindowController(manager: manager, taskID: taskID, filename: name)
        progressWindows[taskID] = wc
        wc.showWindow(nil)
    }

    private func startURL(_ urlString: String) {
        Task {
            do {
                let task = try await manager.addURL(urlString)
                try await manager.start(taskID: task.id)
                selectedTaskID = task.id
                selectedFilter = .active
                await reload()
                showProgress(for: task.id)
            } catch {
                showAlert(error)
                await reload()
            }
        }
    }

    private func startTask(_ id: Int64) {
        Task {
            do {
                try await manager.start(taskID: id)
                selectedTaskID = id
                await reload()
                showProgress(for: id)
            } catch {
                showAlert(error)
                await reload()
            }
        }
    }

    private func deleteTask(_ id: Int64) {
        Task {
            do {
                try await manager.remove(taskID: id, deleteFile: false)
                if selectedTaskID == id { selectedTaskID = nil }
                await reload()
            } catch {
                showAlert(error)
            }
        }
    }

    private func openTaskFile(_ id: Int64) {
        guard let task = allTasks.first(where: { $0.id == id }),
              let url = task.destinationFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealTaskFile(_ id: Int64) {
        guard let task = allTasks.first(where: { $0.id == id }),
              let url = task.destinationFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func showProperties(for id: Int64) {
        guard let task = allTasks.first(where: { $0.id == id }) else { return }
        let wc = TaskPropertiesWindowController(manager: manager, task: task)
        propsWindow = wc
        wc.showWindow(nil)
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
        case .start:
            startTask(taskID)
        case .pause:
            Task {
                await manager.pause(taskID: taskID)
                await reload()
            }
        case .progress:
            showProgress(for: taskID)
        case .properties:
            showProperties(for: taskID)
        case .delete:
            deleteTask(taskID)
        }
    }

    private func showAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Something went wrong"
        alert.informativeText = error.localizedDescription
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

@MainActor
private final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelectFilter: ((SidebarFilter) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var counts: [SidebarFilter: Int] = [:]
    private var selected: SidebarFilter = .all

    override func loadView() {
        view = NSView()
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.allowsEmptySelection = false
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
        if let index = SidebarFilter.allCases.firstIndex(of: selected) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { SidebarFilter.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let filter = SidebarFilter.allCases[row]
        let count = counts[filter] ?? 0
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: filter.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        let badge = NSTextField(labelWithString: "\(count)")
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .right
        badge.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(title)
        cell.addSubview(badge)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < SidebarFilter.allCases.count else { return }
        let filter = SidebarFilter.allCases[row]
        selected = filter
        onSelectFilter?(filter)
    }
}

// MARK: - Task list

enum TaskListContextAction {
    case open, reveal, start, pause, progress, properties, delete
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

        tableView.headerView = nil
        tableView.rowHeight = 72
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
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
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    func update(rows: [TaskRowPresentation], selectedTaskID: Int64?, emptyTitle: String) {
        self.rows = rows
        emptyLabel.stringValue = emptyTitle
        emptyLabel.isHidden = !rows.isEmpty
        tableView.isHidden = rows.isEmpty
        tableView.reloadData()
        if let selectedTaskID, let index = rows.firstIndex(where: { $0.taskID == selectedTaskID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

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
        for item in [
            ("Open", #selector(ctxOpen), "o"),
            ("Show in Finder", #selector(ctxReveal), "r"),
            nil,
            ("Start", #selector(ctxStart), nil),
            ("Pause", #selector(ctxPause), nil),
            ("Progress Details", #selector(ctxProgress), nil),
            ("Properties…", #selector(ctxProperties), nil),
            nil,
            ("Delete", #selector(ctxDelete), "\u{8}"),
        ] as [(String, Selector, String?)?] {
            if let item {
                let menuItem = NSMenuItem(title: item.0, action: item.1, keyEquivalent: item.2 ?? "")
                menuItem.target = self
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
            case #selector(ctxStart): item.isEnabled = presentation.canStart
            case #selector(ctxPause): item.isEnabled = presentation.canPause
            case #selector(ctxProgress): item.isEnabled = presentation.canShowProgress
            case #selector(ctxProperties), #selector(ctxDelete): item.isEnabled = true
            default: break
            }
        }
    }

    private func currentContextTaskID() -> Int64? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count else { return nil }
        return rows[row].taskID
    }

    @objc private func ctxOpen() { if let id = currentContextTaskID() { onContextAction?(.open, id) } }
    @objc private func ctxReveal() { if let id = currentContextTaskID() { onContextAction?(.reveal, id) } }
    @objc private func ctxStart() { if let id = currentContextTaskID() { onContextAction?(.start, id) } }
    @objc private func ctxPause() { if let id = currentContextTaskID() { onContextAction?(.pause, id) } }
    @objc private func ctxProgress() { if let id = currentContextTaskID() { onContextAction?(.progress, id) } }
    @objc private func ctxProperties() { if let id = currentContextTaskID() { onContextAction?(.properties, id) } }
    @objc private func ctxDelete() { if let id = currentContextTaskID() { onContextAction?(.delete, id) } }
}

private final class ContextMenuDelegate: NSObject, NSMenuDelegate {
    private let handler: (NSMenu) -> Void
    init(handler: @escaping (NSMenu) -> Void) { self.handler = handler }
    func menuNeedsUpdate(_ menu: NSMenu) { handler(menu) }
}

@MainActor
private final class TaskRowCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        progressLabel.alignment = .right
        metaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.alignment = .right
        metaLabel.lineBreakMode = .byTruncatingTail

        for view in [titleLabel, subtitleLabel, progressBar, progressLabel, metaLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressLabel.leadingAnchor, constant: -12),

            progressLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            progressLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: metaLabel.leadingAnchor, constant: -12),

            metaLabel.centerYAnchor.constraint(equalTo: subtitleLabel.centerYAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            metaLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),

            progressBar.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            progressBar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            progressBar.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: TaskRowPresentation) {
        titleLabel.stringValue = row.filename
        if let error = row.errorText, !error.isEmpty {
            subtitleLabel.stringValue = "\(row.statusTitle) · \(error)"
            subtitleLabel.textColor = .systemRed
        } else {
            let host = row.host.isEmpty ? row.statusTitle : "\(row.statusTitle) · \(row.host)"
            subtitleLabel.stringValue = host
            subtitleLabel.textColor = .secondaryLabelColor
        }
        progressBar.doubleValue = row.progressFraction
        progressLabel.stringValue = row.progressText
        metaLabel.stringValue = [row.sizeText, row.speedText, row.etaText]
            .filter { $0 != "—" }
            .joined(separator: "  ·  ")
        if metaLabel.stringValue.isEmpty {
            metaLabel.stringValue = row.sizeText
        }
    }
}

// MARK: - Inspector

@MainActor
private final class InspectorViewController: NSViewController {
    var onAction: ((TaskListContextAction) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Details")
    private let filenameLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(wrappingLabelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let speedLabel = NSTextField(labelWithString: "")
    private let etaLabel = NSTextField(labelWithString: "")
    private let connectionsLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let connectionsStack = NSStackView()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let progressButton = NSButton(title: "Progress…", target: nil, action: nil)
    private let propsButton = NSButton(title: "Properties…", target: nil, action: nil)
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "Select a download to inspect progress, connections, and file actions.")

    override func loadView() {
        view = NSView()
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        filenameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 12)
        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        etaLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        connectionsLabel.font = .systemFont(ofSize: 12, weight: .medium)
        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .left

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small

        connectionsStack.orientation = .vertical
        connectionsStack.alignment = .leading
        connectionsStack.spacing = 6

        for button in [openButton, revealButton, startButton, pauseButton, progressButton, propsButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        openButton.action = #selector(tapOpen)
        revealButton.action = #selector(tapReveal)
        startButton.action = #selector(tapStart)
        pauseButton.action = #selector(tapPause)
        progressButton.action = #selector(tapProgress)
        propsButton.action = #selector(tapProps)

        let actions = NSStackView(views: [openButton, revealButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        let actions2 = NSStackView(views: [startButton, pauseButton])
        actions2.orientation = .horizontal
        actions2.spacing = 8
        let actions3 = NSStackView(views: [progressButton, propsButton])
        actions3.orientation = .horizontal
        actions3.spacing = 8

        let stack = NSStackView(views: [
            titleLabel,
            placeholderLabel,
            filenameLabel,
            statusLabel,
            urlLabel,
            progressBar,
            sizeLabel,
            speedLabel,
            etaLabel,
            connectionsLabel,
            connectionsStack,
            actions,
            actions2,
            actions3,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            urlLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            filenameLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        update(row: nil)
    }

    func update(row: TaskRowPresentation?) {
        let hasSelection = row != nil
        placeholderLabel.isHidden = hasSelection
        for view in [filenameLabel, statusLabel, urlLabel, progressBar, sizeLabel, speedLabel, etaLabel, connectionsLabel, connectionsStack, openButton, revealButton, startButton, pauseButton, progressButton, propsButton] {
            view.isHidden = !hasSelection
        }
        guard let row else {
            connectionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            return
        }
        filenameLabel.stringValue = row.filename
        statusLabel.stringValue = row.statusTitle
        urlLabel.stringValue = row.urlText
        progressBar.doubleValue = row.progressFraction
        sizeLabel.stringValue = "Size  \(row.sizeText)"
        speedLabel.stringValue = "Speed  \(row.speedText)"
        etaLabel.stringValue = "ETA  \(row.etaText)"
        connectionsLabel.stringValue = "Connections  \(row.connectionsText)"
        openButton.isEnabled = row.canOpen
        revealButton.isEnabled = row.canShowInFinder
        startButton.isEnabled = row.canStart
        pauseButton.isEnabled = row.canPause
        progressButton.isEnabled = row.canShowProgress

        connectionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let segments = Array(row.segmentStates.prefix(8))
        if segments.isEmpty {
            let label = NSTextField(labelWithString: "No live connection data")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            connectionsStack.addArrangedSubview(label)
        } else {
            for segment in segments {
                let line = NSTextField(labelWithString: String(
                    format: "Conn %d · %@ · %@",
                    segment.id + 1,
                    TaskPresentationFormatting.percent(segment.fractionCompleted),
                    segment.isFinished ? "Done" : "Active"
                ))
                line.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                line.textColor = .secondaryLabelColor
                connectionsStack.addArrangedSubview(line)
            }
            if row.segmentStates.count > 8 {
                let more = NSTextField(labelWithString: "+\(row.segmentStates.count - 8) more in Progress…")
                more.font = .systemFont(ofSize: 11)
                more.textColor = .tertiaryLabelColor
                connectionsStack.addArrangedSubview(more)
            }
        }
    }

    @objc private func tapOpen() { onAction?(.open) }
    @objc private func tapReveal() { onAction?(.reveal) }
    @objc private func tapStart() { onAction?(.start) }
    @objc private func tapPause() { onAction?(.pause) }
    @objc private func tapProgress() { onAction?(.progress) }
    @objc private func tapProps() { onAction?(.properties) }
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
