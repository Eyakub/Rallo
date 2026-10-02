# 0014 — Whisper engine for voice typing

- **Status:** prototype, pending user review.
- **Date:** 2026-10-02

## Context

Voice typing (0013) runs on Apple's `DictationTranscriber`, which needs macOS
26 and is weaker on names and mixed languages. The user wants Whisper as a
second engine, with a model file that other tools on the Mac can use too, not
a private copy inside Rallo.

## Decision

Settings has a new **Voice** tab (the voice-typing controls moved there from
General) with an engine picker: "Apple (built in)" or "Whisper large-v3
turbo". Apple stays macOS 26+; Whisper works on macOS 14+, so before 26 it is
the only choice.

- **whisper.cpp v1.9.4, linked statically.** `scripts/build-whisper.sh`
  downloads the pinned source tarball (SHA-256 checked), builds static ggml
  libraries with Metal and Accelerate, and writes a module map so Swift can
  `import whisper`. The prebuilt xcframework is a dynamic framework, and
  under Rallo's hardened runtime with the self-signed certificate (0012, no
  Team ID) library validation refuses it ("different Team IDs"). The
  alternative, the `disable-library-validation` entitlement, was rejected:
  anything able to write to `~/Applications/Rallo.app` could then load code
  that inherits Rallo's Accessibility and Microphone grants. Static linking
  keeps the binary free of non-system dylibs.
- **Model: ggml-large-v3-turbo.bin**, pinned by Hugging Face commit and
  SHA-256 (1.6 GB), downloaded only when the user clicks Download. It is
  stored in the Hugging Face hub cache layout
  (`~/.cache/huggingface/hub/models--ggerganov--whisper.cpp/`: `blobs/<sha>`,
  a relative `snapshots/<commit>/` symlink, and `refs/main` written only if
  missing) so other tools find it. An existing copy is reused: the blob by
  size, a file in another snapshot only after its hash is verified once
  (remembered by path, size and modification time). Downloads are verified
  before they are renamed into place; failures and cancels delete the partial
  file.
- **Segmentation.** Whisper isn't streaming, so an energy voice-activity
  detector (30 ms frames, adaptive noise floor) cuts the mic audio into
  segments: 700 ms of trailing silence after at least 300 ms of speech, or 20
  s. Each segment is transcribed in order and typed as a final result;
  while someone is still speaking, the bubble gets a preview about every
  1.2 s. Stopping flushes the last segment.
- **Custom words** ("Words to recognize", shared by both engines) go in as
  Whisper's initial prompt. Language: Auto, English or Bangla.
- **Notices.** whisper.cpp is MIT and shipped in the binary, so its license
  is in the app's Resources as `ThirdPartyNotices.txt`, together with a note
  that the weights are OpenAI Whisper (MIT).

## Consequences

- Building from source needs CMake (`brew install cmake`); the first build
  downloads and compiles whisper.cpp (cached in `build/whisper`).
- The shared model isn't removed by `rallo uninstall`, because other tools may
  use it; Settings → Voice has Delete Model.
- The model needs about 2 GB of RAM while loaded; Rallo unloads it after 10
  minutes unused.
- The app grows by the static libraries (Metal shaders are embedded).

## Not done

The compressed q5/q8 model variants, a CoreML encoder, Silero VAD, and AI
cleanup of the text.
