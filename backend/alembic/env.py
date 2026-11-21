from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from app.config import get_settings
from app.models import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Allow `-x dburl=...` override (used by tests), else settings.
db_url = context.get_x_argument(as_dictionary=True).get("dburl") or get_settings().database_url_sync
config.set_main_option("sqlalchemy.url", db_url)
target_metadata = Base.metadata

# Indexes written by hand in migrations (HNSW / GIN / trigram / functional).
# Autogenerate can't express them faithfully, so it must never try to drop them.
HAND_MANAGED_INDEXES = {
    "ix_videos_embedding_hnsw",
    "ix_concepts_embedding_hnsw",
    "ix_videos_tsv_gin",
    "ix_video_concepts_concept_id",
    "ix_concepts_name_trgm",
    "ix_concepts_aliases_trgm",
    "ix_videos_feed",
}


def include_object(obj, name, type_, reflected, compare_to):
    return not (type_ == "index" and name in HAND_MANAGED_INDEXES)


def run_migrations_offline() -> None:
    context.configure(
        url=db_url, target_metadata=target_metadata, literal_binds=True, include_object=include_object
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(
            connection=connection, target_metadata=target_metadata, include_object=include_object
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
