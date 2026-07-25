from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.models import WalEntry

router = APIRouter(prefix="/wal", tags=["memory"])


def wal_row(e: WalEntry) -> dict:
    return {
        "id": e.id,
        "ts": e.ts,
        "type": e.type,
        "headline": e.headline,
        "why": e.why,
        "participants": e.participants,
        "confidence": e.confidence,
        "provenance": e.provenance,
        "evidence": e.evidence,
        "refs": e.refs,
        "superseded_by": e.superseded_by,
        "about_other": e.about_other,
    }


@router.get("")
async def list_wal(
    type: str | None = None,
    person: str | None = None,
    session: AsyncSession = Depends(get_session),
) -> list[dict]:
    stmt = select(WalEntry).order_by(WalEntry.ts.desc())
    if type:
        stmt = stmt.where(WalEntry.type == type)
    entries = (await session.execute(stmt)).scalars().all()
    if person:
        entries = [e for e in entries if person in (e.participants or [])]
    return [wal_row(e) for e in entries]
