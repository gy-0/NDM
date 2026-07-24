import Foundation

/// What a case exercises. The two kinds take genuinely different routes through
/// the product, so mixing their results into one number would hide which half is
/// broken — the report keeps a per-kind breakdown for that reason.
public enum SuccessRateCaseKind: String, Codable, Sendable, CaseIterable {
    /// A plain HTTP(S) file link: the multi-connection engine path.
    case directFile
    /// A page that needs media extraction: the probe → format → deliver path.
    case mediaPage
}

public struct SuccessRateCase: Codable, Sendable, Equatable {
    public var id: String
    public var kind: SuccessRateCaseKind
    public var url: String
    /// Expected bytes of the delivered file, when the source is immutable.
    public var expectedBytes: Int64?
    /// Expected SHA-256 of the delivered file, when the source is immutable.
    /// This is what separates "a file appeared" from "the right bytes arrived";
    /// without it a truncated or error-page download counts as a success.
    public var expectedSHA256: String?
    public var note: String?

    public init(
        id: String,
        kind: SuccessRateCaseKind,
        url: String,
        expectedBytes: Int64? = nil,
        expectedSHA256: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256
        self.note = note
    }
}

public struct SuccessRateSuite: Codable, Sendable, Equatable {
    public var cases: [SuccessRateCase]

    public init(cases: [SuccessRateCase]) {
        self.cases = cases
    }

    public static func load(from url: URL) throws -> SuccessRateSuite {
        let data = try Data(contentsOf: url)
        let suite = try JSONDecoder().decode(SuccessRateSuite.self, from: data)
        try suite.validate()
        return suite
    }

    public enum ValidationError: LocalizedError, Equatable {
        case empty
        case duplicateID(String)
        case badURL(caseID: String, url: String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "the suite contains no cases"
            case .duplicateID(let id):
                return "duplicate case id \(id.debugDescription)"
            case .badURL(let caseID, let url):
                return "case \(caseID.debugDescription) has an unusable url \(url.debugDescription)"
            }
        }
    }

    /// Fail loudly on a malformed suite. A harness that silently skips broken
    /// cases would report a flattering success rate over a shrinking sample.
    public func validate() throws {
        guard !cases.isEmpty else { throw ValidationError.empty }
        var seen = Set<String>()
        for c in cases {
            guard seen.insert(c.id).inserted else {
                throw ValidationError.duplicateID(c.id)
            }
            guard let url = URL(string: c.url),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil
            else {
                throw ValidationError.badURL(caseID: c.id, url: c.url)
            }
        }
    }
}
