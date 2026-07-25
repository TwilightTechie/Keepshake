"""Near-line pipeline worker (spec §3.1): polls for utterance-complete audio runs,
transcribes, segments into conversations, extracts WAL entries. One asyncio task
started with the app; a real queue can replace polling if volume ever demands it.
"""

from __future__ import annotations

import asyncio
import logging
from itertools import groupby

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import AudioSegment, TranscriptTurn
from app.pipeline.extraction import extract_conversation, summarize_conversation
from app.pipeline.segmenter import assign_conversations
from app.providers.llm import get_llm_provider
from app.providers.stt import get_stt_provider

log = logging.getLogger("keepsake.pipeline")


async def process_pending_audio(session: AsyncSession) -> int:
    """Transcribe every unprocessed run of frames that ends in an utterance_end
    marker. Returns number of utterances transcribed."""
    stt = get_stt_provider()
    segments = (
        (
            await session.execute(
                select(AudioSegment)
                .where(AudioSegment.processed.is_(False))
                .order_by(AudioSegment.device_id, AudioSegment.seq)
            )
        )
        .scalars()
        .all()
    )

    # A sequence hole means frames are still in flight (journal resend will fill
    # it) — everything after the hole for that device WAITS; nothing is dropped.
    utterances: list[list[AudioSegment]] = []
    for _, group in groupby(segments, key=lambda s: s.device_id):
        run: list[AudioSegment] = []
        for seg in group:
            if run and seg.seq != run[-1].seq + 1:
                break  # hole: wait for backfill before transcribing further
            run.append(seg)
            if seg.utterance_end:
                utterances.append(run)
                run = []

    done = 0
    for frames in utterances:
        audio = b"".join(f.audio or b"" for f in frames)
        turns = await stt.transcribe(audio, frames[0].codec)
        for t in turns:
            session.add(
                TranscriptTurn(
                    device_id=frames[0].device_id,
                    speaker=t.speaker,
                    started_at=frames[0].captured_at,
                    text=t.text,
                )
            )
        for f in frames:
            f.processed = True
            if not get_settings().audio_retention:
                f.audio = None  # PR-2: transcribe-and-discard
        done += 1
    await session.flush()
    return done


async def run_pipeline_once(session: AsyncSession) -> dict:
    transcribed = await process_pending_audio(session)
    touched = await assign_conversations(session)
    llm = get_llm_provider()
    totals = {"utterances": transcribed, "conversations": len(touched), "wal": 0, "review": 0}
    for convo_id in touched:
        counts = await extract_conversation(session, llm, convo_id)
        await summarize_conversation(session, llm, convo_id)
        totals["wal"] += counts["wal"]
        totals["review"] += counts["review"]
    await session.commit()
    return totals


async def pipeline_loop() -> None:
    from app.db import SessionLocal

    poll = get_settings().pipeline_poll_seconds
    log.info("pipeline worker started (poll=%ss)", poll)
    while True:
        try:
            async with SessionLocal() as session:
                totals = await run_pipeline_once(session)
                if totals["utterances"]:
                    log.info("pipeline: %s", totals)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("pipeline iteration failed")
        await asyncio.sleep(poll)
