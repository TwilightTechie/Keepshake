# Keepsake Firmware

Zephyr firmware for the pendant. P0 target: **XIAO nRF52840 Sense** bench prototype —
VAD-gated PDM capture streamed over BLE with sequence numbers, received by
`backend/tools/ble_gateway.py`, which forwards utterances into the backend's
ingest WebSocket. See [../docs/requirements/firmware.md](../docs/requirements/firmware.md).

P0 simplifications (all tracked to P1): PCM16 instead of Opus (FW-2), no flash
journal (FW-4), no pairing/SMP (FW-8), no DFU (FW-6), no hard-mute button yet (FW-7).

## Setup (one time)

```bash
brew install cmake ninja dtc
python3 -m venv .toolchain-venv && .toolchain-venv/bin/pip install west
cd firmware
../firmware/.toolchain-venv/bin/west init -l manifest .   # if not yet initialized
.toolchain-venv/bin/west update                            # fetches zephyr + modules
.toolchain-venv/bin/west sdk install -t arm-zephyr-eabi    # cross toolchain
.toolchain-venv/bin/pip install -r zephyr/scripts/requirements-base.txt
```

## Build

```bash
cd firmware
.toolchain-venv/bin/west build -b xiao_ble/nrf52840/sense app
```

## Flash (XIAO has UF2 bootloader — no debugger needed)

1. Double-tap the tiny reset button next to USB-C → a `XIAO-SENSE` USB drive appears.
2. `cp build/zephyr/zephyr.uf2 /Volumes/XIAO-SENSE/` — board reboots into the firmware.

## Bench loop

```bash
# Terminal 1: backend (docker compose up in backend/, Sarvam providers on)
# Terminal 2: BLE gateway on the Mac
cd backend && .venv/bin/python tools/ble_gateway.py
# Speak near the pendant → utterances land in the app's Memory tab.
```
