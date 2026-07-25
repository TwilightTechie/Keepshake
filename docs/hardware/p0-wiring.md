# P0 Bench Prototype — Wiring & Connection Diagram

**Kit:** Seeed XIAO nRF52840 Sense + Seeed XIAO Expansion Board + 3.7 V Li-Po (JST-PH) + microSD
**Assembly:** Everything is plug-together. No jumper wires. The only connections you make by hand are: seat the XIAO on the expansion board, plug in the battery, insert the microSD, connect USB-C.

---

## 1. System block diagram (what talks to what)

```
                                (everything below the dashed line is on the two boards —
                                 no external wiring exists in P0)

  ┌────────────────────────────────────────────────────────────────────────────┐
  │                        XIAO nRF52840 SENSE (top board)                     │
  │                                                                            │
  │   ┌──────────────┐  PDM (CLK/DATA)   ┌──────────────────────────────┐      │
  │   │ MSM261D3526  ├──────────────────►│                              │      │
  │   │ PDM mic      │                   │                              │      │
  │   │ (on-board)   │                   │        nRF52840              │      │
  │   └──────────────┘                   │        Cortex-M4F @ 64 MHz   │      │
  │   ┌──────────────┐  QSPI             │        1 MB flash / 256 KB   │◄──┐  │
  │   │ P25Q16H      │◄─────────────────►│        RAM                   │   │  │
  │   │ 2 MB flash   │                   │                              │   │  │
  │   └──────────────┘                   │   BLE 5.0 radio ~~~~~▶ phone │   │  │
  │   ┌──────────────┐  I2C (internal)   │                              │   │  │
  │   │ LSM6DS3 IMU  ├──────────────────►│                              │   │  │
  │   └──────────────┘                   └──────┬───────────────────────┘   │  │
  │   ┌──────────────┐                          │ 14 castellated pins       │  │
  │   │ BQ25101      │ CHG                      │ (D0–D10, 3V3, GND, 5V)    │  │
  │   │ Li-Po charger│◄──── USB-C VBUS          │                           │  │
  │   └──────┬───────┘                          │            USB-C ─────────┘  │
  └──────────┼──────────────────────────────────┼────────────(flash/log/chg)──┘
             │ BAT+/BAT− (via socket pins)      │
  ═══════════╪══════════════════════════════════╪═══════ board-to-board ═══════
  ┌──────────┼──────────────────────────────────┼───────────────────────────┐
  │          │            XIAO EXPANSION BOARD (bottom board)               │
  │          │                                  │                           │
  │   ┌──────┴─────────┐                ┌───────┴────────┐                  │
  │   │ JST-PH 2.0     │                │  Pin breakout  │                  │
  │   │ battery conn.  │                └───┬───┬───┬────┘                  │
  │   └──────┬─────────┘        SPI (D8/9/10)│   │I2C(D4/D5)│D1             │
  │          │                       ┌───────┴┐ ┌┴────────┐ ┌┴───────────┐  │
  │   [+]────┤                       │ microSD│ │ OLED    │ │ User button│  │
  │   [−]────┤◄── Li-Po 3.7 V        │ slot   │ │ SSD1306 │ │ (momentary)│  │
  │          │    500 mAh            │ CS=D2  │ │ + PCF8563│└────────────┘  │
  │          │                       └────────┘ │ RTC     │                 │
  │          │                                  └─────────┘                 │
  └──────────┴────────────────────────────────────────────────────────────┘
```

**Reading it as the audio path (the part we care about):**

```
 sound ──► PDM mic ──► nRF52840 (PDM peripheral, EasyDMA)
                          │
                          ├─► VAD gate ──► Opus encoder ──► BLE GATT notify ~~~► phone ──► backend/STT
                          │
                          └─► (offline / out of range) ──► SPI ──► microSD ring buffer
                                                                    └─ synced over BLE on reconnect
```

---

## 2. Physical assembly (what you actually do)

```
        USB-C cable (flashing + charging)
             │
             ▼
      ┌─────────────┐
      │ XIAO Sense  │   ◄── press down into the two 7-pin female
      │ (component  │       headers on the expansion board.
      │  side up,   │       USB-C connector faces the board edge
      │  USB-C out) │       marked for it on the silkscreen.
      └──┬───────┬──┘
   ┌─────┴───────┴──────────────────────────────┐
   │          XIAO Expansion Board              │
   │                                            │
   │  [JST-PH]◄── Li-Po 500 mAh    [microSD]◄── insert card (contacts down)
   │   │ RED  = +                               │
   │   │ BLACK= −   ⚠ VERIFY against silkscreen │
   │  [SWD pads]     [User button]   [OLED]     │
   └────────────────────────────────────────────┘
```

Assembly order: ① insert microSD → ② seat XIAO on headers → ③ **check battery polarity against the silkscreen** → ④ plug battery → ⑤ USB-C to your machine → flash.

> ⚠ **Battery polarity.** Indian-market JST-PH Li-Pos frequently ship with red/black reversed relative to Seeed's connector. Reversed polarity destroys the charge circuit instantly. Confirm `+`/`−` on the expansion-board silkscreen against the actual red/black leads before plugging in. If reversed, lift the plastic latches on the JST housing with tweezers and swap the two crimp pins.

---

## 3. Pin map (nRF52840 GPIO ⇄ peripherals)

Nothing here needs wiring — it documents which pins the firmware must claim, and which XIAO pins the expansion board consumes.

### On the XIAO Sense itself (internal, fixed)

| Peripheral | Signal | nRF52840 pin | Notes |
|---|---|---|---|
| PDM mic | CLK | P1.00 | 16 kHz capture via PDM peripheral + EasyDMA |
| PDM mic | DATA | P0.16 | |
| PDM mic | power enable | P1.10 | drive high to power the mic; **drive low = hardware-ish mute for FW-7** |
| QSPI flash (2 MB) | CS/CLK/IO0–3 | P0.25/P0.21/P0.20/P0.24/P0.22/P0.23 | small; used for config + short emergency buffer |
| IMU (LSM6DS3) | I2C + INT | internal bus | tap-to-wake later; unused in P0 |
| RGB LED | R/G/B | P0.26/P0.30/P0.06 | active-low; capture/consent indicator |
| Battery voltage sense | ADC | P0.31 (VBAT div.) | crude %; real fuel gauge comes with custom board (HW-3) |
| Charge status (BQ25101) | CHG | P0.17 | |

### Consumed by the expansion board (via XIAO pins D0–D10)

| Expansion-board device | XIAO pin(s) | Bus | Firmware use in P0 |
|---|---|---|---|
| microSD slot | D8 (SCK), D9 (MISO), D10 (MOSI), **D2 (CS)** | SPI | offline Opus ring buffer (FW-4) |
| User button | **D1** | GPIO, active-low | mute / pairing gestures (FW-7) |
| OLED SSD1306 128×64 | D4 (SDA), D5 (SCL) | I2C | debug status: BLE state, VAD state, battery |
| RTC PCF8563 | D4/D5 (shared I2C) | I2C | wall-clock timestamps for offline segments |
| Buzzer | D3 | PWM | optional feedback; off by default |
| SWD pads | SWDIO/SWCLK | — | J-Link/CMSIS-DAP debugging when needed |

**Free pins after all of the above:** D0, D6, D7 — spare for experiments.

> Pin assignments match the Seeed wiki and the Zephyr board definition (`xiao_ble/nrf52840/sense`). Firmware devicetree is the source of truth; if this table and the devicetree ever disagree, trust the devicetree and fix this doc.

---

## 4. Power tree

```
                 ┌──────────── USB-C 5 V (when plugged) ─────────────┐
                 ▼                                                   │
   Li-Po 3.7 V ──► BQ25101 charger (on XIAO) ──► 3V3 LDO ──► nRF52840 + mic + flash
   500 mAh      ◄─ charges at ~50/100 mA           │
   (JST-PH on      while USB present               └─► 3V3 rail to expansion board
    expansion                                           (OLED, SD, RTC)
    board)
```

- Battery charges whenever USB-C is connected; the pendant runs from battery otherwise.
- The OLED and SD card are the hungriest passengers — firmware must power-gate the SD (mount/write/unmount bursts) and blank the OLED outside debug mode, or the ≥ 48 h target (§9 of requirements) is unreachable even at bench scale.

---

## 5. What P0 deliberately does NOT have

- No fuel gauge (MAX17048 arrives with the custom board) — battery % is an ADC estimate.
- No hardwired recording LED (PR-1): P0 approximates it in firmware via the RGB LED + mic power-enable pin. The custom board makes it a hardware guarantee.
- No wearable enclosure — this is a bench rig. Form factor is Phase 2.
