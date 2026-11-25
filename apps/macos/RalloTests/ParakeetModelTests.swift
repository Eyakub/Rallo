import CryptoKit
import XCTest

final class ParakeetModelTests: XCTestCase {
    func testPinnedFiles() {
        let files = ParakeetModelStore.files
        XCTAssertEqual(files.count, 21)
        XCTAssertEqual(ParakeetModelStore.totalSize, 464_413_247)
        XCTAssertEqual(Set(files.map(\.path)).count, 21)
        XCTAssertTrue(files.allSatisfy { $0.sha256.count == 64 })
        XCTAssertEqual(files.first { $0.path == "Encoder.mlmodelc/weights/weight.bin" },
                       ParakeetFile(path: "Encoder.mlmodelc/weights/weight.bin", size: 445_187_200,
                                    sha256: "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e"))
        XCTAssertEqual(files.first { $0.path == "parakeet_vocab.json" }?.sha256,
                       "57019fe3c745772ca83a1b048a4bb951cd51329504ea33d4d83316b96e279a97")
    }

    func testStorePaths() {
        let store = ParakeetModelStore(home: URL(fileURLWithPath: "/Users/x"))
        let root = "/Users/x/.cache/huggingface/hub/models--FluidInference--parakeet-tdt-0.6b-v2-coreml"
        let weights = ParakeetModelStore.files.first { $0.path == "Encoder.mlmodelc/weights/weight.bin" }!
        let vocab = ParakeetModelStore.files.first { $0.path == "parakeet_vocab.json" }!
        XCTAssertEqual(store.snapshot.path, "\(root)/snapshots/ee09c569f73759e6d44c9bd16766f477b2b36d39")
        XCTAssertEqual(store.blob(weights).path, "\(root)/blobs/\(weights.sha256)")
        XCTAssertEqual(store.partial(weights).path, "\(root)/blobs/\(weights.sha256).rallo-download")
        XCTAssertEqual(store.entry(weights).path, "\(store.snapshot.path)/Encoder.mlmodelc/weights/weight.bin")
        XCTAssertEqual(store.linkTarget(weights), "../../../../blobs/\(weights.sha256)")
        XCTAssertEqual(store.linkTarget(vocab), "../../blobs/\(vocab.sha256)")
        XCTAssertEqual(store.refsMain.path, "\(root)/refs/main")
        XCTAssertEqual(ParakeetModelStore.url(for: weights).absoluteString,
                       "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/resolve/ee09c569f73759e6d44c9bd16766f477b2b36d39/Encoder.mlmodelc/weights/weight.bin")
    }

    // MARK: I/O with a temp home and fake files

    private var temp: URL!
    private var home: URL { temp.appendingPathComponent("home") }
    private var source: URL { temp.appendingPathComponent("source") }
    private var store: ParakeetModelStore { ParakeetModelStore(home: home) }
    private let fetchCount = OSAllocatedCounter()

    private static let contents: [String: Data] = [
        "A.mlmodelc/weights/weight.bin": Data("weights-bytes-0123456789".utf8),
        "A.mlmodelc/model.mil": Data("program".utf8),
        "vocab.json": Data("{\"0\":\"a\"}".utf8),
    ]

    private var files: [ParakeetFile] {
        Self.contents.keys.sorted().map { path in
            let data = Self.contents[path]!
            return ParakeetFile(path: path, size: Int64(data.count),
                                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    }

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-\(UUID().uuidString)")
        for (path, data) in Self.contents {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func model(failOn failing: String? = nil, corrupt: Bool = false) -> ParakeetModel {
        let source = source, counter = fetchCount
        return ParakeetModel(home: home, files: files) { url, destination, written in
            counter.increment()
            let path = url.path.components(separatedBy: "/resolve/\(ParakeetModelStore.commit)/")[1]
            if path == failing { throw WhisperModelError.io }
            var data = try Data(contentsOf: source.appendingPathComponent(path))
            if corrupt { data = Data(data.map { $0 ^ 0xFF }) }
            try data.write(to: destination)
            written(Int64(data.count))
        }
    }

    private func blobNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("blobs").path)) ?? []
    }

    func testDownloadInstallsLocatesAndDeletes() async throws {
        let model = model()
        try await model.download { _ in }
        let located = await model.locate()
        XCTAssertEqual(located, store.snapshot)
        let read = try Data(contentsOf: store.snapshot.appendingPathComponent("A.mlmodelc/weights/weight.bin"))
        XCTAssertEqual(read, Self.contents["A.mlmodelc/weights/weight.bin"])
        XCTAssertEqual(try String(contentsOf: store.refsMain, encoding: .utf8), ParakeetModelStore.commit)
        model.delete()
        let after = await model.locate()
        XCTAssertNil(after)
        for file in files { XCTAssertFalse(FileManager.default.fileExists(atPath: store.blob(file).path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshot.path))
    }

    func testDamagedFileIsNotLocated() async throws {
        let model = model()
        try await model.download { _ in }
        let before = await model.locate()
        XCTAssertEqual(before, store.snapshot)
        let victim = files[0]
        let blob = store.blob(victim)
        try Data(repeating: 0x41, count: Int(victim.size)).write(to: blob)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: blob.path)
        let located = await model.locate()
        XCTAssertNil(located)
    }

    func testFailedDownloadLeavesNothing() async throws {
        let model = model(failOn: files[1].path)
        do {
            try await model.download { _ in }
            XCTFail("expected throw")
        } catch {}
        XCTAssertEqual(blobNames(), [])
        let located = await model.locate()
        XCTAssertNil(located)
    }

    func testHashMismatchIsRejected() async throws {
        let model = model(corrupt: true)
        do {
            try await model.download { _ in }
            XCTFail("expected throw")
        } catch WhisperModelError.hashMismatch {}
        XCTAssertEqual(blobNames(), [])
    }

    func testDeleteLeavesOtherSnapshots() async throws {
        let model = model()
        let other = store.snapshotsDirectory.appendingPathComponent("0000000000000000000000000000000000000000/other.txt")
        let unrelated = store.root.appendingPathComponent("blobs/unrelated")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other)
        try Data("y".utf8).write(to: unrelated)
        try await model.download { _ in }
        model.delete()
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.refsMain.path))
    }

    func testSymlinkedFolderIsNeverReturnedUnverified() async throws {
        let model = model()
        try await model.download { _ in }
        let folder = store.snapshot.appendingPathComponent("A.mlmodelc")
        let evil = temp.appendingPathComponent("evil/A.mlmodelc")
        try FileManager.default.createDirectory(at: evil.appendingPathComponent("weights"), withIntermediateDirectories: true)
        for path in ["weights/weight.bin", "model.mil"] {
            let size = Self.contents["A.mlmodelc/\(path)"]!.count
            try Data(repeating: 0x41, count: size).write(to: evil.appendingPathComponent(path))
        }
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: evil)
        let located = await model.locate()
        XCTAssertNil(located)
    }

    func testUnpinnedModelPartsAreNotLocated() async throws {
        let model = model()
        try await model.download { _ in }
        let ctc = store.snapshot.appendingPathComponent("CtcHead.mlmodelc/model.mil")
        try FileManager.default.createDirectory(at: ctc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: ctc)
        let withCtc = await model.locate()
        XCTAssertNil(withCtc)
        try FileManager.default.removeItem(at: ctc.deletingLastPathComponent())
        let clean = await model.locate()
        XCTAssertEqual(clean, store.snapshot)
        let extra = store.snapshot.appendingPathComponent("A.mlmodelc/extra.bin")
        try Data("x".utf8).write(to: extra)
        let withExtra = await model.locate()
        XCTAssertNil(withExtra)
    }

    func testSymlinkedModelFolderIsNotLocated() async throws {
        let model = model()
        try await model.download { _ in }
        let fm = FileManager.default
        let folder = store.snapshot.appendingPathComponent("A.mlmodelc")
        // Same depth as the snapshot, so the entries' relative blob links still resolve.
        let moved = store.snapshot.deletingLastPathComponent().appendingPathComponent("other/A.mlmodelc")
        try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: folder, to: moved)
        try Data("x".utf8).write(to: moved.appendingPathComponent("extra.bin"))
        try fm.createSymbolicLink(atPath: folder.path, withDestinationPath: moved.path)
        let located = await model.locate()
        XCTAssertNil(located)
    }

    func testSymlinkedSubfolderIsNotLocated() async throws {
        let model = model()
        try await model.download { _ in }
        let fm = FileManager.default
        let weights = store.snapshot.appendingPathComponent("A.mlmodelc/weights")
        let elsewhere = store.snapshot.appendingPathComponent("elsewhere/weights")
        let pinned = files.first { $0.path == "A.mlmodelc/weights/weight.bin" }!
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: elsewhere.appendingPathComponent("weight.bin").path,
                                  withDestinationPath: store.linkTarget(pinned))
        try Data("x".utf8).write(to: elsewhere.appendingPathComponent("extra.bin"))
        try fm.removeItem(at: weights)
        try fm.createSymbolicLink(atPath: weights.path, withDestinationPath: elsewhere.path)
        let located = await model.locate()
        XCTAssertNil(located)
    }

    func testFinderDSStoreIsIgnored() async throws {
        let model = model()
        try await model.download { _ in }
        let fm = FileManager.default
        let top = store.snapshot.appendingPathComponent("A.mlmodelc/.DS_Store")
        let deep = store.snapshot.appendingPathComponent("A.mlmodelc/weights/.DS_Store")
        try Data("x".utf8).write(to: top)
        try Data("x".utf8).write(to: deep)
        let withStores = await model.locate()
        XCTAssertEqual(withStores, store.snapshot)
        let target = temp.appendingPathComponent("target.bin")
        try Data("x".utf8).write(to: target)
        try fm.removeItem(at: top)
        try fm.createSymbolicLink(atPath: top.path, withDestinationPath: target.path)
        let withLink = await model.locate()
        XCTAssertNil(withLink)
    }

    func testUnrelatedRootItemsDoNotBlockLocate() async throws {
        let model = model()
        try await model.download { _ in }
        try Data("hi".utf8).write(to: store.snapshot.appendingPathComponent("README.md"))
        let located = await model.locate()
        XCTAssertEqual(located, store.snapshot)
    }

    func testDeleteKeepsBlobsSharedWithAnotherRevision() async throws {
        let model = model()
        try await model.download { _ in }
        let shared = files.first { $0.path == "A.mlmodelc/weights/weight.bin" }!
        let link = store.snapshotsDirectory.appendingPathComponent("1111111111111111111111111111111111111111/A.mlmodelc/weights/weight.bin")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../../blobs/\(shared.sha256)")
        model.delete()
        XCTAssertEqual(try Data(contentsOf: link), Self.contents[shared.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.blob(shared).path))
        for file in files where file != shared {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.blob(file).path))
        }
        let located = await model.locate()
        XCTAssertNil(located)
    }

    func testAlreadyVerifiedFilesAreNotFetchedAgain() async throws {
        let model = model()
        try await model.download { _ in }
        try FileManager.default.removeItem(at: store.entry(files[0]))
        fetchCount.reset()
        try await model.download { _ in }
        XCTAssertEqual(fetchCount.value, 0)
        let located = await model.locate()
        XCTAssertEqual(located, store.snapshot)
    }
}

private final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
}
