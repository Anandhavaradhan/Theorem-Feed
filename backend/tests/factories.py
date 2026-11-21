"""Tiny builders for test data."""
import uuid
from datetime import UTC, date, datetime

from app.models import Concept, Material, MaterialConcept, Video, VideoConcept


def concept(name: str, *, pool: bool = False, subject: str = "math") -> Concept:
    return Concept(id=uuid.uuid4(), canonical_name=name, aliases=[], type="theorem", subject=subject,
                   description=name, in_theorem_pool=pool)


def video(src: str, *, short: bool = False, pool: bool = False, status: str = "active",
          subject: str = "math") -> Video:
    return Video(id=uuid.uuid4(), source="youtube", source_id=src, title=f"Video {src}", description="",
                 transcript="", duration_sec=60 if short else 900, is_short=short, is_theorem=pool,
                 subject=subject, in_theorem_pool=pool, status=status)


def tag(v: Video, c: Concept, primary: bool = True) -> VideoConcept:
    return VideoConcept(video_id=v.id, concept_id=c.id, confidence=1.0, is_primary=primary)


def material(title: str = "Notes", *, status: str = "active", exam: date | None = None,
             created: datetime | None = None) -> Material:
    return Material(id=uuid.uuid4(), title=title, file_hash=uuid.uuid4().hex, page_count=10, status=status,
                    exam_date=exam, created_at=created or datetime.now(UTC))


def mc(m: Material, c: Concept, importance: float = 0.8, statement: str = "stmt",
       difficulty: str = "undergrad") -> MaterialConcept:
    return MaterialConcept(id=uuid.uuid4(), material_id=m.id, concept_id=c.id, statement=statement,
                           difficulty=difficulty, importance=importance, prerequisites_mentioned=[])
