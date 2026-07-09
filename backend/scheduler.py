"""Spaced-repetition scheduling.

Rules:
- every topic starts with interval_days=1 and next_review_date=today
- score > 75  -> interval doubles (capped at 30 days)
- score <= 75 -> interval resets to 1 day
- "Today's Challenge" picks the most overdue topic (earliest next_review_date)

Multi-question sessions:
- Topics already challenged today are skipped until every topic has had one
  challenge today; only then does the rotation cycle back through them.
- Ties on next_review_date are broken by least-recently-challenged
  (never-challenged topics first), then by name for determinism.
"""

from __future__ import annotations

from datetime import date, timedelta

from fastapi import HTTPException

from backend.db import db

MAX_INTERVAL_DAYS = 30
PASS_THRESHOLD = 75


def _last_challenge_times() -> dict[str, str]:
    """topic_id -> ISO timestamp of its most recent challenge (any status)."""
    rows = (
        db().table("challenges")
        .select("topic_id, created_at")
        .order("created_at", desc=True)
        .limit(2000)
        .execute()
        .data
    )
    latest: dict[str, str] = {}
    for row in rows:  # newest first, so the first hit per topic wins
        latest.setdefault(row["topic_id"], row["created_at"])
    return latest


def _challenged_today() -> set[str]:
    rows = (
        db().table("challenges")
        .select("topic_id")
        .eq("challenge_date", date.today().isoformat())
        .execute()
        .data
    )
    return {row["topic_id"] for row in rows}


def pick_topic() -> dict:
    topics = db().table("topics").select("*").execute().data
    if not topics:
        raise HTTPException(status_code=404, detail="No topics exist yet. Add one on the Settings page.")

    last_seen = _last_challenge_times()
    used_today = _challenged_today()

    def sort_key(topic: dict):
        # Empty string sorts before any ISO timestamp -> never-challenged first.
        return (
            topic["next_review_date"],
            last_seen.get(topic["id"], ""),
            topic["name"],
        )

    fresh = [t for t in topics if t["id"] not in used_today]
    pool = fresh if fresh else topics  # cycle back once every topic was used today
    return min(pool, key=sort_key)


def apply_score(topic_id: str, score: int) -> dict:
    rows = db().table("topics").select("interval_days").eq("id", topic_id).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Topic not found.")

    if score > PASS_THRESHOLD:
        interval = min(rows[0]["interval_days"] * 2, MAX_INTERVAL_DAYS)
    else:
        interval = 1

    next_review = date.today() + timedelta(days=interval)
    db().table("topics").update({
        "interval_days": interval,
        "next_review_date": next_review.isoformat(),
    }).eq("id", topic_id).execute()

    return {"interval_days": interval, "next_review_date": next_review.isoformat()}
