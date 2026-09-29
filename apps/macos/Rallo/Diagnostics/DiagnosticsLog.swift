import Foundation

/// Append-only JSON-lines event log under `<data dir>/diagnostics/`.
/// Records identifiers and states only — never note text.
final class DiagnosticsLog: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.razlio.rallo.diagnostics")
    private let file: URL

    init(dataDir: String) {
        directory = URL(fileURLWithPath: dataDir, isDirectory: true).appendingPathComponent("diagnostics", isDirectory: true)
        file = directory.appendingPathComponent("events.jsonl")
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        var entry = fields
        entry["event"] = event
        entry["at_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
        entry["pid"] = ProcessInfo.processInfo.processIdentifier
        queue.async { [directory, file] in
            guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        }
    }

    func write(_ name: String, data: Data) {
        queue.async { [directory] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(name)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
