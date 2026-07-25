"""initial: devices + audio_segments

Revision ID: 0001
Revises:
Create Date: 2026-07-23
"""

import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "devices",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("key_hash", sa.String(128), nullable=False),
        sa.Column("fw_version", sa.String(40), nullable=True),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_table(
        "audio_segments",
        sa.Column("device_id", sa.String(64), primary_key=True),
        sa.Column("seq", sa.BigInteger, primary_key=True),
        sa.Column("captured_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "received_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("opus", sa.LargeBinary, nullable=True),
    )


def downgrade() -> None:
    op.drop_table("audio_segments")
    op.drop_table("devices")
