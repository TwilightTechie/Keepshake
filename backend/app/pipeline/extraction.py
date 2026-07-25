"""WAL extraction pass (D7, spec §3.1 steps ②–④): transcript → candidates →
confidence gate → auto-append or review queue. Commitments also become tasks."""

from __future__ import annotations

import secrets
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import Conversation, ReviewCandidate, Task, TranscriptTurn, WalEntry
from app.providers.llm import EXTRACTION_SYSTEM, LlmProvider


def _new_id() -> str:
    return secrets.token_hex(8)


def _transcript_text(turns: list[TranscriptTurn]) -> str:
    return "\n".join(f"{t.speaker}: {t.text}" for t in turns)


def _tokens(text: str) -> set[str]:
    return {w for w in "".join(c if c.isalnum() else " " for c in text.lower()).split() if w}


def _dedup_candidates(entries: list) -> list:
    """In-batch coherence check (spec §3.1 ③, minimal form): LLMs sometimes emit
    near-duplicate entries in one reply. Keep the highest-confidence variant of
    same-type candidates whose headlines overlap heavily."""
    ordered = sorted(
        (e for e in entries if isinstance(e, dict)),
        key=lambda e: -float(e.get("confidence", 0)),
    )
    kept: list[dict] = []
    for cand in ordered:
        tok = _tokens(str(cand.get("headline", "")))
        if not tok:
            continue
        def _overlaps(other: dict, tok: set[str] = tok) -> bool:
            other_tok = _tokens(str(other.get("headline", "")))
            return len(tok & other_tok) / len(tok | other_tok) >= 0.5

        duplicate = any(cand.get("type") == k.get("type") and _overlaps(k) for k in kept)
        if not duplicate:
            kept.append(cand)
    return kept


async def extract_conversation(
    session: AsyncSession, llm: LlmProvider, conversation_id: str
) -> dict[str, int]:
    """Run extraction over a conversation's not-yet-extracted turns."""
    turns = (
        (
            await session.execute(
                select(TranscriptTurn)
                .where(
                    TranscriptTurn.conversation_id == conversation_id,
                    TranscriptTurn.extracted.is_(False),
                )
                .order_by(TranscriptTurn.started_at)
            )
        )
        .scalars()
        .all()
    )
    if not turns:
        return {"wal": 0, "review": 0}

    # The LLM needs the current date to resolve "tomorrow"/"by Tuesday" into
    # real due dates (bench bug: it guessed a 2024 date without this).
    today = datetime.now().strftime("%A, %Y-%m-%d")
    user_msg = f"Today is {today}.\n\nTRANSCRIPT:\n{_transcript_text(turns)}"
    reply = await llm.complete_json(EXTRACTION_SYSTEM, user_msg)
    entries = reply.get("entries", []) if isinstance(reply, dict) else []
    entries = _dedup_candidates(entries)
    gate = get_settings().confidence_gate

    wal_count = review_count = 0
    for cand in entries:
        if not isinstance(cand, dict) or cand.get("type") not in (
            "decision",
            "commitment",
            "fact",
            "question",
        ):
            continue
        payload = {
            "type": cand["type"],
            "headline": str(cand.get("headline", ""))[:300],
            "why": cand.get("why"),
            "participants": cand.get("participants") or [],
            "confidence": float(cand.get("confidence", 0.5)),
            "about_other": bool(cand.get("about_other", False)),
            "due": cand.get("due"),
            "evidence": {
                "conversation_id": conversation_id,
                "quote": cand.get("quote"),
                "turn_ids": [t.id for t in turns],
            },
        }
        if not payload["headline"]:
            continue
        if payload["confidence"] >= gate:
            _append_wal(session, payload, provenance="auto")
            wal_count += 1
        else:
            session.add(ReviewCandidate(id=_new_id(), candidate=payload))
            review_count += 1

    for turn in turns:
        turn.extracted = True
    await session.flush()
    return {"wal": wal_count, "review": review_count}


def _append_wal(session: AsyncSession, payload: dict, provenance: str) -> WalEntry:
    entry = WalEntry(
        id=_new_id(),
        type=payload["type"],
        headline=payload["headline"],
        why=payload.get("why"),
        participants=payload.get("participants") or [],
        confidence=payload.get("confidence", 1.0),
        provenance=provenance,
        evidence=payload.get("evidence"),
        about_other=payload.get("about_other", False),
    )
    session.add(entry)
    if entry.type == "commitment":
        due = payload.get("due")
        due_dt: datetime | None = None
        if due:
            try:
                due_dt = datetime.fromisoformat(due)
            except (TypeError, ValueError):
                due_dt = None
        session.add(
            Task(
                id=_new_id(),
                title=entry.headline,
                meta=payload.get("why"),
                due=due_dt,
                person=(entry.participants or [None])[0],
                source_conversation_id=(entry.evidence or {}).get("conversation_id"),
                wal_entry_id=entry.id,
            )
        )
    return entry


async def accept_candidate(
    session: AsyncSession, candidate: ReviewCandidate, edits: dict | None = None
) -> WalEntry:
    """Review accept/edit → confirmed WAL entry (spec §3.3). Caller sets status."""
    payload = {**candidate.candidate, **(edits or {})}
    return _append_wal(session, payload, provenance="confirmed")


async def summarize_conversation(
    session: AsyncSession, llm: LlmProvider, conversation_id: str
) -> None:
    """Title + summary for the conversation card (best-effort)."""
    convo = await session.get(Conversation, conversation_id)
    if convo is None:
        return
    turns = (
        (
            await session.execute(
                select(TranscriptTurn)
                .where(TranscriptTurn.conversation_id == conversation_id)
                .order_by(TranscriptTurn.started_at)
            )
        )
        .scalars()
        .all()
    )
    if not turns:
        return
    try:
        reply = await llm.complete_json(
            'Return STRICT JSON {"title": "<max 60 chars>", "summary": "<2 sentences>"} '
            "describing this conversation.",
            _transcript_text(turns),
        )
        convo.title = str(reply.get("title") or convo.title or "Conversation")[:200]
        convo.summary = reply.get("summary") or convo.summary
    except Exception:
        convo.title = convo.title or (turns[0].text[:60] if turns else "Conversation")
    await session.flush()
