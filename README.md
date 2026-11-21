# TheoremFeed

A personal, ad-free, **material-driven** study app. You upload your study material; the app
shows only videos for concepts in that material, plus a curated pool of math-theorem shorts.
It has no discovery feed, no ads, no accounts and no telemetry.

> Personal use only. Never distributed.

## Status: Phase A (walking skeleton) ✅

| Piece | State |
|---|---|
| Postgres 16 + pgvector + pg_trgm schema (all §5 tables, HNSW / GIN / trigram indexes) | ✅ Alembic `0001` |
| yt-dlp resolver `GET /resolve` (6h cache, 20s timeout, failure contract) | ✅ |
| Scoped feeds `GET /feed/longform`, `GET /feed/shorts` (real §10 predicates, reason labels, coverage gaps) | ✅ |
| `user_active_concepts` recompute (§6.4 priority formula) | ✅ |
| Flutter: Home (long-form feed) + native Player (chewie, quality, speed, captions) | ✅ |
| 5 hardcoded videos (`python -m app.seed_phase_a`) | ✅ |

Next: **Phase B**, which covers the three-gate ingestion, `graph_seed_v1.json`, the theorem pool, the shorts UI and concept detail.

## Layout

```
backend/   FastAPI (async) + SQLAlchemy 2 + Alembic + yt-dlp
mobile/    Flutter app (en-US only; strings in assets/i18n/en.json, t() helper)
docker-compose.yml
```

## Run the backend

**Docker (recommended, local machine or small VPS):**

```sh
docker compose up -d --build
docker compose exec backend python -m app.seed_phase_a
curl localhost:8000/feed/longform
```

**Bare metal (for development):** this needs Postgres 16 with the `vector` and `pg_trgm` extensions.

```sh
cd backend
python3.11 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/alembic upgrade head
.venv/bin/python -m app.seed_phase_a
.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Settings come from `TF_*` environment variables; see `backend/app/config.py`.

## Run the app

```sh
cd mobile
flutter pub get
flutter run --dart-define=TF_API_BASE=http://<your-machine-LAN-ip>:8000
```

The default `TF_API_BASE` is `http://10.0.2.2:8000`, which is the host machine as seen from the Android emulator.
Side-load the release build to your own device with `flutter build apk` or an Xcode archive.

## Tests

```sh
cd backend && .venv/bin/pytest -m "not live"   # unit + DB + feed-scope property + guardrails
cd backend && .venv/bin/pytest -m live         # live YouTube resolve + ffprobe (needs network)
cd mobile  && flutter test
```

The backend tests use a separate database, `theoremfeed_test`. You can override it with `TF_TEST_DATABASE_URL` and
`TF_TEST_DATABASE_URL_SYNC`. The tests migrate it with the real Alembic migration.

Guardrail tests run on every change:
- **Feed scope (critical):** every long-form card has `primary_concept ∈ user_active_concepts`, and every short is from the
  theorem pool or an active concept. This is a randomized property test.
- **No ads:** no `ads|admob|ad_unit|adslot` anywhere in the code. Comments are excluded.
- **No discovery:** no `discovery|adjacent|explore` anywhere in the backend code.
- Every `t('key')` used in the app exists in `en.json`.

## Design decisions (documented, non-blocking)

- **The Phase A seed goes through the real scope rules.** The 5 videos come from a labelled
  "Phase A sample material", so the Home feed shows them through the normal
  `primary_concept ∈ user_active_concepts` predicate. They are not hardcoded into the feed.
  Archiving that material (Phase C) reverts the feed to the upload CTA.
- **`/resolve` takes TheoremFeed's video UUID, not a YouTube ID.** Only videos that passed scoped
  ingestion can be played, so the resolver is not a general YouTube proxy.
- **The resolver only returns formats a native player can open from one URL:** muxed MP4 and HLS.
  It skips DASH video-only and audio-only streams. `expires_at` is the earlier of 6 hours and the
  stream URL's own `expire=` minus a 10-minute margin.
- **On failure,** the resolver returns `503` with `{"error":"resolve_failed","retry_after":30}` and a `Retry-After` header.
  The app counts down and retries.
- **Captions** are fetched from the English caption track that `/resolve` returns (manual first, then auto),
  as VTT or SRT. The full transcript text is stored at ingestion, starting in Phase B.
- **Keeping yt-dlp fresh:** watchtower can only re-pull registry images, and the backend image is built locally.
  So the backend entrypoint runs `pip install -U yt-dlp` on every start. Phase F adds a weekly in-app job.
- **Flutter 3.50+:** Material is imported from `package:material_ui` (the framework split).
