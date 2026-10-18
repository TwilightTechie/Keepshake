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
export KEEPSAKE_SARVAM_API_KEY="$SARVAM_API_KEY"   # your existing exported key
docker compose up -d
.venv/bin/python tools/simulate_pendant.py --wav some-recording.wav
```

Saaras v4 is the default STT model, using `transcribe` mode and automatic language
detection. Native 8 kHz WAV bytes pass through unchanged: no backend upsampling.
The BLE gateway also preserves raw samples by default; `--condition-audio` opts
into the legacy high-pass filter and gain adjustment.

For a live pendant, run `.venv/bin/python tools/ble_gateway.py --device <unique-session-id>`
after starting the backend. Speak, then pause to close an utterance. The gateway
sends WAV utterances up to 25 seconds; transcripts appear under `/v1/conversations`.
Use a new device/session ID for each bench run because gateway sequence numbers
restart at 1 and ingest deduplicates by device ID plus sequence number.

See [standalone bench instructions](../new%20testing/README.md) for a local SQLite
option when Docker is unavailable.

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
