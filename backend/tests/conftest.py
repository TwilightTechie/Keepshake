import httpx
import pytest
from httpx import ASGITransport
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.config import get_settings
from app.db import Base, get_session
from app.main import app

AUTH = {"Authorization": "Bearer dev-token-change-me"}


@pytest.fixture
async def db_session_factory():
    engine = create_async_engine("sqlite+aiosqlite://")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


@pytest.fixture
async def session(db_session_factory):
    async with db_session_factory() as s:
        yield s


@pytest.fixture
async def client(db_session_factory, monkeypatch):
    get_settings.cache_clear()

    async def override_session():
        async with db_session_factory() as s:
            yield s

    app.dependency_overrides[get_session] = override_session
    async with httpx.AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test", headers=AUTH
    ) as c:
        yield c
    app.dependency_overrides.clear()
    get_settings.cache_clear()
