from datetime import date, datetime

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    Date,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    LargeBinary,
    String,
    Text,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base

# JSON works on both Postgres (as JSONB-compatible json) and SQLite (tests).


class Device(Base):
    """A paired pendant. key_hash authenticates its frames at ingest."""

    __tablename__ = "devices"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    name: Mapped[str] = mapped_column(String(120))
    key_hash: Mapped[str] = mapped_column(String(128))
    fw_version: Mapped[str | None] = mapped_column(String(40))
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class AudioSegment(Base):
    """One VAD-passed audio segment, idempotent by (device, seq).

    audio is NULLed after STT unless the user opted into retention (PR-2).
    codec: 'opus' from real pendants; 'wav'/'pcm16' from the simulator.
    utterance_end marks the last frame of an utterance — the pipeline
    transcribes frame runs ending at such a marker.
    """

    __tablename__ = "audio_segments"

    device_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    seq: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    captured_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    codec: Mapped[str] = mapped_column(String(12), default="opus")
    utterance_end: Mapped[bool] = mapped_column(Boolean, default=False)
    processed: Mapped[bool] = mapped_column(Boolean, default=False)
    audio: Mapped[bytes | None] = mapped_column(LargeBinary)


class Conversation(Base):
    __tablename__ = "conversations"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    title: Mapped[str | None] = mapped_column(String(200))
    summary: Mapped[str | None] = mapped_column(Text)
    participants: Mapped[list] = mapped_column(JSON, default=list)


class TranscriptTurn(Base):
    __tablename__ = "transcript_turns"

    id: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), primary_key=True, autoincrement=True
    )
    conversation_id: Mapped[str | None] = mapped_column(
        String(32), ForeignKey("conversations.id"), index=True
    )
    device_id: Mapped[str] = mapped_column(String(64))
    speaker: Mapped[str] = mapped_column(String(80), default="Speaker 1")
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    text: Mapped[str] = mapped_column(Text)
    words: Mapped[list | None] = mapped_column(JSON)
    extracted: Mapped[bool] = mapped_column(Boolean, default=False)


class WalEntry(Base):
    """Append-only (MEM-1): never mutated; supersession via superseded_by linkage."""

    __tablename__ = "wal_entries"

    id: Mapped[str] = mapped_column(String(16), primary_key=True)  # random hex
    ts: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    type: Mapped[str] = mapped_column(String(16))  # decision|commitment|fact|question|rollback
    headline: Mapped[str] = mapped_column(String(300))
    why: Mapped[str | None] = mapped_column(Text)
    participants: Mapped[list] = mapped_column(JSON, default=list)
    confidence: Mapped[float] = mapped_column(Float, default=1.0)
    provenance: Mapped[str] = mapped_column(String(12), default="auto")  # auto|confirmed|manual
    evidence: Mapped[dict | None] = mapped_column(JSON)  # {conversation_id, quote, turn_ids}
    refs: Mapped[list] = mapped_column(JSON, default=list)
    superseded_by: Mapped[str | None] = mapped_column(String(16))
    about_other: Mapped[bool] = mapped_column(Boolean, default=False)  # PR-6


class ReviewCandidate(Base):
    __tablename__ = "review_queue"

    id: Mapped[str] = mapped_column(String(16), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    status: Mapped[str] = mapped_column(String(12), default="pending")  # pending|accepted|rejected
    candidate: Mapped[dict] = mapped_column(JSON)  # same shape as WalEntry payload + note/quote
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    edits: Mapped[dict | None] = mapped_column(JSON)  # tuning signal (MEM-4)


class Task(Base):
    __tablename__ = "tasks"

    id: Mapped[str] = mapped_column(String(16), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    title: Mapped[str] = mapped_column(String(300))
    meta: Mapped[str | None] = mapped_column(String(300))
    due: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    person: Mapped[str | None] = mapped_column(String(80))
    done: Mapped[bool] = mapped_column(Boolean, default=False)
    source_conversation_id: Mapped[str | None] = mapped_column(String(32))
    wal_entry_id: Mapped[str | None] = mapped_column(String(16))


class DayRecap(Base):
    __tablename__ = "day_recaps"

    day: Mapped[date] = mapped_column(Date, primary_key=True)
    narrative: Mapped[str | None] = mapped_column(Text)
    stats: Mapped[dict] = mapped_column(JSON, default=dict)
    frozen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
