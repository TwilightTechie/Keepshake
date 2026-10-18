import base64
import hashlib
import json
from uuid import uuid4

from sqlalchemy import func, select

from app.models import RawChunk


def chunk(chunk_id=None, packets=None):
    chunk_id = chunk_id or str(uuid4())
    header = dict(
        version=1,
        chunk_id=chunk_id,
        session_id=str(uuid4()),
        device_id="pendant",
        started_at="2026-10-16T12:00:00Z",
        sample_rate_hz=8000,
        channels=1,
        bits_per_sample=16,
        encoding="pcm_s16le",
        packet_format="keepsake-p0",
        checkpoint_seconds=30,
    )
    packets = packets or [b"\x00\x00\x00\x00\x00\xff", b"\x01\x00\x00\x00\x00\x80\x7f"]
    rows = [header] + [
        dict(
            received_at="2026-10-16T12:00:00Z",
            elapsed_seconds=i * 0.01,
            packet_b64=base64.b64encode(p).decode(),
        )
        for i, p in enumerate(packets)
    ]
    raw = ("\n".join(json.dumps(r) for r in rows) + "\n").encode()
    return raw, {
        "Content-Type": "application/x-ndjson",
        "Idempotency-Key": chunk_id,
        "X-Content-SHA256": hashlib.sha256(raw).hexdigest(),
    }


async def test_exact_bytes_and_lost_ack_retry(client, session):
    raw, headers = chunk(
        packets=[b"\x00\x00\x00\x00\x00\xff", b"\x00\x00\x00\x00\x00\xff", b"\x01"]
    )
    for _ in range(3):
        response = await client.post("/v1/ingest/raw-chunks", content=raw, headers=headers)
        assert response.status_code == 200
        assert response.json() == dict(
            chunk_id=headers["Idempotency-Key"], sha256=headers["X-Content-SHA256"], stored=True
        )
    stored = await session.get(RawChunk, headers["Idempotency-Key"])
    assert stored.envelope == raw
    assert stored.packet_count == 3
    assert await session.scalar(select(func.count()).select_from(RawChunk)) == 1


async def test_conflicting_id_cannot_overwrite_original(client, session):
    raw, headers = chunk()
    assert (
        await client.post("/v1/ingest/raw-chunks", content=raw, headers=headers)
    ).status_code == 200
    other, other_headers = chunk(headers["Idempotency-Key"], [b"changed"])
    assert (
        await client.post("/v1/ingest/raw-chunks", content=other, headers=other_headers)
    ).status_code == 409
    assert (await session.get(RawChunk, headers["Idempotency-Key"])).envelope == raw


async def test_auth_checksum_id_and_truncated_body(client, session):
    raw, headers = chunk()
    response = await client.post(
        "/v1/ingest/raw-chunks", content=raw, headers=headers | {"Authorization": "Bearer wrong"}
    )
    assert response.status_code == 401
    assert (
        await client.post("/v1/ingest/raw-chunks", content=raw + b"x", headers=headers)
    ).status_code == 400
    assert (
        await client.post(
            "/v1/ingest/raw-chunks",
            content=raw,
            headers=headers | {"Idempotency-Key": str(uuid4())},
        )
    ).status_code == 400
    truncated = raw[:-1]
    assert (
        await client.post(
            "/v1/ingest/raw-chunks",
            content=truncated,
            headers=headers | {"X-Content-SHA256": hashlib.sha256(truncated).hexdigest()},
        )
    ).status_code == 422
    assert await session.scalar(select(func.count()).select_from(RawChunk)) == 0


async def test_body_limit(client, monkeypatch):
    from app.api.v1 import raw_chunks

    raw, headers = chunk()
    monkeypatch.setattr(raw_chunks, "MAX_BYTES", len(raw) - 1)
    assert (
        await client.post("/v1/ingest/raw-chunks", content=raw, headers=headers)
    ).status_code == 413


async def test_archive_download_and_delete_all(client, session):
    raw, headers = chunk()
    assert (
        await client.post("/v1/ingest/raw-chunks", content=raw, headers=headers)
    ).status_code == 200
    listing = await client.get("/v1/ingest/raw-chunks")
    assert listing.json()[0]["chunk_id"] == headers["Idempotency-Key"]
    download = await client.get("/v1/ingest/raw-chunks/" + headers["Idempotency-Key"])
    assert download.content == raw
    assert download.headers["x-content-sha256"] == headers["X-Content-SHA256"]
    assert (
        await client.get("/v1/ingest/raw-chunks", headers={"Authorization": "Bearer wrong"})
    ).status_code == 401
    deleted = await client.delete("/v1/data")
    assert deleted.json()["deleted"]["raw_chunks"] == 1
    assert await session.scalar(select(func.count()).select_from(RawChunk)) == 0


async def test_firmware_descriptor_must_match_rate(client):
    raw, headers = chunk()
    lines = raw.splitlines()
    header = json.loads(lines[0])
    info = bytes.fromhex("4b535231803e0000640001100501000078563412")
    header["stream_info_b64"] = base64.b64encode(info).decode()
    for rate, expected in [(8000, 422), (16000, 200)]:
        header["sample_rate_hz"] = rate
        body = b"\n".join([json.dumps(header).encode()] + lines[1:]) + b"\n"
        response = await client.post(
            "/v1/ingest/raw-chunks",
            content=body,
            headers=headers | {"X-Content-SHA256": hashlib.sha256(body).hexdigest()},
        )
        assert response.status_code == expected
