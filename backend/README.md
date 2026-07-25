# Keepsake Backend

Self-hostable backend for the Keepsake pendant: ingest → STT → Memory WAL → query API.
Plan and architecture: [../docs/backend-plan.md](../docs/backend-plan.md).

## Run (self-host, one command)

```bash
KEEPSAKE_API_TOKEN=$(openssl rand -hex 32) docker compose up --build
```

- API: http://localhost:8100 — OpenAPI docs at `/docs` (host port via `KEEPSAKE_API_PORT`, default 8100; 8000 is taken by AadeshAI on this machine)
- Health: `GET /healthz` (no auth) — everything under `/v1/*` needs `Authorization: Bearer <token>`
- Migrations run automatically on container start.

## Try the whole pipeline (no hardware, no keys)

```bash
.venv/bin/python tools/simulate_pendant.py --script demo
# then: curl -H "Authorization: Bearer dev-token-change-me" \
#   localhost:8100/v1/conversations   (also /v1/wal, /v1/review, /v1/tasks, /v1/ask)
```

The simulator replays a scripted transcript into the ingest WebSocket as sequenced
frames; the pipeline transcribes (mock STT), segments, extracts WAL entries, and
derives tasks within a few seconds.

## Go live with Sarvam (STT + LLM, one key)

```bash
export KEEPSAKE_STT_PROVIDER=sarvam KEEPSAKE_LLM_PROVIDER=sarvam
export KEEPSAKE_SARVAM_API_KEY=sk_...   # from dashboard.sarvam.ai
docker compose up -d
.venv/bin/python tools/simulate_pendant.py --wav some-recording.wav
```

> Note (2026-07-23): the key found in AadeshAI/Sarvam_Project `.env` files returns
> `invalid_api_key_error` — it appears rotated/expired. Generate a fresh one.

## Develop

```bash
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/pytest            # unit tests (no Docker needed)
.venv/bin/ruff check .      # lint
docker compose up db -d     # just Postgres
KEEPSAKE_DATABASE_URL=postgresql+asyncpg://keepsake:keepsake@localhost:5432/keepsake \
  .venv/bin/alembic upgrade head
.venv/bin/uvicorn app.main:app --reload
```

## Layout

```
app/main.py        FastAPI app: /healthz + /v1 router (bearer-token gated)
app/config.py      pydantic-settings (KEEPSAKE_* env vars, .env supported)
app/db.py          async SQLAlchemy engine/session
app/models.py      devices, audio_segments (grows per backend-plan.md §5)
app/api/v1/        versioned API routers (ingest, conversations, wal… land in B1+)
migrations/        Alembic
tools/             pendant simulator etc. (B1)
```
