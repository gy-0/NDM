import AppKit

/// Cover readability overlay for Quiet Finder rows.
enum QuietFinderRowScrimStyle {
    /// One even translucent wash over the cover.
    case flat
    /// Left-to-right multi-stop fade (original Quiet Finder look).
    case legacyMultiStop
}

enum QuietFinderRowScrim {
    /// Restored: original multi-stop veil over covers.
    static var style: QuietFinderRowScrimStyle = .legacyMultiStop
}

/// Rounded accent selection — Quiet Finder list / sidebar (Design Suite `.row.on` / `.nav.on`).
///
/// With `selectionHighlightStyle = .none`, AppKit often flips `isSelected` without
/// invalidating the row. Always `needsDisplay` on selection change, and allow an
/// explicit override so we can paint from model state after `reloadData`.
final class QuietFinderRowView: NSTableRowView {
    enum ArtworkStyle: Equatable {
        /// Photographic content is the row: video covers and downloaded images.
        case fullBleed
        /// Documents/packages use a large, quiet real preview at the trailing edge.
        case ambient
    }

    var usesAccentFill = false
    var artworkStyle: ArtworkStyle = .fullBleed {
        didSet {
            if oldValue != artworkStyle { needsDisplay = true }
        }
    }

    /// Optional photographic selection treatment (video/image rows).
    var coverImage: NSImage? {
        didSet {
            if oldValue !== coverImage { needsDisplay = true }
        }
    }

    /// Soft category tint when there is no photographic cover.
    var washColor: NSColor? {
        didSet {
            if oldValue != washColor { needsDisplay = true }
        }
    }

    /// When non-nil, wins over `isSelected` for drawing (keeps pill stable across reloads).
    var forcedSelected: Bool? {
        didSet {
            if oldValue != forcedSelected { needsDisplay = true }
        }
    }

    private var paintsSelected: Bool { forcedSelected ?? isSelected }

    override var isSelected: Bool {
        didSet {
            if oldValue != isSelected { needsDisplay = true }
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 6, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)

        if coverImage != nil, artworkStyle == .fullBleed, !paintsSelected {
            // Resting media rows stay quiet — the thumbnail lives in the
            // leading glyph; richer artwork is a single-selection reward.
            NDMChrome.contentSurface.setFill()
            dirtyRect.fill()
            drawHoverWash(path)
            return
        }

        // Ambient rows always; selected media rows share the same treatment.
        // Aspect-filling a 16:9 cover into a ~25:1 row strip crops it into an
        // unreadable smear, so the old full-bleed selected path is gone: the
        // cover appears whole (aspect-fit) at the trailing edge instead.
        if let artwork = coverImage {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()

            NDMChrome.contentSurface.setFill()
            path.fill()
            if let wash = washColor {
                wash.withAlphaComponent(paintsSelected ? 0.10 : 0.055).setFill()
                path.fill()
            }
            if paintsSelected {
                NDMChrome.rowActive.setFill()
                path.fill()
            }

            // Oversized trailing preview — kept soft and away from the filename.
            let artWidth = min(max(inset.width * 0.36, 110), 210)
            let artBounds = NSRect(
                x: inset.maxX - artWidth + 14,
                y: inset.minY - inset.height * 0.28,
                width: artWidth,
                height: inset.height * 1.56
            )
            let artRect = Self.aspectFitRect(for: artwork.size, in: artBounds)
            artwork.draw(
                in: artRect,
                from: .zero,
                operation: .sourceOver,
                fraction: paintsSelected ? (artworkStyle == .fullBleed ? 0.22 : 0.16) : 0.105,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )

            switch QuietFinderRowScrim.style {
            case .flat:
                // Hard stop on the left reading lane; no gradient fade.
                let laneWidth = max(inset.width * 0.58, 180)
                let lane = NSRect(
                    x: inset.minX,
                    y: inset.minY,
                    width: min(laneWidth, inset.width),
                    height: inset.height
                )
                NDMChrome.contentSurface.setFill()
                lane.fill()
            case .legacyMultiStop:
                let readabilityFade = NSGradient(
                    colorsAndLocations:
                        (NDMChrome.contentSurface, 0.0),
                        (NDMChrome.contentSurface.withAlphaComponent(0.76), 0.42),
                        (NSColor.clear, 1.0)
                )
                readabilityFade?.draw(in: inset, angle: 0)
            }

            if paintsSelected {
                NDMChrome.accent.withAlphaComponent(0.18).setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                drawHoverWash(path)
            }
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        if let wash = washColor {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            wash.withAlphaComponent(paintsSelected ? 0.16 : 0.09).setFill()
            path.fill()
            if paintsSelected {
                NDMChrome.rowActive.setFill()
                path.fill()
            } else {
                drawHoverWash(path)
            }
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        if paintsSelected {
            if usesAccentFill {
                // Sidebar: a soft accent pill, not a solid blue slab. It reads
                // identically over the light paper rail and the dark glass one
                // — no more "solid white vs frosted" mismatch — and the label
                // ink (painted by the cell) carries the accent instead.
                let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                NDMChrome.accent.withAlphaComponent(isDark ? 0.22 : 0.14).setFill()
            } else {
                NDMChrome.rowActive.setFill()
            }
            path.fill()
        } else {
            NSColor.clear.setFill()
            dirtyRect.fill()
            drawHoverWash(path)
        }
    }

    // MARK: - Hover

    /// Subtle pointer feedback on resting rows — driven by the list
    /// controller's row-level tracking (per-cell tracking areas are
    /// unreliable during scroll), so this is a plain flag, not an observer.
    var isHovered = false {
        didSet {
            if oldValue != isHovered { needsDisplay = true }
        }
    }

    private func drawHoverWash(_ path: NSBezierPath) {
        guard isHovered else { return }
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        path.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Selection is painted in drawBackground — keep system highlight off.
    }

    func celebrateCompletion() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        wantsLayer = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let layer = self?.layer else { return }

            let scale = CASpringAnimation(keyPath: "transform")
            let up = CATransform3DMakeScale(1.03, 1.03, 1)
            scale.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            scale.toValue = NSValue(caTransform3D: up)
            scale.mass = 1
            scale.stiffness = 320
            scale.damping = 14
            scale.initialVelocity = 8
            scale.autoreverses = true
            scale.duration = scale.settlingDuration / 2
            layer.add(scale, forKey: "celebrate")

            let shadow = CABasicAnimation(keyPath: "shadowOpacity")
            shadow.fromValue = 0
            shadow.toValue = 0.22
            shadow.duration = 0.25
            shadow.autoreverses = true
            shadow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.shadowColor = NDMChrome.accent.cgColor
            layer.shadowRadius = 12
            layer.shadowOffset = CGSize(width: 0, height: -2)
            layer.add(shadow, forKey: "celebrateShadow")
        }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        // Always `.normal`. Returning `.emphasized` for accent-selected sidebar
        // rows makes AppKit force light (white) label/icon ink onto the cell,
        // and with `selectionHighlightStyle = .none` that style often never
        // clears when the row is deselected — leaving ghost white text.
        // Sidebar/list cells paint their own ink from model selection instead.
        .normal
    }

    private static func aspectFitRect(for imageSize: NSSize, in bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// Compact cover / type glyph for the download list.
@MainActor
final class FileGlyphView: NSView {
    private let imageView = NSImageView()
    private let plate = ChromeBox(
        fill: NDMChrome.track,
        borderColor: NDMChrome.hairline,
        cornerRadius: 9,
        borderWidth: 1
    )
    private let symbolView = NSImageView()
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var symbolWidthConstraint: NSLayoutConstraint?
    private var symbolHeightConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        plate.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.contentTintColor = .secondaryLabelColor

        addSubview(plate)
        addSubview(imageView)
        addSubview(symbolView)
        let widthConstraint = widthAnchor.constraint(equalToConstant: 40)
        let heightConstraint = heightAnchor.constraint(equalToConstant: 40)
        let symbolWidthConstraint = symbolView.widthAnchor.constraint(equalToConstant: 18)
        let symbolHeightConstraint = symbolView.heightAnchor.constraint(equalToConstant: 18)
        self.widthConstraint = widthConstraint
        self.heightConstraint = heightConstraint
        self.symbolWidthConstraint = symbolWidthConstraint
        self.symbolHeightConstraint = symbolHeightConstraint
        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolWidthConstraint,
            symbolHeightConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setContentScale(_ scale: CGFloat) {
        widthConstraint?.constant = 40 * scale
        heightConstraint?.constant = 40 * scale
        symbolWidthConstraint?.constant = 18 * scale
        symbolHeightConstraint?.constant = 18 * scale
        layer?.cornerRadius = 9 * scale
        plate.cornerRadius = 9 * scale
    }

    func apply(filename: String, cover: NSImage?) {
        // Prefer a real cover; otherwise the same Finder / UTType icon the
        // inspector uses (`NDMChrome.fileIcon`).
        plate.isHidden = true
        symbolView.isHidden = true
        imageView.isHidden = false
        imageView.image = cover ?? NDMChrome.fileIcon(filename: filename, pointSize: 40)
    }

    /// Arm a cross-dissolve for the *next* `apply`, so a generic file icon melts into
    /// the file's real poster frame instead of snapping to it.
    ///
    /// The one moment a download manager has that is worth marking. Until a file
    /// finishes there is nothing to make a picture of, so the row carries a UTType
    /// icon; the instant it lands, AVFoundation or Quick Look can pull an actual frame
    /// out of it. Swapping that in is not decoration — the change on screen *means*
    /// the file is real and openable now, which is what the user was waiting to know.
    ///
    /// Deliberately not a spring, a particle or a sound. It fires once per file and
    /// has to still be welcome on the fortieth download of the day.
    ///
    /// Arming rather than setting keeps the image assignment where it already lives:
    /// the transition captures what is on screen now, and the caller's normal apply
    /// supplies what it dissolves to.
    func armPosterReveal() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        imageView.wantsLayer = true
        let dissolve = CATransition()
        dissolve.type = .fade
        dissolve.duration = 0.28
        dissolve.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
        imageView.layer?.add(dissolve, forKey: "posterReveal")
    }
}

@MainActor
enum FileCategoryWash {
    static func color(forFilename filename: String) -> NSColor? {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["mp4", "mkv", "mov", "m4v", "webm", "avi", "ts"].contains(ext) {
            return NDMChrome.accent
        }
        if ["mp3", "m4a", "flac", "wav", "aac", "ogg"].contains(ext) {
            return .systemPink
        }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) {
            return .systemTeal
        }
        if ["zip", "rar", "7z", "gz", "tar"].contains(ext) {
            return .systemOrange
        }
        if ["dmg", "iso"].contains(ext) {
            return .systemIndigo
        }
        if ["pkg", "app", "exe", "msi", "apk"].contains(ext) {
            return .systemPurple
        }
        if ["pdf", "doc", "docx", "txt", "rtf", "md"].contains(ext) {
            return .systemBlue
        }
        return nil
    }
}
