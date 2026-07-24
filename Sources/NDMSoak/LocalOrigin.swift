import Foundation
import Network

/// A local HTTP origin with Range support and optional throttling.
///
/// The soak runs against this rather than a public mirror on purpose. Hammering
/// someone else's CDN for hours is abusive, and it also produces false results:
/// a mirror that starts rate-limiting will serve interstitial pages, so the run
/// would measure the mirror's patience instead of this process's stability.
final class LocalOrigin: @unchecked Sendable {
    private let payload: Data
    /// Delay inserted before each response so a transfer lasts long enough for
    /// pause and resume to actually interleave with it.
    private let responseDelay: TimeInterval
    private let queue = DispatchQueue(label: "ndm.soak.origin")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(payload: Data, responseDelay: TimeInterval = 0.01) {
        self.payload = payload
        self.responseDelay = responseDelay
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/soak.bin")! }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let p = listener.port?.rawValue { self?.port = p }
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard port != 0 else {
            throw NSError(
                domain: "LocalOrigin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "the local origin never became ready"]
            )
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let response = self.buildResponse(for: request)
            self.queue.asyncAfter(deadline: .now() + self.responseDelay) {
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func buildResponse(for request: String) -> Data {
        let lines = request.components(separatedBy: "\r\n")
        let method = (lines.first ?? "").split(separator: " ").first.map(String.init) ?? "GET"
        let total = payload.count

        if method == "HEAD" {
            return header(status: "200 OK", length: total, extra: ["Accept-Ranges: bytes"])
        }

        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let spec = (rangeLine.split(separator: ":", maxSplits: 1).last ?? "")
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts.first ?? "0") ?? 0
            guard start >= 0, start < total else {
                return header(status: "416 Range Not Satisfiable", extra: ["Content-Range: bytes */\(total)"])
            }
            let end = parts.count > 1 ? (Int(parts[1]).map { min($0, total - 1) } ?? total - 1) : total - 1
            let slice = payload.subdata(in: start..<(end + 1))
            var out = header(
                status: "206 Partial Content",
                length: slice.count,
                extra: ["Content-Range: bytes \(start)-\(end)/\(total)", "Accept-Ranges: bytes"]
            )
            out.append(slice)
            return out
        }

        var out = header(status: "200 OK", length: total, extra: ["Accept-Ranges: bytes"])
        out.append(payload)
        return out
    }

    private func header(status: String, length: Int = 0, extra: [String] = []) -> Data {
        var h = "HTTP/1.1 \(status)\r\n"
        h += "Content-Length: \(length)\r\n"
        h += "Content-Type: application/octet-stream\r\n"
        for line in extra { h += line + "\r\n" }
        h += "Connection: close\r\n\r\n"
        return Data(h.utf8)
    }
}
