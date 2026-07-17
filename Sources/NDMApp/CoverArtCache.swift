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
    private let folder: URL

    private init() {
        let support = DownloadStore.defaultSupportDirectory
        folder = support.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func image(for taskID: Int64) -> NSImage? {
        if let cached = memory[taskID] { return cached }
        let url = folder.appendingPathComponent("\(taskID).jpg")
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return nil }
        memory[taskID] = image
        return image
    }

    func prefetchRemote(taskID: Int64, urlString: String) {
        guard memory[taskID] == nil, !inFlight.contains(taskID) else { return }
        guard let remote = URL(string: urlString) else { return }
        inFlight.insert(taskID)
        Task.detached(priority: .utility) { [folder] in
            defer {
                Task { @MainActor in CoverArtCache.shared.inFlight.remove(taskID) }
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: remote)
                guard let image = NSImage(data: data), image.isValid else { return }
                let dest = folder.appendingPathComponent("\(taskID).jpg")
                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
                    try jpeg.write(to: dest, options: .atomic)
                }
                await MainActor.run {
                    CoverArtCache.shared.memory[taskID] = image
                    NotificationCenter.default.post(
                        name: CoverArtCache.didUpdateNotification,
                        object: nil,
                        userInfo: ["taskID": taskID]
                    )
                }
            } catch {
                // Soft-fail — list still works with type glyph.
            }
        }
    }

    /// Prefer existing cover; otherwise grab an AVFoundation / Quick Look frame.
    func ensureCover(taskID: Int64, remoteURL: String?, localFile: URL?) {
        if image(for: taskID) != nil { return }
        if let remoteURL, !remoteURL.isEmpty {
            prefetchRemote(taskID: taskID, urlString: remoteURL)
            return
        }
        guard let localFile,
              FileManager.default.fileExists(atPath: localFile.path),
              !inFlight.contains(taskID) else { return }
        inFlight.insert(taskID)
        Task.detached(priority: .utility) { [folder] in
            defer {
                Task { @MainActor in CoverArtCache.shared.inFlight.remove(taskID) }
            }
            let image: NSImage?
            if let frame = await Self.frameImage(from: localFile) {
                image = frame
            } else {
                image = await Self.quickLookImage(from: localFile)
            }
            guard let image else { return }
            let dest = folder.appendingPathComponent("\(taskID).jpg")
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
                try? jpeg.write(to: dest, options: .atomic)
            }
            await MainActor.run {
                CoverArtCache.shared.memory[taskID] = image
                NotificationCenter.default.post(
                    name: CoverArtCache.didUpdateNotification,
                    object: nil,
                    userInfo: ["taskID": taskID]
                )
            }
        }
    }

    static let didUpdateNotification = Notification.Name("NDMCoverArtDidUpdate")

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
