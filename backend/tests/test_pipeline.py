"""End-to-end pipeline with mock providers: framed script → STT → conversation →
extraction → WAL + review + tasks. This is the contract the real providers slot into."""

from datetime import UTC, datetime

from sqlalchemy import select

from app.models import AudioSegment, Conversation, ReviewCandidate, Task, WalEntry
from app.pipeline.runner import run_pipeline_once

SCRIPT = b"""You|Let's ship the sync fix in 1.4.2, not as a hotfix
Sam|I'll have a draft by end of day
Priya|Did we ever settle the retro cadence?
"""


async def seed_utterance(session, device="dev-1", start_seq=1, script=SCRIPT):
    chunks = [script[i : i + 40] for i in range(0, len(script), 40)]
    for i, chunk in enumerate(chunks):
        session.add(
            AudioSegment(
                device_id=device,
                seq=start_seq + i,
                captured_at=datetime.now(UTC),
                codec="pcm16",
                utterance_end=(i == len(chunks) - 1),
                audio=chunk,
            )
        )
    await session.commit()
    return len(chunks)


async def test_pipeline_produces_wal_review_and_tasks(session):
    await seed_utterance(session)
    totals = await run_pipeline_once(session)
    assert totals["utterances"] == 1
    assert totals["conversations"] == 1

    wal = (await session.execute(select(WalEntry))).scalars().all()
    review = (await session.execute(select(ReviewCandidate))).scalars().all()
    tasks = (await session.execute(select(Task))).scalars().all()

    # Mock LLM: decision (0.9) auto-appends; commitment "I'll have a draft by end
    # of day" contains "by" → 0.9 auto-append + derived task; question 0.7 → review.
    types = {e.type for e in wal}
    assert "decision" in types and "commitment" in types
    assert len(review) == 1 and review[0].candidate["type"] == "question"
    assert len(tasks) == 1 and tasks[0].title.startswith("I'll have a draft")

    # Audio discarded after STT (PR-2 default)
    segments = (await session.execute(select(AudioSegment))).scalars().all()
    assert all(s.audio is None and s.processed for s in segments)


async def test_pipeline_waits_for_gap_free_run(session):
    # A run with a missing seq before the utterance_end must NOT be transcribed.
    session.add(
        AudioSegment(
            device_id="dev-2", seq=1, captured_at=datetime.now(UTC),
            codec="pcm16", utterance_end=False, audio=b"You|part one",
        )
    )
    session.add(
        AudioSegment(
            device_id="dev-2", seq=3, captured_at=datetime.now(UTC),
            codec="pcm16", utterance_end=True, audio=b"You|part two",
        )
    )
    await session.commit()
    totals = await run_pipeline_once(session)
    assert totals["utterances"] == 0

    # Backfilling the hole makes the run complete.
    session.add(
        AudioSegment(
            device_id="dev-2", seq=2, captured_at=datetime.now(UTC),
            codec="pcm16", utterance_end=False, audio=b"You|middle",
        )
    )
    await session.commit()
    totals = await run_pipeline_once(session)
    assert totals["utterances"] == 1


async def test_conversation_gets_title_and_participants(session):
    await seed_utterance(session)
    await run_pipeline_once(session)
    convo = (await session.execute(select(Conversation))).scalars().one()
    assert convo.title
    assert set(convo.participants) == {"You", "Sam", "Priya"}
