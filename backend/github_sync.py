"""Pull all .md files from the configured GitHub repo (Obsidian vault) into Supabase."""

from __future__ import annotations

import re

import httpx
from fastapi import HTTPException

from backend import config
from backend.db import db, get_setting

API = "https://api.github.com"


def _parse_repo_url(url: str) -> tuple[str, str]:
    match = re.search(r"github\.com[:/]([^/]+)/([^/#?]+)", url)
    if not match:
        raise HTTPException(status_code=400, detail=f"Could not parse GitHub repo from URL: {url!r}")
    owner, repo = match.group(1), match.group(2)
    return owner, repo.removesuffix(".git")


def _headers() -> dict:
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = config.get_env("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def _topic_map() -> dict[str, str]:
    """folder-name (lowercased) -> topic id, matched against topic names."""
    topics = db().table("topics").select("id, name").execute().data
    return {t["name"].strip().lower(): t["id"] for t in topics}


def sync() -> dict:
    repo_url = get_setting("github_repo_url")
    if not repo_url:
        raise HTTPException(status_code=400, detail="No GitHub repo URL configured. Set it on the Settings page.")

    owner, repo = _parse_repo_url(repo_url)
    topics = _topic_map()

    with httpx.Client(headers=_headers(), timeout=60) as client:
        repo_info = client.get(f"{API}/repos/{owner}/{repo}")
        if repo_info.status_code == 404:
            raise HTTPException(
                status_code=404,
                detail=f"Repo {owner}/{repo} not found. For private repos, set GITHUB_TOKEN in .env.",
            )
        repo_info.raise_for_status()
        branch = repo_info.json()["default_branch"]

        tree_resp = client.get(f"{API}/repos/{owner}/{repo}/git/trees/{branch}", params={"recursive": "1"})
        tree_resp.raise_for_status()
        tree = tree_resp.json()

        md_files = [item for item in tree.get("tree", []) if item["type"] == "blob" and item["path"].endswith(".md")]

        synced, matched = 0, 0
        for item in md_files:
            path = item["path"]
            raw = client.get(
                f"{API}/repos/{owner}/{repo}/contents/{path}",
                params={"ref": branch},
                headers={**_headers(), "Accept": "application/vnd.github.raw+json"},
            )
            if raw.status_code != 200:
                continue

            folder = path.split("/")[0] if "/" in path else ""
            topic_id = topics.get(folder.strip().lower())
            if topic_id:
                matched += 1

            db().table("notes").upsert(
                {"path": path, "folder": folder, "topic_id": topic_id, "content": raw.text},
                on_conflict="path",
            ).execute()
            synced += 1

    return {
        "repo": f"{owner}/{repo}",
        "branch": branch,
        "markdown_files_found": len(md_files),
        "synced": synced,
        "matched_to_topics": matched,
        "hint": "Folders are matched to topics by name (case-insensitive). "
                "Unmatched notes are stored but not used in challenges.",
    }
