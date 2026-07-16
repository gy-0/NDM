import Foundation
import Network

/// Minimal HTTP server supporting HEAD / GET / Range for engine integration tests.
final class LocalRangeServer: @unchecked Sendable {
    private let payload: Data
    private let responseDelay: TimeInterval
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ndm.test.httpserver")
    private let recordLock = NSLock()
    private var _recordedRanges: [String] = []
    private(set) var port: UInt16 = 0

    init(payload: Data, responseDelay: TimeInterval = 0) {
        self.payload = payload
        self.responseDelay = responseDelay
    }

    var recordedRanges: [String] {
        recordLock.lock(); defer { recordLock.unlock() }
        return _recordedRanges
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let p = listener.port?.rawValue {
                    self?.port = p
                }
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        guard port != 0 else { throw NSError(domain: "LocalRangeServer", code: 1) }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/file.bin")! }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            if let range = req.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("range:") }) {
                self.recordLock.lock()
                self._recordedRanges.append(range)
                self.recordLock.unlock()
            }
            let response = self.buildResponse(for: req)
            let send = {
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            if self.responseDelay > 0 {
                self.queue.asyncAfter(deadline: .now() + self.responseDelay, execute: send)
            } else {
                send()
            }
        }
    }

    private func buildResponse(for request: String) -> Data {
        let lines = request.components(separatedBy: "\r\n")
        let first = lines.first ?? ""
        let method = first.split(separator: " ").first.map(String.init) ?? "GET"
        let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range:") })
        let total = payload.count

        if method == "HEAD" {
            var h = "HTTP/1.1 200 OK\r\n"
            h += "Content-Length: \(total)\r\n"
            h += "Accept-Ranges: bytes\r\n"
            h += "Content-Type: application/octet-stream\r\n"
            h += "Connection: close\r\n\r\n"
            return Data(h.utf8)
        }

        if let rangeHeader {
            // bytes=START-END
            let spec = rangeHeader.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let body = spec.replacingOccurrences(of: "bytes=", with: "")
            let parts = body.split(separator: "-")
            let start = Int(parts.first ?? "0") ?? 0
            let end: Int
            if parts.count > 1, let e = Int(parts[1]) {
                end = min(e, total - 1)
            } else {
                end = total - 1
            }
            let slice = payload.subdata(in: start..<(end + 1))
            var h = "HTTP/1.1 206 Partial Content\r\n"
            h += "Content-Length: \(slice.count)\r\n"
            h += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
            h += "Accept-Ranges: bytes\r\n"
            h += "Content-Type: application/octet-stream\r\n"
            h += "Connection: close\r\n\r\n"
            var out = Data(h.utf8)
            out.append(slice)
            return out
        }

        var h = "HTTP/1.1 200 OK\r\n"
        h += "Content-Length: \(total)\r\n"
        h += "Accept-Ranges: bytes\r\n"
        h += "Content-Type: application/octet-stream\r\n"
        h += "Connection: close\r\n\r\n"
        var out = Data(h.utf8)
        out.append(payload)
        return out
    }
}
