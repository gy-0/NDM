import Foundation

/// One observation of process health during a soak run.
public struct SoakSample: Sendable, Equatable {
    /// Seconds since the run began.
    public var elapsed: TimeInterval
    public var residentBytes: Int64
    public var openFileDescriptors: Int
    /// Rows in the task store. A soak that creates and removes tasks should end
    /// where it started; a rising floor means removal is not actually releasing.
    public var taskRows: Int
    public var completedCycles: Int

    public init(
        elapsed: TimeInterval,
        residentBytes: Int64,
        openFileDescriptors: Int,
        taskRows: Int,
        completedCycles: Int
    ) {
        self.elapsed = elapsed
        self.residentBytes = residentBytes
        self.openFileDescriptors = openFileDescriptors
        self.taskRows = taskRows
        self.completedCycles = completedCycles
    }
}

public struct SoakFinding: Sendable, Equatable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

/// Decides whether a soak run showed unbounded growth.
///
/// Every process grows for a while after start — caches fill, allocators reach a
/// working set. Judging the whole window would flag that normal warm-up as a
/// leak, so a leading fraction is discarded and only the steady-state tail is
/// fitted. A finding also needs to clear an absolute floor, because a percentage
/// of a small baseline is noise.
public struct SoakAnalysis: Sendable {
    public let samples: [SoakSample]
    public let warmupFraction: Double
    public let maxGrowthFraction: Double
    public let minimumAbsoluteGrowthBytes: Int64

    public init(
        samples: [SoakSample],
        warmupFraction: Double = 0.25,
        maxGrowthFraction: Double = 0.25,
        minimumAbsoluteGrowthBytes: Int64 = 8 * 1024 * 1024
    ) {
        self.samples = samples
        self.warmupFraction = min(max(warmupFraction, 0), 0.9)
        self.maxGrowthFraction = maxGrowthFraction
        self.minimumAbsoluteGrowthBytes = minimumAbsoluteGrowthBytes
    }

    /// Samples after the warm-up prefix. Never empty when `samples` is not.
    public var steadyState: [SoakSample] {
        guard !samples.isEmpty else { return [] }
        let drop = Int(Double(samples.count) * warmupFraction)
        let remaining = samples.dropFirst(drop)
        return remaining.isEmpty ? [samples[samples.count - 1]] : Array(remaining)
    }

    /// Least-squares slope of y over elapsed seconds; nil when the window has no
    /// time span to fit against.
    public static func slopePerSecond(
        _ points: [(x: Double, y: Double)]
    ) -> Double? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n
        var numerator = 0.0
        var denominator = 0.0
        for p in points {
            let dx = p.x - meanX
            numerator += dx * (p.y - meanY)
            denominator += dx * dx
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    public var residentSlopeBytesPerSecond: Double? {
        Self.slopePerSecond(
            steadyState.map { (x: $0.elapsed, y: Double($0.residentBytes)) }
        )
    }

    /// Samples from the second half of the steady state.
    public var lateWindow: [SoakSample] {
        let steady = steadyState
        guard steady.count >= 8 else { return steady }
        return Array(steady.suffix(steady.count / 2))
    }

    /// Slope over the late window. A curve that is flattening out fits a line
    /// badly: a run that climbed 10 MB early and then 1 MB over the rest still
    /// reports a frightening average rate. What predicts the next eight hours is
    /// the rate *after* the working set settles, so the verdict uses this and the
    /// report shows both.
    public var lateResidentSlopeBytesPerSecond: Double? {
        Self.slopePerSecond(
            lateWindow.map { (x: $0.elapsed, y: Double($0.residentBytes)) }
        )
    }

    /// The slope the verdict is based on: the late window when it is large enough
    /// to fit, otherwise the whole steady state.
    public var verdictSlopeBytesPerSecond: Double? {
        lateWindow.count >= 4
            ? lateResidentSlopeBytesPerSecond
            : residentSlopeBytesPerSecond
    }

    /// Growth the fitted slope predicts across the measured steady-state window.
    /// Reported rather than extrapolated to eight hours: a linear projection over
    /// a three-minute sample would be a guess dressed as a measurement.
    public var projectedWindowGrowthBytes: Int64? {
        guard let slope = verdictSlopeBytesPerSecond,
              let first = steadyState.first,
              let last = steadyState.last,
              last.elapsed > first.elapsed
        else { return nil }
        return Int64(slope * (last.elapsed - first.elapsed))
    }

    public var baselineResidentBytes: Int64? {
        steadyState.first?.residentBytes
    }

    public var findings: [SoakFinding] {
        var found: [SoakFinding] = []

        if let growth = projectedWindowGrowthBytes,
           let baseline = baselineResidentBytes,
           baseline > 0,
           growth > minimumAbsoluteGrowthBytes,
           Double(growth) / Double(baseline) > maxGrowthFraction {
            let rate = (verdictSlopeBytesPerSecond ?? 0) * 60
            found.append(SoakFinding(
                title: "resident memory grew without settling",
                detail: "\(SuccessRateReport.bytes(growth)) over the measured window "
                    + "(\(SuccessRateReport.bytes(Int64(rate)))/min) from a "
                    + "\(SuccessRateReport.bytes(baseline)) baseline"
            ))
        }

        // File descriptors are the classic soak failure: one unclosed segment
        // handle per cycle stays invisible for minutes and then hits the limit.
        if let first = steadyState.first, let last = steadyState.last,
           last.openFileDescriptors - first.openFileDescriptors > 32 {
            found.append(SoakFinding(
                title: "file descriptors accumulated",
                detail: "\(first.openFileDescriptors) → \(last.openFileDescriptors) "
                    + "across \(last.completedCycles - first.completedCycles) cycles"
            ))
        }

        // Create-then-remove cycles must return the store to its starting size.
        if let first = steadyState.first, let last = steadyState.last,
           last.taskRows - first.taskRows > 0 {
            found.append(SoakFinding(
                title: "task rows were not released",
                detail: "\(first.taskRows) → \(last.taskRows) rows after "
                    + "\(last.completedCycles - first.completedCycles) create/remove cycles"
            ))
        }

        return found
    }

    public var passed: Bool { findings.isEmpty }

    public func render() -> String {
        var lines: [String] = []
        lines.append("Soak stability")
        lines.append(String(repeating: "=", count: 46))

        if let first = samples.first, let last = samples.last {
            lines.append("  duration    \(SuccessRateReport.seconds(last.elapsed - first.elapsed))")
            lines.append("  cycles      \(last.completedCycles)")
            lines.append(
                "  resident    \(SuccessRateReport.bytes(first.residentBytes))"
                    + " → \(SuccessRateReport.bytes(last.residentBytes))"
            )
            lines.append("  descriptors \(first.openFileDescriptors) → \(last.openFileDescriptors)")
            lines.append("  task rows   \(first.taskRows) → \(last.taskRows)")
        }
        lines.append("  samples     \(samples.count) (\(steadyState.count) after warm-up)")
        if let rate = residentSlopeBytesPerSecond {
            lines.append("  trend       \(SuccessRateReport.bytes(Int64(rate * 60)))/min steady-state")
        }
        // Shown separately because a settling curve makes the steady-state average
        // look alarming while the late rate — the one that matters overnight — is
        // near zero.
        if let late = lateResidentSlopeBytesPerSecond,
           lateWindow.count < steadyState.count {
            lines.append("  late trend  \(SuccessRateReport.bytes(Int64(late * 60)))/min (verdict basis)")
        }

        lines.append("")
        if findings.isEmpty {
            lines.append("  no unbounded growth detected")
        } else {
            for finding in findings {
                lines.append("  FINDING: \(finding.title)")
                lines.append("           \(finding.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
