#!/usr/bin/env python3
"""Local-only BLE capture: no VAD, processing, backend, or API key."""
import argparse
import asyncio
from collections import Counter
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import struct
import time
import wave

NAME = "Keepsake-P0"
CHAR = "6b656570-7361-6b65-0001-000000000002"
RATE = 8000  # firmware/app/src/main.c: PCM16, 16 kHz / DECIMATE=2


class Capture:
    def __init__(self, folder):
        self.pcm = bytearray()
        self.expected = None
        self.packets = self.missing = self.reordered = self.malformed = 0
        self.sizes = Counter()
        self.last = None
        self.max_gap = 0.0
        self.started = time.monotonic()
        self.log = (folder / "packets.jsonl").open("w")

    def notify(self, _char, data):
        now = time.monotonic()
        if self.last is not None:
            self.max_gap = max(self.max_gap, now - self.last)
        self.last = now
        if len(data) <= 5:
            self.malformed += 1
            self.log.write(json.dumps({"t": now-self.started, "malformed_hex": data.hex()}) + "\n")
            return
        seq, flags = struct.unpack_from("<IB", data)
        payload = bytes(data[5:])
        delta = 0 if self.expected is None else (seq-self.expected) & 0xffffffff
        accepted = delta < 0x80000000
        if accepted:
            self.missing += delta
            self.expected = (seq+1) & 0xffffffff
            self.pcm.extend(payload)
        else:
            self.reordered += 1
        self.packets += 1
        self.sizes[len(payload)] += 1
        self.log.write(json.dumps({"t": round(now-self.started, 6), "seq": seq,
                                   "flags": flags, "accepted": accepted,
                                   "payload_hex": payload.hex()}) + "\n")

    def save(self, folder, elapsed, error, disconnected):
        self.log.close()
        raw = bytes(self.pcm)
        (folder / "audio.pcm").write_bytes(raw)
        aligned = raw[:len(raw)//2*2]
        samples = [s[0] for s in struct.iter_unpack("<h", aligned)]
        count = len(samples)
        mean = sum(samples)/count if count else 0
        ac_rms = math.sqrt(sum((s-mean)**2 for s in samples)/count) if count else 0
        with wave.open(str(folder / "raw_8khz.wav"), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(RATE)
            wav.writeframes(aligned)
        ratio = count / RATE / elapsed if elapsed else 0
        warnings = []
        if not count: warnings.append("No audio received")
        if self.missing: warnings.append("Missing packets: WAV joins received bytes without filling gaps; timing/alignment may be affected")
        if self.reordered: warnings.append("Duplicate/out-of-order packets excluded from WAV")
        if self.malformed or len(raw)%2: warnings.append("Malformed packets or incomplete PCM sample")
        if not 0.95 <= ratio <= 1.05: warnings.append("Audio duration differs from capture time by more than 5%")
        if ac_rms < 10: warnings.append("Very low audio level; microphone/speech needs verification")
        if self.max_gap > 1: warnings.append("Notification stall exceeded one second")
        if disconnected: warnings.append("Device disconnected during capture")
        if error: warnings.append(error)
        report = dict(sample_rate_hz=RATE, sample_width_bits=16, channels=1,
                      encoding="signed little-endian PCM, uncompressed",
                      wall_seconds=round(elapsed, 3), audio_seconds=count/RATE,
                      received_packets=self.packets, missing_packets=self.missing,
                      duplicate_or_out_of_order=self.reordered, malformed_packets=self.malformed,
                      payload_sizes=dict(self.sizes), max_notification_gap_seconds=round(self.max_gap, 3),
                      dc_offset=round(mean, 2), ac_rms=round(ac_rms, 2),
                      peak=max((abs(s) for s in samples), default=0),
                      clipped_samples=sum(s in (-32768, 32767) for s in samples),
                      warnings=warnings, transport_check="PASS" if not warnings else "CHECK",
                      limitation="Short bench test only; listening and spoken reference are required to assess intelligibility. Firmware queue losses can occur before packet sequence assignment.")
        (folder / "report.json").write_text(json.dumps(report, indent=2)+"\n")
        print(json.dumps(report, indent=2), flush=True)
        print(f"Saved: {folder}", flush=True)
        return not warnings


async def run(args):
    from bleak import BleakClient, BleakScanner
    folder = Path(args.output).resolve() / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    folder.mkdir(parents=True)
    print(f"Scanning for {args.name} (up to {args.scan_timeout}s)...", flush=True)
    device = await BleakScanner.find_device_by_name(args.name, timeout=args.scan_timeout)
    if device is None:
        (folder / "report.json").write_text(json.dumps({"transport_check": "FAIL", "error": "Device not found"}, indent=2))
        print(f"Device not found. Check power/Bluetooth and disconnect other gateways. Report: {folder}")
        return False
    print(f"Found {device.name}: {device.address}", flush=True)
    capture = Capture(folder)
    disconnected = asyncio.Event()
    error = None
    elapsed = 0.0
    ended_early = False
    try:
        async with BleakClient(device, disconnected_callback=lambda _: disconnected.set()) as client:
            capture.started = time.monotonic()
            await client.start_notify(CHAR, capture.notify)
            print(f"RECORDING {args.seconds}s — speak near the pendant. Saving raw local audio.", flush=True)
            deadline = capture.started + args.seconds
            while time.monotonic() < deadline and not disconnected.is_set():
                await asyncio.sleep(min(5, max(0, deadline-time.monotonic())))
                print(f"{time.monotonic()-capture.started:.1f}s: {capture.packets} packets, "
                      f"{len(capture.pcm)/2/RATE:.2f}s audio, {capture.missing} missing", flush=True)
            elapsed = time.monotonic()-capture.started
            ended_early = disconnected.is_set()
            if client.is_connected:
                await client.stop_notify(CHAR)
    except Exception as exc:
        elapsed = time.monotonic()-capture.started
        error = f"{type(exc).__name__}: {exc}"
    return capture.save(folder, elapsed, error, ended_early)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default=NAME)
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--scan-timeout", type=float, default=20)
    parser.add_argument("--output", default=str(Path(__file__).parent / "recordings"))
    args = parser.parse_args()
    if not 0 < args.seconds <= 600 or args.scan_timeout <= 0:
        parser.error("seconds must be between 0 and 600; scan-timeout must be positive")
    raise SystemExit(0 if asyncio.run(run(args)) else 1)
