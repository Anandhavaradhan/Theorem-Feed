"""initial schema

Revision ID: 0001
Revises: 
Create Date: 2026-11-21
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
import pgvector.sqlalchemy
from sqlalchemy.dialects import postgresql

revision: str = '0001'
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")
    op.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    op.create_table('concepts',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('canonical_name', sa.Text(), nullable=False),
    sa.Column('aliases', sa.ARRAY(sa.Text()), nullable=False),
    sa.Column('type', sa.Text(), nullable=False),
    sa.Column('subject', sa.Text(), nullable=False),
    sa.Column('description', sa.Text(), nullable=False),
    sa.Column('embedding', pgvector.sqlalchemy.vector.VECTOR(dim=384), nullable=True),
    sa.Column('in_theorem_pool', sa.Boolean(), nullable=False),
    sa.CheckConstraint("subject IN ('math', 'physics', 'cs')", name='ck_concepts_subject'),
    sa.CheckConstraint("type IN ('theorem', 'definition', 'formula', 'technique', 'concept')", name='ck_concepts_type'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('canonical_name')
    )
    op.create_table('materials',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('title', sa.Text(), nullable=False),
    sa.Column('file_hash', sa.Text(), nullable=False),
    sa.Column('page_count', sa.Integer(), nullable=False),
    sa.Column('status', sa.Text(), nullable=False),
    sa.Column('exam_date', sa.Date(), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.CheckConstraint("status IN ('active', 'archived', 'deleted')", name='ck_materials_status'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('file_hash')
    )
    op.create_table('search_cache',
    sa.Column('query_hash', sa.Text(), nullable=False),
    sa.Column('query_text', sa.Text(), nullable=False),
    sa.Column('results', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
    sa.PrimaryKeyConstraint('query_hash')
    )
    op.create_table('videos',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('source', sa.Text(), nullable=False),
    sa.Column('source_id', sa.Text(), nullable=False),
    sa.Column('title', sa.Text(), nullable=False),
    sa.Column('description', sa.Text(), nullable=False),
    sa.Column('transcript', sa.Text(), nullable=False),
    sa.Column('duration_sec', sa.Integer(), nullable=True),
    sa.Column('thumbnail_url', sa.Text(), nullable=True),
    sa.Column('is_short', sa.Boolean(), nullable=False),
    sa.Column('is_theorem', sa.Boolean(), nullable=False),
    sa.Column('subject', sa.Text(), nullable=True),
    sa.Column('in_theorem_pool', sa.Boolean(), nullable=False),
    sa.Column('embedding', pgvector.sqlalchemy.vector.VECTOR(dim=384), nullable=True),
    sa.Column('status', sa.Text(), nullable=False),
    sa.Column('tsv', postgresql.TSVECTOR(), sa.Computed("to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, ''))", persisted=True), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.CheckConstraint("source IN ('youtube', 'local', 'manim')", name='ck_videos_source'),
    sa.CheckConstraint("status IN ('active', 'rejected_edu', 'rejected_lang', 'rejected_safety')", name='ck_videos_status'),
    sa.CheckConstraint("subject IS NULL OR subject IN ('math', 'physics', 'cs')", name='ck_videos_subject'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('source_id')
    )
    op.create_table('concept_edges',
    sa.Column('from_concept', sa.UUID(), nullable=False),
    sa.Column('to_concept', sa.UUID(), nullable=False),
    sa.Column('relation', sa.Text(), nullable=False),
    sa.Column('weight', sa.Float(), nullable=False),
    sa.CheckConstraint("relation IN ('requires', 'related', 'generalizes')", name='ck_edges_relation'),
    sa.ForeignKeyConstraint(['from_concept'], ['concepts.id'], ),
    sa.ForeignKeyConstraint(['to_concept'], ['concepts.id'], ),
    sa.PrimaryKeyConstraint('from_concept', 'to_concept', 'relation')
    )
    op.create_table('material_concepts',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('material_id', sa.UUID(), nullable=False),
    sa.Column('concept_id', sa.UUID(), nullable=False),
    sa.Column('statement', sa.Text(), nullable=False),
    sa.Column('latex', sa.Text(), nullable=True),
    sa.Column('chapter', sa.Text(), nullable=True),
    sa.Column('section', sa.Text(), nullable=True),
    sa.Column('difficulty', sa.Text(), nullable=False),
    sa.Column('importance', sa.Float(), nullable=False),
    sa.Column('prerequisites_mentioned', sa.ARRAY(sa.UUID()), nullable=False),
    sa.CheckConstraint("difficulty IN ('highschool', 'undergrad', 'advanced')", name='ck_mc_difficulty'),
    sa.CheckConstraint('importance >= 0 AND importance <= 1', name='ck_mc_importance'),
    sa.ForeignKeyConstraint(['concept_id'], ['concepts.id'], ),
    sa.ForeignKeyConstraint(['material_id'], ['materials.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_material_concepts_material_id'), 'material_concepts', ['material_id'], unique=False)
    op.create_table('relevance_scores',
    sa.Column('video_id', sa.UUID(), nullable=False),
    sa.Column('concept_id', sa.UUID(), nullable=False),
    sa.Column('topic_fit', sa.Float(), nullable=False),
    sa.Column('level_fit', sa.Float(), nullable=False),
    sa.Column('depth_fit', sa.Float(), nullable=False),
    sa.Column('prerequisite_ok', sa.Float(), nullable=False),
    sa.Column('final', sa.Float(), nullable=False),
    sa.Column('reason', sa.Text(), nullable=False),
    sa.Column('judged_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['concept_id'], ['concepts.id'], ),
    sa.ForeignKeyConstraint(['video_id'], ['videos.id'], ),
    sa.PrimaryKeyConstraint('video_id', 'concept_id')
    )
    op.create_table('user_active_concepts',
    sa.Column('concept_id', sa.UUID(), nullable=False),
    sa.Column('priority', sa.Float(), nullable=False),
    sa.Column('best_statement', sa.Text(), nullable=False),
    sa.Column('best_difficulty', sa.Text(), nullable=False),
    sa.Column('source_material_ids', sa.ARRAY(sa.UUID()), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['concept_id'], ['concepts.id'], ),
    sa.PrimaryKeyConstraint('concept_id')
    )
    op.create_table('video_concepts',
    sa.Column('video_id', sa.UUID(), nullable=False),
    sa.Column('concept_id', sa.UUID(), nullable=False),
    sa.Column('confidence', sa.Float(), nullable=False),
    sa.Column('is_primary', sa.Boolean(), nullable=False),
    sa.ForeignKeyConstraint(['concept_id'], ['concepts.id'], ),
    sa.ForeignKeyConstraint(['video_id'], ['videos.id'], ),
    sa.PrimaryKeyConstraint('video_id', 'concept_id')
    )
    op.create_table('video_resolutions',
    sa.Column('video_id', sa.UUID(), nullable=False),
    sa.Column('payload', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('resolved_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
    sa.ForeignKeyConstraint(['video_id'], ['videos.id'], ),
    sa.PrimaryKeyConstraint('video_id')
    )
    op.create_table('watch_history',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('video_id', sa.UUID(), nullable=False),
    sa.Column('watched_sec', sa.Integer(), nullable=False),
    sa.Column('completed', sa.Boolean(), nullable=False),
    sa.Column('rewatched_count', sa.Integer(), nullable=False),
    sa.Column('saved', sa.Boolean(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['video_id'], ['videos.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_watch_history_video_id'), 'watch_history', ['video_id'], unique=False)

    # --- §5 indexes -------------------------------------------------------
    op.execute("CREATE INDEX ix_videos_embedding_hnsw ON videos USING hnsw (embedding vector_cosine_ops)")
    op.execute("CREATE INDEX ix_concepts_embedding_hnsw ON concepts USING hnsw (embedding vector_cosine_ops)")
    op.execute("CREATE INDEX ix_videos_tsv_gin ON videos USING gin (tsv)")
    op.create_index("ix_video_concepts_concept_id", "video_concepts", ["concept_id"])
    op.execute("CREATE INDEX ix_concepts_name_trgm ON concepts USING gin (canonical_name gin_trgm_ops)")
    # Arrays can't take gin_trgm_ops directly; index the space-joined text.
    # array_to_string is STABLE, so wrap it in an IMMUTABLE helper.
    op.execute(
        """
        CREATE FUNCTION tf_aliases_text(text[]) RETURNS text
        LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT array_to_string($1, ' ') $$
        """
    )
    op.execute("CREATE INDEX ix_concepts_aliases_trgm ON concepts USING gin (tf_aliases_text(aliases) gin_trgm_ops)")
    # Feed predicates (§10) hit these constantly.
    op.execute("CREATE INDEX ix_videos_feed ON videos (status, is_short, in_theorem_pool)")


def downgrade() -> None:
    # Dev-only. Production data is never dropped (soft-delete rule applies to rows).
    for ix in ("ix_videos_feed", "ix_concepts_aliases_trgm", "ix_concepts_name_trgm",
               "ix_videos_tsv_gin", "ix_concepts_embedding_hnsw", "ix_videos_embedding_hnsw"):
        op.execute(f"DROP INDEX IF EXISTS {ix}")
    op.execute("DROP FUNCTION IF EXISTS tf_aliases_text(text[])")
    op.drop_index("ix_video_concepts_concept_id", table_name="video_concepts")
    op.drop_index(op.f('ix_watch_history_video_id'), table_name='watch_history')
    op.drop_table('watch_history')
    op.drop_table('video_resolutions')
    op.drop_table('video_concepts')
    op.drop_table('user_active_concepts')
    op.drop_table('relevance_scores')
    op.drop_index(op.f('ix_material_concepts_material_id'), table_name='material_concepts')
    op.drop_table('material_concepts')
    op.drop_table('concept_edges')
    op.drop_table('videos')
    op.drop_table('search_cache')
    op.drop_table('materials')
    op.drop_table('concepts')
