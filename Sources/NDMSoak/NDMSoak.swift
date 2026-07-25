import Darwin
import Foundation
import NDMCore
import NDMDiagnostics
import NDMEngine

// Long-run stability probe. A download manager's worst failure is dying after
// running all night, and nothing in this repository had ever watched for that.
//
// Each cycle creates concurrent tasks, pauses them mid-transfer, resumes, waits
// for delivery, then removes them with their files — the create/pause/resume/
// remove path a real session walks thousands of times. Resident memory, open file
// descriptors and task-store rows are sampled throughout, and SoakAnalysis judges
// whether any of them grew without settling.
//
//   swift run NDMSoak                        # 3 minute default
//   swift run NDMSoak --duration 28800       # the real 8 hour run
//   swift run NDMSoak --concurrency 8 --payload-mb 8
//
// Runs against a local origin, never a public mirror: hours of traffic at someone
// else's CDN is abusive, and once it starts rate-limiting the run would measure
// its patience rather than this process's stability.

struct SoakOptions {
    var duration: TimeInterval = 180
    var concurrency = 4
    /// Small on purpose: the transfer only has to exercise the segment machinery, not
    /// move volume. Two megabytes times four tasks times a fast loop is how the first
    /// version wrote hundreds of gigabytes.
    var payloadMB = 1
    var sampleInterval: TimeInterval = 5
    var responseDelay: TimeInterval = 0.01
    var maxGrowthFraction = 0.25
    /// Idle time between cycles.
    ///
    /// Load-bearing, not politeness. Leaks surface per *cycle*, not per byte, so an
    /// unthrottled loop buys nothing and costs everything: the first version of this
    /// tool ran flat out and wrote 710 GB at 94% CPU in under two hours, which cooks
    /// the machine and wears the SSD for no extra signal.
    var cyclePause: TimeInterval = 3.0
}

struct SoakFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func parseSoakOptions() throws -> SoakOptions {
    var options = SoakOptions()
    var args = Array(CommandLine.arguments.dropFirst())
    func next(_ flag: String) throws -> String {
        guard let v = args.first else { throw SoakFailure("\(flag) needs a value") }
        args.removeFirst()
        return v
    }
    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--duration":
            guard let v = Double(try next(arg)), v > 0 else {
                throw SoakFailure("--duration needs positive seconds")
            }
            options.duration = v
        case "--concurrency":
            guard let v = Int(try next(arg)), v > 0, v <= 32 else {
                throw SoakFailure("--concurrency needs 1...32")
            }
            options.concurrency = v
        case "--payload-mb":
            guard let v = Int(try next(arg)), v > 0, v <= 512 else {
                throw SoakFailure("--payload-mb needs 1...512")
            }
            options.payloadMB = v
        case "--sample-interval":
            guard let v = Double(try next(arg)), v > 0 else {
                throw SoakFailure("--sample-interval needs positive seconds")
            }
            options.sampleInterval = v
        case "--cycle-pause":
            guard let v = Double(try next(arg)), v >= 0 else {
                throw SoakFailure("--cycle-pause needs non-negative seconds")
            }
            options.cyclePause = v
        case "--response-delay":
            guard let v = Double(try next(arg)), v >= 0 else {
                throw SoakFailure("--response-delay needs non-negative seconds")
            }
            options.responseDelay = v
        case "--max-growth-fraction":
            guard let v = Double(try next(arg)), v > 0 else {
                throw SoakFailure("--max-growth-fraction needs a positive value")
            }
            options.maxGrowthFraction = v
        case "-h", "--help":
            print("""
            Usage: swift run NDMSoak [options]
              --duration <seconds>       how long to soak (default 180)
              --concurrency <1..32>      tasks per cycle (default 4)
              --payload-mb <1..512>      size served per task (default 1)
              --cycle-pause <secs>       idle between cycles (default 3). Keep this
                                         above zero: leaks show up per cycle, not per
                                         byte, so running flat out only heats the Mac
              --sample-interval <secs>   health sampling period (default 5)
              --response-delay <secs>    origin throttle, keeps transfers long
                                         enough to pause mid-flight (default 0.01)
              --max-growth-fraction <f>  report growth above this share of the
                                         baseline (default 0.25)

            Exits 0 when nothing grew without settling, 3 when a finding was
            reported, 64 on a usage or setup error.
            """)
            exit(0)
        default:
            throw SoakFailure("unknown argument \(arg)")
        }
    }
    return options
}

func residentBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
}

/// Counting /dev/fd is enough to catch the failure that matters: one unclosed
/// segment handle per cycle, invisible for minutes and then fatal.
func openFileDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
}

func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ndm-soak-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@main
struct NDMSoak {
    static func main() async {
        do {
            let options = try parseSoakOptions()
            let payload = Data(repeating: 0x4E, count: options.payloadMB * 1024 * 1024)
            let origin = LocalOrigin(payload: payload, responseDelay: options.responseDelay)
            try origin.start()
            defer { origin.stop() }

            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let support = root.appendingPathComponent("support", isDirectory: true)
            let dest = root.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

            let store = try DownloadStore(directory: support)
            let settings = AppSettings(
                downloadDirectory: dest,
                maxConnections: 8,
                useCategoryFolders: false
            )
            // remove(deleteFile: true) throws fileRecyclingUnavailable without a
            // recycler, which would leave every row behind. Delete outright rather
            // than reusing the app's Trash recycler — a soak would otherwise dump
            // thousands of files into the operator's Trash.
            let manager = DownloadManager(
                store: store,
                settings: settings,
                supportRoot: support,
                fileRecycler: { url in
                    try FileManager.default.removeItem(at: url)
                }
            )

            print("""
            Soaking for \(Int(options.duration))s · \(options.concurrency) tasks/cycle \
            · \(options.payloadMB) MB each · origin :\(origin.port)
            """)

            let started = Date()
            var samples: [SoakSample] = []
            var cycles = 0
            var cycleFailures: [String] = []
            var lastSample = Date.distantPast

            func sample() async {
                let rows = (try? await manager.listTasks().count) ?? -1
                let s = SoakSample(
                    elapsed: Date().timeIntervalSince(started),
                    residentBytes: residentBytes(),
                    openFileDescriptors: openFileDescriptorCount(),
                    taskRows: rows,
                    completedCycles: cycles
                )
                samples.append(s)
                print(
                    "  t+\(String(format: "%5.0f", s.elapsed))s  "
                        + "cycle \(String(format: "%4d", cycles))  "
                        + "rss \(SuccessRateReport.bytes(s.residentBytes))  "
                        + "fd \(s.openFileDescriptors)  rows \(s.taskRows)"
                )
                fflush(stdout)
                lastSample = Date()
            }

            await sample()

            while Date().timeIntervalSince(started) < options.duration {
                do {
                    var ids: [Int64] = []
                    for _ in 0..<options.concurrency {
                        let task = try await manager.addURL(origin.url.absoluteString)
                        ids.append(task.id)
                    }
                    for id in ids {
                        try await manager.start(taskID: id)
                    }

                    // Pause mid-flight, then resume: the state transition most
                    // likely to strand a segment handle or a dangling task.
                    try await Task.sleep(nanoseconds: 120_000_000)
                    for id in ids {
                        await manager.pause(taskID: id)
                    }
                    try await Task.sleep(nanoseconds: 60_000_000)
                    for id in ids {
                        try? await manager.start(taskID: id)
                    }

                    let deadline = Date().addingTimeInterval(60)
                    while await manager.hasActiveDownloads(), Date() < deadline {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }

                    // Not `try?`: a removal that silently fails is exactly the
                    // leak this tool exists to catch, so let it be recorded.
                    for id in ids {
                        do {
                            try await manager.remove(taskID: id, deleteFile: true)
                        } catch {
                            cycleFailures.append("remove: \(error.localizedDescription)")
                        }
                    }
                    cycles += 1
                } catch {
                    cycleFailures.append(error.localizedDescription)
                    if cycleFailures.count > 20 {
                        throw SoakFailure(
                            "too many cycle failures; last: \(error.localizedDescription)"
                        )
                    }
                }

                if Date().timeIntervalSince(lastSample) >= options.sampleInterval {
                    await sample()
                }

                // Idle between cycles. Without this the loop pegs a core and writes
                // continuously for no additional signal.
                if options.cyclePause > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(options.cyclePause * 1_000_000_000)
                    )
                }
            }

            await sample()
            origin.stop()

            let analysis = SoakAnalysis(
                samples: samples,
                maxGrowthFraction: options.maxGrowthFraction
            )
            print("\n" + analysis.render())

            if !cycleFailures.isEmpty {
                print("\n  \(cycleFailures.count) cycle error(s); first: \(cycleFailures[0])")
            }

            guard analysis.passed, cycleFailures.isEmpty else { exit(3) }
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("NDMSoak: \(error.localizedDescription)\n".utf8)
            )
            exit(64)
        }
    }
}
