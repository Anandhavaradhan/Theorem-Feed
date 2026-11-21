"""Phase A walking-skeleton seed: 5 hardcoded videos.

Run:  python -m app.seed_phase_a

To stay honest to the scope rules even in Phase A, the videos are *not*
injected into the feed directly. Instead this creates one clearly-labelled
sample material whose concepts become user-active via the real recompute;
the long-form feed then shows these videos through its normal predicate.

Phase C replaces this with real PDF uploads. Archive the sample material
(POST /material/{id}/archive, Phase C) and the Home feed reverts to the
upload CTA — exactly as the lifecycle rules require.

Idempotent: re-running does not duplicate rows.
"""
from __future__ import annotations

import asyncio
import hashlib
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.models import Concept, Material, MaterialConcept, Video, VideoConcept
from app.services.active_concepts import recompute_user_active_concepts

SAMPLE_MATERIAL_TITLE = "Phase A sample material (dev seed)"
SAMPLE_MATERIAL_HASH = "phase-a-seed-" + hashlib.sha256(b"theoremfeed-phase-a").hexdigest()[:16]

# (youtube_id, title, approx duration sec, concept) — all English, educational, long-form.
SEED: list[dict] = [
    {
        "youtube_id": "WUvTyaaNkzM",
        "title": "The essence of calculus",
        "duration_sec": 1020,
        "concept": {
            "canonical_name": "Definite Integral",
            "aliases": ["integral", "area under a curve"],
            "type": "definition",
            "statement": "The definite integral ∫_a^b f(x) dx is the limit of Riemann sums: the signed area between f and the x-axis on [a, b].",
            "latex": r"\int_a^b f(x)\,dx = \lim_{n\to\infty}\sum_{i=1}^{n} f(x_i^*)\,\Delta x",
            "chapter": "1", "difficulty": "highschool", "importance": 0.9,
        },
    },
    {
        "youtube_id": "r6sGWTCMz2k",
        "title": "But what is a Fourier series? From heat flow to drawing with circles",
        "duration_sec": 1500,
        "concept": {
            "canonical_name": "Fourier Series",
            "aliases": ["fourier expansion"],
            "type": "theorem",
            "statement": "A periodic function can be written as a sum of complex exponentials c_n e^{2πinx}, with coefficients c_n = ∫_0^1 f(x) e^{-2πinx} dx.",
            "latex": r"f(x) = \sum_{n=-\infty}^{\infty} c_n e^{2\pi i n x}",
            "chapter": "4", "difficulty": "undergrad", "importance": 0.8,
        },
    },
    {
        "youtube_id": "fNk_zzaMoSs",
        "title": "Vectors | Chapter 1, Essence of linear algebra",
        "duration_sec": 600,
        "concept": {
            "canonical_name": "Vector",
            "aliases": ["vectors", "vector space element"],
            "type": "definition",
            "statement": "A vector is an element of a vector space; in R^n it is an ordered list of n numbers, added componentwise and scaled by real numbers.",
            "latex": None,
            "chapter": "2", "difficulty": "highschool", "importance": 0.7,
        },
    },
    {
        "youtube_id": "HZGCoVF3YvM",
        "title": "Bayes theorem, the geometry of changing beliefs",
        "duration_sec": 900,
        "concept": {
            "canonical_name": "Bayes' Theorem",
            "aliases": ["bayes rule", "bayes theorem"],
            "type": "theorem",
            "statement": "P(H|E) = P(E|H)·P(H) / P(E): the posterior probability of a hypothesis given evidence.",
            "latex": r"P(H\mid E) = \frac{P(E\mid H)\,P(H)}{P(E)}",
            "chapter": "3", "difficulty": "undergrad", "importance": 0.85,
        },
    },
    {
        "youtube_id": "3d6DsjIBzJ4",
        "title": "Taylor series | Chapter 11, Essence of calculus",
        "duration_sec": 1320,
        "concept": {
            "canonical_name": "Taylor Series",
            "aliases": ["taylor expansion", "taylor polynomial"],
            "type": "theorem",
            "statement": "A smooth f near a equals Σ f^(n)(a)(x−a)^n / n!, approximating f by polynomials matching its derivatives at a.",
            "latex": r"f(x) = \sum_{n=0}^{\infty} \frac{f^{(n)}(a)}{n!}(x-a)^n",
            "chapter": "1", "difficulty": "undergrad", "importance": 0.9,
        },
    },
]


async def _get_or_create_concept(session: AsyncSession, c: dict) -> Concept:
    concept = await session.scalar(select(Concept).where(Concept.canonical_name == c["canonical_name"]))
    if concept is None:
        concept = Concept(
            id=uuid.uuid4(),
            canonical_name=c["canonical_name"],
            aliases=c["aliases"],
            type=c["type"],
            subject="math",
            description=c["statement"],
            in_theorem_pool=False,
        )
        session.add(concept)
        await session.flush()
    return concept


async def seed(session: AsyncSession) -> None:
    material = await session.scalar(select(Material).where(Material.file_hash == SAMPLE_MATERIAL_HASH))
    if material is None:
        material = Material(id=uuid.uuid4(), title=SAMPLE_MATERIAL_TITLE, file_hash=SAMPLE_MATERIAL_HASH,
                            page_count=0, status="active")
        session.add(material)
        await session.flush()

    for item in SEED:
        c = item["concept"]
        concept = await _get_or_create_concept(session, c)

        mc = await session.scalar(
            select(MaterialConcept).where(
                MaterialConcept.material_id == material.id, MaterialConcept.concept_id == concept.id
            )
        )
        if mc is None:
            session.add(MaterialConcept(
                id=uuid.uuid4(), material_id=material.id, concept_id=concept.id,
                statement=c["statement"], latex=c["latex"], chapter=c["chapter"], section=None,
                difficulty=c["difficulty"], importance=c["importance"], prerequisites_mentioned=[],
            ))

        video = await session.scalar(select(Video).where(Video.source_id == item["youtube_id"]))
        if video is None:
            video = Video(
                id=uuid.uuid4(), source="youtube", source_id=item["youtube_id"], title=item["title"],
                description="", transcript="", duration_sec=item["duration_sec"],
                thumbnail_url=f"https://i.ytimg.com/vi/{item['youtube_id']}/hqdefault.jpg",
                is_short=False, is_theorem=c["type"] == "theorem", subject="math",
                in_theorem_pool=False, status="active",
            )
            session.add(video)
            await session.flush()
            session.add(VideoConcept(video_id=video.id, concept_id=concept.id, confidence=1.0, is_primary=True))

    await session.commit()
    n = await recompute_user_active_concepts(session)
    print(f"Seeded {len(SEED)} videos; {n} active concepts.")


async def main() -> None:
    async with SessionLocal() as session:
        await seed(session)


if __name__ == "__main__":
    asyncio.run(main())
