# Opus / Ogg playback — integration roadmap

## Context

Apple added Opus and Vorbis decoding in raw `.opus` / `.ogg` containers in iOS 18.4 / macOS 15.4 / Safari 18.4. On 2026-05-15 we validated this end-to-end with a temporary DEBUG card on the home screen, playing two Ogg/Opus fixtures (48 kHz and 16 kHz mono) on both macOS 26.3 and iOS 26.2 sim. Audible playback succeeded on both platforms with a vanilla `AVURLAsset` → `AVPlayerItem` → `AVPlayer` chain — no `AVURLAssetMIMETypeHintKey`, no audio-engine setup, no third-party decoder. The validation harness has since been removed.

Following the validation, the project's deployment targets were aligned to the Opus-support floor: `IPHONEOS_DEPLOYMENT_TARGET = 18.4`, `MACOSX_DEPLOYMENT_TARGET = 15.4`. This means every device that can install the app already decodes Opus — no runtime capability gating is needed in client code.

This roadmap turns that into shippable support for Opus content.

## Validated facts (from the probe)

| Question | Answer |
| --- | --- |
| Does AVPlayer play raw `.opus` on iOS 26.2? | Yes |
| Does AVPlayer play raw `.opus` on macOS 26.3? | Yes |
| Is the codec UTI `org.xiph.opus` exposed via `AVURLAsset.audiovisualTypes()`? | **No** — only the container UTI `org.xiph.ogg-audio` is present |
| Is `org.xiph.vorbis` exposed? | **No** |
| Does AVPlayer need a MIME hint to decode Opus inside Ogg? | No (validated without `AVURLAssetMIMETypeHintKey`) |
| Per-track codec FourCC reported by `CMFormatDescription`? | `'opus'` |
| iOS deployment target today | `IPHONEOS_DEPLOYMENT_TARGET = 18.4` (= Opus floor ✅) |
| macOS deployment target today | `MACOSX_DEPLOYMENT_TARGET = 15.4` (= Opus floor ✅) |

**Gotcha for future contributors:** A naive client-side capability probe of the form `AVURLAsset.audiovisualTypes().contains("org.xiph.opus")` returns `false` on every shipping OS that actually decodes Opus. The codec UTI is never exposed; only the container UTI `org.xiph.ogg-audio` is reported. If a per-asset check is ever needed (e.g., to distinguish Opus from Vorbis inside an Ogg), inspect the FourCC on the loaded track's `formatDescriptions` — `CMFormatDescriptionGetMediaSubType` returns `0x6F707573` (`'opus'`) for Opus tracks. This finding is captured in the project memory file `avplayer-opus-ogg-uti-behavior.md`.

## Current playback pipeline (baseline)

```
APIClient.audioStreamURL(episodeId:)           APIClient.swift:113-115
   │
   ▼
AudioDownloader.start(url:bearer:episodeId:)   AudioDownloader.swift
   │  └─ Content-Type → file extension         AudioDownloader.swift:206-223
   │     (audio/ogg already maps to .ogg;      ← already accepts Ogg
   │      audio/opus is not mapped)
   ▼
AudioCache/episodes/<episodeId>.<ext>          ApplicationSupport sandbox
   │
   ▼
AudioPlayerViewModel.prepare(url:…)            AudioPlayerViewModel.swift:64-100
   │  └─ AVURLAsset(url:options:)              AudioPlayerViewModel.swift:81
   ▼
AVPlayer(playerItem:)
```

Notable properties of the baseline:

- **Single-episode cache** (one file at a time) — extension change for one episode does not affect any other.
- **Audio session** is `.playback / .default` on iOS, no-op on macOS (`AudioPlayerViewModel.swift:206-219`). Opus needs no different category.
- **MIME mapping fallback** is `mp3` when the server's Content-Type is unrecognized and `suggestedFilename` has no extension. This is a soft fallback — Opus served with an unknown MIME would land as `episode.mp3` on disk, and AVPlayer would still attempt sniff-based playback (which works for Opus per the validation). Not ideal but not broken.

## Goal

End state: the backend can serve Opus-in-Ogg audio for an episode, and the iOS + macOS apps download and play it transparently with the existing playback UX. Because both deployment targets now match the Opus floor, no "unsupported OS" UX path is needed.

## Phased plan

### Phase 1 — MIME → extension mapping

**File:** `s3player-app/AudioDownloader.swift:206-223`

Add the `audio/opus` case. Keep `audio/ogg` (already present) since some servers send the container MIME for Opus streams.

```swift
switch mime {
case "audio/mpeg", "audio/mp3": return "mp3"
case "audio/mp4", "audio/x-m4a": return "m4a"
case "audio/aac": return "aac"
case "audio/ogg", "application/ogg": return "ogg"
case "audio/opus": return "opus"                  // ← new
case "audio/wav", "audio/x-wav": return "wav"
case "audio/flac", "audio/x-flac": return "flac"
default: break
}
```

Notes:
- `application/ogg` is the RFC-correct MIME for the Ogg container; some servers/CDNs use it instead of `audio/ogg`.
- The extension only affects the on-disk filename; AVPlayer doesn't strictly require `.opus` to decode (it sniffs the container). The extension matters for diagnostic clarity, the cache key, and any future code that reads the extension.

**Tests:** none today on this function (no test target). Add a small unit-test target in a later phase if we want this codified.

### (Optional) Phase 2 — Catalog metadata

If the backend ever mixes formats per-show or per-episode, add a `mime_type` or `codec` field to the `Episode` JSON shape (`CatalogModels.swift:98-104`). Today this isn't needed because the client treats Content-Type as the source of truth at fetch time, but if you ever want to badge episodes ("Opus, high quality") or pre-filter on capability before showing them, the field becomes useful.

## Edge cases & open questions

1. **Range requests:** confirm the S3 origin sends `Content-Type: audio/opus` (or `audio/ogg`) on `Range` responses, not just on full-file GETs. AVPlayer issues range requests for seeking. Mis-MIMEing the partial response would not break playback (the file extension is set at download time, not per-range) but is worth a quick check.
2. **Bitrate / channel coverage:** Apple's docs don't explicitly enumerate supported Opus profiles. The two fixtures we tested are 48 kHz mono and 16 kHz mono. Before flipping the catalog over, verify stereo + 48 kHz + typical podcast bitrates (~48-96 kbps) decode cleanly.
3. **Background playback on iOS:** untested. The `.playback` AVAudioSession category is the same as for MP3, so should work, but verify "play, lock screen, audio continues" with an Opus episode before shipping.
4. **AirPlay:** if an AirPlay receiver doesn't natively decode Opus, iOS may transcode or refuse. Test with at least one AirPlay target (HomePod, Apple TV).
5. **Now Playing metadata:** the validation harness ran AVPlayer raw, without `MPNowPlayingInfoCenter`. Verify that artwork / title / artist appear correctly on the lock screen when the underlying file is Opus and the production `AudioPlayerViewModel.updateNowPlayingInfo()` path is in play.
6. **`audio/ogg` already mapped, but does the existing code actually exercise that path?** Today it likely doesn't — no episode is served as Ogg. Adding the `audio/opus` row in Phase 1 should be paired with a smoke test that the downloader correctly stamps `.opus` on an episode whose server returns `Content-Type: audio/opus`.

## Verification plan (per phase)

| Phase | How to verify |
| --- | --- |
| 1 (MIME map) | Stand up a one-off HTTP fixture that returns `Content-Type: audio/opus`; download via `AudioDownloader`, assert resulting filename ends in `.opus`. Or seed an Opus episode in the dev backend and walk the full flow. |
| 2 (catalog metadata) | Future work — only if backend starts mixing formats. |
