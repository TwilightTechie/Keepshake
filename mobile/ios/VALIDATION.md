# Validation — 2026-10-16

Completed on this Mac:

- `mobile/ios/validate.sh`: PASS. Exercises the actual Swift core: exact packet bytes,
  30-second rollover, odd payload sizes, duplicate/short notifications, sequence
  rollover/gaps, recovery after a torn write, stable IDs/checksums across restart,
  strict acknowledgment matching, and persisted retry backoff.
- Backend test suite: **28 passed**, including 5 raw-upload tests for durable
  idempotency, conflicting content, authentication, checksum and envelope checks,
  size limits, byte-identical downloads, and deletion.
- Swift-produced JSONL uploaded twice through the Python ASGI endpoint using an
  in-memory database: **one row**, matching checksum, byte-identical download.
- Shared core, settings, uploader, and Bluetooth receiver: Swift compiler type-check
  passed against the installed macOS SDK. This is not an iOS SDK build.
- SwiftUI app source: compiler syntax parse passed (not full iOS type-check).
- Xcode project and Info.plist: `plutil` validation passed.
- Changed backend files: Ruff checks passed. `git diff --check` passed.
- Five-second BLE advertisement scan: no matching Keepsake/Omi/pendant found.
  No connection, recording, or firmware flashing was performed.

Not yet validated:

- Full Xcode/iOS build and signing. Xcode is absent; selected developer directory
  is `/Library/Developer/CommandLineTools`.
- XCTest runner (`swift test --package-path mobile/ios`): unavailable here because this
  toolchain installation lacks the XCTest module. The executable validation above
  runs without XCTest; the XCTest suite remains ready for full Xcode.
- iPhone pairing, actual notification cadence/MTU, locked-screen capture, background
  URLSession behavior, and network-loss recovery on the physical device.
- DigitalOcean deployment or end-to-end delivery to the user's server. Its URL and
  existing API contract have not yet been provided.

Source-inspected firmware contract: 100 ms blocks, 8 kHz transmitted PCM16,
5-byte packet header, up to 232 audio bytes per notification (MTU dependent).
The app preserves these received bytes. Existing firmware changes in the working
copy were left untouched.
