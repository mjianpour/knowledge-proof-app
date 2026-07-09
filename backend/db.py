"""Supabase client + settings key/value helpers."""

from __future__ import annotations

import re
from functools import lru_cache

from fastapi import HTTPException
from supabase import Client, create_client

from backend import config


def normalize_url(url: str) -> str:
    """Accept the project URL in any commonly pasted form.

    The dashboard shows several URLs; people often paste the REST endpoint
    (…supabase.co/rest/v1/), but create_client needs the bare project URL.
    """
    return re.sub(r"/(rest|auth|storage|realtime)/v\d+/?$", "", url.strip().rstrip("/"))


@lru_cache(maxsize=1)
def _client() -> Client:
    url = normalize_url(config.get_env("SUPABASE_URL"))
    key = config.get_env("SUPABASE_SERVICE_KEY")
    if not url or not key:
        raise HTTPException(
            status_code=503,
            detail="Supabase is not configured. Set SUPABASE_URL and SUPABASE_SERVICE_KEY in .env "
                   "and restart with `knowledge stop` / `knowledge run`.",
        )
    return create_client(url, key)


def db() -> Client:
    return _client()


def is_configured() -> bool:
    return bool(config.get_env("SUPABASE_URL") and config.get_env("SUPABASE_SERVICE_KEY"))


def reset_client() -> None:
    """Drop the cached client so newly saved .env credentials take effect without a restart."""
    _client.cache_clear()


def get_setting(key: str, default: str = "") -> str:
    rows = db().table("settings").select("value").eq("key", key).execute().data
    return rows[0]["value"] if rows else default


def set_setting(key: str, value: str) -> None:
    db().table("settings").upsert({"key": key, "value": value}).execute()
