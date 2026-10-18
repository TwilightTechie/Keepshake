"""Byte-preserving archive for the Swift gateway. Deliberately separate from STT ingest."""

import base64
import binascii
import hashlib
import json
import math
import re
from datetime import datetime
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import Response
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.ingest import _insert_for
from app.auth import require_token
from app.db import get_session
from app.models import RawChunk

router = APIRouter(prefix="/ingest", tags=["raw capture"], dependencies=[Depends(require_token)])
MAX_BYTES = 32 * 1024 * 1024


class Header(BaseModel):
    model_config = ConfigDict(extra="forbid")
    version: Literal[1]
    chunk_id: UUID
    session_id: UUID
    device_id: str = Field(min_length=1, max_length=64)
    started_at: datetime
    sample_rate_hz: int = Field(ge=1000, le=192000)
    channels: Literal[1]
    bits_per_sample: Literal[16]
    encoding: Literal["pcm_s16le"]
    packet_format: Literal["keepsake-p0"]
    checkpoint_seconds: int = Field(ge=5, le=300)
    stream_info_b64: str | None = Field(default=None, max_length=64)
    delivery_mode: Literal["checkpoint"] | None = None


class Packet(BaseModel):
    model_config = ConfigDict(extra="forbid")
    received_at: datetime
    elapsed_seconds: float = Field(ge=0)
    packet_b64: str = Field(max_length=2048)


def validate_envelope(body: bytes) -> tuple[Header, int]:
    if not body.endswith(b"\n"):
        raise ValueError("Chunk must end with a complete JSONL record")
    lines = body.splitlines()
    if len(lines) < 2:
        raise ValueError("Chunk needs a header and at least one packet")
    header = Header.model_validate_json(lines[0])
    if header.started_at.tzinfo is None:
        raise ValueError("Timestamps must include timezone")
    if header.stream_info_b64 is not None:
        descriptor = base64.b64decode(header.stream_info_b64, validate=True)
        if (
            len(descriptor) != 20
            or descriptor[:4] != b"KSR1"
            or int.from_bytes(descriptor[4:8], "little") != header.sample_rate_hz
            or descriptor[8:16] != bytes([100, 0, 1, 16, 5, 1, 0, 0])
        ):
            raise ValueError("Stream descriptor does not match chunk format")
    last_elapsed = -1.0
    for line in lines[1:]:
        packet = Packet.model_validate_json(line)
        if packet.received_at.tzinfo is None or not math.isfinite(packet.elapsed_seconds):
            raise ValueError("Invalid packet time")
        if packet.elapsed_seconds < last_elapsed:
            raise ValueError("Packet monotonic time went backwards")
        last_elapsed = packet.elapsed_seconds
        # Even malformed/duplicate BLE notifications are preserved. Validate transport
        # encoding only; this endpoint never decodes, resamples, filters or repairs PCM.
        base64.b64decode(packet.packet_b64, validate=True)
    return header, len(lines) - 1


@router.post("/raw-chunks")
async def upload_raw_chunk(request: Request, session: AsyncSession = Depends(get_session)) -> dict:
    if request.headers.get("content-type", "").split(";")[0] != "application/x-ndjson":
        raise HTTPException(415, "Use application/x-ndjson")
    expected_hash = request.headers.get("x-content-sha256", "")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
        raise HTTPException(400, "Missing or invalid X-Content-SHA256")
    body = bytearray()
    async for part in request.stream():
        if len(body) + len(part) > MAX_BYTES:
            raise HTTPException(413, "Chunk exceeds 32 MiB")
        body.extend(part)
    raw = bytes(body)
    actual_hash = hashlib.sha256(raw).hexdigest()
    if actual_hash != expected_hash:
        raise HTTPException(400, "Checksum mismatch")
    try:
        header, packet_count = validate_envelope(raw)
    except (ValueError, ValidationError, binascii.Error, json.JSONDecodeError) as exc:
        raise HTTPException(422, "Invalid raw chunk envelope") from exc
    chunk_id = str(header.chunk_id)
    if request.headers.get("idempotency-key") != chunk_id:
        raise HTTPException(400, "Idempotency-Key must match header chunk_id")
    stmt = (
        _insert_for(session)(RawChunk)
        .values(
            chunk_id=chunk_id,
            session_id=str(header.session_id),
            device_id=header.device_id,
            started_at=header.started_at,
            sha256=actual_hash,
            packet_count=packet_count,
            metadata_json=header.model_dump(mode="json"),
            envelope=raw,
        )
        .on_conflict_do_nothing(index_elements=["chunk_id"])
    )
    await session.execute(stmt)
    stored = await session.get(RawChunk, chunk_id)
    if stored.sha256 != actual_hash:
        await session.rollback()
        raise HTTPException(409, "Chunk ID already exists with different content")
    await session.commit()  # Acknowledgment means durable storage, not just receipt.
    return {"chunk_id": chunk_id, "sha256": actual_hash, "stored": True}


@router.get("/raw-chunks")
async def list_raw_chunks(
    limit: int = Query(50, ge=1, le=200), session: AsyncSession = Depends(get_session)
) -> list[dict]:
    rows = (
        (
            await session.execute(
                select(
                    RawChunk.chunk_id,
                    RawChunk.session_id,
                    RawChunk.device_id,
                    RawChunk.started_at,
                    RawChunk.sha256,
                    RawChunk.packet_count,
                )
                .order_by(RawChunk.received_at.desc(), RawChunk.chunk_id)
                .limit(limit)
            )
        )
        .mappings()
        .all()
    )
    return [dict(row) for row in rows]


@router.get("/raw-chunks/{chunk_id}")
async def download_raw_chunk(
    chunk_id: UUID, session: AsyncSession = Depends(get_session)
) -> Response:
    chunk = await session.get(RawChunk, str(chunk_id))
    if chunk is None:
        raise HTTPException(404, "Chunk not found")
    return Response(
        content=chunk.envelope,
        media_type="application/x-ndjson",
        headers={
            "X-Content-SHA256": chunk.sha256,
            "Content-Disposition": f'attachment; filename="{chunk.chunk_id}.jsonl"',
        },
    )
