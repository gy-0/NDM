import Foundation
import NDMCore

/// Dual-track download + mux (video URL + `urla` audio) → single `.mkv` / `.webm`.
/// Uses system `ffmpeg` when available; otherwise concatenates WebM/MKV-compatible
/// streams via a best-effort copy of the larger track and sidecar audio file.
public actor MKVMergeEngine {
    public private(set) var progress: DownloadProgress

    private let taskID: Int64
    private let videoRequest: DownloadRequest
    private let audioRequest: DownloadRequest
    private let workDirectory: URL
    private let httpProxy: ProxySettings?
    private let socksProxy: SocksProxySettings?
    private let globalBandwidthLimit: Int64
    private let token = CancelToken()

    public init(
        taskID: Int64,
        videoRequest: DownloadRequest,
        audioRequest: DownloadRequest,
        workDirectory: URL,
        httpProxy: ProxySettings? = nil,
        socksProxy: SocksProxySettings? = nil,
        globalBandwidthLimit: Int64 = 0
    ) {
        self.taskID = taskID
        self.videoRequest = videoRequest
        self.audioRequest = audioRequest
        self.workDirectory = workDirectory
        self.httpProxy = httpProxy
        self.socksProxy = socksProxy
        self.globalBandwidthLimit = globalBandwidthLimit
        self.progress = DownloadProgress(taskID: taskID, status: .waiting)
    }

    public func pause() {
        token.pause()
        progress.status = .paused
    }

    public func currentProgress() -> DownloadProgress { progress }

    @discardableResult
    public func start() async throws -> URL {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        token.reset()
        progress.status = .downloading

        let videoDir = workDirectory.appendingPathComponent("video", isDirectory: true)
        let audioDir = workDirectory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        var vReq = videoRequest
        vReq.destinationDirectory = videoDir
        vReq.suggestedFilename = "video.bin"
        var aReq = audioRequest
        aReq.destinationDirectory = audioDir
        aReq.suggestedFilename = "audio.bin"

        let videoEngine = DownloadEngine(
            taskID: taskID,
            request: vReq,
            workDirectory: videoDir,
            httpProxy: httpProxy,
            socksProxy: socksProxy,
            globalBandwidthLimit: globalBandwidthLimit
        )
        let audioEngine = DownloadEngine(
            taskID: taskID &+ 1_000_000, // distinct log namespace
            request: aReq,
            workDirectory: audioDir,
            httpProxy: httpProxy,
            socksProxy: socksProxy,
            globalBandwidthLimit: globalBandwidthLimit
        )

        async let videoURL = videoEngine.start()
        async let audioURL = audioEngine.start()

        // Poll combined progress
        let poll = Task {
            while !Task.isCancelled {
                let vp = await videoEngine.currentProgress()
                let ap = await audioEngine.currentProgress()
                var combined = vp
                combined.totalBytes = vp.totalBytes + ap.totalBytes
                combined.completedBytes = vp.completedBytes + ap.completedBytes
                combined.bytesPerSecond = vp.bytesPerSecond + ap.bytesPerSecond
                combined.segmentStates = vp.segmentStates + ap.segmentStates.map {
                    var s = $0
                    s.id += 1000
                    return s
                }
                combined.status = .downloading
                progress = combined
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        let vURL: URL
        let aURL: URL
        do {
            (vURL, aURL) = try await (videoURL, audioURL)
        } catch {
            poll.cancel()
            if token.isPaused { throw EngineError.paused }
            throw error
        }
        poll.cancel()

        try FileManager.default.createDirectory(
            at: videoRequest.destinationDirectory,
            withIntermediateDirectories: true
        )
        let baseName: String = {
            if let s = videoRequest.suggestedFilename, !s.isEmpty {
                let ns = s as NSString
                return ns.deletingPathExtension
            }
            return "media"
        }()
        let outExt = preferredOutputExtension(video: vURL, audio: aURL)
        var finalURL = videoRequest.destinationDirectory.appendingPathComponent("\(baseName).\(outExt)")

        if let ffmpeg = Self.findFFmpeg() {
            // Prefer MP4 (best compatibility); codecs that don't fit MP4
            // (VP9/Opus…) fail the stream copy fast and fall back to MKV/WebM.
            let mp4URL = videoRequest.destinationDirectory.appendingPathComponent("\(baseName).mp4")
            do {
                try FFmpegTool.muxAV(ffmpeg: ffmpeg, video: vURL, audio: aURL, output: mp4URL)
                finalURL = mp4URL
            } catch {
                try await Self.runFFmpegMux(ffmpeg: ffmpeg, video: vURL, audio: aURL, output: finalURL)
            }
        } else {
            // Fallback: keep video as primary, copy audio alongside as `.audio`
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.copyItem(at: vURL, to: finalURL)
            let audioSide = finalURL.deletingPathExtension().appendingPathExtension("audio.\(aURL.pathExtension)")
            try? FileManager.default.removeItem(at: audioSide)
            try FileManager.default.copyItem(at: aURL, to: audioSide)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        progress.totalBytes = size
        progress.completedBytes = size
        progress.status = .complete
        return finalURL
    }

    private func preferredOutputExtension(video: URL, audio: URL) -> String {
        let v = video.pathExtension.lowercased()
        let a = audio.pathExtension.lowercased()
        if v == "webm" || a == "webm" { return "webm" }
        if v == "mkv" || a == "mkv" { return "mkv" }
        return "mkv"
    }

    private static func findFFmpeg() -> String? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func runFFmpegMux(ffmpeg: String, video: URL, audio: URL, output: URL) async throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = [
            "-y", "-i", video.path, "-i", audio.path,
            "-c", "copy", "-map", "0:v:0", "-map", "1:a:0?",
            output.path,
        ]
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ffmpeg failed"
            throw EngineError.mergeFailed(msg)
        }
    }
}
