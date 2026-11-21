"""Test harness: a dedicated Postgres DB migrated with the real Alembic migration.

Set TF_TEST_DATABASE_URL / TF_TEST_DATABASE_URL_SYNC to point elsewhere.
"""
import os
import subprocess
import sys
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

BACKEND = Path(__file__).resolve().parents[1]
TEST_URL = os.environ.get(
    "TF_TEST_DATABASE_URL", "postgresql+asyncpg://theoremfeed:theoremfeed@localhost:5432/theoremfeed_test"
)
TEST_URL_SYNC = os.environ.get(
    "TF_TEST_DATABASE_URL_SYNC", "postgresql+psycopg2://theoremfeed:theoremfeed@localhost:5432/theoremfeed_test"
)
TABLES = (
    "search_cache, relevance_scores, video_resolutions, watch_history, user_active_concepts, "
    "material_concepts, materials, video_concepts, concept_edges, concepts, videos"
)


@pytest.fixture(scope="session", autouse=True)
def _migrate():
    alembic = [sys.executable, "-m", "alembic", "-x", f"dburl={TEST_URL_SYNC}"]
    subprocess.run([*alembic, "downgrade", "base"], cwd=BACKEND, check=True, capture_output=True)
    subprocess.run([*alembic, "upgrade", "head"], cwd=BACKEND, check=True, capture_output=True)


@pytest.fixture(scope="session")
def engine(_migrate):
    return create_async_engine(TEST_URL)


@pytest.fixture
async def session(engine):
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as conn:
        await conn.execute(text(f"TRUNCATE {TABLES} CASCADE"))
    async with maker() as s:
        yield s


@pytest.fixture
async def client(engine, session):
    from app.db import get_session
    from app.main import app

    maker = async_sessionmaker(engine, expire_on_commit=False)

    async def _override():
        async with maker() as s:
            yield s

    app.dependency_overrides[get_session] = _override
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()
