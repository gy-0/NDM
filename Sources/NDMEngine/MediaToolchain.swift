import Foundation

public struct MediaToolComponentStatus: Codable, Equatable, Sendable {
    public let name: String
    public let path: String?
    public let bundled: Bool
    public let ready: Bool
    public let version: String?
}

public struct MediaToolchainReport: Codable, Equatable, Sendable {
    public let ready: Bool
    public let allBundled: Bool
    public let components: [MediaToolComponentStatus]
}

/// Headless release check used by packaging and notarization jobs. The normal
/// product UI never exposes these implementation names to end users.
public enum MediaToolchain {
    public static func inspect() -> MediaToolchainReport {
        let tools: [(name: String, path: String?, args: [String])] = [
            ("yt-dlp", YtDlpTool.find(), ["--version"]),
            ("ffmpeg", FFmpegTool.find(), ["-version"]),
            (
                "deno",
                BundledToolLocator.find(
                    ["deno"],
                    developerFallbacks: ["/opt/homebrew/bin/deno", "/usr/local/bin/deno"]
                ),
                ["--version"]
            ),
        ]
        let roots = bundledToolRoots()
        let components = tools.map { tool -> MediaToolComponentStatus in
            guard let path = tool.path else {
                return MediaToolComponentStatus(
                    name: tool.name,
                    path: nil,
                    bundled: false,
                    ready: false,
                    version: nil
                )
            }
            let result = runVersion(path: path, arguments: tool.args)
            return MediaToolComponentStatus(
                name: tool.name,
                path: path,
                bundled: isInside(path: path, roots: roots),
                ready: result.ready,
                version: result.version
            )
        }
        return MediaToolchainReport(
            ready: components.allSatisfy(\.ready),
            allBundled: components.allSatisfy(\.bundled),
            components: components
        )
    }

    static func isInside(path: String, roots: [URL]) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return roots.contains { root in
            let raw = root.standardizedFileURL.path
            let prefix = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            return candidate == prefix || candidate.hasPrefix(prefix + "/")
        }
    }

    private static func bundledToolRoots() -> [URL] {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL {
            roots.append(resources.appendingPathComponent("Tools", isDirectory: true))
        }
        roots.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/Tools", isDirectory: true)
        )
        return roots
    }

    private static func runVersion(path: String, arguments: [String]) -> (ready: Bool, version: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = [
            "HOME": FileManager.default.temporaryDirectory.path,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let version = text
                .split(whereSeparator: { $0.isNewline })
                .map(String.init)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            return (process.terminationStatus == 0, version)
        } catch {
            return (false, nil)
        }
    }
}
