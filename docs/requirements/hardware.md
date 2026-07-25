# Hardware Requirements

Part of the [requirements overview](../requirements.md). Covers pendant electronics, mechanical, the P0 dev kit, and the Phase-2 custom board.

## P0 dev kit (current, ordered 2026-07-22)

XIAO nRF52840 Sense + 500/1100 mAh protected Li-Po + inline SPDT slide switch (battery soldered to pads, Omi-style). Wiring, pin map, and power tree: [hardware/p0-wiring.md](../hardware/p0-wiring.md). Known P0 compromises: offline buffer limited to onboard 2 MB QSPI (~40–80 min real-world with VAD), ADC-only battery estimate, firmware-driven (not hardwired) recording LED.

## Requirements

- **HW-1 MCU/SoC:** Nordic nRF-family BLE SoC. P0/P1: nRF52840 (XIAO Sense). P2 custom board: **nRF54L15 preferred** (M33 @128 MHz, BLE 6.0, better power efficiency; validate on XIAO nRF54L15 Sense before committing the PCB), nRF5340 as fallback with the larger ecosystem.
- **HW-2 Microphone:** Digital PDM MEMS mic, ≥ 64 dB SNR, AOP ≥ 120 dB SPL. Footprint for a second mic (future beamforming) without a respin.
- **HW-3 Power:** Single-cell Li-Po; targets per [overview §5](../requirements.md). Fuel gauge (MAX17048-class) mandatory on the custom board — battery % must be measured, not estimated. USB-C charging; no proprietary cradle.
- **HW-4 Storage:** Soldered SPI NAND flash on the custom board — W25N-series; **1 Gbit (128 MB) minimum** = ~9–18 h Opus, 2 Gbit preferred. No microSD socket on the product: bulkier, a field-failure point, and a privacy hole (removable audio). Extraction is BLE sync, never card removal. Retained data encrypted at rest.
- **HW-5 UX hardware:** One tactile button (multi-function), one RGB LED. **Recording indicator hardwired to the mic power rail on the custom board** — consent signaling must not depend on firmware correctness. Optional vibration motor (stretch).
- **HW-6 Mechanical:** Pendant ≤ 20 g with battery; lanyard or clip. Enclosure 3D-printable at home (FDM) and CNC-able; STEP + parametric source published; mic acoustic port design documented.
- **HW-7 Design outputs:** KiCad source, fab-ready Gerbers, interactive BOM with LCSC/Digi-Key part numbers + alternates for critical parts, PCBA-ready files. Every part hand-solderable or JLCPCB-assembly-compatible.
- **HW-8 Debug:** SWD (Tag-Connect or 1.27 mm) + one UART exposed. No unbrickable boards.
- **HW-9 Power switch:** True mechanical power switch on the battery path (learned from Omi's build; deep-sleep is not "off" for a drawer-stored device).
- **HW-10 License:** CERN-OHL-S (pending D5 confirmation).
