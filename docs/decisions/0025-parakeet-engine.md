# 0025 — Parakeet engine for fast English voice typing

- **Status:** accepted (user, 2026-11-25: "approved, go ahead with the plan"; "current one is okay but i need a faster one too … so
  that user can use the bigger model like our current or that one"; picked Parakeet TDT v2: "i
  think v2 is good to go"; "Words to recognize" left out of the first version)
- **Date:** 2026-11-25
- **Related:** 0013 (voice typing), 0014 (Whisper engine: static linking, pinned model downloads),
  0015 (cloud engine), 0012 (self-signed certificate, library validation)

## Context

Whisper large-v3 turbo is accurate but slow: on this Mac (Apple M4, macOS 27.0.1) each phrase
takes 3–3.5 s to come back, because whisper.cpp runs Whisper's full 30-second window for every
segment. The user wants a fast English engine beside it, and keeps Whisper for accuracy and
Bangla. Wispr Flow, VoiceInk and Spokenly were the reference apps; the last two run NVIDIA's
Parakeet through FluidAudio.

Benchmark (2026-11-25, details in `private/docs/progress.md`): 28 synthetic clips (US, UK and
Indian English voices, plus 10 dB background noise), model loaded once, warm median.

| Engine | Words wrong | Short phrase | 12–19 s | Download |
|---|---|---|---|---|
| **Parakeet TDT 0.6B v2** (FluidAudio, Neural Engine) | 2.4% | 77 ms | 146 ms | 464 MB |
| Parakeet v3 / Ultra (25 European languages) | 2.7% | 82–92 ms | 177–238 ms | 480–630 MB |
| Whisper turbo 16-bit (today) | 2.1% | 3,046 ms | 3,456 ms | 1.6 GB |
| Whisper Small English, window fitted to the clip | 2.4% | 132 ms | 737 ms | 190 MB |
| Apple DictationTranscriber | 9.5% | 174 ms | 1,055 ms | none |

No engine got unusual names ("Eyakub", "Razlio") right without custom words.

## Decision

### 1. A fourth engine

Settings → Voice → Engine: Apple · Whisper, on this Mac · **Parakeet, on this Mac** · Cloud.
Stored as `"parakeet"` under the existing `voiceEngine` key. Works on macOS 14+. The default
engine doesn't change.

- **English only.** The Language picker is hidden for Parakeet, and the session always uses
  English. Filler tidying gets `"en"` from the session, not the saved `voiceLanguage` (which may
  say Bangla).
- **Words to recognize** aren't used by Parakeet in this version. The footer says so: "English
  only. Words to recognize aren't used yet."
- `VoiceTyping.makeSession()` gets a `parakeet` branch before the macOS 26 Apple check.

### 2. Library: FluidAudio, compiled into Rallo

- **FluidAudio 0.18.4**, exact version, as the project's first Swift package in
  `apps/macos/project.yml` (XcodeGen 2.46 supports package `traits`).
- **`traits: []`.** This drops FluidAudio's `NemoTextProcessing`, a prebuilt Rust static
  library. Rallo already links its own Rust (`rallo_ffi`), and two Rust runtimes in one binary
  clash. It also drops the TTS and diarization code. Checked in a scratch SwiftPM build: no
  `nemo_` or Rust symbols from FluidAudio in the binary.
- **Static, like whisper.cpp (0014).** SwiftPM links the package into the app binary, so no
  dynamic library meets library validation under the self-signed certificate.
- **Pinned by commit** (`revision:` of the v0.18.4 tag), since the generated xcodeproj and its
  `Package.resolved` aren't checked in. If Xcode ignores `traits` from the generated project, a
  small local package that depends on FluidAudio with `traits: []` stands in between.
- **Licenses:** FluidAudio is Apache-2.0 (no NOTICE file), and its `FastClusterWrapper` is still
  compiled in, so `fastcluster-LICENSE.md` goes into `ThirdPartyNotices.txt` too.
- **No transcript text in logs** (0013): FluidAudio logs at debug level by default and some lines
  can hold text, so Rallo sets `AppLogger.minimumLevel` above debug and `mirrorsToConsole = false`.

### 3. Model: pinned, verified, downloaded on request

- **`FluidInference/parakeet-tdt-0.6b-v2-coreml` at commit
  `ee09c569f73759e6d44c9bd16766f477b2b36d39`**: `Preprocessor`, `Encoder`, `Decoder` and
  `JointDecision.mlmodelc` plus `parakeet_vocab.json`, 21 files, 464 MB.
- **Each file is pinned by size and SHA-256.** Hugging Face gives the SHA-256 of the 12 LFS
  files; the 9 small git files are hashed once when the pins are written.
- **Downloaded only when the user clicks Download**, from that commit, into the Hugging Face hub
  cache layout used for Whisper (0014): `~/.cache/huggingface/hub/models--FluidInference--
  parakeet-tdt-0.6b-v2-coreml/`, files in `blobs/<sha256>` with a `.rallo-download` suffix while
  partial, `snapshots/<commit>/<path>` symlinks, `refs/main` written only if missing. A partial,
  failed or cancelled download leaves nothing behind.
- **Verified again once per launch before the first load** (size and SHA-256 of every file), as
  Whisper is, since the files are parsed in a process holding microphone and Accessibility access.
- **Loaded only from that folder**: `AsrModels.loadLocal(from: snapshotDir, version: .v2)`,
  which reads exactly that folder and never calls FluidAudio's downloader (that one checks no
  hashes). `load(from:)` won't do: it looks in a fixed folder name beside the one given.
- **Delete** removes the snapshot entries and blobs this model uses. Uninstall leaves it, as it
  leaves Whisper models.
- The weights are NVIDIA's Parakeet TDT 0.6B v2 under CC-BY-4.0: the attribution goes into
  `ThirdPartyNotices.txt`.

### 4. The session reuses Whisper's

Parakeet plugs into `WhisperVoiceSession` as another `SpeechTranscribing`: a
`ParakeetEngine` actor (load, transcribe, unload after 10 idle minutes, like `WhisperEngine`) and
a `WhisperVoiceSession.parakeet()` factory with previews on and language `"en"`. Mic capture,
`SpeechSegmenter`, previews every 1.2 s, the noise check and tidying stay as they are.

- **The phantom-text guard is off for Parakeet** (user, 2026-11-26: "yes, turn off the filter for
  Parakeet"). It drops Whisper's stock phrases ("Thank you.", "Bye.") from segments under 2 s,
  so a real short "Thank you" was dropped too. Fed room, fan and loud noise, Parakeet returned
  nothing (one 1 s burst gave "Uh", which tidying drops), so it doesn't invent those phrases.
  Whisper and Cloud keep the guard.

- FluidAudio refuses clips under 0.3 s (`invalidAudioData`). `ParakeetEngine` returns no text for
  them instead of failing, so a short last segment never ends the session with an error.
- First load after a download compiles the model for the Neural Engine. The bubble says "Loading
  Parakeet…"; later loads take about 0.3 s.
- Missing model: "Download the Parakeet model in Settings → Voice". Load failure: "Couldn't load
  the Parakeet model. Delete it and download it again in Settings → Voice".

### 5. Settings

The Parakeet row matches Whisper's model row: Download (464 MB) with progress, Cancel, Try Again,
Show in Finder, Delete with confirmation. No model picker (one model).

## Approaches considered

- **Parakeet v2 through FluidAudio (chosen):** fastest and as accurate as turbo on English, and it
  doesn't slow down on long phrases. Costs a new package and a 464 MB download.
- **Parakeet v3 or Ultra:** same speed class, a little worse on English and the Indian voice,
  bigger. Only worth it for other European languages.
- **Parakeet TDT-CTC-110M (220 MB):** slightly faster on short phrases, more mistakes.
- **Whisper Small English with a fitted window (`audio_ctx`):** no new package, same accuracy on
  these clips, but 5× slower than Parakeet on long phrases. The same setting made turbo repeat
  sentences. Possible separate change.
- **Whisper with a Core ML encoder, Moonshine, Parakeet streaming models:** dropped. The first
  speeds up only part of Whisper; Moonshine needs ONNX Runtime as a dynamic library (0014);
  streaming isn't needed while the segmenter types phrase by phrase.

## Checks

- Build: the app links FluidAudio statically, launches under the hardened runtime with the
  self-signed certificate, and `nm` shows no second Rust runtime.
- Tests: pinned file table (21 entries, sizes, paths), cache paths, engine mapping, Parakeet hides
  the Language picker.
- In the app (scratch `--data-dir` build, Dark and Light): download through Settings (hashes
  verified), delete, re-download; dictate `say` clips and check text and speed; missing-model and
  corrupt-file messages.

## Not now

Custom words on Parakeet (FluidAudio's CTC rescoring needs a second ~100 MB model; measure its
cost first), other languages (v3/Ultra), streaming models, the Whisper Small English speed-up,
making Parakeet the default.
