import AppKit
import NDMCore

/// Three steps, thirty seconds: install the extension → feel the speed on a
/// real file → done. Step 2 is where the "回不去" moment gets manufactured.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    /// Reliable public Range-capable test file for the speed demo.
    static let testFileURL = "https://download.thinkbroadband.com/100MB.zip"

    var onInstallExtension: (() -> Void)?
    var onStartTestDownload: ((String) -> Void)?
    var onFinished: (() -> Void)?

    private var step = 0
    private let contentBox = NSView()
    private var dots: [ChromeBox] = []
    private var finishedReported = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.onboardingWindowTitle
        NDMChrome.applyWindowChrome(window)
        super.init(window: window)
        buildUI()
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        contentBox.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentBox)

        let dotsRow = NSStackView()
        dotsRow.orientation = .horizontal
        dotsRow.spacing = 7
        for _ in 0..<3 {
            let dot = ChromeBox(cornerRadius: 3)
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            dots.append(dot)
            dotsRow.addArrangedSubview(dot)
        }
        dotsRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dotsRow)

        NSLayoutConstraint.activate([
            contentBox.topAnchor.constraint(equalTo: content.topAnchor),
            contentBox.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            contentBox.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentBox.bottomAnchor.constraint(equalTo: dotsRow.topAnchor, constant: -14),
            dotsRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dotsRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        showStep(0)
    }

    private func showStep(_ index: Int) {
        step = index
        contentBox.subviews.forEach { $0.removeFromSuperview() }
        for (i, dot) in dots.enumerated() {
            dot.fill = i == index
                ? NDMChrome.accent
                : NSColor.tertiaryLabelColor.withAlphaComponent(0.35)
        }

        let page: NSView
        switch index {
        case 0: page = makeStep1()
        case 1: page = makeStep2()
        default: page = makeStep3()
        }
        page.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(page)
        NSLayoutConstraint.activate([
            page.centerXAnchor.constraint(equalTo: contentBox.centerXAnchor),
            page.centerYAnchor.constraint(equalTo: contentBox.centerYAnchor),
            page.widthAnchor.constraint(equalTo: contentBox.widthAnchor, constant: -88),
        ])
    }

    // MARK: - Pages

    private func makeMark(symbol: String) -> NSView {
        let mark = ChromeBox(fill: NDMChrome.accent, cornerRadius: 16)
        mark.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = NDMChrome.symbol(symbol, pointSize: 28, weight: .semibold)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        mark.addSubview(icon)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 64),
            mark.heightAnchor.constraint(equalToConstant: 64),
            icon.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
        ])
        return mark
    }

    private func makeTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.alignment = .center
        return label
    }

    private func makeBody(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }

    private func primaryButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        if #available(macOS 11.0, *) {
            button.bezelColor = NDMChrome.accent
        }
        return button
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private func makeStep1() -> NSView {
        let chrome = NSButton(title: "Chrome", target: self, action: #selector(installClicked))
        chrome.bezelStyle = .rounded
        chrome.controlSize = .large
        let edge = NSButton(title: "Edge", target: self, action: #selector(installClicked))
        edge.bezelStyle = .rounded
        edge.controlSize = .large
        let safari = NSButton(title: L10n.onboardingSafariSoon, target: nil, action: nil)
        safari.bezelStyle = .rounded
        safari.controlSize = .large
        safari.isEnabled = false
        let browsers = NSStackView(views: [chrome, edge, safari])
        browsers.orientation = .horizontal
        browsers.spacing = 10

        let stack = NSStackView(views: [
            makeMark(symbol: "arrow.down.to.line"),
            makeTitle(L10n.onboardingStep1Title),
            makeBody(L10n.onboardingStep1Body),
            browsers,
            primaryButton(L10n.onboardingContinue, action: #selector(nextClicked)),
            linkButton(L10n.onboardingSkip, action: #selector(nextClicked)),
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(22, after: browsers)
        return stack
    }

    private func makeStep2() -> NSView {
        let race = primaryButton(L10n.onboardingRaceButton, action: #selector(raceClicked))
        let test = linkButton(L10n.onboardingTestButton, action: #selector(testDownloadClicked))
        let stack = NSStackView(views: [
            makeMark(symbol: "gauge.with.needle"),
            makeTitle(L10n.onboardingStep2Title),
            makeBody(L10n.onboardingStep2Body),
            race,
            test,
            linkButton(L10n.onboardingSkip, action: #selector(nextClicked)),
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(4, after: race)
        stack.setCustomSpacing(18, after: test)
        return stack
    }

    @objc private func raceClicked() {
        SpeedRaceWindowController.present()
        showStep(2)
    }

    private func makeStep3() -> NSView {
        let shortcuts = NSTextField(wrappingLabelWithString: L10n.onboardingShortcuts)
        shortcuts.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        shortcuts.textColor = .labelColor
        let card = CardStackView(views: [shortcuts])
        card.orientation = .vertical
        card.alignment = .leading
        card.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)

        let stack = NSStackView(views: [
            makeMark(symbol: "checkmark"),
            makeTitle(L10n.onboardingStep3Title),
            makeBody(L10n.onboardingStep3Body),
            card,
            primaryButton(L10n.onboardingDone, action: #selector(finishClicked)),
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(22, after: card)
        return stack
    }

    // MARK: - Actions

    @objc private func installClicked() {
        onInstallExtension?()
        showStep(1)
    }

    @objc private func nextClicked() {
        if step >= 2 {
            finishClicked()
        } else {
            showStep(step + 1)
        }
    }

    @objc private func testDownloadClicked() {
        onStartTestDownload?(Self.testFileURL)
        showStep(2)
    }

    @objc private func finishClicked() {
        reportFinished()
        window?.close()
    }

    private func reportFinished() {
        guard !finishedReported else { return }
        finishedReported = true
        onFinished?()
    }

    func windowWillClose(_ notification: Notification) {
        reportFinished()
    }
}
