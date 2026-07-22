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
    private let coverPlate = NSView()
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

        coverPlate.wantsLayer = true
        coverPlate.layer?.cornerRadius = 12
        coverPlate.layer?.masksToBounds = true
        coverPlate.layer?.contentsGravity = .resizeAspectFill
        coverPlate.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

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
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),
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
            coverPlate.layer?.contents = cover.layerContents(forContentsScale: view.window?.backingScaleFactor ?? 2)
            coverPlate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
            iconView.isHidden = true
        } else {
            coverPlate.layer?.contents = nil
            coverPlate.layer?.backgroundColor = NDMChrome.track.cgColor
            iconView.image = NDMChrome.fileIcon(filename: row.filename, pointSize: 52)
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

    /// Poster lift — the card answers the pointer like a physical object.
    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        guard let layer = coverHost.layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.3, 0.9, 0.3, 1)
        )
        if hovering {
            let lift = CATransform3DConcat(
                CATransform3DMakeScale(1.025, 1.025, 1),
                CATransform3DMakeTranslation(0, 2, 0)
            )
            layer.transform = lift
            layer.shadowOpacity = 0.22
            layer.shadowRadius = 14
        } else {
            layer.transform = CATransform3DIdentity
            layer.shadowOpacity = 0.10
            layer.shadowRadius = 8
        }
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHovering(false)
        coverPlate.layer?.contents = nil
        progressBar.isHidden = true
        progressBar.isActive = false
        speedBadge.isHidden = true
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
