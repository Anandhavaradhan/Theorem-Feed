# TheoremFeed

A personal, ad-free, **material-driven** study app for Android. You upload your study material;
the app shows only videos for concepts in that material, plus a curated pool of math-theorem shorts.
It has no discovery feed, no ads, no accounts, no telemetry, and **no paid services**: the AI runs on the device.

> Personal use only. Never distributed.

## Architecture: everything on the phone

There is **no server and no paid API**. The app talks to YouTube directly, and all processing, including the AI, happens on the device.

| Concern | How it works on the device |
|---|---|
| Finding video streams | `youtube_explode_dart` gets stream URLs straight from YouTube. No yt-dlp and no proxy. |
| Playback | `media_kit` (libmpv). For 720p/1080p it plays YouTube's separate video and audio streams together. A single 360p stream is the fallback. Captions are English WebVTT. |
| Database | SQLite (`sqlite3` package with bundled SQLite) holding the full §5 data model. |
| Keyword search (BM25) | SQLite FTS5 (`videos_fts`). |
| Fuzzy concept lookup | FTS5 trigram index (`concepts_trgm`). |
| Vector search | 384-d float32 BLOBs with exact cosine in Dart. That's fast enough at personal library size. |
| Language check (Gate 3) | `fast_language_detector` (pure Dart) on title, description and transcript. When there's no transcript, Whisper tiny (`whisper_ggml`, about 75 MB, downloaded once) transcribes the first 30 seconds of audio. |
| Educational and safety checks (Gates 1, 2) | Instant rules first: a trusted-channel list plus a check that the video plainly covers the concept, and a keyword filter. Everything else goes to the on-device model. |
| On-device AI model | [llamadart](https://pub.dev/packages/llamadart) (llama.cpp) running **Qwen3.5 0.8B, 4-bit** (about 0.5 GB, downloaded once from Hugging Face). Its output is constrained to a JSON schema, so even this small model gives well-formed answers. Free, offline after the download, no limits. |
| Knowledge graph | `assets/graph/graph_seed_v1.json`: 364 concepts across math, physics and CS, 520 prerequisite edges, and 71 curated theorems. |
| PDF reading (Phase C) | [pdfrx](https://pub.dev/packages/pdfrx) (Google's PDFium) extracts the text layer on the device. Headings, box titles, defining sentences, bullets and vocabulary lists are read by rules in about a second; the on-device model checks only the doubtful finds. |
| Relevance (Phase D) | Retrieval from concept tags, keyword search (BM25) on your material's statement over video transcripts, and prerequisite videos. Then the same on-device model judges each video (topic, level, depth, prerequisites) and the scores are cached. |

## Status: all six phases (A–F) built ✅

Every phase of the spec is implemented and covered by 149 automated tests. What still needs a real device:

- **Not yet run on Android.** The sandbox it was built in had no Android SDK, so no APK has been built here.
  The first `flutter build apk` on your machine is the real test of the native pieces: llama.cpp, PDFium, libmpv and whisper.cpp.
- **Not yet run against live YouTube or the real AI model.** Network access to both was blocked during development.
  The logic is tested with fakes. The live checks (stream resolving, the model's judgement quality, and the relevance
  check's precision@10) need your tablet.

### Phase F (polish) ✅

- **Shorts preload.** The next 3 shorts' streams are fetched in the background (one at a time, each once), and their thumbnails cached.
- **Thumbnail disk cache.** Feeds and search look complete offline, and scrolling doesn't re-download.
- **Watch history.** Every viewing is recorded (furthest point; 90% counts as finished; finishing again counts as a rewatch).
  Long videos resume where you stopped. Search ranks finished videos slightly lower (§11.4). Saving uses the same row.
- **Resilient playback.** If YouTube expires a stream link mid-video, the player fetches fresh links once and
  continues from the same point. With no connection it says so plainly; feeds, search and material keep working.
- **Exam-proximity boost and auto-archive** (from Phase C): concepts from a material with an exam in the next
  14 days get 1.8× priority, and past-exam materials archive themselves.
- **Storage.** Settings can clear cached video links and thumbnails. Your material, concepts, saved videos and
  history are never touched.

### Phase E (search) ✅

Search runs entirely on the device, so it always works offline, with or without a network connection.

1. **Query understanding.** An empty query shows a hint. A **formula** (∫, Σ, √, `^`, `=`, or LaTeX like `e^{i\pi}`)
   is normalised and matched against concepts' LaTeX and descriptions. Up to 6 words are matched as a **concept**,
   tolerating typos (token_set_ratio ≥ 85, with the graph's aliases). Anything else is **natural language**.
2. **Scope first.** Every search runs inside the same universe as the feeds: videos for your active material's concepts,
   plus the curated theorem-pool shorts. With no active material, only the theorem pool is searched, with a notice.
3. **Retrieval.** For a concept, a direct lookup of every in-scope video tagged with it (this always wins). Also BM25
   over title, description and transcript. If the best concept match is something you aren't studying ("series" →
   Infinite Series), search falls back to free text in your universe, so Taylor, Fourier and geometric series still
   come back grouped.
4. **Re-rank (§11.4).** +1.0 for the primary concept, +0.5 for a secondary tag, +0.3 per query term in the title,
   +0.3 × BM25, and −0.1 per completed viewing. Videos tagged with the queried concept always land in its group's top 3.
5. **Grouping.** Results are grouped by concept, with reason labels, "N videos · from Chapter 7.2", a coverage-gap card
   when a concept in your material has no videos, and prerequisite-gap cards with *Find videos*. A query outside your
   universe gets an out-of-scope card ("Not in your material…") with *Search theorem pool instead*. Never a silent empty.

- **Speed and cache.** About 8 ms per query on a desktop CPU in the tests (target < 150 ms); expect a few times that on a phone. Results are cached for an hour, keyed
  by a signature of the library, so any change to material, videos or judgements invalidates them at once.
- **Golden set (§11.8).** `test/search_eval_test.dart` runs 20 queries (exact, alias, typo, natural language, formula,
  theorem pool, multi-concept, coverage gap, out-of-scope) against a fixture library on the real graph.
  All of them put the expected concept in the top 3 groups or return the right card. Run it on every search change.

### Phase D (relevance engine) ✅

- **Layer A: retrieval (§9.1).** For each concept in your material, candidates come from three signals:
  - its explicit concept tag;
  - your material's *statement* of it, matched against video titles, descriptions and **transcripts** with BM25
    (the keyword index now covers transcripts). This is the on-device stand-in for statement embeddings,
    with no second model to download. A match needs the concept's name or at least two distinctive statement
    words, and generic words like "function" don't count.
  - videos for its prerequisites, from the knowledge graph.
- **Layer B: the judge (§9.2).** The on-device model grades the top 12 candidates per concept, 4 at a time, on topic fit,
  level fit, depth fit and prerequisites. Scores are constrained to integers 0–10, and
  `final = (0.5·topic + 0.2·level + 0.2·depth + 0.1·prereq) / 10`. Each (video, concept) pair is judged once and cached.
  Ranking runs automatically after every video search.
- **Effect on the feed.** Long-form cards are ordered by the judge's score and show its short reason under the title.
  Videos judged clearly off-topic (topic fit ≤ 2) are hidden; a concept left with no videos gets a coverage-gap card.
  A video found by its statement match that the judge rates as on-topic (topic fit ≥ 7) is tagged to the concept
  and joins its feed.
- **Layer C: evaluation (§9.3).** On a concept's page, long-press a video to mark it as a good or bad example.
  The spec's golden set is 5 concepts × 10 videos (5 good, 5 bad). Then Settings → **Run relevance check** computes,
  on what the feed would show for each concept (top 10, after ranking and filtering):
  - **precision@10** = good shown ÷ labelled shown (target ≥ 0.7)
  - **bad-video rate@10** = bad shown ÷ all shown (target ≤ 0.1)

  Run it again after any change to retrieval or the judge.

### Phase C (material system) ✅

- **Upload a text-native PDF** from the My Material tab, or from Home's empty state. Scanned PDFs are rejected with
  "This PDF has no text layer" (§6). Uploading the same file again doesn't re-process it; an archived copy is reactivated.
- **On-device pipeline.** It extracts the text, then removes repeated headers and footers (lines on more than 60% of pages),
  then cleans it as in §6.1 (ligatures, hyphenated line breaks, page numbers). Chapter and section headings are tracked.
  The text is split into chunks of whole paragraphs with overlap, so a theorem stays with its proof. Chunks are sized for
  the small model (≈1,100 tokens rather than the spec's 3,000).
- **Concept extraction.** Labelled, named blocks are read exactly by rules: the statement stays word-for-word as your
  material states it. The on-device model runs the §6.3 prompt on each chunk, constrained to a schema, for everything else,
  filling in LaTeX, prerequisites, difficulty and importance. If the model can't load (say you're offline on first use),
  the labelled blocks are still saved.
- **Mapping (§6.4).** Duplicates across chunks are merged, keeping the most important. Each concept is attached to the
  knowledge graph by fuzzy name/alias match, or created as a new concept. Prerequisites are stored and added to the graph.
  `user_active_concepts` is then recomputed.
- **Videos follow automatically.** Path A runs straight after an upload for the 15 most important new concepts that
  have no videos. The rest show as coverage-gap cards with *Find videos*.
- **Lifecycle (§6.5).** Archive, delete (soft: the row is kept with status `deleted`), reactivate, rename, and set or clear
  the exam date. Past-exam materials are archived automatically at app start and daily while the app is open.
  Archiving immediately reverts the feeds.
- **My Material screen.** A "Studying now" summary (materials · concepts · days to the nearest exam), status chips,
  each material's concepts (tap one for its detail), and upload progress per section.

### Phase B (ingestion and theorem pool) ✅

- **Three gates, all on the device.** The instant checks run first: safety keywords, then title/description language,
  then transcript language (or Whisper). Then trusted channels that clearly cover the concept are accepted by rule.
  Everything else gets one on-device model call that checks it's educational, safe and English.
  English is a hard reject at every stage.
- **Scoped ingestion, two paths only.**
  - Path A, for material concepts: the "Find videos" buttons on coverage-gap cards and on concept pages.
  - Path B, for the curated math theorem pool: the Shorts tab fills it a couple of theorems at a time as you scroll,
    or Settings → *Build theorem pool* does it all in one go. Both can be resumed, and a video already judged is never re-checked.
  - Asking for anything else raises `OutOfScopeIngestion`.
- **Knowledge graph seed.** It's built from readable sources in `tools/` by `python3 tools/build_graph_seed.py`,
  which checks prerequisite references, cycles and alias collisions.
- **Shorts feed.** Full-screen vertical swipe that autoplays and loops. Each short has a Material/Theorem chip,
  its concept and reason label, a Save button, and *Go deeper* when your material has a long-form video for the concept.
- **Concept detail.** The statement (from your material when you have one), LaTeX, the prerequisite chain, videos,
  and *Find some*. That button only appears when the concept is in your material or the theorem pool.
- **Settings.** The on-device model's status, with a download button. Also the pool builder, and a plain list of
  what data leaves the phone.

### Phase A (walking skeleton) ✅

- On-device SQLite schema (all §5 tables), migrations, and FTS5 + trigram indexes.
- On-device resolver: 6-hour cache bounded by the stream URL's own expiry, a 20-second timeout, and a "retry in 30s" contract.
- Scoped feeds with the real §10 rules. Every card has a reason label, concepts without videos get coverage-gap cards, the long-form feed caps at 3 videos per concept, and shorts are blended 65/35.
- `user_active_concepts` recompute (§6.4 priority formula).
- Home feed and native player (quality, speed, captions).
- 5 seed videos, written on first launch through a labelled sample material.


## Using it

1. Install the app (see below).
2. **My Material → Upload PDF**, and pick a chapter or your notes. The first time, this downloads the on-device AI model
   (about 0.5 GB, so use Wi-Fi). A chapter takes a few minutes to read; then videos for its concepts start appearing
   on Home.
3. Open the **Shorts** tab and tap **Find theorem shorts**. Shorts appear within seconds and keep filling as you scroll.
4. On Home, **Find videos** on a coverage-gap card looks for videos for any concept that's still missing them.

Everything is free: there's no API key and no usage limit.
The only waiting is for YouTube, plus about a second per video the model has to judge (more on older phones).

**Sharing with friends.** Build the APK and send it to them directly. Each phone downloads the model once.
It runs on the CPU, so any reasonably recent Android phone works; older or low-memory phones will just be slower.

## Build and install (Android)

You need the Flutter SDK (3.50+) and the Android SDK, including the **NDK**, via Android Studio.
pdfrx compiles a small native library during the build.

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
  trusted-channel rules, out-of-scope refusals, de-duplication, and error handling.
- **Feed scope (critical):** every long-form card has `primary_concept ∈ user_active_concepts`, and every
  short is from the theorem pool or an active concept. This is a randomized property test over 25 seeds.
- **No ads:** no `ads|admob|ad_unit|adslot` in the code, dependencies, strings or manifest.
- **No discovery:** no `discovery|adjacent|explore` in the app code or UI strings.
- **No middleman, no paid AI:** the app never calls a server of its own or an AI API. The only hosts named in its code are YouTube's.
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
- **Search is lexical, not hybrid vector + BM25.** Without an embedding model, stage 3 is concept-tag lookup plus BM25,
  and the §11.3 vector weight goes to BM25. Typo tolerance and aliases come from the fuzzy concept matcher instead.
- **Golden set built in the app.** The spec ships a hand-picked golden list in a test file. Picking real videos
  needs YouTube and your judgement, so labelling happens on the device instead. The metric arithmetic is unit-tested
  with synthetic judges that pass and fail.
- **12 judged candidates per concept, not ~20.** This keeps on-device judging to three short model calls per concept.
- **Concept merging without embeddings.** §6.4 dedupes and maps concepts with embeddings (cosine 0.9 and 0.85).
  Until the embedding model arrives in Phase D, this uses fuzzy name and alias matching (token_set_ratio),
  backed by the 364-concept graph's aliases.
- **The dev seed is gone.** The five Phase A sample videos are now only a test fixture. A fresh install starts with the
  upload prompt on Home and the theorem pool on Shorts.
- **No thumbnail image check.** The on-device model reads text only, so Gate 2 is the keyword filter, trusted channels,
  and the model's check of the title, description and transcript. A vision model would add over a gigabyte.
- **Reading PDFs: the whole text, rules first, AI only for doubtful finds.** Real PDF text has no blank lines
  between paragraphs, so paragraphs are rebuilt from the line layout. The contents page is skipped; headings are
  read whether numbered "7.1 …", "4 …" or "Chapter 7 …". Concepts are read from inside the sections too:
  box titles on their own line ("Plane mirror"), "Term — depends on …" bullets, defining sentences
  ("A lens is …", "… is called dispersion", "… is the critical angle"), vocabulary lists ("Focal length f",
  "Power P"), labelled theorems and definitions, and known graph concepts. Sentence-like headings
  ("It bends towards the normal") are not used as names; "Refraction and dispersion" becomes two concepts. Question
  banks, formula sheets and exam drills are not mined. Concepts the notes say to review or assume stay
  prerequisites. Confident finds are kept without the AI; only doubtful ones (a lone word, a phrase in
  brackets, a passing mention) go to the on-device model, at most 40, in batches of 10, answered with
  lists of numbers so each call is a few dozen output tokens. If the AI fails, the confident finds stand.
  Settings → *Deep read* additionally has the AI read every section, which is slower.
- **English only.** The spoken language must be English: YouTube's speech-recognised caption track
  tells which language it heard, so a Tamil or Hindi video with English subtitles is rejected. With no
  speech track, the first 30 s are checked on the device (last, since it's slow). Titles, descriptions
  and captions must read as English too: besides the language detector, a word check rejects Hindi,
  Tamil, Telugu, Malayalam and Kannada written in English letters. Videos added before these checks are
  re-checked once in the background at start-up and removed if they fail.
- **Shorts and long videos for every concept, and it keeps going.** After an upload (and whenever the app
  opens) the app fills every concept of your notes round by round: round 1 finds 3 long videos and 3 shorts
  per concept (shorts have their own "#shorts" searches), and each further round adds 3 more of each with
  differently worded searches ("explained", "examples", "problems solved", …) until every concept has 20 long
  videos and 20 shorts, or YouTube has nothing new. The banner shows the round; Stop pauses it (also across
  restarts) until Continue.
- **Faster video checks, in your notes' sense.** For each concept the app searches YouTube for its name
  plus words from its chapter ("Superposition standing waves physics"; short names also get their subject)
  and checks the top 8 results; the next concept's search starts while the current one is checked, and the
  next 3 candidates' details download in parallel. Most videos are decided by rule, without the AI: a trusted
  channel covering the concept, or a title that names it and captions that say it and mention 2+ other
  concepts from your notes. A title that qualifies the concept with a word your notes never use ("Quantum
  superposition" for notes on sound waves) always goes to the AI, which is told the PDF and chapter the
  concept comes from and answers with booleans only (about 25 output tokens). At start-up, videos already in
  the library in another sense of their concept are unlinked from it. Videos without captions need the speech
  model, so they are checked last and only if the captioned ones didn't fill the concept. Trade-off: a video
  accepted by rule skips the model's extra safety read; it still passes the unsafe-word filter and the
  English checks.
- **Model memory.** The model is unloaded after 90 seconds without use, freeing roughly 0.6–0.9 GB of RAM.
  The next check, upload or relevance run reloads it from the file on the device in a few seconds,
  without downloading it again.
- **Model storage.** llamadart keeps the downloaded model in the app's cache. Android may clear that when storage runs low;
  if so, the model downloads again the next time it's needed.
- **History.** The earlier server-based version (FastAPI + Postgres + yt-dlp) is in git history at commit
  `2423f60`.
