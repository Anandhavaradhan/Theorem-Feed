from __future__ import annotations

import uuid
from typing import Literal

from pydantic import BaseModel

ReasonKind = Literal["material", "theorem"]


class FeedCard(BaseModel):
    """Every card carries a reason label (constraint #14). No label, no card."""

    video_id: uuid.UUID
    title: str
    thumbnail_url: str | None
    duration_sec: int | None
    is_short: bool
    concept_id: uuid.UUID
    concept_name: str
    reason_kind: ReasonKind
    reason_label: str
    score: float | None = None


class CardAction(BaseModel):
    label: str
    action: Literal["ingest_concept", "related", "theorem_search", "upload_material"]


class CoverageGapCard(BaseModel):
    type: Literal["coverage_gap"] = "coverage_gap"
    concept_id: uuid.UUID
    concept: str
    message: str
    actions: list[CardAction]


class FeedResponse(BaseModel):
    items: list[FeedCard]
    coverage_gaps: list[CoverageGapCard] = []
    # 'upload_material' when the user has no active material (§1, §10.4).
    empty_state: Literal["upload_material"] | None = None


class VideoOut(BaseModel):
    id: uuid.UUID
    title: str
    description: str
    duration_sec: int | None
    thumbnail_url: str | None
    is_short: bool
    subject: str | None


class ResolveFailure(BaseModel):
    error: Literal["resolve_failed"] = "resolve_failed"
    retry_after: int
