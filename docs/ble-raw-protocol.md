# Keepsake raw BLE contract — October 17, 2026

Our nRF52840 firmware and Swift gateway use this contract. UUID prefix:
`6b656570-7361-6b65-0001-00000000000`.

| UUID suffix | Role | Access |
|---|---|---|
| `1` | Primary service | Advertised |
| `2` | Audio | Notify, CCC enabled by phone |
| `3` | Stream descriptor | Read, exactly 20 bytes |
| `4` | Diagnostic snapshot | Read, exactly 20 bytes |
| `5` | Battery voltage and charge state | Read, 3 bytes when supported |
| `6` | Last link event (`KSE1`) | Read, exactly 20 bytes when supported |
| `7` | Previous reset trace (`KTR3`, also accepts `KTR1`/`KTR2`) | Read, exactly 20 bytes when supported |
| `8` | Current transport counters (`KTP1`) | Read, exactly 64 bytes when supported |
| `9` | Previous boot transport counters (`KTP1`) | Read, exactly 64 bytes when supported |

All multibyte numeric fields are little-endian. Descriptor must be read and
validated before subscribing. Unknown formats fail visibly. No legacy 8 kHz guess.

## Descriptor (`KSR1`)

| Offset | Size | Value |
|---|---|---|
| 0 | 4 | ASCII `KSR1` (descriptor/protocol version) |
| 4 | 4 | Sample rate: 16000 |
| 8 | 2 | Capture block duration: 100 ms |
| 10 | 1 | Channels: 1 |
| 11 | 1 | Sample bits: 16, signed PCM little-endian |
| 12 | 1 | Audio notification header size: 5 |
| 13 | 1 | Feature bit 0 = no software audio processing; all other bits 0 |
| 14 | 1 | Hardware gain in dB: 0 |
| 15 | 1 | Reserved: 0 |
| 16 | 4 | Random boot ID, constant until reboot |

Fixture with boot ID `0x12345678`:
`4b535231803e0000640001100501000078563412`.
C framing tests, Swift validation, and backend tests use this fixture.

## Audio notification

| Offset | Size | Value |
|---|---|---|
| 0 | 4 | Sequence number modulo 2^32 |
| 4 | 1 | Flags: 0 (reserved) |
| 5 | variable | Unmodified PCM bytes |

Payload size = even floor of `min(232, ATT_MTU - 8)`. Capture produces 3,200-byte
blocks. At MTU 247: fourteen notifications per 100 ms. Packet numbers are reserved
at capture before queue insertion; a dropped queue block consumes its sequence
range. Failed TX consumes sequence ranges too. Hardware/PDM errors can still lose
samples before framing, so inspect duration and diagnostic counters as well.

No silence is synthesized or discarded based on amplitude. Subscription controls
capture/power. No subscribed phone means no recording. Reconnect starts a new app
session; queued packets from previous subscriptions are not sent to a new session.

## Diagnostic snapshot (`KST1`)

| Offset | Size | Value |
|---|---|---|
| 0 | 4 | ASCII `KST1` |
| 4 | 4 | Dropped capture queue blocks since boot |
| 8 | 4 | Unsent notification packets counted by sender since boot |
| 12 | 4 | Microphone restart attempts since boot |
| 16 | 4 | nRF POWER.RESETREAS captured at startup |

Counters are diagnostic observations, not acknowledgments or a lossless guarantee.
Snapshots can span concurrent counter updates. App displays/polls them approximately
every ten seconds while executing; they do not gate or alter audio.

## Last link event (`KSE1`)

This optional characteristic lets the phone inspect the firmware's preceding
connection after reconnect. It resets on firmware reboot; compare the descriptor's
boot ID and the `KST1` reset flags to recognize a restart.

| Offset | Size | Value |
|---|---|---|
| 0 | 4 | ASCII `KSE1` |
| 4 | 4 | Disconnect count since boot |
| 8 | 4 | Previous connection duration, milliseconds |
| 12 | 2 | Most recent battery sample at disconnect, millivolts; 0 if unavailable |
| 14 | 1 | Bluetooth HCI disconnect reason |
| 15 | 1 | Firmware requested TX-stall recovery: 1 yes, 0 no |
| 16 | 2 | Current ATT MTU |
| 18 | 2 | Reserved, zero |

The normal firmware has serial logging off. A debug build additionally logs link
parameter, PHY, data length, and disconnect events on USB serial. The phone report
includes the readable counters and link event even with normal firmware.

## Previous reset trace (`KTR3`)

The firmware writes capture, supervisor, and sender stages into retained RAM. After
a watchdog or software recovery reset it copies that state before starting the new boot. This optional
characteristic reports the copied trace. It does not report a Bluetooth-only
disconnect when firmware did not reboot. Retained RAM may be invalid after power
loss or an interrupted write; in that case the valid byte is zero.

| Offset | Size | Value |
|---|---|---|
| 0 | 4 | ASCII `KTR3` (PDM ownership backport and nonblocking TX pump) |
| 4 | 1 | Previous reset trace valid: 1 yes, 0 no |
| 5 | 1 | Capture stage: 1 boot, 2 feed watchdog, 3 check state, 4 stop mic, 5 idle wait, 6 start mic, 7 read mic, 8 get BLE link/MTU, 9 queue audio, 10 free buffer, 11 TX recovery reset, 12 supervisor recovery reset |
| 6 | 1 | Supervisor stage: 0 idle, 1 sample battery, 2 request BLE disconnect, 3 start advertising |
| 7 | 1 | Sender stage: 0 idle, 1 dequeue audio, 2 BLE notification |
| 8 | 4 | Uptime in milliseconds at last successful watchdog feed |
| 12 | 4 | Uptime in milliseconds when the capture stage was entered |
| 16 | 4 | Signed watchdog feed return code (zero means last feed succeeded) |

Stages show the last recorded locations, not a proven root cause by themselves.
Compare them with the phone's disconnect timing, RSSI, reset flags, and counters.
The app also accepts `KTR2` (same 20-byte layout) and the previous `KTR1` layout, which only saved watchdog resets
and had stages 1–10. The report includes the characteristic version so a new run
can confirm which firmware is installed.

## Transport counters (`KTP1`)

UUID suffix 8 is the current boot. Suffix 9 is the snapshot captured before a
watchdog/software reset, valid under the same retained-RAM rules as `KTR3`.
The app reads current counters every ten seconds while it is executing; previous
counters are read on connection. All fields after the magic are little-endian u32,
except the signed error field. Each characteristic latches its image on offset 0
for a consistent multi-part ATT read. Fields are sampled individually, not a global
transaction. Queue depth, pool use and high water are observed samples.

| Offset | Value |
|---|---|
| 0 | Four bytes ASCII `KTP1` |
| 4 | Kind/validity: 0 previous unavailable, 1 current, 2 previous valid |
| 8 | Captured microphone blocks |
| 12 | Notifications accepted by `bt_gatt_notify_cb` |
| 16 | Host TX completion callbacks (not app receipt ACKs) |
| 20 | Backpressure attempts (`-ENOMEM`, `-EAGAIN`, `-ENOBUFS`); retries are not necessarily drops |
| 24 | Last nonzero send error, signed i32; remains recorded after recovery |
| 28 | Longest notification API call, microseconds |
| 32 | Capture blocks dropped due to pool/queue capacity |
| 36 | Unsent notification packets discarded by TX or session cleanup |
| 40 | Blocks discarded because age reached 250 ms |
| 44 | Microphone read errors/timeouts in capture loop |
| 48 | Highest observed queued-block count |
| 52 | Last observed queued-block count (capacity 8) |
| 56 | Last observed transport-pool use (capacity 10) |
| 60 | Uptime of last completion callback, milliseconds |

Counters reset per boot. Accepted notifications can be lost on disconnect before
a completion callback; the submission/completion difference is not a direct packet
loss measurement. Compare with the app's received packet counts and sequence gaps.
Older firmware without these optional characteristics still streams normally.

## Phone/server boundary

The phone wraps full notifications (including the five-byte header) in Base64
JSONL records without altering them. Thirty-second checkpoints close durable retry
files. Each chunk's metadata has `sample_rate_hz=16000` and optional
`stream_info_b64` containing the exact 20-byte descriptor. The backend validates
that descriptor against the stated format, and archives the exact body bytes.
Existing chunks without the descriptor remain readable/uploadable.

Packet format identifier `keepsake-p0` still denotes the same five-byte audio
framing; sample rate belongs to the per-chunk metadata, not that identifier.
Each app connection has a UUID session, each checkpoint a unique chunk UUID.
Server deduplication uses chunk UUID + SHA-256, not resettable firmware sequences.
Full upload contract: [iOS README](../mobile/ios/README.md).
