import XCTest
import CommonCrypto
@testable import NDMEngine
@testable import NDMCore

final class HLSEngineIntegrationTests: XCTestCase {
    func testMediaPlaylistDownloadAndMerge() async throws {
        let seg0 = Data("AAAA-SEG0-AAAA".utf8)
        let seg1 = Data("BBBB-SEG1-BBBB".utf8)
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXTINF:9.0,
        seg0.ts
        #EXTINF:9.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let server = LocalHLSServer(files: [
            "stream.m3u8": Data(playlist.utf8),
            "seg0.ts": seg0,
            "seg1.ts": seg1,
        ])
        try server.start()
        defer { server.stop() }

        let (manager, dest) = try makeManager()
        let task = try await manager.addURL(server.url(path: "stream.m3u8").absoluteString, ltype: "hls")
        XCTAssertEqual(task.linkType, "hls")
        try await manager.startAndWait(taskID: task.id)

        let tasks = try await manager.listTasks()
        let done = try XCTUnwrap(tasks.first(where: { $0.id == task.id }))
        XCTAssertEqual(done.status, .complete)

        let fileURL = dest.appendingPathComponent(done.filename)
        XCTAssertEqual(try Data(contentsOf: fileURL), seg0 + seg1)
        XCTAssertTrue(done.filename.hasSuffix(".ts"))
    }

    func testMasterPlaylistSelectsHighestBandwidth() async throws {
        let low = Data("LOW".utf8)
        let hi = Data("HIGH-QUALITY-TS".utf8)
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=500000
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3000000
        hi.m3u8
        """
        let lowMedia = """
        #EXTM3U
        #EXTINF:1.0,
        low.ts
        #EXT-X-ENDLIST
        """
        let hiMedia = """
        #EXTM3U
        #EXTINF:1.0,
        hi.ts
        #EXT-X-ENDLIST
        """
        let server = LocalHLSServer(files: [
            "master.m3u8": Data(master.utf8),
            "low.m3u8": Data(lowMedia.utf8),
            "hi.m3u8": Data(hiMedia.utf8),
            "low.ts": low,
            "hi.ts": hi,
        ])
        try server.start()
        defer { server.stop() }

        let (manager, dest) = try makeManager()
        let task = try await manager.addURL(server.url(path: "master.m3u8").absoluteString)
        try await manager.startAndWait(taskID: task.id)

        let tasks = try await manager.listTasks()
        let done = try XCTUnwrap(tasks.first(where: { $0.id == task.id }))
        XCTAssertEqual(done.status, .complete)
        let data = try Data(contentsOf: dest.appendingPathComponent(done.filename))
        XCTAssertEqual(data, hi)
    }

    func testAES128SegmentDecrypt() async throws {
        let plain = Data("0123456789ABCDEF0123456789ABCDEF".utf8) // 32 bytes
        let key = Data((0..<16).map { UInt8($0) })
        let iv = Data(repeating: 0x11, count: 16)
        let cipher = try encryptAES128(plain, key: key, iv: iv)

        let playlist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x11111111111111111111111111111111
        #EXTINF:1.0,
        enc.ts
        #EXT-X-ENDLIST
        """
        let server = LocalHLSServer(files: [
            "enc.m3u8": Data(playlist.utf8),
            "key.bin": key,
            "enc.ts": cipher,
        ])
        try server.start()
        defer { server.stop() }

        let (manager, dest) = try makeManager()
        let task = try await manager.addURL(server.url(path: "enc.m3u8").absoluteString, ltype: "hls")
        try await manager.startAndWait(taskID: task.id)

        let tasks = try await manager.listTasks()
        let done = try XCTUnwrap(tasks.first(where: { $0.id == task.id }))
        XCTAssertEqual(done.status, .complete)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent(done.filename)), plain)
    }

    func testRealTSStreamRemuxesToMP4() async throws {
        guard let ffmpeg = FFmpegTool.find() else {
            throw XCTSkip("ffmpeg not installed; MP4 remux path not exercisable")
        }
        // Generate a genuine 1-second H.264+AAC MPEG-TS segment.
        let tsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-real-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: tsURL) }
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: ffmpeg)
        gen.arguments = [
            "-y",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=128x72:rate=10",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:v", "h264_videotoolbox", "-allow_sw", "1",
            "-c:a", "aac",
            "-f", "mpegts", tsURL.path,
        ]
        gen.standardError = Pipe()
        gen.standardOutput = Pipe()
        try gen.run()
        gen.waitUntilExit()
        guard gen.terminationStatus == 0,
              let tsData = try? Data(contentsOf: tsURL), !tsData.isEmpty else {
            throw XCTSkip("local ffmpeg can't encode the test stream (missing VideoToolbox H.264/AAC)")
        }

        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXTINF:1.0,
        movie.ts
        #EXT-X-ENDLIST
        """
        let server = LocalHLSServer(files: [
            "lecture.m3u8": Data(playlist.utf8),
            "movie.ts": tsData,
        ])
        try server.start()
        defer { server.stop() }

        let (manager, dest) = try makeManager()
        let task = try await manager.addURL(server.url(path: "lecture.m3u8").absoluteString, ltype: "hls")
        try await manager.startAndWait(taskID: task.id)

        let tasks = try await manager.listTasks()
        let done = try XCTUnwrap(tasks.first(where: { $0.id == task.id }))
        XCTAssertEqual(done.status, .complete)
        // "下完就是能播的 MP4": real streams come out as MP4, not TS.
        XCTAssertTrue(done.filename.hasSuffix(".mp4"), "expected MP4, got \(done.filename)")
        let fileURL = dest.appendingPathComponent(done.filename)
        let size = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(size, 0)
        // The moov atom is up front (faststart) — 'ftyp' marks a valid MP4.
        let head = try XCTUnwrap(FileHandle(forReadingFrom: fileURL).readData(ofLength: 12))
        XCTAssertTrue(String(data: head.subdata(in: 4..<8), encoding: .ascii) == "ftyp")
        // No stray .ts sibling in the destination.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dest.path)
            .filter { $0.hasSuffix(".ts") }
        XCTAssertTrue(leftovers.isEmpty, "unexpected TS leftovers: \(leftovers)")
    }

    // MARK: - Helpers

    private func makeManager() throws -> (DownloadManager, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndm-hls-\(UUID().uuidString)", isDirectory: true)
        let support = tmp.appendingPathComponent("support", isDirectory: true)
        let dest = tmp.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let store = try DownloadStore(directory: support)
        let settings = AppSettings(downloadDirectory: dest, maxConnections: 2, useCategoryFolders: false)
        let manager = DownloadManager(store: store, settings: settings, supportRoot: support)
        return (manager, dest)
    }

    private func encryptAES128(_ data: Data, key: Data, iv: Data) throws -> Data {
        var outLength = data.count + kCCBlockSizeAES128
        var out = Data(count: outLength)
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress, data.count,
                            outBytes.baseAddress, outLength,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw NSError(domain: "AES", code: Int(status))
        }
        out.count = outLength
        return out
    }
}
