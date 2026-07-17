import XCTest
@testable import NDMEngine

final class MediaPreflightTests: XCTestCase {
    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private let sampleProbe = YtDlpProbe(
        title: "A real title",
        durationSeconds: 92,
        formats: [YtDlpFormat(id: "720", label: "720p", height: 720)],
        thumbnailURL: "https://img.example/cover.jpg",
        subtitleTracks: [YtDlpSubtitleTrack(code: "zh", displayName: "Chinese", isAutomatic: false)]
    )

    func testConcurrentRequestsShareOneProbe() async throws {
        let counter = Counter()
        let expected = sampleProbe
        let store = MediaPreflightStore(
            expand: { ExpandedShortLink(originalURL: $0, resolvedURL: $0, didExpand: false) },
            probe: { _ in
                await counter.increment()
                try await Task.sleep(nanoseconds: 30_000_000)
                return expected
            }
        )

        async let first = store.result(for: "https://example.com/watch/1")
        async let second = store.result(for: "https://example.com/watch/1")
        let (a, b) = try await (first, second)
        let probeCount = await counter.value

        XCTAssertEqual(a, b)
        XCTAssertEqual(probeCount, 1)
    }

    func testExpandedAndOriginalURLsShareCachedResult() async throws {
        let counter = Counter()
        let expected = sampleProbe
        let short = "https://b23.tv/abc"
        let resolved = "https://www.bilibili.com/video/BV1"
        let store = MediaPreflightStore(
            expand: { raw in
                ExpandedShortLink(originalURL: raw, resolvedURL: resolved, didExpand: true)
            },
            probe: { _ in
                await counter.increment()
                return expected
            }
        )

        let result = try await store.result(for: short)
        let cachedByResolved = try await store.result(for: resolved)
        let probeCount = await counter.value

        XCTAssertTrue(result.didExpandShortLink)
        XCTAssertEqual(cachedByResolved, result)
        XCTAssertEqual(probeCount, 1)
    }

    func testFailureIsNotPermanentlyCached() async {
        enum SampleError: Error { case unavailable }
        let counter = Counter()
        let expected = sampleProbe
        let store = MediaPreflightStore(
            expand: { ExpandedShortLink(originalURL: $0, resolvedURL: $0, didExpand: false) },
            probe: { _ in
                await counter.increment()
                if await counter.value == 1 { throw SampleError.unavailable }
                return expected
            }
        )

        do {
            _ = try await store.result(for: "https://example.com/watch/2")
            XCTFail("Expected the first probe to fail")
        } catch {}

        let recovered = try? await store.result(for: "https://example.com/watch/2")
        let probeCount = await counter.value
        XCTAssertEqual(recovered?.probe, expected)
        XCTAssertEqual(probeCount, 2)
    }

    func testCollectionMetadataTravelsWithSingleVideoProbe() async throws {
        let expected = sampleProbe
        let collection = YtDlpCollectionProbe(
            title: "Design lessons",
            items: [
                YtDlpCollectionItem(
                    id: "one",
                    title: "First",
                    url: "https://www.youtube.com/watch?v=one"
                ),
                YtDlpCollectionItem(
                    id: "two",
                    title: "Second",
                    url: "https://www.youtube.com/watch?v=two"
                ),
            ],
            totalCount: 2,
            isTruncated: false
        )
        let store = MediaPreflightStore(
            expand: { ExpandedShortLink(originalURL: $0, resolvedURL: $0, didExpand: false) },
            probe: { _ in expected },
            probeCollection: { _ in collection }
        )

        let result = try await store.result(
            for: "https://www.youtube.com/watch?v=one&list=PL123"
        )

        XCTAssertEqual(result.collection, collection)
        XCTAssertEqual(result.mediaURL, result.resolvedURL)
    }

    func testCollectionOnlyPageFallsBackToFirstItemForQualityProbe() async throws {
        enum SampleError: Error { case noSingleVideo }
        let expected = sampleProbe
        let firstURL = "https://www.youtube.com/watch?v=first"
        let collection = YtDlpCollectionProbe(
            title: "Collection",
            items: [
                YtDlpCollectionItem(id: "first", title: "First", url: firstURL),
            ],
            totalCount: 1,
            isTruncated: false
        )
        let store = MediaPreflightStore(
            expand: { ExpandedShortLink(originalURL: $0, resolvedURL: $0, didExpand: false) },
            probe: { url in
                guard url == firstURL else { throw SampleError.noSingleVideo }
                return expected
            },
            probeCollection: { _ in collection }
        )

        let result = try await store.result(
            for: "https://www.youtube.com/playlist?list=PL123"
        )

        XCTAssertEqual(result.mediaURL, firstURL)
        XCTAssertEqual(result.probe, expected)
        XCTAssertEqual(result.collection, collection)
    }

    func testClassifierSeparatesPagesFromDirectFiles() {
        XCTAssertTrue(MediaLinkClassifier.looksLikeMediaPage("https://youtube.com/watch?v=1"))
        XCTAssertTrue(MediaLinkClassifier.looksLikeMediaPage("https://example.com/article/1"))
        XCTAssertFalse(MediaLinkClassifier.looksLikeMediaPage("https://example.com/movie.mp4"))
        XCTAssertFalse(MediaLinkClassifier.looksLikeMediaPage("https://example.com/app.dmg"))
        XCTAssertFalse(MediaLinkClassifier.looksLikeMediaPage("ftp://example.com/archive.zip"))
        XCTAssertTrue(MediaLinkClassifier.looksLikeCollectionURL(
            "https://www.youtube.com/watch?v=one&list=PL123"
        ))
        XCTAssertTrue(MediaLinkClassifier.looksLikeCollectionURL(
            "https://www.bilibili.com/medialist/play/123"
        ))
        XCTAssertFalse(MediaLinkClassifier.looksLikeCollectionURL(
            "https://www.youtube.com/watch?v=one"
        ))
        XCTAssertTrue(MediaLinkClassifier.hasExplicitSingleMedia(
            "https://www.youtube.com/watch?v=one&list=PL123"
        ))
        XCTAssertFalse(MediaLinkClassifier.hasExplicitSingleMedia(
            "https://www.youtube.com/playlist?list=PL123"
        ))
    }
}
