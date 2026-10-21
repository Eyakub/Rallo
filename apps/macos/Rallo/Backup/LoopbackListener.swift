import Foundation
import Network

/// A one-shot HTTP listener on 127.0.0.1 for Google's redirect (0024 §4).
/// Accepts connections until one carries something other than a stray
/// `/favicon.ico`, answers it with a short page, then stops.
final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rallo.loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var finished: Result<String, Error>?
    private var port: UInt16 = 0

    /// Binds to a port the system picks; throws if it can't listen.
    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = AsyncStream<NWListener.State> { continuation in
            listener.stateUpdateHandler = { continuation.yield($0) }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        var bound: UInt16?
        for await state in ready {
            if case .ready = state { bound = listener.port?.rawValue; break }
            if case .failed = state { break }
            if case .cancelled = state { break }
        }
        guard let bound else {
            listener.cancel()
            throw GoogleDriveError.failed(0)
        }
        port = bound
    }

    var redirectURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// The request-target of the redirect. Throws `.timedOut` after `timeout`, `.cancelled` after `cancel()`.
    func waitForRequestTarget(timeout: TimeInterval = 300) async throws -> String {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(GoogleDriveError.timedOut)) }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let finished {
                lock.unlock()
                continuation.resume(with: finished)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func cancel() { finish(.failure(GoogleDriveError.cancelled)) }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard finished == nil else { lock.unlock(); return }
        finished = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        listener.cancel()
        pending?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    /// Reads up to the end of the headers (capped), then answers.
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let ended = buffer.range(of: Data("\r\n\r\n".utf8)) != nil || buffer.count >= 16_384
            guard ended || error != nil || complete else { return self.read(connection, buffer: buffer) }
            guard let target = Self.requestTarget(buffer) else { return connection.cancel() }
            if target.hasPrefix("/favicon.ico") {
                return Self.respond(connection, status: "404 Not Found", body: "Not found.")
            }
            let failed = URLComponents(string: "http://127.0.0.1" + target)?.queryItems?.contains { $0.name == "error" } ?? false
            let page = failed ? "Rallo wasn’t connected. You can close this tab and try again."
                              : "Rallo is connected to Google Drive. You can close this tab."
            Self.respond(connection, status: "200 OK", body: page) { self.finish(.success(target)) }
        }
    }

    /// The `<target>` of `GET <target> HTTP/1.1`.
    static func requestTarget(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private static func respond(_ connection: NWConnection, status: String, body: String, then: @escaping () -> Void = {}) {
        let html = "<!doctype html><meta charset=\"utf-8\"><title>Rallo</title>"
            + "<body style=\"font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh\"><p>\(body)</p>"
        let payload = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
            then()
        })
    }
}
