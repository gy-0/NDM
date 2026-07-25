import XCTest
@testable import NDMCLICore
@testable import NDMCore

final class CLIClockTests: XCTestCase {
    /// Leading zero hours and minutes are noise in a list someone is scanning.
    func testMinutesAndSecondsBelowAnHour() {
        XCTAssertEqual(CLIOutput.clock(0), "0:00")
        XCTAssertEqual(CLIOutput.clock(65), "1:05")
        XCTAssertEqual(CLIOutput.clock(125.4), "2:05")
    }

    func testHoursAppearOnlyWhenThereAreSome() {
        XCTAssertEqual(CLIOutput.clock(3600), "1:00:00")
        XCTAssertEqual(CLIOutput.clock(3725), "1:02:05")
    }

    func testRoundingAndNegatives() {
        XCTAssertEqual(CLIOutput.clock(59.6), "1:00")
        XCTAssertEqual(CLIOutput.clock(-5), "0:00")
    }
}

final class CLIHighlightRenderingTests: XCTestCase {
    private func highlight(_ text: String, _ query: String) -> SearchHighlight {
        SearchSnippet.highlight(text: text, query: query)!
    }

    /// Brackets rather than ANSI colour: output has to stay readable when piped into a
    /// file or another program, which is most of why a CLI exists.
    func testMatchesAreBracketed() {
        XCTAssertEqual(
            CLIOutput.highlighted(highlight("这里讲到本地转写", "转写")),
            "这里讲到本地[转写]"
        )
    }

    func testMultipleMatchesAreEachBracketed() {
        XCTAssertEqual(
            CLIOutput.highlighted(highlight("转写完成，转写成功", "转写")),
            "[转写]完成，[转写]成功"
        )
    }

    func testTextWithNoMatchIsPassedThroughUnchanged() {
        let plain = SearchSnippet.highlight(text: "完全无关的内容", query: "量子力学")!
        XCTAssertEqual(CLIOutput.highlighted(plain), "完全无关的内容")
    }

    /// Ranges are character offsets, so an emoji must not shift the brackets.
    func testEmojiDoesNotMisplaceBrackets() {
        XCTAssertEqual(
            CLIOutput.highlighted(highlight("🎬本地转写", "转写")),
            "🎬本地[转写]"
        )
    }

    func testEnglishMatchesKeepTheirOriginalCase() {
        XCTAssertEqual(
            CLIOutput.highlighted(highlight("On-Device Speech", "speech")),
            "On-Device [Speech]"
        )
    }
}

final class CLISearchOutputTests: XCTestCase {
    private func row(
        _ taskID: Int64,
        _ name: String,
        moments: [(Double?, String)],
        hidden: Int = 0,
        sources: Set<SearchIndexStore.Source> = [.transcript]
    ) -> CLIOutput.SearchRow {
        let snippets = moments.map { moment in
            SearchResultSnippet(
                source: moment.0 == nil ? .title : .transcript,
                startSeconds: moment.0,
                highlight: SearchSnippet.highlight(text: moment.1, query: "转写")!
            )
        }
        return CLIOutput.SearchRow(
            taskID: taskID,
            name: name,
            group: SearchResultGroup(
                taskID: taskID,
                snippets: snippets,
                additionalSnippetCount: hidden,
                bestMatchedTermCount: 1,
                matchedSources: sources
            )
        )
    }

    func testNoResultsSaysSoAndNamesTheQuery() {
        let text = CLIOutput.searchText([], query: "量子力学")
        XCTAssertTrue(text.contains("量子力学"))
        XCTAssertTrue(text.lowercased().contains("nothing matched"))
    }

    func testEachMomentIsOnItsOwnLineWithAClock() {
        let text = CLIOutput.searchText(
            [row(1, "讲座.mp4", moments: [(125, "这里讲到转写"), (3725, "后面又提到转写")])],
            query: "转写"
        )
        XCTAssertTrue(text.contains("讲座.mp4"))
        XCTAssertTrue(text.contains("2:05"))
        XCTAssertTrue(text.contains("1:02:05"))
        XCTAssertTrue(text.contains("[转写]"))
    }

    /// A name-only hit must not look like the words were found inside; that download
    /// simply has no transcript yet.
    func testAMetadataOnlyRowIsLabelled() {
        let text = CLIOutput.searchText(
            [row(1, "讲座.mp4", moments: [(nil, "转写公开课")], sources: [.title])],
            query: "转写"
        )
        XCTAssertTrue(text.contains("name only"))
    }

    func testAContentRowIsNotLabelledAsNameOnly() {
        let text = CLIOutput.searchText(
            [row(1, "讲座.mp4", moments: [(10, "里面讲转写")])],
            query: "转写"
        )
        XCTAssertFalse(text.contains("name only"))
    }

    func testHiddenMatchesAreCountedInTheOutput() {
        let text = CLIOutput.searchText(
            [row(1, "讲座.mp4", moments: [(10, "讲转写")], hidden: 4)],
            query: "转写"
        )
        XCTAssertTrue(text.contains("+ 4 more"))
    }

    func testAMomentWithNoTimeShowsADashRatherThanZero() {
        let text = CLIOutput.searchText(
            [row(1, "讲座.mp4", moments: [(nil, "标题里的转写")], sources: [.title])],
            query: "转写"
        )
        XCTAssertTrue(text.contains("—"))
        XCTAssertFalse(text.contains("0:00"), "no position is not position zero")
    }
}

final class CLIJSONOutputTests: XCTestCase {
    private func decode(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }

    /// Field names are a contract: renaming one breaks whatever somebody automated.
    func testSearchJSONShape() throws {
        let row = CLIOutput.SearchRow(
            taskID: 42,
            name: "讲座.mp4",
            group: SearchResultGroup(
                taskID: 42,
                snippets: [
                    SearchResultSnippet(
                        source: .transcript,
                        startSeconds: 125,
                        highlight: SearchSnippet.highlight(text: "这里讲到转写", query: "转写")!
                    ),
                ],
                additionalSnippetCount: 2,
                bestMatchedTermCount: 1,
                matchedSources: [.transcript]
            )
        )
        let object = try decode(try CLIOutput.searchJSON([row], query: "转写"))
        XCTAssertEqual(object["query"] as? String, "转写")
        let results = try XCTUnwrap(object["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["taskID"] as? Int64, 42)
        XCTAssertEqual(results[0]["name"] as? String, "讲座.mp4")
        XCTAssertEqual(results[0]["matchedInContent"] as? Bool, true)
        XCTAssertEqual(results[0]["hiddenMatches"] as? Int, 2)
        let moments = try XCTUnwrap(results[0]["moments"] as? [[String: Any]])
        XCTAssertEqual(moments[0]["source"] as? String, "transcript")
        XCTAssertEqual(moments[0]["startSeconds"] as? Double, 125)
        XCTAssertEqual(moments[0]["at"] as? String, "2:05")
    }

    /// A moment with no position must omit the field rather than report zero, so a
    /// script cannot mistake "no timestamp" for "the very beginning".
    func testAMomentWithoutATimeOmitsTheTimeFields() throws {
        let row = CLIOutput.SearchRow(
            taskID: 1,
            name: "讲座.mp4",
            group: SearchResultGroup(
                taskID: 1,
                snippets: [
                    SearchResultSnippet(
                        source: .title,
                        startSeconds: nil,
                        highlight: SearchSnippet.highlight(text: "转写公开课", query: "转写")!
                    ),
                ],
                additionalSnippetCount: 0,
                bestMatchedTermCount: 1,
                matchedSources: [.title]
            )
        )
        let object = try decode(try CLIOutput.searchJSON([row], query: "转写"))
        let results = try XCTUnwrap(object["results"] as? [[String: Any]])
        let moments = try XCTUnwrap(results[0]["moments"] as? [[String: Any]])
        XCTAssertNil(moments[0]["startSeconds"])
        XCTAssertNil(moments[0]["at"])
        XCTAssertEqual(results[0]["matchedInContent"] as? Bool, false)
    }

    func testEmptySearchJSONIsStillValid() throws {
        let object = try decode(try CLIOutput.searchJSON([], query: "无"))
        XCTAssertEqual((object["results"] as? [[String: Any]])?.count, 0)
    }

    func testTranscribeJSONShape() throws {
        let object = try decode(try CLIOutput.transcribeJSON(
            subtitleURL: URL(fileURLWithPath: "/tmp/a.srt"),
            transcriptURL: URL(fileURLWithPath: "/tmp/a.txt"),
            segmentCount: 12,
            language: "zh_CN"
        ))
        XCTAssertEqual(object["subtitles"] as? String, "/tmp/a.srt")
        XCTAssertEqual(object["transcript"] as? String, "/tmp/a.txt")
        XCTAssertEqual(object["segments"] as? Int, 12)
        XCTAssertEqual(object["language"] as? String, "zh_CN")
    }

    func testTranscribeJSONOmitsTheTranscriptWhenNotWritten() throws {
        let object = try decode(try CLIOutput.transcribeJSON(
            subtitleURL: URL(fileURLWithPath: "/tmp/a.srt"),
            transcriptURL: nil,
            segmentCount: 3,
            language: "en_US"
        ))
        XCTAssertNil(object["transcript"])
    }

    /// Paths must not come back escaped, or a script that copies one gets a broken path.
    func testPathsAreNotSlashEscaped() throws {
        let text = try CLIOutput.transcribeJSON(
            subtitleURL: URL(fileURLWithPath: "/tmp/dir/a.srt"),
            transcriptURL: nil,
            segmentCount: 1,
            language: "en_US"
        )
        XCTAssertFalse(text.contains("\\/"))
    }

    func testErrorJSONIsValidAndCarriesTheMessage() throws {
        let object = try decode(CLIOutput.errorJSON("something went wrong"))
        XCTAssertEqual(object["error"] as? String, "something went wrong")
    }
}
