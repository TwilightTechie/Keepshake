from datetime import UTC, datetime
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.models import ReviewCandidate
from app.pipeline.extraction import accept_candidate

router = APIRouter(prefix="/review", tags=["memory"])


@router.get("")
async def list_review(
    status: str = "pending", session: AsyncSession = Depends(get_session)
) -> list[dict]:
    stmt = (
        select(ReviewCandidate)
        .where(ReviewCandidate.status == status)
        .order_by(ReviewCandidate.created_at)  # oldest first, like the app shows
    )
    rows = (await session.execute(stmt)).scalars().all()
    return [
        {"id": r.id, "created_at": r.created_at, "status": r.status, **r.candidate}
        for r in rows
    ]


class ResolveIn(BaseModel):
    verdict: Literal["accepted", "rejected"]
    edits: dict | None = None  # accepted-with-edits ("edit" in the app)


@router.post("/{candidate_id}/resolve")
async def resolve(
    candidate_id: str, body: ResolveIn, session: AsyncSession = Depends(get_session)
) -> dict:
    cand = await session.get(ReviewCandidate, candidate_id)
    if cand is None:
        raise HTTPException(404, "candidate not found")
    if cand.status != "pending":
        raise HTTPException(409, f"already {cand.status}")  # guard double-resolve
    cand.status = body.verdict
    cand.resolved_at = datetime.now(UTC)
    cand.edits = body.edits  # stored either way as tuning signal (MEM-4)
    wal_id = None
    if body.verdict == "accepted":
        entry = await accept_candidate(session, cand, body.edits)
        wal_id = entry.id
    await session.commit()
    return {"id": cand.id, "status": cand.status, "wal_entry_id": wal_id}
