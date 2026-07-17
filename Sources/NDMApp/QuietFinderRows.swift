import AppKit
import UniformTypeIdentifiers

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

    /// Optional Downie-style frosted cover wash (video rows).
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

        if let cover = coverImage, artworkStyle == .fullBleed {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            // Keep the photography, then reserve a predictable neutral reading
            // lane for metadata. This is the same scrim/material pattern used by
            // media cards: label colors stay system-consistent in every row.
            let drawRect = Self.aspectFillRect(for: cover.size, in: inset)
            cover.draw(
                in: drawRect,
                from: .zero,
                operation: .copy,
                fraction: paintsSelected ? 0.80 : 0.74,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            let readingLane = NSGradient(
                colorsAndLocations:
                    (NDMChrome.contentSurface.withAlphaComponent(paintsSelected ? 0.94 : 0.97), 0.0),
                    (NDMChrome.contentSurface.withAlphaComponent(paintsSelected ? 0.87 : 0.92), 0.58),
                    (NDMChrome.contentSurface.withAlphaComponent(paintsSelected ? 0.68 : 0.76), 1.0)
            )
            readingLane?.draw(in: path, angle: 0)
            if paintsSelected {
                NDMChrome.accent.withAlphaComponent(0.22).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        if let artwork = coverImage, artworkStyle == .ambient {
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

            // A real Quick Look preview or native file icon becomes atmosphere,
            // not a literal second thumbnail. It is intentionally oversized,
            // softly clipped by the row, and kept away from the filename column.
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
                fraction: paintsSelected ? 0.16 : 0.105,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )

            // Fade the preview before it reaches the primary text block.
            let readabilityFade = NSGradient(
                colorsAndLocations:
                    (NDMChrome.contentSurface, 0.0),
                    (NDMChrome.contentSurface.withAlphaComponent(0.76), 0.42),
                    (NSColor.clear, 1.0)
            )
            readabilityFade?.draw(in: inset, angle: 0)

            if paintsSelected {
                NDMChrome.accent.withAlphaComponent(0.18).setStroke()
                path.lineWidth = 1
                path.stroke()
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
            }
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        if paintsSelected {
            if usesAccentFill {
                NDMChrome.accent.setFill()
            } else {
                NDMChrome.rowActive.setFill()
            }
            path.fill()
        } else {
            NSColor.clear.setFill()
            dirtyRect.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Selection is painted in drawBackground — keep system highlight off.
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        if paintsSelected, usesAccentFill { return .emphasized }
        return .normal
    }

    private static func aspectFillRect(for imageSize: NSSize, in bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
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

    func apply(filename: String, cover: NSImage?, categoryWash: NSColor?) {
        if let cover {
            imageView.image = cover
            imageView.isHidden = false
            symbolView.isHidden = true
            plate.isHidden = true
            return
        }

        imageView.isHidden = true
        symbolView.isHidden = false
        plate.isHidden = false
        let style = Self.style(for: filename)
        plate.fill = (categoryWash ?? NDMChrome.track).withAlphaComponent(0.55)
        plate.borderColor = NDMChrome.hairline
        symbolView.image = NDMChrome.symbol(style.symbol, pointSize: 15, weight: .semibold)
        symbolView.contentTintColor = style.tint
    }

    private struct Style {
        var symbol: String
        var tint: NSColor
    }

    private static func style(for filename: String) -> Style {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["mp4", "mkv", "mov", "m4v", "webm", "avi", "ts"].contains(ext) {
            return Style(symbol: "film", tint: NDMChrome.accent)
        }
        if ["mp3", "m4a", "flac", "wav", "aac", "ogg"].contains(ext) {
            return Style(symbol: "waveform", tint: .systemPink)
        }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) {
            return Style(symbol: "photo", tint: .systemTeal)
        }
        if ["zip", "rar", "7z", "gz", "tar"].contains(ext) {
            return Style(symbol: "archivebox", tint: .systemOrange)
        }
        if ["dmg", "iso"].contains(ext) {
            return Style(symbol: "externaldrive.fill", tint: .systemIndigo)
        }
        if ["pdf", "doc", "docx", "txt", "rtf", "md"].contains(ext) {
            return Style(symbol: "doc.text", tint: .systemBlue)
        }
        if ["pkg", "app", "exe", "msi", "apk"].contains(ext) {
            return Style(symbol: "shippingbox.fill", tint: .systemPurple)
        }
        if let type = UTType(filenameExtension: ext) {
            _ = type
        }
        return Style(symbol: "arrow.down.doc", tint: .secondaryLabelColor)
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
