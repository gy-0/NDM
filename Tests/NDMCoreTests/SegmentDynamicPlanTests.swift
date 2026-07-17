import XCTest
@testable import NDMCore

final class SegmentDynamicPlanTests: XCTestCase {
    func testTailRebalanceWaitsForMeaningfulWorkerDeficitAndBytes() {
        let oneMiB = Int64(1024 * 1024)

        XCTAssertFalse(SegmentFileFormat.shouldRebalanceTail(
            targetConnections: 32,
            activeConnections: 31,
            remainingBytesBySegment: Array(repeating: oneMiB, count: 31)
        ))
        XCTAssertTrue(SegmentFileFormat.shouldRebalanceTail(
            targetConnections: 32,
            activeConnections: 24,
            remainingBytesBySegment: Array(repeating: oneMiB, count: 24)
        ))
        XCTAssertFalse(SegmentFileFormat.shouldRebalanceTail(
            targetConnections: 32,
            activeConnections: 24,
            remainingBytesBySegment: Array(repeating: 128 * 1024, count: 24)
        ))
        XCTAssertFalse(SegmentFileFormat.shouldRebalanceTail(
            targetConnections: 1,
            activeConnections: 0,
            remainingBytesBySegment: [oneMiB]
        ))
    }

    func test4125ObservedPrefixProducesExactFixtureBoundary() {
        let total: Int64 = 18_207_337
        let segs = SegmentFileFormat.planDynamicInitial(
            totalBytes: total,
            completedPrefixBytes: 983_040
        )
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].start, 0)
        XCTAssertEqual(segs[0].end, 9_595_187)
        XCTAssertEqual(segs[1].start, 9_595_188)
        XCTAssertEqual(segs[1].end, total - 1)
    }

    func testDynamicExpansionKeeps4125FirstSplitAndCoversFile() {
        let total: Int64 = 18_207_337
        let segments = SegmentFileFormat.planDynamicConnections(
            totalBytes: total,
            connections: 32,
            completedPrefixBytes: 983_040
        )
        XCTAssertEqual(segments.count, 32)
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.last?.end, total - 1)
        XCTAssertTrue(segments.contains { $0.end == 9_595_187 })
        XCTAssertTrue(segments.contains { $0.start == 9_595_188 })
        for (left, right) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(left.end + 1, right.start)
            XCTAssertEqual(left.nextId, Int32(right.segmentId))
        }
    }

    func testMinSegmentCapsConnections() {
        let segs = SegmentFileFormat.planEqualSegments(totalBytes: 100_000, connections: 32)
        XCTAssertLessThan(segs.count, 32)
        XCTAssertGreaterThanOrEqual(segs.count, 1)
    }

    func testReplanPreservesCompletedPrefix() {
        let total: Int64 = 1_000_000
        let existing = SegmentFileFormat.planEqualSegments(totalBytes: total, connections: 2)
        let completed: [Int16: Int64] = [
            0: existing[0].length, // first fully done
            1: existing[1].length / 2,
        ]
        let replanned = SegmentFileFormat.replanConnections(
            existing: existing,
            totalBytes: total,
            newConnections: 4,
            completedByID: completed
        )
        XCTAssertFalse(replanned.isEmpty)
        XCTAssertEqual(replanned.first?.start, 0)
        XCTAssertEqual(replanned.last?.end, total - 1)
        XCTAssertEqual(replanned.first?.segmentId, existing[0].segmentId)
        XCTAssertTrue(replanned.contains {
            $0.segmentId == existing[1].segmentId
                && $0.start == existing[1].start
                && $0.length == completed[existing[1].segmentId]
        })
        XCTAssertEqual(Set(replanned.map(\.segmentId)).count, replanned.count)
        for (left, right) in zip(replanned, replanned.dropFirst()) {
            XCTAssertEqual(left.end + 1, right.start)
            XCTAssertEqual(left.nextId, Int32(right.segmentId))
        }
    }
}
