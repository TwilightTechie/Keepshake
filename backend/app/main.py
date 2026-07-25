import asyncio
import contextlib
from collections.abc import AsyncIterator

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1 import router as v1_router
from app.api.v1.ingest import router as ingest_router
from app.auth import require_token
from app.db import get_session
from app.pipeline.runner import pipeline_loop


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    worker = asyncio.create_task(pipeline_loop())
    try:
        yield
    finally:
        worker.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await worker


app = FastAPI(
    title="Keepsake Backend",
    version="0.1.0",
    description="Self-hostable Keepsake backend: ingest → STT → Memory WAL → query.",
    lifespan=lifespan,
)


# Dev CORS: the Expo web preview calls the API from another localhost origin.
# Auth stays on the bearer token; tighten origins before any multi-user deploy.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/healthz", tags=["ops"])
async def healthz(session: AsyncSession = Depends(get_session)) -> dict[str, str]:
    await session.execute(text("SELECT 1"))
    return {"status": "ok"}


# WS does its own token check (headers aren't uniform across WS clients);
# batch POST inside carries an explicit require_token dependency.
app.include_router(ingest_router, prefix="/v1")
app.include_router(v1_router, prefix="/v1", dependencies=[Depends(require_token)])
