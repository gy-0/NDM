import XCTest
@testable import NDMCore

final class HLSPlaylistTests: XCTestCase {
    func testParseMediaPlaylist() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:5
        #EXTINF:9.0,
        seg0.ts
        #EXTINF:9.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let media) = try HLSPlaylist.parse(text) else {
            return XCTFail("expected media")
        }
        XCTAssertEqual(media.version, 3)
        XCTAssertEqual(media.targetDuration, 10)
        XCTAssertEqual(media.mediaSequence, 5)
        XCTAssertTrue(media.endList)
        XCTAssertEqual(media.segments.count, 2)
        XCTAssertEqual(media.segments[0].id, 5)
        XCTAssertEqual(media.segments[0].uri, "seg0.ts")
        XCTAssertEqual(media.segments[1].id, 6)
    }

    func testParseMasterPrefersHighestBandwidth() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
        hi.m3u8
        """
        guard case .master(let master) = try HLSPlaylist.parse(text) else {
            return XCTFail("expected master")
        }
        XCTAssertEqual(master.variants.count, 2)
        XCTAssertEqual(master.preferredVariant?.uri, "hi.m3u8")
        XCTAssertEqual(master.preferredVariant?.bandwidth, 2_400_000)
    }

    func testParseKeyAndByteRange() throws {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example/key.bin",IV=0x0123456789ABCDEF0123456789ABCDEF
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:1000@200
        media.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let media) = try HLSPlaylist.parse(text) else {
            return XCTFail("expected media")
        }
        XCTAssertEqual(media.key?.method, "AES-128")
        XCTAssertEqual(media.key?.uri, "https://cdn.example/key.bin")
        XCTAssertEqual(media.key?.ivHex, "0123456789ABCDEF0123456789ABCDEF")
        XCTAssertTrue(media.key?.isAES128 == true)
        XCTAssertEqual(media.segments[0].byteRange?.length, 1000)
        XCTAssertEqual(media.segments[0].byteRange?.offset, 200)
    }

    func testResolveURL() {
        let base = URL(string: "https://cdn.example/v/playlist.m3u8")!
        XCTAssertEqual(
            HLSPlaylist.resolveURL("a.ts", against: base)?.absoluteString,
            "https://cdn.example/v/a.ts"
        )
        XCTAssertEqual(
            HLSPlaylist.resolveURL("https://other/x.ts", against: base)?.absoluteString,
            "https://other/x.ts"
        )
    }

    func testRejectNonPlaylist() {
        XCTAssertThrowsError(try HLSPlaylist.parse("not a playlist")) { err in
            XCTAssertEqual(err as? HLSError, .notPlaylist)
        }
    }
}
