# Firmware Requirements

Part of the [requirements overview](../requirements.md). Targets: `xiao_ble/nrf52840/sense` (P0/P1), custom board devicetree (P2). All storage access goes through a flash-abstraction layer so P0 (QSPI/microSD) and P2 (SPI NAND) run identical logic.

## Requirements

- **FW-1 RTOS:** Zephyr upstream, pinned via `west` manifest; no vendor forks. CI builds every commit; `twister` tests on `native_sim` where possible.
- **FW-2 Audio pipeline:** PDM @ 16 kHz/16-bit mono → VAD gate → Opus (16–32 kbps, complexity tuned to power budget) → framed transport. Mic → BLE notification ≤ 100 ms. Zero-copy buffer handoff; no dynamic allocation in the audio path.
- **FW-2a VAD:** On-device (never backend — silence must die before it costs flash or radio). Lightweight energy+spectral VAD (tiny NN if power allows); **≥ 500 ms RAM pre-roll** so utterance starts are never clipped; 1–2 s hangover; sensitivity configurable from the app. Hard mute sits *before* the VAD: muted = mic power rail down.
- **FW-3 Transport:** Versioned, documented BLE GATT service — audio stream, control, status/telemetry characteristics. Every audio segment carries a monotonic sequence number.
- **FW-4 Write-through journal (D6):** One code path, always:
  1. VAD-passed Opus segments accumulate in RAM (~30–60 s, tunable) and are **burst-written** (block-aligned, sequential — never trickle-written) to an append-only journal on flash.
  2. A sender task streams from a **send cursor**; the phone acks by sequence number (and later, backend-durable acks). Only acked data is reclaimable when the ring wraps.
  3. Connected: cursor rides the journal head → behaves like live streaming. Disconnected: journal grows, cursor waits. Reconnect: resume from last ack — delta sync is `head − cursor`, no negotiation.
  4. Live segments take priority over backlog; backlog trickles behind on remaining bandwidth. Backend reassembles by sequence number + RTC timestamp.
- **FW-5 Power management:** Documented, *measured* budget per state (capture, VAD-idle, sync, sleep). PPK2 power-profile regression is part of the release checklist. SD/NAND power-gated between bursts; every peripheral accounted for.
- **FW-6 DFU:** Signed OTA over BLE (MCUboot), rollback-safe; USB/SWD flashing for developers.
- **FW-7 Controls:** Button gestures: hard mute/unmute (survives reboot), power, pairing. LED reflects capture state.
- **FW-8 Security:** BLE LE Secure Connections; no open characteristics post-pairing; per-device keys; journal encrypted at rest on P2 hardware.
