import Foundation

/// Where the Whisper model lives, in the Hugging Face hub cache layout so
/// other tools can use the same file (0014). Pure paths; no I/O.
struct WhisperModelStore {
    static let repo = "models--ggerganov--whisper.cpp"
    static let commit = "5359861c739e955e79d9a303bcbc70fb988958b1"
    static let fileName = "ggml-large-v3-turbo.bin"
    static let size: Int64 = 1_624_555_275
    static let sha256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    static let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(commit)/\(fileName)")!

    let home: URL

    var root: URL { home.appendingPathComponent(".cache/huggingface/hub/\(Self.repo)") }
    var blob: URL { root.appendingPathComponent("blobs/\(Self.sha256)") }
    var partial: URL { root.appendingPathComponent("blobs/\(Self.sha256).incomplete") }
    var snapshotsDirectory: URL { root.appendingPathComponent("snapshots") }
    var snapshot: URL { snapshotsDirectory.appendingPathComponent("\(Self.commit)/\(Self.fileName)") }
    var refsMain: URL { root.appendingPathComponent("refs/main") }
    /// The relative target of the snapshot symlink.
    static var snapshotLinkTarget: String { "../../blobs/\(sha256)" }
}
