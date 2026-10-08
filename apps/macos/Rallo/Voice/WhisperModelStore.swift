import Foundation

/// Where the Whisper model lives, in the Hugging Face hub cache layout so
/// other tools can use the same file (0014). Pure paths; no I/O.
struct WhisperModelStore {
    static let repo = "models--ggerganov--whisper.cpp"
    static let commit = "5359861c739e955e79d9a303bcbc70fb988958b1"

    let home: URL
    var kind: WhisperModelKind = .turbo16

    var root: URL { home.appendingPathComponent(".cache/huggingface/hub/\(Self.repo)") }
    var blob: URL { root.appendingPathComponent("blobs/\(kind.sha256)") }
    var partial: URL { root.appendingPathComponent("blobs/\(kind.sha256).rallo-download") }
    var snapshotsDirectory: URL { root.appendingPathComponent("snapshots") }
    var snapshot: URL { snapshotsDirectory.appendingPathComponent("\(Self.commit)/\(kind.fileName)") }
    var refsMain: URL { root.appendingPathComponent("refs/main") }
    /// The relative target of the snapshot symlink.
    var snapshotLinkTarget: String { "../../blobs/\(kind.sha256)" }
}

/// The Whisper models Rallo can download (0014). All live in the same
/// Hugging Face repo at the same pinned commit; each is its own file.
enum WhisperModelKind: String, CaseIterable {
    case turbo16
    case turbo8
    case smallEnglish

    static let defaultsKey = "whisperModel"

    /// What a user with no saved choice gets: the 16-bit file if it is already
    /// on disk (existing users keep working), else the smaller 8-bit one.
    static func defaultKind(turbo16Installed: Bool) -> WhisperModelKind { turbo16Installed ? .turbo16 : .turbo8 }

    /// The saved choice, or the 8-bit turbo when none is saved yet (`resolved()` saves one).
    static var selected: WhisperModelKind {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .turbo8
    }

    var fileName: String {
        switch self {
        case .turbo16: "ggml-large-v3-turbo.bin"
        case .turbo8: "ggml-large-v3-turbo-q8_0.bin"
        case .smallEnglish: "ggml-small.en-q5_1.bin"
        }
    }

    var size: Int64 {
        switch self {
        case .turbo16: 1_624_555_275
        case .turbo8: 874_188_075
        case .smallEnglish: 190_098_681
        }
    }

    var sha256: String {
        switch self {
        case .turbo16: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        case .turbo8: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"
        case .smallEnglish: "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30"
        }
    }

    var displayName: String {
        switch self {
        case .turbo16: "Large-v3 turbo · 16-bit · all languages · \(sizeLabel)"
        case .turbo8: "Large-v3 turbo · 8-bit · all languages · \(sizeLabel)"
        case .smallEnglish: "Small · English only · \(sizeLabel)"
        }
    }

    /// Shown in the picker and on the Download button.
    var sizeLabel: String {
        switch self {
        case .turbo16: "1.6 GB"
        case .turbo8: "874 MB"
        case .smallEnglish: "190 MB"
        }
    }

    /// nil: any language. An .en model can only do English.
    var languages: [String]? { self == .smallEnglish ? ["en"] : nil }

    var url: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(WhisperModelStore.commit)/\(fileName)")!
    }
}
