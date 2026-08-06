import AppKit

/// Small owner for AppKit's share picker. Keeping the picker alive avoids the
/// menu disappearing while the user moves from NDM into AirDrop or Messages.
@MainActor
final class FileSharePresenter: NSObject, @MainActor NSSharingServicePickerDelegate {
    private var picker: NSSharingServicePicker?
    private var onChoose: ((NSSharingService?) -> Void)?

    @discardableResult
    func present(
        fileURL: URL?,
        from anchor: NSView,
        onChoose: ((NSSharingService?) -> Void)? = nil
    ) -> Bool {
        guard let fileURL,
              fileURL.isFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        let picker = NSSharingServicePicker(items: [fileURL])
        self.onChoose = onChoose
        picker.delegate = self
        self.picker = picker
        picker.show(
            relativeTo: anchor.bounds,
            of: anchor,
            preferredEdge: .minY
        )
        return true
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        let callback = onChoose
        onChoose = nil
        callback?(service)

        // A dismissed picker has no reason to stay retained. When a service was
        // chosen, let the current run loop finish handing it off before releasing
        // the picker; this also lets a completion window close safely.
        if service == nil {
            picker = nil
        } else {
            DispatchQueue.main.async { [weak self, weak sharingServicePicker] in
                guard let self,
                      self.picker === sharingServicePicker else { return }
                self.picker = nil
            }
        }
    }
}
