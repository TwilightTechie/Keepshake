"""Ask (MEM-5): slurp-first — load the whole WAL + open tasks into the LLM context.
Embeddings retrieval becomes the fallback when the WAL outgrows the context window."""

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.models import Task, WalEntry
from app.providers.llm import ASK_SYSTEM, get_llm_provider

router = APIRouter(tags=["ask"])


class AskIn(BaseModel):
    question: str


@router.post("/ask")
async def ask(body: AskIn, session: AsyncSession = Depends(get_session)) -> dict:
    entries = (
        (await session.execute(select(WalEntry).order_by(WalEntry.ts))).scalars().all()
    )
    tasks = (
        (await session.execute(select(Task).where(Task.done.is_(False)))).scalars().all()
    )
    context_lines = [
        f"[{e.id}] {e.ts:%Y-%m-%d %H:%M} {e.type}: {e.headline}"
        + (f" (why: {e.why})" if e.why else "")
        + (f" (participants: {', '.join(e.participants)})" if e.participants else "")
        for e in entries
    ] + [
        f"[task-{t.id}] open task: {t.title}"
        + (f" (due {t.due:%Y-%m-%d})" if t.due else "")
        for t in tasks
    ]
    user = "MEMORY LOG:\n" + "\n".join(context_lines) + f"\n\nQUESTION: {body.question}"
    reply = await get_llm_provider().complete_json(ASK_SYSTEM, user)

    known_wal = {e.id: e for e in entries}
    known_tasks = {f"task-{t.id}": t for t in tasks}
    citations = []
    for cid in reply.get("citations", []) or []:
        if cid in known_wal:
            e = known_wal[cid]
            citations.append(
                {"kind": "wal", "id": e.id, "type": e.type, "headline": e.headline,
                 "conversation_id": (e.evidence or {}).get("conversation_id")}
            )
        elif cid in known_tasks:
            t = known_tasks[cid]
            citations.append({"kind": "task", "id": t.id, "headline": t.title})
    return {
        "answer": reply.get("answer", ""),
        "citations": citations,
        "searched": {"wal_entries": len(entries), "open_tasks": len(tasks)},
    }
