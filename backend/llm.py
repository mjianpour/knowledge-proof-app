"""LLM provider routing (Anthropic / OpenAI / DeepSeek / Gemini).

The provider and model are stored in the Supabase settings table; API keys are
read from .env only. All calls go through this module so the rest of the
backend is provider-agnostic.

Provider notes:
- DeepSeek is OpenAI-compatible: the OpenAI client pointed at api.deepseek.com.
  deepseek-reasoner rejects response_format, so JSON is prompt-instructed and
  parsed robustly instead of schema-enforced.
- Gemini uses the native google-genai SDK (successor to google-generativeai)
  and, like Anthropic, supports native PDF input for the distillation pass.
"""

from __future__ import annotations

import base64
import json
import re

import httpx
from fastapi import HTTPException

from backend import config, progress
from backend.db import get_setting

DEFAULT_MODELS = {
    "anthropic": "claude-opus-4-8",
    "openai": "gpt-5.1",
    "deepseek": "deepseek-chat",
    "gemini": "gemini-2.5-flash",
}

PROVIDER_KEY_ENV = {
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
    "deepseek": "DEEPSEEK_API_KEY",
    "gemini": "GEMINI_API_KEY",
}

DEEPSEEK_BASE_URL = "https://api.deepseek.com"

# Providers that can ingest a PDF file directly for the one-time distillation
# pass, with a size cap that keeps the request under each API's limit
# (Anthropic: 32 MB request; Gemini: 20 MB inline request), leaving headroom
# for base64 overhead.
NATIVE_PDF_LIMITS = {
    "anthropic": 25 * 1024 * 1024,
    "gemini": 14 * 1024 * 1024,
}


def _probe_key(provider: str, key: str) -> bool:
    """Cheap authenticated GET against the provider's model list."""
    try:
        with httpx.Client(timeout=10) as client:
            if provider == "anthropic":
                r = client.get(
                    "https://api.anthropic.com/v1/models",
                    headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
                )
            elif provider == "openai":
                r = client.get(
                    "https://api.openai.com/v1/models",
                    headers={"Authorization": f"Bearer {key}"},
                )
            elif provider == "deepseek":
                r = client.get(
                    f"{DEEPSEEK_BASE_URL}/models",
                    headers={"Authorization": f"Bearer {key}"},
                )
            else:  # gemini (Google AI Studio)
                r = client.get(
                    "https://generativelanguage.googleapis.com/v1beta/models",
                    params={"key": key},
                )
        return r.status_code == 200
    except httpx.HTTPError:
        return False


def detect_provider(api_key: str) -> str:
    """Figure out which provider an arbitrary API key belongs to.

    The key's format narrows the candidates (OpenAI and DeepSeek both use
    'sk-...', so format alone is ambiguous), then each candidate is verified
    with a real authenticated request until one accepts the key.
    """
    key = api_key.strip()
    if key.startswith("sk-ant-"):
        candidates = ["anthropic"]
    elif key.startswith("AIza"):
        candidates = ["gemini"]
    elif key.startswith("sk-"):
        candidates = ["openai", "deepseek"]
    else:
        candidates = ["anthropic", "openai", "deepseek", "gemini"]

    for provider in candidates:
        progress.log(f"Checking the key against {provider}...")
        if _probe_key(provider, key):
            progress.log(f"✓ Key authenticated with {provider}")
            return provider

    raise HTTPException(
        status_code=400,
        detail="This key was not accepted by any supported provider "
               f"(tried: {', '.join(candidates)}). Check that it was copied "
               "completely and is active.",
    )


def provider_config() -> tuple[str, str]:
    """Return (provider, model), validating that the API key is present."""
    provider = get_setting("llm_provider", "anthropic")
    if provider not in DEFAULT_MODELS:
        provider = "anthropic"
    model = get_setting("llm_model", "") or DEFAULT_MODELS[provider]

    key_name = PROVIDER_KEY_ENV[provider]
    if not config.get_env(key_name):
        raise HTTPException(
            status_code=503,
            detail=f"{key_name} is not set. Add it on the Settings page (or in .env).",
        )
    return provider, model


def _schema_instruction(schema: dict) -> str:
    return (
        "\n\nRespond with ONLY a single JSON object (no prose, no code fence) "
        f"that conforms exactly to this JSON schema:\n{json.dumps(schema)}"
    )


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
                        schema: dict | None = None, effort: str | None = None) -> str:
    kwargs: dict = {
        "model": model,
        "max_tokens": max_tokens,
        "system": system,
        "thinking": {"type": "adaptive"},
        "messages": [{"role": "user", "content": content}],
    }
    output_config: dict = {}
    if effort is not None:
        output_config["effort"] = effort
    if schema is not None:
        output_config["format"] = {"type": "json_schema", "schema": schema}
    if output_config:
        kwargs["output_config"] = output_config
    response = _anthropic_client().messages.create(**kwargs)
    return _anthropic_text(response)


# ---------------------------------------------------------------------------
# OpenAI-compatible (OpenAI, DeepSeek)
# ---------------------------------------------------------------------------

def _openai_compat_generate(provider: str, model: str, system: str, user_text: str,
                            max_tokens: int, schema: dict | None = None) -> str:
    from openai import OpenAI

    if provider == "deepseek":
        client = OpenAI(api_key=config.get_env("DEEPSEEK_API_KEY"), base_url=DEEPSEEK_BASE_URL)
    else:
        client = OpenAI(api_key=config.get_env("OPENAI_API_KEY"))

    kwargs: dict = {"model": model}
    if provider == "deepseek":
        # DeepSeek still uses max_tokens, and deepseek-reasoner rejects
        # response_format entirely — instruct JSON in the prompt instead.
        kwargs["max_tokens"] = max_tokens
        if schema is not None:
            user_text += _schema_instruction(schema)
    else:
        kwargs["max_completion_tokens"] = max_tokens
        if schema is not None:
            kwargs["response_format"] = {
                "type": "json_schema",
                "json_schema": {"name": "result", "schema": schema, "strict": True},
            }

    kwargs["messages"] = [
        {"role": "system", "content": system},
        {"role": "user", "content": user_text},
    ]
    response = client.chat.completions.create(**kwargs)
    return response.choices[0].message.content or ""


# ---------------------------------------------------------------------------
# Gemini (native google-genai SDK)
# ---------------------------------------------------------------------------

def _gemini_generate(model: str, system: str, contents, max_tokens: int,
                     schema: dict | None = None) -> str:
    from google import genai
    from google.genai import types

    client = genai.Client(api_key=config.get_env("GEMINI_API_KEY"))
    config_kwargs: dict = {
        "system_instruction": system,
        "max_output_tokens": max_tokens,
    }
    if schema is not None:
        # Gemini's response_schema uses its own schema dialect; JSON mode plus
        # a prompt-embedded schema is portable and parsed robustly downstream.
        config_kwargs["response_mime_type"] = "application/json"
        if isinstance(contents, str):
            contents = contents + _schema_instruction(schema)
        elif isinstance(contents, list):
            contents = [*contents, _schema_instruction(schema)]

    response = client.models.generate_content(
        model=model,
        contents=contents,
        config=types.GenerateContentConfig(**config_kwargs),
    )
    return response.text or ""


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def _dispatch(provider: str, model: str, system: str, user_text: str,
              max_tokens: int, schema: dict | None, effort: str | None = None) -> str:
    if provider == "anthropic":
        return _anthropic_generate(model, system, user_text, max_tokens,
                                   schema=schema, effort=effort)
    if provider == "gemini":
        return _gemini_generate(model, system, user_text, max_tokens, schema=schema)
    return _openai_compat_generate(provider, model, system, user_text, max_tokens, schema=schema)


def generate_text(system: str, user_text: str, max_tokens: int = 4096,
                  effort: str | None = None) -> str:
    """`effort` tunes latency vs depth on Anthropic models; ignored elsewhere."""
    provider, model = provider_config()
    try:
        return _dispatch(provider, model, system, user_text, max_tokens, None, effort)
    except HTTPException:
        raise
    except Exception as exc:  # surface provider errors to the UI with context
        raise HTTPException(status_code=502, detail=f"LLM call failed ({provider}/{model}): {exc}")


def generate_json(system: str, user_text: str, schema: dict, max_tokens: int = 4096) -> dict:
    provider, model = provider_config()
    try:
        raw = _dispatch(provider, model, system, user_text, max_tokens, schema)
        return _parse_json(raw)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"LLM call failed ({provider}/{model}): {exc}")


def _parse_json(raw: str) -> dict:
    raw = raw.strip()
    if raw.startswith("```"):  # tolerate fenced output from prompt-instructed JSON
        raw = re.sub(r"^```[a-zA-Z]*\n?|```$", "", raw).strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", raw, re.DOTALL)  # tolerate stray prose around the JSON
        if match:
            return json.loads(match.group(0))
        raise


def native_pdf_limit() -> int:
    """Max PDF size (bytes) the current provider accepts natively; 0 = unsupported."""
    provider, _ = provider_config()
    return NATIVE_PDF_LIMITS.get(provider, 0)


def digest_pdf_native(pdf_bytes: bytes, prompt: str, max_tokens: int = 8192) -> str:
    """One-time distillation pass: send the PDF file itself to the model.

    Supported for Anthropic (base64 document block) and Gemini (inline bytes
    part). Callers fall back to text extraction + generate_text() for other
    providers or oversized files.
    """
    provider, model = provider_config()
    system = "You are a precise study-material analyst."
    try:
        if provider == "anthropic":
            data = base64.standard_b64encode(pdf_bytes).decode("utf-8")
            content = [
                {
                    "type": "document",
                    "source": {"type": "base64", "media_type": "application/pdf", "data": data},
                },
                {"type": "text", "text": prompt},
            ]
            return _anthropic_generate(model, system, content, max_tokens)
        if provider == "gemini":
            from google.genai import types

            contents = [
                types.Part.from_bytes(data=pdf_bytes, mime_type="application/pdf"),
                prompt,
            ]
            return _gemini_generate(model, system, contents, max_tokens)
        raise HTTPException(status_code=400, detail=f"{provider} does not support native PDF input.")
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"PDF digestion failed ({provider}/{model}): {exc}")
