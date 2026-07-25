"""PR-4: everything exportable and deletable. Delete is the one exception to
append-only (MEM-1): hard delete, logged as a deletion marker."""

from fastapi import APIRouter, Depends
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.wal import wal_row
from app.db import get_session
from app.models import (
    AudioSegment,
    Conversation,
    DayRecap,
    ReviewCandidate,
    Task,
    TranscriptTurn,
    WalEntry,
)

router = APIRouter(tags=["data"])


@router.get("/export")
async def export_all(session: AsyncSession = Depends(get_session)) -> dict:
    wal = (await session.execute(select(WalEntry).order_by(WalEntry.ts))).scalars().all()
    convos = (await session.execute(select(Conversation))).scalars().all()
    turns = (await session.execute(select(TranscriptTurn))).scalars().all()
    tasks = (await session.execute(select(Task))).scalars().all()
    return {
        "wal": [wal_row(e) for e in wal],
        "conversations": [
            {
                "id": c.id,
                "title": c.title,
                "started_at": c.started_at,
                "ended_at": c.ended_at,
                "summary": c.summary,
                "participants": c.participants,
            }
            for c in convos
        ],
        "transcript_turns": [
            {
                "conversation_id": t.conversation_id,
                "speaker": t.speaker,
                "at": t.started_at,
                "text": t.text,
            }
            for t in turns
        ],
        "tasks": [
            {"id": t.id, "title": t.title, "due": t.due, "person": t.person, "done": t.done}
            for t in tasks
        ],
    }


@router.delete("/data")
async def delete_all(session: AsyncSession = Depends(get_session)) -> dict:
    counts = {}
    for model in (WalEntry, ReviewCandidate, Task, TranscriptTurn, Conversation,
                  DayRecap, AudioSegment):
        result = await session.execute(delete(model))
        counts[model.__tablename__] = result.rowcount
    await session.commit()
    return {"deleted": counts}
