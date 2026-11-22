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
| Language check (Gate 3) | `fast_language_detector` (pure Dart) on title, description and transcript. When there's no transcript, Whisper tiny (`whisper_ggml`, about 75 MB, downloaded once) transcribes the first 30 seconds of audio. |
| Educational and safety checks (Gates 1, 2) | The phone calls the Claude API (`claude-opus-5-5`, low effort, structured JSON) directly with your own API key, plus a local keyword filter. |
| Knowledge graph | `assets/graph/graph_seed_v1.json`: 364 concepts across math, physics and CS, 520 prerequisite edges, and 71 curated theorems. |
| Concept extraction and relevance judging (Phase C/D) | Also the Claude API, called directly from the phone. |

## Status: Phase B (ingestion and theorem pool) ✅

- **Three gates, on the device.** Cheap local checks run first, so obvious rejects never cost an API call:
  safety keywords, then title/description language, then transcript language (or Whisper),
  then Gate 1 (educational, via Claude), then Gate 2 (thumbnail moderation, via Claude vision).
  English is a hard reject at every stage.
- **Scoped ingestion, two paths only.**
  - Path A, for material concepts: the "Find videos" buttons on coverage-gap cards and on concept pages.
  - Path B, for the curated math theorem pool: Settings → *Build theorem pool*. It can be resumed, and it
    never re-checks (or re-bills) a video it has already judged.
  - Asking for anything else raises `OutOfScopeIngestion`.
- **Knowledge graph seed.** It's built from readable sources in `tools/` by `python3 tools/build_graph_seed.py`,
  which checks prerequisite references, cycles and alias collisions.
- **Shorts feed.** Full-screen vertical swipe that autoplays and loops. Each short has a Material/Theorem chip,
  its concept and reason label, a Save button, and *Go deeper* when your material has a long-form video for the concept.
- **Concept detail.** The statement (from your material when you have one), LaTeX, the prerequisite chain, videos,
  and *Find some*. That button only appears when the concept is in your material or the theorem pool.
- **Settings.** Your Claude API key, kept in Android's encrypted storage. Also the pool builder, and a plain list
  of what data leaves the phone.

### Phase A (walking skeleton) ✅

- On-device SQLite schema (all §5 tables), migrations, and FTS5 + trigram indexes.
- On-device resolver: 6-hour cache bounded by the stream URL's own expiry, a 20-second timeout, and a "retry in 30s" contract.
- Scoped feeds with the real §10 rules. Every card has a reason label, concepts without videos get coverage-gap cards, the long-form feed caps at 3 videos per concept, and shorts are blended 65/35.
- `user_active_concepts` recompute (§6.4 priority formula).
- Home feed and native player (quality, speed, captions).
- 5 seed videos, written on first launch through a labelled sample material.

Next: **Phase C**, the material system: reading PDFs on the device, concept extraction, the My Material
screen, and Path A running automatically for new concepts.

## Using it

1. Install the app (see below) and open **Settings** (the gear icon on Home).
2. Paste a Claude API key from console.anthropic.com. It stays encrypted on the phone.
3. Tap **Build theorem pool**. Expect it to take a while; you can stop it and resume later. The Shorts tab fills as theorems are added.
4. On Home, **Find videos** on a coverage-gap card looks for videos for that concept from your material.

**Cost (a rough estimate, not measured yet).** A candidate that passes the local checks costs two Claude calls:
the educational check and the thumbnail check. That's roughly $0.02 per candidate on `claude-opus-5-5`.
A full pool build checks a few hundred candidates, so expect a few dollars, once.
To trade accuracy for cost, you can change `claudeModel` in `lib/services/claude_client.dart`, for example to `claude-haiku-5-5`.

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
- **Ingestion scope and gates:** a fake YouTube and a fake model drive every gate, both paths,
  out-of-scope refusals, de-duplication, and error and auth handling.
- **Feed scope (critical):** every long-form card has `primary_concept ∈ user_active_concepts`, and every
  short is from the theorem pool or an active concept. This is a randomized property test over 25 seeds.
- **No ads:** no `ads|admob|ad_unit|adslot` in the code, dependencies, strings or manifest.
- **No discovery:** no `discovery|adjacent|explore` in the app code or UI strings.
- **No middleman:** the app never calls a server of its own. The only hosts named in its code are YouTube's and `api.anthropic.com`.
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
