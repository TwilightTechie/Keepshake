"""Groups transcript turns into conversations by silence gap (BE spec §3.1 step ①).

v1 heuristic: a turn more than `conversation_gap_minutes` after the previous turn
starts a new conversation. Speaker-set change detection can refine this later.
"""

import secrets
from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import Conversation, TranscriptTurn


def _new_id() -> str:
    return secrets.token_hex(8)


async def assign_conversations(session: AsyncSession) -> list[str]:
    """Attach unassigned turns to conversations. Returns ids of touched conversations."""
    gap = timedelta(minutes=get_settings().conversation_gap_minutes)
    turns = (
        (
            await session.execute(
                select(TranscriptTurn)
                .where(TranscriptTurn.conversation_id.is_(None))
                .order_by(TranscriptTurn.started_at)
            )
        )
        .scalars()
        .all()
    )
    if not turns:
        return []

    touched: list[str] = []
    current: Conversation | None = None
    for turn in turns:
        if current is None or turn.started_at - current.ended_at > gap:
            # Try to continue the most recent conversation if the gap allows.
            latest = (
                await session.execute(
                    select(Conversation).order_by(Conversation.ended_at.desc()).limit(1)
                )
            ).scalar_one_or_none()
            if latest is not None and turn.started_at - latest.ended_at <= gap:
                current = latest
            else:
                current = Conversation(
                    id=_new_id(),
                    started_at=turn.started_at,
                    ended_at=turn.started_at,
                    participants=[],
                )
                session.add(current)
        turn.conversation_id = current.id
        current.ended_at = max(current.ended_at, turn.started_at)
        if turn.speaker not in current.participants:
            current.participants = [*current.participants, turn.speaker]
        if current.id not in touched:
            touched.append(current.id)
    await session.flush()
    return touched
