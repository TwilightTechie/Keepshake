from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="KEEPSAKE_", extra="ignore")

    database_url: str = "postgresql+asyncpg://keepsake:keepsake@localhost:5432/keepsake"
    # Single-user self-host token (v1). Generate one: `openssl rand -hex 32`
    api_token: str = "dev-token-change-me"
    debug: bool = False

    # Providers (BE-3 / MEM-8): mock providers keep the whole pipeline runnable
    # with no keys and no network; sarvam uses one key for both STT and LLM.
    stt_provider: Literal["mock", "sarvam"] = "mock"
    llm_provider: Literal["mock", "sarvam"] = "mock"
    sarvam_api_key: str | None = None
    sarvam_stt_url: str = "https://api.sarvam.ai/speech-to-text"
    sarvam_stt_model: str = "saaras:v4"
    # 'unknown' = let Saaras auto-detect; required for code-mixed Hindi/English
    sarvam_language_code: str = "unknown"
    sarvam_chat_url: str = "https://api.sarvam.ai/v1/chat/completions"
    sarvam_chat_model: str = "sarvam-105b"

    # Pipeline knobs
    conversation_gap_minutes: int = 10  # silence gap that closes a conversation
    confidence_gate: float = 0.8  # >= auto-append to WAL, < goes to review (MEM-4)
    audio_retention: bool = False  # PR-2: transcribe-and-discard by default
    pipeline_poll_seconds: float = 2.0


@lru_cache
def get_settings() -> Settings:
    return Settings()
