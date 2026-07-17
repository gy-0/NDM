import Foundation

/// Locates and runs the system ffmpeg for lossless finalize steps
/// (TS → MP4 remux, split A/V track mux). All operations are `-c copy` —
/// no re-encode, so they finish in seconds even for long videos.
public enum FFmpegTool {
    public static func find() -> String? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
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
