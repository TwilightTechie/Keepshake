# Keepshake

An open-source AI pendant — hardware, firmware, and software — that captures your day (voice-activity-gated, with a hard mute), transcribes it in near real time, and distills it into a personal memory log: not just transcripts, but the decisions you made, the commitments you gave, and *why* — queryable in plain language.

**Status:** requirements & early hardware phase. P0 bench prototype parts ordered; no firmware/app code yet.

## Why another AI pendant?

- **Fully open.** Hardware (schematics, PCB, enclosure), firmware, backend, and apps. No vendor lock-in — the category's biggest player was acquired and shut off new sales overnight; that must not be able to happen to your memory device.
- **Private by architecture.** Self-hostable end to end. Default audio policy is transcribe-and-discard; raw audio retention is opt-in. Hard mute is a physical guarantee, not a software promise.
- **A memory layer, not a voice recorder.** Beyond the table stakes (conversation summaries, action items, daily recap, chat), Keepshake maintains an append-only decision log — attributed, evidence-linked, supersedable — so "what did I decide about X, and why?" has an answer.
- **Indic-first speech.** Sarvam Saaras streaming STT as the default provider (best-in-class Indian-language and code-mixed accuracy), with a pluggable provider interface (Deepgram, self-hosted Whisper).

## Architecture

```
┌──────────┐  BLE (Opus, versioned  ┌─────────────┐  WebSocket/HTTPS   ┌───────────────────────────┐
│ Pendant  │  GATT protocol)        │ Mobile app  │                    │ Backend (self-hostable)   │
│ nRF MCU  ├───────────────────────►│ (gateway +  ├───────────────────►│ STT → transcripts →       │
│ PDM mic  │  ◄── DFU, config       │  UX)        │                    │ memory extraction → API   │
└──────────┘                        └─────────────┘                    └───────────────────────────┘
     └── offline: write-through journal on flash; delta sync on reconnect
```

## Documentation

- [Requirements overview](docs/requirements.md) — vision, market landscape, system architecture, decision log
- [Hardware requirements](docs/requirements/hardware.md) · [P0 wiring guide](docs/hardware/p0-wiring.md)
- [Firmware requirements](docs/requirements/firmware.md)
- [App & platform requirements](docs/requirements/app.md)

## Roadmap

| Phase | Scope |
|---|---|
| **P0** | Bench prototype: XIAO nRF52840 Sense → BLE → Sarvam streaming STT → live transcript |
| **P1** | Vertical slice: mobile gateway app, self-hostable backend, memory log v1, offline journal sync, OTA DFU |
| **P2** | Custom pendant PCB + enclosure, soldered NAND storage, power optimization to spec |
| **P3** | Intelligence layer: richer synthesis, integrations, agent workflows |

## License

To be finalized (tracked as decision D5): Apache-2.0 for software and CERN-OHL-S for hardware are the working recommendation.
