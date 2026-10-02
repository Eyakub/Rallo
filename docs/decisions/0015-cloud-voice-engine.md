# 0015 — Cloud voice engine (your API key)

- **Status:** prototype, pending user review.
- **Date:** 2026-10-02

## Context

The Whisper engine (0014) needs a 1.6 GB download and about 2 GB of RAM while
loaded. Some users don't want that. Groq serves the same model
(whisper-large-v3-turbo) for free, behind an OpenAI-compatible API.

## Decision

Settings → Voice has a third engine, "Cloud (your API key)", on macOS 14+.

- **OpenAI-compatible transcription with presets.** `POST <base>/audio/transcriptions`,
  multipart: a 16-bit mono 16 kHz WAV, `model`, `language` (omitted for Auto),
  `prompt` (the custom words, at most 800 characters), `response_format=json`,
  `temperature=0`. Presets: Groq (`whisper-large-v3-turbo`) and OpenAI
  (`whisper-1`), plus Custom (base URL and model) for any compatible server.
  Presets' models can be overridden.
- **Bring your own key, in the Keychain.** Service `rallo-voice-api-key`,
  account = provider id. Never in defaults, logs or files, and never shown
  again after saving. `rallo uninstall` deletes every item of that service
  (`voice_api_keys` in the cleanup report).
- **Same segmenting as Whisper, no previews.** The shared session cuts speech
  with the energy VAD and sends each finished phrase. Live previews are off:
  they would burn Groq's 20 requests/min free quota. The bubble shows
  "Listening…" until a phrase is done.
- **https only**, except `http://localhost`, `127.0.0.1` and `[::1]` for a
  local whisper-server. Requests use an ephemeral session (no cache, no
  cookies) with a 30 s timeout. Audio and text are never logged.
- Failures name the provider in the bubble: key rejected, rate limit, HTTP
  status, or unreachable.

## Consequences

- Audio leaves the Mac for the chosen provider. That is the user's informed
  choice: the engine is off unless picked and does nothing without a key.
- Quotas apply: Groq's free tier is 20 requests/min, 2,000/day, 25 MB per file.
  Each request is billed as at least 10 s of audio, so many short phrases cost
  more than the speech itself.
- Needs a network connection while dictating.

## Not done

Cloudflare Workers AI (a different API) and streaming transcription.
