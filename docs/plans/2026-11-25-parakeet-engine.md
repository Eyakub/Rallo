# Parakeet Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fourth voice-typing engine, "Parakeet, on this Mac": NVIDIA Parakeet TDT 0.6B v2 through FluidAudio on the Neural Engine, English only, beside Apple, Whisper and Cloud.

**Architecture:** A pure, pinned file table and cache paths (`ParakeetModelStore`), a downloader/verifier for 21 files in the Hugging Face cache layout (`ParakeetModel`, sharing Whisper's downloader), and a `ParakeetEngine` actor that plugs into the existing `WhisperVoiceSession` as one more `SpeechTranscribing`. Settings gets the engine and a model row like Whisper's.

**Tech Stack:** Swift 5 mode, SwiftUI, XcodeGen 2.46, FluidAudio 0.18.4 (SwiftPM, `traits: []`), Core ML, XCTest.

**Spec:** `docs/decisions/0025-parakeet-engine.md`

Work in the worktree `/Users/eyakub/Desktop/Rallo/.claude/worktrees/parakeet` (branch `feat/parakeet`, off master 1ded577). `target/` and `build/whisper` are symlinks to the main checkout's.

## Global Constraints

- Engine key `voiceEngine`, value `"parakeet"`; picker label "Parakeet, on this Mac". Default engine unchanged.
- English only: no Language picker for Parakeet; the session language is `"en"`.
- Footer copy, exact: "English only. Words to recognize aren't used yet."
- FluidAudio `https://github.com/FluidInference/FluidAudio`, revision `e0c6103bc87a88d25276cad491c86e757f58c865` (tag v0.18.4), `traits: []`.
- Model repo `FluidInference/parakeet-tdt-0.6b-v2-coreml`, commit `ee09c569f73759e6d44c9bd16766f477b2b36d39`, 21 files, 464,413,247 bytes, label "464 MB".
- Cache root `~/.cache/huggingface/hub/models--FluidInference--parakeet-tdt-0.6b-v2-coreml/` (`blobs/<sha256>`, `blobs/<sha256>.rallo-download`, `snapshots/<commit>/<path>` relative symlinks, `refs/main` only if missing).
- Download only on the user's click; verify size + SHA-256 of every file once per launch before the first load; load with `AsrModels.loadLocal(from:version: .v2)` only (never FluidAudio's downloader).
- Clips under 4,800 samples (0.3 s at 16 kHz) give `""`, never an error.
- No transcript text in logs: `AppLogger.minimumLevel = .error`, `AppLogger.mirrorsToConsole = false`.
- Messages, exact: "Loading Parakeet…", "Download the Parakeet model in Settings → Voice", "Couldn’t load the Parakeet model. Delete it and download it again in Settings → Voice".
- Never hand-edit `apps/macos/Rallo.xcodeproj` or `Generated/`; edit `apps/macos/project.yml`. Tests and manual checks use `--data-dir`/`RALLO_DATA_DIR`, never the real data directory.
- Commits: conventional, author `eyakubsorkar@gmail.com`, no AI attribution.
- Swift tests: `(cd apps/macos && xcodegen generate) && xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex test`; one class with `-only-testing:RalloTests/<Class>`. PATH needs `/opt/homebrew/opt/rustup/bin`.

## Review Focus

1. **A model deleted or damaged while Parakeet is loaded:** Delete unloads the engine; the next session says "Download the Parakeet model in Settings → Voice", and a damaged file is never loaded. Pinned by `testDamagedFileIsNotLocated` (Task 1) and the delete check in Task 4.
2. **A short last segment when listening stops (< 0.3 s):** typed as nothing, the session doesn't end with an error. Pinned by `testShortClipGivesNoText` (Task 2).
3. **Bangla saved as the language, Parakeet chosen:** English is used and "um"s are still removed. Pinned by `testParakeetTidiesAsEnglish` (Task 2).
4. **A download that fails or is cancelled halfway:** no partial file or blob from that run stays; Try Again starts clean. Pinned by `testFailedDownloadLeavesNothing` and `testHashMismatchIsRejected` (Task 1).
5. **Another tool's copy of the same repo (other revision, other files) in the cache:** Delete leaves it alone. Pinned by `testDeleteLeavesOtherSnapshots` (Task 1).

---

### Task 1: Pinned files, cache paths, download/verify/delete

**Files:**
- Create: `apps/macos/Rallo/Voice/ParakeetModelStore.swift` (pure: pins, paths, URLs)
- Create: `apps/macos/Rallo/Voice/ParakeetModel.swift` (I/O: locate, download, delete)
- Modify: `apps/macos/Rallo/Voice/WhisperModel.swift` (private `Downloader` → internal `ModelDownloader`, keyed by URL and size)
- Modify: `apps/macos/project.yml` (RalloTests sources: add `Rallo/Voice/WhisperModel.swift`, `Rallo/Voice/ParakeetModelStore.swift`, `Rallo/Voice/ParakeetModel.swift`)
- Test: `apps/macos/RalloTests/ParakeetModelTests.swift`

**Interfaces:**
- Produces:
  - `struct ParakeetFile: Equatable, Sendable { let path: String; let size: Int64; let sha256: String }`
  - `struct ParakeetModelStore { let home: URL; static let repo = "models--FluidInference--parakeet-tdt-0.6b-v2-coreml"; static let commit = "ee09c569f73759e6d44c9bd16766f477b2b36d39"; static let files: [ParakeetFile]; static var totalSize: Int64; static let sizeLabel = "464 MB"; static let minimumSamples = 4_800; static func url(for: ParakeetFile) -> URL; var root: URL; var snapshotsDirectory: URL; var snapshot: URL; var refsMain: URL; func blob(_: ParakeetFile) -> URL; func partial(_: ParakeetFile) -> URL; func entry(_: ParakeetFile) -> URL; func linkTarget(_: ParakeetFile) -> String }`
  - `struct ParakeetModel { typealias Fetch = @Sendable (URL, URL, @escaping @Sendable (Int64) -> Void) async throws -> Void; init(home: URL = FileManager.default.homeDirectoryForCurrentUser, files: [ParakeetFile] = ParakeetModelStore.files, fetch: @escaping Fetch = ModelDownloader.fetch); func locate() async -> URL?; func download(progress: @escaping @Sendable (Double) -> Void) async throws; func delete() }` — `locate()` returns `store.snapshot` (the folder to load).
  - `final class ModelDownloader` with `static func fetch(from: URL, to: URL, written: @escaping @Sendable (Int64) -> Void) async throws` (HTTP 200 only, else `WhisperModelError.http(code)`; cancellation cancels the transfer).

- [ ] **Step 1: Write the failing tests** in `ParakeetModelTests.swift`

```swift
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
```

The I/O tests use a temp home and three fake files (`A.mlmodelc/weights/weight.bin`, `A.mlmodelc/model.mil`, `vocab.json`, with their real SHA-256s), and a `fetch` that copies from a source folder keyed by the URL's path:

- `testDownloadInstallsLocatesAndDeletes`: after `download`, `locate()` == `store.snapshot`; reading `snapshot/A.mlmodelc/weights/weight.bin` gives the source bytes (through the symlink); `refs/main` contains the commit; after `delete()`, `locate()` is nil and the three blobs are gone.
- `testDamagedFileIsNotLocated`: after `download`, overwrite one blob with same-size different bytes and set its modification date 10 s later; `locate()` is nil.
- `testFailedDownloadLeavesNothing`: `fetch` throws on the second file; `download` throws; `blobs/` holds no file and no `.rallo-download`; `locate()` is nil.
- `testHashMismatchIsRejected`: `fetch` writes wrong bytes of the right size; `download` throws `WhisperModelError.hashMismatch`; `blobs/` is empty.
- `testDeleteLeavesOtherSnapshots`: create `snapshots/0000000000000000000000000000000000000000/other.txt` and `blobs/unrelated`; after download + delete, both still exist.
- `testAlreadyVerifiedFilesAreNotFetchedAgain`: download, delete one snapshot entry only, download again; `fetch` is called 0 times the second time and `locate()` works.

- [ ] **Step 2: Run them; expect a compile failure** (`ParakeetModelStore` not defined)

Run: `xcodebuild … test -only-testing:RalloTests/ParakeetModelTests`

- [ ] **Step 3: Implement `ParakeetModelStore`** with the 21 pins below (generated from the Hugging Face tree API at the pinned commit; the 9 non-LFS files hashed from their downloads). `linkTarget` = `"../"` repeated (2 + number of `/` in `path`) + `"blobs/<sha256>"`.

```swift
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
```

- [ ] **Step 4: Generalize Whisper's downloader** in `WhisperModel.swift`: rename the private `Downloader` to internal `ModelDownloader(url:expectedSize:destination:written:)` plus `static func fetch(from:to:written:)`; `WhisperModel.download` calls it with `kind.url`/`kind.size` and maps bytes to `min(1, written / kind.size)`. Behaviour unchanged.

- [ ] **Step 5: Implement `ParakeetModel`** mirroring `WhisperModel`: `locate()` (off the main thread) checks every file's blob with size + `WhisperModel.sha256(of:)`, cached per launch by `path|mtime` like `WhisperModel.verified`, then repairs missing snapshot symlinks and writes `refs/main` only if missing. `download` skips files whose blob already verifies, fetches the rest into `partial(_:)`, hashes, moves to `blob(_:)`; reports progress as bytes done / `totalSize` of the files being fetched; on any error removes the partial and every blob it created in this run, then rethrows. `delete()` removes snapshot entries under `store.snapshot` that resolve to this model's blobs, then those blobs, nothing else.

- [ ] **Step 6: Run the tests; expect PASS**, then the whole suite (Whisper download behaviour must be unchanged).

- [ ] **Step 7: Commit** `feat(voice): pinned Parakeet model files, download and verify`

### Task 2: FluidAudio, the engine, and the session

**Files:**
- Modify: `apps/macos/project.yml` (top-level `packages: FluidAudio: {url, revision, traits: []}`; `Rallo` and `RalloTests` get `dependencies: - package: FluidAudio`; RalloTests sources add `Rallo/Voice/ParakeetEngine.swift`)
- Create: `apps/macos/Rallo/Voice/ParakeetEngine.swift`
- Modify: `apps/macos/Rallo/Voice/WhisperVoiceSession.swift` (`extension ParakeetEngine: SpeechTranscribing {}`, `static func parakeet()`)
- Modify: `apps/macos/Rallo/Voice/VoiceTyping.swift:184-189` (`makeSession`), `:211-214` (`handle` tidy language)
- Modify: `apps/macos/Rallo/Voice/VoiceText.swift` (`tidyLanguage`)
- Modify: `apps/macos/Rallo/Resources/ThirdPartyNotices.txt`
- Test: `apps/macos/RalloTests/ParakeetEngineTests.swift`, `apps/macos/RalloTests/VoiceTextTests.swift`

**Interfaces:**
- Consumes: `ParakeetModel().locate()`, `ParakeetModelStore.minimumSamples` (Task 1).
- Produces:
  - `actor ParakeetEngine { static let shared; func load(directory: URL) async throws; func transcribe(samples: [Float], language: String, prompt: String) async throws -> String; func unload() }` — `load` reuses a loaded directory, else `AsrModels.loadLocal(from: directory, version: .v2)` + `AsrManager(config: .default).loadModels`; unloads (`cleanup()`) after 600 idle seconds like `WhisperEngine`; `transcribe` ignores `language`/`prompt`, returns `""` below `minimumSamples`, uses a fresh `TdtDecoderState.make(decoderLayers:)` per call and returns `result.text`. Its `init` sets `AppLogger.minimumLevel = .error` and `AppLogger.mirrorsToConsole = false`.
  - `WhisperVoiceSession.parakeet() -> WhisperVoiceSession` (previews on, language `"en"`, the three exact messages).
  - `VoiceText.tidyLanguage(engine: String?, saved: String?) -> String?` — `"en"` when `engine == "parakeet"`, else `saved`.

- [ ] **Step 1: Write the failing tests**

```swift
// VoiceTextTests
func testParakeetTidiesAsEnglish() {
    XCTAssertEqual(VoiceText.tidyLanguage(engine: "parakeet", saved: "bn"), "en")
    XCTAssertEqual(VoiceText.tidyLanguage(engine: "whisper", saved: "bn"), "bn")
    XCTAssertNil(VoiceText.tidyLanguage(engine: "apple", saved: nil))
}

// ParakeetEngineTests — needs the real model; skipped when it isn't installed (read-only use of ~/.cache).
func testShortClipGivesNoText() async throws {
    guard let directory = await ParakeetModel().locate() else { throw XCTSkip("Parakeet model not installed") }
    try await ParakeetEngine.shared.load(directory: directory)
    let short = try await ParakeetEngine.shared.transcribe(samples: [Float](repeating: 0, count: 3_200), language: "en", prompt: "")
    XCTAssertEqual(short, "")
    _ = try await ParakeetEngine.shared.transcribe(samples: [Float](repeating: 0, count: 16_000), language: "en", prompt: "")
}
```

- [ ] **Step 2: Run; expect compile failure** (`tidyLanguage`, `ParakeetEngine` not defined).

- [ ] **Step 3: Add the package** to `project.yml`:

```yaml
packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    revision: e0c6103bc87a88d25276cad491c86e757f58c865
    # No NeMo text normalization: it is a Rust staticlib and Rallo links its own Rust (0025 §2).
    traits: []
```

- [ ] **Step 4: Implement `ParakeetEngine`, `tidyLanguage`, `parakeet()`, the `makeSession` branch** (`if engine == "parakeet" { return WhisperVoiceSession.parakeet() }` before the macOS 26 check), and in `handle` pass `dropFillers: VoiceText.fillersApply(language: VoiceText.tidyLanguage(engine: UserDefaults.standard.string(forKey: "voiceEngine"), saved: UserDefaults.standard.string(forKey: "voiceLanguage")))`.

- [ ] **Step 5: Notices.** Append to `ThirdPartyNotices.txt`: FluidAudio 0.18.4 (https://github.com/FluidInference/FluidAudio), statically linked, with its `LICENSE` (Apache-2.0) verbatim; fastcluster with `ThirdPartyLicenses/fastcluster-LICENSE.md` verbatim; and: "The Parakeet TDT 0.6B v2 model is by NVIDIA (https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/), converted to Core ML by FluidInference. It is downloaded only when you ask, not shipped in the app."

- [ ] **Step 6: Build and check the link**

Run: `scripts/build-macos.sh`, then `nm -U build/DerivedData.noindex/Build/Products/Release/Rallo.app/Contents/MacOS/Rallo | grep -c -i nemo_` → `0`, and `codesign --verify --strict build/DerivedData.noindex/Build/Products/Release/Rallo.app` → no output. If the build fails with duplicate Rust symbols or `nemo_` symbols appear, Xcode ignored `traits: []`: add `apps/macos/Packages/FluidAudioASR/Package.swift` (tools 6.2, depends on FluidAudio at the same revision with `traits: []`, re-exports it with `@_exported import FluidAudio`), point `project.yml` at that local package instead, and re-run.

- [ ] **Step 7: Run the tests.** With the model not yet installed, `testShortClipGivesNoText` is skipped; Task 4 runs it again after the in-app download. Whole suite passes.

- [ ] **Step 8: Commit** `feat(voice): Parakeet engine through FluidAudio`

### Task 3: Settings → Voice

**Files:**
- Modify: `apps/macos/Rallo/Settings/SettingsModel.swift` (Parakeet model section beside Whisper's, `:126-175`; `opened()` checks it)
- Modify: `apps/macos/Rallo/Settings/SettingsView.swift` (`VoiceTab`, `:314-486`)

**Interfaces:**
- Consumes: `ParakeetModel`, `ParakeetModelStore.sizeLabel` (Task 1), `ParakeetEngine.shared.unload()` (Task 2).
- Produces: `SettingsModel` gains `@Published var parakeetModel: WhisperModelState = .checking` and `checkParakeetModel()`, `downloadParakeetModel()`, `cancelParakeetDownload()`, `deleteParakeetModel()` (also unloads the engine), `showParakeetModel()` (reveals the snapshot folder), each mirroring its Whisper twin.

- [ ] **Step 1: Model section.** Add the members above, with the same cancelled → `.missing`, error → `.failed(localizedDescription)` handling as `downloadWhisperModel`. `opened()` calls `checkParakeetModel()`.

- [ ] **Step 2: Voice tab.**
  - Engine picker: `Text("Parakeet, on this Mac").tag("parakeet")` after Whisper.
  - `engine == "parakeet"`: no Model picker; a model row for `model.parakeetModel` with Download (464 MB), progress + Cancel, Try Again, Show in Finder, Delete… ("Delete the Parakeet model?", same message as Whisper's).
  - Turn `modelRow` into `modelRow(_ state: SettingsModel.WhisperModelState, name: String, sizeLabel: String, download: @escaping () -> Void, cancel: @escaping () -> Void, show: @escaping () -> Void, delete: @escaping () -> Void) -> some View`; Whisper's call keeps its current text exactly.
  - `showsLanguage` is false for `"parakeet"`.
  - `engineFooter` case `"parakeet"`: `footnote("English only. Words to recognize aren't used yet.")`.

- [ ] **Step 3: Build and run the suite** (no new unit tests: this is view and state wiring, checked in the app in Task 4).

- [ ] **Step 4: Commit** `feat(app): Parakeet in Settings → Voice`

### Task 4: Docs and the in-app check

**Files:**
- Modify: `README.md:133` (Voice typing row: add a Parakeet bullet after Whisper: "**Parakeet** (macOS 14+, a one-time 464 MB download): English only and fast, a fraction of a second per phrase; Words to recognize aren't used yet.")
- Modify: `docs/decisions/0025-parakeet-engine.md` (Status: accepted, user 2026-11-25 "approved")
- Modify: `private/docs/progress.md` (gitignored, in the main checkout: entry with commits, test counts, what was and wasn't checked)

- [ ] **Step 1: Scratch build in the worktree** (`scripts/build-macos.sh`), launch with `--data-dir` in the session scratchpad and `--demo-open settings:voice`.
- [ ] **Step 2: Settings, Dark and Light:** select Parakeet, screenshot the Voice tab by window ID (`screencapture -l`), never full screen. Language picker hidden, footer copy exact. Use the Accessibility API (`AXPress`) to press Download, never synthetic mouse or key events on the user's desktop.
- [ ] **Step 3: Download through the app** (464 MB into the real Hugging Face cache): status reaches "Downloaded"; every blob's SHA-256 matches its pin; Show in Finder opens the snapshot folder.
- [ ] **Step 4: Run `ParakeetEngineTests` again**: now runs (not skipped) and passes.
- [ ] **Step 5: Delete and damage checks:** Delete → status Download; download again; overwrite one small blob with same-size bytes → reopen Settings → status Download, nothing loads.
- [ ] **Step 6: Dictation:** ask the user to try it on this build (hold Right ⌥, speak, release), with Bangla saved as the language once. Don't drive the mic or keys yourself.
- [ ] **Step 7: `lsregister -u` the build product; commit** `docs: Parakeet engine (0025 accepted, README)`
