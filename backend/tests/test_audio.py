import io
import math
import wave
from array import array

from app.audio import TARGET_RATE_HZ, ensure_stt_rate, resample_linear


def make_wav(samples: array, rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(samples.tobytes())
    return buf.getvalue()


def read_wav(data: bytes) -> tuple[int, array]:
    with wave.open(io.BytesIO(data)) as w:
        s = array("h")
        s.frombytes(w.readframes(w.getnframes()))
        return w.getframerate(), s


def tone(rate: int, hz: float, secs: float) -> array:
    n = int(rate * secs)
    return array("h", [int(12000 * math.sin(2 * math.pi * hz * i / rate)) for i in range(n)])


def test_upsamples_8k_to_16k_and_preserves_duration():
    src = tone(8000, 440, 0.5)
    out = ensure_stt_rate(make_wav(src, 8000), "wav")
    rate, samples = read_wav(out)
    assert rate == TARGET_RATE_HZ
    assert abs(len(samples) / rate - 0.5) < 0.01  # same wall-clock duration


def test_16k_passes_through_untouched():
    data = make_wav(tone(16000, 440, 0.2), 16000)
    assert ensure_stt_rate(data, "wav") is data


def test_non_wav_codec_passes_through():
    assert ensure_stt_rate(b"\x00opus-ish", "opus") == b"\x00opus-ish"


def test_garbage_does_not_raise():
    assert ensure_stt_rate(b"not a wav at all", "wav") == b"not a wav at all"


def test_upsample_preserves_waveform_shape():
    """A 440 Hz tone must still be 440 Hz after resampling — guards against
    an off-by-one that would pitch-shift every utterance."""
    src = tone(8000, 440, 0.25)
    _, out = read_wav(ensure_stt_rate(make_wav(src, 8000), "wav"))
    # count zero crossings; ~2 per cycle
    def crossings(s):
        return sum(1 for i in range(1, len(s)) if (s[i - 1] < 0) != (s[i] < 0))
    src_hz = crossings(src) / 2 / 0.25
    out_hz = crossings(out) / 2 / 0.25
    assert abs(src_hz - out_hz) < 20


def test_resample_handles_empty():
    assert len(resample_linear(array("h"), 8000, 16000)) == 0
