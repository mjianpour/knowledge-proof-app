"""PDF upload pipeline: local text extraction + one-time LLM distillation.

Per the user's design, uploaded PDFs are small niche documents. Each upload:
1. Extracts text server-side with pypdf and stores it as raw chunks.
2. Runs ONE LLM pass over the file to produce a study digest — the PDF is sent
   natively when the provider supports file input (Anthropic); otherwise the
   locally-extracted text is sent instead. The digest is stored alongside the
   chunks and reused for every future challenge (no per-challenge re-reading).
"""

from __future__ import annotations

import io

from fastapi import HTTPException
from pypdf import PdfReader

from backend import llm
from backend.db import db

CHUNK_CHARS = 6000
NATIVE_PDF_MAX_BYTES = 25 * 1024 * 1024  # stay under the 32 MB request limit after base64

DIGEST_PROMPT = """This PDF is niche study material for the topic "{topic}". Produce a study digest that a tutor can later use to write deep conceptual questions. Include:
1. The core concepts and mechanisms covered (with the key equations/definitions).
2. Subtle points, common misconceptions, and easy-to-get-wrong details.
3. Any worked examples or derivations, summarized with their key steps.
Write it as compact markdown. Be faithful to the document; do not pad."""


def extract_text(pdf_bytes: bytes) -> str:
    try:
        reader = PdfReader(io.BytesIO(pdf_bytes))
        pages = [page.extract_text() or "" for page in reader.pages]
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not read PDF: {exc}")
    text = "\n\n".join(pages).strip()
    if not text:
        raise HTTPException(
            status_code=400,
            detail="No extractable text found in this PDF (it may be a pure image scan).",
        )
    return text


def _chunk(text: str) -> list[str]:
    return [text[i:i + CHUNK_CHARS] for i in range(0, len(text), CHUNK_CHARS)]


def ingest(topic_id: str, filename: str, pdf_bytes: bytes) -> dict:
    topic_rows = db().table("topics").select("name").eq("id", topic_id).execute().data
    if not topic_rows:
        raise HTTPException(status_code=404, detail="Topic not found.")
    topic_name = topic_rows[0]["name"]

    text = extract_text(pdf_bytes)
    chunks = _chunk(text)

    # One-time LLM distillation: native file input if supported, else the extracted text.
    prompt = DIGEST_PROMPT.format(topic=topic_name)
    if llm.supports_native_pdf() and len(pdf_bytes) <= NATIVE_PDF_MAX_BYTES:
        digest = llm.digest_pdf_native(pdf_bytes, prompt)
        digest_source = "native-pdf"
    else:
        digest = llm.generate_text(
            "You are a precise study-material analyst.",
            f"{prompt}\n\nDOCUMENT TEXT:\n{text[:150000]}",
            max_tokens=8192,
        )
        digest_source = "extracted-text"

    # Replace any previous ingestion of the same file for this topic.
    db().table("pdf_excerpts").delete().eq("topic_id", topic_id).eq("filename", filename).execute()

    rows = [
        {"topic_id": topic_id, "filename": filename, "chunk_index": i, "content": chunk, "is_digest": False}
        for i, chunk in enumerate(chunks)
    ]
    rows.append({
        "topic_id": topic_id, "filename": filename, "chunk_index": -1, "content": digest, "is_digest": True,
    })
    db().table("pdf_excerpts").insert(rows).execute()

    return {
        "filename": filename,
        "topic": topic_name,
        "chunks_stored": len(chunks),
        "digest_chars": len(digest),
        "digest_source": digest_source,
    }
