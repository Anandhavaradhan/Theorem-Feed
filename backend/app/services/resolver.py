"""Ad-free playback core (§12).

GET /resolve?video_id=<our UUID>
  1. Cache hit in video_resolutions (not expired) -> return.
  2. Else run yt-dlp --dump-json (20s timeout).
  3. Return {video_id, title, description, transcript, language, duration,
            is_vertical, thumbnail, formats:[{url, quality, mime}], expires_at}.
  4. Cache 6h (or less, if the stream URLs expire sooner).
  5. On failure: {"error": "resolve_failed", "retry_after": 30}.

Only videos already in our `videos` table (i.e. that passed the scoped
ingestion gates) can be resolved — the resolver is not a general YouTube proxy.
No IFrame player, no ads, no tracking.
"""
from __future__ import annotations

import asyncio
import json
import logging
import sys
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import parse_qs, urlparse

from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import Video, VideoResolution

log = logging.getLogger(__name__)

# Give ourselves a margin so the client never receives an about-to-expire URL.
_URL_EXPIRY_MARGIN = timedelta(minutes=10)


class ResolveError(Exception):
    """yt-dlp failed, timed out, or returned nothing playable."""


def youtube_url(source_id: str) -> str:
    return f"https://www.youtube.com/watch?v={source_id}"


def build_ytdlp_cmd(source_id: str) -> list[str]:
    s = get_settings()
    base = [s.ytdlp_bin] if s.ytdlp_bin else [sys.executable, "-m", "yt_dlp"]
    return [
        *base,
        "--dump-json",
        "--no-warnings",
        "--no-playlist",
        "--extractor-args",
        "youtube:player_client=android,web",
        youtube_url(source_id),
    ]


async def run_ytdlp(source_id: str) -> dict[str, Any]:
    timeout = get_settings().resolve_timeout_sec
    try:
        proc = await asyncio.create_subprocess_exec(
            *build_ytdlp_cmd(source_id),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError as e:
        raise ResolveError(f"cannot start yt-dlp: {e}") from e
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except TimeoutError as e:
        proc.kill()
        await proc.wait()
        raise ResolveError(f"yt-dlp timed out after {timeout}s") from e
    if proc.returncode != 0:
        raise ResolveError(stderr.decode(errors="replace").strip()[-500:] or "yt-dlp failed")
    try:
        return json.loads(stdout)
    except json.JSONDecodeError as e:
        raise ResolveError("yt-dlp returned invalid JSON") from e


def _mime_for(fmt: dict[str, Any]) -> str:
    protocol = fmt.get("protocol") or ""
    if "m3u8" in protocol:
        return "application/x-mpegURL"
    if "dash" in protocol:
        return "application/dash+xml"
    ext = fmt.get("ext") or "mp4"
    return f"video/{ext}"


def _url_expiry(url: str) -> datetime | None:
    """googlevideo URLs carry `expire=<unix ts>`; respect it."""
    try:
        exp = parse_qs(urlparse(url).query).get("expire")
        if exp:
            return datetime.fromtimestamp(int(exp[0]), tz=UTC)
    except (ValueError, OverflowError):
        pass
    return None


def _playable_formats(info: dict[str, Any]) -> list[dict[str, Any]]:
    """Formats a native player can open from one URL: muxed A+V progressive or HLS.

    Video-only / audio-only DASH streams are excluded: playing them would need a
    client-side muxer, which video_player / media_kit don't do from split URLs.
    """
    out: list[dict[str, Any]] = []
    seen: set[tuple[int, str]] = set()
    for f in info.get("formats") or []:
        url = f.get("url")
        if not url:
            continue
        vcodec, acodec = f.get("vcodec"), f.get("acodec")
        protocol = f.get("protocol") or ""
        is_hls = "m3u8" in protocol
        muxed = vcodec not in (None, "none") and acodec not in (None, "none")
        if not (muxed or is_hls):
            continue
        if vcodec == "none":  # audio-only HLS
            continue
        height = int(f.get("height") or 0)
        mime = _mime_for(f)
        key = (height, mime)
        if key in seen:
            continue
        seen.add(key)
        out.append(
            {
                "url": url,
                "quality": f"{height}p" if height else (f.get("format_note") or "auto"),
                "height": height,
                "width": int(f.get("width") or 0),
                "mime": mime,
            }
        )
    # Best first; Flutter picks the highest quality <= device resolution.
    out.sort(key=lambda x: (x["height"], x["mime"] != "application/x-mpegURL"), reverse=True)
    return out


def _english_captions(info: dict[str, Any]) -> list[dict[str, str]]:
    """English caption tracks (manual preferred over auto) for the player's SRT/VTT overlay."""
    tracks: list[dict[str, str]] = []
    sources = (("manual", info.get("subtitles") or {}), ("auto", info.get("automatic_captions") or {}))
    for kind, src in sources:
        track = next(
            (
                {"kind": kind, "lang": lang, "ext": t["ext"], "url": t["url"]}
                for lang in ("en", "en-US", "en-GB")
                for t in src.get(lang) or []
                if t.get("ext") in ("vtt", "srt") and t.get("url")
            ),
            None,
        )
        if track:
            tracks.append(track)
    return tracks


def parse_ytdlp_info(
    info: dict[str, Any], *, video: Video, now: datetime | None = None
) -> dict[str, Any]:
    """Pure transform: yt-dlp JSON -> resolver payload. Raises ResolveError if unplayable."""
    now = now or datetime.now(UTC)
    formats = _playable_formats(info)
    if not formats:
        raise ResolveError("no playable muxed/HLS formats")

    width, height = info.get("width"), info.get("height")
    if not (width and height):
        width, height = formats[0]["width"], formats[0]["height"]
    is_vertical = bool(width and height and height > width)

    expires_at = now + timedelta(hours=get_settings().resolve_cache_hours)
    url_expiries = [e for e in (_url_expiry(f["url"]) for f in formats) if e]
    if url_expiries:
        expires_at = min(expires_at, min(url_expiries) - _URL_EXPIRY_MARGIN)

    return {
        "video_id": str(video.id),
        "title": info.get("title") or video.title,
        "description": info.get("description") or video.description,
        # Full transcript is captured at ingestion time (Phase B); captions are for the player.
        "transcript": video.transcript,
        "captions": _english_captions(info),
        "language": info.get("language"),
        "duration": info.get("duration") or video.duration_sec,
        "is_vertical": is_vertical,
        "thumbnail": info.get("thumbnail") or video.thumbnail_url,
        "formats": [{"url": f["url"], "quality": f["quality"], "mime": f["mime"], "height": f["height"]} for f in formats],
        "expires_at": expires_at.isoformat(),
    }


async def resolve_video(session: AsyncSession, video: Video) -> dict[str, Any]:
    now = datetime.now(UTC)
    cached = await session.get(VideoResolution, video.id)
    if cached and cached.expires_at > now:
        return cached.payload

    if video.source != "youtube":
        raise ResolveError(f"source '{video.source}' is not resolvable via yt-dlp")

    info = await run_ytdlp(video.source_id)
    payload = parse_ytdlp_info(info, video=video, now=now)

    stmt = insert(VideoResolution).values(
        video_id=video.id,
        payload=payload,
        resolved_at=now,
        expires_at=datetime.fromisoformat(payload["expires_at"]),
    )
    stmt = stmt.on_conflict_do_update(
        index_elements=[VideoResolution.video_id],
        set_={"payload": stmt.excluded.payload, "resolved_at": stmt.excluded.resolved_at,
              "expires_at": stmt.excluded.expires_at},
    )
    await session.execute(stmt)
    await session.commit()
    return payload
