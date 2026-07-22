import AppKit
import AVFoundation
import QuickLookThumbnailing
import NDMCore

/// Disk + memory cover art for download list rows (remote yt-dlp thumb → local frame).
@MainActor
final class CoverArtCache {
    static let shared = CoverArtCache()

    private var memory: [Int64: NSImage] = [:]
    private var inFlight: Set<Int64> = []
    private var failedUntil: [Int64: Date] = [:]
    private var folder: URL
    private let failureCacheDuration: TimeInterval = 30

    private init() {
        let support = DownloadStore.defaultSupportDirectory
        folder = support.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Keep artwork in the same support root as the task database. This is
    /// essential for isolated QA runs and also prevents a future alternate
    /// profile from reading or overwriting another profile's cover cache.
    func configure(supportRoot: URL) {
        let next = supportRoot.appendingPathComponent("covers", isDirectory: true)
            .standardizedFileURL
        guard next != folder.standardizedFileURL else { return }
        folder = next
        memory.removeAll()
        failedUntil.removeAll()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func image(for taskID: Int64) -> NSImage? {
        if let cached = memory[taskID] { return cached }
        let onDisk = Self.diskImage(for: taskID, in: folder)
        if let onDisk { memory[taskID] = onDisk }
        return onDisk
    }

    func prefetchRemote(taskID: Int64, urlString: String) {
        guard let remote = URL(string: urlString), beginLoad(taskID: taskID) else { return }
        Task.detached(priority: .utility) { [folder] in
            if let image = Self.diskImage(for: taskID, in: folder) {
                await MainActor.run {
                    CoverArtCache.shared.finishLoad(taskID: taskID, image: image)
                }
                return
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: remote)
                guard let image = NSImage(data: data), image.isValid else {
                    await MainActor.run { CoverArtCache.shared.finishLoad(taskID: taskID, image: nil) }
                    return
                }
                Self.store(image, for: taskID, in: folder)
                await MainActor.run {
                    CoverArtCache.shared.finishLoad(taskID: taskID, image: image)
                }
            } catch {
                await MainActor.run { CoverArtCache.shared.finishLoad(taskID: taskID, image: nil) }
            }
        }
    }

    /// Prefer existing cover; otherwise grab an AVFoundation / Quick Look frame.
    func ensureCover(taskID: Int64, remoteURL: String?, localFile: URL?) {
        guard beginLoad(taskID: taskID) else { return }
        Task.detached(priority: .utility) { [folder] in
            if let image = Self.diskImage(for: taskID, in: folder) {
                await MainActor.run {
                    CoverArtCache.shared.finishLoad(taskID: taskID, image: image)
                }
                return
            }
            if let remoteURL, !remoteURL.isEmpty, let remote = URL(string: remoteURL) {
                do {
                    let (data, _) = try await URLSession.shared.data(from: remote)
                    if let image = NSImage(data: data), image.isValid {
                        Self.store(image, for: taskID, in: folder)
                        await MainActor.run {
                            CoverArtCache.shared.finishLoad(taskID: taskID, image: image)
                        }
                        return
                    }
                } catch {
                    // Soft-fail into the local-file path below. A stale remote
                    // thumbnail must not prevent a completed video/PDF/image
                    // from producing its own on-disk preview.
                }
            }
            guard let localFile,
                  FileManager.default.fileExists(atPath: localFile.path) else {
                await MainActor.run { CoverArtCache.shared.finishLoad(taskID: taskID, image: nil) }
                return
            }
            let image: NSImage?
            if let frame = await Self.frameImage(from: localFile) {
                image = frame
            } else {
                image = await Self.quickLookImage(from: localFile)
            }
            guard let image else {
                await MainActor.run { CoverArtCache.shared.finishLoad(taskID: taskID, image: nil) }
                return
            }
            Self.store(image, for: taskID, in: folder)
            await MainActor.run {
                CoverArtCache.shared.finishLoad(taskID: taskID, image: image)
            }
        }
    }

    static let didUpdateNotification = Notification.Name("NDMCoverArtDidUpdate")

    private func beginLoad(taskID: Int64) -> Bool {
        guard memory[taskID] == nil, !inFlight.contains(taskID) else { return false }
        if let failedUntil = failedUntil[taskID] {
            guard failedUntil <= Date() else { return false }
            self.failedUntil.removeValue(forKey: taskID)
        }
        inFlight.insert(taskID)
        return true
    }

    private func finishLoad(taskID: Int64, image: NSImage?) {
        inFlight.remove(taskID)
        guard let image else {
            failedUntil[taskID] = Date().addingTimeInterval(failureCacheDuration)
            return
        }
        failedUntil.removeValue(forKey: taskID)
        memory[taskID] = image
        NotificationCenter.default.post(
            name: Self.didUpdateNotification,
            object: nil,
            userInfo: ["taskID": taskID]
        )
    }

    nonisolated private static func diskImage(for taskID: Int64, in folder: URL) -> NSImage? {
        let url = folder.appendingPathComponent("\(taskID).jpg")
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data),
              image.isValid else { return nil }
        return image
    }

    nonisolated private static func store(_ image: NSImage, for taskID: Int64, in folder: URL) {
        let dest = folder.appendingPathComponent("\(taskID).jpg")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
        try? jpeg.write(to: dest, options: .atomic)
    }

    private static func frameImage(from url: URL) async -> NSImage? {
        let ext = url.pathExtension.lowercased()
        let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi"]
        guard videoExts.contains(ext) else { return nil }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        let time = CMTime(seconds: 1.2, preferredTimescale: 600)
        do {
            let (cg, _) = try await gen.image(at: time)
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } catch {
            return nil
        }
    }

    private static func quickLookImage(from url: URL) async -> NSImage? {
        await withCheckedContinuation { cont in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 480, height: 270),
                scale: 2,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
    }
}
