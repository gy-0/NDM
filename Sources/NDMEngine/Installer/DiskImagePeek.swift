import Foundation
import NDMCore

/// Read-only look inside a disk image for the app a download row should show.
///
/// The list must not use the generic disk-image glyph: a finished `.dmg` is
/// the app the user downloaded, and the row should carry that app's icon.
/// Mount is hidden from Finder, always detached, and skipped entirely when
/// the image carries a software license agreement (peeking must not bypass it).
public enum DiskImagePeek: Sendable {
    /// Mount `dmgURL`, run `body` with the primary app bundle still on the
    /// volume, then detach. Returns `nil` when there is no app to show.
    public static func withPrimaryApp<Result: Sendable>(
        dmgURL: URL,
        _ body: @Sendable (URL) async throws -> Result
    ) async throws -> Result? {
        if try DMGImageTool.hasLicenseAgreement(dmgURL: dmgURL) {
            return nil
        }
        let mountPoint = try DMGImageTool.attach(dmgURL: dmgURL)
        defer { try? DMGImageTool.detach(mountPoint: mountPoint) }
        let entries = VolumeEnumerator.entries(in: mountPoint)
        let plan = InstallerPlan.make(kind: .dmg, entries: entries)
        let relative: String?
        switch plan {
        case .install(let app):
            relative = app
        case .chooseApp(let candidates):
            relative = InstallerPlan.preferredApp(
                candidates: candidates,
                filename: dmgURL.lastPathComponent
            )
        case .noAppFound, .notApplicable:
            relative = nil
        }
        guard let relative else { return nil }
        let appURL = mountPoint.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }
        return try await body(appURL)
    }
}
