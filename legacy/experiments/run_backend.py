#!/usr/bin/env python3
"""Run the actual backend with a separate local SQLite bench DB and live Sarvam STT."""
import asyncio
import os
from pathlib import Path
import sys

import uvicorn

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "backend"))
folder = root / "new testing" / "recordings" / "live_backend"
folder.mkdir(parents=True, exist_ok=True)
os.environ["KEEPSAKE_DATABASE_URL"] = f"sqlite+aiosqlite:///{folder / 'bench.db'}"
os.environ["KEEPSAKE_STT_PROVIDER"] = "sarvam"
os.environ["KEEPSAKE_SARVAM_STT_MODEL"] = "saaras:v4"
os.environ["KEEPSAKE_LLM_PROVIDER"] = "mock"
os.environ["KEEPSAKE_API_TOKEN"] = "dev-token-change-me"
os.environ["KEEPSAKE_AUDIO_RETENTION"] = "false"
key = os.environ.get("SARVAM_API_KEY") or os.environ.get("KEEPSAKE_SARVAM_API_KEY")
if not key:
    raise SystemExit("Export SARVAM_API_KEY first")
os.environ["KEEPSAKE_SARVAM_API_KEY"] = key

from app.db import Base, engine  # noqa: E402
from app.main import app  # noqa: E402


async def main():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    await uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=8100)).serve()


if __name__ == "__main__":
    asyncio.run(main())
