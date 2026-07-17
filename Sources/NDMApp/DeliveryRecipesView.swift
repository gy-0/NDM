import AppKit
import NDMCore
import NDMEngine

/// One calm, outcome-first control for post-download delivery. The original
/// stays the hero; generated versions are deliberate secondary actions.
@MainActor
final class DeliveryRecipesView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let safetyLabel = NSTextField(labelWithString: "")
    private let selector = NSSegmentedControl(
        labels: ["", ""],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let recipeIcon = NSImageView()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var inputURL: URL?
    private var results: [DeliveryRecipe: DeliveryResult] = [:]
    private var exportTask: Task<Void, Never>?

    private var selectedRecipe: DeliveryRecipe {
        let recipes = DeliveryRecipe.allCases
        let index = max(0, min(selector.selectedSegment, recipes.count - 1))
        return recipes[index]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .labelColor

        safetyLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        safetyLabel.textColor = .systemGreen
        safetyLabel.alignment = .right

        selector.segmentStyle = .rounded
        selector.selectedSegment = 0
        selector.target = self
        selector.action = #selector(selectionChanged)
        selector.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<selector.segmentCount {
            selector.setWidth(0, forSegment: index)
        }

        recipeIcon.translatesAutoresizingMaskIntoConstraints = false
        recipeIcon.contentTintColor = NDMChrome.accent

        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, NSView(), safetyLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8

        let descriptionStack = NSStackView(views: [detailLabel, statusLabel])
        descriptionStack.orientation = .vertical
        descriptionStack.alignment = .leading
        descriptionStack.spacing = 3
        descriptionStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detailRow = NSStackView(views: [recipeIcon, descriptionStack, spinner, actionButton])
        detailRow.orientation = .horizontal
        detailRow.alignment = .centerY
        detailRow.spacing = 9

        let separator = ChromeBox(fill: NDMChrome.hairline)
        separator.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [separator, header, selector, detailRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.setCustomSpacing(11, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            selector.widthAnchor.constraint(equalTo: stack.widthAnchor),
            selector.heightAnchor.constraint(equalToConstant: 28),
            detailRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            recipeIcon.widthAnchor.constraint(equalToConstant: 22),
            recipeIcon.heightAnchor.constraint(equalToConstant: 22),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            actionButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        isHidden = true
        relocalize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { exportTask?.cancel() }

    func apply(input: URL?) {
        exportTask?.cancel()
        inputURL = input
        results.removeAll()
        selector.selectedSegment = 0
        isHidden = !SmartFinalize.supportsDeliveryRecipes(input: input)
        updatePresentation()
    }

    func relocalize() {
        let titles = [
            L10n.deliveryOriginalShort,
            L10n.deliveryAudioShort,
        ]
        for (index, title) in titles.enumerated() {
            selector.setLabel(title, forSegment: index)
        }
        titleLabel.stringValue = L10n.deliverySectionTitle
        safetyLabel.stringValue = L10n.deliveryOriginalProtected
        updatePresentation()
    }

    @objc private func selectionChanged() {
        updatePresentation()
    }

    private func updatePresentation() {
        let recipe = selectedRecipe
        recipeIcon.image = NDMChrome.symbol(symbol(for: recipe), pointSize: 17, weight: .medium)
        detailLabel.stringValue = description(for: recipe)

        if let result = results[recipe] {
            actionButton.isHidden = false
            let size = fileSize(result.primaryURL)
            statusLabel.stringValue = L10n.deliveryReady(
                TaskPresentationFormatting.byteCount(size),
                subtitleCount: result.sidecarURLs.count
            )
            statusLabel.textColor = .systemGreen
            actionButton.title = L10n.showInFinder
            setActionProminence(primary: false)
        } else if recipe == .originalQuality {
            // The completed page already has a global Finder action. Repeating
            // it inside the "Original" recipe reads like two competing CTAs.
            actionButton.isHidden = true
            statusLabel.stringValue = L10n.deliveryCurrentFile
            statusLabel.textColor = .tertiaryLabelColor
            actionButton.title = L10n.showInFinder
            setActionProminence(primary: false)
        } else {
            actionButton.isHidden = false
            statusLabel.stringValue = L10n.deliveryCreatesCopy
            statusLabel.textColor = .tertiaryLabelColor
            actionButton.title = L10n.deliveryCreateCopy
            setActionProminence(primary: true)
        }
    }

    private func setActionProminence(primary: Bool) {
        if primary {
            NDMChrome.styleMainButton(actionButton)
        } else {
            if #available(macOS 11.0, *) { actionButton.bezelColor = nil }
            NDMChrome.styleGhostButton(actionButton)
        }
    }

    @objc private func actionClicked() {
        let recipe = selectedRecipe
        if let result = results[recipe] {
            NSWorkspace.shared.activateFileViewerSelecting([result.primaryURL])
            return
        }
        guard let inputURL else { return }
        if recipe == .originalQuality {
            NSWorkspace.shared.activateFileViewerSelecting([inputURL])
            return
        }

        selector.isEnabled = false
        actionButton.isEnabled = false
        spinner.startAnimation(nil)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = L10n.deliveryCreating(recipeTitle(for: recipe))
        exportTask = Task { [weak self] in
            do {
                let result = try await SmartFinalize.deliver(input: inputURL, recipe: recipe)
                guard let self, !Task.isCancelled else { return }
                results[recipe] = result
                selector.isEnabled = true
                actionButton.isEnabled = true
                spinner.stopAnimation(nil)
                updatePresentation()
            } catch {
                guard let self, !Task.isCancelled else { return }
                selector.isEnabled = true
                actionButton.isEnabled = true
                spinner.stopAnimation(nil)
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = FFmpegTool.find() == nil
                    ? L10n.shareNeedsFFmpeg
                    : L10n.deliveryFailed
            }
        }
    }

    private func recipeTitle(for recipe: DeliveryRecipe) -> String {
        switch recipe {
        case .originalQuality: return L10n.deliveryOriginalShort
        case .mobileCompatible: return L10n.deliveryMobileShort
        case .audioOnly: return L10n.deliveryAudioShort
        case .weChat: return L10n.deliveryWeChatShort
        }
    }

    private func description(for recipe: DeliveryRecipe) -> String {
        switch recipe {
        case .originalQuality: return L10n.deliveryOriginalDescription
        case .mobileCompatible: return L10n.deliveryMobileDescription
        case .audioOnly: return L10n.deliveryAudioDescription
        case .weChat: return L10n.deliveryWeChatDescription
        }
    }

    private func symbol(for recipe: DeliveryRecipe) -> String {
        switch recipe {
        case .originalQuality: return "sparkles.rectangle.stack"
        case .mobileCompatible: return "iphone"
        case .audioOnly: return "waveform"
        case .weChat: return "message.fill"
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(max(0, value ?? 0))
    }
}
