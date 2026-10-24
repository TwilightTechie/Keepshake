# Bluetooth/audio investigation — October 23, 2026

## Finding and confidence

The latest report contained both software recovery resets after stalled Bluetooth
TX and hardware-watchdog resets with the last capture breadcrumb at `queue audio`.
Good sampled RSSI and battery voltage did not explain that pattern. The breadcrumbs
locate the last observed code, but do not identify the original fault by themselves.

**A concrete memory-ownership bug was found and reproduced in our pinned Zephyr
v4.1.0 microphone driver.** The driver stores only the most recent allocated slab
pointer. PDM pipelines multiple DMA buffers: while A completes, it requests C and
continues writing B. The old handler enqueues C rather than completed A. Our capture
loop reads and frees that live DMA buffer. Later DMA writes can corrupt a freed
slab block, including its allocator bookkeeping. This is a strong explanation for
failures surfacing in unrelated kernel/Bluetooth operations. Hardware validation is
still needed to establish how much of the reported reset pattern it accounts for.

Upstream corrected this ownership with a FIFO of submitted slab pointers in
[Zephyr commit 8260e1ff5cc4](https://github.com/zephyrproject-rtos/zephyr/commit/8260e1ff5cc4f25ef9f54a8717917016015df707).
We backport that commit into the generated driver during CMake configuration.
There is no untracked edit to the Zephyr dependency and no broad RTOS upgrade.

**A second confirmed design defect was an ineffective TX timeout.** In the pinned
[`bt_att_chan_create_pdu`](https://github.com/zephyrproject-rtos/zephyr/blob/v4.1.0/subsys/bluetooth/host/att.c),
ordinary threads can wait forever for ATT buffers. Our 150 ms loop deadline ran
only after `bt_gatt_notify` returned. Therefore it could not bound that wait.

## Changes

1. Apply the upstream PDM ownership fix. CMake verifies the original driver's hash
   and compiles only the generated corrected source. A future dependency update
   requires reviewing/removing the backport.
2. Replace full PCM messages with pointer messages backed by a fixed ten-block pool.
   Copy samples outside kernel queue locks, and release ownership explicitly on
   normal completion, queue overflow, transport failure and disconnect cleanup.
3. Replace the blocking sender with a short system-workqueue TX pump. This is the
   context in which this Zephyr version makes notification allocation nonblocking.
   Maximum four notifications per invocation; yield between batches/retries.
   Battery sampling and synchronous HCI operations stay on the private supervisor.
4. Expire audio after 250 ms rather than accumulate a growing backlog. Dropped
   packets retain visible sequence gaps. Track actual host TX completion callbacks
   for liveness, fenced by subscription generation.
5. Add live and retained transport snapshots (`KTP1`) to the app's device card,
   disconnect logs and diagnostic exports. Counters identify capture, submission,
   completion, backpressure, last error, longest send call, queue/pool pressure,
   expired blocks and microphone read failures. `KTR3` identifies this firmware.

The native PCM format, hardware gain, server VAD and app's 30-second checkpointing
are unchanged. This transport queue does not record audio across disconnection.

## What Omi does

The comparison is to BasedHardware/**Omi**. Its UI showing connected is not evidence
of an uninterrupted physical link or lossless audio delivery.

- The [devkit microphone driver](https://github.com/BasedHardware/omi/blob/main/omi/firmware/devkit/src/mic.c)
  uses nrfx directly with two buffers and consumes `event->buffer_released`. It
  bypasses the Zephyr DMIC wrapper bug present in our pinned dependency.
- Its [devkit configuration](https://github.com/BasedHardware/omi/blob/main/omi/firmware/devkit/src/config.h)
  uses Opus at 32 kbit/s. Our raw PCM is 256 kbit/s: eight times the nominal audio
  bitrate before transport overhead. Its
  [transport](https://github.com/BasedHardware/omi/blob/main/omi/firmware/devkit/src/transport.c)
  decouples capture and sending with a ring buffer, retries and optional storage
  fallback. The inspected synchronous notification retry alone also does not prove
  that the underlying Zephyr call is time-bounded.
- Omi's [saved-pendant reconnect controller](https://github.com/BasedHardware/omi/blob/312b4f734c22900547ff23e7260f69622b6aa36b/app/lib/services/devices/saved_pendant_reconnect.dart)
  uses one connection attempt, generation guards and capped exponential retry
  timers (5 seconds to 5 minutes), with adapter/resume recovery hooks. Our current
  app already prevents duplicate scheduled reconnects and times out stuck attempts.
- Omi has [reported reconnect-related bugs](https://github.com/BasedHardware/omi/issues/5566).
  That issue concerns repeated UI dialogs on reconnect, not proof of the same
  firmware root cause or a measured disconnect rate.

The implemented ownership, queue and nonblocking TX changes are the immediate
architecture correction. Opus is a separate future option if radio-throughput or
power measurements justify it: it requires versioned firmware framing, app/server
decoding support and audio-quality validation. Device-side recording/replay is a
separate project if the product must preserve audio while the phone is disconnected.
Neither compression nor replay is required to correct the reproduced memory bug.

## Verification and next run

- The host test compiles the actual driver's event handler: the original returns
  the wrong live DMA pointer; the backport passes 10,209 completions, 100 stop/start
  cycles, and RX queue/slab exhaustion checks under ASan/UBSan.
- The actual TX worker passes fake-BLE tests for packet byte preservation, sequence
  wrap, bounded invocation work, resource backpressure, expiry, disconnect cleanup,
  and delayed completion callbacks from old subscriptions.
- Protocol and recovery-deadline host checks pass; the iOS KTP1 decoder tests pass.
- Firmware UF2 and iOS simulator builds succeed. Physical radio behavior, power
  stability and long-session behavior still need the user's pendant run.

Flash `firmware/build-raw/zephyr/zephyr.uf2`, install the app from Xcode, and record
for 20–30 minutes with the phone nearby. Export a report after that run or after
the first unexpected reconnect. Verify `BLE transport 3`, `KTR3` and `KTP1` appear.
The first flash may legitimately have no retained previous-boot snapshot. A later
watchdog/software reset should expose both its breadcrumb and transport snapshot.
Do not accept frequent close-range firmware resets as normal Bluetooth behavior.
