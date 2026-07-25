import Foundation
import NDMCore

/// Renders results for a terminal or for another program.
///
/// Pure, so the exact bytes a script will parse are pinned by tests rather than
/// discovered by whoever writes the script.
public enum CLIOutput: Sendable {
    /// `2:05`, or `1:02:05` once there is an hour to show. Leading zero hours and
    /// minutes are noise in a list someone is scanning.
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// One line per matching moment, with the match bracketed.
    ///
    /// Brackets rather than ANSI colour: the output has to stay readable when piped
    /// into a file or another program, which is most of why a CLI exists.
    public static func highlighted(_ highlight: SearchHighlight) -> String {
        let characters = Array(highlight.snippet)
        var out = ""
        var cursor = 0
        for range in highlight.ranges {
            let lower = min(max(0, range.lowerBound), characters.count)
            let upper = min(max(lower, range.upperBound), characters.count)
            guard cursor <= lower else { continue }
            out += String(characters[cursor..<lower])
            out += "[" + String(characters[lower..<upper]) + "]"
            cursor = upper
        }
        if cursor < characters.count {
            out += String(characters[cursor...])
        }
        return out
    }

    public struct SearchRow: Equatable, Sendable {
        public let taskID: Int64
        public let name: String
        public let group: SearchResultGroup

        public init(taskID: Int64, name: String, group: SearchResultGroup) {
            self.taskID = taskID
            self.name = name
            self.group = group
        }
    }

    public static func searchText(_ rows: [SearchRow], query: String) -> String {
        guard !rows.isEmpty else {
            return "Nothing matched \(query.debugDescription).\n"
        }
        var lines: [String] = []
        for row in rows {
            var header = row.name
            // Say why it matched. A name-only hit must not look like the words were
            // found inside — that download simply has no transcript yet.
            if row.group.isMetadataOnly {
                header += "  (name only)"
            }
            lines.append(header)
            for snippet in row.group.snippets {
                let position = snippet.startSeconds.map { clock($0) } ?? "—"
                lines.append("  \(position)  \(highlighted(snippet.highlight))")
            }
            if row.group.additionalSnippetCount > 0 {
                lines.append("  + \(row.group.additionalSnippetCount) more")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown, because an outline's most likely destination is somewhere else — a
    /// note, an issue, a message. Plain text that pastes well beats a prettier table.
    public static func chaptersText(
        _ chapters: [TranscriptChapter],
        summary: String?,
        modelAvailable: Bool
    ) -> String {
        guard !chapters.isEmpty else { return "No speech found.\n" }
        var lines: [String] = []
        if let summary {
            lines.append(summary)
            lines.append("")
        } else if !modelAvailable {
            // Explain the absence. A missing summary with no reason reads like a bug.
            lines.append("(No summary: this Mac cannot write one. The outline is still below.)")
            lines.append("")
        }
        for chapter in chapters {
            let name = chapter.title ?? String(chapter.text.prefix(24))
            lines.append("- \(clock(chapter.startSeconds))  \(name)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func chaptersJSON(
        _ chapters: [TranscriptChapter],
        summary: String?,
        modelAvailable: Bool
    ) throws -> String {
        var payload: [String: Any] = [
            "modelAvailable": modelAvailable,
            "chapters": chapters.map { chapter -> [String: Any] in
                var entry: [String: Any] = [
                    "startSeconds": chapter.startSeconds,
                    "at": clock(chapter.startSeconds),
                    "endSeconds": chapter.endSeconds,
                    "segments": chapter.segmentCount,
                    "text": chapter.text,
                ]
                // Omitted rather than blank when unnamed, so a script can tell
                // "no title" from "empty title".
                if let title = chapter.title { entry["title"] = title }
                return entry
            },
        ]
        if let summary { payload["summary"] = summary }
        return try json(payload)
    }

    // MARK: - JSON

    /// A stable shape for scripts. Field names are part of the contract; renaming one
    /// breaks whatever someone automated with it.
    public static func searchJSON(_ rows: [SearchRow], query: String) throws -> String {
        let payload: [String: Any] = [
            "query": query,
            "results": rows.map { row -> [String: Any] in
                [
                    "taskID": row.taskID,
                    "name": row.name,
                    "matchedInContent": row.group.hasSpokenMatch,
                    "hiddenMatches": row.group.additionalSnippetCount,
                    "moments": row.group.snippets.map { snippet -> [String: Any] in
                        var moment: [String: Any] = [
                            "source": snippet.source.rawValue,
                            "text": snippet.highlight.snippet,
                            "matchedTerms": snippet.highlight.matchedTermCount,
                        ]
                        if let start = snippet.startSeconds {
                            moment["startSeconds"] = start
                            moment["at"] = clock(start)
                        }
                        return moment
                    },
                ]
            },
        ]
        return try json(payload)
    }

    public static func transcribeJSON(
        subtitleURL: URL,
        transcriptURL: URL?,
        segmentCount: Int,
        language: String
    ) throws -> String {
        var payload: [String: Any] = [
            "subtitles": subtitleURL.path,
            "segments": segmentCount,
            "language": language,
        ]
        if let transcriptURL { payload["transcript"] = transcriptURL.path }
        return try json(payload)
    }

    public static func errorJSON(_ message: String) -> String {
        (try? json(["error": message])) ?? "{\"error\":\"unprintable\"}"
    }

    private static func json(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
