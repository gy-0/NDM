import AppKit
import WebKit
import NDMCore

/// A native WKWebView host for the Appllama loader-button library
/// (loader-buttons.appllama.io), bundled into the target's resource root.
///
/// The 25 button animations are the reference site's own WebGL2 shaders +
/// Canvas-2D fallbacks. NDM drives them through the `ndmLoaders` JS bridge:
///
///   - `setPhase(_:)`  — swap the phase button to the matching animation
///                       (preparing → Gathering, transferring → Drifting,
///                        merging → Merging, finalizing → Polishing, …)
///   - `setIdle()`     — stop the animation, restore the resting label
///   - `showGallery()` — render all 25 buttons like the site (debug / about)
///
/// The view is intentionally transparent: the WKWebView layer carries no
/// background, so the pill button blends onto whatever surface hosts it.
@MainActor
final class LoaderButtonView: NSView {
    enum Mode { case phaseButton, glyph, gallery }

    /// Fired when the web side reports readiness or a phase swap.
    var onStateChange: ((String) -> Void)?

    private let webView: WKWebView
    private let pageURL: URL
    private var currentMode: Mode = .phaseButton
    /// Scripts issued before the page finished loading are replayed once
    /// the navigation completes; otherwise the phase set during the first
    /// progress tick would be lost to the idle default.
    private var pendingScripts: [String] = []

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        // WebGL2 needs the layer-backed accelerated compositing path. The
        // `allowWebGL` preference is a private key and KVC-setting it throws
        // NSUnknownKeyException on macOS 13 — modern WKWebView enables WebGL by
        // default, so no private-key poking is needed.
        configuration.websiteDataStore = .nonPersistent()

        webView = WKWebView(frame: .zero, configuration: configuration)
        // Single self-contained bundle at the Resources root (SwiftPM flattens
        // subdirectories, so the whole library inlines into one file). Use
        // Bundle.module — Bundle.main misses resources when the executable runs
        // directly from .build/debug.
        pageURL = Bundle.module.url(
            forResource: "loader_buttons",
            withExtension: "html"
        ) ?? URL(fileURLWithPath: "/dev/null")

        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
        setAccessibilityHidden(true)

        webView.translatesAutoresizingMaskIntoConstraints = false
        // Transparent host: the button pill blends onto whatever surface it sits on.
        // The HTML's body is already `background: transparent`, so no private-KVC
        // drawsBackground poking (which throws NSUnknownKeyException).
        // This WebView is visual-only. LoaderPauseButton supplies the one native
        // accessible control, so VoiceOver must not also discover the page's
        // internal default "下载" button.
        webView.setAccessibilityElement(false)
        webView.setAccessibilityHidden(true)
        webView.underPageBackgroundColor = .clear
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.navigationDelegate = self
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Load the local page once; JS drives itself from then on.
        webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Native → JS

    /// Swap the phase button to the animation matching an engine phase.
    func setPhase(_ phase: DownloadPhase?) {
        guard currentMode == .phaseButton || currentMode == .glyph else { return }
        let verb: String
        switch phase {
        case .preparing: verb = "preparing"
        case .merging: verb = "merging"
        case .subtitles: verb = "subtitles"
        case .finalizing: verb = "finalizing"
        default: verb = "transferring"
        }
        evaluate("ndmLoaders.setPhase('\(verb)')")
    }

    /// Drive non-running transfer states with the reference site's own verbs.
    /// The transparent AppKit overlay still exposes the actionable Chinese
    /// label (继续 / 重试); the web pill describes the state itself.
    func setStatus(_ status: DownloadStatus) {
        guard currentMode == .phaseButton || currentMode == .glyph else { return }
        switch status {
        case .paused, .incomplete:
            evaluate("ndmLoaders.setPhase('paused')")
        case .error:
            evaluate("ndmLoaders.setPhase('failed')")
        case .complete:
            evaluate("ndmLoaders.setPhase('completed')")
        case .downloading:
            evaluate("ndmLoaders.setPhase('transferring')")
        case .waiting:
            setIdle()
        }
    }

    /// Stop the animation and restore the resting label.
    func setIdle() {
        evaluate("ndmLoaders.setIdle()")
    }

    /// Render all 25 buttons in a grid, exactly like the reference site.
    func showGallery() {
        currentMode = .gallery
        evaluate("ndmLoaders.showGallery()")
    }

    func showPhaseButton() {
        currentMode = .phaseButton
        evaluate("ndmLoaders.showPhaseButton()")
    }

    /// Keep the reference site's real shader/canvas visual, but remove its web
    /// chrome. AppKit owns the capsule, label, hover and press feedback; WebKit
    /// is reduced to a small live glyph slot so it no longer reads as a pasted
    /// webpage inside the progress window.
    func showGlyphOnly() {
        currentMode = .glyph
        evaluate("ndmLoaders.showGlyphOnly()")
    }

    /// The native button owns pointer input, so mirror its interaction state
    /// into the visual web pill instead of expecting WKWebView to receive hover.
    func setInteraction(hovered: Bool, pressed: Bool) {
        evaluate("ndmLoaders.setInteraction(\(hovered), \(pressed))")
    }

    /// Keep the imported loader material inside NDM's live accent/appearance
    /// system rather than leaving a hard-coded white reference-site island.
    func setTheme(accentHex: String, isDark: Bool) {
        let safeHex = accentHex.replacingOccurrences(of: "'", with: "")
        evaluate("ndmLoaders.setTheme('\(safeHex)', \(isDark))")
    }

    private func evaluate(_ script: String) {
        if webView.isLoading {
            // Page not up yet — remember and replay after didFinish.
            pendingScripts.append(script)
            return
        }
        // Errors here are non-fatal: a later setPhase/setStatus call re-drives
        // the state, and the page-load race is handled by pendingScripts.
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// The click on the web button routes through a transparent NSButton-like
    /// gesture: we surface the click to the host. WKWebView swallows clicks
    /// inside its own content, so the host (progress window) keeps its own
    /// clickable control layered on top when it needs the action.
    func requestHostAction() {
        // Subclasses / hosts can override; the progress window wires this to pause.
    }
}

extension LoaderButtonView: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            // WebKit can rebuild its accessibility subtree after navigation.
            // Re-assert visual-only semantics here, not only during init.
            setAccessibilityElement(false)
            setAccessibilityHidden(true)
            webView.setAccessibilityElement(false)
            webView.setAccessibilityHidden(true)
            // Replay anything the host asked for while the page was loading.
            let scripts = pendingScripts
            pendingScripts = []
            scripts.forEach(evaluate)
            onStateChange?("loaded")
        }
    }
}
