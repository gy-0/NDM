import Foundation

/// Pure eligibility rules for sending a finished download to a transcription app.
/// Keeping this outside AppKit makes the product rule deterministic and testable.
public enum TranscriptionWorkflow: Sendable {
    public static let supportedExtensions: Set<String> = [
        "mp3", "wav", "ogg", "opus", "m4a", "aac", "flac",
        "mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "ts", "mts", "m2ts",
    ]

    public static func supports(fileURL: URL?) -> Bool {
        guard let fileURL, fileURL.isFileURL else { return false }
        return supportedExtensions.contains(fileURL.pathExtension.lowercased())
    }
}
