#!/usr/bin/env python3
"""Record Omi DevKit 1 audio directly on this Mac, without the phone app or server."""

import argparse
import asyncio
from array import array
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import struct
import sys
import time
import wave

from bleak import BleakClient, BleakScanner


SERVICE = "19b10000-e8f2-537e-4f6c-d104768a1214"
AUDIO = "19b10001-e8f2-537e-4f6c-d104768a1214"
CODEC = "19b10002-e8f2-537e-4f6c-d104768a1214"
CODECS = {0: ("PCM16", 16000), 1: ("PCM16", 8000),
          10: ("mu-law", 16000), 11: ("mu-law", 8000),
          20: ("Opus", 16000)}


def decode_mulaw(data):
    out = array("h")
    for byte in data:
        value = (~byte) & 0xff
        magnitude = ((value & 15) << 3) + 132
        magnitude <<= (value >> 4) & 7
        out.append((132 - magnitude) if value & 128 else (magnitude - 132))
    if sys.byteorder != "little":
        out.byteswap()
    return out.tobytes()


class Capture:
    def __init__(self, wav, codec):
        self.wav = wav
        self.codec = codec
        self.decoder = None
        if codec == 20:
            from opuslib import Decoder
            self.decoder = Decoder(16000, 1)
        self.current = bytearray()
        self.notifications = 0
        self.frames = 0
        self.samples = 0
        self.missing = 0
        self.decode_errors = 0
        self.malformed = 0
        self.last_sequence = None
        self.level_energy = 0
        self.level_samples = 0
        self.peak = 0
        self.started = time.monotonic()

    def finish_frame(self):
        if not self.current:
            return
        frame = bytes(self.current)
        self.current.clear()
        try:
            if self.codec == 20:
                pcm = self.decoder.decode(frame, 960, decode_fec=False)
            elif self.codec in (10, 11):
                pcm = decode_mulaw(frame)
            else:
                pcm = frame
            if len(pcm) % 2:
                raise ValueError("odd PCM byte count")
        except Exception:
            self.decode_errors += 1
            return
        self.wav.writeframesraw(pcm)
        samples = array("h")
        samples.frombytes(pcm)
        if sys.byteorder != "little":
            samples.byteswap()
        self.frames += 1
        self.samples += len(samples)
        self.level_samples += len(samples)
        self.level_energy += sum(value * value for value in samples)
        self.peak = max(self.peak, max((abs(value) for value in samples), default=0))

    def notify(self, _characteristic, value):
        if len(value) <= 3:
            self.malformed += 1
            return
        sequence = struct.unpack_from("<H", value)[0]
        index = value[2]
        if self.last_sequence is not None:
            gap = (sequence - self.last_sequence - 1) & 0xffff
            if 0 < gap < 0x8000:
                self.missing += gap
        self.last_sequence = sequence
        self.notifications += 1
        if index == 0:
            self.finish_frame()
        elif not self.current:
            self.malformed += 1
        self.current.extend(value[3:])

    def print_progress(self):
        rms = math.sqrt(self.level_energy / self.level_samples) if self.level_samples else 0
        seconds = self.samples / CODECS[self.codec][1]
        print(f"{time.monotonic() - self.started:5.1f}s | "
              f"{self.notifications} notifications | {seconds:.1f}s audio | "
              f"RMS {rms:.0f} | peak {self.peak} | gaps {self.missing}", flush=True)
        self.level_energy = self.level_samples = self.peak = 0


async def find_omi(scan_seconds):
    def matches(device, advertisement):
        name = (advertisement.local_name or device.name or "").lower()
        services = [uuid.lower() for uuid in advertisement.service_uuids]
        return SERVICE in services or name.startswith(("omi", "friend"))

    return await BleakScanner.find_device_by_filter(matches, timeout=scan_seconds)


async def run(args):
    print(f"Scanning for Omi/Friend for up to {args.scan_seconds:.0f}s...", flush=True)
    device = await find_omi(args.scan_seconds)
    if device is None:
        print("No Omi device found. Disconnect it in the phone app (or temporarily "
              "turn off phone Bluetooth), ensure the pendant is on, then retry.")
        return 1
    print(f"Found {device.name or 'Omi device'}; connecting...", flush=True)
    output = Path(args.output).expanduser().resolve() / datetime.now(timezone.utc).strftime("omi_%Y%m%dT%H%M%SZ")
    output.mkdir(parents=True, exist_ok=True)
    stopped = asyncio.Event()
    disconnected = asyncio.Event()
    error = None
    capture = None
    codec = None
    try:
        async with BleakClient(device, disconnected_callback=lambda _: disconnected.set(), timeout=20) as client:
            try:
                revision = (await client.read_gatt_char("00002a26-0000-1000-8000-00805f9b34fb")).decode(errors="replace")
                print(f"Firmware: {revision}", flush=True)
            except Exception:
                pass
            codec_data = await client.read_gatt_char(CODEC)
            codec = codec_data[0]
            if codec not in CODECS:
                raise RuntimeError(f"Unsupported Omi codec ID {codec}; please share this value.")
            kind, rate = CODECS[codec]
            print(f"Audio: {kind}, {rate} Hz", flush=True)
            with wave.open(str(output / "audio.wav"), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(rate)
                capture = Capture(wav, codec)
                await client.start_notify(AUDIO, capture.notify)
                loop = asyncio.get_running_loop()
                if sys.stdin.isatty():
                    loop.add_reader(sys.stdin, stopped.set)
                try:
                    print("Recording. Speak near the pendant; press Enter to stop.", flush=True)
                    deadline = time.monotonic() + args.seconds
                    while not stopped.is_set() and not disconnected.is_set() and time.monotonic() < deadline:
                        await asyncio.sleep(1)
                        capture.print_progress()
                    if disconnected.is_set():
                        error = "BLE disconnected during recording"
                    if client.is_connected:
                        await client.stop_notify(AUDIO)
                    capture.finish_frame()
                finally:
                    if sys.stdin.isatty():
                        loop.remove_reader(sys.stdin)
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
    report = {"codec_id": codec, "notifications": capture.notifications if capture else 0,
              "decoded_frames": capture.frames if capture else 0,
              "audio_seconds": round(capture.samples / CODECS[codec][1], 2) if capture and codec in CODECS else 0,
              "missing_notifications": capture.missing if capture else 0,
              "decode_errors": capture.decode_errors if capture else 0,
              "malformed_notifications": capture.malformed if capture else 0,
              "error": error}
    if args.transcribe and capture and capture.samples:
        key = os.environ.get("SARVAM_API_KEY") or os.environ.get("KEEPSAKE_SARVAM_API_KEY")
        if not key:
            report["transcription_error"] = "SARVAM_API_KEY is not loaded; run source ~/.zshrc first"
        else:
            import httpx
            print("Transcribing the saved recording with Saaras v4...", flush=True)
            try:
                audio = (output / "audio.wav").read_bytes()
                async with httpx.AsyncClient(timeout=120) as client:
                    response = await client.post(
                        "https://api.sarvam.ai/speech-to-text",
                        headers={"Api-Subscription-Key": key},
                        data={"model": "saaras:v4", "mode": "transcribe", "language_code": "unknown"},
                        files={"file": ("audio.wav", audio, "audio/wav")},
                    )
                result = response.json()
                if response.is_success:
                    report["transcript"] = result.get("transcript", "")
                    print("TRANSCRIPT:", report["transcript"], flush=True)
                else:
                    report["transcription_error"] = f"Sarvam HTTP {response.status_code}: {str(result)[:300]}"
            except Exception as exc:
                report["transcription_error"] = f"{type(exc).__name__}: {str(exc).replace(key, '[REDACTED]')[:300]}"
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)
    print(f"Saved: {output / 'audio.wav'}", flush=True)
    return 0 if capture and capture.samples and not error and not report.get("transcription_error") else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=30, help="Maximum recording duration (default: 30)")
    parser.add_argument("--scan-seconds", type=float, default=45, help="Bluetooth scan timeout (default: 45)")
    parser.add_argument("--output", default=str(Path(__file__).parent / "recordings"), help="Output directory")
    parser.add_argument("--transcribe", action="store_true", help="Transcribe the saved WAV with Sarvam Saaras v4")
    args = parser.parse_args()
    if args.seconds <= 0 or args.scan_seconds <= 0:
        parser.error("durations must be positive")
    if args.transcribe and args.seconds > 30:
        parser.error("--transcribe supports recordings of at most 30 seconds")
    try:
        raise SystemExit(asyncio.run(run(args)))
    except KeyboardInterrupt:
        print("Cancelled.")
        raise SystemExit(130)
