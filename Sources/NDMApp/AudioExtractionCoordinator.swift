import AppKit
import NDMCore
import NDMEngine

/// Owns the low-frequency audio export flow shared by completion surfaces.
/// Controllers render the state; the engine work and cancellation stay here.
@MainActor
final class AudioExtractionCoordinator {
    enum State {
        case unavailable
        case ready
        case running
        case succeeded(DeliveryResult)
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .unavailable {
        didSet { onStateChange?(state) }
    }

    private var sourceURL: URL?
    private var exportTask: Task<Void, Never>?

    deinit { exportTask?.cancel() }

    func apply(sourceURL: URL?) {
        // Inspector refreshes, language changes, and completion relayouts may
        // present the same finished file repeatedly. Treat that as a no-op so
        // UI maintenance cannot cancel an export already in progress or erase
        // its success state.
        guard self.sourceURL != sourceURL else { return }
        exportTask?.cancel()
        exportTask = nil
        self.sourceURL = sourceURL
        state = SmartFinalize.supportsDeliveryRecipes(input: sourceURL)
            ? .ready
            : .unavailable
    }

    func extract() {
        guard let sourceURL else { return }
        switch state {
        case .ready, .succeeded, .failed:
            break
        case .unavailable, .running:
            return
        }

        state = .running
        exportTask = Task { [weak self] in
            do {
                let result = try await SmartFinalize.deliver(
                    input: sourceURL,
                    recipe: .audioOnly
                )
                guard let self, !Task.isCancelled else { return }
                exportTask = nil
                state = .succeeded(result)
            } catch {
                guard let self, !Task.isCancelled else { return }
                exportTask = nil
                state = .failed(
                    FFmpegTool.find() == nil
                        ? L10n.shareNeedsFFmpeg
                        : L10n.deliveryFailed
                )
            }
        }
    }

    func revealResult() {
        guard case let .succeeded(result) = state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.primaryURL])
    }

    func cancel() {
        exportTask?.cancel()
        exportTask = nil
    }
}

/// Compact, persistent feedback for an action launched from a transient menu.
@MainActor
final class AudioExtractionStatusView: NSView {
    private let icon = AmicroIconSwapView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = NDMChrome.accent
        icon.setSymbol("waveform", pointSize: 13, weight: .semibold, animated: false)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            spinner.widthAnchor.constraint(equalToConstant: 15),
            spinner.heightAnchor.constraint(equalToConstant: 15),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: AudioExtractionCoordinator.State) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        icon.isHidden = false

        switch state {
        case .unavailable, .ready:
            isHidden = true
            setAccessibilityValue(nil)
        case .running:
            isHidden = false
            icon.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
            label.textColor = .secondaryLabelColor
            label.stringValue = L10n.extractingAudio
            setAccessibilityValue(L10n.extractingAudio)
        case .succeeded:
            isHidden = false
            icon.tintColor = NDMChrome.accent
            icon.setSymbol("checkmark.circle.fill", pointSize: 13, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.stringValue = L10n.audioExtractionReady
            setAccessibilityValue(L10n.audioExtractionReady)
        case let .failed(message):
            isHidden = false
            icon.tintColor = .secondaryLabelColor
            icon.setSymbol("exclamationmark.circle.fill", pointSize: 13, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.stringValue = message
            setAccessibilityValue(message)
        }
        invalidateIntrinsicContentSize()
    }
}
