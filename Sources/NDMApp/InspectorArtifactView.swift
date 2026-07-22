import AppKit

/// A restrained, non-interactive type mark for the inspector's empty corner.
///
/// It deliberately has no backdrop, card, play control, or oversized arc. The
/// mark stays inside a measured safe area, sits upright, and never turns a
/// video cover into a second fake player.
@MainActor
final class InspectorArtifactView: NSView {
    private enum Kind {
        case video, audio, document, diskImage, archive, application, image, generic
    }

    private let artwork = ArtifactArtworkView()
    private var artworkWidth: NSLayoutConstraint!
    private var artworkHeight: NSLayoutConstraint!
    private var artworkTrailing: NSLayoutConstraint!
    private var artworkBottom: NSLayoutConstraint!
    private var contentScale: CGFloat = 1
    private var currentKind: Kind = .generic

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        setAccessibilityHidden(true)

        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.setAccessibilityElement(false)
        addSubview(artwork)

        artworkWidth = artwork.widthAnchor.constraint(equalToConstant: 190)
        artworkHeight = artwork.heightAnchor.constraint(equalToConstant: 170)
        artworkTrailing = artwork.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18)
        artworkBottom = artwork.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        NSLayoutConstraint.activate([
            artworkWidth,
            artworkHeight,
            artworkTrailing,
            artworkBottom,
            artwork.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            artwork.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(image: NSImage?, filename: String) {
        guard !filename.isEmpty else {
            artwork.image = nil
            artwork.isHidden = true
            return
        }

        currentKind = Self.kind(for: filename)
        // A downloaded image may preview itself. Video deliberately uses a film
        // type mark: a second cover in the inspector reads like a player and
        // duplicates the real cover already shown in the list/header.
        let usesRealPreview = currentKind == .image && image != nil
        artwork.image = usesRealPreview ? image : Self.symbol(for: filename)
        artwork.tintColor = usesRealPreview ? nil : Self.tint(for: currentKind)
        artwork.alphaValue = usesRealPreview ? 0.18 : 0.28
        artwork.isHidden = artwork.image == nil
        configure(for: currentKind)
    }

    func setContentScale(_ scale: CGFloat) {
        contentScale = 1 + (scale - 1) * 0.20
        configure(for: currentKind)
    }

    private func configure(for kind: Kind) {
        let base: (width: CGFloat, height: CGFloat)
        switch kind {
        case .video: base = (196, 164)
        case .audio: base = (188, 164)
        case .document: base = (176, 184)
        case .diskImage: base = (184, 174)
        case .archive: base = (184, 178)
        case .application: base = (184, 176)
        case .image: base = (214, 164)
        case .generic: base = (170, 178)
        }
        artworkWidth.constant = base.width * contentScale
        artworkHeight.constant = base.height * contentScale
        artworkTrailing.constant = -18 * contentScale
        artworkBottom.constant = -14 * contentScale
    }

    private static func symbol(for filename: String) -> NSImage? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let name: String
        switch ext {
        case "dmg", "iso": name = "externaldrive.fill"
        case "pkg", "app", "exe", "msi", "apk": name = "shippingbox.fill"
        case "zip", "rar", "7z", "gz", "tar": name = "archivebox.fill"
        case "mp3", "m4a", "flac", "wav", "aac", "ogg": name = "waveform"
        case "pdf", "doc", "docx", "txt", "rtf", "md", "epub": name = "doc.richtext.fill"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": name = "photo.fill"
        case "mp4", "mkv", "mov", "m4v", "webm", "avi", "ts": name = "film"
        default: name = "doc.fill"
        }
        return NDMChrome.symbol(name, pointSize: 112, weight: .regular)
    }

    private static func tint(for kind: Kind) -> NSColor {
        switch kind {
        case .video: return NDMChrome.accent.withAlphaComponent(0.72)
        case .audio: return NSColor.systemPink.withAlphaComponent(0.68)
        case .document: return NSColor.systemBlue.withAlphaComponent(0.66)
        case .diskImage: return NSColor.systemIndigo.withAlphaComponent(0.66)
        case .archive: return NSColor.systemOrange.withAlphaComponent(0.68)
        case .application: return NSColor.systemPurple.withAlphaComponent(0.64)
        case .image: return NSColor.systemTeal.withAlphaComponent(0.64)
        case .generic: return NSColor.secondaryLabelColor.withAlphaComponent(0.54)
        }
    }

    private static func kind(for filename: String) -> Kind {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["mp4", "mkv", "mov", "m4v", "webm", "avi", "ts"].contains(ext) { return .video }
        if ["mp3", "m4a", "flac", "wav", "aac", "ogg"].contains(ext) { return .audio }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) { return .image }
        if ["pdf", "doc", "docx", "txt", "rtf", "md", "epub"].contains(ext) { return .document }
        if ["dmg", "iso"].contains(ext) { return .diskImage }
        if ["zip", "rar", "7z", "gz", "tar"].contains(ext) { return .archive }
        if ["pkg", "app", "exe", "msi", "apk"].contains(ext) { return .application }
        return .generic
    }
}

private final class ArtifactArtworkView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var tintColor: NSColor? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }

        // Drawn upright inside a generous inset, so no type ever loses an
        // edge to clipping even at the largest interface scale.
        let safeBounds = bounds.insetBy(dx: 24, dy: 22)
        guard safeBounds.width > 0, safeBounds.height > 0 else { return }

        context.saveGState()

        let scale = min(safeBounds.width / image.size.width, safeBounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(
            x: safeBounds.midX - size.width / 2,
            y: safeBounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        if let tintColor {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .sourceIn
            tintColor.setFill()
            NSBezierPath(rect: rect).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        context.restoreGState()
    }
}
