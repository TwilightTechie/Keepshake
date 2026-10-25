# Keepshake

Keepshake is an open-source, screenless wristband and iPhone companion. A first
3D-printed wearable prototype is now assembled and being worn. Its firmware sends
raw audio over Bluetooth Low Energy to a native iPhone app, which archives the
incoming data and uploads it with retries. The personal memory and assistant
experience is the next product layer; the current raw capture path does not yet
deliver the full memory interface shown in the [site preview](https://keepshake-band.pages.dev/).
Some firmware and app identifiers still use the earlier Keepsake name.

## Repository layout

| Directory | Contents |
| --- | --- |
| [`firmware/`](firmware/README.md) | Zephyr firmware for the Seeed XIAO nRF52840 Sense |
| [`mobile/ios/`](mobile/ios/README.md) | Native Swift iPhone app, BLE capture, chunk archive, retrying uploads |
| [`backend/`](backend/README.md) | Optional self-hosted FastAPI backend and raw chunk ingestion API |
| [`server/`](server/README.md) | Current webhook, live speech and Keepsake Create service |
| [`docs/`](docs/) | BLE protocol and hardware/project notes |
| [`hardware/cad/`](hardware/cad/README.md) | V1 enclosure STEP exports: top lid and two tub variants |
| [`website/`](website/README.md) | Static project website |
| [`legacy/`](legacy/) | Retired prototypes and experiments kept for reference |

The firmware and iPhone app form the current pendant capture path. `backend/`
and `server/` are separate server implementations with different endpoints; choose
the one that matches the upload mode configured in the app. Neither server is
required to build or install the iPhone app.

## Quick start

1. Follow [`firmware/README.md`](firmware/README.md) to install Zephyr dependencies,
   build and flash the pendant.
2. Open `mobile/ios/RawGateway.xcodeproj` in Xcode and follow
   [`mobile/ios/README.md`](mobile/ios/README.md) to sign and install on an iPhone.
3. Configure an HTTPS server URL and its bearer token in the app. See the server
   README for the matching upload contract and deployment configuration.

## Audio and delivery behavior

The current firmware captures 16 kHz mono PCM16 and sends framed BLE notifications.
The app preserves every received notification and stores checkpoint files locally.
Delivery mode controls live upload, checkpoint upload, or archive-only capture.
Uploads use stable chunk IDs, checksums, durable acknowledgments, and retry after
network failure. The local queue is retained until the configured server confirms
storage. Firmware BLE packets are transient: radio loss can create sequence gaps;
the phone cannot recover samples it never received.

## Security and privacy

- Do not commit `.env` files, API keys, bearer tokens, private keys, recordings,
  transcripts, or database files. Use each service's environment variables or the
  app's Keychain-backed settings.
- The app requires HTTPS for uploads and keeps incomplete or unacknowledged chunks
  on-device for retry.
- Audio and derived data are sensitive. Review server retention, access control,
  backups, and deletion policies before exposing a server publicly.
- Historical sample recordings and transcripts were removed from the current
  source tree. Git history may still contain previously committed data; see the
  repository history note below.

## Validation

From the repository root:

```sh
python3 firmware/tests/run_host_tests.py
```

The firmware README documents hardware validation. The iOS app includes a Swift
package validation script and Xcode project; a physical iPhone is required to
validate BLE capture and background upload behavior.

## Repository history

This repository has existing public Git history. Removing a file from the current
tree does not erase earlier commits. If you find a real credential in old history,
revoke it first, then coordinate history rewriting before using `git filter-repo`
and force-pushing; this can disrupt existing clones. No active API keys or private
keys were found in the repository history during the current scan.

## License

See individual components for their licenses. Firmware and software licensing
should be finalized before redistribution; this repository currently contains
third-party model assets with their own license notices.
