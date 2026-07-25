from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.models import Task

router = APIRouter(prefix="/tasks", tags=["tasks"])


def _group(t: Task, now: datetime) -> str:
    if t.due is None:
        return "later"
    due = t.due if t.due.tzinfo else t.due.replace(tzinfo=UTC)
    if due.date() < now.date():
        return "overdue"
    if due.date() == now.date():
        return "today"
    return "later"


@router.get("")
async def list_tasks(
    person: str | None = None,
    done: bool | None = None,
    session: AsyncSession = Depends(get_session),
) -> list[dict]:
    stmt = select(Task).order_by(Task.due.is_(None), Task.due, Task.created_at)
    if person:
        stmt = stmt.where(Task.person == person)
    if done is not None:
        stmt = stmt.where(Task.done.is_(done))
    now = datetime.now(UTC)
    return [
        {
            "id": t.id,
            "title": t.title,
            "meta": t.meta,
            "due": t.due,
            "person": t.person,
            "done": t.done,
            "group": _group(t, now),
            "source_conversation_id": t.source_conversation_id,
            "wal_entry_id": t.wal_entry_id,
        }
        for t in (await session.execute(stmt)).scalars().all()
    ]


class TaskPatch(BaseModel):
    done: bool | None = None
    due: datetime | None = None
    title: str | None = None


@router.patch("/{task_id}")
async def patch_task(
    task_id: str, body: TaskPatch, session: AsyncSession = Depends(get_session)
) -> dict:
    task = await session.get(Task, task_id)
    if task is None:
        raise HTTPException(404, "task not found")
    if body.done is not None:
        task.done = body.done
    if body.due is not None:
        task.due = body.due
    if body.title is not None:
        task.title = body.title
    await session.commit()
    return {"id": task.id, "done": task.done, "due": task.due, "title": task.title}
