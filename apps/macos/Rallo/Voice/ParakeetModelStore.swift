import Foundation

/// One file of the pinned Parakeet model repo.
struct ParakeetFile: Equatable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
}

/// Where the Parakeet model lives, in the Hugging Face hub cache layout so
/// FluidAudio and other tools find the same files (0025). Pure paths; no I/O.
struct ParakeetModelStore {
    static let repo = "models--FluidInference--parakeet-tdt-0.6b-v2-coreml"
    static let commit = "ee09c569f73759e6d44c9bd16766f477b2b36d39"
    static let sizeLabel = "464 MB"
    /// 0.3 s at 16 kHz: shorter clips are not sent to the model.
    static let minimumSamples = 4_800

    static let files: [ParakeetFile] = [
        ParakeetFile(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "46de1a6fe2e49d19a2125bc91acf020df7f2aea84ba821532aade8427a440b05"),
        ParakeetFile(path: "Decoder.mlmodelc/coremldata.bin", size: 554, sha256: "d200ca07694a347f6d02a3886a062ae839831e094e443222f2e48a14945966a8"),
        ParakeetFile(path: "Decoder.mlmodelc/metadata.json", size: 3_427, sha256: "90a279b822496316458febc0ce761ab05954fadd9d66aa97bea077a35fc8f2b2"),
        ParakeetFile(path: "Decoder.mlmodelc/model.mil", size: 13_106, sha256: "7b95a5a6b672c652000348a67b6d4d92bb8e176b978c6666fe73c28a4d7ec579"),
        ParakeetFile(path: "Decoder.mlmodelc/weights/weight.bin", size: 14_429_952, sha256: "27d26890221d82322c1092fd99d7b40578e435d5cf4b83c887c42603caf97aba"),
        ParakeetFile(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
        ParakeetFile(path: "Encoder.mlmodelc/coremldata.bin", size: 485, sha256: "4def7aa848599ad0e17a8b9a982edcdbf33cf92e1f4b798de32e2ca0bc74b030"),
        ParakeetFile(path: "Encoder.mlmodelc/metadata.json", size: 2_926, sha256: "58222fbc48c13c49d9715567803cd50cb9c23e4360462e0f8ffcea59a2c73c63"),
        ParakeetFile(path: "Encoder.mlmodelc/model.mil", size: 959_769, sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
        ParakeetFile(path: "Encoder.mlmodelc/weights/weight.bin", size: 445_187_200, sha256: "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e"),
        ParakeetFile(path: "JointDecision.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "f1183ba213bb94a918c8d2cad19ab045320618f97f6ca662245b3936d7b090f7"),
        ParakeetFile(path: "JointDecision.mlmodelc/coremldata.bin", size: 534, sha256: "e2c6752f1c8cf2d3f6f26ec93195c9bfa759ad59edf9f806696a138154f96f11"),
        ParakeetFile(path: "JointDecision.mlmodelc/metadata.json", size: 2_936, sha256: "ba8d309417b9acd4a175fdb15687de6a941db2f5b06666a60e7cf3cc8e2d3c3c"),
        ParakeetFile(path: "JointDecision.mlmodelc/model.mil", size: 9_722, sha256: "93bf82042235127cb81ab537dcae47a1c2e7e242ce4ffdaf772981b45eedc4f0"),
        ParakeetFile(path: "JointDecision.mlmodelc/weights/weight.bin", size: 3_453_388, sha256: "ca22a65903a05e64137677da608077578a8606090a598abf4875fa6199aaa19d"),
        ParakeetFile(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "03ab3c1327a054c54c07a40325db967ec574f2c91dcc8192bfa44aa561bcf2d8"),
        ParakeetFile(path: "Preprocessor.mlmodelc/coremldata.bin", size: 494, sha256: "d88ea1fc349459c9e100d6a96688c5b29a1f0d865f544be103001724b986b6d6"),
        ParakeetFile(path: "Preprocessor.mlmodelc/metadata.json", size: 2_974, sha256: "fb16c581ff5e1b962e7cb2181ed892cd32f9f84c12b6e80ff3e089f28e35bcbb"),
        ParakeetFile(path: "Preprocessor.mlmodelc/model.mil", size: 27_166, sha256: "3e06d16fd061294c8a75be68c43a3b1ed1f593d4a9c35249e9cdbccadc59721e"),
        ParakeetFile(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 298_880, sha256: "a5f7df6c7f47147ae9486fe18cc7792f9a44d093ec3c6a11e91ef2dc363c48dc"),
        ParakeetFile(path: "parakeet_vocab.json", size: 18_762, sha256: "57019fe3c745772ca83a1b048a4bb951cd51329504ea33d4d83316b96e279a97"),
    ]

    static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    static func url(for file: ParakeetFile) -> URL {
        URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/resolve/\(commit)/\(file.path)")!
    }

    let home: URL

    var root: URL { home.appendingPathComponent(".cache/huggingface/hub/\(Self.repo)") }
    var snapshotsDirectory: URL { root.appendingPathComponent("snapshots") }
    /// The folder FluidAudio loads.
    var snapshot: URL { snapshotsDirectory.appendingPathComponent(Self.commit) }
    var refsMain: URL { root.appendingPathComponent("refs/main") }

    func blob(_ file: ParakeetFile) -> URL { root.appendingPathComponent("blobs/\(file.sha256)") }
    func partial(_ file: ParakeetFile) -> URL { root.appendingPathComponent("blobs/\(file.sha256).rallo-download") }
    func entry(_ file: ParakeetFile) -> URL { snapshot.appendingPathComponent(file.path) }
    /// The relative target of the snapshot symlink.
    func linkTarget(_ file: ParakeetFile) -> String {
        String(repeating: "../", count: 2 + file.path.filter { $0 == "/" }.count) + "blobs/\(file.sha256)"
    }
}
