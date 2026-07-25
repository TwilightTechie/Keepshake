"""API flows over a pipeline-populated DB: review triage, wal, tasks, ask, export."""

from sqlalchemy import select
from test_pipeline import seed_utterance

from app.models import WalEntry
from app.pipeline.runner import run_pipeline_once


async def populated(session):
    await seed_utterance(session)
    await run_pipeline_once(session)


async def test_review_accept_appends_confirmed_wal(client, session):
    await populated(session)
    queue = (await client.get("/v1/review")).json()
    assert len(queue) == 1
    cid = queue[0]["id"]

    r = await client.post(f"/v1/review/{cid}/resolve", json={"verdict": "accepted"})
    assert r.status_code == 200
    wal_id = r.json()["wal_entry_id"]
    assert wal_id

    entry = (
        await session.execute(select(WalEntry).where(WalEntry.id == wal_id))
    ).scalar_one()
    assert entry.provenance == "confirmed"

    # Double-resolve guarded
    r2 = await client.post(f"/v1/review/{cid}/resolve", json={"verdict": "rejected"})
    assert r2.status_code == 409
    # Queue drained
    assert (await client.get("/v1/review")).json() == []


async def test_review_reject_does_not_append(client, session):
    await populated(session)
    before = len((await client.get("/v1/wal")).json())
    cid = (await client.get("/v1/review")).json()[0]["id"]
    r = await client.post(f"/v1/review/{cid}/resolve", json={"verdict": "rejected"})
    assert r.status_code == 200 and r.json()["wal_entry_id"] is None
    assert len((await client.get("/v1/wal")).json()) == before


async def test_wal_filter_and_task_toggle(client, session):
    await populated(session)
    decisions = (await client.get("/v1/wal", params={"type": "decision"})).json()
    assert decisions and all(e["type"] == "decision" for e in decisions)

    tasks = (await client.get("/v1/tasks")).json()
    assert tasks
    tid = tasks[0]["id"]
    r = await client.patch(f"/v1/tasks/{tid}", json={"done": True})
    assert r.json()["done"] is True


async def test_conversations_detail_links_entries(client, session):
    await populated(session)
    convos = (await client.get("/v1/conversations")).json()
    assert len(convos) == 1
    detail = (await client.get(f"/v1/conversations/{convos[0]['id']}")).json()
    assert len(detail["transcript"]) == 3
    assert any(e["type"] == "decision" for e in detail["entries"])


async def test_ask_returns_answer_shape(client, session):
    await populated(session)
    r = await client.post("/v1/ask", json={"question": "what did I promise?"})
    body = r.json()
    assert r.status_code == 200
    assert "answer" in body and "citations" in body
    assert body["searched"]["wal_entries"] >= 2


async def test_export_and_delete(client, session):
    await populated(session)
    export = (await client.get("/v1/export")).json()
    assert export["wal"] and export["conversations"] and export["transcript_turns"]

    r = await client.delete("/v1/data")
    assert r.status_code == 200
    assert (await client.get("/v1/wal")).json() == []
    assert (await client.get("/v1/conversations")).json() == []
