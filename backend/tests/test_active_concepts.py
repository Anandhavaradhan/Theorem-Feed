from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from app.models import UserActiveConcept
from app.services.active_concepts import recency_factor, recompute_user_active_concepts
from tests import factories as f

NOW = datetime(2026, 11, 21, tzinfo=UTC)


@pytest.mark.parametrize("days,expected", [(0, 1.0), (30, 1.0), (105, 0.75), (180, 0.5), (400, 0.5)])
def test_recency_factor(days, expected):
    assert recency_factor(NOW - timedelta(days=days), NOW) == pytest.approx(expected)


async def test_priority_sums_materials_boosts_exam_and_ignores_archived(session):
    a, b = f.concept("A"), f.concept("B")
    fresh = f.material("fresh", created=NOW, exam=(NOW + timedelta(days=7)).date())
    old = f.material("old", created=NOW - timedelta(days=105))
    archived = f.material("arch", status="archived", created=NOW)
    session.add_all([a, b, fresh, old, archived])
    await session.flush()
    session.add_all([
        f.mc(fresh, a, 0.5, statement="fresh A", difficulty="highschool"),
        f.mc(old, a, 0.8, statement="old A", difficulty="advanced"),
        f.mc(old, b, 0.4),
        f.mc(archived, b, 1.0),
    ])
    await session.commit()

    assert await recompute_user_active_concepts(session, now=NOW) == 2
    rows = {r.concept.canonical_name: r for r in (await session.scalars(select(UserActiveConcept))).all()}
    # A: (0.5*1.0 + 0.8*0.75) * 1.8 (exam within 14 days on `fresh`)
    assert rows["A"].priority == pytest.approx((0.5 + 0.6) * 1.8)
    assert rows["A"].best_statement == "old A" and rows["A"].best_difficulty == "advanced"
    # B: archived material contributes nothing
    assert rows["B"].priority == pytest.approx(0.4 * 0.75)
    assert rows["B"].source_material_ids == [old.id]


async def test_past_exam_does_not_boost(session):
    a = f.concept("A")
    m = f.material(created=NOW, exam=(NOW - timedelta(days=1)).date())
    session.add_all([a, m])
    await session.flush()
    session.add(f.mc(m, a, 0.5))
    await session.commit()
    await recompute_user_active_concepts(session, now=NOW)
    assert (await session.scalar(select(UserActiveConcept.priority))) == pytest.approx(0.5)
