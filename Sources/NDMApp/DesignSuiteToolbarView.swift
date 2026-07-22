import AppKit
import NDMCore

/// Design Suite in-window tool strip: primary New + Pause/Resume + trailing search.
/// Text chips — not system rounded push buttons.
@MainActor
final class DesignSuiteToolbarView: NSView, NSTextFieldDelegate {
    var onNew: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onClipboardOffer: (() -> Void)?
    var onSearch: ((String) -> Void)?

    private let newButton = ToolChipButton(title: "＋ \(L10n.new)", style: .primary)
    private let pauseButton = ToolChipButton(title: L10n.pause, style: .ghost, symbolName: "pause.fill")
    private let resumeButton = ToolChipButton(title: L10n.resume, style: .ghost, symbolName: "play.fill")
    private let clipboardOfferButton = ClipboardOfferButton()
    private var clipboardOffer: SharedLinkResolution?
    private let activityIcon = NSImageView()
    private let activityLabel = NSTextField(labelWithString: "")
    private let activityStack = NSStackView()
    private var lastActiveCount = 0
    private var lastBytesPerSecond: Double = 0
    // Plain NSTextField + a manually laid-out icon/clear button, not
    // NSSearchField: NSSearchFieldCell's private searchButtonRect /
    // searchTextRect geometry does not behave predictably at custom heights,
    // so icon/placeholder alignment is instead guaranteed by AutoLayout.
    private let searchField = ToolbarSearchField()
    private let searchIcon = NSImageView()
    private let searchClearButton = NSButton()
    private let searchShell = SearchShellView(
        fill: NDMChrome.searchSurface,
        borderColor: NDMChrome.hairline,
        cornerRadius: 9,
        borderWidth: 1
    )
    private let hairline = ChromeBox(fill: NDMChrome.hairline)
    private var contentScale: CGFloat = InterfaceScale.default
    private var searchFocused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        newButton.target = self
        newButton.action = #selector(tapNew)
        pauseButton.target = self
        pauseButton.action = #selector(tapPause)
        resumeButton.target = self
        resumeButton.action = #selector(tapResume)
        resumeButton.isEnabled = false
        clipboardOfferButton.target = self
        clipboardOfferButton.action = #selector(tapClipboardOffer)
        clipboardOfferButton.isHidden = true

        activityIcon.image = NDMChrome.symbol("arrow.down.circle", pointSize: 12, weight: .medium)
        activityIcon.contentTintColor = NDMChrome.accent
        activityIcon.imageScaling = .scaleProportionallyUpOrDown
        activityIcon.translatesAutoresizingMaskIntoConstraints = false
        activityLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.lineBreakMode = .byTruncatingTail
        activityStack.orientation = .horizontal
        activityStack.alignment = .centerY
        activityStack.spacing = 6
        activityStack.addArrangedSubview(activityIcon)
        activityStack.addArrangedSubview(activityLabel)
        activityStack.setContentHuggingPriority(.required, for: .horizontal)
        activityStack.translatesAutoresizingMaskIntoConstraints = false
        // Idle by default — this is live traffic info, not a permanent chip;
        // it only earns its space in the toolbar while something is moving.
        activityStack.isHidden = true

        configureSearchField()
        searchShell.translatesAutoresizingMaskIntoConstraints = false
        searchShell.onActivate = { [weak self] in self?.focusSearch() }
        searchShell.addSubview(searchIcon)
        searchShell.addSubview(searchField)
        searchShell.addSubview(searchClearButton)

        let tools = NSStackView(views: [newButton, pauseButton, resumeButton])
        tools.orientation = .horizontal
        tools.spacing = 8
        tools.translatesAutoresizingMaskIntoConstraints = false

        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tools)
        addSubview(clipboardOfferButton)
        addSubview(activityStack)
        addSubview(searchShell)
        addSubview(hairline)
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            tools.centerYAnchor.constraint(equalTo: centerYAnchor),
            clipboardOfferButton.leadingAnchor.constraint(equalTo: tools.trailingAnchor, constant: 18),
            clipboardOfferButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clipboardOfferButton.trailingAnchor.constraint(lessThanOrEqualTo: searchShell.leadingAnchor, constant: -14),
            clipboardOfferButton.heightAnchor.constraint(equalToConstant: 34),
            clipboardOfferButton.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            activityStack.leadingAnchor.constraint(equalTo: clipboardOfferButton.trailingAnchor, constant: 14),
            activityStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityStack.trailingAnchor.constraint(lessThanOrEqualTo: searchShell.leadingAnchor, constant: -18),
            activityIcon.widthAnchor.constraint(equalToConstant: 14),
            activityIcon.heightAnchor.constraint(equalToConstant: 14),
            searchShell.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            searchShell.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchShell.widthAnchor.constraint(equalToConstant: 236),
            searchShell.heightAnchor.constraint(equalToConstant: 36),
            // Icon, text and clear button all pin to the shell's centerY —
            // this is the actual fix for the icon/placeholder misalignment,
            // not a cell-geometry hack.
            searchIcon.leadingAnchor.constraint(equalTo: searchShell.leadingAnchor, constant: 9),
            searchIcon.centerYAnchor.constraint(equalTo: searchShell.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 13),
            searchIcon.heightAnchor.constraint(equalToConstant: 13),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: searchClearButton.leadingAnchor, constant: -1),
            searchField.centerYAnchor.constraint(equalTo: searchShell.centerYAnchor),
            searchClearButton.trailingAnchor.constraint(equalTo: searchShell.trailingAnchor, constant: -2),
            searchClearButton.centerYAnchor.constraint(equalTo: searchShell.centerYAnchor),
            searchClearButton.widthAnchor.constraint(equalToConstant: 28),
            searchClearButton.heightAnchor.constraint(equalToConstant: 28),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            newButton.heightAnchor.constraint(equalToConstant: 38),
            pauseButton.heightAnchor.constraint(equalToConstant: 38),
            resumeButton.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureSearchField() {
        searchIcon.image = NDMChrome.symbol("magnifyingglass", pointSize: 12, weight: .medium)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = L10n.searchDownloads
        searchField.font = .systemFont(ofSize: 12.5)
        // The shell draws the keyboard focus state so the text field keeps its
        // clean borderless geometry without becoming invisible to keyboard users.
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.usesSingleLineMode = true
        searchField.lineBreakMode = .byClipping
        searchField.cell?.sendsActionOnEndEditing = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.onFocusChange = { [weak self] focused in
            self?.setSearchFocused(focused)
        }

        searchClearButton.bezelStyle = .inline
        searchClearButton.isBordered = false
        searchClearButton.focusRingType = .default
        searchClearButton.image = NDMChrome.symbol("xmark.circle.fill", pointSize: 12, weight: .regular)
        searchClearButton.imageScaling = .scaleProportionallyUpOrDown
        searchClearButton.contentTintColor = .tertiaryLabelColor
        searchClearButton.target = self
        searchClearButton.action = #selector(tapClearSearch)
        searchClearButton.toolTip = L10n.clearSearch
        searchClearButton.setAccessibilityLabel(L10n.clearSearch)
        searchClearButton.isHidden = true
        searchClearButton.translatesAutoresizingMaskIntoConstraints = false
    }

    override func updateLayer() {
        layer?.backgroundColor = NDMChrome.toolbarSurface.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func setResumeEnabled(_ enabled: Bool) {
        resumeButton.isEnabled = enabled
    }

    func setPauseEnabled(_ enabled: Bool) {
        pauseButton.isEnabled = enabled
    }

    func setSearchQuery(_ query: String) {
        searchField.stringValue = query
        updateClearButtonVisibility()
    }

    @discardableResult
    func focusSearch() -> Bool {
        guard let window else { return false }
        let ok = window.makeFirstResponder(searchField)
        if ok {
            setSearchFocused(true)
            searchField.currentEditor()?.selectAll(nil)
        }
        return ok
    }

    func setClipboardOffer(_ offer: SharedLinkResolution?) {
        clipboardOffer = offer
        refreshClipboardOffer()
    }

    /// Live "N active · speed" readout for the toolbar's otherwise-empty
    /// middle stretch. Hidden entirely at idle — this is traffic info, not
    /// permanent chrome.
    func setActivitySummary(activeCount: Int, bytesPerSecond: Double) {
        lastActiveCount = activeCount
        lastBytesPerSecond = bytesPerSecond
        refreshActivitySummary()
    }

    private func refreshActivitySummary() {
        guard lastActiveCount > 0 else {
            activityStack.isHidden = true
            stopActivityPulse()
            return
        }
        let speedText = TaskPresentationFormatting.speed(lastBytesPerSecond, status: .downloading)
        activityLabel.stringValue = L10n.activeSummary(lastActiveCount, speedText == L10n.emDash ? "…" : speedText)
        activityStack.isHidden = false
        startActivityPulse()
    }

    private func startActivityPulse() {
        activityIcon.wantsLayer = true
        guard activityIcon.layer?.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.4
        pulse.duration = 1.0
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        activityIcon.layer?.add(pulse, forKey: "pulse")
    }

    private func stopActivityPulse() {
        activityIcon.layer?.removeAnimation(forKey: "pulse")
        activityIcon.layer?.opacity = 1.0
    }

    /// Semantic zoom changes legibility and intrinsic widths, while the 62pt
    /// chrome itself stays stable. This avoids mechanically scaling the window.
    func setContentScale(_ scale: CGFloat) {
        contentScale = min(InterfaceScale.maximum, max(InterfaceScale.minimum, scale))
        let textScale = 1 + (contentScale - 1) * 0.55
        newButton.setContentScale(textScale)
        pauseButton.setContentScale(textScale)
        resumeButton.setContentScale(textScale)
        clipboardOfferButton.setContentScale(textScale)
        searchField.font = .systemFont(ofSize: 12.5 * textScale)
        activityLabel.font = .monospacedDigitSystemFont(ofSize: 12.5 * textScale, weight: .medium)
        needsLayout = true
    }

    func relocalize() {
        newButton.title = "＋ \(L10n.new)"
        pauseButton.title = L10n.pause
        resumeButton.title = L10n.resume
        searchField.placeholderString = L10n.searchDownloads
        searchClearButton.toolTip = L10n.clearSearch
        searchClearButton.setAccessibilityLabel(L10n.clearSearch)
        refreshClipboardOffer()
        refreshActivitySummary()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func controlTextDidChange(_ obj: Notification) {
        updateClearButtonVisibility()
        // Skip mid-IME composition so Chinese input does not filter on every
        // candidate keystroke; commit still goes through searchChanged/action.
        if let editor = searchField.currentEditor() as? NSTextView, editor.hasMarkedText() {
            return
        }
        emitSearch()
    }

    /// Esc: clear if there's text (native search field behavior), otherwise
    /// give up first responder. Routed through the field editor's command
    /// dispatch rather than a custom `cancelOperation` override, since this
    /// is now a plain `NSTextField`, not `NSSearchField`.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            updateClearButtonVisibility()
            emitSearch()
        } else {
            window?.makeFirstResponder(nil)
        }
        return true
    }

    @objc private func tapNew() { onNew?() }
    @objc private func tapPause() { onPause?() }
    @objc private func tapResume() { onResume?() }
    @objc private func tapClipboardOffer() { onClipboardOffer?() }
    @objc private func searchChanged() { emitSearch() }

    @objc private func tapClearSearch() {
        searchField.stringValue = ""
        updateClearButtonVisibility()
        emitSearch()
        focusSearch()
    }

    private func emitSearch() {
        onSearch?(searchField.stringValue)
    }

    private func updateClearButtonVisibility() {
        searchClearButton.isHidden = searchField.stringValue.isEmpty
    }

    private func setSearchFocused(_ focused: Bool) {
        guard searchFocused != focused else { return }
        searchFocused = focused
        // A restrained accent outline is visible to keyboard users while the
        // slightly brighter fill keeps the quiet Design Suite treatment.
        searchShell.fill = focused ? NDMChrome.searchSurfaceFocused : NDMChrome.searchSurface
        searchShell.borderColor = focused ? NDMChrome.accent : NDMChrome.hairline
        searchShell.borderWidth = focused ? 2 : 1
    }

    private func refreshClipboardOffer() {
        guard let clipboardOffer else {
            clipboardOfferButton.isHidden = true
            clipboardOfferButton.title = ""
            return
        }
        clipboardOfferButton.title = L10n.clipboardOffer(
            source: clipboardOffer.source,
            wasExtractedFromText: clipboardOffer.wasExtractedFromText
        )
        clipboardOfferButton.toolTip = L10n.clipboardOfferTooltip
        clipboardOfferButton.isHidden = false
        clipboardOfferButton.invalidateIntrinsicContentSize()
    }
}

/// Capsule chrome that focuses the enclosed search field when the padding is clicked.
private final class SearchShellView: ChromeBox {
    var onActivate: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Hits on the field itself go there via hit-testing; this path is the
        // capsule padding around the control.
        onActivate?()
    }
}

/// Plain borderless text field with first-responder focus callbacks. A
/// regular `NSTextField`, not `NSSearchField` — the icon and clear button
/// are separate sibling views laid out by AutoLayout (see
/// `DesignSuiteToolbarView`), so this class owns no icon/cancel geometry.
private final class ToolbarSearchField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        // Field editor steals first responder immediately — do not clear focus
        // in resignFirstResponder or the shell fill will flicker off.
        if ok { onFocusChange?(true) }
        return ok
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        onFocusChange?(true)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

/// A temporary affordance, not another toolbar chip: no border, no permanent
/// surface, just source-aware copy in the toolbar's existing whitespace.
private final class ClipboardOfferButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .inline
        isBordered = false
        focusRingType = .default
        font = .systemFont(ofSize: 12.5, weight: .medium)
        image = NDMChrome.symbol("doc.on.clipboard", pointSize: 13, weight: .medium)
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        contentTintColor = NDMChrome.accent
        lineBreakMode = .byTruncatingTail
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setContentScale(_ scale: CGFloat) {
        font = .systemFont(ofSize: 12.5 * scale, weight: .medium)
        image = NDMChrome.symbol(
            "doc.on.clipboard",
            pointSize: 13 * scale,
            weight: .medium
        )
        invalidateIntrinsicContentSize()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        layer?.backgroundColor = NDMChrome.track.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }
}

/// Borderless chip matching Design Suite `.tool` / `.tool.primary`.
private final class ToolChipButton: NSButton {
    enum Style { case primary, ghost }

    private let chipStyle: Style
    private let symbolName: String?
    private var horizontalPadding: CGFloat = 34

    init(title: String, style: Style, symbolName: String? = nil) {
        self.chipStyle = style
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.title = title
        if let symbolName {
            image = NDMChrome.symbol(symbolName, pointSize: 10.5, weight: .semibold)
            imagePosition = .imageLeading
            imageScaling = .scaleProportionallyDown
        }
        bezelStyle = .inline
        isBordered = false
        // The stock AppKit focus ring is painted outside the button's layer.
        // With our 38pt custom capsule that leaves a second, offset rounded
        // shape peeking out underneath until another control becomes first
        // responder. Keep keyboard focus visible with a restrained inner
        // stroke instead of mixing two independent button renderers.
        focusRingType = .none
        font = .systemFont(ofSize: 13.5, weight: style == .primary ? .semibold : .medium)
        contentTintColor = style == .primary ? .white : .labelColor
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + horizontalPadding, height: 38)
    }

    func setContentScale(_ scale: CGFloat) {
        font = .systemFont(
            ofSize: 13.5 * scale,
            weight: chipStyle == .primary ? .semibold : .medium
        )
        if let symbolName {
            image = NDMChrome.symbol(symbolName, pointSize: 10.5 * scale, weight: .semibold)
        }
        horizontalPadding = 34 * (1 + (scale - 1) * 0.35)
        invalidateIntrinsicContentSize()
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func updateLayer() {
        let isKeyboardFocused = window?.firstResponder === self
        switch chipStyle {
        case .primary:
            layer?.backgroundColor = (isEnabled ? NDMChrome.accent : NDMChrome.accent.withAlphaComponent(0.35)).cgColor
            contentTintColor = .white
            layer?.borderWidth = isKeyboardFocused ? 1.5 : 0
            layer?.borderColor = NSColor.white.withAlphaComponent(0.72).cgColor
        case .ghost:
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = isEnabled ? .labelColor : .tertiaryLabelColor
            // A resting hairline keeps the chip readable as a control —
            // bare text next to a filled primary reads as a stray label.
            layer?.borderWidth = isKeyboardFocused ? 1.5 : 1
            layer?.borderColor = isKeyboardFocused
                ? NDMChrome.accent.withAlphaComponent(0.62).cgColor
                : NDMChrome.hairline.cgColor
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { needsDisplay = true }
        return resigned
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isEnabled, chipStyle == .ghost else { return }
        layer?.backgroundColor = NDMChrome.track.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if chipStyle == .ghost {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            self.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.95, y: 0.95))
        }
        super.mouseDown(with: event)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
            ctx.allowsImplicitAnimation = true
            self.layer?.setAffineTransform(.identity)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
    }
}
