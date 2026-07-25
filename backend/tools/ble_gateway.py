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

VERBOSE = False
_meter_active = False


def log(msg: str) -> None:
    """Timestamped line that never gets eaten by the in-place meter."""
    global _meter_active
    prefix = "\n" if _meter_active else ""
    _meter_active = False
    print(f"{prefix}[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def vlog(msg: str) -> None:
    if VERBOSE:
        log(msg)


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
        # stats
        self.packets = 0
        self.audio_bytes = 0
        self.last_packet_at = 0.0
        self.subscribed_at = 0.0
        self.utterances = 0
        self.acked = 0
        self.was_speech = False
        self.speech_started_at = 0.0

    def on_notify(self, _char, data: bytearray) -> None:
        global _meter_active
        now = time.monotonic()
        if len(data) < 5:
            vlog(f"runt packet ({len(data)}B) ignored")
            return
        seq, flags = struct.unpack_from("<IB", data)
        payload = bytes(data[5:])

        if self.packets == 0:
            log(f"first audio packet received (seq {seq}, {len(payload)}B payload) "
                "— stream is live")
        if self.expected_seq is not None and seq != self.expected_seq:
            missed = max(0, seq - self.expected_seq)
            self.dropped += missed
            if missed:
                log(f"! gap: expected seq {self.expected_seq}, got {seq} "
                    f"({missed} lost, {self.dropped} total)")
        self.expected_seq = seq + 1
        self.packets += 1
        self.audio_bytes += len(payload)
        self.last_packet_at = now
        vlog(f"pkt seq={seq} flags={flags} {len(payload)}B")

        utterances = self.seg.feed(payload)

        # Speech onset/end are the events that matter when nothing shows up.
        if self.seg.in_speech and not self.was_speech:
            self.speech_started_at = now
            log(f"speech START  (energy {self.seg.energy:.0f} > thr "
                f"{self.seg.threshold:.0f}, floor {self.seg.floor or 0:.0f})")
        elif not self.seg.in_speech and self.was_speech and not utterances:
            log(f"speech end — too short, discarded (< {self.seg.min_bytes/2/SAMPLE_RATE:.1f}s)")
        self.was_speech = self.seg.in_speech

        for pcm in utterances:
            secs = len(pcm) / 2 / SAMPLE_RATE
            self.utterances += 1
            log(f"utterance #{self.utterances} complete: {secs:.1f}s "
                f"({len(pcm)} bytes) → queued for upload")
            self.queue.put_nowait(pcm)

        if self.show_meter and now - self._last_meter > 0.5:
            self._last_meter = now
            _meter_active = True
            kbps = self.audio_bytes * 8 / 1000 / max(now - self.subscribed_at, 1)
            print(f"\r{self.seg.meter()}  {kbps:5.0f}kbps drop {self.dropped}",
                  end="", flush=True)

    async def monitor(self) -> None:
        """Heartbeat: proves the gateway is alive and shouts if audio stops."""
        warned = False
        while True:
            await asyncio.sleep(5)
            now = time.monotonic()
            if not self.subscribed_at:
                continue
            gap = now - self.last_packet_at if self.last_packet_at else 999
            if gap > 3:
                if not warned:
                    log(f"⚠ no audio from pendant for {gap:.0f}s — is it powered "
                        "and still connected?")
                    warned = True
            else:
                warned = False
                secs = now - self.subscribed_at
                log(f"stats: {self.packets} pkts, {self.audio_bytes/1024:.0f} KiB, "
                    f"{self.audio_bytes*8/1000/max(secs,1):.0f} kbps, "
                    f"{self.dropped} dropped, {self.utterances} utterances, "
                    f"{self.acked} acked")

    async def uplink(self) -> None:
        url = f"{self.ws_url}?token={self.token}"
        async with websockets.connect(url, max_size=16 * 1024 * 1024) as ws:
            await ws.send(json.dumps({
                "type": "hello", "device_id": self.device_id,
                "device_name": "Keepsake P0 (BLE gateway)",
            }))
            hello = json.loads(await ws.recv())
            assert hello.get("type") == "hello_ack", hello
            log(f"uplink connected: {self.ws_url} (device_id={self.device_id})")
            while True:
                pcm = await self.queue.get()
                self.ingest_seq += 1
                wav = pcm_to_wav(pcm)
                t0 = time.monotonic()
                log(f"uploading utterance seq={self.ingest_seq} "
                    f"({len(wav)/1024:.0f} KiB WAV, {len(pcm)/2/SAMPLE_RATE:.1f}s)…")
                await ws.send(json.dumps({
                    "type": "frame",
                    "seq": self.ingest_seq,
                    "captured_at": datetime.now(UTC).isoformat(),
                    "codec": "wav",
                    "utterance_end": True,
                    "audio_b64": base64.b64encode(wav).decode(),
                }))
                ack = json.loads(await ws.recv())
                self.acked += 1
                log(f"✓ durable ack seq {ack.get('seq')} in "
                    f"{(time.monotonic()-t0)*1000:.0f}ms — STT + extraction running "
                    "(transcript in ~15s)")

    async def run(self) -> None:
        uplink_task = asyncio.create_task(self.uplink_forever())
        monitor_task = asyncio.create_task(self.monitor())
        try:
            while True:
                log(f"scanning for '{DEVICE_NAME}'…")
                device = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=30)
                if device is None:
                    log("not found — pendant off or out of range; rescanning…")
                    continue
                log(f"found {device.address} — connecting…")
                try:
                    disconnected = asyncio.Event()
                    async with BleakClient(
                        device,
                        disconnected_callback=lambda _c, ev=disconnected: ev.set(),
                    ) as client:
                        mtu = getattr(client, "mtu_size", None)
                        log(f"connected (MTU {mtu}) — subscribing to audio…")
                        await client.start_notify(AUDIO_CHAR, self.on_notify)
                        self.expected_seq = None  # pendant may have rebooted
                        self.subscribed_at = time.monotonic()
                        self.last_packet_at = 0.0
                        log("subscribed — speak near the pendant. Meter below: "
                            "bar rises with sound, SPEECH when above threshold. "
                            "(Ctrl+C to stop)")
                        await disconnected.wait()
                    log(f"pendant disconnected after {self.packets} packets "
                        f"/ {self.utterances} utterances — rescanning…")
                    self.subscribed_at = 0.0
                except Exception as exc:  # noqa: BLE001 - keep the bench loop alive
                    log(f"BLE error: {exc} — rescanning in 3s…")
                    self.subscribed_at = 0.0
                    await asyncio.sleep(3)
        finally:
            uplink_task.cancel()
            monitor_task.cancel()

    async def uplink_forever(self) -> None:
        while True:
            try:
                await self.uplink()
            except Exception as exc:  # noqa: BLE001
                log(f"uplink error: {exc} — reconnecting in 3s…")
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
    p.add_argument("-v", "--verbose", action="store_true",
                   help="log every BLE packet (very chatty)")
    args = p.parse_args()

    global VERBOSE
    VERBOSE = args.verbose

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
