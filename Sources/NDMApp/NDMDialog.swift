import AppKit
import NDMCore

/// NDM's own dialog, replacing `NSAlert` everywhere.
///
/// `NSAlert` is a grey slab with a stock app icon and a stack of system-blue
/// buttons. It is fine, and it looks like every other app's fine — which, in a
/// product whose whole argument is that somebody designed it, is the wrong place to
/// hand the user to the platform default. These panels appear at exactly the moments
/// that matter (deleting something, quitting mid-download, a failure), and they were
/// the last surfaces still speaking a different language.
///
/// Three ideas, none of them restyling:
///
/// **A dialog shows its subject.** A confirmation about a file displays *that file*
/// — its own poster and name — instead of a generic warning glyph. It is better
/// looking and strictly more informative: you can see what you are about to delete.
/// Only dialogs with no subject fall back to a tinted symbol.
///
/// **An option is not a button.** "Remove / Remove and Trash / Cancel" is three
/// buttons for two decisions. It becomes a checkbox and two buttons, which is calmer
/// to look at and clearer about what will happen to the file.
///
/// **A dialog belongs to a window.** With a host it is a sheet, attached to the
/// thing it concerns, rather than a slab floating in the middle of the screen.
@MainActor
enum NDMDialog {
    struct Button {
        let title: String
        /// Paints the filled action red. Only meaningful on the primary.
        var isDestructive = false
        /// Answers Escape, and never takes the filled treatment.
        var isCancel = false

        init(_ title: String, isDestructive: Bool = false, isCancel: Bool = false) {
            self.title = title
            self.isDestructive = isDestructive
            self.isCancel = isCancel
        }
    }

    /// What the panel is about, shown before the text says it.
    @MainActor
    enum Subject {
        /// A specific file: its artwork if there is any, its type glyph otherwise.
        case file(name: String, cover: NSImage?)
        case info
        case caution
        case failure

        var symbol: String {
            switch self {
            case .file: return "doc.fill"
            case .info: return "info.circle.fill"
            case .caution: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.octagon.fill"
            }
        }

        var tint: NSColor {
            switch self {
            case .file, .info: return NDMChrome.accent
            case .caution: return .systemOrange
            case .failure: return .systemRed
            }
        }
    }

    /// An optional extra decision that would otherwise cost a third button.
    struct Option {
        let title: String
        var isOn: Bool = false
    }

    struct Result {
        /// Index into the `buttons` array as passed in.
        let buttonIndex: Int
        /// State of `option` when the panel closed; false when there was none.
        let optionIsOn: Bool
    }

    /// App-modal with a synchronous answer, for callers that branch on it inline.
    @discardableResult
    static func runModal(
        title: String,
        body: String? = nil,
        subject: Subject = .info,
        buttons: [Button] = [Button(L10n.ok)],
        option: Option? = nil,
        accessory: NSView? = nil
    ) -> Result {
        let panel = DialogPanel(
            title: title,
            body: body,
            subject: subject,
            buttons: buttons,
            option: option,
            accessory: accessory
        )
        panel.center()
        panel.playEntrance()
        let response = NSApp.runModal(for: panel)
        let optionIsOn = panel.optionIsOn
        panel.orderOut(nil)
        return Result(buttonIndex: response.rawValue, optionIsOn: optionIsOn)
    }

    /// A sheet on `host` when there is one, app-modal otherwise — the same fallback
    /// every call site was already writing by hand.
    static func present(
        title: String,
        body: String? = nil,
        subject: Subject = .info,
        buttons: [Button] = [Button(L10n.ok)],
        option: Option? = nil,
        accessory: NSView? = nil,
        host: NSWindow?,
        completion: ((Result) -> Void)? = nil
    ) {
        guard let host, host.isVisible else {
            let result = runModal(
                title: title,
                body: body,
                subject: subject,
                buttons: buttons,
                option: option,
                accessory: accessory
            )
            completion?(result)
            return
        }
        let panel = DialogPanel(
            title: title,
            body: body,
            subject: subject,
            buttons: buttons,
            option: option,
            accessory: accessory
        )
        panel.presentedAsSheet = true
        host.beginSheet(panel) { response in
            completion?(
                Result(buttonIndex: response.rawValue, optionIsOn: panel.optionIsOn)
            )
        }
    }
}

/// The panel itself, sized to its content so a one-line notice is not as tall as a
/// three-decision confirmation.
@MainActor
private final class DialogPanel: NSWindow {
    /// Sheets end through `endSheet`; app-modal panels through `stopModal`.
    var presentedAsSheet = false
    var optionIsOn: Bool { optionCheckbox?.state == .on }

    private var buttonControls: [InspectorActionButton] = []
    private var optionCheckbox: NSButton?
    private var cancelIndex: Int?

    init(
        title: String,
        body: String?,
        subject: NDMDialog.Subject,
        buttons: [NDMDialog.Button],
        option: NDMDialog.Option?,
        accessory: NSView?
    ) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 436, height: 160),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        NDMChrome.applyWindowChrome(self)

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NDMChrome.contentSurface.cgColor
        contentView = content

        let emblem = Self.makeEmblem(for: subject)
        emblem.translatesAutoresizingMaskIntoConstraints = false
        emblem.setAccessibilityElement(false)

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 3
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 7
        textStack.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        if let body, !body.isEmpty {
            let bodyLabel = NSTextField(wrappingLabelWithString: body)
            bodyLabel.font = .systemFont(ofSize: 12.5)
            bodyLabel.textColor = .secondaryLabelColor
            bodyLabel.isSelectable = true
            bodyLabel.translatesAutoresizingMaskIntoConstraints = false
            textStack.addArrangedSubview(bodyLabel)
            bodyLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        }
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            textStack.addArrangedSubview(accessory)
            textStack.setCustomSpacing(13, after: textStack.arrangedSubviews[max(0, textStack.arrangedSubviews.count - 2)])
            accessory.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        }
        if let option {
            let checkbox = NSButton(checkboxWithTitle: option.title, target: nil, action: nil)
            checkbox.state = option.isOn ? .on : .off
            checkbox.font = .systemFont(ofSize: 12.5)
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            textStack.addArrangedSubview(checkbox)
            textStack.setCustomSpacing(13, after: textStack.arrangedSubviews[max(0, textStack.arrangedSubviews.count - 2)])
            optionCheckbox = checkbox
        }

        // Cancel sits leftmost of the group and never carries the fill; the primary
        // is last, where the eye finishes.
        let primaryIndex = buttons.firstIndex(where: { !$0.isCancel })
        let ordered = Array(buttons.enumerated()).sorted { lhs, rhs in
            lhs.element.isCancel && !rhs.element.isCancel
        }
        var controls: [NSView] = [NSView()]
        for (index, spec) in ordered {
            let isPrimary = !spec.isCancel && index == primaryIndex
            let button = Self.makeButton(spec, isPrimary: isPrimary)
            button.tag = index
            button.target = self
            button.action = #selector(buttonPressed(_:))
            if spec.isCancel {
                cancelIndex = index
                button.keyEquivalent = "\u{1b}"
            } else if isPrimary {
                button.keyEquivalent = "\r"
            }
            buttonControls.append(button)
            controls.append(button)
        }
        if cancelIndex == nil { cancelIndex = buttons.count - 1 }

        let actions = NSStackView(views: controls)
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 9
        actions.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(emblem)
        content.addSubview(textStack)
        content.addSubview(actions)

        NSLayoutConstraint.activate([
            emblem.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            emblem.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),

            textStack.leadingAnchor.constraint(equalTo: emblem.trailingAnchor, constant: 15),
            textStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            textStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 27),

            actions.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
            actions.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: actions.bottomAnchor, constant: 22),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: emblem.bottomAnchor, constant: 22),
        ])
        for button in buttonControls {
            button.heightAnchor.constraint(
                equalToConstant: NDMChrome.sheetActionHeight
            ).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true
        }

        content.layoutSubtreeIfNeeded()
        setContentSize(NSSize(width: 436, height: max(content.fittingSize.height, 128)))
        initialFirstResponder = accessory ?? buttonControls.last
    }

    /// A file shows itself; everything else gets a tinted symbol puck.
    private static func makeEmblem(for subject: NDMDialog.Subject) -> NSView {
        switch subject {
        case .file(let name, let cover):
            let plate = ChromeBox(
                fill: NDMChrome.track,
                borderColor: NDMChrome.hairline,
                cornerRadius: 9,
                borderWidth: 1
            )
            let image = NSImageView()
            image.image = cover ?? NDMChrome.fileIcon(filename: name, pointSize: 34)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            image.wantsLayer = true
            image.layer?.cornerRadius = 8
            image.layer?.masksToBounds = true
            plate.addSubview(image)
            NSLayoutConstraint.activate([
                plate.widthAnchor.constraint(equalToConstant: 46),
                plate.heightAnchor.constraint(equalToConstant: 46),
                image.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 1),
                image.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -1),
                image.topAnchor.constraint(equalTo: plate.topAnchor, constant: 1),
                image.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -1),
            ])
            return plate
        default:
            let puck = ChromeBox(fill: subject.tint.withAlphaComponent(0.14), cornerRadius: 11)
            let icon = NSImageView()
            icon.image = NDMChrome.symbol(subject.symbol, pointSize: 17, weight: .semibold)
            icon.contentTintColor = subject.tint
            icon.translatesAutoresizingMaskIntoConstraints = false
            puck.addSubview(icon)
            NSLayoutConstraint.activate([
                puck.widthAnchor.constraint(equalToConstant: 38),
                puck.heightAnchor.constraint(equalToConstant: 38),
                icon.centerXAnchor.constraint(equalTo: puck.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: puck.centerYAnchor),
            ])
            return puck
        }
    }

    private static func makeButton(
        _ spec: NDMDialog.Button,
        isPrimary: Bool
    ) -> InspectorActionButton {
        if isPrimary {
            let button = InspectorActionButton(title: spec.title, style: .filled)
            button.font = .systemFont(ofSize: 13, weight: .semibold)
            // Return already runs it; the exterior ring on a filled pill is noise.
            button.focusRingType = .none
            if spec.isDestructive { button.overrideFilledColor = .systemRed }
            return button
        }
        // Secondaries stay quiet. A row of equally weighted boxes is what makes a
        // dialog feel like a form rather than a question.
        let button = InspectorActionButton(title: spec.title, style: .flat)
        button.usesOutlinedHover = true
        button.focusRingType = .none
        return button
    }

    /// Arrive, rather than appear. Sheets get AppKit's own slide, so this is only
    /// for the app-modal case.
    func playEntrance() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = contentView?.superview?.layer ?? contentView?.layer else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.965
        scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.16
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        layer.add(group, forKey: "dialogEntrance")
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        finish(with: sender.tag)
    }

    override func cancelOperation(_ sender: Any?) {
        finish(with: cancelIndex ?? 0)
    }

    private func finish(with index: Int) {
        if presentedAsSheet {
            sheetParent?.endSheet(self, returnCode: NSApplication.ModalResponse(rawValue: index))
        } else {
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: index))
        }
    }

    override var canBecomeKey: Bool { true }
}
