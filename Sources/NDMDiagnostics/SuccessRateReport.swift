import Foundation

public struct CaseOutcome: Sendable, Equatable {
    public var caseID: String
    public var kind: SuccessRateCaseKind
    public var succeeded: Bool
    /// Wall time from submitting the link to a verified deliverable file.
    public var duration: TimeInterval
    public var bytes: Int64?
    public var failure: String?

    public init(
        caseID: String,
        kind: SuccessRateCaseKind,
        succeeded: Bool,
        duration: TimeInterval,
        bytes: Int64? = nil,
        failure: String? = nil
    ) {
        self.caseID = caseID
        self.kind = kind
        self.succeeded = succeeded
        self.duration = duration
        self.bytes = bytes
        self.failure = failure
    }
}

/// Aggregates the north-star metric: how often a submitted link becomes a usable
/// file, and how long that takes.
public struct SuccessRateReport: Sendable, Equatable {
    public let outcomes: [CaseOutcome]

    public init(outcomes: [CaseOutcome]) {
        self.outcomes = outcomes
    }

    public var total: Int { outcomes.count }
    public var succeeded: Int { outcomes.filter(\.succeeded).count }
    public var failed: Int { total - succeeded }

    public var successRate: Double {
        guard total > 0 else { return 0 }
        return Double(succeeded) / Double(total)
    }

    /// Durations of successful attempts only. A failure's elapsed time is not a
    /// delivery time — a link that dies in 200 ms would otherwise *improve* the
    /// median and make a broken build look fast.
    public var successfulDurations: [TimeInterval] {
        outcomes.filter(\.succeeded).map(\.duration).sorted()
    }

    public var medianDuration: TimeInterval? {
        Self.percentile(successfulDurations, 0.5)
    }

    public var p95Duration: TimeInterval? {
        Self.percentile(successfulDurations, 0.95)
    }

    /// Linear interpolation between closest ranks, matching what most people mean
    /// by "the median" for even-sized samples.
    public static func percentile(_ sorted: [TimeInterval], _ q: Double) -> TimeInterval? {
        guard !sorted.isEmpty else { return nil }
        guard sorted.count > 1 else { return sorted[0] }
        let clamped = min(max(q, 0), 1)
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    public func breakdown(for kind: SuccessRateCaseKind) -> SuccessRateReport {
        SuccessRateReport(outcomes: outcomes.filter { $0.kind == kind })
    }

    public func meetsThreshold(_ minimumSuccessRate: Double) -> Bool {
        successRate >= minimumSuccessRate
    }

    public func render() -> String {
        var lines: [String] = []
        lines.append("Delivery success rate")
        lines.append(String(repeating: "=", count: 46))

        for outcome in outcomes {
            let mark = outcome.succeeded ? "PASS" : "FAIL"
            var line = "  [\(mark)] \(outcome.caseID)  \(Self.seconds(outcome.duration))"
            if let bytes = outcome.bytes {
                line += "  \(Self.bytes(bytes))"
            }
            lines.append(line)
            if let failure = outcome.failure {
                lines.append("         \(failure)")
            }
        }

        lines.append("")
        lines.append("  delivered   \(succeeded)/\(total)  (\(Self.percent(successRate)))")
        lines.append("  median      \(medianDuration.map(Self.seconds) ?? "n/a")")
        lines.append("  p95         \(p95Duration.map(Self.seconds) ?? "n/a")")

        for kind in SuccessRateCaseKind.allCases {
            let sub = breakdown(for: kind)
            guard sub.total > 0 else { continue }
            lines.append(
                "  \(kind.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))"
                    + "\(sub.succeeded)/\(sub.total)  median "
                    + (sub.medianDuration.map(Self.seconds) ?? "n/a")
            )
        }

        return lines.joined(separator: "\n")
    }

    public static func seconds(_ t: TimeInterval) -> String {
        String(format: "%.2fs", t)
    }

    public static func percent(_ r: Double) -> String {
        String(format: "%.0f%%", r * 100)
    }

    public static func bytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(n)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(n) B"
            : String(format: "%.1f %@", value, units[index])
    }
}
