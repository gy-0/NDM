import XCTest
@testable import NDMDiagnostics

final class SoakAnalysisTests: XCTestCase {
    private func samples(
        resident: [Int64],
        fds: [Int]? = nil,
        rows: [Int]? = nil,
        interval: TimeInterval = 10
    ) -> [SoakSample] {
        resident.enumerated().map { index, bytes in
            SoakSample(
                elapsed: Double(index) * interval,
                residentBytes: bytes,
                openFileDescriptors: fds?[index] ?? 20,
                taskRows: rows?[index] ?? 0,
                completedCycles: index
            )
        }
    }

    private let mb: Int64 = 1024 * 1024

    func testFlatMemoryPasses() {
        let analysis = SoakAnalysis(samples: samples(
            resident: Array(repeating: 120 * mb, count: 20)
        ))
        XCTAssertTrue(analysis.passed)
        XCTAssertEqual(analysis.findings, [])
    }

    func testJitterWithoutTrendPasses() {
        let jitter: [Int64] = (0..<20).map { 120 * mb + Int64(($0 % 5) - 2) * mb }
        let analysis = SoakAnalysis(samples: samples(resident: jitter))
        XCTAssertTrue(analysis.passed, "noise around a stable mean is not a leak")
    }

    func testSteadyClimbIsReported() {
        // 4 MB per sample over 20 samples from a 100 MB base: unmistakable.
        let climbing: [Int64] = (0..<20).map { 100 * mb + Int64($0) * 4 * mb }
        let analysis = SoakAnalysis(samples: samples(resident: climbing))
        XCTAssertFalse(analysis.passed)
        XCTAssertTrue(
            analysis.findings.contains { $0.title.contains("resident memory") },
            "findings were \(analysis.findings)"
        )
    }

    /// Processes grow while caches fill and the allocator reaches a working set.
    /// Judging the whole window would call that normal start-up a leak.
    func testWarmupGrowthFollowedByAPlateauPasses() {
        var series: [Int64] = (0..<8).map { 40 * mb + Int64($0) * 12 * mb }
        series += Array(repeating: 136 * mb, count: 24)
        let analysis = SoakAnalysis(samples: samples(resident: series))
        XCTAssertTrue(
            analysis.passed,
            "warm-up then plateau must pass; findings were \(analysis.findings)"
        )
    }

    /// A percentage of a tiny baseline is noise, so growth must also clear an
    /// absolute floor before it counts.
    func testSmallAbsoluteGrowthIsBelowTheFloor() {
        let series: [Int64] = (0..<20).map { 4 * mb + Int64($0) * 100 * 1024 }
        let analysis = SoakAnalysis(samples: samples(resident: series))
        XCTAssertTrue(
            analysis.passed,
            "sub-floor growth must not be reported; findings were \(analysis.findings)"
        )
    }

    func testDescriptorLeakIsReported() {
        let fds = (0..<20).map { 20 + $0 * 5 }
        let analysis = SoakAnalysis(samples: samples(
            resident: Array(repeating: 120 * mb, count: 20),
            fds: fds
        ))
        XCTAssertFalse(analysis.passed)
        XCTAssertTrue(analysis.findings.contains { $0.title.contains("descriptors") })
    }

    func testSmallDescriptorFluctuationIsTolerated() {
        let fds = (0..<20).map { 20 + ($0 % 4) }
        let analysis = SoakAnalysis(samples: samples(
            resident: Array(repeating: 120 * mb, count: 20),
            fds: fds
        ))
        XCTAssertTrue(analysis.passed)
    }

    func testUnreleasedTaskRowsAreReported() {
        let rows = (0..<20).map { $0 }
        let analysis = SoakAnalysis(samples: samples(
            resident: Array(repeating: 120 * mb, count: 20),
            rows: rows
        ))
        XCTAssertFalse(analysis.passed)
        XCTAssertTrue(analysis.findings.contains { $0.title.contains("task rows") })
    }

    func testTaskRowsReturningToTheStartPasses() {
        let rows = (0..<20).map { $0 % 3 }
        let analysis = SoakAnalysis(samples: samples(
            resident: Array(repeating: 120 * mb, count: 20),
            rows: rows
        ))
        XCTAssertTrue(analysis.passed, "cycling rows up and back down is expected")
    }

    func testSlopeOfAKnownLine() {
        let points = (0..<10).map { (x: Double($0), y: Double($0) * 3 + 7) }
        XCTAssertEqual(try XCTUnwrap(SoakAnalysis.slopePerSecond(points)), 3, accuracy: 1e-9)
    }

    func testSlopeIsUndefinedWithoutASpan() {
        XCTAssertNil(SoakAnalysis.slopePerSecond([]))
        XCTAssertNil(SoakAnalysis.slopePerSecond([(x: 1, y: 1)]))
        XCTAssertNil(
            SoakAnalysis.slopePerSecond([(x: 5, y: 1), (x: 5, y: 9)]),
            "all samples at one instant cannot define a rate"
        )
    }

    func testEmptyRunHasNothingToReportAndDoesNotCrash() {
        let analysis = SoakAnalysis(samples: [])
        XCTAssertTrue(analysis.steadyState.isEmpty)
        XCTAssertNil(analysis.residentSlopeBytesPerSecond)
        XCTAssertNil(analysis.projectedWindowGrowthBytes)
        XCTAssertTrue(analysis.passed)
        XCTAssertFalse(analysis.render().isEmpty)
    }

    func testSteadyStateNeverEmptiesOutANonEmptyRun() {
        let analysis = SoakAnalysis(
            samples: samples(resident: [100 * mb]),
            warmupFraction: 0.9
        )
        XCTAssertEqual(analysis.steadyState.count, 1)
    }

    /// The case that motivated the late window: a real 120s soak climbed
    /// 152 → 162 MB early in the steady state and then only 1.9 MB across the
    /// remaining 54s. Fitting one line to that reported 8.3 MB/min, which over
    /// eight hours would read as multiple gigabytes of leak that is not there.
    func testSettlingCurveIsJudgedOnItsLateRate() {
        let series: [Int64] = [
            152 * mb, 153 * mb, 153 * mb, 160 * mb, 162 * mb, 162 * mb,
            162 * mb, 163 * mb, 163 * mb, 163 * mb, 164 * mb, 164 * mb,
            164 * mb, 164 * mb, 164 * mb, 164 * mb,
        ]
        let analysis = SoakAnalysis(samples: samples(resident: series, interval: 8))
        let steadySlope = try? XCTUnwrap(analysis.residentSlopeBytesPerSecond)
        let lateSlope = try? XCTUnwrap(analysis.lateResidentSlopeBytesPerSecond)
        XCTAssertNotNil(steadySlope)
        XCTAssertNotNil(lateSlope)
        XCTAssertLessThan(
            lateSlope ?? 0,
            (steadySlope ?? 0) / 2,
            "the late rate must reflect the flattening, not the early jump"
        )
        XCTAssertTrue(
            analysis.passed,
            "a curve that settles is not a leak; findings were \(analysis.findings)"
        )
    }

    /// The late window must not launder a genuine leak: a steady climb has the
    /// same slope late as early, so it still gets caught.
    func testLateWindowStillCatchesASteadyClimb() {
        let climbing: [Int64] = (0..<24).map { 100 * mb + Int64($0) * 4 * mb }
        let analysis = SoakAnalysis(samples: samples(resident: climbing))
        XCTAssertFalse(analysis.passed)
        XCTAssertTrue(analysis.findings.contains { $0.title.contains("resident memory") })
    }

    /// A leak that only begins after the warm-up would be hidden by averaging.
    func testGrowthThatStartsLateIsCaught() {
        var series: [Int64] = Array(repeating: 100 * mb, count: 12)
        series += (0..<12).map { 100 * mb + Int64($0) * 6 * mb }
        let analysis = SoakAnalysis(samples: samples(resident: series))
        XCTAssertFalse(
            analysis.passed,
            "a leak beginning late must not be averaged away"
        )
    }

    func testShortRunsFallBackToTheWholeSteadyState() {
        let series: [Int64] = (0..<6).map { 100 * mb + Int64($0) * mb }
        let analysis = SoakAnalysis(samples: samples(resident: series))
        XCTAssertEqual(
            analysis.lateWindow.count,
            analysis.steadyState.count,
            "too few samples to split, so the late window is the whole window"
        )
        XCTAssertEqual(
            analysis.verdictSlopeBytesPerSecond,
            analysis.residentSlopeBytesPerSecond
        )
    }

    func testRenderNamesFindings() {
        let climbing: [Int64] = (0..<20).map { 100 * mb + Int64($0) * 4 * mb }
        let text = SoakAnalysis(samples: samples(resident: climbing)).render()
        XCTAssertTrue(text.contains("FINDING"))
        XCTAssertTrue(text.contains("/min"))
    }

    func testRenderSaysSoWhenClean() {
        let text = SoakAnalysis(
            samples: samples(resident: Array(repeating: 120 * mb, count: 12))
        ).render()
        XCTAssertTrue(text.contains("no unbounded growth detected"))
    }
}
