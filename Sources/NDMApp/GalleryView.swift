import AppKit
import NDMCore

/// Poster-wall card for the media gallery. The cover is the row: aspect-fill
/// artwork with an editorial caption underneath — no chrome, no boxes. Files
/// without artwork fall back to their Finder icon on a quiet plate.
@MainActor
final class GalleryCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GalleryCard")

    var onActivate: ((Int64) -> Void)?

    private let coverHost = NSView()
    /// The artwork lives on an owned sublayer inside the masked plate, so
    /// hover can zoom the image while the rounded frame never moves — AppKit
    /// clobbers transforms on view-backing layers (that was the "corners go
    /// square mid-animation" bug), but leaves our sublayers alone. The plate
    /// frames that sublayer in its own `layout()`, which — unlike the item's
    /// `viewDidLayout` — reliably fires when the flow layout sizes the cell.
    private let coverPlate = CoverPlateView()
    private var imageLayer: CALayer { coverPlate.imageLayer }
    private let iconView = NSImageView()
    private let speedBadge = NSTextField(labelWithString: "")
    private let progressBar = ThinProgressView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private var currentTaskID: Int64?
    private var isHovering = false

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        // Shadow lives on the host; the plate clips the artwork.
        coverHost.wantsLayer = true
        coverHost.layer?.shadowColor = NSColor.black.cgColor
        coverHost.layer?.shadowOpacity = 0.10
        coverHost.layer?.shadowRadius = 8
        coverHost.layer?.shadowOffset = CGSize(width: 0, height: -3)
        coverHost.translatesAutoresizingMaskIntoConstraints = false

        coverPlate.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)

        speedBadge.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        speedBadge.textColor = .white
        speedBadge.alignment = .center
        speedBadge.wantsLayer = true
        speedBadge.layer?.cornerRadius = 6
        speedBadge.layer?.masksToBounds = true
        speedBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        speedBadge.isHidden = true
        speedBadge.translatesAutoresizingMaskIntoConstraints = false

        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(coverHost)
        coverHost.addSubview(coverPlate)
        coverPlate.addSubview(iconView)
        coverHost.addSubview(speedBadge)
        coverHost.addSubview(progressBar)
        view.addSubview(titleLabel)
        view.addSubview(metaLabel)

        NSLayoutConstraint.activate([
            coverHost.topAnchor.constraint(equalTo: view.topAnchor),
            coverHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coverHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coverHost.heightAnchor.constraint(
                equalTo: coverHost.widthAnchor, multiplier: 9.0 / 16.0
            ),
            coverPlate.topAnchor.constraint(equalTo: coverHost.topAnchor),
            coverPlate.leadingAnchor.constraint(equalTo: coverHost.leadingAnchor),
            coverPlate.trailingAnchor.constraint(equalTo: coverHost.trailingAnchor),
            coverPlate.bottomAnchor.constraint(equalTo: coverHost.bottomAnchor),
            iconView.centerXAnchor.constraint(equalTo: coverPlate.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: coverPlate.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),
            speedBadge.topAnchor.constraint(equalTo: coverHost.topAnchor, constant: 8),
            speedBadge.trailingAnchor.constraint(equalTo: coverHost.trailingAnchor, constant: -8),
            speedBadge.heightAnchor.constraint(equalToConstant: 19),
            speedBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            progressBar.leadingAnchor.constraint(equalTo: coverHost.leadingAnchor, constant: 10),
            progressBar.trailingAnchor.constraint(equalTo: coverHost.trailingAnchor, constant: -10),
            progressBar.bottomAnchor.constraint(equalTo: coverHost.bottomAnchor, constant: -10),
            progressBar.heightAnchor.constraint(equalToConstant: 4),
            titleLabel.topAnchor.constraint(equalTo: coverHost.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -2),
        ])

        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(tracking)
    }

    func apply(_ row: TaskRowPresentation, cover: NSImage?) {
        currentTaskID = row.taskID
        titleLabel.stringValue = row.filename

        if let cover {
            imageLayer.contents = cover.layerContents(forContentsScale: view.window?.backingScaleFactor ?? 2)
            coverPlate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
            coverPlate.setTypeTint(nil)
            iconView.isHidden = true
        } else {
            // No artwork: a big centered type glyph tinted to the file's
            // category, on a faint tint wash — a designed placeholder, not a
            // gray void with a stamp-sized Finder icon.
            imageLayer.contents = nil
            let tint = Self.categoryTint(for: row.filename)
            coverPlate.setTypeTint(tint)
            iconView.image = Self.typeGlyph(for: row.filename, tint: tint)
            iconView.contentTintColor = tint.withAlphaComponent(0.9)
            iconView.isHidden = false
        }

        if row.isDownloading {
            progressBar.isHidden = false
            progressBar.progress = row.progressFraction
            progressBar.isActive = true
            let speed = row.speedText
            speedBadge.isHidden = speed == L10n.emDash || speed == "—"
            speedBadge.stringValue = " \(speed) "
            metaLabel.stringValue = "\(row.progressText) · \(row.statusDetail)"
            metaLabel.textColor = .secondaryLabelColor
        } else {
            progressBar.isHidden = true
            progressBar.isActive = false
            speedBadge.isHidden = true
            if row.isFailed {
                metaLabel.stringValue = row.errorText ?? row.statusTitle
                metaLabel.textColor = .secondaryLabelColor
            } else if row.isComplete {
                metaLabel.stringValue = row.sizeText
                metaLabel.textColor = .tertiaryLabelColor
            } else {
                metaLabel.stringValue = "\(row.statusTitle) · \(row.sizeText)"
                metaLabel.textColor = .tertiaryLabelColor
            }
        }
        refreshSelectionChrome()
    }

    override var isSelected: Bool {
        didSet { refreshSelectionChrome() }
    }

    private func refreshSelectionChrome() {
        guard isViewLoaded else { return }
        if isSelected {
            coverPlate.layer?.borderWidth = 2.5
            coverPlate.layer?.borderColor = NDMChrome.accent.cgColor
        } else {
            coverPlate.layer?.borderWidth = 1
            coverPlate.layer?.borderColor = NDMChrome.hairline.cgColor
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        coverHost.layer?.shadowPath = CGPath(
            roundedRect: coverHost.bounds,
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let currentTaskID {
            onActivate?(currentTaskID)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovering(false)
    }

    /// The frame stays perfectly still; the artwork breathes inside it and
    /// the shadow blooms underneath — touching a print in a gallery, not
    /// bouncing a widget.
    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        )
        imageLayer.transform = hovering
            ? CATransform3DMakeScale(1.06, 1.06, 1)
            : CATransform3DIdentity
        coverHost.layer?.shadowOpacity = hovering ? 0.24 : 0.10
        coverHost.layer?.shadowRadius = hovering ? 16 : 8
        if !isSelected {
            coverPlate.layer?.borderColor = hovering
                ? NDMChrome.accent.withAlphaComponent(0.45).cgColor
                : NDMChrome.hairline.cgColor
        }
        CATransaction.commit()
    }

    // MARK: - No-artwork placeholder

    private static func categoryTint(for filename: String) -> NSColor {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "dmg", "iso": return .systemIndigo
        case "pkg", "app", "exe", "msi", "apk": return .systemPurple
        case "zip", "rar", "7z", "gz", "tar": return .systemOrange
        case "pdf", "doc", "docx", "txt", "rtf", "md", "epub": return .systemBlue
        case "mp3", "m4a", "flac", "wav", "aac", "ogg": return .systemPink
        case "html", "htm", "js", "css", "json", "xml": return .systemTeal
        case "mp4", "mkv", "mov", "m4v", "webm", "avi", "ts": return NDMChrome.accent
        default: return .systemGray
        }
    }

    private static func typeGlyph(for filename: String, tint: NSColor) -> NSImage? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let name: String
        switch ext {
        case "dmg", "iso": name = "externaldrive.fill"
        case "pkg", "app", "exe", "msi", "apk": name = "shippingbox.fill"
        case "zip", "rar", "7z", "gz", "tar": name = "archivebox.fill"
        case "mp3", "m4a", "flac", "wav", "aac", "ogg": name = "waveform"
        case "pdf", "doc", "docx", "txt", "rtf", "md", "epub": name = "doc.richtext.fill"
        case "html", "htm", "js", "css", "json", "xml": name = "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": name = "photo.fill"
        case "mp4", "mkv", "mov", "m4v", "webm", "avi", "ts": name = "film.fill"
        default: name = "doc.fill"
        }
        let img = NDMChrome.symbol(name, pointSize: 44, weight: .regular)
        img?.isTemplate = true
        return img
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHovering(false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        imageLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        progressBar.isHidden = true
        progressBar.isActive = false
        speedBadge.isHidden = true
    }
}

/// Masked, rounded artwork plate. Owns an image sublayer and frames it in
/// `layout()` — reliably called by AppKit when the flow layout resizes the
/// cell, unlike `NSCollectionViewItem.viewDidLayout`.
@MainActor
final class CoverPlateView: NSView {
    let imageLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NDMChrome.hairline.cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Faint category wash behind a no-artwork type glyph. nil resets to the
    /// neutral cover backing used under real artwork.
    func setTypeTint(_ tint: NSColor?) {
        guard let tint else {
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
            return
        }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = tint.withAlphaComponent(isDark ? 0.16 : 0.10).cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = bounds
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}

/// Collection view that resolves right-clicks to an item before the shared
/// context menu opens — the menu itself is the same one the list uses.
@MainActor
final class GalleryCollectionView: NSCollectionView {
    var onRightClickItem: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            onRightClickItem?(indexPath.item)
        }
        return super.menu(for: event)
    }
}
