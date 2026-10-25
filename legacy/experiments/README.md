# Standalone pendant test

## Dream AI server speech gate

`omi_server.py` now uses the bundled Silero VAD ONNX model on the server before
calling Saaras. Install `requirements.txt` in the server's Python environment and
restart the server. The model stays in `models/silero_vad.onnx`; it is never loaded
by the iOS app or firmware.

The server drops segments with no detected speech, trims leading/trailing nonspeech,
and applies mild spectral noise reduction when a nonspeech noise profile is available.
The original live packet handling and 30-second checkpoint upload, durable acknowledgment,
segment IDs, and archive are unchanged. The authenticated
`GET /dream-ai/api/vad/diagnostics` endpoint returns process-lifetime counts and
recent decisions without audio or transcript content. It uses the same bearer token
as the audio webhook. Counters reset on server restart.

## Speak and see transcripts in your terminal

```sh
cd /Users/anup_mini/code/AI_Pendant
source ~/.zshrc
backend/.venv/bin/python 'new testing/live_transcribe.py'
```

No app or backend is needed. Wait for `RECORDING`, then speak. The script streams
100 ms frames of original 8 kHz PCM16 over Sarvam's realtime WebSocket endpoint,
using Saaras v4, `language_code=auto`, and `stream_type=fast`. Each `partial` line
is the latest evolving hypothesis, not additional words to append. `FINAL` lines
are completed utterances and are saved to `transcript.txt`.

Default mode is `transcribe` (spoken-language output). Add `--mode codemix` for
mixed-language final output, or `--stream-type balanced` for the alternative
latency/accuracy tradeoff. Sarvam detects speech boundaries on the server.

Press **Enter** to stop recording, send remaining audio and the `end` event,
and wait for the final events and `session.end` before `Completed`. Ctrl+C
cancels immediately. WAV audio, raw server events, final transcripts, and a report
are saved under `recordings/stream_...`. If the pendant isn't found, unplug and
reconnect it, then retry. Close other gateways first.

To verify the streaming API without connecting the pendant, replay an existing
8 kHz mono PCM16 WAV in real time using `--wav 'path/to/recording.wav'`. Replay
stops automatically at EOF. It uses the same send/receive path as live capture.

Protocol: https://docs.sarvam.ai/api/api-guides-tutorials/speech-to-text/realtime-streaming

The existing backend virtual environment already contains the dependencies.
For a separate environment, install this directory's `requirements.txt`.

Run from the repository root using the existing environment:

```sh
backend/.venv/bin/python 'new testing/test_device.py' --seconds 30
```

Or create a separate environment and install `requirements.txt` in this directory.
Disconnect other BLE gateways first. Keep Bluetooth enabled and the pendant powered.
Speak a known sentence near the pendant while `RECORDING` is displayed.
For a longer bench test, use `--seconds 120`; repeat to test reconnection.

Each run creates a timestamped directory under `recordings/` containing:

- `raw_8khz.wav`: original received PCM, wrapped in a mono 16-bit 8 kHz WAV.
- `audio.pcm`: original accepted payload bytes without a WAV header.
- `packets.jsonl`: notification timing, sequence, flags, and full payload hex.
- `report.json`: packet loss, duplicates, stalls, duration, DC bias, AC RMS and clipping.

No backend, VAD, gain adjustment, resampling, or Sarvam call is involved. Audio stays
local, and recordings are git-ignored. Delete recordings when no longer needed.
The format comes from the checked-in firmware; the BLE protocol does not advertise
its format or firmware version. Reassess if a different firmware is flashed.

`PASS` means the short capture passed basic transport/level checks. It does not prove
speech intelligibility or long-term reliability. Listen to the WAV and compare with
your spoken sentence before testing transcription. Missing packets are not replaced
with silence, so a lossy WAV may be shorter or have sample alignment errors. Firmware
queue drops happen before sequence assignment: compare wall time with audio duration
as well as packet counters. Packet logs preserve bytes for further investigation.

The microphone captures at 16 kHz, and the current firmware averages adjacent samples
to transmit at 8 kHz. Samples remain 16-bit throughout; there is no codec compression.
The updated backend sends native 8 kHz WAV audio to Saaras v4. Upsampling
does not restore frequencies lost in the firmware's downsampling.

Exit status is zero when basic checks pass and one when checks need attention.

## Sarvam comparison

With `SARVAM_API_KEY` (or `KEEPSAKE_SARVAM_API_KEY`) exported, run from the repo root:

```sh
backend/.venv/bin/python 'new testing/transcribe_recording.py' 'path/to/recording.wav'
```

This uploads the selected audio twice to Sarvam: the original WAV, then a version
resampled by the existing backend helper. It defaults to `saaras:v4` in `transcribe`
mode with automatic language detection. Override with `--model` or `--mode`.
Use mono PCM16 WAV files up to 30 seconds. Responses, transcripts, input WAVs,
request timings, and source hash are saved in a timestamped folder beside the WAV.
No API key is saved. This script needs `httpx` and this repository's `backend/app/audio.py`.
The comparison changes sample rate only; no gain adjustment or VAD is applied.
Assess accuracy against the words actually spoken, not agreement between outputs.

## Live backend bench test

From the repository root, with `SARVAM_API_KEY` exported:

```sh
backend/.venv/bin/python 'new testing/run_backend.py'
```

This runs the actual API and pipeline on localhost:8100 with a separate SQLite
database in `recordings/live_backend/bench.db`, live Saaras v4 STT, and mock LLM
extraction. It does not test Postgres deployment or live LLM summaries. Audio is
discarded after transcription; transcripts persist in the local test database.
In another terminal, start the gateway with a fresh session ID:

```sh
backend/.venv/bin/python backend/tools/ble_gateway.py --device "bench-$(date +%s)"
```

Speak near the pendant and pause for segmentation. Read `/v1/conversations`
and `/v1/conversations/{id}` with bearer token `dev-token-change-me`. This bench
server binds to loopback only. Stop the gateway and server with Ctrl+C afterward.
# Direct Omi DevKit 1 capture on Mac

The Keepsake scripts below do not read Omi firmware. For the XIAO nRF52840 Sense
running Omi DevKit 1 firmware, first disconnect the pendant in the Omi phone app
(or temporarily turn off Bluetooth on the phone). Then run:

```sh
cd /Users/anup_mini/code/AI_Pendant
backend/.venv/bin/python 'new testing/omi_direct_capture.py'
```

Speak near the pendant. The terminal prints BLE notification counts and audio
levels each second. Press Enter to stop, or let the 30-second timer finish.
The test saves `audio.wav` and `report.json` under `new testing/recordings/omi_...`.
Add `--transcribe` and run `source ~/.zshrc` first to print a Saaras v4 transcript
of the captured WAV after recording stops.
It uses `bleak`, `opuslib`, and the `libopus` system library. On a fresh Mac,
install the latter with `brew install opus` and install Python packages from
`new testing/requirements.txt`.
