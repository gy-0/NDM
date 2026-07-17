import AppKit

/// Small owner for AppKit's share picker. Keeping the picker alive avoids the
/// menu disappearing while the user moves from NDM into AirDrop or Messages.
@MainActor
final class FileSharePresenter {
    private var picker: NSSharingServicePicker?

    @discardableResult
    func present(fileURL: URL?, from anchor: NSView) -> Bool {
        guard let fileURL,
              fileURL.isFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        let picker = NSSharingServicePicker(items: [fileURL])
        self.picker = picker
        picker.show(
            relativeTo: anchor.bounds,
            of: anchor,
            preferredEdge: .minY
        )
        return true
    }
}
