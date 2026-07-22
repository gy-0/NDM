import AppKit
import NDMCore
import NDMEngine

/// Clarity picker for page-level media (yt-dlp).
/// Presented as a sheet on the main window so it cannot slip behind chrome.
@MainActor
final class YtDlpQualityPickerWindowController: NSWindowController, NSWindowDelegate {
    enum Scope: Equatable {
        case single
        case collection(YtDlpCollectionProbe)
    }

    enum Choice {
        case download(YtDlpFormat, YtDlpDownloadOptions, Scope)
        case cancel
    }

    private let probe: YtDlpProbe
    private let pageHost: String
    private let cookieSource: YtDlpCookieSource?
    private let collection: YtDlpCollectionProbe?
    private let destinationDirectory: URL
    private let availableBytes: Int64?
    private let rememberedPreference: SiteMediaPreference?
    private var onChoice: ((Choice) -> Void)?
    private var selectedIndex = 0
    private var optionRows: [QualityOptionRow] = []
    private var downloadButton: NSButton!
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let subtitleCheckbox = NSButton(checkboxWithTitle: L10n.ytdlpDownloadSubtitles, target: nil, action: nil)
    private let subtitlePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scopeSelector = NSSegmentedControl(
        labels: ["", ""],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let storageIcon = NSImageView()
    private let storageLabel = NSTextField(wrappingLabelWithString: "")
    private let thumbnailView = NSImageView()
    private var didFinish = false

    private static var active: YtDlpQualityPickerWindowController?

    /// Close a picker still waiting on a previous browser capture. The newest
    /// "download with NDM" supersedes the pending one instead of stacking a
    /// second picker or being silently dropped.
    static func dismissActive() {
        active?.finish(.cancel)
    }

    private var formats: [YtDlpFormat] { probe.formats }

    init(
        host: String,
        probe: YtDlpProbe,
        collection: YtDlpCollectionProbe?,
        cookieSource: YtDlpCookieSource?,
        destinationDirectory: URL,
        onChoice: @escaping (Choice) -> Void
    ) {
        self.probe = probe
        self.pageHost = host
        self.collection = collection
        self.cookieSource = cookieSource
        self.destinationDirectory = destinationDirectory
        self.availableBytes = VolumeCapacity.availableBytes(at: destinationDirectory)
        self.rememberedPreference = SiteMediaPreferenceStore.load(for: host)
        self.onChoice = onChoice
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: collection == nil ? 620 : 698),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.videoFound
        window.representedURL = nil
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = false
        NDMChrome.applySheetChrome(window)
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func choose(
        url: String,
        probe: YtDlpProbe,
        collection: YtDlpCollectionProbe? = nil,
        cookieSource: YtDlpCookieSource? = nil,
        destinationDirectory: URL,
        parentWindow: NSWindow?
    ) async -> Choice {
        let host = URL(string: url)?.host ?? ""
        return await withCheckedContinuation { continuation in
            let wc = YtDlpQualityPickerWindowController(
                host: host,
                probe: probe,
                collection: collection,
                cookieSource: cookieSource,
                destinationDirectory: destinationDirectory
            ) { choice in
                Self.active = nil
                continuation.resume(returning: choice)
            }
            Self.active = wc
            guard let sheet = wc.window else {
                continuation.resume(returning: .cancel)
                return
            }
            if let parent = parentWindow {
                parent.beginSheet(sheet) { _ in }
            } else {
                sheet.center()
                sheet.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let header = makeHeader()

        let headline = probe.title.isEmpty ? L10n.advancedVideo : probe.title
        let titleLabel = NSTextField(wrappingLabelWithString: headline)
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.truncatesLastVisibleLine = true

        let durationText = probe.durationSeconds.map { L10n.ytdlpDuration($0) }
        let subLabel = NSTextField(wrappingLabelWithString: L10n.ytdlpPickerSummary(
            host: pageHost,
            count: formats.count,
            durationText: durationText
        ))
        subLabel.font = .systemFont(ofSize: 12.5)
        subLabel.textColor = .secondaryLabelColor

        let optionsStack = NSStackView()
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 6
        for (index, format) in formats.enumerated() {
            let row = QualityOptionRow(format: format, index: index, recommended: index == 0)
            row.onSelect = { [weak self] i in self?.applySelection(i) }
            optionRows.append(row)
            optionsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: optionsStack.widthAnchor).isActive = true
        }

        let cancel = NSButton(title: L10n.cancel, target: self, action: #selector(cancelClicked))
        NDMChrome.styleGhostButton(cancel)
        cancel.keyEquivalent = "\u{1b}"

        downloadButton = NSButton(title: "", target: self, action: #selector(downloadClicked))
        NDMChrome.styleMainButton(downloadButton)
        downloadButton.keyEquivalent = "\r"

        let actions = NSStackView(views: [NSView(), cancel, downloadButton])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.alignment = .centerY

        let mediaOptions = makeMediaOptions()
        let storageStatus = makeStorageStatus()
        let headerText = NSStackView(views: [titleLabel, subLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4
        titleLabel.widthAnchor.constraint(equalTo: headerText.widthAnchor).isActive = true
        subLabel.widthAnchor.constraint(equalTo: headerText.widthAnchor).isActive = true
        header.addArrangedSubview(headerText)

        var arranged: [NSView] = [header]
        let collectionScope = collection == nil ? nil : makeCollectionScope()
        if let collectionScope { arranged.append(collectionScope) }
        arranged.append(contentsOf: [optionsStack, storageStatus, mediaOptions, actions])
        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(14, after: header)
        stack.setCustomSpacing(14, after: optionsStack)
        stack.setCustomSpacing(12, after: storageStatus)
        stack.setCustomSpacing(16, after: mediaOptions)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            optionsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            storageStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            mediaOptions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancel.heightAnchor.constraint(equalToConstant: 30),
            downloadButton.heightAnchor.constraint(equalToConstant: 30),
            downloadButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        collectionScope?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        restoreRememberedPreference()
        loadThumbnail()
    }

    private func makeHeader() -> NSStackView {
        thumbnailView.imageScaling = .scaleAxesIndependently
        thumbnailView.image = NDMChrome.symbol("play.rectangle.fill", pointSize: 28, weight: .medium)
        thumbnailView.contentTintColor = .tertiaryLabelColor
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 10
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbnailView.widthAnchor.constraint(equalToConstant: 136),
            thumbnailView.heightAnchor.constraint(equalToConstant: 82),
        ])

        let row = NSStackView(views: [thumbnailView])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        return row
    }

    private func loadThumbnail() {
        guard let raw = probe.thumbnailURL,
              let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= 12 * 1_024 * 1_024,
                  let image = NSImage(data: data), image.isValid,
                  !Task.isCancelled else { return }
            self?.thumbnailView.contentTintColor = nil
            self?.thumbnailView.imageScaling = .scaleProportionallyUpOrDown
            self?.thumbnailView.alphaValue = 0.3
            self?.thumbnailView.image = image
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.3
            NSAnimationContext.current.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self?.thumbnailView.animator().alphaValue = 1
            NSAnimationContext.endGrouping()
        }
    }

    private func restoreRememberedPreference() {
        guard let preference = rememberedPreference else {
            selectFirstUseSubtitleLanguage()
            applySelection(0)
            return
        }
        let resolution = preference.resolved(
            formatHeights: formats.map(\.height),
            subtitleCodes: probe.subtitleTracks.map(\.code)
        )
        selectedIndex = formats.indices.contains(resolution.selectedFormatIndex)
            ? resolution.selectedFormatIndex
            : 0
        formatPopup.selectItem(at: resolution.container == .compactMKV ? 1 : 0)

        if let subtitleLanguage = resolution.subtitleLanguage,
           probe.subtitleTracks.contains(where: {
               $0.code == subtitleLanguage
           }) {
            subtitleCheckbox.state = .on
            selectSubtitle(code: subtitleLanguage)
        } else {
            subtitleCheckbox.state = .off
            selectFirstUseSubtitleLanguage()
        }
        subtitlePopup.isEnabled = subtitleCheckbox.state == .on

        let container = formatPopup.indexOfSelectedItem == 1 ? "MKV" : "MP4"
        for row in optionRows { row.setContainer(container) }
        refreshOptionSizes()
        applySelection(selectedIndex)
    }

    private func selectFirstUseSubtitleLanguage() {
        guard let index = YtDlpTool.preferredSubtitleIndex(in: probe.subtitleTracks) else { return }
        selectSubtitle(code: probe.subtitleTracks[index].code)
    }

    private func selectSubtitle(code: String) {
        guard let item = subtitlePopup.itemArray.first(where: {
            ($0.representedObject as? String) == code
        }) else { return }
        subtitlePopup.select(item)
    }

    private func makeStorageStatus() -> NSView {
        storageIcon.imageScaling = .scaleProportionallyDown
        storageIcon.translatesAutoresizingMaskIntoConstraints = false
        storageIcon.setContentHuggingPriority(.required, for: .horizontal)

        storageLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        storageLabel.maximumNumberOfLines = 2
        storageLabel.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [storageIcon, storageLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        NSLayoutConstraint.activate([
            storageIcon.widthAnchor.constraint(equalToConstant: 16),
            storageIcon.heightAnchor.constraint(equalToConstant: 16),
            storageLabel.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -26),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        return row
    }

    private func makeCollectionScope() -> NSView {
        guard let collection else { return NSView() }
        scopeSelector.segmentStyle = .rounded
        scopeSelector.setLabel(L10n.ytdlpCurrentVideo, forSegment: 0)
        scopeSelector.setLabel(
            L10n.ytdlpEntireCollection(
                collection.items.count,
                isTruncated: collection.isTruncated
            ),
            forSegment: 1
        )
        scopeSelector.selectedSegment = 0
        scopeSelector.target = self
        scopeSelector.action = #selector(scopeChanged)
        scopeSelector.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: L10n.ytdlpCollectionQueueHint)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [scopeSelector, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        scopeSelector.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scopeSelector.heightAnchor.constraint(equalToConstant: 28).isActive = true
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeMediaOptions() -> NSView {
        let formatLabel = NSTextField(labelWithString: L10n.ytdlpFileFormat)
        formatLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        formatPopup.addItems(withTitles: [
            L10n.ytdlpCompatibleMP4,
            L10n.ytdlpCompactMKV,
        ])
        formatPopup.target = self
        formatPopup.action = #selector(mediaOptionChanged)
        formatPopup.selectItem(at: 0)

        let formatRow = NSStackView(views: [formatLabel, NSView(), formatPopup])
        formatRow.orientation = .horizontal
        formatRow.alignment = .centerY
        formatRow.spacing = 10

        let formatNote = NSTextField(wrappingLabelWithString: L10n.ytdlpFormatHint)
        formatNote.font = .systemFont(ofSize: 11)
        formatNote.textColor = .secondaryLabelColor

        subtitleCheckbox.target = self
        subtitleCheckbox.action = #selector(mediaOptionChanged)
        subtitleCheckbox.state = .off

        subtitlePopup.removeAllItems()
        for track in probe.subtitleTracks {
            let suffix = track.isAutomatic ? L10n.ytdlpAutoSubtitleSuffix : ""
            subtitlePopup.addItem(withTitle: track.displayName + suffix)
            subtitlePopup.lastItem?.representedObject = track.code
        }
        subtitlePopup.isEnabled = false
        subtitlePopup.target = self
        subtitlePopup.action = #selector(mediaOptionChanged)
        if YtDlpTool.preferredSubtitleIndex(in: probe.subtitleTracks) == nil,
           !probe.subtitleTracks.isEmpty {
            subtitlePopup.insertItem(
                withTitle: L10n.t("Choose a language", "选择字幕语言"),
                at: 0
            )
            subtitlePopup.item(at: 0)?.representedObject = nil
        }
        selectFirstUseSubtitleLanguage()

        if probe.subtitleTracks.isEmpty {
            subtitleCheckbox.title = L10n.ytdlpNoSubtitlesFound
            subtitleCheckbox.isEnabled = false
            subtitlePopup.isHidden = true
        }

        let subtitleRow = NSStackView(views: [subtitleCheckbox, NSView(), subtitlePopup])
        subtitleRow.orientation = .horizontal
        subtitleRow.alignment = .centerY
        subtitleRow.spacing = 10

        let subtitleNote = NSTextField(wrappingLabelWithString: L10n.ytdlpSubtitleHint)
        subtitleNote.font = .systemFont(ofSize: 11)
        subtitleNote.textColor = .secondaryLabelColor

        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [formatRow, formatNote, divider, subtitleRow, subtitleNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: formatNote)
        stack.setCustomSpacing(10, after: divider)

        for row in [formatRow, formatNote, divider, subtitleRow, subtitleNote] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let card = NSBox()
        card.boxType = .custom
        card.borderWidth = 1
        card.cornerRadius = 10
        card.fillColor = .controlBackgroundColor
        card.borderColor = NDMChrome.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        return card
    }

    private func applySelection(_ index: Int) {
        selectedIndex = index
        for row in optionRows {
            row.setSelected(row.index == index)
        }
        refreshDownloadButton()
        refreshStorageStatus()
        NDMChrome.styleMainButton(downloadButton)
    }

    @objc private func mediaOptionChanged() {
        subtitlePopup.isEnabled = subtitleCheckbox.state == .on
        let container = formatPopup.indexOfSelectedItem == 1 ? "MKV" : "MP4"
        for row in optionRows { row.setContainer(container) }
        refreshOptionSizes()
        refreshDownloadButton()
        refreshStorageStatus()
    }

    @objc private func scopeChanged() {
        refreshOptionSizes()
        refreshDownloadButton()
        refreshStorageStatus()
    }

    private func refreshDownloadButton() {
        guard formats.indices.contains(selectedIndex) else { return }
        let container = formatPopup.indexOfSelectedItem == 1 ? "MKV" : "MP4"
        if let collection, scopeSelector.selectedSegment == 1 {
            downloadButton.title = L10n.downloadCollection(
                collection.items.count,
                quality: "\(formats[selectedIndex].label) · \(container)"
            )
        } else {
            downloadButton.title = L10n.downloadQuality(formats[selectedIndex].label, container: container)
        }
        NDMChrome.styleMainButton(downloadButton)
    }

    private var collectionIsSelected: Bool {
        collection != nil && scopeSelector.selectedSegment == 1
    }

    private var selectedContainer: YtDlpContainerPreference {
        formatPopup.indexOfSelectedItem == 1 ? .compactMKV : .compatibleMP4
    }

    private func storageBudget(for format: YtDlpFormat) -> StorageBudget {
        StorageBudget.media(
            sampleFinalBytes: format.estimatedBytes(for: selectedContainer),
            sampleComponentBytes: format.estimatedComponentBytes(for: selectedContainer),
            sampleDurationSeconds: probe.durationSeconds,
            collectionDurations: collectionIsSelected
                ? collection?.items.map(\.durationSeconds)
                : nil
        )
    }

    private func refreshOptionSizes() {
        for (index, row) in optionRows.enumerated() where formats.indices.contains(index) {
            let format = formats[index]
            if collectionIsSelected,
               let bytes = storageBudget(for: format).finalBytes {
                row.setSizeText("≈ " + TaskPresentationFormatting.byteCount(bytes))
            } else {
                row.setSizeText(format.sizeText(for: selectedContainer) ?? "—")
            }
        }
    }

    private func refreshStorageStatus() {
        guard formats.indices.contains(selectedIndex) else { return }
        let budget = storageBudget(for: formats[selectedIndex])
        let confidence = StorageConfidence(
            budget: budget,
            availableBytes: availableBytes
        )
        let symbol: String
        let color: NSColor
        switch confidence.level {
        case .comfortable:
            symbol = "checkmark.circle.fill"
            color = .systemGreen
            if let final = budget.finalBytes, let availableBytes {
                storageLabel.stringValue = L10n.storageComfortable(
                    finalBytes: final,
                    availableBytes: availableBytes,
                    isCollection: budget.isCollectionEstimate
                )
            }
        case .tight:
            symbol = "exclamationmark.circle.fill"
            color = .systemOrange
            if let final = budget.finalBytes {
                storageLabel.stringValue = L10n.storageTight(
                    finalBytes: final,
                    projectedFreeBytes: confidence.projectedFreeBytes ?? 0,
                    isCollection: budget.isCollectionEstimate
                )
            }
        case .insufficient:
            symbol = "externaldrive.badge.exclamationmark"
            color = .systemRed
            storageLabel.stringValue = L10n.storageInsufficient(
                shortfallBytes: confidence.shortfallBytes
            )
        case .unknown:
            symbol = "externaldrive"
            color = .secondaryLabelColor
            storageLabel.stringValue = L10n.storageUnknown(
                availableBytes: availableBytes
            )
        }
        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: storageLabel.stringValue
        )
        image?.isTemplate = true
        storageIcon.image = image
        storageIcon.contentTintColor = color
        storageLabel.textColor = confidence.level == .insufficient
            ? .systemRed
            : (confidence.level == .tight ? .systemOrange : .secondaryLabelColor)
        let subtitleReady = subtitleCheckbox.state != .on
            || subtitlePopup.selectedItem?.representedObject is String
        downloadButton.isEnabled = confidence.level != .insufficient && subtitleReady
        if confidence.level == .insufficient {
            downloadButton.toolTip = storageLabel.stringValue
        } else if !subtitleReady {
            downloadButton.toolTip = L10n.t(
                "Choose a subtitle language first",
                "请先选择字幕语言"
            )
        } else {
            downloadButton.toolTip = nil
        }
    }

    private var selectedOptions: YtDlpDownloadOptions {
        let container: YtDlpContainerPreference = formatPopup.indexOfSelectedItem == 1
            ? .compactMKV
            : .compatibleMP4
        let subtitleLanguage = subtitleCheckbox.state == .on
            ? (subtitlePopup.selectedItem?.representedObject as? String)
            : nil
        return YtDlpDownloadOptions(
            container: container,
            subtitleLanguage: subtitleLanguage,
            cookieSource: cookieSource
        )
    }

    @objc private func downloadClicked() {
        guard formats.indices.contains(selectedIndex) else { return }
        let proRequirements = ProAccessPolicy.mediaRequirements(
            height: formats[selectedIndex].height,
            collectionItemCount: collectionIsSelected ? collection?.items.count : nil,
            includesSubtitles: subtitleCheckbox.state == .on
        )
        if !LicenseStore.isPro, !proRequirements.isEmpty {
            UpgradeWindowController.present(
                features: proRequirements,
                parentWindow: window
            ) { [weak self] in
                self?.downloadClicked()
            }
            return
        }

        let scope: Scope
        if let collection, scopeSelector.selectedSegment == 1 {
            scope = .collection(collection)
        } else {
            scope = .single
        }
        let options = selectedOptions
        SiteMediaPreferenceStore.save(
            SiteMediaPreference(
                qualityHeight: formats[selectedIndex].height,
                container: options.container == .compactMKV ? .compactMKV : .compatibleMP4,
                subtitleLanguage: options.subtitleLanguage
            ),
            for: pageHost
        )
        finish(.download(formats[selectedIndex], options, scope))
    }

    @objc private func cancelClicked() {
        finish(.cancel)
    }

    func windowWillClose(_ notification: Notification) {
        finish(.cancel)
    }

    private func finish(_ choice: Choice) {
        guard !didFinish else { return }
        didFinish = true
        let callback = onChoice
        onChoice = nil
        window?.delegate = nil
        if let sheet = window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            window?.close()
        }
        callback?(choice)
    }
}

// MARK: - Option row (Design Suite `.qopt`)

private final class QualityOptionRow: NSView {
    var onSelect: ((Int) -> Void)?
    let index: Int

    private let radio = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let formatHeight: Int
    private let baseSizeText: String

    init(format: YtDlpFormat, index: Int, recommended: Bool) {
        self.index = index
        self.formatHeight = format.height
        self.baseSizeText = format.sizeText ?? "—"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        radio.wantsLayer = true
        radio.layer?.cornerRadius = 7.5
        radio.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        if recommended {
            let attr = NSMutableAttributedString(
                string: format.label + "  ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            attr.append(NSAttributedString(
                string: L10n.recommended,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: NDMChrome.accent,
                ]
            ))
            nameLabel.attributedStringValue = attr
        } else {
            nameLabel.stringValue = format.label
        }

        subLabel.stringValue = L10n.ytdlpQualityDetail(
            height: format.height,
            container: format.containerHint
        )
        subLabel.font = .systemFont(ofSize: 11.5)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail

        trailingLabel.stringValue = baseSizeText
        trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        trailingLabel.textColor = .labelColor
        trailingLabel.alignment = .right
        trailingLabel.toolTip = format.sizeText == nil
            ? L10n.t("Size unknown until download", "大小需下载后才准确")
            : L10n.t("Approximate size", "约为估算大小")

        for v in [radio, nameLabel, subLabel, trailingLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            radio.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            radio.centerYAnchor.constraint(equalTo: centerYAnchor),
            radio.widthAnchor.constraint(equalToConstant: 15),
            radio.heightAnchor.constraint(equalToConstant: 15),

            nameLabel.leadingAnchor.constraint(equalTo: radio.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingLabel.leadingAnchor, constant: -10),

            subLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            subLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingLabel.leadingAnchor, constant: -10),

            trailingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
        setSelected(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ on: Bool) {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = (on
            ? NDMChrome.accent.withAlphaComponent(0.65)
            : NDMChrome.hairline
        ).cgColor
        layer?.borderWidth = on ? 1.5 : 1

        radio.layer?.borderWidth = on ? 4.5 : 1.5
        radio.layer?.borderColor = (on ? NDMChrome.accent : NSColor.tertiaryLabelColor).cgColor
        radio.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func setContainer(_ container: String) {
        subLabel.stringValue = L10n.ytdlpQualityDetail(height: formatHeight, container: container)
    }

    func setSizeText(_ text: String?) {
        trailingLabel.stringValue = text ?? baseSizeText
        trailingLabel.toolTip = trailingLabel.stringValue == "—"
            ? L10n.t("Size unknown until download", "大小需下载后才准确")
            : L10n.t("Approximate final size", "预计最终大小")
    }

    @objc private func clicked() {
        onSelect?(index)
    }
}
