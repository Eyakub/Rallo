import Foundation

/// A URLProtocol that answers from `handler` and records every request, so tests never touch the network.
final class StubURLProtocol: URLProtocol {
    struct Seen { let request: URLRequest; let body: Data }
    typealias Handler = (URLRequest, Data) throws -> (status: Int, headers: [String: String], body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [Seen] = []

    static var seen: [Seen] { lock.withLock { recorded } }

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> (status: Int, headers: [String: String], body: Data) {
        (status, headers, (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let handler = Self.lock.withLock { () -> Handler? in
            Self.recorded.append(Seen(request: request, body: body))
            return Self.handler
        }
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let answer = try handler(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// A token store for tests: never the real Keychain item.
final class MemoryTokenStore: GoogleTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ token: String? = nil) { self.token = token }
    func exists() -> Bool { lock.withLock { token != nil } }
    func read() -> String? { lock.withLock { token } }
    func save(_ token: String) -> Bool { lock.withLock { self.token = token }; return true }
    func delete() { lock.withLock { token = nil } }
}

func formFields(_ body: Data) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = String(data: body, encoding: .utf8)
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}
