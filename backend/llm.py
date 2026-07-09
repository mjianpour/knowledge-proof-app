"""LLM provider routing (Anthropic / OpenAI).

The provider and model are stored in the Supabase settings table; API keys are
read from .env only. All calls go through this module so the rest of the
backend is provider-agnostic.
"""

from __future__ import annotations

import base64
import json
import re

from fastapi import HTTPException

from backend import config
from backend.db import get_setting

DEFAULT_MODELS = {
    "anthropic": "claude-opus-4-8",
    "openai": "gpt-5.1",
}


def provider_config() -> tuple[str, str]:
    """Return (provider, model), validating that the API key is present."""
    provider = get_setting("llm_provider", "anthropic")
    if provider not in DEFAULT_MODELS:
        provider = "anthropic"
    model = get_setting("llm_model", "") or DEFAULT_MODELS[provider]

    key_name = "ANTHROPIC_API_KEY" if provider == "anthropic" else "OPENAI_API_KEY"
    if not config.get_env(key_name):
        raise HTTPException(
            status_code=503,
            detail=f"{key_name} is not set. Add it on the Settings page (or in .env).",
        )
    return provider, model


# ---------------------------------------------------------------------------
# Anthropic
# ---------------------------------------------------------------------------

def _anthropic_client():
    import anthropic

    return anthropic.Anthropic(api_key=config.get_env("ANTHROPIC_API_KEY"))


def _anthropic_text(response) -> str:
    if response.stop_reason == "refusal":
        raise HTTPException(status_code=502, detail="The model declined this request (refusal).")
    return "".join(b.text for b in response.content if b.type == "text")


def _anthropic_generate(model: str, system: str, content, max_tokens: int,
                        schema: dict | None = None) -> str:
    kwargs: dict = {
        "model": model,
        "max_tokens": max_tokens,
        "system": system,
        "thinking": {"type": "adaptive"},
        "messages": [{"role": "user", "content": content}],
    }
    if schema is not None:
        kwargs["output_config"] = {"format": {"type": "json_schema", "schema": schema}}
    response = _anthropic_client().messages.create(**kwargs)
    return _anthropic_text(response)


# ---------------------------------------------------------------------------
# OpenAI
# ---------------------------------------------------------------------------

def _openai_client():
    from openai import OpenAI

    return OpenAI(api_key=config.get_env("OPENAI_API_KEY"))


def _openai_generate(model: str, system: str, user_text: str, max_tokens: int,
                     schema: dict | None = None) -> str:
    kwargs: dict = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user_text},
        ],
        "max_completion_tokens": max_tokens,
    }
    if schema is not None:
        kwargs["response_format"] = {
            "type": "json_schema",
            "json_schema": {"name": "result", "schema": schema, "strict": True},
        }
    response = _openai_client().chat.completions.create(**kwargs)
    return response.choices[0].message.content or ""


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def generate_text(system: str, user_text: str, max_tokens: int = 4096) -> str:
    provider, model = provider_config()
    try:
        if provider == "anthropic":
            return _anthropic_generate(model, system, user_text, max_tokens)
        return _openai_generate(model, system, user_text, max_tokens)
    except HTTPException:
        raise
    except Exception as exc:  # surface provider errors to the UI with context
        raise HTTPException(status_code=502, detail=f"LLM call failed ({provider}/{model}): {exc}")


def generate_json(system: str, user_text: str, schema: dict, max_tokens: int = 4096) -> dict:
    provider, model = provider_config()
    try:
        if provider == "anthropic":
            raw = _anthropic_generate(model, system, user_text, max_tokens, schema=schema)
        else:
            raw = _openai_generate(model, system, user_text, max_tokens, schema=schema)
        return _parse_json(raw)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"LLM call failed ({provider}/{model}): {exc}")


def _parse_json(raw: str) -> dict:
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", raw, re.DOTALL)  # tolerate stray prose around the JSON
        if match:
            return json.loads(match.group(0))
        raise


def supports_native_pdf() -> bool:
    provider, _ = provider_config()
    return provider == "anthropic"


def digest_pdf_native(pdf_bytes: bytes, prompt: str, max_tokens: int = 8192) -> str:
    """One-time distillation pass: send the PDF file itself to the model (Anthropic only).

    Anthropic accepts base64 PDF document blocks directly; callers should fall
    back to text extraction + generate_text() for other providers or oversized
    files (32 MB request limit).
    """
    _, model = provider_config()
    data = base64.standard_b64encode(pdf_bytes).decode("utf-8")
    content = [
        {
            "type": "document",
            "source": {"type": "base64", "media_type": "application/pdf", "data": data},
        },
        {"type": "text", "text": prompt},
    ]
    try:
        return _anthropic_generate(model, "You are a precise study-material analyst.", content, max_tokens)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"PDF digestion failed: {exc}")
