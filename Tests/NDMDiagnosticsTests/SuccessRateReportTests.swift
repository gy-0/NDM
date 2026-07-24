import XCTest
@testable import NDMDiagnostics

final class SuccessRateReportTests: XCTestCase {
    private func outcome(
        _ id: String,
        _ kind: SuccessRateCaseKind = .directFile,
        succeeded: Bool,
        duration: TimeInterval
    ) -> CaseOutcome {
        CaseOutcome(
            caseID: id,
            kind: kind,
            succeeded: succeeded,
            duration: duration,
            failure: succeeded ? nil : "boom"
        )
    }

    func testSuccessRateCountsEveryAttempt() {
        let report = SuccessRateReport(outcomes: [
            outcome("a", succeeded: true, duration: 1),
            outcome("b", succeeded: false, duration: 1),
            outcome("c", succeeded: true, duration: 1),
            outcome("d", succeeded: true, duration: 1),
        ])
        XCTAssertEqual(report.total, 4)
        XCTAssertEqual(report.succeeded, 3)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.successRate, 0.75, accuracy: 0.0001)
    }

    func testEmptyReportIsZeroRatherThanUndefined() {
        let report = SuccessRateReport(outcomes: [])
        XCTAssertEqual(report.successRate, 0)
        XCTAssertNil(report.medianDuration)
        XCTAssertNil(report.p95Duration)
        XCTAssertFalse(report.meetsThreshold(0.01))
    }

    /// The metric is "how long a delivery takes". A link that fails in 200 ms
    /// would otherwise pull the median down and make a broken build look fast.
    func testFailedAttemptsAreExcludedFromDurationStats() {
        let report = SuccessRateReport(outcomes: [
            outcome("fast-failure", succeeded: false, duration: 0.2),
            outcome("slow-success-a", succeeded: true, duration: 10),
            outcome("slow-success-b", succeeded: true, duration: 20),
        ])
        XCTAssertEqual(report.successfulDurations, [10, 20])
        XCTAssertEqual(try XCTUnwrap(report.medianDuration), 15, accuracy: 0.0001)
    }

    func testMedianInterpolatesForEvenSamples() {
        XCTAssertEqual(
            try XCTUnwrap(SuccessRateReport.percentile([1, 2, 3, 4], 0.5)),
            2.5,
            accuracy: 0.0001
        )
    }

    func testMedianOfOddSampleIsTheMiddleValue() {
        XCTAssertEqual(
            try XCTUnwrap(SuccessRateReport.percentile([1, 5, 100], 0.5)),
            5,
            accuracy: 0.0001
        )
    }

    func testPercentileEdgesAreTheExtremes() {
        let sorted: [TimeInterval] = [1, 2, 3, 4, 5]
        XCTAssertEqual(try XCTUnwrap(SuccessRateReport.percentile(sorted, 0)), 1)
        XCTAssertEqual(try XCTUnwrap(SuccessRateReport.percentile(sorted, 1)), 5)
        XCTAssertNil(SuccessRateReport.percentile([], 0.5))
        XCTAssertEqual(try XCTUnwrap(SuccessRateReport.percentile([7], 0.95)), 7)
    }

    func testBreakdownSeparatesTheTwoDeliveryRoutes() {
        let report = SuccessRateReport(outcomes: [
            outcome("file-ok", .directFile, succeeded: true, duration: 1),
            outcome("file-ok-2", .directFile, succeeded: true, duration: 3),
            outcome("page-bad", .mediaPage, succeeded: false, duration: 1),
        ])
        let files = report.breakdown(for: .directFile)
        let pages = report.breakdown(for: .mediaPage)
        XCTAssertEqual(files.successRate, 1)
        XCTAssertEqual(try XCTUnwrap(files.medianDuration), 2, accuracy: 0.0001)
        XCTAssertEqual(pages.successRate, 0)
        XCTAssertNil(pages.medianDuration, "a route with no delivery has no median")
    }

    func testThresholdIsInclusive() {
        let report = SuccessRateReport(outcomes: [
            outcome("a", succeeded: true, duration: 1),
            outcome("b", succeeded: false, duration: 1),
        ])
        XCTAssertTrue(report.meetsThreshold(0.5))
        XCTAssertFalse(report.meetsThreshold(0.51))
    }

    func testRenderNamesFailuresAndTheAggregate() {
        let report = SuccessRateReport(outcomes: [
            outcome("good", succeeded: true, duration: 2),
            outcome("bad", .mediaPage, succeeded: false, duration: 1),
        ])
        let text = report.render()
        XCTAssertTrue(text.contains("[PASS] good"))
        XCTAssertTrue(text.contains("[FAIL] bad"))
        XCTAssertTrue(text.contains("boom"), "a failure must state why")
        XCTAssertTrue(text.contains("1/2"))
        XCTAssertTrue(text.contains("50%"))
    }

    func testByteFormattingScalesUnits() {
        XCTAssertEqual(SuccessRateReport.bytes(512), "512 B")
        // 1_017_723 / 1024 is 993.9, so it stays in KB.
        XCTAssertEqual(SuccessRateReport.bytes(1_017_723), "993.9 KB")
        XCTAssertEqual(SuccessRateReport.bytes(5 * 1024 * 1024), "5.0 MB")
        XCTAssertEqual(SuccessRateReport.bytes(3 * 1024 * 1024 * 1024), "3.0 GB")
    }
}

final class SuccessRateSuiteTests: XCTestCase {
    func testDecodesTheShippedCaseFile() throws {
        // Walk up from this source file so the test does not depend on the
        // process working directory.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let suiteURL = repoRoot
            .appendingPathComponent("Scripts/success-rate-cases.json")
        let suite = try SuccessRateSuite.load(from: suiteURL)
        XCTAssertFalse(suite.cases.isEmpty)
        XCTAssertTrue(
            suite.cases.contains { $0.kind == .directFile },
            "the suite must cover the plain-file engine path"
        )
        XCTAssertTrue(
            suite.cases.contains { $0.kind == .mediaPage },
            "the suite must cover the media extraction path"
        )
        XCTAssertTrue(
            suite.cases.allSatisfy { !($0.url.contains("youtube.com") || $0.url.contains("youtu.be")) },
            "test sources must stay domestic so a failure is not just the network"
        )
    }

    /// A harness that silently drops malformed cases would report a flattering
    /// rate over a shrinking sample, so validation has to be loud.
    func testEmptySuiteIsRejected() {
        XCTAssertThrowsError(try SuccessRateSuite(cases: []).validate()) { error in
            XCTAssertEqual(error as? SuccessRateSuite.ValidationError, .empty)
        }
    }

    func testDuplicateIDsAreRejected() {
        let suite = SuccessRateSuite(cases: [
            SuccessRateCase(id: "same", kind: .directFile, url: "https://example.com/a"),
            SuccessRateCase(id: "same", kind: .directFile, url: "https://example.com/b"),
        ])
        XCTAssertThrowsError(try suite.validate()) { error in
            XCTAssertEqual(
                error as? SuccessRateSuite.ValidationError,
                .duplicateID("same")
            )
        }
    }

    func testUnusableURLsAreRejected() {
        for bad in ["", "not a url", "ftp://example.com/f", "file:///etc/passwd", "https://"] {
            let suite = SuccessRateSuite(cases: [
                SuccessRateCase(id: "c", kind: .directFile, url: bad),
            ])
            XCTAssertThrowsError(try suite.validate(), "\(bad.debugDescription) must be rejected")
        }
    }

    func testRoundTripsThroughJSON() throws {
        let original = SuccessRateSuite(cases: [
            SuccessRateCase(
                id: "c",
                kind: .mediaPage,
                url: "https://www.bilibili.com/video/BV1",
                expectedBytes: 10,
                expectedSHA256: "abc",
                note: "n"
            ),
        ])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(SuccessRateSuite.self, from: data), original)
    }
}
