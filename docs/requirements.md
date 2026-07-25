# AI Pendant — Requirements Overview

**Status:** v0.3 — split into per-domain docs; Memory WAL feature added
**Date:** 2026-07-23
**License intent:** Fully open source — firmware, backend, apps, and hardware. (D5 pending: recommended Apache-2.0 software / CERN-OHL-S hardware.)

This is the umbrella document: vision, market context, system architecture, cross-cutting requirements, and the decision log. Domain requirements live in:

| Doc | Scope |
|---|---|
| [requirements/hardware.md](requirements/hardware.md) | Pendant electronics, mechanical, P0 dev-kit, Phase-2 custom board |
| [requirements/firmware.md](requirements/firmware.md) | Zephyr firmware: audio pipeline, VAD, journal/sync, BLE, DFU, power |
| [requirements/app.md](requirements/app.md) | Flutter gateway app, backend platform, STT, and the Memory WAL |

---

## 1. Vision

A wearable pendant that captures speech (VAD-gated), transcribes it in near real time, and distills it into a **personal memory substrate**: not just transcripts, but an append-only log of the decisions you made, commitments you gave, and facts worth keeping — queryable in plain language ("what did I agree with Ramesh about the deadline, and why?"). It must be:

- **Buildable by anyone.** Order the parts, flash the firmware, deploy or point at a backend, use it the same day.
- **Engineered, not hacked.** Measured power budgets, defined latency budgets, versioned protocols, CI, tests, signed DFU. No workarounds baked into the design.
- **Private by architecture.** Self-hostable end to end; pluggable cloud providers (STT, LLM), never mandatory; transcribe-and-discard as the default audio policy.

### Non-goals (v1)

- On-device STT/LLM inference on the pendant MCU.
- Camera, display, or speaker output on the pendant.
- Cellular/Wi-Fi on the pendant (phone is the gateway).
- Real-time voice-assistant conversation loop (capture → transcribe → distill first; assistant features layer on later).

## 2. Market Landscape

| Product | Status (2026) | What they got right | Gaps we exploit |
|---|---|---|---|
| **Omi** (BasedHardware) | Active, open source (MIT) | Fully open HW+FW+SW; the de-facto open reference (nRF + Zephyr + Opus over BLE) | Build quality, rough UX, plugin-marketplace privacy questions |
| **Limitless** | Acquired by Meta Dec 2025; sales stopped | Best polish in category | The canonical lock-in cautionary tale; validates open source |
| **Bee** (Amazon) | Active | Transcribe-and-discard privacy default | Closed; Amazon trust problem |
| **Plaud NotePin** | Active | Recorder ergonomics | Closed; recorder-first, no memory layer |
| **Humane AI Pin** | Dead | — | Proof that standalone-everything wearables fail; validates phone-as-gateway |

**Our differentiation:** engineering rigor over feature count; first-class Indic/code-mixed STT (Sarvam); self-host-first backend; and the **Memory WAL** — every incumbent stops at transcripts + summaries, none maintains a queryable, supersedable record of *what you decided and why*.

## 3. System Architecture

```
┌──────────┐  BLE (Opus frames,     ┌─────────────┐  WebSocket/HTTPS   ┌───────────────────────────┐
│ Pendant  │  versioned GATT)      │ Flutter app  │  (live stream +    │ Backend (self-host/cloud) │
│ nRF MCU  ├──────────────────────►│ (gateway +   ├───────────────────►│ ingest → STT (Sarvam) →   │
│ PDM mic  │  ◄── DFU, config      │  UX)         │  backlog sync      │ transcript store →        │
└──────────┘                        └─────────────┘                    │ WAL extraction (LLM) →    │
     │ offline: write-through journal on flash                         │ personal WAL → query API  │
     └── syncs delta on reconnect (journal cursor + acks)              └───────────────────────────┘
```

Monorepo: `firmware/`, `app/`, `backend/`, `hardware/`, `docs/`.

## 4. Privacy & Consent (hard requirements, all domains)

- **PR-1** Visible recording indicator on the pendant (hardwired on the custom board) + one-gesture hard mute that disables the mic path, not just the gate.
- **PR-2** Default audio policy is transcribe-and-discard; raw-audio retention is opt-in.
- **PR-3** Self-hosting is a first-class, documented, CI-tested path.
- **PR-4** All data — transcripts and WAL — exportable and deletable via API; no telemetry without opt-in.
- **PR-5** Docs include a jurisdiction-aware note on recording-consent laws.
- **PR-6** WAL entries about third parties (things *others* said) are marked as such and excluded from any future sharing surface by default.

## 5. Non-Functional Requirements (system-level)

| Metric | Target |
|---|---|
| Mic → live transcript in app (online) | ≤ 1.5 s end-to-end; ≤ 100 ms firmware share |
| Speech end → WAL entry available | ≤ 2 min (extraction is near-line, not real-time) |
| Battery, VAD-gated day (~30 % speech) | ≥ 48 h |
| Battery, worst case continuous | ≥ 24 h |
| Offline capture capacity | ≥ 8 h (product); ~1 h accepted on P0 dev kit |
| Capture loss on BLE/app/backend failure | Zero for journaled audio (write-through journal + acks) |
| Reproducibility | Clean-machine build of FW/app/backend documented and CI-verified |

## 6. Phasing

- **P0 — Bench prototype:** XIAO nRF52840 Sense → BLE → minimal receiver → Sarvam streaming → transcript. *(Hardware ordered 2026-07-22.)*
- **P1 — Vertical slice:** Flutter gateway app + self-hostable backend + **Memory WAL v1** + web transcript/WAL view; offline journal sync; DFU.
- **P2 — Custom hardware:** Pendant PCB (nRF54L15 candidate) + enclosure + soldered NAND storage; power optimization to targets.
- **P3 — Intelligence layer:** richer synthesis (daily digests, cross-conversation patterns), integrations, agent workflows over the WAL.

## 7. Decision Log

| ID | Decision | Outcome |
|---|---|---|
| D1 | Hardware path | Dev-board first (XIAO nRF52840 Sense); custom board in P2 (nRF54L15 preferred candidate) |
| D2 | Capture model | VAD-gated with ≥ 500 ms pre-roll; hard mute upstream of VAD |
| D3 | STT strategy | Pluggable provider interface; Sarvam Saaras v3 streaming default; Deepgram + self-hosted Whisper alternates |
| D4 | App stack | Flutter |
| D5 | Licenses | **Open** — recommended Apache-2.0 (software) + CERN-OHL-S (hardware) |
| D6 | Data-loss architecture | Write-through journal on pendant flash; BLE sender reads from cursor; ack-based delta sync (see firmware.md) |
| D7 | Memory feature | Personal decision WAL (Stoa-inspired), extracted by a backend LLM pipeline; app is viewer/query surface (see app.md) |
| D8 | Real-product storage | Soldered SPI NAND (W25N-series) on the custom board; microSD is bench-only; extraction path is sync, not card removal |
