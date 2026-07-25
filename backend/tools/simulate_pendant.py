#!/usr/bin/env python3
"""Pendant simulator: replays audio (or a scripted transcript) into the ingest WS
as sequenced frames, exercising the zero-loss ack contract without hardware.

Usage:
  # Scripted transcript (works with the mock STT provider — no keys needed):
  python tools/simulate_pendant.py --script demo
  python tools/simulate_pendant.py --text "You|I'll send the report by Friday"

  # Real audio file (WAV; use with KEEPSAKE_STT_PROVIDER=sarvam on the server):
  python tools/simulate_pendant.py --wav path/to/recording.wav

Options:
  --url ws://localhost:8100/v1/ingest/live   --token dev-token-change-me
  --device sim-pendant-1   --frame-bytes 32000
"""

import argparse
import asyncio
import base64
import json
import sys
from datetime import UTC, datetime

try:
    import websockets
except ImportError:
    sys.exit("pip install websockets  (dev extra: .venv/bin/pip install -e '.[dev]')")

DEMO_SCRIPT = """\
You|Morning everyone, quick standup. If we hotfix the sync bug we skip QA entirely.
Leo|I'd rather hold it. Let's ship the sync fix in 1.4.2, not as a hotfix.
You|Agreed. Sam, can you own the release notes? I'll review the draft by end of day.
Sam|Yep, I'll have a draft by end of day.
Priya|One more thing - did we ever settle the retro cadence?
"""


async def run(args: argparse.Namespace) -> None:
    if args.wav:
        with open(args.wav, "rb") as f:
            payload = f.read()
        codec = "wav"
    else:
        text = args.text or DEMO_SCRIPT
        payload = text.encode("utf-8")
        codec = "pcm16"  # mock STT parses utf-8 scripts; label irrelevant for it

    frames = [
        payload[i : i + args.frame_bytes]
        for i in range(0, len(payload), args.frame_bytes)
    ] or [b""]

    url = f"{args.url}?token={args.token}"
    async with websockets.connect(url, max_size=8 * 1024 * 1024) as ws:
        await ws.send(json.dumps({"type": "hello", "device_id": args.device,
                                  "device_name": "Simulated pendant"}))
        hello = json.loads(await ws.recv())
        assert hello.get("type") == "hello_ack", hello

        acked = 0
        for i, chunk in enumerate(frames):
            seq = args.start_seq + i
            await ws.send(json.dumps({
                "type": "frame",
                "seq": seq,
                "captured_at": datetime.now(UTC).isoformat(),
                "codec": codec,
                "utterance_end": i == len(frames) - 1,
                "audio_b64": base64.b64encode(chunk).decode("ascii"),
            }))
            ack = json.loads(await ws.recv())
            assert ack.get("type") == "ack" and ack.get("seq") == seq, ack
            acked += 1
        print(f"sent {len(frames)} frames, {acked} durable acks "
              f"(seq {args.start_seq}..{args.start_seq + len(frames) - 1})")
        print("pipeline will transcribe + extract within a few seconds — check "
              "/v1/conversations, /v1/wal, /v1/review")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--url", default="ws://localhost:8100/v1/ingest/live")
    p.add_argument("--token", default="dev-token-change-me")
    p.add_argument("--device", default="sim-pendant-1")
    p.add_argument("--wav")
    p.add_argument("--text")
    p.add_argument("--script", choices=["demo"], help="use the built-in demo transcript")
    p.add_argument("--frame-bytes", type=int, default=32000)
    p.add_argument("--start-seq", type=int, default=1)
    asyncio.run(run(p.parse_args()))


if __name__ == "__main__":
    main()
