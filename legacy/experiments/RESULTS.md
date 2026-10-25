# Initial bench results

Tested October 16, 2026 (Asia/Kolkata). Recording directory names use UTC.

- First BLE capture: PASS. 30.001 seconds elapsed, 29.9 seconds received audio,
  2,093 packets, zero sequence gaps, duplicates, malformed packets or clipped
  samples. Maximum notification gap: 0.118 seconds. AC RMS: 1970.27.
- Second connection attempt: FAIL. Device not found during a 20-second scan
  immediately following the first capture's clean disconnect.
- USB logs showed the microphone continuing to run with notifications off,
  sequence counter 2093 and zero firmware queue drops in the observed log.
  This supports investigating BLE reconnection/advertising next; it does not
  establish the root cause of the failed scan.
- Backend: nothing listening at localhost:8100. Existing automated tests:
  21 passed. Live backend ingest and Sarvam transcription were not tested.
- Diagnostic parser checks passed for byte preservation, WAV metadata,
  sequence rollover, missing packets, duplicates and malformed packets.

The initial stream is healthy by these measurements. Overall reliability is
not established because discovery after disconnect failed. A power-cycle and
repeat capture are the next bench step. Listen to `raw_8khz.wav` and compare
against a known spoken sentence before drawing conclusions about STT quality.
No firmware or existing backend code was changed.
