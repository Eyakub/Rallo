import CryptoKit
import Foundation
import os

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
    private static let launchVerified = OSAllocatedUnfairLock(initialState: Set<String>())
    let store: WhisperModelStore

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, kind: WhisperModelKind) {
        store = WhisperModelStore(home: home, kind: kind)
    }

    /// The model's path if it is installed and intact. Hashing, when needed,
    /// runs off the main thread.
    func locate() async -> URL? {
        let store = store
        return await Task.detached { Self.locateSync(store) }.value
    }

    private static func locateSync(_ store: WhisperModelStore) -> URL? {
        if verified(store.blob, store.kind) {
            ensureSnapshot(store)
            return store.blob
        }
        // A copy another tool put in a snapshot.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: store.snapshotsDirectory.path)) ?? []
        for name in names.sorted() {
            let real = store.snapshotsDirectory.appendingPathComponent("\(name)/\(store.kind.fileName)")
                .resolvingSymlinksInPath()
            if verified(real, store.kind) { return real }
        }
        return nil
    }

    /// Right size and SHA-256, hashed once per launch (a changed size or date
    /// hashes again): whisper.cpp parses it in a process with mic access.
    private static func verified(_ url: URL, _ kind: WhisperModelKind) -> Bool {
        guard fileSize(url) == kind.size else { return false }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(mtime?.timeIntervalSince1970 ?? 0)"
        if launchVerified.withLock({ $0.contains(key) }) { return true }
        guard (try? sha256(of: url)) == kind.sha256 else { return false }
        launchVerified.withLock { _ = $0.insert(key) }
        return true
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
            try? fm.createSymbolicLink(atPath: store.snapshot.path, withDestinationPath: store.snapshotLinkTarget)
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
            try await Downloader(kind: store.kind, destination: partial, progress: progress).run()
            try Task.checkCancellation()
            let hash = try await Task.detached { try Self.sha256(of: partial) }.value
            guard hash == store.kind.sha256 else { throw WhisperModelError.hashMismatch }
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
        // Only entries that resolve to Rallo's blob; other revisions are someone else's.
        let blob = store.blob.resolvingSymlinksInPath().path
        for name in (try? fm.contentsOfDirectory(atPath: store.snapshotsDirectory.path)) ?? [] {
            let entry = store.snapshotsDirectory.appendingPathComponent("\(name)/\(store.kind.fileName)")
            if entry.resolvingSymlinksInPath().path == blob { try? fm.removeItem(at: entry) }
        }
        try? fm.removeItem(at: store.blob)
    }
}

extension WhisperModelKind {
    /// The saved choice; with none, applies `defaultKind` (hashing the 16-bit
    /// file off the main thread if needed) and saves it.
    static func resolved() async -> WhisperModelKind {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) { return saved }
        let kind = defaultKind(turbo16Installed: await WhisperModel(kind: .turbo16).locate() != nil)
        UserDefaults.standard.set(kind.rawValue, forKey: defaultsKey)
        return kind
    }
}

/// One URLSession download with progress; moves the file into place before
/// the system deletes its temporary copy.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let kind: WhisperModelKind
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var task: URLSessionDownloadTask?

    init(kind: WhisperModelKind, destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.kind = kind
        self.destination = destination
        self.progress = progress
    }

    func run() async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: kind.url)
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
        progress(min(1, Double(written) / Double(kind.size)))
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
