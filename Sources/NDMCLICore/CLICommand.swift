import Foundation
import NDMCore

/// What the user asked the command line to do.
///
/// Parsing lives apart from doing so the grammar is testable without touching a
/// database, a media file, or the speech framework.
public enum CLICommand: Equatable, Sendable {
    case transcribe(file: String, language: String?, writesTextFile: Bool)
    case search(query: String, limit: Int)
    case rebuildIndex
    case help
    case version
}

public struct CLIRequest: Equatable, Sendable {
    public let command: CLICommand
    /// Machine-readable output. The reason a CLI is worth building: it is what makes
    /// the same capabilities reachable from Shortcuts, Raycast or a shell script
    /// later, without any of them needing a UI.
    public let json: Bool

    public init(command: CLICommand, json: Bool) {
        self.command = command
        self.json = json
    }
}

public enum CLIParseError: LocalizedError, Equatable {
    case noCommand
    case unknownCommand(String)
    case missingArgument(command: String, what: String)
    case invalidValue(flag: String, value: String)
    case unexpectedArgument(String)

    public var errorDescription: String? {
        switch self {
        case .noCommand:
            return "No command given. Try `ndm --help`."
        case .unknownCommand(let name):
            return "Unknown command \(name.debugDescription). Try `ndm --help`."
        case .missingArgument(let command, let what):
            return "`\(command)` needs \(what)."
        case .invalidValue(let flag, let value):
            return "\(flag) does not accept \(value.debugDescription)."
        case .unexpectedArgument(let value):
            return "Unexpected argument \(value.debugDescription)."
        }
    }
}

public enum CLIParser: Sendable {
    public static let usage = """
    ndm — transcribe and search downloaded media from the terminal.

    USAGE
      ndm transcribe <file> [--language <tag>] [--no-text]
      ndm search <words…> [--limit <n>]
      ndm index rebuild
      ndm --help | --version

    OPTIONS
      --language <tag>   Force a language, e.g. zh-Hans. Default: decide from the file.
      --no-text          Write only subtitles, not the readable transcript.
      --limit <n>        Maximum downloads to list. Default 20.
      --json             Machine-readable output.

    Transcription runs entirely on this Mac and needs macOS 26 or later.
    """

    public static func parse(_ arguments: [String]) throws -> CLIRequest {
        var rest = arguments
        var json = false
        // Pull the global flag out first so it can appear anywhere, which is what
        // anyone typing it will expect.
        rest.removeAll { argument in
            if argument == "--json" {
                json = true
                return true
            }
            return false
        }

        guard let first = rest.first else { throw CLIParseError.noCommand }
        rest.removeFirst()

        switch first {
        case "--help", "-h", "help":
            return CLIRequest(command: .help, json: json)
        case "--version", "-v", "version":
            return CLIRequest(command: .version, json: json)
        case "transcribe":
            return CLIRequest(command: try parseTranscribe(rest), json: json)
        case "search":
            return CLIRequest(command: try parseSearch(rest), json: json)
        case "index":
            guard let sub = rest.first else {
                throw CLIParseError.missingArgument(command: "index", what: "a subcommand (rebuild)")
            }
            guard sub == "rebuild" else { throw CLIParseError.unknownCommand("index \(sub)") }
            guard rest.count == 1 else {
                throw CLIParseError.unexpectedArgument(rest[1])
            }
            return CLIRequest(command: .rebuildIndex, json: json)
        default:
            throw CLIParseError.unknownCommand(first)
        }
    }

    private static func parseTranscribe(_ arguments: [String]) throws -> CLICommand {
        var file: String?
        var language: String?
        var writesText = true
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--language":
                guard index + 1 < arguments.count else {
                    throw CLIParseError.missingArgument(command: "--language", what: "a language tag")
                }
                let raw = arguments[index + 1]
                guard let tag = SettingsInputValidation.transcriptionLanguageTag(raw) else {
                    throw CLIParseError.invalidValue(flag: "--language", value: raw)
                }
                language = tag
                index += 2
            case "--no-text":
                writesText = false
                index += 1
            default:
                guard !argument.hasPrefix("--") else {
                    throw CLIParseError.unknownCommand(argument)
                }
                guard file == nil else { throw CLIParseError.unexpectedArgument(argument) }
                file = argument
                index += 1
            }
        }
        guard let file else {
            throw CLIParseError.missingArgument(command: "transcribe", what: "a file to read")
        }
        return .transcribe(file: file, language: language, writesTextFile: writesText)
    }

    private static func parseSearch(_ arguments: [String]) throws -> CLICommand {
        var words: [String] = []
        var limit = 20
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--limit" {
                guard index + 1 < arguments.count else {
                    throw CLIParseError.missingArgument(command: "--limit", what: "a number")
                }
                let raw = arguments[index + 1]
                guard let value = Int(raw), value > 0 else {
                    throw CLIParseError.invalidValue(flag: "--limit", value: raw)
                }
                limit = value
                index += 2
            } else if argument.hasPrefix("--") {
                throw CLIParseError.unknownCommand(argument)
            } else {
                words.append(argument)
                index += 1
            }
        }
        // Words are rejoined rather than treated as separate operands: a shell splits
        // `ndm search 本地 转写` into two, and the user meant one query.
        let query = words.joined(separator: " ")
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CLIParseError.missingArgument(command: "search", what: "something to look for")
        }
        return .search(query: query, limit: limit)
    }
}
