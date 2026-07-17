import Foundation

/// A product-facing result for links pasted as either a URL or a social share message.
public struct SharedLinkResolution: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case youtube
        case bilibili
        case douyin
        case xiaohongshu
        case tiktok
        case web
    }

    public let urlString: String
    public let source: Source
    public let wasExtractedFromText: Bool

    public init(urlString: String, source: Source, wasExtractedFromText: Bool) {
        self.urlString = urlString
        self.source = source
        self.wasExtractedFromText = wasExtractedFromText
    }
}

/// Turns copied share messages into a clean URL without making the user hunt
/// through Chinese copy, hashtags, timestamps, or app-specific command text.
public enum SharedLinkResolver {
    private static let maximumInputLength = 32_768
    private static let urlExpression = try! NSRegularExpression(
        pattern: #"(?i)(?:https?|ftp)://[^\s<>\"'，。；：！？）》】」』、]+"#
    )
    private static let knownHostExpression = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w.])(?:v\.douyin\.com|www\.douyin\.com|xhslink\.com|www\.xiaohongshu\.com|b23\.tv|www\.bilibili\.com|youtu\.be|www\.youtube\.com)/[^\s<>\"'，。；：！？）》】」』、]+"#
    )
    private static let tiktokHostExpression = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w.])(?:vm\.tiktok\.com|vt\.tiktok\.com|www\.tiktok\.com)/[^\s<>\"'，。；：！？）》】」』、]+"#
    )
    private static let trailingPunctuation = CharacterSet(
        charactersIn: ".,;:!?)]}>，。；：！？）》】」』、"
    )

    public static func resolve(_ raw: String) -> SharedLinkResolution? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= maximumInputLength else { return nil }

        var candidates = matches(in: trimmed, expression: urlExpression, prependHTTPS: false)
        candidates.append(contentsOf: matches(
            in: trimmed,
            expression: knownHostExpression,
            prependHTTPS: true
        ))
        candidates.append(contentsOf: matches(
            in: trimmed,
            expression: tiktokHostExpression,
            prependHTTPS: true
        ))

        var seen: Set<String> = []
        let unique = candidates.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }

        // A share message can contain an unrelated tracking/help URL too. Give
        // known media hosts priority, then preserve the original visual order.
        let ranked = unique.enumerated().compactMap { index, candidate -> (Int, Int, String, SharedLinkResolution.Source)? in
            guard let url = URL(string: candidate),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ftp"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty else { return nil }
            let source = source(for: host)
            let hostRank = source == .web ? 1 : 0
            return (hostRank, index, candidate, source)
        }.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }

        guard let selected = ranked.first else { return nil }
        let direct = normalizedForComparison(trimmed) == normalizedForComparison(selected.2)
        return SharedLinkResolution(
            urlString: selected.2,
            source: selected.3,
            wasExtractedFromText: !direct
        )
    }

    private static func matches(
        in text: String,
        expression: NSRegularExpression,
        prependHTTPS: Bool
    ) -> [String] {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.range.location != NSNotFound else { return nil }
            var candidate = nsText.substring(with: match.range)
            while let scalar = candidate.unicodeScalars.last,
                  trailingPunctuation.contains(scalar) {
                candidate.removeLast()
            }
            guard !candidate.isEmpty else { return nil }
            return prependHTTPS && !candidate.contains("://")
                ? "https://\(candidate)"
                : candidate
        }
    }

    private static func source(for host: String) -> SharedLinkResolution.Source {
        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
            return .youtube
        }
        if host == "b23.tv" || host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
            return .bilibili
        }
        if host == "douyin.com" || host.hasSuffix(".douyin.com") || host.hasSuffix(".iesdouyin.com") {
            return .douyin
        }
        if host == "xhslink.com" || host.hasSuffix(".xhslink.com")
            || host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com") {
            return .xiaohongshu
        }
        if host == "tiktok.com" || host.hasSuffix(".tiktok.com") {
            return .tiktok
        }
        return .web
    }

    private static func normalizedForComparison(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: trailingPunctuation)
    }
}
