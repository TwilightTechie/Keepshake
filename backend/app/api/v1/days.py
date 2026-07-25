from datetime import UTC, date, datetime, time

from fastapi import APIRouter, Depends
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.models import Conversation, DayRecap, ReviewCandidate, WalEntry

router = APIRouter(prefix="/days", tags=["days"])


@router.get("/{day}")
async def get_day(day: date, session: AsyncSession = Depends(get_session)) -> dict:
    start = datetime.combine(day, time.min, tzinfo=UTC)
    end = datetime.combine(day, time.max, tzinfo=UTC)
    convos = (
        (
            await session.execute(
                select(Conversation).where(
                    Conversation.started_at >= start, Conversation.started_at <= end
                )
            )
        )
        .scalars()
        .all()
    )
    wal_count = (
        await session.execute(
            select(func.count())
            .select_from(WalEntry)
            .where(WalEntry.ts >= start, WalEntry.ts <= end)
        )
    ).scalar_one()
    review_count = (
        await session.execute(
            select(func.count())
            .select_from(ReviewCandidate)
            .where(ReviewCandidate.status == "pending")
        )
    ).scalar_one()
    captured_seconds = sum(
        (c.ended_at - c.started_at).total_seconds() for c in convos
    )
    recap = await session.get(DayRecap, day)
    return {
        "day": day,
        "conversations": len(convos),
        "captured_seconds": int(captured_seconds),
        "wal_entries": wal_count,
        "review_pending": review_count,
        "narrative": recap.narrative if recap else None,
        "frozen_at": recap.frozen_at if recap else None,
    }
