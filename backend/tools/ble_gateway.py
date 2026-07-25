#!/usr/bin/env python3
"""P0 bench gateway: receives Keepsake pendant BLE notifications on this Mac and
forwards complete utterances into the backend ingest WebSocket as WAV frames.

The pendant sends [seq:u32 LE][flags:u8][pcm16 @16k mono] per notification
(flags bit0 = utterance end). This buffers one utterance, wraps it in a WAV
header, and ships it as a single ingest frame — the backend pipeline is
identical to the simulator path, so nothing server-side changes.

Usage:
  pip install bleak websockets   (both in backend dev extras)
  .venv/bin/python tools/ble_gateway.py
  .venv/bin/python tools/ble_gateway.py --url ws://localhost:8100/v1/ingest/live
"""

import argparse
import asyncio
import base64
import io
import json
import struct
import sys
import wave
from datetime import UTC, datetime

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    sys.exit("pip install bleak   (.venv/bin/pip install bleak)")
try:
    import websockets
except ImportError:
    sys.exit("pip install websockets")

DEVICE_NAME = "Keepsake-P0"
AUDIO_CHAR = "6b656570-7361-6b65-0001-000000000002"
SAMPLE_RATE = 16000


def pcm_to_wav(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return buf.getvalue()


class Gateway:
    def __init__(self, ws_url: str, token: str, device_id: str) -> None:
        self.ws_url = ws_url
        self.token = token
        self.device_id = device_id
        self.buffer = bytearray()
        self.expected_seq: int | None = None
        self.dropped = 0
        self.ingest_seq = 0
        self.queue: asyncio.Queue[bytes] = asyncio.Queue()

    def on_notify(self, _char, data: bytearray) -> None:
        if len(data) < 5:
            return
        seq, flags = struct.unpack_from("<IB", data)
        if self.expected_seq is not None and seq != self.expected_seq:
            self.dropped += seq - self.expected_seq
            print(f"! gap: expected seq {self.expected_seq}, got {seq} "
                  f"(total dropped {self.dropped})")
        self.expected_seq = seq + 1
        self.buffer.extend(data[5:])
        if flags & 1 and self.buffer:
            pcm = bytes(self.buffer)
            self.buffer.clear()
            secs = len(pcm) / 2 / SAMPLE_RATE
            print(f"utterance complete: {secs:.1f}s ({len(pcm)} bytes)")
            self.queue.put_nowait(pcm)

    async def uplink(self) -> None:
        url = f"{self.ws_url}?token={self.token}"
        async with websockets.connect(url, max_size=16 * 1024 * 1024) as ws:
            await ws.send(json.dumps({
                "type": "hello", "device_id": self.device_id,
                "device_name": "Keepsake P0 (BLE gateway)",
            }))
            hello = json.loads(await ws.recv())
            assert hello.get("type") == "hello_ack", hello
            print(f"uplink connected: {self.ws_url}")
            while True:
                pcm = await self.queue.get()
                self.ingest_seq += 1
                await ws.send(json.dumps({
                    "type": "frame",
                    "seq": self.ingest_seq,
                    "captured_at": datetime.now(UTC).isoformat(),
                    "codec": "wav",
                    "utterance_end": True,
                    "audio_b64": base64.b64encode(pcm_to_wav(pcm)).decode(),
                }))
                ack = json.loads(await ws.recv())
                print(f"durable ack seq {ack.get('seq')} — pipeline will "
                      "transcribe + extract shortly")

    async def run(self) -> None:
        uplink_task = asyncio.create_task(self.uplink_forever())
        try:
            while True:
                print(f"scanning for '{DEVICE_NAME}'…")
                device = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=30)
                if device is None:
                    print("not found — pendant off or out of range; rescanning…")
                    continue
                print(f"found {device.address}, connecting…")
                try:
                    disconnected = asyncio.Event()
                    async with BleakClient(
                        device,
                        disconnected_callback=lambda _c, ev=disconnected: ev.set(),
                    ) as client:
                        await client.start_notify(AUDIO_CHAR, self.on_notify)
                        self.expected_seq = None  # pendant may have rebooted
                        self.buffer.clear()
                        print("subscribed to audio stream — speak near the pendant "
                              "(Ctrl+C to stop)")
                        await disconnected.wait()
                    print("pendant disconnected — rescanning…")
                except Exception as exc:  # noqa: BLE001 - keep the bench loop alive
                    print(f"BLE error: {exc} — rescanning in 3s…")
                    await asyncio.sleep(3)
        finally:
            uplink_task.cancel()

    async def uplink_forever(self) -> None:
        while True:
            try:
                await self.uplink()
            except Exception as exc:  # noqa: BLE001
                print(f"uplink error: {exc} — reconnecting in 3s…")
                await asyncio.sleep(3)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--url", default="ws://localhost:8100/v1/ingest/live")
    p.add_argument("--token", default="dev-token-change-me")
    p.add_argument("--device", default="keepsake-p0")
    args = p.parse_args()
    asyncio.run(Gateway(args.url, args.token, args.device).run())


if __name__ == "__main__":
    main()
