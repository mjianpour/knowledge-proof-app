"""Supabase client + settings key/value helpers."""

from __future__ import annotations

from functools import lru_cache

from fastapi import HTTPException
from supabase import Client, create_client

from backend import config


@lru_cache(maxsize=1)
def _client() -> Client:
    url = config.get_env("SUPABASE_URL")
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


def get_setting(key: str, default: str = "") -> str:
    rows = db().table("settings").select("value").eq("key", key).execute().data
    return rows[0]["value"] if rows else default


def set_setting(key: str, value: str) -> None:
    db().table("settings").upsert({"key": key, "value": value}).execute()
