import Foundation
import CommonCrypto
import NDMCore

/// HLS path: fetch master/media m3u8 → download TS segments → concat to one `.ts` file.
/// Aligns with original `hlsMode` / `NeatSocketHlsMaster` behaviour (download all TS then merge).
public actor HLSEngine {
    public private(set) var progress: DownloadProgress

    private let request: DownloadRequest
    private let taskID: Int64
    private let workDirectory: URL
    private let session: URLSession
    private let token = CancelToken()
    private var logHandle: FileHandle?

    public init(
        taskID: Int64,
        request: DownloadRequest,
        workDirectory: URL,
        httpProxy: ProxySettings? = nil,
        socksProxy: SocksProxySettings? = nil
    ) {
        self.taskID = taskID
        self.request = request
        self.workDirectory = workDirectory
        self.progress = DownloadProgress(taskID: taskID, status: .waiting)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        if let socks = socksProxy, socks.enabled, !socks.host.isEmpty {
            var dict: [AnyHashable: Any] = [
                kCFStreamPropertySOCKSProxyHost as String: socks.host,
                kCFStreamPropertySOCKSProxyPort as String: NSNumber(value: socks.port),
                kCFStreamPropertySOCKSVersion as String: socks.version == .v4
                    ? kCFStreamSocketSOCKSVersion4 : kCFStreamSocketSOCKSVersion5,
            ]
            if let u = socks.username { dict[kCFStreamPropertySOCKSUser as String] = u }
            if let p = socks.password { dict[kCFStreamPropertySOCKSPassword as String] = p }
            config.connectionProxyDictionary = dict
        } else if let proxy = httpProxy, proxy.enabled, !proxy.host.isEmpty {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: proxy.host,
                kCFNetworkProxiesHTTPPort as String: NSNumber(value: proxy.port),
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: proxy.host,
                kCFNetworkProxiesHTTPSPort as String: NSNumber(value: proxy.port),
            ]
        }
        self.session = URLSession(configuration: config)
    }

    public func pause() {
        token.pause()
        progress.status = .paused
        log("HLS engine paused")
    }

    public func cancel() {
        token.cancel()
        session.invalidateAndCancel()
        progress.status = .incomplete
        log("HLS Download Canceled By User.")
    }

    public func currentProgress() -> DownloadProgress { progress }

    @discardableResult
    public func start() async throws -> URL {
        guard !Task.isCancelled else { throw EngineError.cancelled }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        token.reset()
        openLog()
        progress.status = .downloading
        log("DownloadID = \(taskID) , Protocol = HLS , OS = MAC")
        log("Trying to Start HLS Download for -> \(request.url.absoluteString)")

        let media = try await resolveMediaPlaylist(startingAt: request.url)
        log("TS-Mode Sockets Created. hlsSegmentsCount = \(media.segments.count)")

        var keyData: Data?
        if let key = media.key, key.isAES128 {
            guard let uri = key.uri,
                  let keyURL = HLSPlaylist.resolveURL(uri, against: request.url) else {
                throw HLSError.missingKey
            }
            keyData = try await fetchData(keyURL)
            log("Loaded AES-128 key (\(keyData?.count ?? 0) bytes)")
        }

        progress.segmentStates = media.segments.map {
            SegmentState(id: $0.id, start: 0, end: 0, completed: 0, isFinished: false)
        }
        progress.totalBytes = Int64(media.segments.count) // segment count as progress denominator unit

        let tsDir = workDirectory.appendingPathComponent("ts", isDirectory: true)
        try FileManager.default.createDirectory(at: tsDir, withIntermediateDirectories: true)

        var completed: Int64 = 0
        for (index, seg) in media.segments.enumerated() {
            if token.isCancelled {
                if token.isPaused { throw EngineError.paused }
                throw EngineError.cancelled
            }
            let partURL = tsDir.appendingPathComponent(String(format: "seg_%05d.ts", index))
            // Resume: skip segments already on disk (G06).
            if FileManager.default.fileExists(atPath: partURL.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path),
               let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 {
                completed += 1
                progress.completedBytes = completed
                if index < progress.segmentStates.count {
                    progress.segmentStates[index].completed = 1
                    progress.segmentStates[index].isFinished = true
                }
                log("TS-Segment \(index + 1)/\(media.segments.count) resumed from disk")
                continue
            }
            guard let segURL = HLSPlaylist.resolveURL(seg.uri, against: request.url) else {
                throw HLSError.unresolvedURL(seg.uri)
            }
            var data = try await fetchData(segURL, byteRange: seg.byteRange)
            if let keyData, let key = media.key, key.isAES128 {
                let iv = Self.ivData(hex: key.ivHex, mediaSequence: seg.id)
                data = try Self.decryptAES128(data, key: keyData, iv: iv)
            }
            try data.write(to: partURL, options: .atomic)
            completed += 1
            progress.completedBytes = completed
            if index < progress.segmentStates.count {
                progress.segmentStates[index].completed = 1
                progress.segmentStates[index].isFinished = true
            }
            log("TS-Segment \(index + 1)/\(media.segments.count) ok (\(data.count) bytes)")
        }

        log("DownloadEngine State Changed : Downloading... -> Merging...")
        let filename = outputFilename()
        try FileManager.default.createDirectory(
            at: request.destinationDirectory,
            withIntermediateDirectories: true
        )

        // Merge in the work directory first, then finalize into the destination.
        let mergedURL = workDirectory.appendingPathComponent("merged.ts")
        try mergeTS(count: media.segments.count, from: tsDir, to: mergedURL)

        // "下完就是能播的 MP4": lossless remux by default when ffmpeg is present.
        // Fake/broken streams (or exotic codecs) fail fast → keep the TS as-is.
        var finalURL = request.destinationDirectory.appendingPathComponent(filename)
        if let ffmpeg = FFmpegTool.find() {
            let mp4URL = request.destinationDirectory
                .appendingPathComponent((filename as NSString).deletingPathExtension)
                .appendingPathExtension("mp4")
            do {
                try FFmpegTool.remuxToMP4(ffmpeg: ffmpeg, input: mergedURL, output: mp4URL)
                finalURL = mp4URL
                try? FileManager.default.removeItem(at: mergedURL)
                log("Remuxed TS -> MP4 (stream copy, faststart)")
            } catch {
                log("MP4 remux unavailable for this stream; keeping TS. \(error.localizedDescription)")
                finalURL = Self.tsFallbackURL(for: finalURL)
                try Self.replaceItem(at: finalURL, with: mergedURL)
            }
        } else {
            log("ffmpeg not found; keeping TS output")
            finalURL = Self.tsFallbackURL(for: finalURL)
            try Self.replaceItem(at: finalURL, with: mergedURL)
        }

        progress.status = .complete
        progress.completedBytes = progress.totalBytes
        let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        progress.totalBytes = size
        progress.completedBytes = size
        log("DownloadEngine State Changed : Merging... -> Completed")
        closeLog()
        return finalURL
    }

    // MARK: - Playlist

    private func resolveMediaPlaylist(startingAt url: URL) async throws -> HLSPlaylist.Media {
        let text = try await fetchText(url)
        switch try HLSPlaylist.parse(text) {
        case .media(let media):
            return media
        case .master(let master):
            guard let variant = master.preferredVariant,
                  let mediaURL = HLSPlaylist.resolveURL(variant.uri, against: url) else {
                throw HLSError.emptyMaster
            }
            log("Selected HLS variant bandwidth=\(variant.bandwidth) -> \(mediaURL.absoluteString)")
            let mediaText = try await fetchText(mediaURL)
            guard case .media(let media) = try HLSPlaylist.parse(mediaText) else {
                throw HLSError.emptyMedia
            }
            // Re-base segment URLs against media playlist URL by swapping request.url context:
            // fetch uses resolve against request.url — update via returning media with absolute URIs.
            return absolutize(media, base: mediaURL)
        }
    }

    private func absolutize(_ media: HLSPlaylist.Media, base: URL) -> HLSPlaylist.Media {
        var copy = media
        copy.segments = media.segments.map { seg in
            var s = seg
            if let abs = HLSPlaylist.resolveURL(seg.uri, against: base) {
                s.uri = abs.absoluteString
            }
            return s
        }
        if var key = copy.key, let uri = key.uri, let abs = HLSPlaylist.resolveURL(uri, against: base) {
            key.uri = abs.absoluteString
            copy.key = key
        }
        return copy
    }

    // MARK: - Network

    private func fetchText(_ url: URL) async throws -> String {
        let data = try await fetchData(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EngineError.invalidResponse
        }
        return text
    }

    private func fetchData(_ url: URL, byteRange: HLSPlaylist.ByteRange? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let ua = request.userAgent {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        for (k, v) in request.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let br = byteRange {
            if let off = br.offset {
                req.setValue("bytes=\(off)-\(off + br.length - 1)", forHTTPHeaderField: "Range")
            } else {
                req.setValue("bytes=0-\(br.length - 1)", forHTTPHeaderField: "Range")
            }
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) || http.statusCode == 206 else {
            throw EngineError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    // MARK: - Merge / crypto

    private func mergeTS(count: Int, from dir: URL, to finalURL: URL) throws {
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        FileManager.default.createFile(atPath: finalURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: finalURL)
        defer { try? out.close() }
        for i in 0..<count {
            let part = dir.appendingPathComponent(String(format: "seg_%05d.ts", i))
            let data = try Data(contentsOf: part)
            try out.write(contentsOf: data)
        }
    }

    /// A requested `.mp4` name must not end up holding raw TS bytes when the
    /// remux couldn't run — relabel the fallback file honestly.
    private static func tsFallbackURL(for url: URL) -> URL {
        guard url.pathExtension.lowercased() == "mp4" else { return url }
        return url.deletingPathExtension().appendingPathExtension("ts")
    }

    /// Move (or copy across volumes) the merged file into its destination.
    private static func replaceItem(at destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
            try? FileManager.default.removeItem(at: source)
        }
    }

    private func outputFilename() -> String {
        if let suggested = request.suggestedFilename, !suggested.isEmpty {
            if suggested.lowercased().hasSuffix(".m3u8") {
                return String(suggested.dropLast(5)) + ".ts"
            }
            if suggested.lowercased().hasSuffix(".ts") { return suggested }
            return suggested
        }
        let base = request.url.deletingPathExtension().lastPathComponent
        return (base.isEmpty ? "stream" : base) + ".ts"
    }

    static func ivData(hex: String?, mediaSequence: Int) -> Data {
        if let hex, let data = Data(hexString: hex), data.count == 16 {
            return data
        }
        // Default IV = media sequence as 16-byte big-endian
        var bytes = [UInt8](repeating: 0, count: 16)
        var seq = UInt64(mediaSequence).bigEndian
        withUnsafeBytes(of: &seq) { raw in
            for i in 0..<8 {
                bytes[8 + i] = raw[i]
            }
        }
        return Data(bytes)
    }

    static func decryptAES128(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16, iv.count == 16 else { throw HLSError.decryptFailed }
        var outLength = data.count + kCCBlockSizeAES128
        var out = Data(count: outLength)
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
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
        guard status == kCCSuccess else { throw HLSError.decryptFailed }
        out.count = outLength
        return out
    }

    // MARK: - Log

    private func openLog() {
        let url = workDirectory.appendingPathComponent("LogFile.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: url)
        _ = try? logHandle?.seekToEnd()
        log("Opening LogFile...")
    }

    private func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func log(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let formatted = "INFO   \(f.string(from: Date())) ( \(Int(Date().timeIntervalSince1970)) )   \(line)\n"
        if let data = formatted.data(using: .utf8) {
            try? logHandle?.write(contentsOf: data)
        }
    }
}

private extension Data {
    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        self = data
    }
}
