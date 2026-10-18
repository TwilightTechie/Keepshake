# Keepsake raw BLE contract — October 17, 2026

Our nRF52840 firmware and Swift gateway use this contract. UUID prefix:
`6b656570-7361-6b65-0001-00000000000`.

| UUID suffix | Role | Access |
|---|---|---|
| `1` | Primary service | Advertised |
| `2` | Audio | Notify, CCC enabled by phone |
| `3` | Stream descriptor | Read, exactly 20 bytes |
| `4` | Diagnostic snapshot | Read, exactly 20 bytes |

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
Full upload contract: [iOS README](../ios/README.md).
