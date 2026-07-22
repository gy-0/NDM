import AppKit
import NDMCore
import NDMEngine

/// Converts restricted-site access into a guided handoff. NDM never asks for
/// account credentials; it reads only the existing site state from the browser
/// the user explicitly selects.
@MainActor
enum MediaAccessPrompt {
    fileprivate struct BrowserChoice: Equatable {
        var title: String
        var identifier: String
        var applicationPath: String
    }

    static func choose(
        pageURL: String,
        parentWindow: NSWindow?,
        previousSource: YtDlpCookieSource? = nil,
        retrying: Bool = false
    ) async -> YtDlpCookieSource? {
        await MediaAccessWindowController.present(
            pageURL: pageURL,
            choices: installedBrowsers(),
            previousSource: previousSource,
            retrying: retrying,
            on: parentWindow
        )
    }

    private static func installedBrowsers() -> [BrowserChoice] {
        let candidates = [
            BrowserChoice(title: "Safari", identifier: "safari", applicationPath: "/Applications/Safari.app"),
            BrowserChoice(title: "Google Chrome", identifier: "chrome", applicationPath: "/Applications/Google Chrome.app"),
            BrowserChoice(title: "Chromium", identifier: "chromium", applicationPath: "/Applications/Chromium.app"),
            BrowserChoice(title: "Firefox", identifier: "firefox", applicationPath: "/Applications/Firefox.app"),
            BrowserChoice(title: "Firefox Developer Edition", identifier: "firefox", applicationPath: "/Applications/Firefox Developer Edition.app"),
            BrowserChoice(title: "Microsoft Edge", identifier: "edge", applicationPath: "/Applications/Microsoft Edge.app"),
            BrowserChoice(title: "Brave", identifier: "brave", applicationPath: "/Applications/Brave Browser.app"),
            // Brave Origin (com.brave.Browser.origin) is a separate app + cookie store.
            BrowserChoice(
                title: "Brave Origin",
                identifier: "brave:\(NSHomeDirectory())/Library/Application Support/BraveSoftware/Brave-Origin",
                applicationPath: "/Applications/Brave Origin.app"
            ),
            BrowserChoice(title: "Vivaldi", identifier: "vivaldi", applicationPath: "/Applications/Vivaldi.app"),
            BrowserChoice(title: "Opera", identifier: "opera", applicationPath: "/Applications/Opera.app"),
        ]
        let installed = candidates.filter {
            FileManager.default.fileExists(atPath: $0.applicationPath)
        }
        guard !installed.isEmpty else { return [candidates[0]] }
        guard let sampleURL = URL(string: "https://example.com"),
              let defaultApplication = NSWorkspace.shared.urlForApplication(toOpen: sampleURL) else {
            return installed
        }
        let defaultPath = defaultApplication.standardizedFileURL.path
        return installed.enumerated().sorted { lhs, rhs in
            let lhsIsDefault = URL(fileURLWithPath: lhs.element.applicationPath)
                .standardizedFileURL.path == defaultPath
            let rhsIsDefault = URL(fileURLWithPath: rhs.element.applicationPath)
                .standardizedFileURL.path == defaultPath
            if lhsIsDefault != rhsIsDefault { return lhsIsDefault }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

@MainActor
private final class MediaAccessWindowController: NSWindowController, NSWindowDelegate {
    private static var active: MediaAccessWindowController?

    private let pageURL: URL?
    private let choices: [MediaAccessPrompt.BrowserChoice]
    private let popup = NSPopUpButton()
    private let openButton = NSButton()
    private let continueButton = NSButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var onFinish: ((YtDlpCookieSource?) -> Void)?
    private var activationObserver: NSObjectProtocol?
    private var didFinish = false
    private var didOpenBrowser = false

    private var selectedChoice: MediaAccessPrompt.BrowserChoice {
        let index = max(0, min(popup.indexOfSelectedItem, choices.count - 1))
        return choices[index]
    }

    init(
        pageURL: String,
        choices: [MediaAccessPrompt.BrowserChoice],
        previousSource: YtDlpCookieSource?,
        retrying: Bool,
        onFinish: @escaping (YtDlpCookieSource?) -> Void
    ) {
        self.pageURL = URL(string: pageURL)
        self.choices = choices
        self.onFinish = onFinish
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 414),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.mediaAccessTitle
        window.isReleasedWhenClosed = false
        window.representedURL = nil
        NDMChrome.applySheetChrome(window)
        super.init(window: window)
        window.delegate = self
        buildUI(retrying: retrying)
        // The panel's height follows its content; a hard-coded height leaves
        // dead space inside the step card whenever copy runs short.
        if let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            let fitted = content.fittingSize
            window.setContentSize(NSSize(width: 560, height: max(fitted.height, 280)))
        }

        if case .browser(let identifier) = previousSource,
           let index = choices.firstIndex(where: { $0.identifier == identifier }) {
            popup.selectItem(at: index)
        }
        refreshBrowserCopy()

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.returnedFromBrowser() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    static func present(
        pageURL: String,
        choices: [MediaAccessPrompt.BrowserChoice],
        previousSource: YtDlpCookieSource?,
        retrying: Bool,
        on parentWindow: NSWindow?
    ) async -> YtDlpCookieSource? {
        await withCheckedContinuation { continuation in
            let controller = MediaAccessWindowController(
                pageURL: pageURL,
                choices: choices,
                previousSource: previousSource,
                retrying: retrying
            ) { result in
                Self.active = nil
                continuation.resume(returning: result)
            }
            Self.active = controller
            guard let sheet = controller.window else {
                continuation.resume(returning: nil)
                return
            }
            if let parentWindow {
                parentWindow.beginSheet(sheet) { _ in }
            } else {
                sheet.center()
                sheet.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func buildUI(retrying: Bool) {
        guard let content = window?.contentView else { return }
        content.widthAnchor.constraint(equalToConstant: 560).isActive = true

        let badgeImage = NSImageView(image: NDMChrome.symbol(
            "lock.open.display",
            pointSize: 24,
            weight: .medium
        ) ?? NSImage())
        badgeImage.contentTintColor = NDMChrome.accent
        badgeImage.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L10n.mediaAccessTitle)
        title.font = .systemFont(ofSize: 19, weight: .bold)
        let lede = NSTextField(wrappingLabelWithString: L10n.mediaAccessBody)
        lede.font = .systemFont(ofSize: 12.5)
        lede.textColor = .secondaryLabelColor

        let headerCopy = NSStackView(views: [title, lede])
        headerCopy.orientation = .vertical
        headerCopy.alignment = .leading
        headerCopy.spacing = 4

        let header = NSStackView(views: [badgeImage, headerCopy])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 14

        popup.addItems(withTitles: choices.map(\.title))
        popup.target = self
        popup.action = #selector(browserChanged)
        popup.controlSize = .regular

        let browserLabel = NSTextField(labelWithString: L10n.mediaAccessBrowserLabel)
        browserLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        browserLabel.textColor = .secondaryLabelColor
        let browserRow = NSStackView(views: [browserLabel, NSView(), popup])
        browserRow.orientation = .horizontal
        browserRow.alignment = .centerY

        let openStep = AccessStepView(
            number: "1",
            title: L10n.mediaAccessOpenStep,
            detail: L10n.mediaAccessOpenStepBody
        )
        let returnStep = AccessStepView(
            number: "2",
            title: L10n.mediaAccessReturnStep,
            detail: L10n.mediaAccessReturnStepBody
        )
        let steps = CardStackView(views: [browserRow, openStep, returnStep])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 12
        steps.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        statusLabel.font = .systemFont(ofSize: 12, weight: retrying ? .medium : .regular)
        statusLabel.textColor = retrying ? .systemOrange : .secondaryLabelColor
        statusLabel.stringValue = retrying
            ? L10n.mediaAccessRetryHint
            : L10n.mediaAccessHint

        let cancel = NSButton(title: L10n.cancel, target: self, action: #selector(cancelClicked))
        NDMChrome.styleGhostButton(cancel)
        cancel.keyEquivalent = "\u{1b}"

        let fileButton = NSButton(
            title: L10n.mediaAccessChooseFile,
            target: self,
            action: #selector(fileClicked)
        )
        fileButton.isBordered = false
        fileButton.font = .systemFont(ofSize: 12, weight: .medium)
        fileButton.contentTintColor = .secondaryLabelColor

        openButton.target = self
        openButton.action = #selector(openClicked)
        NDMChrome.styleMainButton(openButton)

        continueButton.target = self
        continueButton.action = #selector(continueClicked)
        NDMChrome.styleGhostButton(continueButton)

        let actions = NSStackView(views: [fileButton, NSView(), cancel, continueButton, openButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 9

        let stack = NSStackView(views: [header, steps, statusLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(18, after: header)
        stack.setCustomSpacing(10, after: steps)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            badgeImage.widthAnchor.constraint(equalToConstant: 30),
            badgeImage.heightAnchor.constraint(equalToConstant: 30),
            lede.widthAnchor.constraint(equalToConstant: 430),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            steps.widthAnchor.constraint(equalTo: stack.widthAnchor),
            browserRow.widthAnchor.constraint(equalTo: steps.widthAnchor, constant: -32),
            openStep.widthAnchor.constraint(equalTo: steps.widthAnchor, constant: -32),
            returnStep.widthAnchor.constraint(equalTo: steps.widthAnchor, constant: -32),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancel.heightAnchor.constraint(equalToConstant: 28),
            openButton.heightAnchor.constraint(equalToConstant: 28),
            continueButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func browserChanged() {
        didOpenBrowser = false
        refreshBrowserCopy()
        statusLabel.stringValue = L10n.mediaAccessHint
        statusLabel.textColor = .secondaryLabelColor
    }

    private func refreshBrowserCopy() {
        openButton.isHidden = false
        openButton.title = L10n.mediaAccessOpenInBrowser(selectedChoice.title)
        continueButton.title = L10n.mediaAccessAlreadyOpen
        openButton.keyEquivalent = "\r"
        continueButton.keyEquivalent = ""
        NDMChrome.styleMainButton(openButton)
        NDMChrome.styleGhostButton(continueButton)
        openButton.invalidateIntrinsicContentSize()
        continueButton.invalidateIntrinsicContentSize()
    }

    @objc private func openClicked() {
        guard let pageURL else {
            statusLabel.stringValue = L10n.mediaAccessOpenFailed
            statusLabel.textColor = .secondaryLabelColor
            return
        }
        didOpenBrowser = true
        statusLabel.stringValue = L10n.mediaAccessWaitingForReturn(selectedChoice.title)
        statusLabel.textColor = NDMChrome.accent
        promoteContinueButton()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [pageURL],
            withApplicationAt: URL(fileURLWithPath: selectedChoice.applicationPath),
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.didOpenBrowser = false
                self?.refreshBrowserCopy()
                self?.statusLabel.stringValue = L10n.mediaAccessOpenFailed
                self?.statusLabel.toolTip = error.localizedDescription
                self?.statusLabel.textColor = .secondaryLabelColor
            }
        }
    }

    private func returnedFromBrowser() {
        guard didOpenBrowser, !didFinish else { return }
        statusLabel.stringValue = L10n.mediaAccessReturnedHint(selectedChoice.title)
        statusLabel.textColor = NDMChrome.accent
        promoteContinueButton()
    }

    private func promoteContinueButton() {
        openButton.isHidden = true
        continueButton.title = L10n.mediaAccessContinueWith(selectedChoice.title)
        openButton.keyEquivalent = ""
        continueButton.keyEquivalent = "\r"
        NDMChrome.styleMainButton(continueButton)
        continueButton.invalidateIntrinsicContentSize()
    }

    @objc private func continueClicked() {
        finish(.browser(selectedChoice.identifier))
    }

    @objc private func fileClicked() {
        let panel = NSOpenPanel()
        panel.title = L10n.mediaAccessFileTitle
        panel.prompt = L10n.mediaAccessImport
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        Task { [weak self] in
            guard let self else { return }
            let result = await panel.begin()
            guard result == .OK, let url = panel.url else { return }
            finish(.file(url.path))
        }
    }

    @objc private func cancelClicked() { finish(nil) }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ result: YtDlpCookieSource?) {
        guard !didFinish else { return }
        didFinish = true
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        let callback = onFinish
        onFinish = nil
        window?.delegate = nil
        if let sheet = window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            window?.close()
        }
        callback?(result)
    }
}

@MainActor
private final class AccessStepView: NSView {
    init(number: String, title: String, detail: String) {
        super.init(frame: .zero)

        let badge = ChromeBox(
            fill: NDMChrome.accent.withAlphaComponent(0.12),
            borderColor: nil,
            cornerRadius: 10
        )
        badge.translatesAutoresizingMaskIntoConstraints = false
        let numberLabel = NSTextField(labelWithString: number)
        numberLabel.font = .systemFont(ofSize: 11, weight: .bold)
        numberLabel.textColor = NDMChrome.accent
        numberLabel.alignment = .center
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(numberLabel)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        let copy = NSStackView(views: [titleLabel, detailLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 2
        copy.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badge)
        addSubview(copy)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20),
            numberLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            copy.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            copy.trailingAnchor.constraint(equalTo: trailingAnchor),
            copy.topAnchor.constraint(equalTo: topAnchor),
            copy.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            detailLabel.widthAnchor.constraint(equalTo: copy.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
