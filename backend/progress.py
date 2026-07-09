"""In-memory progress log for long-running operations.

Single-user local app, so a process-global, thread-safe event list is enough.
The frontend polls GET /api/progress while a loading spinner is up and shows
the latest messages so the user can see what is actually happening.
"""

from __future__ import annotations

import threading
import time

_lock = threading.Lock()
_events: list[dict] = []
_busy_count = 0


def log(message: str) -> None:
    with _lock:
        _events.append({"t": time.time(), "msg": message})
        del _events[:-200]  # keep a bounded history


class task:
    """Context manager marking a busy phase; logs start, end, and elapsed time."""

    def __init__(self, label: str):
        self.label = label
        self.start = 0.0

    def __enter__(self):
        global _busy_count
        with _lock:
            _busy_count += 1
        self.start = time.time()
        log(self.label)
        return self

    def __exit__(self, exc_type, exc, tb):
        global _busy_count
        elapsed = time.time() - self.start
        if exc is None:
            log(f"✓ {self.label} — done in {elapsed:.1f}s")
        else:
            log(f"✗ {self.label} — failed after {elapsed:.1f}s")
        with _lock:
            _busy_count -= 1
        return False


def snapshot(limit: int = 12) -> dict:
    with _lock:
        return {"busy": _busy_count > 0, "events": list(_events[-limit:])}
