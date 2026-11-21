"""Feeds (§10). Scope predicates are the non-negotiable core of the app:

  long-form:  status='active' AND is_short=false AND primary_concept ∈ user_active_concepts
  shorts:     status='active' AND is_short=true AND
              ((in_theorem_pool AND subject='math') OR primary_concept ∈ user_active_concepts)

There is no fallback, no "explore", no adjacent-topic padding. An empty
long-form feed is an empty state (upload CTA) or coverage-gap cards.
"""
from __future__ import annotations

import uuid
from collections import Counter
from dataclasses import dataclass

from sqlalchemy import and_, exists, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Concept, RelevanceScore, UserActiveConcept, Video, VideoConcept
from app.schemas import CardAction, CoverageGapCard, FeedCard, FeedResponse

LONGFORM_PER_CONCEPT_CAP = 3
SHORTS_MATERIAL_SHARE = 0.65


def material_label(concept_name: str) -> str:
    return f"From your material: {concept_name}"


def theorem_label(concept_name: str) -> str:
    return f"Math theorem: {concept_name}"


@dataclass
class _Row:
    video: Video
    concept_id: uuid.UUID
    concept_name: str
    priority: float  # concept priority (0 for theorem-pool-only)
    final: float | None  # cached LLM-judge score, if any
    from_material: bool

    def sort_key(self) -> tuple[float, float, float]:
        # relevance_scores.final desc; cold start falls back to concept priority (§10.4).
        has = 1.0 if self.final is not None else 0.0
        return (has, self.final or 0.0, self.priority)

    def card(self) -> FeedCard:
        v = self.video
        return FeedCard(
            video_id=v.id,
            title=v.title,
            thumbnail_url=v.thumbnail_url,
            duration_sec=v.duration_sec,
            is_short=v.is_short,
            concept_id=self.concept_id,
            concept_name=self.concept_name,
            reason_kind="material" if self.from_material else "theorem",
            reason_label=material_label(self.concept_name)
            if self.from_material
            else theorem_label(self.concept_name),
            score=self.final,
        )


def _best_per_video(rows: list[_Row]) -> list[_Row]:
    """A video can be primary for several active concepts; keep its strongest pairing."""
    best: dict[uuid.UUID, _Row] = {}
    for r in rows:
        cur = best.get(r.video.id)
        if cur is None or (r.from_material, r.sort_key()) > (cur.from_material, cur.sort_key()):
            best[r.video.id] = r
    return sorted(best.values(), key=lambda r: r.sort_key(), reverse=True)


async def _material_rows(session: AsyncSession, *, is_short: bool) -> list[_Row]:
    stmt = (
        select(Video, Concept.id, Concept.canonical_name, UserActiveConcept.priority, RelevanceScore.final)
        .join(VideoConcept, and_(VideoConcept.video_id == Video.id, VideoConcept.is_primary.is_(True)))
        .join(UserActiveConcept, UserActiveConcept.concept_id == VideoConcept.concept_id)
        .join(Concept, Concept.id == VideoConcept.concept_id)
        .outerjoin(
            RelevanceScore,
            and_(RelevanceScore.video_id == Video.id, RelevanceScore.concept_id == VideoConcept.concept_id),
        )
        .where(Video.status == "active", Video.is_short.is_(is_short))
    )
    res = await session.execute(stmt)
    return [_Row(v, cid, name, prio, final, True) for v, cid, name, prio, final in res.all()]


async def _theorem_pool_rows(session: AsyncSession) -> list[_Row]:
    stmt = (
        select(Video, Concept.id, Concept.canonical_name, RelevanceScore.final)
        .join(VideoConcept, and_(VideoConcept.video_id == Video.id, VideoConcept.is_primary.is_(True)))
        .join(Concept, Concept.id == VideoConcept.concept_id)
        .outerjoin(
            RelevanceScore,
            and_(RelevanceScore.video_id == Video.id, RelevanceScore.concept_id == VideoConcept.concept_id),
        )
        .where(
            Video.status == "active",
            Video.is_short.is_(True),
            Video.in_theorem_pool.is_(True),
            Video.subject == "math",
        )
        .order_by(Video.created_at)  # curated (insertion) order for cold start
    )
    res = await session.execute(stmt)
    return [_Row(v, cid, name, 0.0, final, False) for v, cid, name, final in res.all()]


async def has_active_material(session: AsyncSession) -> bool:
    return bool(await session.scalar(select(exists().select_from(UserActiveConcept))))


async def coverage_gaps(session: AsyncSession) -> list[CoverageGapCard]:
    """Active concepts with zero active long-form videos. Never a silent empty (#12)."""
    has_video = (
        select(VideoConcept.video_id)
        .join(Video, Video.id == VideoConcept.video_id)
        .where(
            VideoConcept.concept_id == UserActiveConcept.concept_id,
            VideoConcept.is_primary.is_(True),
            Video.status == "active",
            Video.is_short.is_(False),
        )
        .exists()
    )
    res = await session.execute(
        select(Concept.id, Concept.canonical_name)
        .join(UserActiveConcept, UserActiveConcept.concept_id == Concept.id)
        .where(~has_video)
        .order_by(UserActiveConcept.priority.desc(), func.lower(Concept.canonical_name))
    )
    return [
        CoverageGapCard(
            concept_id=cid,
            concept=name,
            message="You're studying this concept but have no videos for it yet.",
            actions=[
                CardAction(label="Find videos for this concept", action="ingest_concept"),
                CardAction(label="Related material concepts", action="related"),
            ],
        )
        for cid, name in res.all()
    ]


def cap_per_concept(rows: list[_Row], cap: int, window: int) -> list[_Row]:
    """At most `cap` videos per concept in the visible window; overflow follows after."""
    head: list[_Row] = []
    overflow: list[_Row] = []
    counts: Counter[uuid.UUID] = Counter()
    for r in rows:
        if len(head) < window and counts[r.concept_id] < cap:
            head.append(r)
            counts[r.concept_id] += 1
        else:
            overflow.append(r)
    return head + overflow


async def longform_feed(session: AsyncSession, limit: int = 30) -> FeedResponse:
    if not await has_active_material(session):
        return FeedResponse(items=[], empty_state="upload_material")
    rows = _best_per_video(await _material_rows(session, is_short=False))
    rows = cap_per_concept(rows, LONGFORM_PER_CONCEPT_CAP, window=limit)[:limit]
    return FeedResponse(items=[r.card() for r in rows], coverage_gaps=await coverage_gaps(session))


def interleave(material: list[_Row], pool: list[_Row], share: float) -> list[_Row]:
    """Blend two ranked queues at ~`share` material, avoiding the same concept back-to-back."""
    out: list[_Row] = []
    m, p = list(material), list(pool)
    n_mat = 0
    while m or p:
        want_material = bool(m) and (not p or n_mat < share * (len(out) + 1))
        queue = m if want_material else p
        last = out[-1].concept_id if out else None
        idx = next((i for i, r in enumerate(queue) if r.concept_id != last), 0)
        out.append(queue.pop(idx))
        n_mat += want_material
    return out


async def shorts_feed(session: AsyncSession, limit: int = 30) -> FeedResponse:
    pool = await _theorem_pool_rows(session)
    if not await has_active_material(session):
        # Cold start: 100% theorem pool in curated order (dedupe consecutive concepts).
        return FeedResponse(items=[r.card() for r in interleave([], pool, 0.0)[:limit]])

    material = _best_per_video(await _material_rows(session, is_short=True))
    material_ids = {r.video.id for r in material}
    pool = [r for r in pool if r.video.id not in material_ids]
    pool.sort(key=lambda r: r.sort_key(), reverse=True)
    return FeedResponse(items=[r.card() for r in interleave(material, pool, SHORTS_MATERIAL_SHARE)[:limit]])
