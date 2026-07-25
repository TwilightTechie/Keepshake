"""LLM provider interface (MEM-8): extraction + ask. Sarvam chat (OpenAI-compatible)
default in prod; deterministic mock for dev/tests. Prompts versioned here in-repo."""

from __future__ import annotations

import json
import re
from typing import Any, Protocol

import httpx

from app.config import get_settings

EXTRACTION_PROMPT_VERSION = "v1"

EXTRACTION_SYSTEM = """\
You maintain a personal memory log for the wearer of an always-on pendant. From a
conversation transcript, extract ONLY durable, memory-worthy items. The default is to
extract NOTHING — small talk produces no entries. Precision beats recall.

Types:
- decision: something was settled ("let's ship it in 1.4.2")
- commitment: someone promised someone something ("I'll send it by Friday")
- fact: durable info worth keeping ("Ana is moving to Lisbon in October")
- question: something raised and left open

Return STRICT JSON: {"entries": [{"type": "...", "headline": "<one line, <=120 chars>",
"why": "<the reasoning around it, from the transcript>", "participants": ["..."],
"confidence": 0.0-1.0, "quote": "<short verbatim supporting quote>",
"about_other": true|false, "due": "<ISO date or null, commitments only>"}]}
confidence reflects how sure you are this is real and durable, not phrasing quality.
Return {"entries": []} when nothing qualifies."""

ASK_SYSTEM = """\
You answer questions over the wearer's personal memory log and tasks. Use ONLY the
provided entries. Cite entries you used by their id in a `citations` array.
Return STRICT JSON: {"answer": "<concise answer, plain language>",
"citations": ["<entry-id>", ...]}. If the log has no answer, say so."""


class LlmProvider(Protocol):
    async def complete_json(self, system: str, user: str) -> dict[str, Any]: ...


def _parse_json_reply(text: str) -> dict[str, Any]:
    """LLMs wrap JSON in prose/fences despite instructions; dig it out."""
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    # Balanced-brace scan: parse the first syntactically valid object in the text.
    start = text.find("{")
    while start != -1:
        depth = 0
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[start : i + 1])
                    except json.JSONDecodeError:
                        break
        start = text.find("{", start + 1)
    raise ValueError(f"no JSON object in LLM reply: {text[:200]!r}")


class MockLlm:
    """Keyword-heuristic extraction so the full pipeline runs with no key/network.
    Not clever — just deterministic enough for tests and local dev."""

    async def complete_json(self, system: str, user: str) -> dict[str, Any]:
        if "personal memory log for the wearer" in system:
            return self._extract(user)
        return {"answer": "Mock answer over " + user[:60], "citations": []}

    def _extract(self, transcript: str) -> dict[str, Any]:
        entries = []
        for line in transcript.splitlines():
            speaker, _, text = line.partition(":")
            text = text.strip() or speaker
            lowered = text.lower()
            if "i'll " in lowered or "i will " in lowered:
                entries.append(
                    {
                        "type": "commitment",
                        "headline": text[:120],
                        "why": None,
                        "participants": [speaker.strip()],
                        "confidence": 0.9 if "by" in lowered else 0.6,
                        "quote": text[:160],
                        "about_other": False,
                        "due": None,
                    }
                )
            elif lowered.startswith(("let's", "we'll go with", "decision:")):
                entries.append(
                    {
                        "type": "decision",
                        "headline": text[:120],
                        "why": None,
                        "participants": [speaker.strip()],
                        "confidence": 0.9,
                        "quote": text[:160],
                        "about_other": False,
                        "due": None,
                    }
                )
            elif text.endswith("?"):
                entries.append(
                    {
                        "type": "question",
                        "headline": text[:120],
                        "why": None,
                        "participants": [speaker.strip()],
                        "confidence": 0.7,
                        "quote": text[:160],
                        "about_other": False,
                        "due": None,
                    }
                )
        return {"entries": entries}


class SarvamLlm:
    async def complete_json(self, system: str, user: str) -> dict[str, Any]:
        s = get_settings()
        if not s.sarvam_api_key:
            raise RuntimeError("KEEPSAKE_SARVAM_API_KEY is not set")
        async with httpx.AsyncClient(timeout=120) as client:
            resp = await client.post(
                s.sarvam_chat_url,
                headers={"Authorization": f"Bearer {s.sarvam_api_key}"},
                json={
                    "model": s.sarvam_chat_model,
                    "temperature": 0.2,
                    "max_tokens": 4096,
                    # sarvam-105b reasons by default; on long inputs the budget
                    # goes to reasoning and content comes back null. Disable it
                    # (same knob AadeshAI uses via ChatOpenAI extra_body).
                    "reasoning_effort": None,
                    "response_format": {"type": "json_object"},
                    "messages": [
                        {"role": "system", "content": system},
                        {"role": "user", "content": user},
                    ],
                },
            )
        resp.raise_for_status()
        message = resp.json()["choices"][0]["message"]
        content = message.get("content") or message.get("reasoning_content")
        if not content:
            raise ValueError(f"empty LLM reply: {str(message)[:200]!r}")
        return _parse_json_reply(content)


def get_llm_provider() -> LlmProvider:
    if get_settings().llm_provider == "sarvam":
        return SarvamLlm()
    return MockLlm()
