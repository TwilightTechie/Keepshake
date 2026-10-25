#!/usr/bin/env python3
"""Compare native WAV and the existing backend's 16 kHz resampling with Sarvam."""
import argparse
import asyncio
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import time
import wave

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from app.audio import ensure_stt_rate


async def main(args):
    key = os.environ.get("SARVAM_API_KEY") or os.environ.get("KEEPSAKE_SARVAM_API_KEY")
    if not key:
        raise SystemExit("Load SARVAM_API_KEY or KEEPSAKE_SARVAM_API_KEY in the environment first.")
    source = args.wav.resolve()
    original = source.read_bytes()
    with wave.open(io.BytesIO(original)) as wav:
        duration = wav.getnframes() / wav.getframerate()
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or not 0 < duration <= 30:
            raise SystemExit("Expected a mono PCM16 WAV of at most 30 seconds.")
        original_rate = wav.getframerate()
    folder = source.parent / ("sarvam_" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ"))
    folder.mkdir()
    variants = [("original", original), ("resampled_16khz", ensure_stt_rate(original, "wav"))]
    report = {"model": args.model, "mode": args.mode, "source": str(source),
              "source_sha256": hashlib.sha256(original).hexdigest(),
              "original_rate": original_rate, "duration": duration, "results": []}
    async with httpx.AsyncClient(timeout=120) as client:
        for name, audio in variants:
            (folder / f"{name}.wav").write_bytes(audio)
            print(f"Transcribing {name}, {duration:.2f}s, {args.model} / {args.mode}...", flush=True)
            started = time.monotonic()
            try:
                response = await client.post(
                    "https://api.sarvam.ai/speech-to-text",
                    headers={"Api-Subscription-Key": key},
                    data={"model": args.model, "mode": args.mode, "language_code": "unknown"},
                    files={"file": (f"{name}.wav", audio, "audio/wav")},
                )
                # Avoid writing or displaying credentials even in an unexpected response.
                safe_body = response.text.replace(key, "[REDACTED]")
                try:
                    payload = json.loads(safe_body)
                except ValueError:
                    payload = {"error": safe_body[:2000]}
                result = {"variant": name, "status": response.status_code,
                          "elapsed_seconds": round(time.monotonic()-started, 3), "response": payload}
            except httpx.RequestError as exc:
                result = {"variant": name, "error": type(exc).__name__}
            report["results"].append(result)
            (folder / "comparison.json").write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")
            print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
            if result.get("status") != 200:
                print(f"Stopped after API failure. Results: {folder}")
                return 1
            (folder / f"{name}.txt").write_text(payload.get("transcript", "")+"\n")
    print(f"Results: {folder}", flush=True)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", type=Path)
    parser.add_argument("--model", default="saaras:v4")
    parser.add_argument("--mode", default="transcribe", choices=["transcribe", "verbatim", "codemix", "translit", "translate"])
    raise SystemExit(asyncio.run(main(parser.parse_args())))
