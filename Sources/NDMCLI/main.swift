import Foundation
import NDMCLICore
import NDMCore
import NDMEngine

// The first surface of these capabilities anyone can actually reach. Transcription
// and search both work end to end, but every way into them is queued for design
// review — so a command line makes them usable today, and doubles as the seam
// Shortcuts, Raycast or a shell script can use later without needing a window.

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, json: Bool, code: Int32 = 64) -> Never {
    let text = json ? CLIOutput.errorJSON(message) : "ndm: \(message)"
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(code)
}

let request: CLIRequest
do {
    request = try CLIParser.parse(arguments)
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    // No --json is known yet when parsing itself failed, so report plainly.
    FileHandle.standardError.write(Data(("ndm: " + message + "\n").utf8))
    exit(64)
}

/// The app's own support directory, so the CLI searches the same inbox the app fills.
let supportRoot = DownloadStore.defaultSupportDirectory

func openIndex(json: Bool) -> SearchIndexStore {
    do {
        return try SearchIndexStore(directory: supportRoot)
    } catch {
        fail("could not open the search index: \(error.localizedDescription)", json: json, code: 74)
    }
}

func loadTasks(json: Bool) -> [DownloadTask] {
    do {
        return try DownloadStore(directory: supportRoot).allDownloads()
    } catch {
        fail("could not read the downloads: \(error.localizedDescription)", json: json, code: 74)
    }
}

switch request.command {
case .help:
    print(CLIParser.usage)

case .version:
    // Version lives with the app bundle; the tool reports the schema it speaks so a
    // script can tell whether its expectations still hold.
    if request.json {
        print(CLIOutput.errorJSON("").isEmpty ? "{}" : "{\n  \"searchIndexSchema\" : \(SearchIndexStore.schemaVersion)\n}")
    } else {
        print("ndm (search index schema \(SearchIndexStore.schemaVersion))")
    }

case .search(let query, let limit):
    let index = openIndex(json: request.json)
    let tasks = loadTasks(json: request.json)
    let namesByID = Dictionary(
        tasks.map { ($0.id, $0.filename.isEmpty ? "download \($0.id)" : $0.filename) },
        uniquingKeysWith: { first, _ in first }
    )
    do {
        let groups = try InboxSearch(index: index).search(query, taskLimit: limit)
        let rows = groups.map { group in
            CLIOutput.SearchRow(
                taskID: group.taskID,
                // A row for a task the database no longer knows is still worth showing:
                // the index says the words are there, and hiding it would be a silent
                // hole rather than an answer.
                name: namesByID[group.taskID] ?? "download \(group.taskID)",
                group: group
            )
        }
        if request.json {
            print(try CLIOutput.searchJSON(rows, query: query))
        } else {
            print(CLIOutput.searchText(rows, query: query), terminator: "")
        }
        exit(rows.isEmpty ? 1 : 0)
    } catch {
        fail("search failed: \(error.localizedDescription)", json: request.json, code: 70)
    }

case .rebuildIndex:
    let index = openIndex(json: request.json)
    do {
        let store = try DownloadStore(directory: supportRoot)
        let manager = DownloadManager(
            store: store,
            settings: SettingsStore.load(),
            supportRoot: supportRoot,
            searchIndex: index
        )
        let progress = await manager.rebuildSearchIndex()
        let failures = await manager.searchIndexFailures()
        if request.json {
            print("""
            {
              "downloads" : \(progress.total),
              "transcripts" : \(progress.indexedTranscripts),
              "problems" : \(failures.count)
            }
            """)
        } else {
            print("Indexed \(progress.total) download(s), \(progress.indexedTranscripts) with transcripts.")
            for failure in failures { print("  problem: \(failure)") }
        }
    } catch {
        fail("rebuild failed: \(error.localizedDescription)", json: request.json, code: 70)
    }

case .transcribe(let file, let language, let writesTextFile):
    guard #available(macOS 26, *) else {
        fail(
            "reading speech on this Mac needs macOS 26 or later",
            json: request.json,
            code: 69
        )
    }
    let mediaURL = URL(fileURLWithPath: file).standardizedFileURL
    guard FileManager.default.fileExists(atPath: mediaURL.path) else {
        fail("no file at \(mediaURL.path)", json: request.json, code: 66)
    }

    let environment = await SpeechTranscriptionEngine.environment()
    let decision = TranscriptionWorkflow.decide(
        fileURL: mediaURL,
        pageTitle: mediaURL.deletingPathExtension().lastPathComponent,
        environment: environment
    )
    var localeExplanation: String?
    let locale: String
    if let language {
        guard let matched = TranscriptionWorkflow.match(
            tag: language,
            in: environment.supportedLocaleIdentifiers
        ) else {
            fail("this Mac cannot read speech in \(language)", json: request.json, code: 69)
        }
        locale = matched
    } else {
        switch decision {
        case .ready(let plan):
            locale = plan.localeIdentifier
            // Say when the language was a guess rather than evidence. A file with no
            // language signal falls back to this Mac's own language, which is right
            // more often than not but plainly wrong for, say, an English recording on
            // a Chinese system — and a silent wrong guess wastes a whole run.
            switch plan.source {
            case .systemPreference:
                localeExplanation = "guessed from this Mac's language; use --language to change it"
            case .englishFallback:
                localeExplanation = "no language signal found; use --language to change it"
            case .site, .titleScript:
                localeExplanation = nil
            }
        case .unavailable(let reason):
            fail(reason.detail, json: request.json, code: 69)
        }
    }

    let readiness = await SpeechLanguageAssets.readiness(forLocaleIdentifier: locale)
    switch readiness {
    case .unsupported:
        fail("this Mac cannot read speech in that language", json: request.json, code: 69)
    case .needsPreparation, .preparing:
        // Say what is happening rather than appearing to hang: this is a one-time
        // download the system performs.
        if !request.json { print("Preparing \(locale) for the first time…") }
        do {
            try await SpeechLanguageAssets().prepare(localeIdentifier: locale)
        } catch {
            fail("preparing the language failed: \(error.localizedDescription)", json: request.json, code: 70)
        }
    case .ready:
        break
    }

    do {
        if !request.json {
            if let localeExplanation {
                print("Reading speech (\(locale) — \(localeExplanation))…")
            } else {
                print("Reading speech (\(locale))…")
            }
        }
        let segments = try await SpeechTranscriptionEngine().transcribe(
            fileURL: mediaURL,
            localeIdentifier: locale
        )
        guard !segments.isEmpty else {
            fail("no speech was recognised", json: request.json, code: 65)
        }
        let output = try TranscriptDelivery.write(segments: segments, besidePrimary: mediaURL)
        if !writesTextFile {
            try? FileManager.default.removeItem(at: output.transcriptURL)
        }
        if request.json {
            print(try CLIOutput.transcribeJSON(
                subtitleURL: output.subtitleURL,
                transcriptURL: writesTextFile ? output.transcriptURL : nil,
                segmentCount: segments.count,
                language: locale
            ))
        } else {
            print("Subtitles: \(output.subtitleURL.path)")
            if writesTextFile { print("Transcript: \(output.transcriptURL.path)") }
            print("\(segments.count) line(s).")
        }
    } catch {
        fail("transcription failed: \(error.localizedDescription)", json: request.json, code: 70)
    }
}
