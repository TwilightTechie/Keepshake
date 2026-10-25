# Keepsake raw firmware

Our own Zephyr firmware for **Seeed XIAO nRF52840 Sense**, paired with the native
Swift app in `../mobile/ios`. No Omi firmware, codec, cloud integration, or runtime code is
included. Review/update: October 17, 2026.

## Audio path

Microphone → native **16 kHz mono PCM16**, in **100 ms / 3,200-byte blocks** →
MTU-sized BLE notifications. Every notification retains the existing five-byte
header: `[uint32 LE sequence][uint8 flags=0][PCM bytes]`.

Removed from the previous firmware:
- Pair-averaging/downsampling from 16 to 8 kHz.
- The software gain/clamp loop (previously configured to shift by zero).
- Extra +12 dB hardware gain; PDM gain is now fixed at **0 dB**.
- Per-block energy/DC calculations and periodic energy logs.
- Unused 32 KB heap reservation, UART/console/USB runtime in the normal build.

No VAD, silence suppression, noise reduction, AGC, high-pass filter, resampling,
or audio codec is applied. PDM-to-PCM conversion by the microphone peripheral is
still required to obtain PCM samples; the resulting samples are copied unchanged.

At MTU 247, each block becomes 14 notifications (13 × 232 audio bytes + 184 bytes),
about **140 notifications/second**. Smaller MTUs produce more packets. Payloads
are rounded down to an even number of bytes so a packet never splits a PCM16 sample.
There is no padding or sample transformation. Native audio is **32 KB/second**,
about 960 KB per 30 seconds before packet/JSON/Base64 overhead.

## October 23 transport correction

The v4.1.0 Zephyr PDM driver returned the **most recently allocated** slab buffer
instead of the DMA buffer that had completed. This could return/free memory while
PDM was still writing to it. The build now applies upstream commit
[8260e1ff5cc4](https://github.com/zephyrproject-rtos/zephyr/commit/8260e1ff5cc4f25ef9f54a8717917016015df707)
from `patches/zephyr-pdm-ownership.patch` to a generated source file in the build
directory and substitutes it for the original audio driver. The west checkout is
unchanged. CMake checks the original source hash and stops for review on a Zephyr
upgrade, so this correction cannot silently disappear. The build requires `patch`.

Capture copies PCM into a fixed ten-block pool with interrupts enabled and enqueues
only a pointer. The eight-entry queue no longer copies 3,200 bytes while holding its
kernel spinlock. The TX worker owns and releases each dequeued block; disconnect
cleanup frees queued blocks instead of purging away their pointers.

The dedicated blocking sender has been replaced with a short system-workqueue
pump, **at most four notifications per invocation**. In this pinned Zephyr version,
notification allocation from that queue uses `K_NO_WAIT`; an ordinary thread uses
`K_FOREVER`. Backpressure retries yield for 2 ms; otherwise the next batch waits
1 ms. Audio older than 250 ms at send time is dropped with sequence gaps and explicit
counters. This is a bounded live queue, not durable offline storage. Recovery uses
TX **completion callbacks**, not merely successful submission. These callbacks are
host-stack completion signals, not app-level receipt acknowledgements.

`KTP1` current/previous-boot counters and `KTR3` breadcrumbs are shown in the app
and exported reports. The previous snapshot is available only after a retained-RAM
watchdog/software reset; a power loss or firmware update may invalidate it.
The 16 kHz PCM packet contract and the app's 30-second checkpointing are unchanged.

Run the focused host regression tests from the repository root:

```sh
python3 firmware/tests/run_host_tests.py
```

The harness compiles the actual driver event handler before/after the patch and
reproduces the old ownership failure. It also exercises the actual TX pump with
fake BLE backpressure, expiry, disconnect cleanup and delayed completion callbacks.
These checks and successful builds do not replace the next physical pendant run.
See [investigation and Omi comparison](../docs/2026-10-23-ble-audio-fix.md).

## Power and recovery

- Microphone PDM capture and its power rail are **off until a phone subscribes**.
  On unsubscribe/disconnect, capture stops, queued old-session samples are cleared,
  the PDM driver releases its clock, and the mic rail turns off. This is not an
  offline recorder: there is no flash journal to capture while disconnected.
- The unused IMU's boot-on regulator is disabled and its power rail held low.
- Preserve the board's existing DC/DC regulator configuration; do not force
  regulator modes intended for other hardware.
- Fast advertising (100–150 ms) for 30 seconds after boot/disconnect, then slower
  connectable advertising (1–1.2 seconds), indefinitely. The service UUID is in
  the primary advertisement for background scans. Idle is never System OFF,
  because that would require a physical wake event.
- Advertising resumes when connection resources are recycled. A one-second
  supervisor on its own preemptible workqueue retries failed starts and resets after 30 seconds of persistent
  advertising failure. No normal periodic reset or reset-on-disconnect.
- One hardware watchdog channel is fed by the capture loop. If that loop stops
  progressing for 30 seconds, the SoC resets. A retained breadcrumb records the
  last capture, sender, and supervisor stages and is available after a watchdog
  or software recovery reboot through the optional `KTR3` BLE characteristic. The trace is diagnostic;
  it does not alter capture, packet framing, or watchdog recovery.
- Microphone reads have 500 ms timeouts. Three failures trigger a stop/drain/restart;
  three unsuccessful recovery rounds reset the device. Ten seconds of healthy
  capture clears the recovery streak. The STOP path allows asynchronous DMA release.
- If capture is progressing but notifications have made no progress for five
  seconds, request a disconnect to let the phone reconnect. Independently, the
  capture/idle loop resets if subscribed TX has stalled for 15 seconds or its
  private supervisor has not completed for 20 seconds. This bounds recovery when
  a blocking Bluetooth/ADC call cannot finish. The shared system workqueue remains
  available for Bluetooth TX completion and disconnect cleanup. The app separately reconnects
  after an eight-second observed notification stall while it is executing.
- Connection references are protected against disconnect races. Generation tags
  prevent queued audio from an old connection/subscription leaking into a new one.
- Packet sequences are reserved **before** enqueueing a capture block, so software
  queue drops now create visible sequence gaps. Readable diagnostic counters report
  dropped queue blocks, unsent notification packets, mic recoveries, and reset cause.
- Automatic PHY and data-length negotiation are enabled. Request 15 ms connections;
  the phone controls the final parameters. Increase ACL TX buffers from the old
  default of 3 to 16, with sufficient event buffers and matching upper-layer buffers.
  Retries are bounded; a slower radio can still drop audio. Never silently downsample
  to conceal insufficient throughput.

These are implemented recovery/power measures, **not measured battery-life claims**.
No offline storage, DFU, pairing, or hard-mute button has been added in this milestone.
Onboard flash deep sleep is not claimed: no new flash driver or vendor-specific
power commands have been introduced just to optimize an unused device.

## App and protocol alignment

See [BLE protocol](../docs/ble-raw-protocol.md).

The service and audio UUIDs are unchanged. Two new read characteristics report
stream format and diagnostics. The updated Swift app reads and validates the format
**before enabling audio notifications**, labels saved chunks from the device's rate,
and archives the exact descriptor in chunk metadata. There is no manual sample-rate
picker. It refuses old firmware without the descriptor rather than guessing 8 kHz.

Deploy the updated backend raw-chunk schema together with the updated app; it accepts
and verifies the optional descriptor. Previously recorded 8 kHz chunks still upload
with their original metadata. The old Python gateway/test scripts that hardcode
8 kHz are **not compatible with this 16 kHz firmware**; use the updated Swift app or
the hardware verification script below. They were not silently repurposed.

## Build

Existing Zephyr workspace: upstream **v4.1.0**, Nordic SDK toolchain installed locally.
From `firmware/`:

```sh
.toolchain-venv/bin/west build -d build-raw -b xiao_ble/nrf52840/sense app
```

Artifact: `build-raw/zephyr/zephyr.uf2`.
Optional USB serial diagnostics (more power/RAM; not the normal image):

```sh
.toolchain-venv/bin/west build -d build-debug -b xiao_ble/nrf52840/sense app -- -DEXTRA_CONF_FILE=debug.conf
```

Fresh workspace bootstrap remains in `setup_and_build.sh` (requires Homebrew
cmake/ninja/dtc and a downloaded Zephyr SDK). Do not run setup just to rebuild.

## Flash and physical validation

1. Connect the board by USB. Double-tap its reset button **once to enter the UF2
   bootloader for flashing**; wait for the `XIAO-SENSE` drive.
2. Copy `build-raw/zephyr/zephyr.uf2` onto that drive. It reboots automatically.
3. Use the updated Swift app to connect. The normal build does not expose a USB
   serial console. The bootloader still exposes its own USB drive on double-tap.

The firmware cannot change the bootloader's button requirement for entering flash
mode. After a successful flash, normal boot/reconnect/recovery is intended to work
without button presses. This still needs hardware acceptance, including cold power-on.

From the repository root, with other BLE gateways closed:

```sh
backend/.venv/bin/python firmware/tests/verify_ble.py --cycles 5 --seconds 30 --output /tmp/keepsake-raw-acceptance
```

This records **all notification bytes**, validates the descriptor, measures received
PCM duration versus wall time, checks gaps, and disconnects/reconnects five times
without reset. No cloud upload or audio processing is performed. Audio logs remain
in the chosen output directory. A short transport pass does not prove audio quality.

Then verify: ten-minute locked-iPhone capture; out-of-range recovery; Bluetooth
off/on; unsubscribe/resubscribe; cold USB/battery boot; and true current draw both
idle and capturing. Test watchdog stalls with a debugger/fault-injection image before
claiming automatic recovery from every possible fault. Confirm 0 dB speech levels by
listening to server-side reconstructed PCM. Previous firmware had 16 kHz congestion;
the new transport settings must be measured on this phone before everyday use.

## Research references

Reviewed Omi's official source at commit `6a9c57556d8160921c9e35ac5c5677a3429f45b7`:

- [Devkit startup](https://github.com/BasedHardware/omi/blob/6a9c57556d8160921c9e35ac5c5677a3429f45b7/omi/firmware/devkit/src/main.c): watchdog initialization, unused-flash suspension, regulator setup.
- [Devkit transport](https://github.com/BasedHardware/omi/blob/6a9c57556d8160921c9e35ac5c5677a3429f45b7/omi/firmware/devkit/src/transport.c): bounded notification retries, connection generations.
- [Devkit configuration](https://github.com/BasedHardware/omi/blob/6a9c57556d8160921c9e35ac5c5677a3429f45b7/omi/firmware/devkit/prj_xiao_ble_sense_devkitv1.conf): automatic PHY/data-length negotiation.
- [Consumer microphone power control](https://github.com/BasedHardware/omi/blob/6a9c57556d8160921c9e35ac5c5677a3429f45b7/omi/firmware/omi/src/lib/evt/mic.c): explicit mic power lifecycle. Consumer-specific AAD/pins are not transferable to our board.
- [Zephyr v4.1 Bluetooth definitions](https://github.com/zephyrproject-rtos/zephyr/blob/v4.1.0/include/zephyr/bluetooth/bluetooth.h): advertising stops after connection; restart after connection-object recycling.

These informed the design; this implementation uses our own protocol and code.
We deliberately did not adopt codecs, speech gating, extra sensors, SD-card startup
dependencies, or unrelated consumer-board power/register assumptions.
