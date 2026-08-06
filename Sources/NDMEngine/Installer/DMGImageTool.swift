import Foundation

/// Errors surfaced by the one-click installer.
///
/// Separate from `EngineError` because these describe a different surface: not
/// a download that failed, but a local install that could not be completed.
public enum InstallerError: Error, LocalizedError, Equatable {
    /// `hdiutil attach` returned no usable mount point.
    case mountFailed(detail: String)
    /// The mounted volume could not be read.
    case enumerationFailed(detail: String)
    /// The chosen app bundle is missing from the mounted volume.
    case appNotFound(app: String)
    /// The copy step failed (permission, disk full, locked file…).
    case copyFailed(detail: String)
    /// `hdiutil detach` failed and the volume may still be mounted.
    case detachFailed(detail: String)
    /// The destination directory does not exist and could not be created.
    case destinationUnavailable(detail: String)
    /// Cancelled by the user or the owning window.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .mountFailed(let d): return "Could not mount the disk image. \(d)"
        case .enumerationFailed(let d): return "Could not read the disk image. \(d)"
        case .appNotFound(let a): return "The app “\(a)” was not found in the disk image."
        case .copyFailed(let d): return "Could not copy the app. \(d)"
        case .detachFailed(let d): return "The disk image could not be unmounted. \(d)"
        case .destinationUnavailable(let d): return "The destination folder is not available. \(d)"
        case .cancelled: return "The install was cancelled."
        }
    }
}

/// Thin wrapper around `hdiutil` for the one-click install path.
///
/// Ported from the *behavior* of Rapidmg 1.3.1 (reverse spec 15). Rapidmg
/// extracts DMGs with an embedded 7-Zip and never mounts; NDM is not sandboxed,
/// so the system `hdiutil` — present on every supported macOS — is the lighter,
/// dependency-free equivalent. The contract that matters is the same: a
/// read-only mount that is *always* detached, even when the caller throws.
public enum DMGImageTool: Sendable {
    struct ProcessResult: Sendable {
        let terminationStatus: Int32
        let standardOutput: String
        let standardError: String
    }

    public static let hdiutil = "/usr/bin/hdiutil"

    /// Mount the image read-only and hidden from Finder; returns the mount point.
    /// The caller must call `detach` (preferably via `withMountedImage`).
    public static func attach(dmgURL: URL, timeout: TimeInterval = 60) throws -> URL {
        let result = try run(
            ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path],
            timeout: timeout
        )
        guard result.terminationStatus == 0,
              let mountPoint = parseMountPoint(plist: result.standardOutput) else {
            throw InstallerError.mountFailed(
                detail: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return URL(fileURLWithPath: mountPoint, isDirectory: true)
    }

    /// Detach the volume; retries with `-force` once for a busy handle.
    public static func detach(mountPoint: URL, timeout: TimeInterval = 60) throws {
        let normal = try run(["detach", mountPoint.path, "-quiet"], timeout: timeout)
        if normal.terminationStatus == 0 { return }
        // Busy volumes (a Finder window, Quick Look, or a lingering helper) fail
        // the first time. Forcing is safe here: the mount is read-only, so there
        // is nothing on the volume to lose.
        let forced = try run(["detach", mountPoint.path, "-force", "-quiet"], timeout: timeout)
        guard forced.terminationStatus == 0 else {
            throw InstallerError.detachFailed(
                detail: forced.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Mount, run `body`, and always detach — including when `body` throws.
    public static func withMountedImage<Result>(
        dmgURL: URL,
        timeout: TimeInterval = 60,
        _ body: (URL) throws -> Result
    ) throws -> Result {
        let mountPoint = try attach(dmgURL: dmgURL, timeout: timeout)
        do {
            let result = try body(mountPoint)
            try detach(mountPoint: mountPoint, timeout: timeout)
            return result
        } catch {
            try? detach(mountPoint: mountPoint, timeout: timeout)
            throw error
        }
    }

    /// Whether the image carries a software license agreement.
    ///
    /// This is the one real sacrifice of the hdiutil approach vs. Rapidmg's
    /// embedded 7-Zip: `hdiutil attach` refuses (or interactively prompts on)
    /// SLA-protected images, while 7-Zip reads them without caring. Detecting
    /// the SLA up front lets the caller hand the image to Disk Image Mounter,
    /// which is the system path that actually shows and records the license.
    public static func hasLicenseAgreement(
        dmgURL: URL, timeout: TimeInterval = 60
    ) throws -> Bool {
        let result = try run(["imageinfo", "-plist", dmgURL.path], timeout: timeout)
        guard result.terminationStatus == 0 else { return false }
        return parseLicenseAgreement(plist: result.standardOutput)
    }

    /// `hdiutil imageinfo -plist` reports the license under `Properties`.
    static func parseLicenseAgreement(plist: String) -> Bool {
        guard let data = plist.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let properties = root["Properties"] as? [String: Any] else {
            return false
        }
        return properties["Software License Agreement"] as? Bool == true
    }

    // MARK: - Parsing

    /// `hdiutil attach -plist` reports mount points inside `system-entities`.
    static func parseMountPoint(plist: String) -> String? {
        guard let data = plist.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else {
            return nil
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return mountPoint
            }
        }
        return nil
    }

    // MARK: - Process plumbing

    static func run(_ arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let stdoutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-hdiutil-out-\(UUID().uuidString)")
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-hdiutil-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        let outHandle = try FileHandle(forWritingTo: stdoutURL)
        let errHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: hdiutil)
        process.arguments = arguments
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let startedAt = Date()
        while process.isRunning, Date().timeIntervalSince(startedAt) < timeout {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? outHandle.synchronize()
        try? errHandle.synchronize()
        return ProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            standardError: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        )
    }
}
