import XCTest
@testable import NDMCLICore
@testable import NDMCore

final class CLIParserTests: XCTestCase {
    private func parse(_ arguments: String...) throws -> CLIRequest {
        try CLIParser.parse(arguments)
    }

    // MARK: - Shape

    func testNoArgumentsAsksForHelpRatherThanGuessing() {
        XCTAssertThrowsError(try CLIParser.parse([])) { error in
            XCTAssertEqual(error as? CLIParseError, .noCommand)
        }
    }

    func testHelpAndVersionHaveTheUsualSpellings() throws {
        for spelling in ["--help", "-h", "help"] {
            XCTAssertEqual(try CLIParser.parse([spelling]).command, .help)
        }
        for spelling in ["--version", "-v", "version"] {
            XCTAssertEqual(try CLIParser.parse([spelling]).command, .version)
        }
    }

    func testAnUnknownCommandIsNamedInTheError() {
        XCTAssertThrowsError(try parse("frobnicate")) { error in
            XCTAssertEqual(error as? CLIParseError, .unknownCommand("frobnicate"))
        }
    }

    /// A global flag has to work wherever it is typed; nobody remembers flag position.
    func testJSONFlagIsAcceptedAnywhere() throws {
        XCTAssertTrue(try parse("--json", "search", "转写").json)
        XCTAssertTrue(try parse("search", "--json", "转写").json)
        XCTAssertTrue(try parse("search", "转写", "--json").json)
        XCTAssertFalse(try parse("search", "转写").json)
    }

    // MARK: - transcribe

    func testTranscribeTakesAFile() throws {
        XCTAssertEqual(
            try parse("transcribe", "/tmp/talk.mp4").command,
            .transcribe(file: "/tmp/talk.mp4", language: nil, writesTextFile: true)
        )
    }

    func testTranscribeRequiresAFile() {
        XCTAssertThrowsError(try parse("transcribe")) { error in
            XCTAssertEqual(
                error as? CLIParseError,
                .missingArgument(command: "transcribe", what: "a file to read")
            )
        }
    }

    func testTranscribeAcceptsALanguageOverride() throws {
        XCTAssertEqual(
            try parse("transcribe", "/tmp/a.mp4", "--language", "zh-Hans").command,
            .transcribe(file: "/tmp/a.mp4", language: "zh-Hans", writesTextFile: true)
        )
    }

    /// A typo must be refused at the door rather than becoming a language that can
    /// never match.
    func testAMalformedLanguageIsRejected() {
        XCTAssertThrowsError(try parse("transcribe", "/tmp/a.mp4", "--language", "chinese")) { error in
            XCTAssertEqual(
                error as? CLIParseError,
                .invalidValue(flag: "--language", value: "chinese")
            )
        }
    }

    func testLanguageFlagNeedsAValue() {
        XCTAssertThrowsError(try parse("transcribe", "/tmp/a.mp4", "--language")) { error in
            XCTAssertEqual(
                error as? CLIParseError,
                .missingArgument(command: "--language", what: "a language tag")
            )
        }
    }

    func testNoTextSuppressesTheTranscriptFile() throws {
        XCTAssertEqual(
            try parse("transcribe", "/tmp/a.mp4", "--no-text").command,
            .transcribe(file: "/tmp/a.mp4", language: nil, writesTextFile: false)
        )
    }

    func testASecondFileIsRefusedRatherThanIgnored() {
        XCTAssertThrowsError(try parse("transcribe", "/tmp/a.mp4", "/tmp/b.mp4")) { error in
            XCTAssertEqual(error as? CLIParseError, .unexpectedArgument("/tmp/b.mp4"))
        }
    }

    func testAnUnknownFlagIsRefusedRatherThanTreatedAsAFilename() {
        XCTAssertThrowsError(try parse("transcribe", "--wat", "/tmp/a.mp4")) { error in
            XCTAssertEqual(error as? CLIParseError, .unknownCommand("--wat"))
        }
    }

    // MARK: - search

    /// A shell splits `ndm search 本地 转写` into two words; the user meant one query.
    func testSearchWordsAreRejoinedIntoOneQuery() throws {
        XCTAssertEqual(
            try parse("search", "本地", "转写").command,
            .search(query: "本地 转写", limit: 20)
        )
    }

    func testSearchNeedsSomethingToLookFor() {
        XCTAssertThrowsError(try parse("search")) { error in
            XCTAssertEqual(
                error as? CLIParseError,
                .missingArgument(command: "search", what: "something to look for")
            )
        }
        XCTAssertThrowsError(try parse("search", "   "))
    }

    func testSearchLimitIsParsed() throws {
        XCTAssertEqual(
            try parse("search", "转写", "--limit", "5").command,
            .search(query: "转写", limit: 5)
        )
    }

    func testANonPositiveLimitIsRejected() {
        for bad in ["0", "-3", "many", "3.5"] {
            XCTAssertThrowsError(try parse("search", "转写", "--limit", bad)) { error in
                XCTAssertEqual(
                    error as? CLIParseError,
                    .invalidValue(flag: "--limit", value: bad)
                )
            }
        }
    }

    // MARK: - index

    func testIndexRebuild() throws {
        XCTAssertEqual(try parse("index", "rebuild").command, .rebuildIndex)
    }

    func testIndexNeedsASubcommand() {
        XCTAssertThrowsError(try parse("index")) { error in
            XCTAssertEqual(
                error as? CLIParseError,
                .missingArgument(command: "index", what: "a subcommand (rebuild)")
            )
        }
    }

    func testAnUnknownIndexSubcommandIsRefused() {
        XCTAssertThrowsError(try parse("index", "obliterate")) { error in
            XCTAssertEqual(error as? CLIParseError, .unknownCommand("index obliterate"))
        }
    }

    func testTrailingJunkAfterRebuildIsRefused() {
        XCTAssertThrowsError(try parse("index", "rebuild", "everything")) { error in
            XCTAssertEqual(error as? CLIParseError, .unexpectedArgument("everything"))
        }
    }

    // MARK: - Usage text

    func testUsageMentionsEveryCommand() {
        for command in ["transcribe", "search", "index rebuild", "--json"] {
            XCTAssertTrue(
                CLIParser.usage.contains(command),
                "usage does not mention \(command)"
            )
        }
    }

    /// The macOS requirement has to be discoverable without running the command and
    /// getting an error.
    func testUsageStatesTheSystemRequirement() {
        XCTAssertTrue(CLIParser.usage.contains("macOS 26"))
    }
}
