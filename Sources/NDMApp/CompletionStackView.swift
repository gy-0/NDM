import AppKit
import NDMCore
import NDMEngine

/// A quiet disclosure for the real files delivered by one completed task.
/// Collapsed by default so the main result remains the hero.
@MainActor
final class CompletionStackView: NSView {
    var onExpansionChanged: ((Bool) -> Void)?

    private let shell = ChromeBox(
        fill: NDMChrome.dockFill,
        borderColor: NDMChrome.hairline,
        cornerRadius: 9,
        borderWidth: 1
    )
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let summaryLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private let contentStack = NSStackView()
    private var result: CompletionStack?
    private var expanded = false

    /// Extra vertical space needed when the disclosure opens. Each artifact
    /// row resolves to 40pt, with a one-pixel divider between adjacent rows.
    var expansionHeight: CGFloat {
        guard let count = result?.artifacts.count, count > 0 else { return 0 }
        return CGFloat(count * 40 + max(0, count - 1))
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
        contentStack.edgeInsets = NSEdgeInsets(top: 9, left: 11, bottom: 9, right: 11)
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
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -22),
            rowsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -22),
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

    @objc private func toggleExpanded() {
        setExpanded(!expanded, notify: true)
    }

    private func setExpanded(_ value: Bool, notify: Bool) {
        expanded = value
        rowsStack.isHidden = !value
        updateDisclosure()
        needsLayout = true
        window?.contentView?.layoutSubtreeIfNeeded()
        if notify { onExpansionChanged?(value) }
    }

    private func updateDisclosure() {
        toggleButton.image = NDMChrome.symbol(
            expanded ? "chevron.down" : "chevron.right",
            pointSize: 10,
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
        name.font = .systemFont(ofSize: 11.5, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = artifact.url.lastPathComponent
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detail = NSTextField(labelWithString: artifactDetail(artifact))
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let reveal = ArtifactRevealButton(url: artifact.url)
        reveal.target = self
        reveal.action = #selector(revealArtifact(_:))

        let row = NSStackView(views: [icon, labels, reveal])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 7, left: 2, bottom: 7, right: 2)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            reveal.widthAnchor.constraint(equalToConstant: 28),
            reveal.heightAnchor.constraint(equalToConstant: 28),
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
        case .subtitle: return .systemGreen
        case .cover: return .systemTeal
        case .audio: return .systemPink
        case .metadata, .other: return .secondaryLabelColor
        }
    }

    @objc private func revealArtifact(_ sender: ArtifactRevealButton) {
        NSWorkspace.shared.activateFileViewerSelecting([sender.fileURL])
    }
}

private final class ArtifactRevealButton: NSButton {
    let fileURL: URL

    init(url: URL) {
        fileURL = url
        super.init(frame: .zero)
        image = NDMChrome.symbol("folder", pointSize: 13, weight: .medium)
        bezelStyle = .inline
        isBordered = false
        contentTintColor = .secondaryLabelColor
        focusRingType = .none
        toolTip = L10n.showInFinder
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
