"""pipeline tables: conversations, turns, wal, review, tasks, recaps; segment flags

Revision ID: 0002
Revises: 0001
Create Date: 2026-07-23
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column("audio_segments", "opus", new_column_name="audio")
    op.add_column("audio_segments", sa.Column("codec", sa.String(12), server_default="opus"))
    op.add_column(
        "audio_segments",
        sa.Column("utterance_end", sa.Boolean, server_default=sa.false(), nullable=False),
    )
    op.add_column(
        "audio_segments",
        sa.Column("processed", sa.Boolean, server_default=sa.false(), nullable=False),
    )

    op.create_table(
        "conversations",
        sa.Column("id", sa.String(32), primary_key=True),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("title", sa.String(200)),
        sa.Column("summary", sa.Text),
        sa.Column("participants", sa.JSON, nullable=False, server_default="[]"),
    )
    op.create_table(
        "transcript_turns",
        sa.Column("id", sa.BigInteger, primary_key=True, autoincrement=True),
        sa.Column("conversation_id", sa.String(32), sa.ForeignKey("conversations.id"), index=True),
        sa.Column("device_id", sa.String(64), nullable=False),
        sa.Column("speaker", sa.String(80), nullable=False, server_default="Speaker 1"),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("text", sa.Text, nullable=False),
        sa.Column("words", sa.JSON),
        sa.Column("extracted", sa.Boolean, nullable=False, server_default=sa.false()),
    )
    op.create_table(
        "wal_entries",
        sa.Column("id", sa.String(16), primary_key=True),
        sa.Column("ts", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("type", sa.String(16), nullable=False),
        sa.Column("headline", sa.String(300), nullable=False),
        sa.Column("why", sa.Text),
        sa.Column("participants", sa.JSON, nullable=False, server_default="[]"),
        sa.Column("confidence", sa.Float, nullable=False, server_default="1.0"),
        sa.Column("provenance", sa.String(12), nullable=False, server_default="auto"),
        sa.Column("evidence", sa.JSON),
        sa.Column("refs", sa.JSON, nullable=False, server_default="[]"),
        sa.Column("superseded_by", sa.String(16)),
        sa.Column("about_other", sa.Boolean, nullable=False, server_default=sa.false()),
    )
    op.create_table(
        "review_queue",
        sa.Column("id", sa.String(16), primary_key=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("status", sa.String(12), nullable=False, server_default="pending"),
        sa.Column("candidate", sa.JSON, nullable=False),
        sa.Column("resolved_at", sa.DateTime(timezone=True)),
        sa.Column("edits", sa.JSON),
    )
    op.create_table(
        "tasks",
        sa.Column("id", sa.String(16), primary_key=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("title", sa.String(300), nullable=False),
        sa.Column("meta", sa.String(300)),
        sa.Column("due", sa.DateTime(timezone=True)),
        sa.Column("person", sa.String(80)),
        sa.Column("done", sa.Boolean, nullable=False, server_default=sa.false()),
        sa.Column("source_conversation_id", sa.String(32)),
        sa.Column("wal_entry_id", sa.String(16)),
    )
    op.create_table(
        "day_recaps",
        sa.Column("day", sa.Date, primary_key=True),
        sa.Column("narrative", sa.Text),
        sa.Column("stats", sa.JSON, nullable=False, server_default="{}"),
        sa.Column("frozen_at", sa.DateTime(timezone=True)),
    )


def downgrade() -> None:
    tables = ["day_recaps", "tasks", "review_queue", "wal_entries", "transcript_turns",
              "conversations"]
    for t in tables:
        op.drop_table(t)
    op.drop_column("audio_segments", "processed")
    op.drop_column("audio_segments", "utterance_end")
    op.drop_column("audio_segments", "codec")
    op.alter_column("audio_segments", "audio", new_column_name="opus")
