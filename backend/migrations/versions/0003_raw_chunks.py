"""Durable, idempotent archive for unmodified pendant notifications.

Revision ID: 0003
Revises: 0002
"""

import sqlalchemy as sa
from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "raw_chunks",
        sa.Column("chunk_id", sa.String(36), primary_key=True),
        sa.Column("session_id", sa.String(36), nullable=False),
        sa.Column("device_id", sa.String(64), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "received_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("sha256", sa.String(64), nullable=False),
        sa.Column("packet_count", sa.Integer, nullable=False),
        sa.Column("metadata_json", sa.JSON, nullable=False),
        sa.Column("envelope", sa.LargeBinary, nullable=False),
    )
    op.create_index("ix_raw_chunks_session_id", "raw_chunks", ["session_id"])
    op.create_index("ix_raw_chunks_device_id", "raw_chunks", ["device_id"])


def downgrade() -> None:
    op.drop_table("raw_chunks")
