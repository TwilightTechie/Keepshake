"""Legacy resampling utilities retained for bench comparisons.

The live Sarvam provider sends native WAV bytes unchanged. Saaras v4 supports
8 kHz directly; upsampling did not improve our recorded-speech comparison.
"""

from __future__ import annotations

import io
import wave
from array import array

TARGET_RATE_HZ = 16000


def resample_linear(samples: array, src_rate: int, dst_rate: int) -> array:
    """Linear interpolation resampling. Adequate here because our only real
    case is an exact 2x upsample (8k -> 16k), where it is just midpoint
    insertion; a polyphase filter would buy nothing measurable and would cost
    a scipy dependency."""
    if src_rate == dst_rate or not samples:
        return samples
    ratio = dst_rate / src_rate
    out_len = int(len(samples) * ratio)
    out = array("h", bytes(out_len * 2))
    last = len(samples) - 1
    for i in range(out_len):
        pos = i / ratio
        i0 = int(pos)
        if i0 >= last:
            out[i] = samples[last]
            continue
        frac = pos - i0
        a, b = samples[i0], samples[i0 + 1]
        out[i] = int(a + (b - a) * frac)
    return out


def ensure_stt_rate(audio: bytes, codec: str) -> bytes:
    """Upsample mono WAV below TARGET_RATE_HZ. Anything else passes through
    untouched (Opus frames, already-16k WAVs, unexpected formats)."""
    if codec not in ("wav", "pcm16"):
        return audio
    try:
        with wave.open(io.BytesIO(audio)) as w:
            if w.getnchannels() != 1 or w.getsampwidth() != 2:
                return audio
            rate = w.getframerate()
            if rate >= TARGET_RATE_HZ:
                return audio
            samples = array("h")
            samples.frombytes(w.readframes(w.getnframes()))
    except (wave.Error, EOFError):
        return audio

    upsampled = resample_linear(samples, rate, TARGET_RATE_HZ)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as o:
        o.setnchannels(1)
        o.setsampwidth(2)
        o.setframerate(TARGET_RATE_HZ)
        o.writeframes(upsampled.tobytes())
    return buf.getvalue()
