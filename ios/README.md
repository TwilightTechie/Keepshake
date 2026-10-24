# Keepsake Raw Gateway (iPhone)

A small native Swift app: subscribe to the current pendant's BLE notifications,
append **every notification unchanged** to local disk, close a file every 30 seconds,
and upload completed files with persistent retries. No DSP, VAD, sample conversion,
codec, transcription, or speech segmentation runs on the phone.

## Hardware contract

The October 17 raw firmware sends **native 16 kHz mono PCM16**, 100 ms blocks,
without downsampling, noise reduction, software gain, or codecs. The microphone
is powered only while the app subscribes. The app reads the 20-byte `KSR1` stream
descriptor before subscribing and stores it with each chunk; no manual rate label.
An old firmware image without this descriptor is rejected with instructions to
flash the matching firmware. See [the exact BLE contract](../docs/ble-raw-protocol.md)
and [firmware build/flash instructions](../firmware/README.md).

At a 247-byte MTU there are 14 notifications per block (about 140/second), each
with a five-byte sequence/flags header. The phone saves all bytes unchanged.
The new firmware reserves sequences before queueing, making queue drops visible.
Firmware diagnostic counters and reset cause appear on the app's device card.
The current diagnostic firmware also exposes the previous Bluetooth HCI disconnect
reason, whether its own TX-stall recovery requested that disconnect, connection
duration, and the latest battery sample. The app logs these alongside iPhone error,
RSSI, boot ID, and per-connection packet totals, and includes them in Generate Report.
Compare reports from battery versus USB power and open air versus a pocket; a
voltage sample cannot by itself prove or rule out a brief power dip.
The physical radio/cadence and battery behavior still require device validation.

## Open and install with Xcode

This Mac currently has Command Line Tools, but no full Xcode app/iOS SDK.

1. Install **Xcode** from the Mac App Store. Open it, finish first-launch components,
   and install iOS platform support if prompted.
2. Open `ios/RawGateway.xcodeproj` (no CocoaPods, npm, or third-party packages needed).
3. In Xcode Settings → Accounts, sign in with your free Apple Account.
4. Select the **RawGateway** target → Signing & Capabilities. Keep automatic signing
   on, select your **Personal Team**, and change the bundle identifier to a unique
   value if Xcode requests it, e.g. `com.yourname.keepsake.rawgateway`.
5. Connect your iPhone with a data-capable USB cable, unlock it, and accept **Trust**.
6. Enable **Settings → Privacy & Security → Developer Mode** on the iPhone; restart
   and confirm if prompted. The option may appear after Xcode pairs with the phone.
7. Select your real iPhone as the run destination and press **Run** (⌘R).
8. If asked, trust the developer under **Settings → General → VPN & Device Management**.
   Allow Bluetooth when the app asks.
9. In the app, enter your exact HTTPS upload endpoint and bearer token, then **Save
   server settings**. Keep **Checkpoint: 30 seconds**, and choose whether
   uploads may use cellular data. Enable **Automatic uploads**, then **Connect and capture**.

A free Personal Team provisioning profile expires after seven days; rebuild/run
again from Xcode. Keep the bundle ID and installation so the app's queued files
remain in its container. Do not uninstall the app while it holds unsent recordings.
The iPhone simulator does not validate physical pendant Bluetooth capture.

Apple references:
- https://developer.apple.com/help/account/basics/about-your-developer-account
- https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
- https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules

## Upload contract and server deployment

The matching backend implementation is included in this repo. It is **not deployed**
to DigitalOcean by creating the app. An arbitrary webhook returning `200 OK` is
not sufficient: it must honor the durable acknowledgment contract below.

Deploy the updated backend and run its migration (`alembic upgrade head`, or the
existing Docker startup migration). Configure an HTTPS reverse proxy and allow
request bodies up to **32 MiB** (for nginx, `client_max_body_size 32m;`). Use the backend's
`KEEPSAKE_API_TOKEN` as the app bearer token. No token is committed to this project.

The app's full endpoint is:

```
https://YOUR_HOST/v1/ingest/raw-chunks
```

The server URL must be reachable by the phone. `localhost` on the phone is the phone,
not the Mac or DigitalOcean server. HTTPS with a valid certificate is required.

Request:

```
POST /v1/ingest/raw-chunks
Authorization: Bearer <configured token>
Content-Type: application/x-ndjson
Idempotency-Key: <permanent chunk UUID>
X-Content-SHA256: <SHA-256 of exact body bytes, lowercase hex>
```

Body is UTF-8 JSON Lines. The first line is metadata:

```json
{"version":1,"chunk_id":"<uuid>","session_id":"<uuid>","device_id":"<CoreBluetooth UUID>","started_at":"2026-10-16T12:00:00.000Z","sample_rate_hz":16000,"channels":1,"bits_per_sample":16,"encoding":"pcm_s16le","packet_format":"keepsake-p0","checkpoint_seconds":30}
```

Each subsequent line is one complete original Bluetooth notification:

```json
{"received_at":"2026-10-16T12:00:00.100Z","elapsed_seconds":0.1,"packet_b64":"<base64 of header AND audio bytes>"}
```

Metadata also includes `stream_info_b64`, the Base64 encoding of the exact firmware descriptor. The backend checks its rate against `sample_rate_hz`. Base64 is lossless packaging, not audio compression. JSON key order is immaterial
for decoding, but the checksum covers the exact stored file bytes. Receipt times
come from the phone; they are not hardware microphone timestamps. Elapsed time
uses the phone's monotonic uptime relative to the chunk's first notification.
Chunk boundaries use elapsed time, never a guess about sample rate or packet size.

The server responds **after database commit**:

```json
{"chunk_id":"<same UUID>","sha256":"<same hash>","stored":true}
```

The phone deletes its file only after a 2xx response with all three fields matching.
Network failures, non-2xx responses, redirects, wrong hashes, and generic `OK`
responses keep the file for retry. Same ID + same bytes is idempotent; same ID +
different bytes returns 409. Retrying may resend network bytes; it cannot create
a second stored chunk under the same ID.

Raw files are stored in the new `raw_chunks` table, **independently of the existing
STT pipeline**. This milestone archives raw input; it does not automatically feed
it to Sarvam or the old utterance segmenter. Server-side processing can consume
these envelopes later without changing the app. Originals are retained until
explicit deletion; the existing authenticated `DELETE /v1/data` includes them.

Authenticated inspection endpoints:
- `GET /v1/ingest/raw-chunks?limit=50`: recent chunk metadata (maximum 200).
- `GET /v1/ingest/raw-chunks/<uuid>`: download the exact received file and checksum.

## Reliability behavior

- Default 30-second checkpoints, configurable from 10 to 60 seconds. Capture
  continues into the next file while older files upload. Stop/disconnect flushes
  the current partial-duration chunk.
- Disk writes happen on each notification; synchronization happens about once per
  second and at checkpoints. A crash/power failure can still lose unsynced bytes.
- Startup recovers complete records from `.open` files and preserves a torn final
  record separately as `.partial`. It never pads missing audio or drops duplicate
  BLE packets silently. A malformed complete record fails visibly for inspection.
- Finalized chunks and retry schedules survive relaunch. Failed uploads back off
  from 2 seconds to a maximum of 256 seconds; the system may delay them further.
- Automatic uploads start disabled until configured. Pause them before changing
  settings. An already-submitted background upload may finish after pausing;
  pause does not cancel it. Changing the server routes all pending files there.
- Only one upload is submitted at a time. CoreBluetooth restoration and a background
  URLSession reconnect to system-owned work. iOS may delay transfers; a 30-second
  chunk does not promise 30-second server delivery.
- A foreground timer checkpoints even if notifications stall. In the background,
  packet callbacks also enforce the boundary; if suspended with no packets, a
  partial chunk may remain open until execution resumes.
- Queue storage is capped at approximately **1 GB**: capture stops visibly at the
  limit instead of deleting unacknowledged files. Storage protection permits work
  after the first unlock following reboot. Queue files are excluded from backups.
- The UI exposes current connection packet counts, bytes, sequence gaps, duplicate
  or short packets, queued chunks, storage use, last confirmed upload, and errors.
- Swiping the app away, expired signing, a powered-off phone, or Bluetooth loss can
  interrupt capture. Audio never received by the phone cannot be recovered by it.

## Validation

With Command Line Tools only:

```sh
ios/validate.sh
backend/.venv/bin/pytest backend/tests -q
```

`validate.sh` exercises actual Swift core code for exact byte preservation,
30-second boundaries, odd-sized payloads, duplicates, sequence rollover, crash
recovery, stable chunk IDs/checksums, acknowledgment checks, and retry persistence.
With Xcode selected, the equivalent XCTest suite runs via `swift test --package-path ios`.

After installing Xcode, build the complete app:

```sh
xcodebuild -project ios/RawGateway.xcodeproj -scheme RawGateway \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Physical acceptance checks (still required):
1. Close other BLE gateways; capture at least 65 seconds. Expect two completed
   roughly 30-second files and a final partial chunk on Stop.
2. Verify the server's downloaded file hash and packet bytes; listen only after
   server-side parsing/reassembly that handles gaps and split samples explicitly.
3. Disable Wi-Fi/cellular while leaving Bluetooth on, capture, restore internet,
   and verify the queue drains with one server row per chunk UUID.
4. Repeat a submitted file: confirm the same acknowledgment and row count.
5. Lock the phone for at least ten minutes; measure received duration, missing
   sequences, queue recovery, and upload latency. Repeat after Bluetooth loss.
6. Restart the app with a partially captured chunk and pending uploads. Confirm
   recovered files retain their IDs and successful retries do not duplicate rows.

The core tests cannot establish iPhone radio reliability, background survival,
provisioning/signing, or compatibility with your deployed server.

## Transport diagnostics (October 23)

Reports identify this app as **BLE transport 3**. The device card shows optional
`KTP1` live and previous-boot counters, and `KTR3` reset breadcrumbs. Current
counters are sampled every ten seconds while the app runs, logged, and included
in disconnect summaries and exported reports; previous counters are read once
per connection. Read failures are logged without tearing down audio. Older firmware
without these characteristics remains supported. Host TX completions are not
acknowledgements that the app stored the audio.

Install this app with Xcode Run after flashing the new UF2; no backend deployment
is needed for these Bluetooth/microphone fixes. Checkpoint format/timing is unchanged.
