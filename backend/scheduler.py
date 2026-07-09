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


def pick_topics(count: int, allowed_ids: list[str] | None = None) -> list[dict]:
    """Rotation for a batch of `count` challenges.

    Optionally restricted to a user-selected subset of topics; otherwise all
    topics are eligible ("automatic"). Rotation rules are unchanged: skip
    topics already challenged today until every eligible topic has been used,
    then cycle back through, ordered by overdue-ness with the
    least-recently-challenged tie-break.
    """
    topics = db().table("topics").select("*").execute().data
    if not topics:
        raise HTTPException(status_code=404, detail="No topics exist yet. Add one on the Settings page.")
    if allowed_ids:
        allowed = set(allowed_ids)
        topics = [t for t in topics if t["id"] in allowed]
        if not topics:
            raise HTTPException(status_code=400, detail="None of the selected topics exist anymore.")

    last_seen = _last_challenge_times()

    def sort_key(topic: dict):
        # Empty string sorts before any ISO timestamp -> never-challenged first.
        return (
            topic["next_review_date"],
            last_seen.get(topic["id"], ""),
            topic["name"],
        )

    ordered = sorted(topics, key=sort_key)
    used = {tid for tid in _challenged_today() if any(t["id"] == tid for t in ordered)}

    picks: list[dict] = []
    for _ in range(count):
        fresh = [t for t in ordered if t["id"] not in used]
        if not fresh:  # every eligible topic used today -> start a new cycle
            used = set()
            fresh = ordered
        chosen = fresh[0]
        used.add(chosen["id"])
        picks.append(chosen)
    return picks


def pick_topic() -> dict:
    return pick_topics(1)[0]


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
