import httpx
import pytest
from httpx import ASGITransport

from app.config import get_settings
from app.main import app


@pytest.fixture
async def client(monkeypatch):
    # healthz pings the DB; point it at in-memory sqlite for unit tests
    monkeypatch.setenv("KEEPSAKE_DATABASE_URL", "sqlite+aiosqlite://")
    get_settings.cache_clear()
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    import app.db as db_mod

    engine = create_async_engine("sqlite+aiosqlite://")
    monkeypatch.setattr(db_mod, "engine", engine)
    monkeypatch.setattr(db_mod, "SessionLocal", async_sessionmaker(engine, expire_on_commit=False))
    async with httpx.AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        yield client
    await engine.dispose()
    get_settings.cache_clear()


async def test_healthz_ok(client):
    r = await client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


async def test_v1_requires_token(client):
    r = await client.get("/v1/me")
    assert r.status_code == 401


async def test_v1_wrong_token_rejected(client):
    r = await client.get("/v1/me", headers={"Authorization": "Bearer wrong"})
    assert r.status_code == 401


async def test_v1_accepts_token(client):
    token = get_settings().api_token
    r = await client.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json() == {"user": "self-hosted"}
