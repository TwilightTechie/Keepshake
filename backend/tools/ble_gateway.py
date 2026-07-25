#!/usr/bin/env python3
"""P0 bench gateway: receives the Keepsake pendant's continuous BLE audio stream,
segments it into utterances here (not on the pendant), and forwards each one to
the backend ingest WebSocket as a WAV frame.

The pendant streams [seq:u32 LE][flags:u8][pcm16 @8k mono] continuously while
subscribed — it makes no speech/silence decisions. Segmentation lives here
because it is observable (live meter below) and tunable without a reflash;
on-device VAD gating cost us hours of silent failures on the bench.

Usage:
  .venv/bin/python tools/ble_gateway.py            # live meter + auto-calibrating VAD
  .venv/bin/python tools/ble_gateway.py --quiet    # no meter
  .venv/bin/python tools/ble_gateway.py --vad-ratio 2.0 --hangover 1.5

The meter line shows: energy | noise floor | threshold | state. If speech never
triggers, lower --vad-ratio; if it never closes, raise it.
"""

import argparse
import asyncio
import base64
import io
import json
import struct
import sys
import time
import wave
from array import array
from collections import deque
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
SAMPLE_RATE = 8000  # firmware decimates 2:1 on-air until Opus lands (P1)


FRAME_MS = 20
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000
FRAME_BYTES = FRAME_SAMPLES * 2


class Segmenter:
    """Energy VAD with an adaptive noise floor, pre-roll, and hangover.

    Mirrors what used to run on the pendant, but here we can watch it work and
    change its numbers without reflashing.
    """

    def __init__(self, *, ratio: float, floor_min: float, hangover_s: float,
                 min_utt_s: float, max_utt_s: float, preroll_s: float) -> None:
        self.ratio = ratio
        self.floor_min = floor_min
        self.hangover_frames = int(hangover_s * 1000 / FRAME_MS)
        self.min_bytes = int(min_utt_s * SAMPLE_RATE) * 2
        self.max_bytes = int(max_utt_s * SAMPLE_RATE) * 2
        self.preroll_frames = int(preroll_s * 1000 / FRAME_MS)

        self.pending = bytearray()          # bytes not yet split into frames
        self.preroll: deque[bytes] = deque(maxlen=self.preroll_frames)
        self.speech = bytearray()
        self.in_speech = False
        self.silence_run = 0
        self.floor: float | None = None
        self.energy = 0.0
        self.threshold = 0.0

    @staticmethod
    def _energy(frame: bytes) -> float:
        """Mean absolute deviation from the frame's own DC offset — the mic has
        a large DC bias, so raw mean-abs would read 'loud' in a silent room."""
        samples = array("h", frame)
        mean = sum(samples) / len(samples)
        return sum(abs(s - mean) for s in samples) / len(samples)

    def feed(self, pcm: bytes) -> list[bytes]:
        """Returns completed utterances (raw PCM)."""
        done: list[bytes] = []
        self.pending.extend(pcm)
        while len(self.pending) >= FRAME_BYTES:
            frame = bytes(self.pending[:FRAME_BYTES])
            del self.pending[:FRAME_BYTES]
            done.extend(self._frame(frame))
        return done

    def _frame(self, frame: bytes) -> list[bytes]:
        self.energy = self._energy(frame)
        if self.floor is None:
            self.floor = self.energy
        self.threshold = max(self.floor * self.ratio, self.floor_min)
        voiced = self.energy > self.threshold

        if not voiced:
            # Track ambient only while quiet, so speech never raises the floor.
            self.floor = self.floor * 0.97 + self.energy * 0.03

        out: list[bytes] = []
        if not self.in_speech:
            self.preroll.append(frame)
            if voiced:
                self.in_speech = True
                self.silence_run = 0
                self.speech = bytearray(b"".join(self.preroll))
                self.preroll.clear()
        else:
            self.speech.extend(frame)
            self.silence_run = 0 if voiced else self.silence_run + 1
            if self.silence_run >= self.hangover_frames:
                out.append(self._close())
            elif len(self.speech) >= self.max_bytes:
                out.append(self._close())  # long monologue: ship a chunk
        return [u for u in out if u]

    def _close(self) -> bytes | None:
        pcm = bytes(self.speech)
        self.speech = bytearray()
        self.in_speech = False
        self.silence_run = 0
        if len(pcm) < self.min_bytes:
            return None  # cough/door-slam, not speech
        return pcm

    def meter(self) -> str:
        bars = min(30, int(self.energy / max(self.threshold, 1) * 10))
        state = "SPEECH" if self.in_speech else "  idle"
        return (f"{state} |{'█' * bars}{' ' * (30 - bars)}| "
                f"energy {self.energy:7.0f}  floor {self.floor or 0:7.0f}  "
                f"thr {self.threshold:7.0f}")


def pcm_to_wav(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return buf.getvalue()


class Gateway:
    def __init__(self, ws_url: str, token: str, device_id: str,
                 seg: Segmenter, show_meter: bool) -> None:
        self.ws_url = ws_url
        self.token = token
        self.device_id = device_id
        self.seg = seg
        self.show_meter = show_meter
        self.expected_seq: int | None = None
        self.dropped = 0
        self.ingest_seq = 0
        self.queue: asyncio.Queue[bytes] = asyncio.Queue()
        self._last_meter = 0.0

    def on_notify(self, _char, data: bytearray) -> None:
        if len(data) < 5:
            return
        seq, _flags = struct.unpack_from("<IB", data)
        if self.expected_seq is not None and seq != self.expected_seq:
            self.dropped += max(0, seq - self.expected_seq)
        self.expected_seq = seq + 1

        for pcm in self.seg.feed(bytes(data[5:])):
            secs = len(pcm) / 2 / SAMPLE_RATE
            print(f"\nutterance complete: {secs:.1f}s ({len(pcm)} bytes)")
            self.queue.put_nowait(pcm)

        now = time.monotonic()
        if self.show_meter and now - self._last_meter > 0.5:
            self._last_meter = now
            print(f"\r{self.seg.meter()}  drop {self.dropped}", end="", flush=True)

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
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--url", default="ws://localhost:8100/v1/ingest/live")
    p.add_argument("--token", default="dev-token-change-me")
    p.add_argument("--device", default="keepsake-p0")
    p.add_argument("--vad-ratio", type=float, default=2.5,
                   help="speech when energy exceeds noise floor x this (default 2.5)")
    p.add_argument("--vad-floor-min", type=float, default=60,
                   help="absolute floor so a dead-silent room still needs real sound")
    p.add_argument("--hangover", type=float, default=1.2,
                   help="seconds of silence that close an utterance (default 1.2)")
    p.add_argument("--min-utterance", type=float, default=0.6,
                   help="discard anything shorter (default 0.6 s)")
    p.add_argument("--max-utterance", type=float, default=25.0,
                   help="force-ship long monologues (default 25 s)")
    p.add_argument("--preroll", type=float, default=0.5,
                   help="seconds kept before speech onset (default 0.5)")
    p.add_argument("--quiet", action="store_true", help="hide the live meter")
    args = p.parse_args()

    seg = Segmenter(
        ratio=args.vad_ratio,
        floor_min=args.vad_floor_min,
        hangover_s=args.hangover,
        min_utt_s=args.min_utterance,
        max_utt_s=args.max_utterance,
        preroll_s=args.preroll,
    )
    gw = Gateway(args.url, args.token, args.device, seg, show_meter=not args.quiet)
    try:
        asyncio.run(gw.run())
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
