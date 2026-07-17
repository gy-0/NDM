import Foundation

/// On-disk layout of `segments.bin` (24-byte records), recovered from runtime samples
/// and verified against LogFile Range lines (task 4125).
///
/// ```c
/// struct NeatSegmentRecord {
///   int16_t orderOrId;
///   int16_t segmentId;   // → seg.x{segmentId}
///   int32_t nextId;      // -1 = end
///   int64_t start;       // inclusive
///   int64_t end;         // inclusive
/// };
/// ```
public struct SegmentRecord: Equatable, Sendable {
    public var order: Int16
    public var segmentId: Int16
    public var nextId: Int32
    public var start: Int64
    public var end: Int64

    public static let recordSize = 24
    public static let endOfList: Int32 = -1

    public init(order: Int16, segmentId: Int16, nextId: Int32, start: Int64, end: Int64) {
        self.order = order
        self.segmentId = segmentId
        self.nextId = nextId
        self.start = start
        self.end = end
    }

    public var length: Int64 {
        max(0, end - start + 1)
    }

    public var rangeHeader: String {
        if end < 0 {
            return "bytes=\(start)-"
        }
        return "bytes=\(start)-\(end)"
    }
}

public enum SegmentFileFormat {
    public static func parse(_ data: Data) throws -> [SegmentRecord] {
        guard data.count % SegmentRecord.recordSize == 0 else {
            throw SegmentError.invalidSize(data.count)
        }
        var records: [SegmentRecord] = []
        records.reserveCapacity(data.count / SegmentRecord.recordSize)
        var offset = 0
        while offset < data.count {
            let order = readI16(data, offset)
            let segId = readI16(data, offset + 2)
            let next = readI32(data, offset + 4)
            let start = readI64(data, offset + 8)
            let end = readI64(data, offset + 16)
            records.append(SegmentRecord(order: order, segmentId: segId, nextId: next, start: start, end: end))
            offset += SegmentRecord.recordSize
        }
        return records
    }

    public static func serialize(_ records: [SegmentRecord]) -> Data {
        var data = Data(capacity: records.count * SegmentRecord.recordSize)
        for r in records {
            appendI16(&data, r.order)
            appendI16(&data, r.segmentId)
            appendI32(&data, r.nextId)
            appendI64(&data, r.start)
            appendI64(&data, r.end)
        }
        return data
    }

    /// Minimum remaining bytes worth spinning a new connection (behavioural stand-in for G01).
    public static let minSegmentBytes: Int64 = 256 * 1024

    /// Decide whether a static Range round has entered its straggler tail.
    ///
    /// The original engine keeps recycling idle sockets into unfinished ranges.
    /// URLSession cannot safely shorten an in-flight response, so the clean-room
    /// engine rebalances in bounded rounds instead: once a quarter of the worker
    /// pool has gone idle, cancel the remaining requests, preserve every written
    /// prefix, split the holes again, and refill the pool. The byte guards avoid
    /// spending more time reconnecting than downloading near the true end.
    public static func shouldRebalanceTail(
        targetConnections: Int,
        activeConnections: Int,
        remainingBytesBySegment: [Int64]
    ) -> Bool {
        let target = max(1, min(targetConnections, 32))
        guard target > 1,
              activeConnections > 0,
              activeConnections < target else {
            return false
        }

        let positive = remainingBytesBySegment.filter { $0 > 0 }
        guard !positive.isEmpty else { return false }

        // A 32-worker round rebalances at 24 active workers. Smaller pools use
        // the same ratio, with at least one live worker left to steal from.
        let idleThreshold = max(1, target * 3 / 4)
        guard activeConnections <= idleThreshold else { return false }

        let totalRemaining = positive.reduce(Int64(0), +)
        let largestRemaining = positive.max() ?? 0
        return totalRemaining >= minSegmentBytes * Int64(target)
            && largestRemaining >= minSegmentBytes * 2
    }

    /// Split total file size into `connections` contiguous inclusive ranges (original starts with 1 then grows).
    public static func planEqualSegments(totalBytes: Int64, connections: Int) -> [SegmentRecord] {
        guard totalBytes > 0 else { return [] }
        let n = max(1, min(connections, 32))
        if n == 1 {
            return [SegmentRecord(order: 0, segmentId: 0, nextId: SegmentRecord.endOfList, start: 0, end: totalBytes - 1)]
        }
        // Cap connections by min segment size (dynamic split threshold).
        var effective = n
        while effective > 1, totalBytes / Int64(effective) < minSegmentBytes {
            effective -= 1
        }
        let part = totalBytes / Int64(effective)
        var segs: [SegmentRecord] = []
        for i in 0..<effective {
            let start = Int64(i) * part
            let end = (i == effective - 1) ? (totalBytes - 1) : (start + part - 1)
            let next: Int32 = (i == effective - 1) ? SegmentRecord.endOfList : Int32(i + 1)
            segs.append(SegmentRecord(order: Int16(i), segmentId: Int16(i), nextId: next, start: start, end: end))
        }
        return segs
    }

    /// Original behaviour: socket 1 has already received a prefix while socket 2 is
    /// connecting, then socket 2 steals half of the *remaining* interval.
    ///
    /// Task 4125 proves the timing-dependent form: after 983,040 bytes were received,
    /// `(983_040 + 18_207_337) / 2 == 9_595_188`, exactly matching the second Range
    /// and the persisted `segments.bin` boundary.
    public static func planDynamicInitial(
        totalBytes: Int64,
        completedPrefixBytes: Int64 = 0
    ) -> [SegmentRecord] {
        guard totalBytes > 0 else { return [] }
        guard totalBytes > 1 else {
            return planEqualSegments(totalBytes: totalBytes, connections: 1)
        }
        let prefix = min(max(0, completedPrefixBytes), totalBytes - 2)
        let mid = prefix + (totalBytes - prefix) / 2
        return [
            SegmentRecord(order: 0, segmentId: 0, nextId: 1, start: 0, end: mid - 1),
            SegmentRecord(order: 1, segmentId: 1, nextId: SegmentRecord.endOfList, start: mid, end: totalBytes - 1),
        ]
    }

    /// Grow the two-socket dynamic split by repeatedly bisecting the largest range,
    /// which is the clean-room equivalent of idle sockets stealing unfinished tails.
    /// Segment 0 deliberately keeps its id so an already-downloaded prefix in `seg.x0`
    /// remains append-compatible.
    public static func planDynamicConnections(
        totalBytes: Int64,
        connections: Int,
        completedPrefixBytes: Int64
    ) -> [SegmentRecord] {
        guard totalBytes > 0 else { return [] }
        let target = max(1, min(connections, 32, Int(totalBytes)))
        guard target > 1 else {
            return planEqualSegments(totalBytes: totalBytes, connections: 1)
        }

        var segments = planDynamicInitial(
            totalBytes: totalBytes,
            completedPrefixBytes: completedPrefixBytes
        )
        var nextID: Int16 = 2
        while segments.count < target {
            guard let index = segments.indices
                .filter({ segments[$0].length > 1 })
                .max(by: { segments[$0].length < segments[$1].length }) else {
                break
            }
            let original = segments[index]
            let split = original.start + original.length / 2
            segments[index].end = split - 1
            segments.append(SegmentRecord(
                order: 0,
                segmentId: nextID,
                nextId: SegmentRecord.endOfList,
                start: split,
                end: original.end
            ))
            nextID += 1
        }
        return finalizeLinksPreservingIDs(segments)
    }

    /// Re-plan unfinished ranges into `newConnections` segments while preserving completed bytes on disk
    /// by keeping finished segments and re-splitting remaining byte ranges.
    public static func replanConnections(
        existing: [SegmentRecord],
        totalBytes: Int64,
        newConnections: Int,
        completedByID: [Int16: Int64]
    ) -> [SegmentRecord] {
        guard totalBytes > 0 else { return existing }
        let requestedWorkers = max(1, min(newConnections, 32))

        struct Hole {
            var start: Int64
            var end: Int64
            var reusableID: Int16?
            var length: Int64 { end - start + 1 }
        }

        var fixed: [SegmentRecord] = []
        var holes: [Hole] = []
        let sorted = existing.sorted { $0.start < $1.start }
        for segment in sorted {
            let have = min(max(0, completedByID[segment.segmentId] ?? 0), segment.length)
            if have > 0 {
                var prefix = segment
                prefix.end = segment.start + have - 1
                fixed.append(prefix)
            }
            if have < segment.length {
                holes.append(Hole(
                    start: segment.start + have,
                    end: segment.end,
                    reusableID: have == 0 ? segment.segmentId : nil
                ))
            }
        }
        guard !holes.isEmpty else {
            return finalizeLinksPreservingIDs(fixed)
        }

        let remainingBytes = holes.reduce(Int64(0)) { $0 + $1.length }
        let targetHoles = max(
            holes.count,
            min(requestedWorkers, Int(min(remainingBytes, Int64(Int.max))))
        )
        while holes.count < targetHoles {
            guard let index = holes.indices
                .filter({ holes[$0].length > 1 })
                .max(by: { holes[$0].length < holes[$1].length }) else {
                break
            }
            let original = holes[index]
            let split = original.start + original.length / 2
            holes[index].end = split - 1
            holes.append(Hole(start: split, end: original.end, reusableID: nil))
        }

        var usedIDs = Set(existing.map(\.segmentId))
        func allocateID() -> Int16 {
            for candidate in Int16.min...Int16.max where candidate >= 0 && !usedIDs.contains(candidate) {
                usedIDs.insert(candidate)
                return candidate
            }
            // The format cannot represent more ids; this is unreachable under the 32-worker cap.
            return 0
        }

        var result = fixed
        for hole in holes {
            let id = hole.reusableID ?? allocateID()
            result.append(SegmentRecord(
                order: 0,
                segmentId: id,
                nextId: SegmentRecord.endOfList,
                start: hole.start,
                end: hole.end
            ))
        }
        return finalizeLinksPreservingIDs(result)
    }

    private static func finalizeLinksPreservingIDs(_ segs: [SegmentRecord]) -> [SegmentRecord] {
        var sorted = segs.sorted { $0.start < $1.start }
        for i in 0..<sorted.count {
            sorted[i].order = Int16(i)
            sorted[i].nextId = (i == sorted.count - 1)
                ? SegmentRecord.endOfList
                : Int32(sorted[i + 1].segmentId)
        }
        return sorted
    }

    public static func segmentFileName(id: Int16) -> String {
        "seg.x\(id)"
    }

    public static func segmentFileURL(id: Int16, in workDirectory: URL) -> URL {
        workDirectory.appendingPathComponent(segmentFileName(id: id))
    }

    /// Bytes already on disk for a segment (0 if missing / unreadable).
    public static func existingByteCount(for segment: SegmentRecord, in workDirectory: URL) -> Int64 {
        let url = segmentFileURL(id: segment.segmentId, in: workDirectory)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        let n = size.int64Value
        // Clamp: never claim more than the segment length
        return min(max(0, n), segment.length)
    }

    /// Inclusive Range still needed, or `nil` if the segment file is complete.
    public static func remainingRange(for segment: SegmentRecord, have: Int64) -> (start: Int64, end: Int64)? {
        guard have < segment.length else { return nil }
        let start = segment.start + have
        return (start, segment.end)
    }

    public static func loadSegmentsBin(from workDirectory: URL) throws -> [SegmentRecord]? {
        let url = workDirectory.appendingPathComponent("segments.bin")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        return try parse(data)
    }

    // MARK: - LE helpers

    private static func readI16(_ d: Data, _ o: Int) -> Int16 {
        Int16(bitPattern: UInt16(d[o]) | (UInt16(d[o + 1]) << 8))
    }

    private static func readI32(_ d: Data, _ o: Int) -> Int32 {
        Int32(bitPattern:
            UInt32(d[o]) |
            (UInt32(d[o + 1]) << 8) |
            (UInt32(d[o + 2]) << 16) |
            (UInt32(d[o + 3]) << 24)
        )
    }

    private static func readI64(_ d: Data, _ o: Int) -> Int64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(d[o + i]) << (8 * i)
        }
        return Int64(bitPattern: v)
    }

    private static func appendI16(_ d: inout Data, _ v: Int16) {
        let u = UInt16(bitPattern: v)
        d.append(UInt8(u & 0xff))
        d.append(UInt8((u >> 8) & 0xff))
    }

    private static func appendI32(_ d: inout Data, _ v: Int32) {
        let u = UInt32(bitPattern: v)
        for i in 0..<4 { d.append(UInt8((u >> (8 * i)) & 0xff)) }
    }

    private static func appendI64(_ d: inout Data, _ v: Int64) {
        let u = UInt64(bitPattern: v)
        for i in 0..<8 { d.append(UInt8((u >> (8 * i)) & 0xff)) }
    }
}

public enum SegmentError: Error, LocalizedError {
    case invalidSize(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidSize(let n): return "segments.bin size \(n) is not a multiple of 24"
        }
    }
}
