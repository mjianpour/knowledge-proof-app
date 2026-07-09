"""Deep Dive Tracker — FastAPI backend (localhost only).

All heavy lifting lives in the sibling modules; this file is just the HTTP
surface the Flutter app talks to. Secrets never leave this process.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import date, timedelta

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from backend import challenges, config, github_sync, llm, pdf_ingest
from backend.db import db, get_setting, set_setting

app = FastAPI(title="Deep Dive Tracker API")

# Local single-user tool: the frontend is served from another localhost port.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/api/health")
def health():
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

class SettingsUpdate(BaseModel):
    github_repo_url: str | None = None
    llm_provider: str | None = None       # "anthropic" | "openai"
    llm_model: str | None = None
    anthropic_api_key: str | None = None  # written to .env, never stored in Supabase
    openai_api_key: str | None = None
    github_token: str | None = None


@app.get("/api/settings")
def get_settings():
    return {
        "github_repo_url": get_setting("github_repo_url"),
        "llm_provider": get_setting("llm_provider", "anthropic"),
        "llm_model": get_setting("llm_model"),
        "default_models": llm.DEFAULT_MODELS,
        # Secrets are only reported masked so the UI can show "already set".
        "anthropic_api_key_masked": config.mask_secret(config.get_env("ANTHROPIC_API_KEY")),
        "openai_api_key_masked": config.mask_secret(config.get_env("OPENAI_API_KEY")),
        "github_token_masked": config.mask_secret(config.get_env("GITHUB_TOKEN")),
    }


@app.put("/api/settings")
def update_settings(body: SettingsUpdate):
    if body.github_repo_url is not None:
        set_setting("github_repo_url", body.github_repo_url.strip())
    if body.llm_provider is not None:
        if body.llm_provider not in ("anthropic", "openai"):
            raise HTTPException(status_code=400, detail="llm_provider must be 'anthropic' or 'openai'.")
        set_setting("llm_provider", body.llm_provider)
    if body.llm_model is not None:
        set_setting("llm_model", body.llm_model.strip())
    if body.anthropic_api_key:
        config.set_env_var("ANTHROPIC_API_KEY", body.anthropic_api_key)
    if body.openai_api_key:
        config.set_env_var("OPENAI_API_KEY", body.openai_api_key)
    if body.github_token:
        config.set_env_var("GITHUB_TOKEN", body.github_token)
    return get_settings()


# ---------------------------------------------------------------------------
# Topics
# ---------------------------------------------------------------------------

class TopicCreate(BaseModel):
    name: str
    book_reference: str = ""


class TopicUpdate(BaseModel):
    name: str | None = None
    book_reference: str | None = None


@app.get("/api/topics")
def list_topics():
    return db().table("topics").select("*").order("name").execute().data


@app.post("/api/topics")
def create_topic(body: TopicCreate):
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Topic name is required.")
    existing = db().table("topics").select("id").ilike("name", name).execute().data
    if existing:
        raise HTTPException(status_code=409, detail=f"Topic '{name}' already exists.")
    return (
        db().table("topics")
        .insert({"name": name, "book_reference": body.book_reference.strip()})
        .execute()
        .data[0]
    )


@app.patch("/api/topics/{topic_id}")
def update_topic(topic_id: str, body: TopicUpdate):
    updates = {}
    if body.name is not None:
        updates["name"] = body.name.strip()
    if body.book_reference is not None:
        updates["book_reference"] = body.book_reference.strip()
    if not updates:
        raise HTTPException(status_code=400, detail="Nothing to update.")
    rows = db().table("topics").update(updates).eq("id", topic_id).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Topic not found.")
    return rows[0]


@app.delete("/api/topics/{topic_id}")
def delete_topic(topic_id: str):
    db().table("topics").delete().eq("id", topic_id).execute()
    return {"deleted": topic_id}


# ---------------------------------------------------------------------------
# Knowledge sources
# ---------------------------------------------------------------------------

@app.post("/api/sync/github")
def sync_github():
    return github_sync.sync()


@app.post("/api/pdfs/upload")
async def upload_pdf(topic_id: str = Form(...), file: UploadFile = File(...)):
    if not (file.filename or "").lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="Only .pdf files are supported.")
    pdf_bytes = await file.read()
    if not pdf_bytes:
        raise HTTPException(status_code=400, detail="Uploaded file is empty.")
    return pdf_ingest.ingest(topic_id, file.filename, pdf_bytes)


@app.get("/api/pdfs")
def list_pdfs():
    """Distinct uploaded PDFs per topic (digest rows only)."""
    rows = (
        db().table("pdf_excerpts")
        .select("filename, topic_id, created_at, topics(name)")
        .eq("is_digest", True)
        .execute()
        .data
    )
    return [
        {
            "filename": r["filename"],
            "topic_id": r["topic_id"],
            "topic": (r.get("topics") or {}).get("name", "?"),
            "uploaded_at": r["created_at"],
        }
        for r in rows
    ]


# ---------------------------------------------------------------------------
# Challenges
# ---------------------------------------------------------------------------

class AnswerBody(BaseModel):
    answer: str


@app.post("/api/challenges/today")
def todays_challenge():
    return challenges.generate_challenge()


@app.post("/api/challenges/{challenge_id}/answer")
def answer_challenge(challenge_id: str, body: AnswerBody):
    return challenges.evaluate_answer(challenge_id, body.answer)


# ---------------------------------------------------------------------------
# Heatmap
# ---------------------------------------------------------------------------

@app.get("/api/heatmap")
def heatmap(days: int = 365):
    start = (date.today() - timedelta(days=days - 1)).isoformat()
    rows = (
        db().table("challenges")
        .select("challenge_date, topics(name)")
        .eq("status", "answered")
        .gte("challenge_date", start)
        .execute()
        .data
    )
    by_day: dict[str, list[str]] = defaultdict(list)
    for row in rows:
        topic = (row.get("topics") or {}).get("name", "?")
        by_day[row["challenge_date"]].append(topic)
    return {
        "start": start,
        "end": date.today().isoformat(),
        "days": [
            {"date": day, "count": len(topics), "topics": sorted(set(topics))}
            for day, topics in sorted(by_day.items())
        ],
    }
