"""Recompute the derived `user_active_concepts` cache (§6.4 step 4).

priority(c) = Σ_material (importance × recency_factor(material)) × exam_proximity_boost(c)

  recency_factor:        1.0 if material age ≤ 30 days, linear down to 0.5 at 180 days, 0.5 after.
  exam_proximity_boost:  1.8 if any active material containing c has exam_date within 14 days.
  best_statement / best_difficulty: from the highest-importance material for c.

Only materials with status='active' contribute. Archived / deleted material
therefore drops its concepts out of the feeds and search on the next recompute.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import UTC, date, datetime

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Material, MaterialConcept, UserActiveConcept

EXAM_BOOST = 1.8
EXAM_WINDOW_DAYS = 14


def recency_factor(created_at: datetime, now: datetime) -> float:
    age_days = (now - created_at).total_seconds() / 86400
    if age_days <= 30:
        return 1.0
    if age_days >= 180:
        return 0.5
    return 1.0 - 0.5 * (age_days - 30) / 150


def exam_is_near(exam_date: date | None, today: date) -> bool:
    return exam_date is not None and 0 <= (exam_date - today).days <= EXAM_WINDOW_DAYS


@dataclass
class _Acc:
    base: float = 0.0
    boost: bool = False
    best_importance: float = -1.0
    best_statement: str = ""
    best_difficulty: str = "undergrad"
    materials: set[uuid.UUID] = field(default_factory=set)
    # importance already counted per material (dedupe duplicate rows in one material)
    per_material: dict[uuid.UUID, float] = field(default_factory=dict)


def compute_priorities(
    rows: list[tuple[MaterialConcept, Material]], now: datetime
) -> dict[uuid.UUID, _Acc]:
    """Pure function so it can be unit-tested without a DB."""
    today = now.date()
    acc: dict[uuid.UUID, _Acc] = {}
    for mc, m in rows:
        a = acc.setdefault(mc.concept_id, _Acc())
        prev = a.per_material.get(m.id)
        if prev is None or mc.importance > prev:
            # Replace this material's contribution with its max-importance row.
            rf = recency_factor(m.created_at, now)
            if prev is not None:
                a.base -= prev * rf
            a.base += mc.importance * rf
            a.per_material[m.id] = mc.importance
        a.materials.add(m.id)
        a.boost = a.boost or exam_is_near(m.exam_date, today)
        if mc.importance > a.best_importance:
            a.best_importance = mc.importance
            a.best_statement = mc.statement
            a.best_difficulty = mc.difficulty
    return acc


async def recompute_user_active_concepts(session: AsyncSession, now: datetime | None = None) -> int:
    now = now or datetime.now(UTC)
    rows = (
        await session.execute(
            select(MaterialConcept, Material)
            .join(Material, Material.id == MaterialConcept.material_id)
            .where(Material.status == "active")
        )
    ).all()
    acc = compute_priorities([(r[0], r[1]) for r in rows], now)

    # This table is a derived cache, not user data: rebuilding it is not a hard-delete
    # of anything the user owns (materials / watch history are never deleted).
    await session.execute(delete(UserActiveConcept))
    for concept_id, a in acc.items():
        session.add(
            UserActiveConcept(
                concept_id=concept_id,
                priority=a.base * (EXAM_BOOST if a.boost else 1.0),
                best_statement=a.best_statement,
                best_difficulty=a.best_difficulty,
                source_material_ids=sorted(a.materials),
                updated_at=now,
            )
        )
    await session.commit()
    return len(acc)
