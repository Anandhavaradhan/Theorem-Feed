import json
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from app.services import resolver
from app.services.resolver import ResolveError, parse_ytdlp_info
from tests import factories as f

SAMPLE = json.loads((Path(__file__).parent / "fixtures" / "ytdlp_sample.json").read_text())
NOW = datetime(2026, 11, 21, 12, 0, tzinfo=UTC)


def _video():
    v = f.video("WUvTyaaNkzM")
    v.transcript = "stored transcript"
    return v


def test_only_single_url_playable_formats_best_first():
    p = parse_ytdlp_info(SAMPLE, video=_video(), now=NOW)
    urls = [x["url"] for x in p["formats"]]
    # video-only DASH, audio-only, storyboard and audio-only HLS are excluded
    assert not any(u.endswith(("vonly?expire=4102444800", "audio?expire=4102444800", "audio.m3u8", "/sb/x")) for u in urls)
    assert [x["quality"] for x in p["formats"]] == ["1080p", "720p", "360p"]
    assert p["formats"][0]["mime"] == "application/x-mpegURL"
    assert p["formats"][-1]["mime"] == "video/mp4"


def test_payload_shape_matches_spec():
    p = parse_ytdlp_info(SAMPLE, video=_video(), now=NOW)
    for key in ("video_id", "title", "description", "transcript", "language", "duration",
                "is_vertical", "thumbnail", "formats", "expires_at"):
        assert key in p
    assert p["is_vertical"] is False
    assert p["language"] == "en"
    assert p["transcript"] == "stored transcript"


def test_english_captions_manual_then_auto_never_other_languages():
    caps = parse_ytdlp_info(SAMPLE, video=_video(), now=NOW)["captions"]
    assert [(c["kind"], c["url"]) for c in caps] == [("manual", "https://x/en.vtt"), ("auto", "https://x/auto-en.vtt")]


def test_expiry_is_6h_unless_stream_url_expires_sooner():
    p = parse_ytdlp_info(SAMPLE, video=_video(), now=NOW)
    assert datetime.fromisoformat(p["expires_at"]) == NOW + timedelta(hours=6)

    soon = int((NOW + timedelta(hours=1)).timestamp())
    info = json.loads(json.dumps(SAMPLE))
    info["formats"][3]["url"] = f"https://rr1.googlevideo.com/muxed360?expire={soon}"
    p = parse_ytdlp_info(info, video=_video(), now=NOW)
    assert datetime.fromisoformat(p["expires_at"]) == NOW + timedelta(minutes=50)


def test_vertical_detection():
    info = dict(SAMPLE, width=1080, height=1920)
    assert parse_ytdlp_info(info, video=_video(), now=NOW)["is_vertical"] is True


def test_unplayable_raises():
    with pytest.raises(ResolveError):
        parse_ytdlp_info({"formats": [SAMPLE["formats"][2]]}, video=_video(), now=NOW)


def test_command_uses_spec_flags():
    cmd = resolver.build_ytdlp_cmd("abc")
    assert "--dump-json" in cmd and "--no-warnings" in cmd and "--no-playlist" in cmd
    assert "youtube:player_client=android,web" in cmd
    assert cmd[-1] == "https://www.youtube.com/watch?v=abc"


# --- endpoint ---------------------------------------------------------------

async def test_resolve_endpoint_caches(client, session, monkeypatch):
    v = f.video("WUvTyaaNkzM")
    session.add(v)
    await session.commit()
    calls = []

    async def fake(source_id):
        calls.append(source_id)
        return SAMPLE

    monkeypatch.setattr(resolver, "run_ytdlp", fake)
    r1 = await client.get("/resolve", params={"video_id": str(v.id)})
    r2 = await client.get("/resolve", params={"video_id": str(v.id)})
    assert r1.status_code == r2.status_code == 200
    assert r1.json() == r2.json()
    assert calls == ["WUvTyaaNkzM"]  # second hit served from video_resolutions


async def test_resolve_failure_contract(client, session, monkeypatch):
    v = f.video("broken")
    session.add(v)
    await session.commit()

    async def boom(_):
        raise ResolveError("nope")

    monkeypatch.setattr(resolver, "run_ytdlp", boom)
    r = await client.get("/resolve", params={"video_id": str(v.id)})
    assert r.status_code == 503
    assert r.json() == {"error": "resolve_failed", "retry_after": 30}
    assert r.headers["retry-after"] == "30"


async def test_resolve_refuses_unknown_or_rejected(client, session):
    rejected = f.video("rej", status="rejected_lang")
    session.add(rejected)
    await session.commit()
    assert (await client.get("/resolve", params={"video_id": str(uuid.uuid4())})).status_code == 404
    assert (await client.get("/resolve", params={"video_id": str(rejected.id)})).status_code == 404


@pytest.mark.live
async def test_live_resolve_and_ffprobe(session):
    """§15.2: resolve a live URL and ffprobe the first format. Needs YouTube network access."""
    import asyncio
    import shutil

    info = await resolver.run_ytdlp("WUvTyaaNkzM")
    p = parse_ytdlp_info(info, video=f.video("WUvTyaaNkzM"))
    assert p["formats"]
    if shutil.which("ffprobe"):
        proc = await asyncio.create_subprocess_exec(
            "ffprobe", "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0",
            p["formats"][0]["url"], stdout=asyncio.subprocess.PIPE)
        out, _ = await asyncio.wait_for(proc.communicate(), 60)
        assert b"video" in out
