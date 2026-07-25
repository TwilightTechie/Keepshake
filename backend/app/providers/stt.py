"""STT provider interface (D3/BE-3): pluggable, Sarvam Saaras default, mock for dev/tests.

v1 uses batch REST per utterance — the pipeline is near-line (≤2 min), not realtime,
so streaming buys nothing yet. The streaming client (see AadeshAI's stt.py) can slot
in behind the same interface later.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

import httpx

from app.audio import ensure_stt_rate
from app.config import get_settings


@dataclass
class SttTurn:
    speaker: str
    text: str
    offset_seconds: float = 0.0


class SttProvider(Protocol):
    async def transcribe(self, audio: bytes, codec: str) -> list[SttTurn]: ...


class MockStt:
    """Deterministic fixture STT. If the audio bytes are UTF-8 of the form
    'Speaker|text\\n...' it parses them (lets tests script transcripts);
    otherwise it emits a single placeholder turn."""

    async def transcribe(self, audio: bytes, codec: str) -> list[SttTurn]:
        try:
            text = audio.decode("utf-8")
        except UnicodeDecodeError:
            return [SttTurn(speaker="Speaker 1", text=f"[mock transcript of {len(audio)} bytes]")]
        turns: list[SttTurn] = []
        for i, line in enumerate(filter(None, text.splitlines())):
            speaker, _, spoken = line.partition("|")
            if not spoken:
                speaker, spoken = "Speaker 1", speaker
            turns.append(
                SttTurn(speaker=speaker.strip(), text=spoken.strip(), offset_seconds=i * 5)
            )
        return turns


class SarvamStt:
    """Sarvam Saaras batch REST. Sends the utterance as a WAV file upload."""

    async def transcribe(self, audio: bytes, codec: str) -> list[SttTurn]:
        s = get_settings()
        if not s.sarvam_api_key:
            raise RuntimeError("KEEPSAKE_SARVAM_API_KEY is not set")
        audio = ensure_stt_rate(audio, codec)  # 8 kHz costs real accuracy, see app/audio.py
        filename = "utterance.wav" if codec in ("wav", "pcm16") else "utterance.opus"
        mime = "audio/wav" if codec in ("wav", "pcm16") else "audio/opus"
        async with httpx.AsyncClient(timeout=120) as client:
            resp = await client.post(
                s.sarvam_stt_url,
                headers={"Api-Subscription-Key": s.sarvam_api_key},
                # 'unknown' = auto-detect, which is what keeps code-mixed
                # Hindi/English working; pinning a language would break it.
                data={
                    "model": s.sarvam_stt_model,
                    "language_code": s.sarvam_language_code,
                },
                files={"file": (filename, audio, mime)},
            )
        resp.raise_for_status()
        payload = resp.json()
        transcript = (payload.get("transcript") or "").strip()
        if not transcript:
            return []
        # Batch endpoint gives no diarization in v1 — single-speaker turn; the
        # extraction prompt is written to cope with unlabeled speakers.
        return [SttTurn(speaker="Speaker 1", text=transcript)]


def get_stt_provider() -> SttProvider:
    if get_settings().stt_provider == "sarvam":
        return SarvamStt()
    return MockStt()
