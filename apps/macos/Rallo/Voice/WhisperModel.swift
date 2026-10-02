import CryptoKit
import Foundation

enum WhisperModelError: LocalizedError {
    case http(Int)
    case hashMismatch
    case io

    var errorDescription: String? {
        switch self {
        case let .http(code): "Hugging Face answered with HTTP \(code)."
        case .hashMismatch: "The download didn’t match the expected checksum, so it was discarded."
        case .io: "Rallo couldn’t save the model."
        }
    }
}

/// Finds, downloads and deletes the Whisper model in the shared Hugging Face
/// cache (0014). Nothing leaves the Mac except the download the user asks for.
struct WhisperModel {
    private static let verifiedKey = "whisperVerifiedModels"
    let store: WhisperModelStore

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { store = WhisperModelStore(home: home) }

    /// The model's path if it is installed and intact. Hashing, when needed,
    /// runs off the main thread.
    func locate() async -> URL? {
        let store = store
        return await Task.detached { Self.locateSync(store) }.value
    }

    private static func locateSync(_ store: WhisperModelStore) -> URL? {
        let fm = FileManager.default
        if fileSize(store.blob) == WhisperModelStore.size {
            ensureSnapshot(store)
            return store.snapshot
        }
        let names = (try? fm.contentsOfDirectory(atPath: store.snapshotsDirectory.path)) ?? []
        for name in names.sorted() {
            let url = store.snapshotsDirectory.appendingPathComponent("\(name)/\(WhisperModelStore.fileName)")
            let real = url.resolvingSymlinksInPath()
            guard fileSize(real) == WhisperModelStore.size else { continue }
            let mtime = (try? real.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let key = "\(real.path)|\(WhisperModelStore.size)|\(mtime?.timeIntervalSince1970 ?? 0)"
            var verified = UserDefaults.standard.stringArray(forKey: verifiedKey) ?? []
            if verified.contains(key) { return url }
            if (try? sha256(of: real)) == WhisperModelStore.sha256 {
                verified.append(key)
                UserDefaults.standard.set(verified, forKey: verifiedKey)
                return url
            }
        }
        return nil
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    /// Streams the file through SHA-256 in 4 MB chunks.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 4 << 20) }), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The snapshot symlink, and refs/main only if no other tool wrote one.
    private static func ensureSnapshot(_ store: WhisperModelStore) {
        let fm = FileManager.default
        try? fm.createDirectory(at: store.snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: store.snapshot.path)) == nil, !fm.fileExists(atPath: store.snapshot.path) {
            try? fm.createSymbolicLink(atPath: store.snapshot.path, withDestinationPath: WhisperModelStore.snapshotLinkTarget)
        }
        if !fm.fileExists(atPath: store.refsMain.path) {
            try? fm.createDirectory(at: store.refsMain.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(WhisperModelStore.commit.utf8).write(to: store.refsMain)
        }
    }

    /// Downloads, verifies and installs the model; cancelling the calling task
    /// cancels the transfer. Partial files are removed on failure.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: store.partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: store.partial)
        let partial = store.partial
        do {
            try await Downloader(destination: partial, progress: progress).run()
            try Task.checkCancellation()
            let hash = try await Task.detached { try Self.sha256(of: partial) }.value
            guard hash == WhisperModelStore.sha256 else { throw WhisperModelError.hashMismatch }
            try? fm.removeItem(at: store.blob)
            try fm.moveItem(at: partial, to: store.blob)
            Self.ensureSnapshot(store)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// Removes the snapshot link(s) and the blob. Other tools lose the file.
    func delete() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: store.snapshotsDirectory.path)) ?? [] {
            try? fm.removeItem(at: store.snapshotsDirectory.appendingPathComponent("\(name)/\(WhisperModelStore.fileName)"))
        }
        try? fm.removeItem(at: store.blob)
    }
}

/// One URLSession download with progress; moves the file into place before
/// the system deletes its temporary copy.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var task: URLSessionDownloadTask?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run() async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: WhisperModelStore.url)
                lock.withLock {
                    self.continuation = continuation
                    self.task = task
                }
                task.resume()
            }
        } onCancel: {
            lock.withLock { task }?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite _: Int64) {
        progress(min(1, Double(written) / Double(WhisperModelStore.size)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            lock.withLock { failure = WhisperModelError.http(code) }
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { failure = WhisperModelError.io }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, saved) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            defer { self.continuation = nil }
            return (self.continuation, failure)
        }
        if let error = saved ?? error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}
