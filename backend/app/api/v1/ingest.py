"""Ingest (BE-2): WS for live frames, batch POST for backlog catch-up.

Protocol (JSON text frames on the WS):
  client → {"type": "hello", "device_id": "...", "device_name": "..."}
  client → {"type": "frame", "seq": 1042, "captured_at": "<iso>",
            "codec": "wav", "utterance_end": false, "audio_b64": "..."}
  server → {"type": "ack", "seq": 1042}          durable ack: row is committed
  server → {"type": "error", "detail": "..."}

Idempotent by (device_id, seq): re-sent frames ack again without duplicating.
The ack chain is the zero-loss contract — the phone forwards acks to the pendant,
which only then reclaims journal flash (D6).
"""

import base64
import secrets
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_token
from app.config import get_settings
from app.db import get_session
from app.models import AudioSegment, Device

router = APIRouter(prefix="/ingest", tags=["ingest"])


def _insert_for(session: AsyncSession):
    return sqlite_insert if session.bind.dialect.name == "sqlite" else pg_insert


async def _upsert_device(session: AsyncSession, device_id: str, name: str | None) -> None:
    device = await session.get(Device, device_id)
    if device is None:
        session.add(
            Device(id=device_id, name=name or device_id, key_hash="v1-token-auth")
        )
    else:
        device.last_seen_at = datetime.now(UTC)
    await session.flush()


async def _store_frame(
    session: AsyncSession,
    device_id: str,
    seq: int,
    captured_at: datetime,
    codec: str,
    utterance_end: bool,
    audio: bytes,
) -> None:
    insert = _insert_for(session)
    stmt = (
        insert(AudioSegment)
        .values(
            device_id=device_id,
            seq=seq,
            captured_at=captured_at,
            codec=codec,
            utterance_end=utterance_end,
            processed=False,
            audio=audio,
        )
        .on_conflict_do_nothing(index_elements=["device_id", "seq"])
    )
    await session.execute(stmt)


@router.websocket("/live")
async def ingest_live(ws: WebSocket, session: AsyncSession = Depends(get_session)) -> None:
    # WS auth: token as query param or Authorization header
    token = ws.query_params.get("token") or (
        ws.headers.get("authorization", "").removeprefix("Bearer ")
    )
    if not secrets.compare_digest(token, get_settings().api_token):
        await ws.close(code=4401)
        return
    await ws.accept()
    device_id: str | None = None
    try:
        while True:
            msg = await ws.receive_json()
            mtype = msg.get("type")
            if mtype == "hello":
                device_id = str(msg["device_id"])
                await _upsert_device(session, device_id, msg.get("device_name"))
                await session.commit()
                await ws.send_json({"type": "hello_ack", "device_id": device_id})
            elif mtype == "frame":
                if device_id is None:
                    await ws.send_json({"type": "error", "detail": "hello first"})
                    continue
                seq = int(msg["seq"])
                await _store_frame(
                    session,
                    device_id,
                    seq,
                    datetime.fromisoformat(msg["captured_at"]),
                    msg.get("codec", "opus"),
                    bool(msg.get("utterance_end", False)),
                    base64.b64decode(msg.get("audio_b64", "")),
                )
                await session.commit()  # durable before ack
                await ws.send_json({"type": "ack", "seq": seq})
            else:
                await ws.send_json({"type": "error", "detail": f"unknown type {mtype!r}"})
    except WebSocketDisconnect:
        pass


class BatchFrame(BaseModel):
    seq: int
    captured_at: datetime
    codec: str = "opus"
    utterance_end: bool = False
    audio_b64: str = ""


class BatchIn(BaseModel):
    device_id: str
    device_name: str | None = None
    frames: list[BatchFrame] = Field(default_factory=list)


@router.post("/batch", dependencies=[Depends(require_token)])
async def ingest_batch(
    body: BatchIn, session: AsyncSession = Depends(get_session)
) -> dict:
    await _upsert_device(session, body.device_id, body.device_name)
    for frame in body.frames:
        await _store_frame(
            session,
            body.device_id,
            frame.seq,
            frame.captured_at,
            frame.codec,
            frame.utterance_end,
            base64.b64decode(frame.audio_b64),
        )
    await session.commit()
    acked = [f.seq for f in body.frames]
    return {"acked": acked, "count": len(acked)}
