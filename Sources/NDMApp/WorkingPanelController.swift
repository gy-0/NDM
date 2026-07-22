import AppKit
import NDMCore

/// Honest stages for work performed before a media task exists. There is no
/// percentage because the remote page does not expose one yet.
@MainActor
enum MediaPreparationStage: Int, CaseIterable {
    case resolvingLink
    case readingMedia
    case preparingOptions

    var title: String {
        switch self {
        case .resolvingLink: return L10n.mediaPreparationResolvingTitle
        case .readingMedia: return L10n.mediaPreparationReadingTitle
        case .preparingOptions: return L10n.mediaPreparationOptionsTitle
        }
    }

    var detail: String {
        switch self {
        case .resolvingLink: return L10n.mediaPreparationResolvingBody
        case .readingMedia: return L10n.mediaPreparationReadingBody
        case .preparingOptions: return L10n.mediaPreparationOptionsBody
        }
    }

    var symbol: String {
        switch self {
        case .resolvingLink: return "link"
        case .readingMedia: return "play.square.stack"
        case .preparingOptions: return "slider.horizontal.3"
        }
    }
}

/// Modern, delayed preparation sheet. Fast probes never flash a spinner; slow
/// ones explain the current stage and always provide an immediate way out.
@MainActor
final class WorkingPanelController: NSWindowController {
    private static var retained: WorkingPanelController?

    private let titleLabel = NSTextField(labelWithString: L10n.mediaPreparationTitle)
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let stepViews = MediaPreparationStage.allCases.map(PreparationStepView.init)
    private weak var parentWindow: NSWindow?
    private var revealTask: Task<Void, Never>?
    private var onCancel: (() -> Void)?
    private var isPresented = false
    private var isDismissed = false

    init(stage: MediaPreparationStage, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 242),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.mediaPreparationTitle
        window.isFloatingPanel = false
        window.isReleasedWhenClosed = false
        window.representedURL = nil
        NDMChrome.applySheetChrome(window)
        super.init(window: window)
        buildUI()
        update(stage: stage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // A quiet accent glyph beside the title — no pastel icon tile.
        let badgeImage = NSImageView(image: NDMChrome.symbol(
            "play.rectangle.on.rectangle",
            pointSize: 20,
            weight: .medium
        ) ?? NSImage())
        badgeImage.contentTintColor = NDMChrome.accent
        badgeImage.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        detailLabel.font = .systemFont(ofSize: 12.5)
        detailLabel.textColor = .secondaryLabelColor
        let copy = NSStackView(views: [titleLabel, detailLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 4

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)

        let header = NSStackView(views: [badgeImage, copy, NSView(), spinner])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 13

        // Open step row — the colored state badges carry the journey; no
        // containing gray card.
        let journey = CardStackView(views: stepViews)
        journey.fill = nil
        journey.cardBorderColor = nil
        journey.orientation = .horizontal
        journey.alignment = .centerY
        journey.distribution = .fillEqually
        journey.spacing = 8
        journey.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 2, right: 0)

        let note = NSTextField(wrappingLabelWithString: L10n.mediaPreparationNote)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let cancel = NSButton(title: L10n.cancel, target: self, action: #selector(cancelClicked))
        NDMChrome.styleGhostButton(cancel)
        cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [note, NSView(), cancel])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10

        let stack = NSStackView(views: [header, journey, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            badgeImage.widthAnchor.constraint(equalToConstant: 26),
            badgeImage.heightAnchor.constraint(equalToConstant: 26),
            detailLabel.widthAnchor.constraint(equalToConstant: 335),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            journey.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancel.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    /// Schedules presentation after a short grace period. The common fast path
    /// goes straight to quality options without a sheet flashing on screen.
    static func schedule(
        stage: MediaPreparationStage,
        on parent: NSWindow?,
        delayNanoseconds: UInt64 = 380_000_000,
        onCancel: @escaping () -> Void
    ) -> WorkingPanelController {
        retained?.dismiss()
        let controller = WorkingPanelController(stage: stage, onCancel: onCancel)
        controller.parentWindow = parent
        retained = controller
        controller.revealTask = Task { [weak controller] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let controller, !Task.isCancelled, !controller.isDismissed else { return }
            controller.presentNow()
        }
        return controller
    }

    func update(stage: MediaPreparationStage) {
        titleLabel.stringValue = stage.title
        detailLabel.stringValue = stage.detail
        detailLabel.toolTip = stage.detail
        for (candidate, view) in zip(MediaPreparationStage.allCases, stepViews) {
            let state: PreparationStepView.State
            if candidate.rawValue < stage.rawValue {
                state = .complete
            } else if candidate == stage {
                state = .active
            } else {
                state = .upcoming
            }
            view.apply(state)
        }
    }

    private func presentNow() {
        guard !isPresented, !isDismissed, let sheet = window else { return }
        isPresented = true
        if let parentWindow {
            parentWindow.beginSheet(sheet) { _ in }
        } else {
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func cancelClicked() {
        let callback = onCancel
        dismiss()
        callback?()
    }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        revealTask?.cancel()
        revealTask = nil
        onCancel = nil
        if Self.retained === self { Self.retained = nil }
        guard isPresented else { return }
        if let sheet = window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            window?.orderOut(nil)
            close()
        }
    }
}

@MainActor
private final class PreparationStepView: NSView {
    enum State { case upcoming, active, complete }

    private let stage: MediaPreparationStage
    private let badge = ChromeBox(cornerRadius: 10)
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(stage: MediaPreparationStage) {
        self.stage = stage
        super.init(frame: .zero)

        badge.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(imageView)

        label.stringValue = stage.title
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badge)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 54),
            badge.topAnchor.constraint(equalTo: topAnchor),
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            imageView.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
            label.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
        apply(.upcoming)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: State) {
        switch state {
        case .upcoming:
            badge.fill = NDMChrome.track
            imageView.image = NDMChrome.symbol(stage.symbol, pointSize: 12, weight: .medium)
            imageView.contentTintColor = .tertiaryLabelColor
            label.textColor = .tertiaryLabelColor
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
        case .active:
            badge.fill = NDMChrome.accent.withAlphaComponent(0.15)
            imageView.image = NDMChrome.symbol(stage.symbol, pointSize: 12, weight: .semibold)
            imageView.contentTintColor = NDMChrome.accent
            label.textColor = .labelColor
            label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        case .complete:
            badge.fill = NDMChrome.okSoft
            imageView.image = NDMChrome.symbol("checkmark", pointSize: 12, weight: .bold)
            imageView.contentTintColor = NDMChrome.accent
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
        }
    }
}
