import AppKit
import NDMCore

@MainActor
enum ScribeStudioIntegration {
    static let bundleIdentifier = "dev.yuan.scribestudio"

    enum LaunchError: LocalizedError {
        case unsupportedFile
        case missingFile
        case appNotInstalled

        var errorDescription: String? {
            switch self {
            case .unsupportedFile: return "Unsupported media file"
            case .missingFile: return "The downloaded file no longer exists"
            case .appNotInstalled: return "ScribeStudio is not installed"
            }
        }
    }

    static func applicationURL() -> URL? {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["NDM_QA_SCRIBESTUDIO_APP"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
#endif
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static func isAvailable(for fileURL: URL?) -> Bool {
        guard TranscriptionWorkflow.supports(fileURL: fileURL),
              let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              applicationURL() != nil else { return false }
        return true
    }

    static func open(
        fileURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard TranscriptionWorkflow.supports(fileURL: fileURL) else {
            completion(.failure(LaunchError.unsupportedFile))
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            completion(.failure(LaunchError.missingFile))
            return
        }
        guard let applicationURL = applicationURL() else {
            completion(.failure(LaunchError.appNotInstalled))
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }
    }
}

/// Contextual ecosystem handoff shared by the inspector and completion window.
/// It stays hidden for unrelated files and when the companion app is absent.
@MainActor
final class ScribeStudioActionCard: ChromeBox {
    private let appIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()
    private var fileURL: URL?
    private var contentScale: CGFloat = 1

    init() {
        super.init(
            fill: .clear
        )
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        configure()
        relocalize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        appIcon.imageScaling = .scaleProportionallyDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        appIcon.setAccessibilityElement(false)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.isHidden = true

        actionButton.target = self
        actionButton.action = #selector(openInScribeStudio)
        actionButton.image = NDMChrome.symbol("arrow.up.forward.app", pointSize: 11.5, weight: .semibold)
        actionButton.imagePosition = .imageLeading
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        NDMChrome.styleGhostButton(actionButton)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let top = NSStackView(views: [appIcon, titleLabel, spacer, actionButton])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [top, subtitleLabel, statusLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24),
            subtitleLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24),
            statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24),
            appIcon.widthAnchor.constraint(equalToConstant: 30),
            appIcon.heightAnchor.constraint(equalToConstant: 30),
            actionButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    func apply(fileURL: URL?) {
        self.fileURL = fileURL
        statusLabel.isHidden = true
        actionButton.isEnabled = true
        guard ScribeStudioIntegration.isAvailable(for: fileURL),
              let applicationURL = ScribeStudioIntegration.applicationURL() else {
            isHidden = true
            return
        }

        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        icon.size = NSSize(width: 30, height: 30)
        appIcon.image = icon
        isHidden = false
        relocalize()
    }

    func setContentScale(_ scale: CGFloat) {
        contentScale = min(1.3, max(0.9, scale))
        titleLabel.font = .systemFont(ofSize: 12.5 * contentScale, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12 * contentScale)
        statusLabel.font = .systemFont(ofSize: 12 * contentScale, weight: .medium)
    }

    func relocalize() {
        titleLabel.stringValue = "ScribeStudio"
        subtitleLabel.stringValue = L10n.scribeStudioDescription
        actionButton.title = L10n.open
        actionButton.toolTip = L10n.openInScribeStudio
        actionButton.setAccessibilityLabel(L10n.openInScribeStudio)
        if !statusLabel.isHidden, statusLabel.textColor == .secondaryLabelColor {
            statusLabel.stringValue = L10n.sentToScribeStudio
        }
    }

    @objc private func openInScribeStudio() {
        guard let fileURL else { return }
        actionButton.isEnabled = false
        ScribeStudioIntegration.open(fileURL: fileURL) { [weak self] result in
            guard let self else { return }
            actionButton.isEnabled = true
            statusLabel.isHidden = false
            switch result {
            case .success:
                statusLabel.textColor = .secondaryLabelColor
                statusLabel.stringValue = L10n.sentToScribeStudio
            case let .failure(error):
                statusLabel.textColor = .tertiaryLabelColor
                statusLabel.stringValue = L10n.scribeStudioOpenFailed
                statusLabel.toolTip = error.localizedDescription
            }
            invalidateIntrinsicContentSize()
        }
    }
}
