# Backend Plan — Processing Split, API Flow, and Implementation Phases

**Status:** v1.2 — B0–B6 all implemented and verified E2E (2026-07-23): simulator → ingest → pipeline → app screens live against the server (hydration, convo detail, review triage write-back, typed Ask). App falls back to mock fixtures when the server is unreachable. Sarvam providers implemented, awaiting a fresh API key (the one in AadeshAI/Sarvam_Project `.env` is invalid). Remaining: daily-digest freeze job, golden-transcript eval set, real-pendant Opus decode.
**Date:** 2026-07-23
**Related:** [requirements.md](requirements.md) · [requirements/app.md](requirements/app.md) · [requirements/firmware.md](requirements/firmware.md) · [app-rn-implementation.md](app-rn-implementation.md)

---

## 1. Who does what — the three-tier split

The system is a relay: **pendant hears → phone ferries → server thinks.** Each tier does the *least* work it can get away with, for a specific physical reason.

### Pendant (edge, nRF52840 — battery is the constraint)

| Does | Why here and not elsewhere |
|---|---|
| Mic capture (PDM 16 kHz mono) | It's the microphone. |
| **VAD** (voice-activity detection, gate + 500 ms pre-roll) | Silence must die at the source — streaming or storing silence costs radio/flash, i.e., battery. This is the single most important edge decision (FW-2a). |
| **Opus encoding** (16–32 kbps) | Raw PCM is ~256 kbps; BLE and battery can't afford it. 10× compression before the radio. |
| **Write-through journal on flash** (append-only ring + sequence numbers) | The phone connection *will* drop. Zero-loss guarantee (D6) has to live on the device that heard the audio. |
| Hard mute (mic power rail off), LED state, battery telemetry | Consent and honesty surfaces (PR-1). |
| **Nothing else.** No STT, no ML inference beyond tiny VAD, no Wi-Fi. | An nRF52840 has 256 KB RAM and a coin-sized battery. Every added cycle is hours of battery lost. |

### Phone app (gateway + UX — connectivity is the constraint)

| Does | Why here and not elsewhere |
|---|---|
| **BLE central**: receives Opus frames, acks sequence numbers back to the pendant | Only the phone is physically near the pendant. |
| **Store-and-forward buffer** (persistent local queue) | The phone has internet *sometimes*. Frames are held locally until the backend confirms durability. Two ack levels: pendant→phone ack ≠ phone→backend ack (APP-3). |
| Uplink to backend: live WebSocket when online, batched catch-up after gaps | |
| **All the UX we built**: Home, Convos, Tasks, Memory (Log + Review triage), Ask, pendant sheet | |
| Read cache of transcripts/WAL for offline viewing | Reads degrade gracefully; writes queue (APP-6). |
| **No STT, no LLM, no storage of record.** | Phones throttle background apps mercilessly; battery matters here too; and your memory must outlive any single phone. The phone is a *courier and a window*, not the brain. |

### Server (self-hosted or cloud — this is the brain, and the only tier with real compute)

| Does | Why here and not elsewhere |
|---|---|
| **Ingest**: authenticated WS + batch endpoint, idempotent by (device, seq), emits durable acks | Acks flow back through the phone to advance the pendant's journal cursor. |
| **STT** via provider interface (Sarvam Saaras v3 streaming default; mock/Whisper alternates) | Real STT needs GPU-class compute or a paid API — neither exists on pendant/phone. |
| Conversation segmentation (time gaps + speaker-set changes) | |
| **WAL extraction** (LLM pass → candidates → coherence check → confidence gate) | The flagship feature (D7). High-confidence entries auto-append; low-confidence go to the Review queue the app already renders. |
| **Storage of record**: Postgres — transcripts, conversations, WAL, tasks, review queue | Durable, queryable, survives phone loss, self-hostable (PR-3). |
| **Ask/query**: plain-language question → slurp WAL into LLM context (small) / embeddings retrieval (large) → cited answer | |
| Daily digest generation; export/delete APIs (PR-4) | |

**Rule of thumb: bytes shrink at the edge, decisions happen at the server.** The pendant turns sound into small numbered packets; the phone turns flaky proximity into reliable delivery; the server turns packets into memory.

## 2. Do we need an app backend? Yes — and it's *the* backend

There is no separate "app backend" vs "processing backend" — one server does both (BE-5: the app consumes only the public API). You can't skip it because:

1. **STT and LLM extraction** can't run on the pendant (no compute) and shouldn't run on the phone (background throttling, battery, and it would tie your memory to one device).
2. **The memory substrate must be durable and queryable** — a phone is neither, long-term.
3. **Self-hosting is a hard requirement** (PR-3) — the backend is a Docker Compose you own, not a mandatory cloud.

The mobile app is a **client**: it pushes audio up and pulls views (day summary, conversations, WAL, review queue, ask answers) down. Everything the RN app currently fakes with the mock zustand store becomes API responses; the store stays, its data source changes (that seam was designed in `app-rn-implementation.md` §5).

## 3. API flow

### 3.1 Live capture (happy path)

```
Pendant                    Phone app                       Server
  │ BLE notify: Opus frame    │                               │
  │  (seq=1042, ts)           │                               │
  ├──────────────────────────►│ persist to local queue        │
  │◄── ack(1042) ─────────────┤                               │
  │                           │ WS send: frame(seq=1042)      │
  │                           ├──────────────────────────────►│ append to audio log
  │                           │◄── durable_ack(seq=1042) ─────┤ (idempotent by device+seq)
  │◄─ backend-ack(1042) ──────┤   → pendant may reclaim flash │
  │                           │                               │ STT stream → transcript turns
  │                           │                               │ segmenter → conversation
  │                           │                               │ (async, ≤2 min) extraction →
  │                           │                               │   WAL entries + review queue
  │                           │ GET /days/today (poll/refetch)│
  │                           │◄── stats, digest, tasks ──────┤
```

### 3.2 Offline catch-up

```
Pendant offline 3h → journal grows (seq 2000..5400)
Phone reconnects BLE → pendant resumes from last ack (2000)
  live frames take priority; backlog trickles behind (FW-4.4)
Phone regains internet → POST /ingest/batch (gzipped frame runs)
  server acks ranges → phone advances → pendant journal reclaims
Server reassembles by (seq, RTC timestamp) → same STT→WAL path
```

### 3.3 Review triage (what Accept/Reject in the app actually does)

```
App: GET /review?status=pending          → cards (the 4 we mock today)
User taps Accept →
App: POST /review/{id}/resolve {verdict: accepted, edits?}
Server: marks candidate resolved, appends WAL entry (provenance: confirmed),
        stores verdict as tuning signal (MEM-4)
App: refetches /wal → new entry at top, badge count drops
```

### 3.4 Ask

```
App: POST /ask {question}
Server: load WAL (+ relevant transcript spans) into LLM context →
        answer + citations [{type: wal|task|conversation, id, span}]
App: renders answer bubble + citation chips (already built)
```

## 4. API surface (v1)

REST (OpenAPI-documented), single bearer token per user in v1 (self-host, single user), JWT/multi-user later.

| Method | Path | Purpose |
|---|---|---|
| `WS` | `/ingest/live` | Opus frames up, durable acks down |
| `POST` | `/ingest/batch` | Backlog frame runs after offline gaps |
| `GET` | `/days/{date}` | Home screen: stats, digest, frozen recaps |
| `GET` | `/conversations?date=` | Convos list (+ badge counts) |
| `GET` | `/conversations/{id}` | Detail: summary, action items, entries, transcript |
| `GET` | `/tasks?filter=` | Tasks (grouped overdue/today/later) |
| `PATCH` | `/tasks/{id}` | Toggle done / edit due |
| `GET` | `/wal?type=&person=` | Memory log (append-only, supersession links) |
| `GET` | `/review?status=pending` | Review queue |
| `POST` | `/review/{id}/resolve` | Accept / edit / reject (+ tuning signal) |
| `POST` | `/ask` | Question → cited answer |
| `GET` | `/device` | Pendant status mirror (battery, backlog, last sync) |
| `PUT` | `/device/settings` | VAD sensitivity etc. (proxied to pendant over BLE by the app) |
| `GET/DELETE` | `/export`, `/data` | PR-4: full export, hard delete |

Notes:
- The app keeps rendering from its zustand store; a thin `ApiClient` fills the store instead of `data/mock.ts`. Mock stays as the offline/dev fixture.
- Device settings writes go **app → pendant over BLE** (source of truth is the device), with the server storing a mirror for display.

## 5. Data model (Postgres, v1)

```
devices(id, name, key_hash, fw_version, last_seen_at)
audio_segments(device_id, seq BIGINT, ts, opus BYTEA NULL, PRIMARY KEY(device_id, seq))
      -- opus discarded after STT unless retention opted in (PR-2)
transcript_turns(id, conversation_id, speaker_label, started_at, text, words JSONB)
conversations(id, started_at, ended_at, title, summary, participants JSONB)
wal_entries(id HEX, ts, type, headline, why, participants JSONB, confidence,
            provenance ENUM(auto,confirmed,manual), evidence JSONB, refs JSONB,
            superseded_by NULL)          -- append-only; MEM-1
review_queue(id, wal_candidate JSONB, status, verdict_at, edits JSONB)
tasks(id, title, due, person, group, done, source_conversation_id, wal_entry_id)
day_recaps(date, narrative, stats JSONB, frozen_at)
```

## 6. Proposed stack

| Layer | Choice | Rationale |
|---|---|---|
| API server | **Python 3.12 + FastAPI + uvicorn** | First-class WebSockets + OpenAPI for free (BE-5); Sarvam & Anthropic SDKs are Python-native; the extraction pipeline is LLM-tooling-heavy — Python is where that ecosystem lives |
| DB | **Postgres 16** (SQLAlchemy 2 async + Alembic migrations) | BE-4 |
| STT | `SttProvider` interface → `SarvamProvider` (Saaras v3 streaming), `MockProvider` (dev), Whisper later (D3) | |
| Extraction/Ask LLM | `LlmProvider` interface → Anthropic (default), prompt + JSON schema versioned in-repo, golden-transcript eval set (MEM-8) | |
| Deploy | **Docker Compose**: `api` + `postgres` (one command, BE-1) | |
| Dev without pendant | **`tools/simulate_pendant.py`**: replays a WAV/Opus file into `/ingest/live` as framed, sequenced packets — exercises the whole pipeline before firmware exists | Unblocks backend + app integration now; the P0 dev kit slots in later with zero server changes |

## 7. Implementation phases

Each phase is independently testable; app wiring starts as soon as B2 exists.

| Phase | Scope | Proves |
|---|---|---|
| **B0 — Skeleton** | Compose (api+postgres), migrations, auth token, `/healthz`, OpenAPI, CI | Clean-machine bring-up (PR-3) |
| **B1 — Ingest** | WS `/ingest/live` + `/ingest/batch`, idempotent seq store, durable acks, pendant simulator CLI | Zero-loss contract end-to-end with fake audio |
| **B2 — STT + conversations** | Provider interface, Mock + Sarvam providers, segmenter, `/conversations` endpoints | Real transcript from simulator WAV; app Convos tab goes live |
| **B3 — WAL extraction** | LLM extraction pass, coherence check, confidence gate, `/wal`, `/review` + resolve, tasks derived from commitments | The flagship: Review triage in the app hits real candidates |
| **B4 — Ask + digest** | `/ask` (slurp-first), `/days/{date}` recaps, day freeze job | Ask tab live with citations |
| **B5 — App integration pass** | `ApiClient` in the RN app replacing mock seeds (mock kept as fixture), pull-to-refresh, error/offline states | Whole app runs against your own server |
| **B6 — Hardening** | Export/delete (PR-4), audio-retention opt-in, docs, eval set in CI | Ship-shape self-host |

Deferred (needs hardware/native): real BLE path in the app (Expo dev build + `react-native-ble-plx`), backend-ack → journal-cursor loop on the pendant, DFU. The server contract above doesn't change when those arrive — that's the point of the simulator.

## 8. Open decisions for approval

1. **Stack**: Python/FastAPI/Postgres as above? (Alternative: Node/TS for one-language repo — but STT/LLM tooling favors Python.) → **Recommend Python.**
2. **v1 auth**: single bearer token (self-host, single user)? → **Recommend yes; JWT multi-user later.**
3. **Repo layout**: `backend/` beside `app/` in this repo (monorepo per requirements §3)? → **Recommend yes.**
4. **Phase order**: B0→B6 as listed, wiring the app early at B2? → **Recommend yes.**
