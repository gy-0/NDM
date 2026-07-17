import Foundation

/// Locates and runs the system ffmpeg for lossless finalize steps
/// (TS → MP4 remux, split A/V track mux). All operations are `-c copy` —
/// no re-encode, so they finish in seconds even for long videos.
public enum FFmpegTool {
    public static func find() -> String? {
        BundledToolLocator.find(
            ["ffmpeg"],
            developerFallbacks: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        )
    }

    /// Repackage a finished stream (usually MPEG-TS) into MP4 without re-encoding.
    /// `+faststart` moves the moov atom up front so the file streams/previews instantly.
    /// Throws `EngineError.mergeFailed` when the source codecs don't fit MP4 —
    /// callers fall back to keeping the original container.
    public static func remuxToMP4(ffmpeg: String, input: URL, output: URL) throws {
        try run(ffmpeg, [
            "-y", "-i", input.path,
            "-c", "copy",
            "-movflags", "+faststart",
            output.path,
        ], cleanupOnFailure: output)
    }

    /// Merge separate video + audio downloads into one container (stream copy).
    public static func muxAV(ffmpeg: String, video: URL, audio: URL, output: URL) throws {
        var args = [
            "-y", "-i", video.path, "-i", audio.path,
            "-c", "copy", "-map", "0:v:0", "-map", "1:a:0?",
        ]
        if output.pathExtension.lowercased() == "mp4" {
            args += ["-movflags", "+faststart"]
        }
        args.append(output.path)
        try run(ffmpeg, args, cleanupOnFailure: output)
    }

    /// Chat-friendly re-encode (H.264 + AAC). Used by Smart Finalize share presets.
    public static func transcodeShare(
        ffmpeg: String,
        input: URL,
        output: URL,
        crf: String,
        maxrate: String
    ) throws {
        try run(ffmpeg, [
            "-y", "-i", input.path,
            "-c:v", "libx264", "-preset", "veryfast", "-crf", crf,
            "-maxrate", maxrate, "-bufsize", maxrate,
            "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart",
            output.path,
        ], cleanupOnFailure: output)
    }

    /// A predictable H.264/AAC MP4 that plays in QuickTime, iPhone apps and
    /// mainstream chat clients. The source is never touched and smaller video
    /// is not intentionally enlarged beyond the 1080p delivery canvas.
    public static func transcodeMobileCompatible(ffmpeg: String, input: URL, output: URL) throws {
        try run(ffmpeg, mobileCompatibleArguments(input: input, output: output), cleanupOnFailure: output)
    }

    /// Extract the primary audio track as a broadly compatible AAC/M4A copy.
    public static func extractAudio(ffmpeg: String, input: URL, output: URL) throws {
        try run(ffmpeg, audioOnlyArguments(input: input, output: output), cleanupOnFailure: output)
    }

    /// Produce a chat-sized H.264 copy. Average bitrate is derived from the
    /// desired file size so a long video is not treated like a short clip.
    public static func transcodeChatFriendly(
        ffmpeg: String,
        input: URL,
        output: URL,
        targetBytes: Int64 = 25 * 1_024 * 1_024
    ) throws {
        let duration = try probeDuration(ffmpeg: ffmpeg, input: input)
        let videoKbps = targetVideoBitrateKbps(duration: duration, targetBytes: targetBytes)
        try run(
            ffmpeg,
            chatFriendlyArguments(input: input, output: output, videoKbps: videoKbps),
            cleanupOnFailure: output
        )
    }

    static func mobileCompatibleArguments(input: URL, output: URL) -> [String] {
        [
            "-n", "-i", input.path,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-vf", "scale=min(1920\\,iw):min(1080\\,ih):force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p",
            "-c:v", "libx264", "-preset", "fast", "-crf", "22",
            "-c:a", "aac", "-b:a", "160k",
            "-movflags", "+faststart",
            output.path,
        ]
    }

    static func audioOnlyArguments(input: URL, output: URL) -> [String] {
        [
            "-n", "-i", input.path,
            "-map", "0:a:0", "-vn",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart",
            output.path,
        ]
    }

    static func chatFriendlyArguments(input: URL, output: URL, videoKbps: Int) -> [String] {
        let rate = "\(videoKbps)k"
        return [
            "-n", "-i", input.path,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-vf", "scale=min(1280\\,iw):min(720\\,ih):force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p",
            "-c:v", "libx264", "-preset", "veryfast", "-b:v", rate,
            "-maxrate", rate, "-bufsize", "\(videoKbps * 2)k",
            "-c:a", "aac", "-b:a", "96k",
            "-movflags", "+faststart",
            output.path,
        ]
    }

    static func targetVideoBitrateKbps(
        duration: Double,
        targetBytes: Int64,
        audioKbps: Int = 96
    ) -> Int {
        guard duration.isFinite, duration > 0, targetBytes > 0 else { return 1_200 }
        let totalKbps = Double(targetBytes) * 8 / duration / 1_000
        // Leave room for audio and container overhead. Extremely long videos
        // keep a minimum watchable bitrate even if that means exceeding 25 MB.
        return min(2_500, max(220, Int(totalKbps - Double(audioKbps) - 24)))
    }

    private static func probeDuration(ffmpeg: String, input: URL) throws -> Double {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-hide_banner", "-i", input.path]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let pattern = #"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 4,
              let hoursRange = Range(match.range(at: 1), in: text),
              let minutesRange = Range(match.range(at: 2), in: text),
              let secondsRange = Range(match.range(at: 3), in: text),
              let hours = Double(text[hoursRange]),
              let minutes = Double(text[minutesRange]),
              let seconds = Double(text[secondsRange]) else {
            throw EngineError.mergeFailed("Could not read media duration")
        }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private static func run(_ ffmpeg: String, _ args: [String], cleanupOnFailure: URL?) throws {
        if let output = cleanupOnFailure, FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            // A failed run may leave a truncated output file behind.
            if let output = cleanupOnFailure {
                try? FileManager.default.removeItem(at: output)
            }
            let data = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .split(separator: "\n").last.map(String.init) ?? "ffmpeg failed"
            throw EngineError.mergeFailed(message)
        }
    }
}
