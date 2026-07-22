import AppKit
import NDMCore
import NDMEngine

/// A quiet disclosure for the real files delivered by one completed task.
/// Collapsed by default so the main result remains the hero.
@MainActor
final class CompletionStackView: NSView {
    var onExpansionChanged: ((Bool) -> Void)?

    private let shell = ChromeBox(
        fill: .clear
    )
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let summaryLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private let contentStack = NSStackView()
    private var result: CompletionStack?
    private var expanded = false
    private var contentScale: CGFloat = 1

    /// Extra vertical space needed when the disclosure opens. Each artifact
    /// row resolves to 40pt, with a one-pixel divider between adjacent rows.
    var expansionHeight: CGFloat {
        guard let count = result?.artifacts.count, count > 0 else { return 0 }
        return CGFloat(count) * rowHeight
            + CGFloat(max(0, count - 1))
            + 8 * layoutScale
    }

    private var layoutScale: CGFloat {
        1 + (contentScale - 1) * 0.38
    }

    private var rowHeight: CGFloat {
        40 * layoutScale
    }

    override var intrinsicContentSize: NSSize {
        guard !isHidden else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        let collapsedHeight = 30 * layoutScale
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: collapsedHeight + (expanded ? expansionHeight : 0)
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        toggleButton.target = self
        toggleButton.action = #selector(toggleExpanded)
        toggleButton.isBordered = false
        toggleButton.bezelStyle = .inline
        toggleButton.imagePosition = .imageLeading
        toggleButton.imageHugsTitle = true
        toggleButton.font = .systemFont(ofSize: 12.5, weight: .semibold)
        toggleButton.contentTintColor = .labelColor
        toggleButton.setContentHuggingPriority(.required, for: .horizontal)

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .right
        summaryLabel.lineBreakMode = .byTruncatingHead
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [toggleButton, summaryLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.distribution = .fill

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.isHidden = true

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(rowsStack)

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.addSubview(contentStack)
        addSubview(shell)
        NSLayoutConstraint.activate([
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: shell.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            rowsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
        isHidden = true
        updateDisclosure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ result: CompletionStack?) {
        self.result = result
        setExpanded(false, notify: false)
        rebuildRows()
        // A single main file is already represented by the completion header.
        // The stack earns its space only when a real sidecar exists.
        isHidden = (result?.sidecars.isEmpty ?? true)
        invalidateIntrinsicContentSize()
        relocalize()
    }

    func relocalize() {
        toggleButton.title = L10n.completionFilesTitle
        if let result {
            var details = [L10n.completionFileCount(result.artifacts.count)]
            let subtitleCount = result.artifacts.filter { $0.kind == .subtitle }.count
            if subtitleCount > 0 {
                details.append(L10n.completionSubtitleCount(subtitleCount))
            }
            summaryLabel.stringValue = details.joined(separator: " · ")
            rebuildRows()
        } else {
            summaryLabel.stringValue = ""
        }
        updateDisclosure()
    }

    func setContentScale(_ scale: CGFloat) {
        contentScale = min(InterfaceScale.maximum, max(InterfaceScale.minimum, scale))
        toggleButton.font = .systemFont(ofSize: 12.5 * contentScale, weight: .semibold)
        summaryLabel.font = .systemFont(ofSize: 11 * contentScale)
        contentStack.spacing = 8 * layoutScale
        contentStack.edgeInsets = NSEdgeInsets(
            top: 6 * layoutScale,
            left: 0,
            bottom: 6 * layoutScale,
            right: 0
        )
        rebuildRows()
        updateDisclosure()
        invalidateIntrinsicContentSize()
    }

    @objc private func toggleExpanded() {
        setExpanded(!expanded, notify: true)
    }

    private func setExpanded(_ value: Bool, notify: Bool) {
        expanded = value
        rowsStack.isHidden = !value
        invalidateIntrinsicContentSize()
        updateDisclosure()
        needsLayout = true
        window?.contentView?.layoutSubtreeIfNeeded()
        if notify { onExpansionChanged?(value) }
    }

    private func updateDisclosure() {
        toggleButton.image = NDMChrome.symbol(
            expanded ? "chevron.down" : "chevron.right",
            pointSize: 10 * contentScale,
            weight: .semibold
        )
        toggleButton.toolTip = expanded ? L10n.completionHideFiles : L10n.completionShowFiles
    }

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let result else { return }
        for (index, artifact) in result.artifacts.enumerated() {
            let row = makeRow(artifact)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if index < result.artifacts.count - 1 {
                let separator = ChromeBox(fill: NDMChrome.hairline)
                separator.translatesAutoresizingMaskIntoConstraints = false
                rowsStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
        }
    }

    private func makeRow(_ artifact: CompletionArtifact) -> NSView {
        let icon = NSImageView()
        icon.image = NDMChrome.symbol(symbol(for: artifact.kind), pointSize: 16, weight: .medium)
        icon.contentTintColor = tint(for: artifact.kind)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: artifact.url.lastPathComponent)
        name.font = .systemFont(ofSize: 11.5 * contentScale, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = artifact.url.lastPathComponent
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detail = NSTextField(labelWithString: artifactDetail(artifact))
        detail.font = .systemFont(ofSize: 10.5 * contentScale)
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actions = ArtifactActionsButton(url: artifact.url)
        actions.target = self
        actions.action = #selector(showArtifactActions(_:))

        let row = NSStackView(views: [icon, labels, actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 7, left: 2, bottom: 7, right: 2)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            actions.widthAnchor.constraint(equalToConstant: 28),
            actions.heightAnchor.constraint(equalToConstant: 28),
        ])
        return row
    }

    private func artifactDetail(_ artifact: CompletionArtifact) -> String {
        let kind: String
        switch artifact.kind {
        case .primary: kind = L10n.completionMainFile
        case .subtitle: kind = L10n.completionSubtitleReady
        case .cover: kind = L10n.completionCover
        case .audio: kind = L10n.completionAudio
        case .metadata: kind = L10n.completionMetadata
        case .other: kind = L10n.other
        }
        guard artifact.byteCount > 0 else { return kind }
        return "\(kind) · \(TaskPresentationFormatting.byteCount(artifact.byteCount))"
    }

    private func symbol(for kind: CompletionArtifact.Kind) -> String {
        switch kind {
        case .primary: return "play.rectangle.fill"
        case .subtitle: return "captions.bubble.fill"
        case .cover: return "photo.fill"
        case .audio: return "waveform"
        case .metadata: return "doc.text.fill"
        case .other: return "doc.fill"
        }
    }

    private func tint(for kind: CompletionArtifact.Kind) -> NSColor {
        switch kind {
        case .primary: return NDMChrome.accent
        case .subtitle: return .systemTeal
        case .cover: return .systemTeal
        case .audio: return .systemPink
        case .metadata, .other: return .secondaryLabelColor
        }
    }

    @objc private func showArtifactActions(_ sender: ArtifactActionsButton) {
        let menu = NSMenu()
        let open = NSMenuItem(title: L10n.open, action: #selector(openArtifact(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = sender.fileURL
        menu.addItem(open)

        let reveal = NSMenuItem(title: L10n.showInFinder, action: #selector(revealArtifact(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = sender.fileURL
        menu.addItem(reveal)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 3), in: sender)
    }

    @objc private func openArtifact(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealArtifact(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private final class ArtifactActionsButton: NSButton {
    let fileURL: URL

    init(url: URL) {
        fileURL = url
        super.init(frame: .zero)
        image = NDMChrome.symbol("ellipsis", pointSize: 12, weight: .semibold)
        bezelStyle = .inline
        isBordered = false
        contentTintColor = .secondaryLabelColor
        focusRingType = .default
        toolTip = L10n.moreActions
        setAccessibilityLabel(L10n.t(
            "More actions for \(url.lastPathComponent)",
            "对「\(url.lastPathComponent)」执行更多操作"
        ))
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
