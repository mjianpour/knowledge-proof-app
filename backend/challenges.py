"""Challenge generation and evaluation.

Context strategy (per user's design):
- The topic's book_reference is a citation string ("Electrodynamics, Reitz &
  Milford, 2nd ed., ch. 13") — well-known books need no upload; the LLM is told
  the user studies from that book.
- Uploaded niche PDFs contribute their one-time LLM digest plus a random
  sample of raw text chunks.
- Obsidian notes for the topic are randomly sampled each day for variety.
"""

from __future__ import annotations

import random
from datetime import date

from fastapi import HTTPException

from backend import llm, scheduler
from backend.db import db

MAX_NOTE_CHARS = 4000        # per sampled note
MAX_CHUNK_CHARS = 4000       # per sampled pdf chunk
NOTE_SAMPLE = 4
CHUNK_SAMPLE = 3
CONTEXT_BUDGET_CHARS = 40000

EVALUATION_SCHEMA = {
    "type": "object",
    "properties": {
        "score": {"type": "integer", "description": "0-100 correctness score"},
        "feedback": {
            "type": "string",
            "description": "What was right, what was wrong, and the correct explanation of the mechanism.",
        },
        "understood_mechanism": {
            "type": "boolean",
            "description": "True only if the user explained the underlying mechanism, not just the surface fix.",
        },
        "symptom_patching_note": {
            "type": "string",
            "description": "If the user patched the symptom without understanding the mechanism, explain what they missed. Empty string otherwise.",
        },
    },
    "required": ["score", "feedback", "understood_mechanism", "symptom_patching_note"],
    "additionalProperties": False,
}


def _truncate(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit] + "\n[...truncated...]"


def build_context(topic: dict) -> str:
    parts: list[str] = []

    if topic.get("book_reference"):
        parts.append(f"REFERENCE BOOK: the user is studying this topic from: {topic['book_reference']}")

    notes = (
        db().table("notes")
        .select("path, content")
        .eq("topic_id", topic["id"])
        .execute()
        .data
    )
    if notes:
        for note in random.sample(notes, min(NOTE_SAMPLE, len(notes))):
            parts.append(
                f"USER'S NOTE ({note['path']}):\n{_truncate(note['content'], MAX_NOTE_CHARS)}"
            )

    digests = (
        db().table("pdf_excerpts")
        .select("filename, content")
        .eq("topic_id", topic["id"])
        .eq("is_digest", True)
        .execute()
        .data
    )
    for digest in digests:
        parts.append(
            f"DIGEST OF UPLOADED PDF ({digest['filename']}):\n{_truncate(digest['content'], 12000)}"
        )

    chunks = (
        db().table("pdf_excerpts")
        .select("filename, chunk_index, content")
        .eq("topic_id", topic["id"])
        .eq("is_digest", False)
        .execute()
        .data
    )
    if chunks:
        for chunk in random.sample(chunks, min(CHUNK_SAMPLE, len(chunks))):
            parts.append(
                f"EXCERPT FROM {chunk['filename']} (chunk {chunk['chunk_index']}):\n"
                f"{_truncate(chunk['content'], MAX_CHUNK_CHARS)}"
            )

    context = "\n\n---\n\n".join(parts)
    return _truncate(context, CONTEXT_BUDGET_CHARS)


GENERATION_SYSTEM = """You are a demanding but fair tutor building one daily challenge for a single dedicated student.

Rules for the challenge you produce:
- Produce exactly ONE conceptual problem. Never fact-recall, never a list of questions.
- The problem must require explaining a mechanism, predicting behavior from first principles, or finding and explaining a subtle error. A great format: a plausible-looking code snippet, derivation, or argument that contains one subtle conceptual bug the student must find AND explain.
- Ground the problem in the student's own material when provided (their notes, book, PDF digests) so it feels personal, but do not require material they haven't seen.
- Target roughly 5-15 minutes of hard thinking for someone who studied the material.
- Output ONLY the challenge itself. No preamble, no greeting, no answer, no hints section.

Formatting rules (the client renders GitHub-flavored markdown with LaTeX):
- All code goes in fenced code blocks with a language tag (```dart, ```python, ...).
- All mathematics goes in LaTeX: $...$ inline, $$...$$ for display equations. Never write plain-text formulas like p^2/2m or hbar — write $\\frac{p^2}{2m}$ and $\\hbar$.
- Use markdown structure (short paragraphs, lists) where it helps readability."""


def _answered_today(today: str) -> int:
    rows = (
        db().table("challenges")
        .select("id")
        .eq("status", "answered")
        .eq("challenge_date", today)
        .execute()
        .data
    )
    return len(rows)


def generate_challenge() -> dict:
    # Resume today's unanswered challenge instead of generating a duplicate.
    today = date.today().isoformat()
    pending = (
        db().table("challenges")
        .select("*")
        .eq("status", "pending")
        .eq("challenge_date", today)
        .limit(1)
        .execute()
        .data
    )
    if pending:
        challenge = pending[0]
        topic_row = db().table("topics").select("name").eq("id", challenge["topic_id"]).execute().data
        return {
            "id": challenge["id"],
            "topic": topic_row[0]["name"] if topic_row else "?",
            "question": challenge["question"],
            "resumed": True,
            "answered_today": _answered_today(today),
        }

    topic = scheduler.pick_topic()
    context = build_context(topic)
    user_prompt = (
        f"Topic for today's challenge: {topic['name']}\n\n"
        f"Student's study material for this topic:\n\n{context if context else '(no material uploaded yet — use standard core concepts of the topic)'}\n\n"
        "Generate today's single conceptual challenge now."
    )
    question = llm.generate_text(GENERATION_SYSTEM, user_prompt, max_tokens=4096).strip()
    if not question:
        raise HTTPException(status_code=502, detail="The LLM returned an empty challenge. Try again.")

    row = (
        db().table("challenges")
        .insert({
            "topic_id": topic["id"],
            "challenge_date": today,
            "question": question,
            "status": "pending",
        })
        .execute()
        .data[0]
    )
    return {
        "id": row["id"],
        "topic": topic["name"],
        "question": question,
        "resumed": False,
        "answered_today": _answered_today(today),
    }


EVALUATION_SYSTEM = """You are grading a student's free-text answer to a conceptual challenge.

Grade on understanding of the underlying mechanism, not on polish:
- Full credit requires explaining WHY, not just WHAT to change.
- Specifically detect "symptom patching": the student fixes the surface problem (e.g. changes the buggy line, cites the right formula) without demonstrating they understand the underlying mechanism. If so, cap the score at 60 and explain what mechanism they missed.
- Partial credit for partially correct reasoning; be concrete about which step of their reasoning failed.
- Feedback should teach: state the correct mechanism clearly and briefly.
- Format the feedback as GitHub-flavored markdown: code in fenced blocks with a language tag, all mathematics in LaTeX ($...$ inline, $$...$$ display) — never plain-text formulas.
Return the structured result."""


def evaluate_answer(challenge_id: str, answer: str) -> dict:
    answer = answer.strip()
    if not answer:
        raise HTTPException(status_code=400, detail="Answer is empty.")

    rows = db().table("challenges").select("*").eq("id", challenge_id).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Challenge not found.")
    challenge = rows[0]
    if challenge["status"] == "answered":
        raise HTTPException(status_code=409, detail="This challenge was already answered.")

    topic_rows = db().table("topics").select("*").eq("id", challenge["topic_id"]).execute().data
    topic_name = topic_rows[0]["name"] if topic_rows else "?"

    user_prompt = (
        f"Topic: {topic_name}\n\n"
        f"CHALLENGE GIVEN TO THE STUDENT:\n{challenge['question']}\n\n"
        f"STUDENT'S ANSWER:\n{answer}\n\n"
        "Evaluate now."
    )
    result = llm.generate_json(EVALUATION_SYSTEM, user_prompt, EVALUATION_SCHEMA, max_tokens=4096)

    score = max(0, min(100, int(result.get("score", 0))))
    feedback = result.get("feedback", "").strip()
    symptom_note = result.get("symptom_patching_note", "").strip()
    understood = bool(result.get("understood_mechanism", False))

    evaluation_text = feedback
    if symptom_note:
        evaluation_text += f"\n\n⚠ Symptom patching detected: {symptom_note}"

    db().table("challenges").update({
        "user_answer": answer,
        "evaluation": evaluation_text,
        "score": score,
        "status": "answered",
    }).eq("id", challenge_id).execute()

    schedule = scheduler.apply_score(challenge["topic_id"], score)

    return {
        "score": score,
        "feedback": feedback,
        "understood_mechanism": understood,
        "symptom_patching_note": symptom_note,
        "topic": topic_name,
        "next_review_date": schedule["next_review_date"],
        "interval_days": schedule["interval_days"],
        "answered_today": _answered_today(date.today().isoformat()),
    }
