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

from backend import challenges, config, github_sync, llm, pdf_ingest, progress
from backend import db as db_mod
from backend.db import db, get_setting, set_setting

app = FastAPI(title="Deep Dive Tracker API")

# Local single-user tool: the frontend is served from another localhost port.
# If you run the frontend on a non-default port (knowledge run --frontend-port),
# add that origin here too.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:8080",
        "http://127.0.0.1:8080",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/api/health")
def health():
    return {"status": "ok"}


@app.get("/api/progress")
def get_progress():
    """Live progress log — the frontend polls this while a spinner is up."""
    return progress.snapshot()


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

class SettingsUpdate(BaseModel):
    github_repo_url: str | None = None
    llm_provider: str | None = None       # "anthropic" | "openai" | "deepseek" | "gemini"
    llm_model: str | None = None
    daily_target: int | None = None       # questions per day chosen on the home slider
    supabase_url: str | None = None       # written to .env like the keys below
    supabase_service_key: str | None = None
    anthropic_api_key: str | None = None  # keys are written to .env, never stored in Supabase
    openai_api_key: str | None = None
    deepseek_api_key: str | None = None
    gemini_api_key: str | None = None
    github_token: str | None = None


@app.get("/api/settings")
def get_settings():
    # Settings stored in Supabase — fall back to defaults when the database
    # isn't reachable yet, so the Settings page can load and be used to paste
    # the Supabase credentials in the first place.
    stored = {
        "github_repo_url": "",
        "llm_provider": "anthropic",
        "llm_model": "",
        "daily_target": 1,
    }
    supabase_error = None
    if db_mod.is_configured():
        try:
            stored = {
                "github_repo_url": get_setting("github_repo_url"),
                "llm_provider": get_setting("llm_provider", "anthropic"),
                "llm_model": get_setting("llm_model"),
                "daily_target": int(get_setting("daily_target", "1") or "1"),
            }
        except Exception as exc:
            supabase_error = f"Supabase is configured but unreachable: {exc}"
    return {
        **stored,
        "default_models": llm.DEFAULT_MODELS,
        "supabase_configured": db_mod.is_configured(),
        "supabase_error": supabase_error,
        # The URL isn't a secret; the service key is only reported masked,
        # like every other secret, so the UI can show "already set".
        "supabase_url": config.get_env("SUPABASE_URL"),
        "supabase_service_key_masked": config.mask_secret(config.get_env("SUPABASE_SERVICE_KEY")),
        "anthropic_api_key_masked": config.mask_secret(config.get_env("ANTHROPIC_API_KEY")),
        "openai_api_key_masked": config.mask_secret(config.get_env("OPENAI_API_KEY")),
        "deepseek_api_key_masked": config.mask_secret(config.get_env("DEEPSEEK_API_KEY")),
        "gemini_api_key_masked": config.mask_secret(config.get_env("GEMINI_API_KEY")),
        "github_token_masked": config.mask_secret(config.get_env("GITHUB_TOKEN")),
    }


class DetectKeyBody(BaseModel):
    api_key: str


@app.post("/api/settings/detect-key")
def detect_key(body: DetectKeyBody):
    """Paste any LLM API key: identify the provider, store the key in .env,
    and switch the active provider to it (with that provider's default model).
    """
    key = body.api_key.strip()
    if not key:
        raise HTTPException(status_code=400, detail="No API key provided.")

    with progress.task("Detecting which provider this API key belongs to"):
        provider = llm.detect_provider(key)

    config.set_env_var(llm.PROVIDER_KEY_ENV[provider], key)
    if db_mod.is_configured():
        set_setting("llm_provider", provider)
        set_setting("llm_model", "")  # use the provider's default model
    return {
        "provider": provider,
        "model": llm.DEFAULT_MODELS[provider],
        "settings": get_settings(),
    }


@app.put("/api/settings")
def update_settings(body: SettingsUpdate):
    # 1. .env-backed values first — these must work before Supabase is set up.
    if body.supabase_url is not None:
        url = db_mod.normalize_url(body.supabase_url)
        if url and not url.startswith("http"):
            raise HTTPException(status_code=400, detail="supabase_url must be an https URL.")
        config.set_env_var("SUPABASE_URL", url)
    if body.supabase_service_key:
        config.set_env_var("SUPABASE_SERVICE_KEY", body.supabase_service_key)
    if body.supabase_url is not None or body.supabase_service_key:
        db_mod.reset_client()  # pick up new credentials without a restart
    if body.anthropic_api_key:
        config.set_env_var("ANTHROPIC_API_KEY", body.anthropic_api_key)
    if body.openai_api_key:
        config.set_env_var("OPENAI_API_KEY", body.openai_api_key)
    if body.deepseek_api_key:
        config.set_env_var("DEEPSEEK_API_KEY", body.deepseek_api_key)
    if body.gemini_api_key:
        config.set_env_var("GEMINI_API_KEY", body.gemini_api_key)
    if body.github_token:
        config.set_env_var("GITHUB_TOKEN", body.github_token)

    # 2. Values stored in the Supabase settings table. If Supabase still isn't
    # configured, skip these instead of failing the save — the .env values
    # above were persisted, and the UI shows a "configure Supabase" banner.
    if not db_mod.is_configured():
        return get_settings()

    if body.github_repo_url is not None:
        set_setting("github_repo_url", body.github_repo_url.strip())
    if body.llm_provider is not None:
        if body.llm_provider not in llm.DEFAULT_MODELS:
            raise HTTPException(
                status_code=400,
                detail=f"llm_provider must be one of: {', '.join(llm.DEFAULT_MODELS)}.",
            )
        set_setting("llm_provider", body.llm_provider)
    if body.llm_model is not None:
        set_setting("llm_model", body.llm_model.strip())
    if body.daily_target is not None:
        if not 1 <= body.daily_target <= 37:
            raise HTTPException(status_code=400, detail="daily_target must be between 1 and 37.")
        set_setting("daily_target", str(body.daily_target))
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


class SessionBody(BaseModel):
    count: int = 1
    topic_ids: list[str] = []  # empty = automatic (all topics eligible)


@app.post("/api/challenges/session")
def start_session(body: SessionBody):
    if not 1 <= body.count <= 37:
        raise HTTPException(status_code=400, detail="count must be between 1 and 37.")
    return challenges.generate_session(body.count, body.topic_ids)


@app.get("/api/challenges")
def list_challenges(limit: int = 300):
    """Full challenge history (newest first) for the sidebar question list."""
    rows = (
        db().table("challenges")
        .select("id, challenge_date, question, user_answer, evaluation, score, status, created_at, topics(name)")
        .order("created_at", desc=True)
        .limit(limit)
        .execute()
        .data
    )
    return [
        {
            "id": r["id"],
            "date": r["challenge_date"],
            "topic": (r.get("topics") or {}).get("name", "?"),
            "question": r["question"],
            "user_answer": r["user_answer"],
            "evaluation": r["evaluation"],
            "score": r["score"],
            "status": r["status"],
            "created_at": r["created_at"],
        }
        for r in rows
    ]


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
