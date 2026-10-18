# Practical wearable path — October 16, 2026

Recommendation: keep the XIAO, use a phone as a durable BLE-to-internet relay,
and put transcripts, summaries and action items in a web UI. For an iPhone with
no developer membership budget, evaluate the published Omi app with compatible
DIY firmware before building an app. Do not replace firmware until that route
is selected. Our current custom BLE protocol is not automatically compatible.

## Reconnect diagnosis and change

The installed Zephyr 4.1 header explicitly states that BT_LE_ADV_OPT_CONN stops
advertising after connecting and recommends bt_conn_cb.recycled to restart it.
The firmware called bt_le_adv_start only in main. A recycled callback now submits
work to restart advertising. Build succeeded; hardware flash/reconnect testing
is outstanding. No firmware was flashed during this investigation.

## Storage arithmetic

Assuming mono audio, continuous recording, decimal MB, excluding metadata:

| Format | MB/hour | MB/16-hour day | Duration in 2 MB |
|---|---:|---:|---:|
| Current PCM16 at 8 kHz, 128 kbps | 57.6 | 921.6 | 125 seconds |
| Proposed Opus at 16 kbps | 7.2 | 115.2 | 16.7 minutes |
| Proposed Opus at 32 kbps | 14.4 | 230.4 | 8.3 minutes |

Compression figures are target bitrate calculations, not measured codec quality
or battery results. Onboard 256 KB RAM and 1 MB internal flash are also needed by
the firmware. The current build uses 145,498 bytes of RAM. It has no persistent
audio journal and drops audio when no client subscribes. Adding storage requires
firmware work, not just attaching a battery. 256 MB external storage or microSD
is a more comfortable starting point for a full compressed waking day than 2 MB.

## Proposed custom architecture

Pendant captures and journals sequenced audio, then transfers small chunks over
a maintained BLE connection. Phone acknowledges only after saving locally;
pendant reclaims acknowledged data. Phone retains files through network outages,
uploads opportunistically around 10–20 minutes, and removes files only after
server confirmation. Server deduplicates by session/chunk ID, transcribes speech
with automatic language detection, then builds conversation and daily summaries.
Use a daily job for the final recap. Put all review UI on the web.

The phone is the BLE central: it scans/connects/subscribes. The pendant advertises
when available. Auto reconnect needs both ends; firmware alone cannot force an
iPhone to run an app. Persist session IDs/sequence numbers across reconnects and
reboots. The current gateway resets ingest sequences at each launch, so it is a
bench tool rather than a durable all-day relay.

A custom phone relay needs only device selection, recording/mute status, battery,
queued audio count, and reconnect/upload logic. iOS requires native CoreBluetooth
background support and state restoration; Android needs a supported background
connection strategy such as a connected-device foreground service. Exact periodic
background execution is not guaranteed. Test screen lock, process termination,
Bluetooth toggles, range loss, no internet and phone restarts.

## Existing-app option

Omi's DIY DevKit 1 uses this exact XIAO nRF52840 Sense board. The published iOS
app avoids personal App Store publishing fees. Its Developer Mode exposes raw
audio delivery to a custom webhook at configurable intervals; use the supplied
sample_rate, not a hardcoded 8 kHz assumption. It also documents custom STT
WebSocket services and memory/day-summary integrations.

This is an integration candidate, not a verified drop-in replacement. Confirm
current app/DIY firmware compatibility, locked-screen operation, webhook plan
availability, cloud routing and retry behavior before relying on it. The docs
explicitly say raw audio webhooks require active live listening and do not replay
historical/store-and-forward uploads. They are not a documented lossless offline
delivery queue. Public pricing advertises a free tier with limited cloud minutes;
do not assume unlimited cloud processing or custom integrations are cost-free.

## Battery and cost

Measure current while recording + encoding + transmitting; deep sleep current
does not estimate microphone-on runtime. Ideal runtime is capacity_mAh/current_mA;
allow margin for actual usable capacity and conversion losses. A 500 mAh battery
at a measured 20 mA would be 25 hours ideal, not a claim about this board.

Evaluate Opus, longer BLE connection intervals and slower disconnected advertising
after an initial fast period. Keep a small journal for reconnects. Batching server
uploads saves phone network wakeups but does not reduce pendant microphone energy.
Avoid repeated disconnect/reconnect purely to batch data. Voice detection before
paid STT can reduce billed duration; delaying the same audio does not inherently
make it cheaper. Do not aggressively discard quiet speech before quality testing.

For a no-phone design, add ample storage and sync at home; this board has no Wi-Fi
or cellular. Switching to Wi-Fi hardware adds hotspot/radio/power complexity.
For an all-day wearable, add a visible recording indicator and accessible mute,
and secure stored audio and the BLE link before routine use.

## Sources

- Board memory/radio: https://wiki.seeedstudio.com/XIAO_BLE/
- Same-board DIY: https://docs.omi.me/doc/assembly/Buying_Guide
- Published iOS app: https://apps.apple.com/us/app/omi-smart-meeting-notes/id6502156163
- Audio forwarding: https://docs.omi.me/doc/developer/AudioStreaming
- Webhook limits: https://docs.omi.me/doc/developer/apps/Integrations
- Custom STT: https://docs.omi.me/doc/developer/backend/transcription
- Omi pricing: https://www.omi.me/pages/pricing
- Apple free development limits: https://developer.apple.com/help/account/basics/about-your-developer-account
- Apple membership: https://developer.apple.com/help/account/membership/program-enrollment/
- iOS background BLE: https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html
- Android background BLE: https://developer.android.com/develop/connectivity/bluetooth/ble/background
- Browser BLE: https://developer.chrome.com/docs/capabilities/bluetooth
