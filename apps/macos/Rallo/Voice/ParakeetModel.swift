import Foundation

/// Finds, downloads and deletes the Parakeet model files in the shared Hugging
/// Face cache (0025). Nothing leaves the Mac except the download the user asks for.
struct ParakeetModel {
    /// (source, destination, bytes written so far); throws on failure.
    typealias Fetch = @Sendable (URL, URL, @escaping @Sendable (Int64) -> Void) async throws -> Void

    let store: ParakeetModelStore
    private let files: [ParakeetFile]
    private let fetch: Fetch

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         files: [ParakeetFile] = ParakeetModelStore.files,
         fetch: @escaping Fetch = ModelDownloader.fetch) {
        store = ParakeetModelStore(home: home)
        self.files = files
        self.fetch = fetch
    }

    /// The snapshot folder to load, if every file is installed and intact.
    /// Hashing, when needed, runs off the main thread.
    func locate() async -> URL? {
        let model = self
        return await Task.detached { model.locateSync() }.value
    }

    private func locateSync() -> URL? {
        guard files.allSatisfy(isVerified) else { return nil }
        ensureSnapshot()
        return store.snapshot
    }

    private func isVerified(_ file: ParakeetFile) -> Bool {
        WhisperModel.verified(store.blob(file), size: file.size, sha256: file.sha256)
    }

    /// Missing or wrong snapshot symlinks, and refs/main only if none exists.
    private func ensureSnapshot() {
        let fm = FileManager.default
        for file in files {
            let entry = store.entry(file)
            let target = store.linkTarget(file)
            if (try? fm.destinationOfSymbolicLink(atPath: entry.path)) == target { continue }
            try? fm.removeItem(at: entry)
            try? fm.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: entry.path, withDestinationPath: target)
        }
        if !fm.fileExists(atPath: store.refsMain.path) {
            try? fm.createDirectory(at: store.refsMain.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(ParakeetModelStore.commit.utf8).write(to: store.refsMain)
        }
    }

    /// Downloads, verifies and installs the files not already intact; cancelling
    /// the calling task cancels the transfer. On failure the partial file and
    /// every blob this run created are removed. Progress is bytes done over the
    /// bytes being fetched.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let model = self
        let todo = await Task.detached { model.files.filter { !model.isVerified($0) } }.value
        let total = Double(todo.reduce(0) { $0 + $1.size })
        try fm.createDirectory(at: store.root.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        var created: [URL] = []
        var current: URL?
        do {
            var done: Int64 = 0
            for file in todo {
                let partial = store.partial(file)
                current = partial
                try? fm.removeItem(at: partial)
                let base = done
                try await fetch(ParakeetModelStore.url(for: file), partial) { progress(min(1, Double(base + $0) / total)) }
                try Task.checkCancellation()
                let hash = try await Task.detached { try WhisperModel.sha256(of: partial) }.value
                guard hash == file.sha256 else { throw WhisperModelError.hashMismatch }
                let blob = store.blob(file)
                try? fm.removeItem(at: blob)
                try fm.moveItem(at: partial, to: blob)
                created.append(blob)
                current = nil
                done += file.size
            }
            ensureSnapshot()
        } catch {
            if let current { try? fm.removeItem(at: current) }
            for blob in created { try? fm.removeItem(at: blob) }
            throw error
        }
    }

    /// Removes this model's snapshot entries and blobs, then folders left empty
    /// under the snapshot. Other snapshots, other blobs and refs/main stay.
    func delete() {
        let fm = FileManager.default
        for file in files {
            let entry = store.entry(file)
            let blob = store.blob(file)
            let points = (try? fm.destinationOfSymbolicLink(atPath: entry.path)) == store.linkTarget(file)
                || entry.resolvingSymlinksInPath().path == blob.resolvingSymlinksInPath().path
            if points { try? fm.removeItem(at: entry) }
            try? fm.removeItem(at: blob)
            try? fm.removeItem(at: store.partial(file))
        }
        let subpaths = (try? fm.subpathsOfDirectory(atPath: store.snapshot.path)) ?? []
        let folders = subpaths.sorted { $0.count > $1.count }.map { store.snapshot.appendingPathComponent($0) } + [store.snapshot]
        for folder in folders {
            let isFolder = (try? fm.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) == .typeDirectory
            if isFolder, (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
        }
    }
}
