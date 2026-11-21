"""Runtime settings. Personal-use app: no auth, no telemetry."""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="TF_", extra="ignore")

    database_url: str = "postgresql+asyncpg://theoremfeed:theoremfeed@localhost:5432/theoremfeed"
    # Sync URL used by Alembic.
    database_url_sync: str = "postgresql+psycopg2://theoremfeed:theoremfeed@localhost:5432/theoremfeed"

    # Empty = run the yt_dlp module with this interpreter (always matches the installed package).
    ytdlp_bin: str = ""
    resolve_timeout_sec: int = 20
    resolve_cache_hours: int = 6
    resolve_retry_after_sec: int = 30

    embedding_dim: int = 384


@lru_cache
def get_settings() -> Settings:
    return Settings()
