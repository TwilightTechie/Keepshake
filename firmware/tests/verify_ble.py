#!/usr/bin/env python3
"""Hardware acceptance: exact bytes, format handshake, repeated clean reconnect.
Run after flashing. Uses the backend venv's bleak; never flashes hardware.
"""
import argparse
import asyncio
import base64
import json
from pathlib import Path
import struct
import time

from bleak import BleakClient, BleakScanner

SERVICE = "6b656570-7361-6b65-0001-000000000001"
AUDIO = "6b656570-7361-6b65-0001-000000000002"
INFO = "6b656570-7361-6b65-0001-000000000003"
STATUS = "6b656570-7361-6b65-0001-000000000004"


async def run(args):
    args.output.mkdir(parents=True, exist_ok=True)
    reports = []
    for cycle in range(args.cycles):
        device = await BleakScanner.find_device_by_filter(
            lambda d, a: SERVICE in a.service_uuids, timeout=20
        )
        if device is None:
            raise RuntimeError("Keepsake not advertising; power/flash must be verified")
        async with BleakClient(device) as client:
            info = bytes(await client.read_gatt_char(INFO))
            if len(info) != 20 or info[:4] != b"KSR1" or info[4:16] != bytes.fromhex("803e00006400011005010000"):
                raise RuntimeError(f"Unexpected firmware descriptor: {info.hex()}")
            stats = dict(packets=0, audio_bytes=0, gaps=0, duplicate_or_old=0, short=0)
            expected = None
            start = time.monotonic()
            path = args.output / f"cycle-{cycle + 1}-{time.time_ns()}.jsonl"
            with path.open("w") as output:
                output.write(json.dumps({"stream_info_b64": base64.b64encode(info).decode()}) + "\n")

                def notify(_, data):
                    nonlocal expected
                    output.write(json.dumps({"elapsed": time.monotonic() - start,
                                             "packet_b64": base64.b64encode(data).decode()}) + "\n")
                    stats["packets"] += 1
                    if len(data) <= 5:
                        stats["short"] += 1
                        return
                    seq = struct.unpack_from("<I", data)[0]
                    delta = 0 if expected is None else (seq - expected) & 0xffffffff
                    if delta >= 0x80000000:
                        stats["duplicate_or_old"] += 1
                        return
                    stats["gaps"] += delta
                    expected = (seq + 1) & 0xffffffff
                    stats["audio_bytes"] += len(data) - 5

                await client.start_notify(AUDIO, notify)
                start = time.monotonic()
                await asyncio.sleep(args.seconds)
                await client.stop_notify(AUDIO)
                elapsed = time.monotonic() - start
            status = bytes(await client.read_gatt_char(STATUS))
            report = {"cycle": cycle + 1, "wall_seconds": elapsed,
                      "received_audio_seconds": stats["audio_bytes"] / 32000,
                      "stream_info_hex": info.hex(), "status_hex": status.hex(), **stats}
            report["pass"] = (stats["gaps"] == 0 and stats["short"] == 0 and
                              stats["duplicate_or_old"] == 0 and
                              abs(report["received_audio_seconds"] - elapsed) < 0.5)
            reports.append(report)
            print(json.dumps(report), flush=True)
        await asyncio.sleep(2)  # connection objects recycled, then scan without reset
    (args.output / "report.json").write_text(json.dumps(reports, indent=2))
    if not all(r["pass"] for r in reports):
        raise RuntimeError("Transport check failed; retain raw logs and investigate before daily use")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--cycles", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    asyncio.run(run(parser.parse_args()))
