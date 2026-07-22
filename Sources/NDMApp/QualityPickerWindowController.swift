import AppKit
import NDMCore

/// Probe an HLS URL before creating the task: when it's a master playlist with
/// several renditions, the person gets the design-suite picker instead of a
/// silent "highest bandwidth wins". Every failure path falls back to the old
/// behaviour — the picker must never make a download less likely to start.
enum HLSMasterProbe {
    struct Result {
        var options: [HLSQualityOption]
        var rawStreamCount: Int
        var masterURL: URL
    }

    static func probe(
        urlString: String,
        headers: [String: String] = [:],
        userAgent: String? = nil
    ) async -> Result? {
        guard let url = URL(string: urlString) else { return nil }
        guard let masterText = await fetchText(url, headers: headers, userAgent: userAgent) else {
            return nil
        }
        guard case .master(let master)? = try? HLSPlaylist.parse(masterText),
              master.variants.count >= 2 else {
            return nil
        }

        // Best-effort duration from the top variant → size estimates.
        var duration: Double?
        if let preferred = master.preferredVariant,
           let mediaURL = HLSPlaylist.resolveURL(preferred.uri, against: url),
           let mediaText = await fetchText(mediaURL, headers: headers, userAgent: userAgent),
           case .media(let media)? = try? HLSPlaylist.parse(mediaText) {
            duration = HLSQualityCatalog.totalDuration(of: media)
        }

        let options = HLSQualityCatalog.options(from: master, duration: duration)
        guard options.count >= 2 else { return nil }
        return Result(options: options, rawStreamCount: master.variants.count, masterURL: url)
    }

    private static func fetchText(
        _ url: URL,
        headers: [String: String],
        userAgent: String?
    ) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let userAgent { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count < 4 << 20 else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// The design-suite quality sheet: deduped renditions, recommended pick
/// preselected, output format already decided (MP4, lossless).
@MainActor
final class QualityPickerWindowController: NSWindowController, NSWindowDelegate {
    enum Choice {
        case download(HLSQualityOption)
        case cancel
    }

    private let options: [HLSQualityOption]
    private let pageTitle: String
    private let summaryText: String
    private var onChoice: ((Choice) -> Void)?
    private var selectedIndex = 0
    private var optionButtons: [NSButton] = []
    private var downloadButton: NSButton!

    init(
        title: String,
        host: String,
        rawStreamCount: Int,
        options: [HLSQualityOption],
        onChoice: @escaping (Choice) -> Void
    ) {
        self.options = options
        self.pageTitle = title.isEmpty ? L10n.chooseQuality : title
        self.summaryText = L10n.qualityStreamsSummary(
            host: host,
            found: rawStreamCount,
            kept: options.count
        )
        self.onChoice = onChoice
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.videoFound
        NDMChrome.applyWindowChrome(window)
        super.init(window: window)
        buildUI()
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Keeps the controller alive while its window is up.
    private static var active: QualityPickerWindowController?

    /// Close an HLS picker still waiting on a previous browser capture so the
    /// newest "download with NDM" replaces it.
    static func dismissActive() {
        active?.window?.close()
    }

    /// Show the picker and await the person's choice.
    static func choose(probe: HLSMasterProbe.Result, title: String) async -> Choice {
        await withCheckedContinuation { continuation in
            let wc = QualityPickerWindowController(
                title: title,
                host: probe.masterURL.host ?? "",
                rawStreamCount: probe.rawStreamCount,
                options: probe.options
            ) { choice in
                Self.active = nil
                continuation.resume(returning: choice)
            }
            Self.active = wc
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let titleLabel = NSTextField(wrappingLabelWithString: pageTitle)
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        let subLabel = NSTextField(wrappingLabelWithString: summaryText)
        subLabel.font = .systemFont(ofSize: 12)
        subLabel.textColor = .secondaryLabelColor

        let optionsStack = NSStackView()
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 8
        for (index, option) in options.enumerated() {
            let row = makeOptionRow(option, index: index)
            optionButtons.append(row)
            optionsStack.addArrangedSubview(row)
        }

        let cancel = NSButton(title: L10n.cancel, target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"

        downloadButton = NSButton(title: "", target: self, action: #selector(downloadClicked))
        downloadButton.bezelStyle = .rounded
        downloadButton.controlSize = .large
        downloadButton.keyEquivalent = "\r"
        if #available(macOS 11.0, *) {
            downloadButton.bezelColor = NDMChrome.accent
        }

        let actions = NSStackView(views: [NSView(), cancel, downloadButton])
        actions.orientation = .horizontal
        actions.spacing = 10

        let stack = NSStackView(views: [titleLabel, subLabel, optionsStack, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: titleLabel)
        stack.setCustomSpacing(16, after: subLabel)
        stack.setCustomSpacing(14, after: optionsStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            optionsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        applySelection(0)
    }

    private func makeOptionRow(_ option: HLSQualityOption, index: Int) -> NSButton {
        var title = option.label
        if index == 0 {
            title += "  ·  \(L10n.recommended)"
        }
        var subtitleParts: [String] = []
        if let size = option.estimatedSizeText { subtitleParts.append(size) }
        if !option.detail.isEmpty { subtitleParts.append(option.detail) }

        let button = NSButton(radioButtonWithTitle: "", target: self, action: #selector(optionClicked(_:)))
        button.tag = index
        button.imagePosition = .imageLeft
        let text = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if !subtitleParts.isEmpty {
            text.append(NSAttributedString(
                string: "\n" + subtitleParts.joined(separator: " · "),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        button.attributedTitle = text
        // Quiet Finder qopt: soft surface, accent ring when selected (applied in applySelection).
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        button.layer?.borderWidth = 1
        return button
    }

    private func applySelection(_ index: Int) {
        selectedIndex = index
        for button in optionButtons {
            let on = button.tag == index
            button.state = on ? .on : .off
            button.layer?.backgroundColor = (on
                ? NDMChrome.accent.withAlphaComponent(0.10)
                : NDMChrome.dockFill
            ).cgColor
            button.layer?.borderColor = (on
                ? NDMChrome.accent.withAlphaComponent(0.55)
                : NDMChrome.hairline
            ).cgColor
        }
        downloadButton.title = L10n.downloadQuality(options[index].label)
    }

    @objc private func optionClicked(_ sender: NSButton) {
        applySelection(sender.tag)
    }

    @objc private func downloadClicked() {
        let choice = options[selectedIndex]
        let callback = onChoice
        onChoice = nil
        window?.close()
        callback?(.download(choice))
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        let callback = onChoice
        onChoice = nil
        callback?(.cancel)
    }
}
