"""Spaced-repetition scheduling.

Rules:
- every topic starts with interval_days=1 and next_review_date=today
- score > 75  -> interval doubles (capped at 30 days)
- score <= 75 -> interval resets to 1 day
- "Today's Challenge" always picks the most overdue topic (earliest next_review_date)
"""

from __future__ import annotations

from datetime import date, timedelta

from fastapi import HTTPException

from backend.db import db

MAX_INTERVAL_DAYS = 30
PASS_THRESHOLD = 75


def pick_topic() -> dict:
    rows = (
        db().table("topics")
        .select("*")
        .order("next_review_date")
        .order("name")
        .limit(1)
        .execute()
        .data
    )
    if not rows:
        raise HTTPException(status_code=404, detail="No topics exist yet. Add one on the Settings page.")
    return rows[0]


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
