"""§15.4 Feed scope test (critical). Any violation = bug.

Every long-form card: primary_concept ∈ user_active_concepts.
Every short:          in_theorem_pool (math) OR primary_concept ∈ user_active_concepts.
Every card:           has a non-empty reason label.
"""
import random

import pytest
from sqlalchemy import select

from app.models import UserActiveConcept, Video, VideoConcept
from app.services import feed
from app.services.active_concepts import recompute_user_active_concepts
from tests import factories as f


async def _random_world(session, seed: int):
    rng = random.Random(seed)
    concepts = [f.concept(f"C{seed}-{i}", pool=rng.random() < 0.3) for i in range(12)]
    materials = [f.material(f"M{i}", status=rng.choice(["active", "active", "archived", "deleted"]))
                 for i in range(3)]
    session.add_all(concepts + materials)
    await session.flush()
    for m in materials:
        for c in rng.sample(concepts, 4):
            session.add(f.mc(m, c, round(rng.uniform(0.1, 1.0), 2)))
    for i in range(40):
        short = rng.random() < 0.5
        v = f.video(f"v{seed}-{i}", short=short, pool=short and rng.random() < 0.4,
                    status=rng.choice(["active"] * 4 + ["rejected_lang", "rejected_edu"]),
                    subject=rng.choice(["math", "math", "physics"]))
        session.add(v)
        await session.flush()
        for j, c in enumerate(rng.sample(concepts, rng.randint(1, 2))):
            session.add(f.tag(v, c, primary=(j == 0 or rng.random() < 0.3)))
    await session.commit()
    await recompute_user_active_concepts(session)


async def _primaries(session, video_id):
    return set((await session.scalars(
        select(VideoConcept.concept_id).where(VideoConcept.video_id == video_id, VideoConcept.is_primary)
    )).all())


@pytest.mark.parametrize("seed", range(8))
async def test_feed_scope_property(session, seed):
    await _random_world(session, seed)
    active = set((await session.scalars(select(UserActiveConcept.concept_id))).all())

    longform = await feed.longform_feed(session, limit=100)
    for card in longform.items:
        v = await session.get(Video, card.video_id)
        assert v.status == "active" and not v.is_short
        assert card.concept_id in active
        assert card.concept_id in await _primaries(session, v.id)
        assert card.reason_label == f"From your material: {card.concept_name}"

    shorts = await feed.shorts_feed(session, limit=100)
    for card in shorts.items:
        v = await session.get(Video, card.video_id)
        assert v.status == "active" and v.is_short
        in_pool = v.in_theorem_pool and v.subject == "math"
        assert in_pool or (await _primaries(session, v.id)) & active
        assert card.reason_label.startswith(("From your material: ", "Math theorem: "))
        if card.reason_kind == "material":
            assert card.concept_id in active

    # Coverage gaps are exactly the active concepts without an active long-form primary video.
    gap_ids = {g.concept_id for g in longform.coverage_gaps}
    assert gap_ids <= active
    assert not gap_ids & {c.concept_id for c in longform.items}


async def test_no_material_states(session):
    c = f.concept("Pythagorean Theorem", pool=True)
    pool_short = f.video("pool1", short=True, pool=True)
    longv = f.video("long1")
    session.add_all([c, pool_short, longv])
    await session.flush()
    session.add_all([f.tag(pool_short, c), f.tag(longv, c)])
    await session.commit()

    lf = await feed.longform_feed(session)
    assert lf.items == [] and lf.empty_state == "upload_material"  # no fallback, ever
    sh = await feed.shorts_feed(session)
    assert [x.video_id for x in sh.items] == [pool_short.id]
    assert sh.items[0].reason_label == "Math theorem: Pythagorean Theorem"


async def test_archive_reverts_longform_and_gap_cards(session):
    a, b = f.concept("A"), f.concept("B")
    m = f.material()
    va = f.video("va")
    session.add_all([a, b, m, va])
    await session.flush()
    session.add_all([f.mc(m, a, 0.9), f.mc(m, b, 0.5), f.tag(va, a)])
    await session.commit()
    await recompute_user_active_concepts(session)

    lf = await feed.longform_feed(session)
    assert [x.video_id for x in lf.items] == [va.id]
    assert [g.concept for g in lf.coverage_gaps] == ["B"]

    m.status = "archived"
    await session.commit()
    await recompute_user_active_concepts(session)
    lf = await feed.longform_feed(session)
    assert lf.items == [] and lf.empty_state == "upload_material"


async def test_longform_cap_three_per_concept(session):
    a, b = f.concept("A"), f.concept("B")
    m = f.material()
    session.add_all([a, b, m])
    await session.flush()
    session.add_all([f.mc(m, a, 1.0), f.mc(m, b, 0.2)])
    vids = [f.video(f"a{i}") for i in range(5)] + [f.video("b0")]
    session.add_all(vids)
    await session.flush()
    session.add_all([f.tag(v, a) for v in vids[:5]] + [f.tag(vids[5], b)])
    await session.commit()
    await recompute_user_active_concepts(session)

    items = (await feed.longform_feed(session, limit=4)).items
    assert [x.concept_name for x in items].count("A") == 3
    assert "B" in [x.concept_name for x in items]


def test_interleave_ratio_and_no_back_to_back():
    import uuid
    from types import SimpleNamespace

    def rows(n, concepts, mat):
        return [feed._Row(SimpleNamespace(id=uuid.uuid4()), concepts[i % len(concepts)], "x", 0, None, mat)
                for i in range(n)]

    cs = [uuid.uuid4() for _ in range(4)]
    out = feed.interleave(rows(40, cs, True), rows(40, cs, False), 0.65)
    head = out[:20]
    assert 12 <= sum(r.from_material for r in head) <= 14
    assert all(x.concept_id != y.concept_id for x, y in zip(out[:40], out[1:40]))
