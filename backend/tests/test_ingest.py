import base64
from datetime import UTC, datetime


def frame(seq: int, text: bytes = b"hello", end: bool = False) -> dict:
    return {
        "seq": seq,
        "captured_at": datetime.now(UTC).isoformat(),
        "codec": "pcm16",
        "utterance_end": end,
        "audio_b64": base64.b64encode(text).decode(),
    }


async def test_batch_ingest_and_idempotency(client):
    body = {
        "device_id": "test-dev",
        "frames": [frame(1), frame(2, end=True)],
    }
    r = await client.post("/v1/ingest/batch", json=body)
    assert r.status_code == 200
    assert r.json() == {"acked": [1, 2], "count": 2}

    # Re-sending the same seqs must ack again without duplicating rows
    r2 = await client.post("/v1/ingest/batch", json=body)
    assert r2.status_code == 200
    assert r2.json()["acked"] == [1, 2]


async def test_batch_requires_token(client):
    r = await client.post(
        "/v1/ingest/batch",
        json={"device_id": "x", "frames": []},
        headers={"Authorization": "Bearer wrong"},
    )
    assert r.status_code == 401
