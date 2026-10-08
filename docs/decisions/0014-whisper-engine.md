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
  missing) so other tools find it. An existing copy is reused, the blob or a
  file in another snapshot, once its SHA-256 matches; it is hashed again on
  each launch before the first load (about a second), since whisper.cpp
  parses it in a process holding microphone and Accessibility access.
  Downloads go to `blobs/<sha>.rallo-download` (not huggingface_hub's own
  `.incomplete`), are verified before they are renamed into place, and
  failures and cancels delete the partial file. Delete removes only the
  snapshot entries that point at that blob.
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

## Amendment: Small (English) model and a phantom-text guard

- **Three model files**, all from the same Hugging Face repo and pinned
  commit (sizes and hashes from the Hugging Face tree API), each pinned by
  size and SHA-256: `ggml-large-v3-turbo.bin` (16-bit, 1.6 GB, unchanged),
  `ggml-large-v3-turbo-q8_0.bin` (8-bit, 874,188,075 bytes, SHA-256
  `317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1`) and
  `ggml-small.en-q5_1.bin` (English only, 190,098,681 bytes, SHA-256
  `bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30`).
  Settings → Voice has a Model picker with the size in each label, stored as
  `whisperModel` (`turbo16`, `turbo8`, `smallEnglish`). With nothing saved, the
  16-bit file is chosen if it is already downloaded and verified (existing
  users keep working, no re-download), otherwise the 8-bit one; that choice is
  then saved. Same cache layout and the same download, verify and delete row,
  acting on the selected model; several can be on disk, and turbo16's paths
  are untouched.
- **English only.** An `.en` model can't do Bangla, so with Small selected the
  Language picker is hidden and Rallo transcribes with language `en`.
- **Phantom text.** Whisper invents "Thank you." and similar from noise.
  The segmenter already gates on energy over the session's noise floor. On
  top of that, a segment of 2 s or more goes to Whisper or the cloud engine
  only if a speech check passes (100 ms frames; speech when the
  95th-percentile frame RMS is above 0.008 and 2.5 times the 20th-percentile
  one; idea from hoole's `containsSpeech`), otherwise it is dropped silently
  with no request; that catches steady noise, such as a fan coming on, that
  the segmenter took for speech. Shorter segments skip the check: they carry
  only 90 ms of quiet around the speech, so a short word would fail it. After
  transcription, a result that is exactly a known stock phrase ("thank you",
  "thanks for watching", "please subscribe", "you", "bye", ...) is dropped when
  the audio was under 2 s; longer segments keep it.

## Consequences

- Building from source needs CMake (`brew install cmake`); the first build
  downloads and compiles whisper.cpp (cached in `build/whisper`).
- The shared model isn't removed by `rallo uninstall`, because other tools may
  use it; Settings → Voice has Delete Model.
- The model needs about 2 GB of RAM while loaded; Rallo unloads it after 10
  minutes unused.
- The app grows by the static libraries (Metal shaders are embedded).

## Not done

A compressed turbo variant, a CoreML encoder, Silero VAD, and AI
cleanup of the text.
