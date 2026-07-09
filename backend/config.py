"""Environment / .env handling. Secrets live only here, never in Supabase or the frontend."""

from __future__ import annotations

import os
import re
from pathlib import Path

from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = PROJECT_ROOT / ".env"

load_dotenv(ENV_FILE)

SECRET_KEYS = ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GITHUB_TOKEN")


def get_env(key: str) -> str:
    return os.environ.get(key, "").strip()


def set_env_var(key: str, value: str) -> None:
    """Write/update a variable in .env (creating the file if needed) and in the live process."""
    value = value.strip()
    lines: list[str] = []
    if ENV_FILE.exists():
        lines = ENV_FILE.read_text().splitlines()

    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    replaced = False
    for i, line in enumerate(lines):
        if pattern.match(line):
            lines[i] = f"{key}={value}"
            replaced = True
            break
    if not replaced:
        lines.append(f"{key}={value}")

    ENV_FILE.write_text("\n".join(lines) + "\n")
    os.environ[key] = value


def mask_secret(value: str) -> str:
    """Return a display-safe version of a secret, e.g. 'sk-a...x9Kw'."""
    if not value:
        return ""
    if len(value) <= 8:
        return "*" * len(value)
    return f"{value[:4]}...{value[-4:]}"
