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
    /// Cooldown for "the file is not at its final path yet", which is not the same
    /// thing as "this file cannot produce a picture".
    ///
    /// A row is first painted the moment its task completes, which is *before*
    /// delivery has finished moving the file into place. Blacklisting that for the
    /// full 30s meant the poster never arrived for the download you just watched
    /// finish — the reveal was only ever seen after a relaunch, which is precisely
    /// backwards.
    private let notYetOnDiskRetryDelay: TimeInterval = 1

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
                    CoverArtCache.shared.finishLoad(taskID: taskID, image: image, fresh: false)
                }
                return
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: remote)
                guard let image = NSImage(data: data), image.isValid else {
                    await MainActor.run { CoverArtCache.shared.finishLoad(taskID: taskID, image: nil, fresh: false) }
                    return
                }
                Self.store(image, for: taskID, in: folder)
                await MainActor.run {
                    CoverArtCache.shared.finishLoad(taskID: taskID, image: image, fresh: true)
                }
            } catch {
                await MainActor.run { CoverArtCache.shared.finishLoad(taskID: taskID, image: nil, fresh: false) }
            }
        }
    }

    /// Prefer existing cover; otherwise grab an AVFoundation / Quick Look frame.
    func ensureCover(taskID: Int64, remoteURL: String?, localFile: URL?) {
        guard beginLoad(taskID: taskID) else { return }
        Task.detached(priority: .utility) { [folder] in
            if let image = Self.diskImage(for: taskID, in: folder) {
                await MainActor.run {
                    CoverArtCache.shared.finishLoad(taskID: taskID, image: image, fresh: false)
                }
                return
            }
            if let remoteURL, !remoteURL.isEmpty, let remote = URL(string: remoteURL) {
                do {
                    let (data, _) = try await URLSession.shared.data(from: remote)
                    if let image = NSImage(data: data), image.isValid {
                        Self.store(image, for: taskID, in: folder)
                        await MainActor.run {
                            CoverArtCache.shared.finishLoad(taskID: taskID, image: image, fresh: true)
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
                await MainActor.run {
                    CoverArtCache.shared.finishLoad(
                        taskID: taskID,
                        image: nil,
                        fresh: false,
                        cooldown: CoverArtCache.shared.notYetOnDiskRetryDelay
                    )
                }
                return
            }
            let image: NSImage?
            if let frame = await Self.frameImage(from: localFile) {
                image = frame
            } else {
                image = await Self.quickLookImage(from: localFile)
            }
            guard let image else {
                await MainActor.run { CoverArtCache.shared.finishLoad(taskID: taskID, image: nil, fresh: false) }
                return
            }
            Self.store(image, for: taskID, in: folder)
            await MainActor.run {
                CoverArtCache.shared.finishLoad(taskID: taskID, image: image, fresh: true)
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

    /// - Parameter fresh: this artwork was produced just now (downloaded, or pulled
    ///   out of the finished file), as opposed to read back from the cover cache.
    ///   Only a fresh one is a *moment*: it is the first time this file has ever had
    ///   a picture, which is what the row's poster reveal animates. Reading a cover
    ///   off disk happens on every launch and must stay silent, or the whole list
    ///   would dissolve at once every time the app opens.
    private func finishLoad(
        taskID: Int64,
        image: NSImage?,
        fresh: Bool,
        cooldown: TimeInterval? = nil
    ) {
        inFlight.remove(taskID)
        guard let image else {
            failedUntil[taskID] = Date()
                .addingTimeInterval(cooldown ?? failureCacheDuration)
            return
        }
        failedUntil.removeValue(forKey: taskID)
        memory[taskID] = image
        NotificationCenter.default.post(
            name: Self.didUpdateNotification,
            object: nil,
            userInfo: ["taskID": taskID, "fresh": fresh]
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
