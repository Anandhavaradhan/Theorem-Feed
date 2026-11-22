# TheoremFeed

A personal, ad-free, **material-driven** study app for Android. You upload your study material;
the app shows only videos for concepts in that material, plus a curated pool of math-theorem shorts.
It has no discovery feed, no ads, no accounts and no telemetry.

> Personal use only. Never distributed.

## Architecture: everything on the phone

There is **no server**. The app talks to YouTube directly, and all processing happens on the device.

| Concern | How it works on the device |
|---|---|
| Finding video streams | `youtube_explode_dart` gets stream URLs straight from YouTube. No yt-dlp and no proxy. |
| Playback | `media_kit` (libmpv). For 720p/1080p it plays YouTube's separate video and audio streams together. A single 360p stream is the fallback. Captions are English WebVTT. |
| Database | SQLite (`sqlite3` package with bundled SQLite) holding the full §5 data model. |
| Keyword search (BM25) | SQLite FTS5 (`videos_fts`). |
| Fuzzy concept lookup | FTS5 trigram index (`concepts_trgm`). |
| Vector search | 384-d float32 BLOBs with exact cosine in Dart. That's fast enough at personal library size. |
| Concept extraction and relevance judging (Phase C/D) | The phone calls the Claude API directly with your own API key. No other server is involved. |

## Status: Phase A (walking skeleton) ✅

- On-device SQLite schema (all §5 tables), migrations, and FTS5 + trigram indexes.
- On-device resolver: 6-hour cache bounded by the stream URL's own expiry, a 20-second timeout, and a "retry in 30s" contract.
- Scoped feeds with the real §10 rules. Every card has a reason label, concepts without videos get coverage-gap cards, the long-form feed caps at 3 videos per concept, and shorts are blended 65/35.
- `user_active_concepts` recompute (§6.4 priority formula).
- Home feed and native player (quality, speed, captions).
- 5 seed videos, written on first launch through a labelled sample material.

Next: **Phase B**, which covers the three-gate ingestion on the device, the graph seed, the theorem pool, the shorts UI and concept detail.

## Build and install (Android)

You need the Flutter SDK (3.50+) and the Android SDK (via Android Studio).

```sh
cd mobile
flutter pub get
flutter build apk --release
# then copy build/app/outputs/flutter-apk/app-release.apk to your phone and install it
#   (Android will ask you to allow installs from this source)
# or, with the phone plugged in over USB:
flutter install
```

## Tests

```sh
cd mobile
flutter analyze
flutter test
```

On a Linux machine, the tests use the system `libsqlite3`, which must have FTS5 (Ubuntu's does).
The Android build bundles its own SQLite. See `hooks:` in `pubspec.yaml`.

The guardrail tests run on every change:
- **Feed scope (critical):** every long-form card has `primary_concept ∈ user_active_concepts`, and every
  short is from the theorem pool or an active concept. This is a randomized property test over 25 seeds.
- **No ads:** no `ads|admob|ad_unit|adslot` in the code, dependencies, strings or manifest.
- **No discovery:** no `discovery|adjacent|explore` in the app code or UI strings.
- **No middleman:** the app never calls a server of its own.
- Every `t('key')` used in the app exists in `en.json`.

## Design decisions

- **Phase A seed goes through the real scope rules.** The 5 videos reach the Home feed via a labelled
  sample material and the normal `primary_concept ∈ user_active_concepts` predicate, not a hardcoded list.
- **Only library videos can be played.** The resolver refuses anything that isn't an active video in the
  local database, so the app is not a general YouTube player.
- **Stream choice.** At each resolution the app prefers H.264, which every Android phone can decode in hardware,
  paired with the best AAC audio. The single-URL 360p stream is always kept as a robust fallback.
  The best quality at or below the screen's resolution is picked automatically.
- **Keeping up with YouTube.** YouTube changes often, and stream extraction can break until the
  `youtube_explode_dart` package is updated. With no server, the fix means rebuilding the app with
  the updated package: `flutter pub upgrade youtube_explode_dart && flutter build apk`.
- **History.** The earlier server-based version (FastAPI + Postgres + yt-dlp) is in git history at commit
  `2423f60`.
