"""Server-side Silero speech gate and conservative noise reduction for 16 kHz PCM."""

from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
import math
from pathlib import Path
import threading

import numpy as np
import onnxruntime as ort

SAMPLE_RATE = 16000
WINDOW = 512
CONTEXT = 64
MODEL_PATH = Path(__file__).parent / "models" / "silero_vad.onnx"


@dataclass
class GateResult:
    decision: str
    reason: str
    pcm: bytes
    speech_ms: int
    duration_ms: int
    noise_reduced: bool = False
    peak_probability: float = 0.0


class AudioGate:
    """Each audio segment gets fresh recurrent VAD state; inference session is shared."""

    def __init__(self):
        options = ort.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        self.session = ort.InferenceSession(str(MODEL_PATH), sess_options=options,
                                            providers=["CPUExecutionProvider"])
        self.started_at = datetime.now(timezone.utc).isoformat()
        self.lock = threading.Lock()
        self.counters = {
            "evaluated": 0, "passed": 0, "dropped_silence": 0,
            "dropped_no_speech": 0, "errors": 0, "noise_reduced": 0,
        }
        self.by_path = {"live": self.counters.copy(), "checkpoint": self.counters.copy()}
        self.events = deque(maxlen=30)

    def record(self, path: str, result: GateResult, segment_id: str = ""):
        with self.lock:
            self.counters["evaluated"] += 1
            path_counts = self.by_path[path]
            path_counts["evaluated"] += 1
            if result.decision == "pass":
                self.counters["passed"] += 1
                path_counts["passed"] += 1
            elif result.decision == "error":
                self.counters["errors"] += 1
                path_counts["errors"] += 1
            else:
                self.counters["dropped_" + result.reason] += 1
                path_counts["dropped_" + result.reason] += 1
            if result.noise_reduced:
                self.counters["noise_reduced"] += 1
                path_counts["noise_reduced"] += 1
            self.events.appendleft({
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "path": path,
                "segment_id": segment_id,
                "decision": result.decision,
                "reason": result.reason,
                "duration_ms": result.duration_ms,
                "speech_ms": result.speech_ms,
                "noise_reduced": result.noise_reduced,
                "peak_probability": round(result.peak_probability, 3),
            })

    def snapshot(self):
        with self.lock:
            return {
                "model": "Silero VAD v6 ONNX",
                "ready": True,
                "started_at": self.started_at,
                "settings": {
                    "sample_rate_hz": SAMPLE_RATE,
                    "speech_probability_threshold": 0.5,
                    "minimum_speech_ms": 250,
                    "silence_peak_100ms_rms_pcm16": 30,
                    "noise_reduction": "mild spectral subtraction",
                },
                "counters": self.counters.copy(),
                "by_path": {path: counts.copy() for path, counts in self.by_path.items()},
                "recent": list(self.events),
            }

    def process(self, pcm: bytes, sample_rate: int) -> GateResult:
        duration_ms = round(len(pcm) / (2 * sample_rate) * 1000) if sample_rate > 0 else 0
        if sample_rate != SAMPLE_RATE or len(pcm) % 2:
            raise ValueError("VAD requires 16 kHz mono PCM16")
        samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        if len(samples) == 0:
            return GateResult("drop", "silence", b"", 0, duration_ms)
        block = 1600  # 100 ms; short speech must not be diluted by a 30-second checkpoint.
        padded_for_rms = np.pad(samples, (0, (-len(samples)) % block))
        peak_rms = np.sqrt(np.mean(padded_for_rms.reshape(-1, block) ** 2, axis=1)).max()
        if peak_rms < 30 / 32768:
            return GateResult("drop", "silence", b"", 0, duration_ms)

        state = np.zeros((2, 1, 128), dtype=np.float32)
        context = np.zeros((1, CONTEXT), dtype=np.float32)
        flags = []
        peak_probability = 0.0
        for offset in range(0, len(samples), WINDOW):
            window = samples[offset:offset + WINDOW]
            if len(window) < WINDOW:
                window = np.pad(window, (0, WINDOW - len(window)))
            audio = window.reshape(1, -1)
            output, state = self.session.run(
                None, {"input": np.concatenate((context, audio), axis=1),
                       "state": state, "sr": np.array(SAMPLE_RATE, dtype=np.int64)}
            )
            probability = float(output[0][0])
            if not math.isfinite(probability) or not 0 <= probability <= 1:
                raise RuntimeError("invalid Silero probability")
            peak_probability = max(peak_probability, probability)
            flags.append(probability >= 0.5)
            context = audio[:, -CONTEXT:]

        speech_ms = round(sum(flags) * WINDOW / SAMPLE_RATE * 1000)
        if speech_ms < 250:
            return GateResult("drop", "no_speech", b"", speech_ms, duration_ms,
                              peak_probability=float(peak_probability))

        # Keep 200 ms around detected speech so VAD boundaries do not clip words.
        active = np.repeat(np.asarray(flags, dtype=bool), WINDOW)[:len(samples)]
        padding = int(0.2 * SAMPLE_RATE)
        active = _pad_activity(active, padding)
        first = int(np.argmax(active))
        last = len(active) - int(np.argmax(active[::-1]))
        trimmed = samples[first:last]
        trimmed_active = active[first:last]
        cleaned, reduced = _reduce_noise(trimmed, trimmed_active)
        pcm_out = (np.clip(cleaned, -1, 1) * 32767).astype("<i2").tobytes()
        return GateResult("pass", "speech", pcm_out, speech_ms, duration_ms, reduced,
                          float(peak_probability))


def _pad_activity(active: np.ndarray, padding: int) -> np.ndarray:
    indexes = np.flatnonzero(active)
    if len(indexes) == 0:
        return active
    starts = np.maximum(indexes - padding, 0)
    ends = np.minimum(indexes + padding + 1, len(active))
    difference = np.zeros(len(active) + 1, dtype=np.int32)
    np.add.at(difference, starts, 1)
    np.add.at(difference, ends, -1)
    return np.cumsum(difference[:-1]) > 0


def _reduce_noise(samples: np.ndarray, active: np.ndarray) -> tuple[np.ndarray, bool]:
    """Mild spectral subtraction from nonspeech frames; preserve at least 35% of speech."""
    frame = 512
    hop = 256
    if len(samples) < frame:
        return samples, False
    pad = (hop - (len(samples) - frame) % hop) % hop
    padded = np.pad(samples, (0, pad))
    activity = np.pad(active, (0, pad))
    frames = np.lib.stride_tricks.sliding_window_view(padded, frame)[::hop]
    activity_frames = np.lib.stride_tricks.sliding_window_view(activity, frame)[::hop]
    window = np.hanning(frame).astype(np.float32)
    spectrum = np.fft.rfft(frames * window, axis=1)
    magnitude = np.abs(spectrum)
    noise_frames = activity_frames.mean(axis=1) < 0.1
    if np.any(noise_frames):
        noise = np.median(magnitude[noise_frames], axis=0)
        strength, floor = 1.1, 0.35
    else:
        # With continuous speech, only use a weak percentile estimate.
        noise = np.percentile(magnitude, 20, axis=0)
        strength, floor = 0.5, 0.55
    gain = np.maximum(floor, 1.0 - strength * noise / np.maximum(magnitude, 1e-8))
    filtered = np.fft.irfft(spectrum * gain, n=frame, axis=1)
    output = np.zeros(len(padded), dtype=np.float32)
    weights = np.zeros(len(padded), dtype=np.float32)
    for index, block in enumerate(filtered):
        start = index * hop
        output[start:start + frame] += block * window
        weights[start:start + frame] += window * window
    output = output / np.maximum(weights, 1e-6)
    return output[:len(samples)], True
