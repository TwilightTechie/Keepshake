#!/usr/bin/env python3
"""
Dream AI Pendant Server & Web Console (v2.2.0)
Hosts:
- Omi mobile app webhooks (/omi/webhook/* or /webhook/*)
- Low-latency Sarvam STT integration (saaras:v4) with smart pause detection (4-8s turnaround)
- Ollama LLM integration (Qwen 3 8B running on Mac Mini via reverse tunnel)
- 5-Minute Auto & On-Demand AI Summarization (Decisions, Key Points, Action Items)
- Real-time WebSocket & SSE Transcript Stream
- Automated Audio Storage Cleanup (keeps transcripts, purges old temporary .wav files)
- Mobile-Friendly Web Application Console at /dream-ai
"""

import argparse
import asyncio
import datetime
import io
import json
import math
import os
import struct
import time
import wave
from pathlib import Path
from typing import Optional, List, Dict, Any

from dotenv import load_dotenv
import httpx
from fastapi import FastAPI, Request, Query, Response, status, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, FileResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

# Load environment
ENV_PATH = os.path.join(os.path.dirname(__file__), ".env")
load_dotenv(ENV_PATH)

SARVAM_API_KEY = os.environ.get("SARVAM_API_KEY", "")
SARVAM_MODEL = os.environ.get("SARVAM_STT_MODEL", "saaras:v4")
SARVAM_MODE = os.environ.get("SARVAM_STT_MODE", "transcribe")
SARVAM_LANGUAGE = os.environ.get("SARVAM_LANGUAGE_CODE", "auto")

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3:8b")
SUMMARY_INTERVAL_MIN = int(os.environ.get("SUMMARY_INTERVAL_MIN", "5"))
WEBHOOK_AUTH_TOKEN = os.environ.get("WEBHOOK_AUTH_TOKEN", "keepsake-secret-2026")

app = FastAPI(title="Dream AI Pendant Console", version="2.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "recordings_omi")
os.makedirs(OUTPUT_DIR, exist_ok=True)

TRANSCRIPTS_LOG = os.path.join(OUTPUT_DIR, "live_transcripts.jsonl")
MEMORIES_LOG = os.path.join(OUTPUT_DIR, "memories.jsonl")
SUMMARIES_LOG = os.path.join(OUTPUT_DIR, "summaries.jsonl")


def get_effective_sarvam_lang() -> str:
    """Returns valid Sarvam REST API language_code (unknown = auto-detect)."""
    if SARVAM_LANGUAGE in ("auto", "unknown", None, ""):
        return "unknown"
    return SARVAM_LANGUAGE


# ---------------------------------------------------------------------------
# Storage Management & Audio Cleanup
# ---------------------------------------------------------------------------

def cleanup_old_audio_files(max_age_minutes: int = 5, max_files: int = 6) -> Dict[str, Any]:
    """
    Deletes older temporary .wav audio files to prevent filling server disk.
    Text transcripts (.jsonl, .txt) and conversation memories are NEVER deleted.
    """
    now = time.time()
    deleted_count = 0
    freed_bytes = 0
    try:
        wav_files = []
        for f in os.listdir(OUTPUT_DIR):
            if f.endswith(".wav"):
                p = os.path.join(OUTPUT_DIR, f)
                try:
                    wav_files.append((p, os.path.getmtime(p), os.path.getsize(p)))
                except OSError:
                    pass

        # Sort ascending by modification time (oldest first)
        wav_files.sort(key=lambda x: x[1])

        cutoff = now - (max_age_minutes * 60)
        # Keep at least the 2 most recent files for active streaming
        num_to_inspect = max(0, len(wav_files) - 2)

        for i in range(num_to_inspect):
            path, mtime, size = wav_files[i]
            # Delete if older than cutoff OR if total file count exceeds max_files
            if mtime < cutoff or (len(wav_files) - deleted_count) > max_files:
                try:
                    os.remove(path)
                    deleted_count += 1
                    freed_bytes += size
                except OSError:
                    pass

        freed_mb = round(freed_bytes / (1024 * 1024), 2)
        if deleted_count > 0:
            print(f"[STORAGE CLEANUP] Purged {deleted_count} old .wav files, freed {freed_mb} MB.")
        return {"deleted": deleted_count, "freed_mb": freed_mb}
    except Exception as e:
        print(f"[STORAGE CLEANUP ERROR]: {e}")
        return {"error": str(e), "deleted": 0, "freed_mb": 0.0}


# ---------------------------------------------------------------------------
# Smart Transcription Buffer (Low Latency, Silence Aware, Zero Repetition)
# ---------------------------------------------------------------------------

class SmartTranscriptionBuffer:
    """
    Accumulates PCM audio from Omi app and triggers Sarvam STT with target latency 4-8s.

    Key Features:
    1. Speech Energy Detection: Calculates RMS to distinguish speech from ambient room hum.
    2. Dynamic Pause Trigger: When speech pauses for >= 0.9s and buffer has >= 2.5s, transcribes immediately.
    3. Max Latency Bound: Forces transcription if buffer reaches MAX_SEGMENT_SEC (4.5s) to guarantee fast updates.
    4. Stream Idle Trigger: If device pauses audio streaming for >= 1.5s and buffer has >= 1.0s, transcribes immediately.
    5. Silence Filtering: Segments containing NO speech (pure silence/room noise) are discarded without calling Sarvam STT.
    6. Strict Deduplication: Deduplicates against recent transcripts to prevent duplicate words or repeat logs.
    """

    MIN_SEGMENT_SEC = 1.0           # Minimum duration to send to STT
    PAUSE_THRESHOLD_SEC = 0.75      # Silence gap that marks end of spoken phrase
    MAX_SEGMENT_SEC = 4.5           # Max audio duration before triggering STT (~4-5s latency)
    SPEECH_RMS_THRESHOLD = 70       # Calibrated for 0 dB raw PCM (room noise ~20-40, speech ~100-250)

    def __init__(self, sample_rate: int = 16000):
        self.sample_rate = sample_rate
        self.accumulated_pcm = bytearray()
        self.last_packet_time: Optional[float] = None
        self.last_speech_time: Optional[float] = None
        self.has_active_speech = False
        self.total_bytes_received = 0
        self.uid: Optional[str] = None
        self.current_file: Optional[str] = None
        self.active_recording_seconds = 0.0
        self._transcription_lock = asyncio.Lock()
        self._recent_transcripts: List[str] = []
        self._MAX_RECENT = 12
        self._last_lang: Optional[str] = None

    def _compute_rms(self, pcm_bytes: bytes) -> float:
        if len(pcm_bytes) < 2:
            return 0.0
        n_samples = len(pcm_bytes) // 2
        samples = struct.unpack(f"<{n_samples}h", pcm_bytes[:n_samples * 2])
        if not samples:
            return 0.0
        return math.sqrt(sum(s * s for s in samples) / len(samples))

    def _is_duplicate(self, text: str) -> bool:
        normalized = text.strip().lower()
        if not normalized or len(normalized) < 2:
            return True
        for recent in self._recent_transcripts:
            recent_norm = recent.strip().lower()
            if normalized == recent_norm:
                return True
            if recent_norm.endswith(normalized):
                return True
            if len(normalized) > 16 and normalized in recent_norm:
                return True
        return False

    def _register_transcript(self, text: str):
        self._recent_transcripts.append(text)
        if len(self._recent_transcripts) > self._MAX_RECENT:
            self._recent_transcripts.pop(0)

    def add_audio(self, audio_bytes: bytes, sample_rate: int, uid: Optional[str] = None):
        now = time.time()
        self.last_packet_time = now
        self.sample_rate = sample_rate
        self.uid = uid
        self.total_bytes_received += len(audio_bytes)
        self.accumulated_pcm.extend(audio_bytes)

        # Compute peak RMS across 100ms slices (3200 bytes) to catch short spoken phrases
        block_size = max(1600, (sample_rate * 2) // 10)
        max_block_rms = 0.0
        for i in range(0, len(audio_bytes), block_size):
            slice_bytes = audio_bytes[i:i + block_size]
            b_rms = self._compute_rms(slice_bytes)
            if b_rms > max_block_rms:
                max_block_rms = b_rms

        if max_block_rms >= self.SPEECH_RMS_THRESHOLD:
            self.has_active_speech = True
            self.last_speech_time = now

        dur = len(self.accumulated_pcm) / (sample_rate * 2)
        self.active_recording_seconds = dur

        # Maintain single rolling active WAV file on disk for diagnostics
        self._update_wav_file()

    def _update_wav_file(self):
        if not self.current_file or not os.path.exists(self.current_file):
            ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            self.current_file = os.path.join(OUTPUT_DIR, f"pendant_active_{self.sample_rate}hz.wav")
        try:
            with wave.open(self.current_file, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(self.sample_rate)
                wf.writeframes(self.accumulated_pcm)
        except Exception:
            pass

    def should_transcribe(self) -> bool:
        if not self.accumulated_pcm or not self.last_packet_time:
            return False

        dur = len(self.accumulated_pcm) / (self.sample_rate * 2)
        if dur < self.MIN_SEGMENT_SEC:
            return False

        now = time.time()

        # Rule 1: Buffer reached max segment duration (4.5s) -> transcribe now
        if dur >= self.MAX_SEGMENT_SEC:
            return True

        # Rule 2: Speech occurred and is followed by a natural silence pause (>= 0.75s)
        if self.has_active_speech and self.last_speech_time is not None:
            silence_gap = now - self.last_speech_time
            if silence_gap >= self.PAUSE_THRESHOLD_SEC and dur >= 1.4:
                return True

        # Rule 3: Transmission paused from mobile app (no packet for >= 1.5s)
        if (now - self.last_packet_time) >= 1.5 and dur >= self.MIN_SEGMENT_SEC:
            return True

        return False

    async def transcribe_and_reset(self) -> Optional[str]:
        async with self._transcription_lock:
            if not self.accumulated_pcm:
                return None

            pcm_to_process = bytes(self.accumulated_pcm)
            had_speech = self.has_active_speech
            dur = len(pcm_to_process) / (self.sample_rate * 2)

            # Reset state for next incoming audio chunk
            self.accumulated_pcm = bytearray()
            self.has_active_speech = False
            self.last_speech_time = None

            # Skip calling STT if segment has no speech energy and buffer is short (< 3.8s)
            # Longer segments are passed to Sarvam which natively handles silence rejection
            if dur < self.MIN_SEGMENT_SEC or (not had_speech and dur < 3.8):
                return None

            # Wrap in-memory PCM as WAV
            buf = io.BytesIO()
            with wave.open(buf, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(self.sample_rate)
                wf.writeframes(pcm_to_process)
            wav_bytes = buf.getvalue()

            t0 = time.time()
            transcript = await self._call_sarvam(wav_bytes, dur)
            elapsed = round(time.time() - t0, 2)

            if transcript and not self._is_duplicate(transcript):
                self._register_transcript(transcript)
                now_str = datetime.datetime.now().strftime("%H:%M:%S")
                lang = self._last_lang or "unknown"
                print(f"[STT ✓ {now_str} in {elapsed}s] [{lang}]: \"{transcript}\"")
                entry = {
                    "time": now_str,
                    "timestamp": datetime.datetime.now().isoformat(),
                    "speaker": "Pendant (Sarvam Saaras)",
                    "text": transcript,
                    "language": lang,
                    "source": "sarvam",
                    "duration_sec": round(dur, 1),
                }
                log_transcript_entry(entry)
                return transcript
            elif transcript:
                print(f"[STT DEDUP] Skipped duplicate: \"{transcript[:50]}...\"")

            return None

    async def _call_sarvam(self, wav_bytes: bytes, duration: float) -> Optional[str]:
        """Calls Sarvam Saaras v4 STT."""
        if not SARVAM_API_KEY:
            return None

        headers = {"Api-Subscription-Key": SARVAM_API_KEY}
        eff_lang = get_effective_sarvam_lang()
        data = {"model": SARVAM_MODEL, "mode": SARVAM_MODE, "language_code": eff_lang}
        files = {"file": ("audio_segment.wav", wav_bytes, "audio/wav")}

        try:
            async with httpx.AsyncClient(timeout=30) as client:
                resp = await client.post("https://api.sarvam.ai/speech-to-text", headers=headers, data=data, files=files)
                if resp.status_code == 200:
                    res = resp.json()
                    self._last_lang = res.get("language_code", "unknown")
                    return res.get("transcript", "").strip()
                else:
                    print(f"[SARVAM ERROR {resp.status_code}]: {resp.text}")
        except Exception as e:
            print(f"[SARVAM EXCEPTION]: {e}")
        return None


# Global Buffer & Session State
tx_buffer = SmartTranscriptionBuffer()

session_state: Dict[str, Any] = {
    "current_file": None,
    "last_packet_time": None,
    "sample_rate": 16000,
    "uid": None,
    "total_bytes_received": 0,
    "active_recording_seconds": 0.0,
}

# Summarization & Streaming State
is_summarizing = False
last_auto_summary_time = time.time()
ws_clients: List[WebSocket] = []


async def broadcast_ws(event_type: str, data: Any):
    """Broadcasts events to connected WebSocket clients for real-time live streaming."""
    dead = []
    msg = json.dumps({"type": event_type, "data": data}, ensure_ascii=False)
    for ws in ws_clients:
        try:
            await ws.send_text(msg)
        except Exception:
            dead.append(ws)
    for ws in dead:
        if ws in ws_clients:
            ws_clients.remove(ws)


def log_transcript_entry(entry: Dict[str, Any]):
    with open(TRANSCRIPTS_LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    try:
        loop = asyncio.get_event_loop()
        if loop.is_running():
            asyncio.create_task(broadcast_ws("transcript", entry))
    except Exception:
        pass


def log_memory_entry(entry: Dict[str, Any]):
    with open(MEMORIES_LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    try:
        loop = asyncio.get_event_loop()
        if loop.is_running():
            asyncio.create_task(broadcast_ws("memory", entry))
    except Exception:
        pass


def log_summary_entry(entry: Dict[str, Any]):
    with open(SUMMARIES_LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    try:
        loop = asyncio.get_event_loop()
        if loop.is_running():
            asyncio.create_task(broadcast_ws("summary", entry))
    except Exception:
        pass


def get_summaries(limit: int = 50) -> List[Dict[str, Any]]:
    entries = []
    if os.path.exists(SUMMARIES_LOG):
        with open(SUMMARIES_LOG, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        entries.append(json.loads(line))
                    except Exception:
                        pass
    entries.reverse()
    return entries[:limit]


def get_clean_transcripts(minutes: int = 5) -> Dict[str, Any]:
    """
    Reads TRANSCRIPTS_LOG and produces clean, deduplicated transcript lines for LLM summarization.
    If minutes > 0, restricts to entries within the last `minutes`.
    If minutes == 0, returns all available entries.
    """
    entries = []
    if not os.path.exists(TRANSCRIPTS_LOG):
        return {"items": [], "formatted_text": "", "word_count": 0, "line_count": 0}

    cutoff_dt = None
    if minutes > 0:
        cutoff_dt = datetime.datetime.now() - datetime.timedelta(minutes=minutes)

    with open(TRANSCRIPTS_LOG, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except Exception:
                continue

            if cutoff_dt:
                iso_ts = item.get("timestamp")
                if iso_ts:
                    try:
                        ts_clean = iso_ts.replace("Z", "+00:00")
                        entry_dt = datetime.datetime.fromisoformat(ts_clean)
                        if entry_dt.tzinfo:
                            entry_dt = entry_dt.replace(tzinfo=None)
                        if entry_dt < cutoff_dt:
                            continue
                    except Exception:
                        pass

            entries.append(item)

    cleaned_items = []
    last_text = ""
    for e in entries:
        txt = (e.get("text") or "").strip()
        if not txt or len(txt) < 3 or txt == last_text:
            continue
        if last_text and (txt in last_text or last_text in txt and len(txt) <= len(last_text)):
            continue

        cleaned_items.append({
            "time": e.get("time", ""),
            "timestamp": e.get("timestamp", ""),
            "speaker": e.get("speaker", "Speaker"),
            "text": txt,
            "source": e.get("source", "sarvam"),
            "language": e.get("language", ""),
        })
        last_text = txt

    llm_items = cleaned_items[-60:] if len(cleaned_items) > 60 else cleaned_items
    formatted_lines = [f"[{item['time']}] {item['speaker']}: {item['text']}" for item in llm_items]
    formatted_text = "\n".join(formatted_lines)
    word_count = len(formatted_text.split())

    return {
        "items": cleaned_items,
        "formatted_text": formatted_text,
        "word_count": word_count,
        "line_count": len(llm_items)
    }


# ---------------------------------------------------------------------------
# Ollama LLM Summarizer (Qwen 3 8B on Mac Mini)
# ---------------------------------------------------------------------------

async def check_ollama_status() -> Dict[str, Any]:
    """Checks if Ollama on Mac Mini is accessible via the tunnel."""
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            resp = await client.get(f"{OLLAMA_BASE_URL}/api/tags")
            if resp.status_code == 200:
                data = resp.json()
                models = [m.get("name") for m in data.get("models", [])]
                is_ready = any(OLLAMA_MODEL in m for m in models)
                return {
                    "online": True,
                    "model": OLLAMA_MODEL,
                    "target_model_ready": is_ready,
                    "available_models": models,
                    "endpoint": OLLAMA_BASE_URL,
                    "host": "Mac Mini (via Tunnel)"
                }
    except Exception as e:
        return {
            "online": False,
            "model": OLLAMA_MODEL,
            "error": str(e),
            "endpoint": OLLAMA_BASE_URL,
            "host": "Mac Mini (via Tunnel)"
        }
    return {"online": False, "model": OLLAMA_MODEL}


async def generate_speech_summary(minutes: int = 5, trigger_source: str = "manual") -> Dict[str, Any]:
    """Feeds recent speech transcript to Qwen 3 8B on Mac Mini and extracts structured summary."""
    global is_summarizing, last_auto_summary_time
    if is_summarizing:
        return {"status": "busy", "message": "Another summarization task is already in progress"}

    clean_res = get_clean_transcripts(minutes=minutes)
    context_text = clean_res["formatted_text"]
    if not context_text or clean_res["word_count"] < 8:
        return {
            "status": "empty",
            "message": f"Not enough speech content found in the selected {minutes} min window ({clean_res['word_count']} words)."
        }

    is_summarizing = True
    t0 = time.time()
    try:
        system_prompt = (
            "You are Anup's personal ambient AI pendant intelligence system. Anup wears this pendant throughout his day to capture discussions, meetings, and thoughts.\n"
            "Analyze the spoken conversation transcript and craft a personalized, high-signal briefing directly for Anup.\n\n"
            "Style guidelines:\n"
            "- Speak directly to Anup in the second person ('Hey Anup, ...', 'You discussed...', 'You decided to...').\n"
            "- Focus strictly on high-impact insights: what actually matters, decisions agreed upon, and what Anup should do next.\n"
            "- Filter out trivial chit-chat, background noise, or meaningless filler.\n"
            "- Make decisions concrete ('Decided to...', 'Agreed to...').\n"
            "- Make action items clear and actionable for Anup ('Follow up with...', 'Review...', 'Deploy...').\n\n"
            "Respond ONLY with a valid JSON object matching this schema:\n"
            "{\n"
            '  "title": "Short 3-6 word descriptive title of the topic",\n'
            '  "headline": "Brief 1-sentence personalized takeaway starting with \'Hey Anup, ...\'",\n'
            '  "summary": "Concise 2-3 sentence personalized digest of what occurred and why it matters to Anup",\n'
            '  "decisions": ["Concrete decision 1", ...],\n'
            '  "action_items": ["Action item 1 for Anup", ...],\n'
            '  "key_points": ["Insightful point 1", ...]\n'
            "}"
        )

        user_content = (
            f"Spoken Conversation Transcript ({clean_res['word_count']} words, {clean_res['line_count']} utterances):\n\n"
            f"{context_text}"
        )

        payload = {
            "model": OLLAMA_MODEL,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content}
            ],
            "stream": False,
            "format": "json",
            "options": {
                "temperature": 0.2
            }
        }

        print(f"\n[LLM] Calling {OLLAMA_MODEL} on Mac Mini for summary ({clean_res['word_count']} words)...")
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(f"{OLLAMA_BASE_URL}/api/chat", json=payload)
            if resp.status_code != 200:
                print(f"[LLM] Error from Ollama: {resp.status_code} - {resp.text}")
                return {"status": "error", "message": f"Ollama HTTP {resp.status_code}: {resp.text[:200]}"}

            resp_data = resp.json()
            raw_content = resp_data.get("message", {}).get("content", "").strip()

            parsed = None
            try:
                parsed = json.loads(raw_content)
            except Exception:
                if "```json" in raw_content:
                    extracted_block = raw_content.split("```json")[1].split("```")[0].strip()
                    parsed = json.loads(extracted_block)
                elif "{" in raw_content and "}" in raw_content:
                    start_idx = raw_content.find("{")
                    end_idx = raw_content.rfind("}") + 1
                    parsed = json.loads(raw_content[start_idx:end_idx])

            if not isinstance(parsed, dict):
                return {"status": "error", "message": "Could not parse JSON from model response", "raw": raw_content}

            elapsed = round(time.time() - t0, 1)
            now_dt = datetime.datetime.now()

            title = parsed.get("title") or "Conversation Insights"
            headline = parsed.get("headline") or ""
            summary_text = parsed.get("summary") or ""
            key_points = parsed.get("key_points") or []
            decisions = parsed.get("decisions") or []
            action_items = parsed.get("action_items") or []

            if not headline and summary_text:
                if not summary_text.lower().startswith("hey anup"):
                    headline = f"Hey Anup, {summary_text.split('.')[0]}."
                else:
                    headline = summary_text.split('.')[0] + "."

            if not summary_text and key_points:
                summary_text = " ".join(key_points[:2])
            elif not summary_text and context_text:
                summary_text = f"Discussion covering {clean_res['word_count']} words."

            entry = {
                "id": f"sum_{int(time.time())}",
                "timestamp": now_dt.isoformat(),
                "time": now_dt.strftime("%H:%M:%S"),
                "date": now_dt.strftime("%Y-%m-%d"),
                "minutes_window": minutes,
                "trigger_source": trigger_source,
                "title": title,
                "headline": headline,
                "summary": summary_text,
                "key_points": key_points,
                "decisions": decisions,
                "action_items": action_items,
                "word_count": clean_res["word_count"],
                "utterance_count": clean_res["line_count"],
                "processing_time_sec": elapsed,
                "model": OLLAMA_MODEL,
                "host": "Mac Mini (Qwen 3 8B)"
            }

            log_summary_entry(entry)
            last_auto_summary_time = time.time()
            print(f"[LLM] Summary generated successfully in {elapsed}s: \"{entry['title']}\"")
            return {"status": "success", "summary": entry}

    except Exception as e:
        print(f"[LLM] Exception during summarization: {e}")
        return {"status": "error", "message": str(e)}
    finally:
        is_summarizing = False


# ---------------------------------------------------------------------------
# Background Workers
# ---------------------------------------------------------------------------

async def smart_transcription_worker():
    """Checks the transcription buffer periodically and triggers fast transcription on speech pauses."""
    while True:
        await asyncio.sleep(0.3)
        try:
            if tx_buffer.should_transcribe():
                await tx_buffer.transcribe_and_reset()
        except Exception as e:
            print(f"[STT WORKER ERROR]: {e}")


async def background_summary_worker():
    """Periodically triggers 5-minute summary if new speech is detected."""
    global last_auto_summary_time
    await asyncio.sleep(20)
    while True:
        await asyncio.sleep(30)
        now = time.time()
        if (now - last_auto_summary_time) >= (SUMMARY_INTERVAL_MIN * 60):
            try:
                clean_res = get_clean_transcripts(minutes=SUMMARY_INTERVAL_MIN)
                if clean_res["word_count"] >= 20:
                    print(f"\n[AUTO-SUMMARY] Triggering {SUMMARY_INTERVAL_MIN}-min auto summary ({clean_res['word_count']} words)...")
                    await generate_speech_summary(minutes=SUMMARY_INTERVAL_MIN, trigger_source="auto_5min")
                else:
                    last_auto_summary_time = now
            except Exception as e:
                print(f"[AUTO-SUMMARY] Background error: {e}")


async def background_storage_cleanup_worker():
    """Periodically removes older temporary .wav files to protect disk space."""
    # Run immediate cleanup on startup
    cleanup_old_audio_files(max_age_minutes=5, max_files=6)
    while True:
        await asyncio.sleep(60)
        cleanup_old_audio_files(max_age_minutes=5, max_files=6)


@app.on_event("startup")
async def startup_event():
    asyncio.create_task(smart_transcription_worker())
    asyncio.create_task(background_summary_worker())
    asyncio.create_task(background_storage_cleanup_worker())


# ---------------------------------------------------------------------------
# Webhook Endpoints (Omi App Integration)
# ---------------------------------------------------------------------------

def extract_transcripts_from_payload(body: Any) -> List[Dict[str, Any]]:
    """Extracts speaker and text from various Omi webhook formats."""
    results = []
    if isinstance(body, dict):
        segments = body.get("segments") or body.get("items") or body.get("transcripts") or []
        if isinstance(segments, list) and segments:
            for s in segments:
                if isinstance(s, dict):
                    txt = s.get("text") or s.get("transcript") or s.get("content") or ""
                    spk = s.get("speaker") or ("User" if s.get("is_user") else "Speaker")
                    if txt:
                        results.append({"text": txt, "speaker": spk})
                elif isinstance(s, str) and s.strip():
                    results.append({"text": s.strip(), "speaker": "Speaker"})

        txt = body.get("text") or body.get("transcript") or body.get("transcription") or body.get("message")
        if txt and isinstance(txt, str) and txt.strip():
            spk = body.get("speaker") or ("User" if body.get("is_user") else "Speaker")
            results.append({"text": txt.strip(), "speaker": spk})

    elif isinstance(body, list):
        for item in body:
            if isinstance(item, dict):
                txt = item.get("text") or item.get("transcript") or item.get("content") or ""
                spk = item.get("speaker") or ("User" if item.get("is_user") else "Speaker")
                if txt:
                    results.append({"text": txt, "speaker": spk})
            elif isinstance(item, str) and item.strip():
                results.append({"text": item.strip(), "speaker": "Speaker"})
    elif isinstance(body, str) and body.strip():
        results.append({"text": body.strip(), "speaker": "Speaker"})

    return results


@app.get("/")
@app.get("/omi")
@app.get("/omi/")
def health_check():
    return {
        "status": "online",
        "service": "Dream AI Pendant Console",
        "sarvam_configured": bool(SARVAM_API_KEY),
        "sarvam_model": SARVAM_MODEL,
        "ollama_model": OLLAMA_MODEL,
        "endpoints": {
            "web_ui": "/dream-ai",
            "audio_webhook": "/omi/webhook/audio",
            "transcript_webhook": "/omi/webhook/transcript",
            "memory_webhook": "/omi/webhook/memory",
            "summaries": "/dream-ai/api/summaries",
            "summarize": "/dream-ai/api/summarize"
        }
    }


def check_webhook_auth(request: Request, token: Optional[str] = None):
    if not WEBHOOK_AUTH_TOKEN:
        return
    provided = token
    if not provided:
        auth_header = request.headers.get("authorization", "")
        if auth_header.lower().startswith("bearer "):
            provided = auth_header[7:].strip()
        elif request.headers.get("x-auth-token"):
            provided = request.headers.get("x-auth-token")
    if provided != WEBHOOK_AUTH_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Unauthorized: invalid or missing webhook token"
        )


@app.post("/webhook/audio")
@app.post("/omi/webhook/audio")
async def receive_audio(
    request: Request,
    sample_rate: int = Query(16000, description="Sample rate in Hz"),
    uid: Optional[str] = Query(None, description="User ID from Omi app"),
    token: Optional[str] = Query(None, description="Auth token")
):
    """
    Receives raw PCM16 mono audio bytes from Omi app.
    Feeds into SmartTranscriptionBuffer which detects pauses and triggers STT.
    """
    check_webhook_auth(request, token)
    audio_bytes = await request.body()
    if not audio_bytes:
        return Response(status_code=status.HTTP_200_OK)

    tx_buffer.add_audio(audio_bytes, sample_rate, uid)

    session_state["last_packet_time"] = tx_buffer.last_packet_time
    session_state["sample_rate"] = sample_rate
    session_state["uid"] = uid
    session_state["total_bytes_received"] = tx_buffer.total_bytes_received
    session_state["active_recording_seconds"] = tx_buffer.active_recording_seconds

    return Response(status_code=status.HTTP_200_OK)


@app.post("/webhook/transcript")
@app.post("/omi/webhook/transcript")
async def receive_transcript(
    request: Request,
    uid: Optional[str] = Query(None),
    token: Optional[str] = Query(None)
):
    check_webhook_auth(request, token)
    try:
        body = await request.json()
    except Exception:
        raw = (await request.body()).decode("utf-8", errors="replace")
        body = {"raw": raw}

    now_str = datetime.datetime.now().strftime("%H:%M:%S")
    now_iso = datetime.datetime.now().isoformat()

    extracted = extract_transcripts_from_payload(body)
    if extracted:
        for item in extracted:
            entry = {
                "time": now_str,
                "timestamp": now_iso,
                "speaker": item.get("speaker", "Speaker"),
                "text": item.get("text", ""),
                "source": "omi_app",
                "uid": uid,
            }
            log_transcript_entry(entry)
    else:
        preview_text = json.dumps(body) if not isinstance(body, str) else body
        if preview_text and preview_text != "{}" and preview_text != "[]":
            entry = {
                "time": now_str,
                "timestamp": now_iso,
                "speaker": "Omi Device",
                "text": preview_text,
                "source": "omi_app",
                "uid": uid,
            }
            log_transcript_entry(entry)

    return {"status": "ok"}


@app.post("/webhook/memory")
@app.post("/omi/webhook/memory")
async def receive_memory(
    request: Request,
    uid: Optional[str] = Query(None),
    token: Optional[str] = Query(None)
):
    check_webhook_auth(request, token)
    try:
        body = await request.json()
    except Exception:
        body = {"raw": (await request.body()).decode("utf-8", errors="replace")}

    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry = {
        "time": now_str,
        "timestamp": datetime.datetime.now().isoformat(),
        "uid": uid,
        "data": body
    }
    log_memory_entry(entry)
    print(f"\n[MEMORY CREATED {now_str}]:\n{json.dumps(body, indent=2)}")

    return {"status": "ok"}


# ---------------------------------------------------------------------------
# Dream AI APIs
# ---------------------------------------------------------------------------

@app.get("/dream-ai/api/stats")
async def get_stats():
    now = time.time()
    last_time = session_state.get("last_packet_time")
    is_live = last_time is not None and (now - last_time < 20.0)

    # Audio storage footprint
    wav_files = [f for f in os.listdir(OUTPUT_DIR) if f.endswith(".wav")]
    total_audio_bytes = sum(os.path.getsize(os.path.join(OUTPUT_DIR, f)) for f in wav_files)
    audio_mb = round(total_audio_bytes / (1024 * 1024), 2)

    transcript_count = 0
    if os.path.exists(TRANSCRIPTS_LOG):
        with open(TRANSCRIPTS_LOG, "r", encoding="utf-8") as f:
            transcript_count = sum(1 for _ in f)

    summary_count = 0
    if os.path.exists(SUMMARIES_LOG):
        with open(SUMMARIES_LOG, "r", encoding="utf-8") as f:
            summary_count = sum(1 for _ in f)

    return {
        "is_live": is_live,
        "last_seen_sec": round(now - last_time, 1) if last_time else None,
        "sample_rate": session_state.get("sample_rate", 16000),
        "audio_storage_mb": audio_mb,
        "audio_files_count": len(wav_files),
        "total_transcripts": transcript_count,
        "total_summaries": summary_count,
        "sarvam_model": SARVAM_MODEL,
        "sarvam_configured": bool(SARVAM_API_KEY),
        "ollama_model": OLLAMA_MODEL,
        "active_recording_seconds": round(session_state.get("active_recording_seconds", 0.0), 1),
    }


@app.get("/dream-ai/api/llm/status")
async def get_llm_status():
    status_data = await check_ollama_status()
    status_data["is_summarizing"] = is_summarizing
    status_data["summary_interval_min"] = SUMMARY_INTERVAL_MIN
    return status_data


@app.get("/dream-ai/api/transcripts")
async def get_transcripts(limit: int = 60):
    entries = []
    if os.path.exists(TRANSCRIPTS_LOG):
        with open(TRANSCRIPTS_LOG, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        entries.append(json.loads(line))
                    except Exception:
                        pass
    entries.reverse()  # Newest first
    return entries[:limit]


@app.get("/dream-ai/api/transcripts/clean")
async def get_clean_transcripts_endpoint(minutes: int = Query(5)):
    return get_clean_transcripts(minutes=minutes)


@app.get("/dream-ai/api/summaries")
@app.get("/omi/api/summaries")
async def list_summaries(limit: int = 30):
    return get_summaries(limit=limit)


@app.post("/dream-ai/api/summarize")
@app.post("/omi/api/summarize")
async def trigger_summarization(minutes: int = Query(5, description="Minutes window, 0 for all conversation")):
    res = await generate_speech_summary(minutes=minutes, trigger_source="manual")
    if res.get("status") == "error":
        raise HTTPException(status_code=500, detail=res.get("message"))
    return res


@app.post("/dream-ai/api/storage/clean")
async def trigger_audio_cleanup():
    """Manual endpoint to immediately delete old temporary .wav files."""
    res = cleanup_old_audio_files(max_age_minutes=0, max_files=2)
    return {"status": "ok", "cleaned": res}


@app.websocket("/dream-ai/ws/stream")
@app.websocket("/ws/stream")
async def websocket_stream(websocket: WebSocket):
    await websocket.accept()
    ws_clients.append(websocket)
    try:
        await websocket.send_json({"type": "init", "status": "connected", "model": OLLAMA_MODEL})
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        if websocket in ws_clients:
            ws_clients.remove(websocket)
    except Exception:
        if websocket in ws_clients:
            ws_clients.remove(websocket)


@app.get("/dream-ai/api/memories")
async def get_memories(limit: int = 20):
    entries = []
    if os.path.exists(MEMORIES_LOG):
        with open(MEMORIES_LOG, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        entries.append(json.loads(line))
                    except Exception:
                        pass
    entries.reverse()
    return entries[:limit]


@app.get("/dream-ai/api/settings")
async def get_settings():
    return {
        "sarvam_model": SARVAM_MODEL,
        "sarvam_language": SARVAM_LANGUAGE,
        "sarvam_mode": SARVAM_MODE,
        "ollama_model": OLLAMA_MODEL,
        "summary_interval_min": SUMMARY_INTERVAL_MIN
    }


@app.post("/dream-ai/api/settings")
async def update_settings(request: Request):
    global SARVAM_LANGUAGE, SARVAM_MODE
    body = await request.json()
    if "language_code" in body:
        SARVAM_LANGUAGE = body["language_code"]
    if "mode" in body:
        SARVAM_MODE = body["mode"]
    print(f"\n[SETTINGS] Updated Sarvam language={SARVAM_LANGUAGE}, mode={SARVAM_MODE}")
    return {"status": "ok", "language_code": SARVAM_LANGUAGE, "mode": SARVAM_MODE}


# ---------------------------------------------------------------------------
# Mobile-Friendly Web Application Dashboard HTML
# ---------------------------------------------------------------------------

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en" class="dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>Dream AI - Pendant Console & Intelligence</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
  <script>
    tailwind.config = {
      darkMode: 'class',
      theme: {
        extend: {
          colors: {
            brand: { 500: '#6366f1', 600: '#4f46e5', 700: '#4338ca' }
          }
        }
      }
    }
  </script>
  <style>
    body { background-color: #0b0f19; -webkit-tap-highlight-color: transparent; }
    .glass-card { background: rgba(17, 24, 39, 0.75); backdrop-filter: blur(14px); border: 1px solid rgba(255, 255, 255, 0.08); }
    .glass-card-accent { background: rgba(23, 31, 51, 0.85); backdrop-filter: blur(16px); border: 1px solid rgba(99, 102, 241, 0.25); }
    .custom-scroll::-webkit-scrollbar { width: 5px; }
    .custom-scroll::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.18); border-radius: 4px; }
    .custom-scroll { -webkit-overflow-scrolling: touch; }
    @keyframes slideIn {
      from { opacity: 0; transform: translateY(6px); }
      to { opacity: 1; transform: translateY(0); }
    }
    .slide-in { animation: slideIn 0.25s ease-out; }
  </style>
</head>
<body class="text-gray-100 min-h-screen flex flex-col font-sans">

  <!-- Responsive Header -->
  <header class="glass-card sticky top-0 z-50 px-4 sm:px-6 py-3 border-b border-gray-800 flex flex-col sm:flex-row sm:items-center justify-between gap-3">
    <div class="flex items-center justify-between">
      <div class="flex items-center space-x-3">
        <div class="w-9 h-9 sm:w-10 sm:h-10 rounded-xl bg-gradient-to-tr from-indigo-500 via-purple-500 to-pink-500 flex items-center justify-center shadow-lg shadow-indigo-500/30 shrink-0">
          <i class="fa-solid fa-microphone-lines text-white text-base sm:text-lg"></i>
        </div>
        <div>
          <div class="flex items-center space-x-2">
            <h1 class="text-lg sm:text-xl font-bold tracking-tight bg-gradient-to-r from-white via-indigo-100 to-purple-200 bg-clip-text text-transparent">
              Dream AI Pendant
            </h1>
            <span class="px-1.5 py-0.5 rounded text-[9px] font-semibold bg-indigo-900/60 text-indigo-300 border border-indigo-700/60">v2.2</span>
          </div>
          <p class="text-[11px] text-gray-400">Ambient Intelligence & Edge LLM</p>
        </div>
      </div>

      <!-- Mobile Endpoint Button (Visible on XS screens) -->
      <button onclick="toggleSetupModal()" class="sm:hidden p-2 rounded-lg text-xs font-semibold bg-indigo-600/80 hover:bg-indigo-600 text-white">
        <i class="fa-solid fa-link"></i>
      </button>
    </div>

    <!-- Right Controls (Responsive wrap) -->
    <div class="flex flex-wrap items-center gap-2 text-xs">
      <!-- Language Selector -->
      <div class="flex items-center space-x-1.5 bg-gray-900 border border-gray-700 rounded-lg px-2 py-1 text-[11px]">
        <i class="fa-solid fa-language text-indigo-400"></i>
        <select id="langSelect" onchange="changeLanguage(this.value)" class="bg-transparent text-gray-200 outline-none font-medium cursor-pointer max-w-[140px] truncate">
          <option value="unknown">🌐 Auto (Detect)</option>
          <option value="ne-IN">🇳🇵 Nepali (ne-IN)</option>
          <option value="hi-IN">🇮🇳 Hindi (hi-IN)</option>
          <option value="en-IN">🇬🇧 English (en-IN)</option>
          <option value="codemix">🔤 Hinglish (Codemix)</option>
        </select>
      </div>

      <!-- LLM Status Pill -->
      <div id="llmPill" class="flex items-center space-x-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium bg-gray-900 text-gray-300 border border-gray-700">
        <span class="w-2 h-2 rounded-full bg-emerald-400" id="llmDot"></span>
        <span id="llmText" class="truncate max-w-[130px]">Qwen 3 (8B)</span>
      </div>

      <!-- Live Device Streaming Status -->
      <div id="statusPill" class="flex items-center space-x-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium bg-gray-800 text-gray-400 border border-gray-700">
        <span class="w-2 h-2 rounded-full bg-gray-500" id="statusDot"></span>
        <span id="statusText">Checking...</span>
      </div>

      <!-- Desktop Endpoints Button -->
      <button onclick="toggleSetupModal()" class="hidden sm:flex px-3 py-1 rounded-lg text-xs font-semibold bg-indigo-600 hover:bg-indigo-500 transition shadow-md items-center space-x-1.5">
        <i class="fa-solid fa-link"></i>
        <span>Endpoints</span>
      </button>
    </div>
  </header>

  <!-- Main Content Container -->
  <main class="flex-1 max-w-7xl w-full mx-auto p-3.5 sm:p-6 space-y-4 sm:space-y-6">

    <!-- Top Stats Row (2 cols on mobile, 4 on desktop) -->
    <div class="grid grid-cols-2 md:grid-cols-4 gap-2.5 sm:gap-4">
      <div class="glass-card rounded-xl sm:rounded-2xl p-3 sm:p-4">
        <div class="text-[11px] font-medium text-gray-400 flex items-center justify-between">
          <span>Streaming Status</span>
          <i class="fa-solid fa-tower-broadcast text-indigo-400"></i>
        </div>
        <div class="text-base sm:text-xl font-bold mt-1 text-emerald-300 truncate" id="statLiveLabel">Standby</div>
        <div class="text-[10px] text-gray-500" id="statLastSeen">Waiting for audio</div>
      </div>

      <div class="glass-card rounded-xl sm:rounded-2xl p-3 sm:p-4">
        <div class="text-[11px] font-medium text-gray-400 flex items-center justify-between">
          <span>Transcripts</span>
          <i class="fa-solid fa-comment-dots text-purple-400"></i>
        </div>
        <div class="text-xl sm:text-2xl font-bold mt-1 text-white" id="statTranscripts">0</div>
        <div class="text-[10px] text-gray-500">Captured segments</div>
      </div>

      <div class="glass-card rounded-xl sm:rounded-2xl p-3 sm:p-4">
        <div class="text-[11px] font-medium text-gray-400 flex items-center justify-between">
          <span>AI Summaries</span>
          <i class="fa-solid fa-wand-magic-sparkles text-amber-400"></i>
        </div>
        <div class="text-xl sm:text-2xl font-bold mt-1 text-white" id="statSummaries">0</div>
        <div class="text-[10px] text-gray-500">Auto & on-demand</div>
      </div>

      <div class="glass-card rounded-xl sm:rounded-2xl p-3 sm:p-4 border border-indigo-900/40">
        <div class="text-[11px] font-medium text-gray-400 flex items-center justify-between">
          <span>Audio Storage</span>
          <i class="fa-solid fa-hard-drive text-cyan-400"></i>
        </div>
        <div class="text-base sm:text-xl font-bold mt-1 text-cyan-300" id="statStorage">0.0 MB</div>
        <div class="text-[10px] text-emerald-400 flex items-center space-x-1">
          <i class="fa-solid fa-recycle text-[9px]"></i>
          <span>Auto-cleaned (5m)</span>
        </div>
      </div>
    </div>

    <!-- AI Intelligence & Summary Card (FULL WIDTH / PROMINENT) -->
    <div class="glass-card-accent rounded-xl sm:rounded-2xl p-4 sm:p-5 shadow-2xl relative overflow-hidden">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 pb-3 sm:pb-4 border-b border-gray-800">
        <div class="flex items-center space-x-3">
          <div class="w-8 h-8 sm:w-9 sm:h-9 rounded-xl bg-indigo-600/30 border border-indigo-500/40 flex items-center justify-center shrink-0">
            <i class="fa-solid fa-wand-magic-sparkles text-indigo-400 text-xs sm:text-sm"></i>
          </div>
          <div>
            <h2 class="font-bold text-sm sm:text-base text-white flex items-center space-x-2">
              <span>AI Executive Summary & Decisions</span>
              <span class="text-[10px] px-2 py-0.5 rounded-full bg-indigo-950 text-indigo-300 border border-indigo-800 font-normal">
                Auto 5-Min
              </span>
            </h2>
            <p class="text-[11px] text-gray-400">Qwen 3 (8B) model running on Mac Mini</p>
          </div>
        </div>

        <!-- Controls -->
        <div class="flex items-center space-x-2">
          <div class="flex items-center space-x-1.5 bg-gray-900/90 border border-gray-700 rounded-lg px-2 py-1 text-xs">
            <span class="text-gray-400 text-[10px]">Window:</span>
            <select id="summaryWindowSelect" class="bg-transparent text-gray-200 outline-none text-[11px] font-medium cursor-pointer">
              <option value="5">Last 5 Min</option>
              <option value="15">Last 15 Min</option>
              <option value="30">Last 30 Min</option>
              <option value="0">All Conversation</option>
            </select>
          </div>

          <button id="btnSummarize" onclick="triggerSummaryNow()" class="flex-1 sm:flex-none px-3.5 py-1.5 rounded-lg text-xs font-semibold bg-gradient-to-r from-indigo-600 to-purple-600 hover:from-indigo-500 hover:to-purple-500 text-white shadow-lg shadow-indigo-600/30 flex items-center justify-center space-x-1.5 transition">
            <i class="fa-solid fa-bolt text-yellow-300" id="summarizeIcon"></i>
            <span id="summarizeBtnText">Generate Summary Now</span>
          </button>
        </div>
      </div>

      <!-- Summary Display Area -->
      <div id="summaryContent" class="pt-4">
        <div id="summaryLoading" class="hidden py-8 sm:py-12 text-center space-y-2.5">
          <i class="fa-solid fa-circle-notch fa-spin text-2xl sm:text-3xl text-indigo-400"></i>
          <p class="text-xs sm:text-sm font-medium text-gray-200">Qwen 3 (8B) is analyzing your conversation on Mac Mini...</p>
          <p class="text-[11px] text-gray-500">Synthesizing key discussion points, decisions taken, and action items.</p>
        </div>

        <div id="summaryContainer">
          <div class="text-center text-gray-500 text-xs py-8">
            <i class="fa-regular fa-lightbulb text-gray-600 text-2xl mb-2 block"></i>
            No conversation summaries generated yet. Speak near your pendant or tap "Generate Summary Now".
          </div>
        </div>
      </div>

      <!-- Past Summaries History Accordion -->
      <div class="mt-3 pt-3 border-t border-gray-800/80">
        <button onclick="toggleHistoryList()" class="text-xs text-indigo-400 hover:text-indigo-300 flex items-center space-x-1.5 font-medium">
          <i class="fa-solid fa-clock-rotate-left"></i>
          <span id="historyToggleText">View Previous Summaries</span>
          <i class="fa-solid fa-chevron-down text-[10px] ml-1 transition" id="historyChevron"></i>
        </button>
        <div id="historyListContainer" class="hidden mt-2.5 space-y-2 max-h-56 overflow-y-auto custom-scroll pr-1"></div>
      </div>
    </div>

    <!-- Main Grid: Live Transcripts & Sidebar -->
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-4 sm:gap-6">

      <!-- Left 2 Columns: Live Speech Transcript Stream -->
      <div class="lg:col-span-2 glass-card rounded-xl sm:rounded-2xl p-4 sm:p-5 flex flex-col h-[520px]">
        <div class="flex items-center justify-between pb-3 border-b border-gray-800">
          <div class="flex items-center space-x-2">
            <span class="w-2.5 h-2.5 rounded-full bg-emerald-400 animate-pulse"></span>
            <h2 class="font-semibold text-xs sm:text-sm tracking-wide text-gray-200">Live Speech Transcript Stream</h2>
          </div>

          <!-- Controls -->
          <div class="flex items-center space-x-2 text-xs">
            <button onclick="toggleAutoScroll()" id="btnAutoScroll" class="px-2 py-1 rounded bg-gray-900 border border-gray-700 text-indigo-300 text-[11px] flex items-center space-x-1">
              <i class="fa-solid fa-arrow-down-short-wide"></i>
              <span id="autoScrollLabel">Auto-Scroll: ON</span>
            </button>
            <button onclick="copyAllTranscripts()" class="px-2 py-1 rounded bg-gray-900 border border-gray-700 hover:bg-gray-800 text-gray-300 text-[11px] flex items-center space-x-1" title="Copy transcript">
              <i class="fa-regular fa-copy"></i>
              <span class="hidden sm:inline">Copy</span>
            </button>
            <button onclick="clearTranscriptFeed()" class="px-2 py-1 rounded bg-gray-900 border border-gray-700 hover:bg-gray-800 text-gray-300 text-[11px]" title="Clear view">
              <i class="fa-regular fa-trash-can"></i>
            </button>
          </div>
        </div>

        <!-- Transcript Feed (Smooth scrolling, real-time cards) -->
        <div id="transcriptFeed" class="flex-1 overflow-y-auto space-y-2.5 pt-3.5 custom-scroll pr-1">
          <div class="text-center text-gray-500 text-xs py-20" id="emptyTranscriptPlaceholder">
            <i class="fa-solid fa-microphone text-gray-600 text-2xl mb-2 block"></i>
            Waiting for speech input... Speak into your Omi pendant!
          </div>
        </div>
      </div>

      <!-- Right Column: Sidebar (Memories + System Health) -->
      <div class="space-y-4 sm:space-y-6">

        <!-- Conversation Memories Card -->
        <div class="glass-card rounded-xl sm:rounded-2xl p-4 sm:p-5">
          <div class="flex items-center justify-between pb-3 border-b border-gray-800">
            <h2 class="font-semibold text-xs sm:text-sm tracking-wide text-gray-200 flex items-center space-x-2">
              <i class="fa-solid fa-brain text-purple-400"></i>
              <span>Omi App Memories</span>
            </h2>
            <button onclick="fetchMemories()" class="text-xs text-indigo-400 hover:text-indigo-300">
              <i class="fa-solid fa-rotate-right"></i>
            </button>
          </div>
          <div id="memoriesList" class="space-y-2 pt-3 max-h-56 overflow-y-auto custom-scroll">
            <div class="text-xs text-gray-500 text-center py-6">No memories synced from Omi app yet.</div>
          </div>
        </div>

        <!-- System & Storage Health Card (Replacing Audio Player) -->
        <div class="glass-card rounded-xl sm:rounded-2xl p-4 sm:p-5 space-y-3">
          <h2 class="font-semibold text-xs sm:text-sm tracking-wide text-gray-200 pb-2 border-b border-gray-800 flex items-center space-x-2">
            <i class="fa-solid fa-server text-cyan-400"></i>
            <span>System & Storage Health</span>
          </h2>

          <div class="space-y-2 text-xs">
            <div class="flex items-center justify-between p-2 rounded-lg bg-gray-900/60 border border-gray-800">
              <span class="text-gray-400">Audio Sample Rate</span>
              <span class="font-mono text-indigo-300 font-semibold" id="healthRate">16,000 Hz</span>
            </div>

            <div class="flex items-center justify-between p-2 rounded-lg bg-gray-900/60 border border-gray-800">
              <span class="text-gray-400">Audio Storage on Disk</span>
              <span class="font-mono text-cyan-300 font-semibold" id="healthStorage">0.0 MB</span>
            </div>

            <div class="flex items-center justify-between p-2 rounded-lg bg-gray-900/60 border border-gray-800">
              <span class="text-gray-400">STT Turnaround</span>
              <span class="font-mono text-emerald-300 font-semibold">~4 - 6s Latency</span>
            </div>
          </div>

          <div class="pt-1 flex items-center space-x-2">
            <button onclick="triggerStorageCleanNow()" class="w-full py-2 px-3 rounded-lg text-xs font-semibold bg-gray-800 hover:bg-gray-700 text-gray-200 border border-gray-700 transition flex items-center justify-center space-x-1.5">
              <i class="fa-solid fa-broom text-amber-400"></i>
              <span>Clean Temporary Audio Now</span>
            </button>
          </div>
        </div>

      </div>

    </div>

  </main>

  <!-- Webhook Setup Modal -->
  <div id="setupModal" class="fixed inset-0 bg-black/75 backdrop-blur-sm z-50 hidden flex items-center justify-center p-3 sm:p-4">
    <div class="glass-card max-w-lg w-full rounded-2xl p-5 sm:p-6 border border-gray-700 shadow-2xl max-h-[90vh] overflow-y-auto custom-scroll">
      <div class="flex items-center justify-between pb-3 border-b border-gray-800">
        <h3 class="text-base sm:text-lg font-bold text-white flex items-center space-x-2">
          <i class="fa-solid fa-mobile-screen text-indigo-400"></i>
          <span>Omi App Webhook Setup</span>
        </h3>
        <button onclick="toggleSetupModal()" class="text-gray-400 hover:text-white p-1">
          <i class="fa-solid fa-xmark text-lg"></i>
        </button>
      </div>

      <div class="py-4 text-xs text-gray-300 space-y-3 leading-relaxed">
        <p>In your Omi Mobile App Developer Settings, enter these endpoints:</p>

        <div class="space-y-3 pt-1">
          <div>
            <label class="block text-gray-400 text-[11px] font-semibold mb-1">
              Audio Bytes Webhook (Live Audio Stream)
            </label>
            <div class="flex items-center space-x-2">
              <input type="text" readonly value="https://aadeshai.xyz/omi/webhook/audio"
                id="urlAudio" class="w-full bg-gray-900 border border-gray-700 text-xs text-indigo-300 rounded-lg p-2 font-mono">
              <button onclick="copyToClipboard('urlAudio')" class="px-3 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg text-xs font-medium">
                Copy
              </button>
            </div>
          </div>

          <div>
            <label class="block text-gray-400 text-[11px] font-semibold mb-1">
              Real-Time Transcript Webhook
            </label>
            <div class="flex items-center space-x-2">
              <input type="text" readonly value="https://aadeshai.xyz/omi/webhook/transcript"
                id="urlTranscript" class="w-full bg-gray-900 border border-gray-700 text-xs text-purple-300 rounded-lg p-2 font-mono">
              <button onclick="copyToClipboard('urlTranscript')" class="px-3 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg text-xs font-medium">
                Copy
              </button>
            </div>
          </div>

          <div>
            <label class="block text-gray-400 text-[11px] font-semibold mb-1">
              Memory Creation Webhook
            </label>
            <div class="flex items-center space-x-2">
              <input type="text" readonly value="https://aadeshai.xyz/omi/webhook/memory"
                id="urlMemory" class="w-full bg-gray-900 border border-gray-700 text-xs text-emerald-300 rounded-lg p-2 font-mono">
              <button onclick="copyToClipboard('urlMemory')" class="px-3 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg text-xs font-medium">
                Copy
              </button>
            </div>
          </div>
        </div>
      </div>

      <div class="pt-3 border-t border-gray-800 text-right">
        <button onclick="toggleSetupModal()" class="px-4 py-2 bg-indigo-600 hover:bg-indigo-500 rounded-lg text-xs font-semibold">
          Got it
        </button>
      </div>
    </div>
  </div>

  <script>
    let allSummariesList = [];
    let isSummarizingNow = false;
    let autoScrollEnabled = true;
    let ws = null;
    let renderedTranscriptTimestamps = new Set();
    let allTranscriptsData = [];

    function toggleSetupModal() {
      const m = document.getElementById('setupModal');
      m.classList.toggle('hidden');
    }

    function toggleAutoScroll() {
      autoScrollEnabled = !autoScrollEnabled;
      const label = document.getElementById('autoScrollLabel');
      const btn = document.getElementById('btnAutoScroll');
      if (autoScrollEnabled) {
        label.textContent = 'Auto-Scroll: ON';
        btn.className = 'px-2 py-1 rounded bg-gray-900 border border-gray-700 text-indigo-300 text-[11px] flex items-center space-x-1';
      } else {
        label.textContent = 'Auto-Scroll: OFF';
        btn.className = 'px-2 py-1 rounded bg-gray-900 border border-gray-700 text-gray-400 text-[11px] flex items-center space-x-1';
      }
    }

    function clearTranscriptFeed() {
      document.getElementById('transcriptFeed').innerHTML = `
        <div class="text-center text-gray-500 text-xs py-20" id="emptyTranscriptPlaceholder">
          <i class="fa-solid fa-microphone text-gray-600 text-2xl mb-2 block"></i>
          Screen cleared. Waiting for new speech input...
        </div>
      `;
      renderedTranscriptTimestamps.clear();
      allTranscriptsData = [];
    }

    function copyAllTranscripts() {
      if (allTranscriptsData.length === 0) {
        alert('No transcripts captured yet.');
        return;
      }
      const text = allTranscriptsData.map(t => `[${t.time}] ${t.speaker}: ${t.text}`).join('\\n');
      navigator.clipboard.writeText(text);
      alert('Copied conversation transcript to clipboard!');
    }

    function toggleHistoryList() {
      const container = document.getElementById('historyListContainer');
      const chevron = document.getElementById('historyChevron');
      container.classList.toggle('hidden');
      chevron.style.transform = container.classList.contains('hidden') ? 'rotate(0deg)' : 'rotate(180deg)';
    }

    function copyToClipboard(elementId) {
      const el = document.getElementById(elementId);
      navigator.clipboard.writeText(el.value);
      alert('Copied to clipboard: ' + el.value);
    }

    async function changeLanguage(val) {
      let lang = val;
      let mode = 'transcribe';
      if (val === 'codemix') {
        lang = 'auto';
        mode = 'codemix';
      }
      try {
        await fetch('/dream-ai/api/settings', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({language_code: lang, mode: mode})
        });
      } catch (e) {
        console.error('Failed to update language:', e);
      }
    }

    async function triggerStorageCleanNow() {
      try {
        const res = await fetch('/dream-ai/api/storage/clean', { method: 'POST' });
        const data = await res.json();
        alert(`Storage Cleaned! Freed ${data.cleaned.freed_mb} MB.`);
        fetchStats();
      } catch (e) {
        alert('Clean failed: ' + e);
      }
    }

    async function fetchStats() {
      try {
        const res = await fetch('/dream-ai/api/stats');
        const data = await res.json();

        const dot = document.getElementById('statusDot');
        const text = document.getElementById('statusText');
        const pill = document.getElementById('statusPill');
        const liveLabel = document.getElementById('statLiveLabel');
        const lastSeen = document.getElementById('statLastSeen');

        if (data.is_live) {
          dot.className = 'w-2 h-2 rounded-full bg-emerald-400 animate-ping';
          text.textContent = 'Device Streaming Live';
          pill.className = 'flex items-center space-x-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium bg-emerald-950/60 text-emerald-300 border border-emerald-800';
          liveLabel.textContent = 'Streaming Live';
          liveLabel.className = 'text-base sm:text-xl font-bold mt-1 text-emerald-400';
          lastSeen.textContent = `Active now (${data.sample_rate}Hz)`;
        } else if (data.last_seen_sec !== null) {
          dot.className = 'w-2 h-2 rounded-full bg-amber-400';
          text.textContent = `Last seen ${data.last_seen_sec}s ago`;
          pill.className = 'flex items-center space-x-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium bg-amber-950/60 text-amber-300 border border-amber-800';
          liveLabel.textContent = 'Idle';
          liveLabel.className = 'text-base sm:text-xl font-bold mt-1 text-amber-300';
          lastSeen.textContent = `Last packet ${data.last_seen_sec}s ago`;
        } else {
          dot.className = 'w-2 h-2 rounded-full bg-gray-500';
          text.textContent = 'Awaiting Device';
          pill.className = 'flex items-center space-x-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium bg-gray-800 text-gray-400 border border-gray-700';
          liveLabel.textContent = 'Standby';
          liveLabel.className = 'text-base sm:text-xl font-bold mt-1 text-gray-300';
          lastSeen.textContent = 'No packets received yet';
        }

        document.getElementById('statTranscripts').textContent = data.total_transcripts || 0;
        document.getElementById('statSummaries').textContent = data.total_summaries || 0;
        const storageMb = (data.audio_storage_mb !== undefined) ? data.audio_storage_mb : 0.0;
        document.getElementById('statStorage').textContent = `${storageMb} MB`;
        document.getElementById('healthStorage').textContent = `${storageMb} MB (${data.audio_files_count || 0} clips)`;
        document.getElementById('healthRate').textContent = `${data.sample_rate || 16000} Hz`;
      } catch (err) {
        console.error('Stats error:', err);
      }
    }

    async function fetchLlmStatus() {
      try {
        const res = await fetch('/dream-ai/api/llm/status');
        const data = await res.json();

        const dot = document.getElementById('llmDot');
        const text = document.getElementById('llmText');
        const pill = document.getElementById('llmPill');

        if (data.online) {
          dot.className = 'w-2 h-2 rounded-full bg-emerald-400';
          text.textContent = `${data.model} (Mac Mini)`;
          pill.className = 'flex items-center space-x-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium bg-emerald-950/40 text-emerald-300 border border-emerald-800/60';
        } else {
          dot.className = 'w-2 h-2 rounded-full bg-rose-500';
          text.textContent = 'LLM Tunnel Disconnected';
          pill.className = 'flex items-center space-x-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium bg-rose-950/40 text-rose-300 border border-rose-800/60';
        }
      } catch (e) {
        console.error('LLM status error:', e);
      }
    }

    function createTranscriptCard(item) {
      const isSarvam = item.source === 'sarvam';
      const badgeClass = isSarvam ? 'bg-indigo-900/60 text-indigo-300 border-indigo-700/60' : 'bg-purple-900/60 text-purple-300 border-purple-700/60';
      const badgeText = isSarvam ? 'Sarvam Saaras' : 'Omi App';
      const langBadge = item.language ? `<span class="px-1.5 py-0.5 rounded text-[9px] font-mono bg-gray-800 text-gray-400 border border-gray-700">${item.language}</span>` : '';
      const speaker = item.speaker || 'Speaker';
      const text = item.text || item.transcript || '';

      const div = document.createElement('div');
      div.className = 'p-3 rounded-xl bg-gray-900/60 border border-gray-800/90 hover:border-gray-700 transition slide-in';
      div.innerHTML = `
        <div class="flex items-center justify-between text-[11px] text-gray-400 mb-1">
          <div class="flex items-center space-x-1.5">
            <span class="font-semibold text-gray-200">${speaker}</span>
            <span class="px-2 py-0.5 rounded text-[10px] font-medium border ${badgeClass}">${badgeText}</span>
            ${langBadge}
          </div>
          <span class="text-[10px] text-gray-500">${item.time || ''}</span>
        </div>
        <p class="text-xs sm:text-sm text-gray-100 leading-relaxed">${text}</p>
      `;
      return div;
    }

    async function fetchTranscripts() {
      try {
        const res = await fetch('/dream-ai/api/transcripts');
        const list = await res.json();
        if (!list || list.length === 0) return;

        allTranscriptsData = list;
        const container = document.getElementById('transcriptFeed');
        const placeholder = document.getElementById('emptyTranscriptPlaceholder');
        if (placeholder) placeholder.remove();

        // Chronological order (earliest at top, latest at bottom)
        const chronological = [...list].reverse();
        container.innerHTML = '';
        renderedTranscriptTimestamps.clear();

        chronological.forEach(item => {
          const key = (item.timestamp || item.time || '') + (item.text || '');
          renderedTranscriptTimestamps.add(key);
          container.appendChild(createTranscriptCard(item));
        });

        if (autoScrollEnabled) {
          container.scrollTop = container.scrollHeight;
        }
      } catch (err) {
        console.error('Transcripts error:', err);
      }
    }

    function connectWebSocket() {
      const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const wsUrl = `${proto}//${window.location.host}/dream-ai/ws/stream`;
      ws = new WebSocket(wsUrl);

      ws.onopen = () => {
        console.log('[WS] Connected to live stream');
      };

      ws.onmessage = (event) => {
        try {
          const payload = JSON.parse(event.data);
          if (payload.type === 'transcript') {
            const item = payload.data;
            const key = (item.timestamp || item.time || '') + (item.text || '');
            if (!renderedTranscriptTimestamps.has(key)) {
              renderedTranscriptTimestamps.add(key);
              allTranscriptsData.unshift(item);
              const container = document.getElementById('transcriptFeed');
              const placeholder = document.getElementById('emptyTranscriptPlaceholder');
              if (placeholder) placeholder.remove();

              container.appendChild(createTranscriptCard(item));
              if (autoScrollEnabled) {
                container.scrollTop = container.scrollHeight;
              }
            }
          } else if (payload.type === 'summary') {
            fetchSummaries();
          }
        } catch (e) {
          console.error('[WS] Parse error:', e);
        }
      };

      ws.onclose = () => {
        console.log('[WS] Closed, retrying in 3s...');
        setTimeout(connectWebSocket, 3000);
      };

      ws.onerror = () => {
        if (ws) ws.close();
      };
    }

    async function fetchSummaries() {
      try {
        const res = await fetch('/dream-ai/api/summaries');
        const list = await res.json();
        allSummariesList = list;

        const container = document.getElementById('summaryContainer');
        const historyContainer = document.getElementById('historyListContainer');

        if (!list || list.length === 0) {
          if (!isSummarizingNow) {
            container.innerHTML = `
              <div class="text-center text-gray-500 text-xs py-8">
                <i class="fa-regular fa-lightbulb text-gray-600 text-2xl mb-2 block"></i>
                No conversation summaries generated yet. Speak near your pendant or tap "Generate Summary Now".
              </div>
            `;
          }
          return;
        }

        renderSummaryCard(list[0], container);

        if (list.length > 1) {
          historyContainer.innerHTML = list.slice(1).map((s, idx) => `
            <div class="p-2.5 rounded-xl bg-gray-900/60 border border-gray-800 text-xs flex items-center justify-between hover:border-gray-700 transition cursor-pointer" onclick="selectHistoricalSummary(${idx + 1})">
              <div class="flex items-center space-x-2 truncate">
                <span class="w-1.5 h-1.5 rounded-full bg-indigo-400 shrink-0"></span>
                <span class="font-semibold text-gray-200 truncate">${s.title || 'Summary'}</span>
                <span class="text-[10px] text-gray-500 shrink-0">${s.time}</span>
              </div>
              <span class="text-xs text-indigo-400 shrink-0 ml-2"><i class="fa-solid fa-arrow-up-right-from-square"></i></span>
            </div>
          `).join('');
        } else {
          historyContainer.innerHTML = '<div class="text-xs text-gray-500 py-2">No older summaries in this session.</div>';
        }
      } catch (err) {
        console.error('Summaries error:', err);
      }
    }

    function selectHistoricalSummary(idx) {
      if (allSummariesList[idx]) {
        renderSummaryCard(allSummariesList[idx], document.getElementById('summaryContainer'));
        window.scrollTo({ top: 120, behavior: 'smooth' });
      }
    }

    function renderSummaryCard(s, targetEl) {
      const keyPointsHtml = (s.key_points || []).map(kp => `
        <li class="flex items-start space-x-2 text-xs text-gray-200">
          <i class="fa-solid fa-circle-check text-indigo-400 mt-0.5 text-[11px] shrink-0"></i>
          <span>${kp}</span>
        </li>
      `).join('');

      const decisionsHtml = (s.decisions || []).map(d => `
        <li class="flex items-start space-x-2 text-xs text-emerald-200">
          <i class="fa-solid fa-square-check text-emerald-400 mt-0.5 text-[11px] shrink-0"></i>
          <span>${d}</span>
        </li>
      `).join('');

      const actionsHtml = (s.action_items || []).map(a => {
        const text = typeof a === 'string' ? a : (a.task || JSON.stringify(a));
        return `
          <li class="flex items-start space-x-2 text-xs text-amber-200">
            <i class="fa-solid fa-list-check text-amber-400 mt-0.5 text-[11px] shrink-0"></i>
            <span>${text}</span>
          </li>
        `;
      }).join('');

      targetEl.innerHTML = `
        <div class="space-y-3 sm:space-y-4">
          <div class="flex flex-col sm:flex-row sm:items-center justify-between text-xs pb-1 gap-1">
            <h3 class="text-base sm:text-lg font-bold text-transparent bg-clip-text bg-gradient-to-r from-white via-indigo-100 to-purple-200">
              ${s.title}
            </h3>
            <div class="flex items-center space-x-2 text-gray-400 text-[11px]">
              <span class="px-2 py-0.5 rounded bg-gray-900 border border-gray-800">
                <i class="fa-regular fa-clock mr-1"></i>${s.time}
              </span>
              <span class="px-2 py-0.5 rounded bg-indigo-950 text-indigo-300 border border-indigo-800">
                ${s.processing_time_sec ? s.processing_time_sec + 's' : 'Qwen 3'}
              </span>
            </div>
          </div>

          <div class="p-3 sm:p-3.5 rounded-xl bg-gray-900/80 border border-gray-800 text-xs sm:text-sm text-gray-200 leading-relaxed shadow-inner">
            ${s.summary}
          </div>

          <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
            <div class="p-3 rounded-xl bg-indigo-950/20 border border-indigo-900/40 space-y-1.5">
              <div class="flex items-center space-x-1.5 text-xs font-semibold text-indigo-300 pb-1 border-b border-indigo-900/30">
                <i class="fa-solid fa-list-ul text-indigo-400"></i>
                <span>Key Discussion Points</span>
              </div>
              <ul class="space-y-1 pt-1">
                ${keyPointsHtml || '<li class="text-xs text-gray-500 italic">No explicit points listed</li>'}
              </ul>
            </div>

            <div class="p-3 rounded-xl bg-emerald-950/20 border border-emerald-900/40 space-y-1.5">
              <div class="flex items-center space-x-1.5 text-xs font-semibold text-emerald-300 pb-1 border-b border-emerald-900/30">
                <i class="fa-solid fa-gavel text-emerald-400"></i>
                <span>Decisions Taken</span>
              </div>
              <ul class="space-y-1 pt-1">
                ${decisionsHtml || '<li class="text-xs text-gray-500 italic">No direct decisions captured</li>'}
              </ul>
            </div>

            <div class="p-3 rounded-xl bg-amber-950/20 border border-amber-900/40 space-y-1.5">
              <div class="flex items-center space-x-1.5 text-xs font-semibold text-amber-300 pb-1 border-b border-amber-900/30">
                <i class="fa-solid fa-clipboard-check text-amber-400"></i>
                <span>Action Items</span>
              </div>
              <ul class="space-y-1 pt-1">
                ${actionsHtml || '<li class="text-xs text-gray-500 italic">No action items pending</li>'}
              </ul>
            </div>
          </div>
        </div>
      `;
    }

    async function triggerSummaryNow() {
      if (isSummarizingNow) return;
      const mins = document.getElementById('summaryWindowSelect').value;
      const btn = document.getElementById('btnSummarize');
      const btnText = document.getElementById('summarizeBtnText');
      const icon = document.getElementById('summarizeIcon');
      const loading = document.getElementById('summaryLoading');
      const container = document.getElementById('summaryContainer');

      isSummarizingNow = true;
      btn.disabled = true;
      btn.classList.add('opacity-75');
      icon.className = 'fa-solid fa-circle-notch fa-spin text-white';
      btnText.textContent = 'Analyzing...';
      loading.classList.remove('hidden');
      container.classList.add('hidden');

      try {
        const res = await fetch(`/dream-ai/api/summarize?minutes=${mins}`, { method: 'POST' });
        const data = await res.json();
        if (data.status === 'success') {
          await fetchSummaries();
        } else if (data.status === 'empty') {
          alert('Note: ' + data.message);
        } else {
          alert('Summarization response: ' + JSON.stringify(data));
        }
      } catch (err) {
        alert('Failed to connect to LLM: ' + err);
      } finally {
        isSummarizingNow = false;
        btn.disabled = false;
        btn.classList.remove('opacity-75');
        icon.className = 'fa-solid fa-bolt text-yellow-300';
        btnText.textContent = 'Generate Summary Now';
        loading.classList.add('hidden');
        container.classList.remove('hidden');
      }
    }

    async function fetchMemories() {
      try {
        const res = await fetch('/dream-ai/api/memories');
        const list = await res.json();
        const container = document.getElementById('memoriesList');
        if (!list || list.length === 0) return;

        container.innerHTML = list.map(m => `
          <div class="p-2 rounded-lg bg-gray-900/80 border border-gray-800 text-xs">
            <div class="text-[10px] text-gray-500 mb-0.5">${m.time}</div>
            <pre class="text-[10px] text-gray-300 whitespace-pre-wrap">${JSON.stringify(m.data, null, 2)}</pre>
          </div>
        `).join('');
      } catch (e) {}
    }

    // Initial Load & Intervals
    fetchStats();
    fetchLlmStatus();
    fetchTranscripts();
    fetchSummaries();
    fetchMemories();
    connectWebSocket();

    setInterval(fetchStats, 3000);
    setInterval(fetchLlmStatus, 6000);
    setInterval(fetchTranscripts, 3000);
    setInterval(fetchSummaries, 6000);
  </script>
</body>
</html>
"""

@app.get("/dream-ai", response_class=HTMLResponse)
@app.get("/dream-ai/", response_class=HTMLResponse)
async def serve_dashboard():
    return HTMLResponse(content=DASHBOARD_HTML)


def main():
    parser = argparse.ArgumentParser(description="Dream AI Pendant Console")
    parser.add_argument("--host", default="0.0.0.0", help="Host to bind")
    parser.add_argument("--port", type=int, default=8080, help="Port to listen on")
    args = parser.parse_args()

    print("\n" + "="*60)
    print("🚀 DREAM AI PENDANT SERVER STARTING (v2.2.0)")
    print(f"Local URL: http://localhost:{args.port}/dream-ai")
    print(f"Sarvam Model: {SARVAM_MODEL}")
    print(f"Ollama Brain: {OLLAMA_MODEL} @ {OLLAMA_BASE_URL}")
    print(f"Auto Summary: Every {SUMMARY_INTERVAL_MIN} minutes")
    print(f"Storage Cleanup: Every 60s (keeping transcripts, purging temporary .wav)")
    print("="*60 + "\n")

    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
