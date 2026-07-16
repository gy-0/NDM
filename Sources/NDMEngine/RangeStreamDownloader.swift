import Foundation

/// Streams an HTTP Range (or full GET) into a file with append + progress callbacks.
/// Partial `seg.xN` files remain on cancel so the engine can resume.
enum RangeStreamDownloader {
    struct Result: Sendable {
        var bytesWritten: Int64
        var httpStatus: Int
        var contentLengthHint: Int64?
        var wwwAuthenticate: String?
    }

    static func download(
        request: URLRequest,
        to fileURL: URL,
        append: Bool,
        isCancelled: @escaping @Sendable () -> Bool,
        cancellationTokens: [CancelToken] = [],
        limiter: BandwidthLimiter?,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let box = SessionBox(
                request: request,
                fileURL: fileURL,
                append: append,
                isCancelled: isCancelled,
                cancellationTokens: cancellationTokens,
                limiter: limiter,
                onBytes: onBytes,
                continuation: continuation
            )
            box.start()
        }
    }
}

/// Owns a one-shot URLSession + delegate for a single Range transfer.
private final class SessionBox: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let fileURL: URL
    private let append: Bool
    private let isCancelled: @Sendable () -> Bool
    private let cancellationTokens: [CancelToken]
    private let limiter: BandwidthLimiter?
    private let onBytes: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<RangeStreamDownloader.Result, Error>?
    private var session: URLSession!
    private var dataTask: URLSessionDataTask?
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var lastReported: Int64 = 0
    private var status = 0
    private var contentLengthHint: Int64?
    private var wwwAuthenticate: String?
    private var finished = false
    private let finishLock = NSLock()
    private var cancellationHandlerIDs: [(CancelToken, UUID)] = []

    init(
        request: URLRequest,
        fileURL: URL,
        append: Bool,
        isCancelled: @escaping @Sendable () -> Bool,
        cancellationTokens: [CancelToken],
        limiter: BandwidthLimiter?,
        onBytes: @escaping @Sendable (Int64) -> Void,
        continuation: CheckedContinuation<RangeStreamDownloader.Result, Error>
    ) {
        self.request = request
        self.fileURL = fileURL
        self.append = append
        self.isCancelled = isCancelled
        self.cancellationTokens = cancellationTokens
        self.limiter = limiter
        self.onBytes = onBytes
        self.continuation = continuation
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start() {
        let task = session.dataTask(with: request)
        dataTask = task
        cancellationHandlerIDs = cancellationTokens.map { token in
            let id = token.registerCancellationHandler { [weak self] in
                self?.dataTask?.cancel()
            }
            return (token, id)
        }
        guard !isCancelled() else {
            finish(.failure(EngineError.cancelled))
            return
        }
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if isCancelled() {
            completionHandler(.cancel)
            finish(.failure(EngineError.cancelled))
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(EngineError.invalidResponse))
            return
        }
        status = http.statusCode
        wwwAuthenticate = http.value(forHTTPHeaderField: "WWW-Authenticate")
            ?? http.value(forHTTPHeaderField: "Proxy-Authenticate")

        if status == 401 || status == 407 {
            completionHandler(.cancel)
            finish(.failure(EngineError.authRequired(status: status, challenge: wwwAuthenticate)))
            return
        }

        guard (200..<300).contains(status) || status == 206 else {
            completionHandler(.cancel)
            finish(.failure(EngineError.httpStatus(status)))
            return
        }
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let total = cr.split(separator: "/").last,
           let n = Int64(total), n > 0 {
            contentLengthHint = n
        } else if http.expectedContentLength > 0 {
            contentLengthHint = http.expectedContentLength
        }

        do {
            if !append || !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: fileURL)
            if append {
                try handle?.seekToEnd()
            } else {
                try handle?.truncate(atOffset: 0)
                try handle?.seek(toOffset: 0)
            }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if isCancelled() {
            dataTask.cancel()
            finish(.failure(EngineError.cancelled))
            return
        }
        limiter?.consume(data.count)
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            if written - lastReported >= 256 * 1024 {
                lastReported = written
                onBytes(written)
            }
        } catch {
            dataTask.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if finished { return }
        if written != lastReported {
            lastReported = written
            onBytes(written)
        }
        if let error {
            if isCancelled() || (error as NSError).code == NSURLErrorCancelled {
                // 401 path already finished via authRequired in didReceive response
                finish(.failure(EngineError.cancelled))
            } else {
                finish(.failure(error))
            }
            return
        }
        finish(.success(RangeStreamDownloader.Result(
            bytesWritten: written,
            httpStatus: status,
            contentLengthHint: contentLengthHint,
            wwwAuthenticate: wwwAuthenticate
        )))
    }

    private func finish(_ result: Result<RangeStreamDownloader.Result, Error>) {
        finishLock.lock()
        guard !finished else {
            finishLock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let registrations = cancellationHandlerIDs
        cancellationHandlerIDs.removeAll()
        finishLock.unlock()

        for (token, id) in registrations {
            token.removeCancellationHandler(id)
        }
        // Replanning must not inspect/truncate a segment until its writer is closed.
        // `finish` can be reached from didReceive(data:) before didCompleteWithError.
        try? handle?.close()
        handle = nil
        session.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
