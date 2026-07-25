# App & Platform Requirements

Part of the [requirements overview](../requirements.md). Covers the Flutter gateway app, the backend platform it depends on, and the **Memory WAL** — the feature that turns transcripts into a queryable record of decisions. (Backend requirements live here until backend work starts in earnest; split into `backend.md` then.)

---

## 1. Flutter Gateway App

- **APP-1 Role:** BLE central + user surface. Maintains the pendant connection, receives Opus frames, acks sequence numbers, forwards to backend (live WebSocket when online, store-and-forward otherwise). Background survival is the hardest problem and gets first-class treatment: Android foreground service, iOS background BLE modes, reconnect state machine with exponential backoff, OS-kill recovery.
- **APP-2 Stack:** Flutter (D4), one codebase Android + iOS. BLE via `flutter_blue_plus`-class plugin; platform channels where background behavior demands native code.
- **APP-3 Buffering:** Persistent local queue (acked-to-phone ≠ acked-to-backend — two ack levels). Nothing is lost if the backend is unreachable; "delete everything on this device" control.
- **APP-4 Information architecture (5 tabs; category table-stakes first, Memory WAL as the distinct feature):**
  1. **Home** — persistent recording/mute/disconnected status pill (consent surface, visible on every tab); narrative day summary; stat chips (conversations / captured time / entries); "Needs you" (review count, commitments due, open questions); conversation timeline; device card. Past days remain browsable as an AI-diary journal (daily recap freezes at day's end).
  2. **Conversations** — the primary object: per-conversation summary, key points, action items, participants, full transcript, and bidirectional links to WAL entries it produced.
  3. **Tasks** — commitments/action items as a checkable list: due dates, person filter, export/sync to Apple Reminders / Google Tasks / Todoist-class apps (category table-stakes).
  4. **Memory** — the WAL (distinct feature): browse/filter by type/person/topic; entry detail with the *why*, evidence link (transcript span ± audio if retained), supersession chain; the Review queue lives here (badged on Home).
  5. **Ask** — natural-language chat over conversations + tasks + WAL, answers with tappable citations.
  - Device status is a pill/card (not a tab): pairing, battery, journal backlog, VAD sensitivity, mute, DFU. Settings is a profile sheet: backend URL (self-host first-class), STT/LLM provider + language, audio retention opt-in, export/delete.
- **APP-5 Pendant status honesty:** journal backlog size, last-sync time, packet-loss stats visible; diagnostics exportable.
- **APP-6 Offline UX:** transcripts/WAL cached locally for read; queries degrade gracefully (local search when backend unreachable).

## 2. Backend Platform

- **BE-1 Deployment:** Docker Compose single-command self-host; deployable to any cloud; no hosted-only functionality.
- **BE-2 Ingest:** Authenticated WebSocket for live Opus + batch endpoint for backlog sync; idempotent by (device, sequence number); emits backend-durable acks that flow back to the pendant's journal cursor.
- **BE-3 STT:** Provider interface; **Sarvam Saaras v3 streaming default** (diarization, word timestamps, code-mixed); Deepgram + self-hosted Whisper alternates (D3).
- **BE-4 Stores:** Postgres: transcripts (speaker turns, word timestamps, conversation segmentation) + the WAL (append-only table). Object storage only if audio retention is opted in. Embeddings index for search at scale.
- **BE-5 API:** OpenAPI-documented REST + WebSocket; the Flutter app and web app consume only this public API.
- **BE-6 Web app:** Secondary surface — transcript/WAL browsing, search, device management.

## 3. Memory WAL (D7) — the flagship feature

Stoa's insight, transplanted: an append-only decision log is only sustainable when an AI absorbs the maintenance cost. Here the "operator" is your day: the pendant hears it, STT transcribes it, and an extraction pipeline maintains the WAL autonomously — you audit, you don't author.

### 3.1 Pipeline flow

```
 transcript turns (diarized, timestamped)
        │
        ▼
 ① Conversation segmenter          — groups turns into conversations (time gaps,
        │                            speaker-set changes); assigns conversation IDs
        ▼
 ② Extraction pass (LLM, pluggable provider — near-line, ≤2 min after speech ends)
        │    reads: new conversation segment + relevant recent WAL entries
        │    emits: candidate entries with type, confidence, evidence spans
        ▼
 ③ Coherence check                 — before append: does a candidate contradict or
        │                            supersede an existing entry? → link as rollback,
        │                            or merge as duplicate, or append as new
        ▼
 ④ Confidence gate
        ├── high  → auto-append to WAL (visible immediately, marked auto)
        └── low   → Review queue in app (accept/edit/reject; feedback tunes the gate)
        ▼
 ⑤ Personal WAL (append-only)      — query API, daily digest, export
```

### 3.2 Entry model (adapted from Stoa's 8 types to a personal context)

| Type | Meaning | Example from speech |
|---|---|---|
| `decision` | You settled something | "let's go with the 1100 mAh battery" |
| `commitment` | You promised someone something, or they promised you | "I'll send the report by Friday" |
| `fact` | Durable info worth keeping | "Ramesh's new office is in Indiranagar" |
| `question` | Something left open | "need to check if the switch handles 0.5 A" |
| `rollback` | Supersedes an earlier entry | "actually, scrap Friday — Monday" |

Every entry carries: ISO timestamp, random hex ID (stable reference), type, one-line headline, **why** (the reasoning captured from surrounding speech — the part every notetaker app throws away), participants (from diarization; "me" vs named/unknown others), confidence, provenance (`auto` / `confirmed` / `manual`), and **evidence refs** — conversation ID + transcript span, so every entry is one tap from what was actually said. Entries are never edited; corrections are `rollback` entries. `Refs:` cross-link related entries.

### 3.3 Requirements

- **MEM-1 Append-only:** No entry is ever mutated or deleted by the pipeline; supersession via `rollback` only. (User-initiated privacy deletion — PR-4 — is the one exception, implemented as hard delete of entry + evidence, and logged as a deletion marker.)
- **MEM-2 Evidence chain:** Every auto entry must reference the transcript span it came from. No unexplainable memories.
- **MEM-3 Extraction discipline:** Default is NOT to log (Stoa's yardstick, inherited). Small talk produces nothing. Precision beats recall at launch: a WAL you trust with 60 % recall is a feature; one that's 95 % recall / 70 % precision is noise.
- **MEM-4 Review loop:** Low-confidence candidates go to the app's Review queue; accept/edit/reject outcomes are stored as tuning signal. Explicit voice logging ("pendant, note this") is a high-priority capture cue.
- **MEM-5 Query:** Plain-language ask over the WAL. Small WAL: load whole log into LLM context (slurp-first, Stoa's pattern). Large WAL: embeddings retrieval fallback. Answers cite entry IDs.
- **MEM-6 Digest:** End-of-day synthesis: decisions made, commitments given/received (with due dates), open questions. Push notification optional.
- **MEM-7 Third-party respect (PR-6):** Entries whose subject is another person's statement are flagged `about:other` and excluded from any future sharing/export-to-team surface by default.
- **MEM-8 Provider abstraction:** Extraction LLM is pluggable like STT (Anthropic/OpenAI-compatible/self-hosted); prompt + schema versioned in-repo; a golden-transcript eval set gates prompt/model changes in CI.
- **MEM-9 Portability:** WAL exportable as markdown (human-readable, Stoa-style) and JSON (machine-readable), one command/API call.

### 3.4 Explicitly out of scope for v1

Multi-user/shared WALs, git-repo integration (the "full Stoa" mode), real-time extraction (< seconds), on-phone extraction, and automatic task-manager sync (export hooks exist via API; native integrations are P3).
