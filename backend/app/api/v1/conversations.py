from datetime import UTC, date, datetime, time

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.models import Conversation, TranscriptTurn, WalEntry

router = APIRouter(prefix="/conversations", tags=["conversations"])


def _convo_row(c: Conversation) -> dict:
    return {
        "id": c.id,
        "title": c.title or "Conversation",
        "started_at": c.started_at,
        "ended_at": c.ended_at,
        "participants": c.participants,
        "summary": c.summary,
    }


@router.get("")
async def list_conversations(
    day: date | None = None, session: AsyncSession = Depends(get_session)
) -> list[dict]:
    stmt = select(Conversation).order_by(Conversation.started_at.desc())
    if day is not None:
        stmt = stmt.where(
            Conversation.started_at >= datetime.combine(day, time.min, tzinfo=UTC),
            Conversation.started_at <= datetime.combine(day, time.max, tzinfo=UTC),
        )
    convos = (await session.execute(stmt)).scalars().all()
    # Badge counts: WAL entries grouped by type per source conversation
    entries = (await session.execute(select(WalEntry))).scalars().all()
    badges: dict[str, dict[str, int]] = {}
    for e in entries:
        cid = (e.evidence or {}).get("conversation_id")
        if cid:
            badges.setdefault(cid, {})
            badges[cid][e.type] = badges[cid].get(e.type, 0) + 1
    return [
        {
            **_convo_row(c),
            "badges": [
                {"type": t, "count": n} for t, n in sorted(badges.get(c.id, {}).items())
            ],
        }
        for c in convos
    ]


@router.get("/{conversation_id}")
async def get_conversation(
    conversation_id: str, session: AsyncSession = Depends(get_session)
) -> dict:
    convo = await session.get(Conversation, conversation_id)
    if convo is None:
        raise HTTPException(404, "conversation not found")
    turns = (
        (
            await session.execute(
                select(TranscriptTurn)
                .where(TranscriptTurn.conversation_id == conversation_id)
                .order_by(TranscriptTurn.started_at, TranscriptTurn.id)
            )
        )
        .scalars()
        .all()
    )
    entries = (
        (await session.execute(select(WalEntry).order_by(WalEntry.ts))).scalars().all()
    )
    linked = [
        e
        for e in entries
        if (e.evidence or {}).get("conversation_id") == conversation_id
    ]
    return {
        **_convo_row(convo),
        "transcript": [
            {"time": t.started_at, "speaker": t.speaker, "text": t.text} for t in turns
        ],
        "entries": [
            {"id": e.id, "type": e.type, "headline": e.headline} for e in linked
        ],
    }
