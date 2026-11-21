"""ORM models — mirrors §5 of the master prompt exactly.

Soft-delete only: nothing here is ever removed with DELETE; status columns
carry lifecycle state.
"""
import uuid
from datetime import date, datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import (
    ARRAY,
    Boolean,
    CheckConstraint,
    Computed,
    Date,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    Text,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, TSVECTOR, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

EMBED_DIM = 384  # all-MiniLM-L6-v2, English only


class Base(DeclarativeBase):
    pass


def _uuid_pk() -> Mapped[uuid.UUID]:
    return mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)


def _created_at() -> Mapped[datetime]:
    return mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


VIDEO_STATUSES = ("active", "rejected_edu", "rejected_lang", "rejected_safety")
MATERIAL_STATUSES = ("active", "archived", "deleted")
CONCEPT_TYPES = ("theorem", "definition", "formula", "technique", "concept")
SUBJECTS = ("math", "physics", "cs")
DIFFICULTIES = ("highschool", "undergrad", "advanced")
EDGE_RELATIONS = ("requires", "related", "generalizes")


def _in(col: str, values: tuple[str, ...]) -> str:
    return f"{col} IN ({', '.join(repr(v) for v in values)})"


class Video(Base):
    __tablename__ = "videos"
    __table_args__ = (
        CheckConstraint(_in("source", ("youtube", "local", "manim")), name="ck_videos_source"),
        CheckConstraint(_in("status", VIDEO_STATUSES), name="ck_videos_status"),
        CheckConstraint(f"subject IS NULL OR {_in('subject', SUBJECTS)}", name="ck_videos_subject"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    source: Mapped[str] = mapped_column(Text, nullable=False)
    source_id: Mapped[str] = mapped_column(Text, nullable=False, unique=True)
    title: Mapped[str] = mapped_column(Text, nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False, default="")
    transcript: Mapped[str] = mapped_column(Text, nullable=False, default="")
    duration_sec: Mapped[int | None] = mapped_column(Integer)
    thumbnail_url: Mapped[str | None] = mapped_column(Text)
    is_short: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_theorem: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    subject: Mapped[str | None] = mapped_column(Text)
    in_theorem_pool: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # title + description + first 2000 chars of transcript
    embedding: Mapped[list[float] | None] = mapped_column(Vector(EMBED_DIM))
    status: Mapped[str] = mapped_column(Text, nullable=False, default="active")
    tsv = mapped_column(
        TSVECTOR,
        Computed(
            "to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, ''))",
            persisted=True,
        ),
    )
    created_at: Mapped[datetime] = _created_at()

    concepts: Mapped[list["VideoConcept"]] = relationship(back_populates="video", lazy="selectin")


class Concept(Base):
    __tablename__ = "concepts"
    __table_args__ = (
        CheckConstraint(_in("type", CONCEPT_TYPES), name="ck_concepts_type"),
        CheckConstraint(_in("subject", SUBJECTS), name="ck_concepts_subject"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    canonical_name: Mapped[str] = mapped_column(Text, nullable=False, unique=True)
    aliases: Mapped[list[str]] = mapped_column(ARRAY(Text), nullable=False, default=list)
    type: Mapped[str] = mapped_column(Text, nullable=False)
    subject: Mapped[str] = mapped_column(Text, nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False, default="")
    embedding: Mapped[list[float] | None] = mapped_column(Vector(EMBED_DIM))
    in_theorem_pool: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)


class ConceptEdge(Base):
    __tablename__ = "concept_edges"
    __table_args__ = (CheckConstraint(_in("relation", EDGE_RELATIONS), name="ck_edges_relation"),)

    from_concept: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("concepts.id"), primary_key=True
    )
    to_concept: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("concepts.id"), primary_key=True
    )
    relation: Mapped[str] = mapped_column(Text, primary_key=True)
    weight: Mapped[float] = mapped_column(Float, nullable=False, default=1.0)


class VideoConcept(Base):
    __tablename__ = "video_concepts"

    video_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("videos.id"), primary_key=True
    )
    concept_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("concepts.id"), primary_key=True
    )
    confidence: Mapped[float] = mapped_column(Float, nullable=False, default=1.0)
    is_primary: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    video: Mapped[Video] = relationship(back_populates="concepts")
    concept: Mapped[Concept] = relationship(lazy="joined")


class Material(Base):
    __tablename__ = "materials"
    __table_args__ = (CheckConstraint(_in("status", MATERIAL_STATUSES), name="ck_materials_status"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    title: Mapped[str] = mapped_column(Text, nullable=False)
    file_hash: Mapped[str] = mapped_column(Text, nullable=False, unique=True)
    page_count: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[str] = mapped_column(Text, nullable=False, default="active")
    exam_date: Mapped[date | None] = mapped_column(Date)
    created_at: Mapped[datetime] = _created_at()


class MaterialConcept(Base):
    __tablename__ = "material_concepts"
    __table_args__ = (
        CheckConstraint(_in("difficulty", DIFFICULTIES), name="ck_mc_difficulty"),
        CheckConstraint("importance >= 0 AND importance <= 1", name="ck_mc_importance"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    material_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("materials.id"), nullable=False, index=True
    )
    concept_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("concepts.id"), nullable=False
    )
    statement: Mapped[str] = mapped_column(Text, nullable=False)
    latex: Mapped[str | None] = mapped_column(Text)
    chapter: Mapped[str | None] = mapped_column(Text)
    section: Mapped[str | None] = mapped_column(Text)
    difficulty: Mapped[str] = mapped_column(Text, nullable=False)
    importance: Mapped[float] = mapped_column(Float, nullable=False)
    prerequisites_mentioned: Mapped[list[uuid.UUID]] = mapped_column(
        ARRAY(UUID(as_uuid=True)), nullable=False, default=list
    )


class UserActiveConcept(Base):
    """Derived cache: recomputed whenever material changes (§6.4)."""

    __tablename__ = "user_active_concepts"

    concept_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("concepts.id"), primary_key=True
    )
    priority: Mapped[float] = mapped_column(Float, nullable=False)
    best_statement: Mapped[str] = mapped_column(Text, nullable=False)
    best_difficulty: Mapped[str] = mapped_column(Text, nullable=False)
    source_material_ids: Mapped[list[uuid.UUID]] = mapped_column(
        ARRAY(UUID(as_uuid=True)), nullable=False, default=list
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    concept: Mapped[Concept] = relationship(lazy="joined")


class WatchHistory(Base):
    __tablename__ = "watch_history"

    id: Mapped[uuid.UUID] = _uuid_pk()
    video_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("videos.id"), nullable=False, index=True
    )
    watched_sec: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    completed: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    rewatched_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    saved: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = _created_at()


class VideoResolution(Base):
    """yt-dlp cache (§12)."""

    __tablename__ = "video_resolutions"

    video_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("videos.id"), primary_key=True
    )
    payload: Mapped[dict] = mapped_column(JSONB, nullable=False)
    resolved_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class RelevanceScore(Base):
    """Cached LLM-judge output (§9.2)."""

    __tablename__ = "relevance_scores"

    video_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("videos.id"), primary_key=True
    )
    concept_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("concepts.id"), primary_key=True
    )
    topic_fit: Mapped[float] = mapped_column(Float, nullable=False)
    level_fit: Mapped[float] = mapped_column(Float, nullable=False)
    depth_fit: Mapped[float] = mapped_column(Float, nullable=False)
    prerequisite_ok: Mapped[float] = mapped_column(Float, nullable=False)
    final: Mapped[float] = mapped_column(Float, nullable=False)
    reason: Mapped[str] = mapped_column(Text, nullable=False, default="")
    judged_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class SearchCache(Base):
    __tablename__ = "search_cache"

    query_hash: Mapped[str] = mapped_column(Text, primary_key=True)
    query_text: Mapped[str] = mapped_column(Text, nullable=False)
    results: Mapped[dict] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = _created_at()
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
