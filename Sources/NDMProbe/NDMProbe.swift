import Foundation
import CryptoKit
import NDMCore
import NDMDiagnostics
import NDMEngine

// Measures the north-star metric on real links: how often a submitted URL becomes
// a usable file, and how long that takes.
//
// This is a deliberate, manually-run diagnostic — never part of `swift test`. It
// reaches the public internet, so its failures say as much about the network as
// about this repository, and a flaky number must not gate a merge.
//
//   swift run NDMProbe
//   swift run NDMProbe --cases Scripts/success-rate-cases.json --repeat 3
//   swift run NDMProbe --min-success-rate 0.9    # exit 1 when below
//
// Cases route through exactly the API the app uses (addURL/startAndWait for
// files, MediaPreflightStore + startYtDlp for pages) so the number reflects the
// shipping delivery path rather than a parallel reimplementation.

struct Options {
    var casesPath = "Scripts/success-rate-cases.json"
    var repeatCount = 1
    var minSuccessRate: Double?
    var keepFiles = false
    var only: String?
    var warmup = false
}

func parseOptions() throws -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--cases":
            guard let v = args.first else { throw Failure("--cases needs a path") }
            options.casesPath = v
            args.removeFirst()
        case "--repeat":
            guard let v = args.first, let n = Int(v), n > 0 else {
                throw Failure("--repeat needs a positive integer")
            }
            options.repeatCount = n
            args.removeFirst()
        case "--min-success-rate":
            guard let v = args.first, let d = Double(v), d >= 0, d <= 1 else {
                throw Failure("--min-success-rate needs a value between 0 and 1")
            }
            options.minSuccessRate = d
            args.removeFirst()
        case "--only":
            guard let v = args.first else { throw Failure("--only needs a case id") }
            options.only = v
            args.removeFirst()
        case "--keep":
            options.keepFiles = true
        case "--warmup":
            options.warmup = true
        case "-h", "--help":
            print("""
            Usage: swift run NDMProbe [options]
              --cases <path>             case suite JSON (default Scripts/success-rate-cases.json)
              --repeat <n>               run the suite n times
              --min-success-rate <0..1>  exit non-zero below this rate
              --only <case-id>           run a single case
              --warmup                   run one discarded pass first (see below)
              --keep                     keep downloaded files for inspection

            Timing caveat: passes are not independent. The first attempt pays
            cold-start costs the rest do not — paging in the media toolchain
            binary alone measured 21.8s versus 3.8s on the following pass. Use
            --warmup when comparing medians across runs.
            """)
            exit(0)
        default:
            throw Failure("unknown argument \(arg)")
        }
    }
    return options
}

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Set from `--keep`. Inspecting what actually landed on disk is how a wrong-bytes
/// delivery gets diagnosed, so keeping the sandbox has to be possible.
nonisolated(unsafe) var keepSandboxes = false

func cleanUp(_ root: URL) {
    guard !keepSandboxes else {
        print("         kept \(root.path)")
        return
    }
    try? FileManager.default.removeItem(at: root)
}

/// One sandbox per attempt. Sharing a download directory would let a previous
/// attempt's file satisfy the next one's existence check, quietly inflating the
/// success rate.
func makeSandbox() throws -> (root: URL, support: URL, dest: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ndm-probe-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let dest = root.appendingPathComponent("Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    return (root, support, dest)
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// A file on disk is not yet a success. Verify it against whatever the case
/// declares, so a truncated transfer or an error page written to disk fails here
/// rather than being counted as a delivery.
func verify(_ testCase: SuccessRateCase, fileURL: URL) throws -> Int64 {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw Failure("delivered file is missing at \(fileURL.path)")
    }
    let size = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
        .int64Value ?? 0
    guard size > 0 else { throw Failure("delivered file is empty") }
    if let expected = testCase.expectedBytes, size != expected {
        throw Failure("expected \(expected) bytes, delivered \(size)")
    }
    if let expected = testCase.expectedSHA256?.lowercased() {
        let actual = try sha256(of: fileURL)
        guard actual == expected else {
            throw Failure(
                "sha256 mismatch: expected \(expected), got \(actual)"
                    + (interstitialHint(at: fileURL).map { " — \($0)" } ?? "")
            )
        }
    }
    return size
}

/// The most common cause of a hash mismatch is not a transfer bug but a server
/// substituting a page for the file: a mirror's rate-limit notice, a login wall,
/// a captive portal. Naming that saves the next person from hunting a phantom
/// engine bug — this check exists because a Tsinghua mirror served exactly such a
/// notice, with an honest Content-Length, while this harness was being written.
func interstitialHint(at url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: 1024), !head.isEmpty,
          let text = String(data: head, encoding: .utf8)
    else { return nil }
    let lowered = text.lowercased()
    for marker in ["<!doctype html", "<html", "<?xml", "access denied", "denied access"] {
        if lowered.contains(marker) {
            let firstLine = text
                .split(whereSeparator: \.isNewline).first
                .map { $0.prefix(120).trimmingCharacters(in: .whitespaces) } ?? ""
            return "the server sent a page, not the file (\(firstLine.debugDescription))"
        }
    }
    return nil
}

func runDirectFile(_ testCase: SuccessRateCase) async throws -> Int64 {
    let sandbox = try makeSandbox()
    defer { cleanUp(sandbox.root) }
    let store = try DownloadStore(directory: sandbox.support)
    let settings = AppSettings(
        downloadDirectory: sandbox.dest,
        maxConnections: 8,
        useCategoryFolders: false
    )
    let manager = DownloadManager(store: store, settings: settings, supportRoot: sandbox.support)
    let task = try await manager.addURL(testCase.url)
    try await manager.startAndWait(taskID: task.id)
    guard let delivered = try await manager.task(id: task.id) else {
        throw Failure("task vanished after completion")
    }
    let fileURL = URL(fileURLWithPath: delivered.folderPath ?? sandbox.dest.path)
        .appendingPathComponent(delivered.filename)
    return try verify(testCase, fileURL: fileURL)
}

func runMediaPage(_ testCase: SuccessRateCase) async throws -> Int64 {
    guard YtDlpTool.isAvailable else {
        throw Failure("the media toolchain is unavailable")
    }
    let sandbox = try makeSandbox()
    defer { cleanUp(sandbox.root) }
    let store = try DownloadStore(directory: sandbox.support)
    let settings = AppSettings(
        downloadDirectory: sandbox.dest,
        maxConnections: 8,
        useCategoryFolders: false
    )
    let manager = DownloadManager(store: store, settings: settings, supportRoot: sandbox.support)

    let preflight = try await MediaPreflightStore.uncached().result(for: testCase.url)
    // Deliberately the cheapest tier: this measures whether delivery works, not
    // how fast the network is, and a 4K pull would make the suite unrunnable.
    guard let format = preflight.probe.formats.last ?? preflight.probe.formats.first else {
        throw Failure("no formats were offered for this page")
    }
    let task = try await manager.startYtDlp(
        url: preflight.mediaURL,
        formatID: format.id,
        pageTitle: preflight.probe.title,
        estimatedBytes: format.approximateBytes,
        preferredFilename: preflight.probe.title
    )
    try await manager.startAndWait(taskID: task.id)
    guard let delivered = try await manager.task(id: task.id) else {
        throw Failure("task vanished after completion")
    }
    let fileURL = URL(fileURLWithPath: delivered.folderPath ?? sandbox.dest.path)
        .appendingPathComponent(delivered.filename)
    return try verify(testCase, fileURL: fileURL)
}

func run(_ testCase: SuccessRateCase) async -> CaseOutcome {
    let started = Date()
    do {
        let bytes: Int64
        switch testCase.kind {
        case .directFile: bytes = try await runDirectFile(testCase)
        case .mediaPage: bytes = try await runMediaPage(testCase)
        }
        return CaseOutcome(
            caseID: testCase.id,
            kind: testCase.kind,
            succeeded: true,
            duration: Date().timeIntervalSince(started),
            bytes: bytes
        )
    } catch {
        return CaseOutcome(
            caseID: testCase.id,
            kind: testCase.kind,
            succeeded: false,
            duration: Date().timeIntervalSince(started),
            failure: error.localizedDescription
        )
    }
}

@main
struct NDMProbe {
    static func main() async {
        do {
            let options = try parseOptions()
            keepSandboxes = options.keepFiles
            let suiteURL = URL(fileURLWithPath: options.casesPath)
            var suite = try SuccessRateSuite.load(from: suiteURL)
            if let only = options.only {
                suite.cases = suite.cases.filter { $0.id == only }
                guard !suite.cases.isEmpty else {
                    throw Failure("no case matches id \(only.debugDescription)")
                }
            }

            print("Probing \(suite.cases.count) case(s) × \(options.repeatCount) run(s)\n")

            // Passes are not independent: the first attempt pays cold-start costs
            // (paging in the media toolchain binary measured 21.8s versus 3.8s on
            // the next pass), which would skew a median computed across passes.
            if options.warmup {
                print("  warmup (discarded)")
                for testCase in suite.cases {
                    _ = await run(testCase)
                }
                print("")
            }

            var outcomes: [CaseOutcome] = []
            for pass in 1...options.repeatCount {
                for testCase in suite.cases {
                    let outcome = await run(testCase)
                    outcomes.append(outcome)
                    let mark = outcome.succeeded ? "PASS" : "FAIL"
                    var line = "  pass \(pass)  [\(mark)] \(outcome.caseID)"
                    if let failure = outcome.failure { line += " — \(failure)" }
                    print(line)
                    fflush(stdout)
                }
            }

            let report = SuccessRateReport(outcomes: outcomes)
            print("\n" + report.render())

            if let minimum = options.minSuccessRate, !report.meetsThreshold(minimum) {
                print(
                    "\nBelow the required success rate "
                        + "(\(SuccessRateReport.percent(minimum)))."
                )
                exit(1)
            }
            exit(report.failed == 0 ? 0 : 2)
        } catch {
            FileHandle.standardError.write(
                Data("NDMProbe: \(error.localizedDescription)\n".utf8)
            )
            exit(64)
        }
    }
}
