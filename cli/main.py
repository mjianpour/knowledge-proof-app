"""Deep Dive Tracker CLI — `knowledge run` / `knowledge stop`.

Starts the FastAPI backend (uvicorn) and serves the built Flutter web app as
detached background processes, tracking their PIDs in .knowledge_pids so a
later `knowledge stop` can shut them down cleanly on Windows/macOS/Linux.
"""

from __future__ import annotations

import json
import socket
import subprocess
import sys
import time
import urllib.request
import webbrowser
from pathlib import Path

import psutil
import typer

app = typer.Typer(help="Deep Dive Tracker — run/stop the local backend and frontend.")

# The package is installed with `pip install -e .` from the project root,
# so the repo root is two levels up from this file. This makes the CLI work
# from any working directory.
PROJECT_ROOT = Path(__file__).resolve().parent.parent
PID_FILE = PROJECT_ROOT / ".knowledge_pids"
LOG_DIR = PROJECT_ROOT / ".knowledge_logs"
FRONTEND_DIR = PROJECT_ROOT / "frontend"
WEB_BUILD_DIR = FRONTEND_DIR / "build" / "web"


def _read_pid_file() -> dict | None:
    if not PID_FILE.exists():
        return None
    try:
        return json.loads(PID_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def _proc_if_ours(pid: int, marker: str) -> psutil.Process | None:
    """Return the process only if it's alive and still looks like ours.

    PIDs get recycled by the OS; checking the cmdline prevents killing an
    unrelated process that happened to reuse the PID.
    """
    try:
        proc = psutil.Process(pid)
        cmdline = " ".join(proc.cmdline())
        if marker in cmdline:
            return proc
    except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
        pass
    return None


def _running_processes(state: dict) -> dict[str, psutil.Process]:
    found = {}
    markers = {"backend": "backend.main:app", "frontend": "http.server"}
    for name, marker in markers.items():
        pid = state.get(name)
        if pid:
            proc = _proc_if_ours(pid, marker)
            if proc:
                found[name] = proc
    return found


def _spawn_detached(cmd: list[str], log_path: Path) -> subprocess.Popen:
    """Start a background process that survives this CLI exiting."""
    log_file = open(log_path, "a")
    kwargs: dict = {
        "cwd": str(PROJECT_ROOT),
        "stdout": log_file,
        "stderr": subprocess.STDOUT,
        "stdin": subprocess.DEVNULL,
    }
    if sys.platform == "win32":
        kwargs["creationflags"] = (
            subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
        )
    else:
        kwargs["start_new_session"] = True
    return subprocess.Popen(cmd, **kwargs)


def _wait_for_http(url: str, timeout: float = 45.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2):
                return True
        except Exception:
            time.sleep(0.5)
    return False


def _port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        return sock.connect_ex(("127.0.0.1", port)) == 0


def _terminate_tree(proc: psutil.Process) -> None:
    procs = [proc]
    try:
        procs += proc.children(recursive=True)
    except psutil.NoSuchProcess:
        pass
    for p in procs:
        try:
            p.terminate()
        except psutil.NoSuchProcess:
            pass
    _, alive = psutil.wait_procs(procs, timeout=5)
    for p in alive:
        try:
            p.kill()
        except psutil.NoSuchProcess:
            pass


def _build_flutter_web(rebuild: bool) -> None:
    index = WEB_BUILD_DIR / "index.html"
    if index.exists() and not rebuild:
        return
    typer.echo("Building Flutter web app (first run can take a few minutes)...")
    # shell=True on Windows so `flutter.bat` resolves from PATH.
    result = subprocess.run(
        "flutter build web",
        shell=True,
        cwd=str(FRONTEND_DIR),
    )
    if result.returncode != 0 or not index.exists():
        typer.secho("Flutter web build failed — see output above.", fg="red")
        raise typer.Exit(code=1)


@app.command()
def run(
    backend_port: int = typer.Option(8000, help="Port for the FastAPI backend."),
    frontend_port: int = typer.Option(8080, help="Port for the Flutter web app."),
    rebuild: bool = typer.Option(False, "--rebuild", help="Force a fresh `flutter build web`."),
    no_browser: bool = typer.Option(False, "--no-browser", help="Don't open the browser."),
):
    """Start the backend and frontend as background processes."""
    state = _read_pid_file()
    if state:
        alive = _running_processes(state)
        if alive:
            names = " and ".join(alive)
            typer.secho(f"Already running ({names}). Use `knowledge stop` first.", fg="yellow")
            typer.echo(f"  Frontend: http://localhost:{state.get('frontend_port', frontend_port)}")
            typer.echo(f"  Backend:  http://localhost:{state.get('backend_port', backend_port)}")
            raise typer.Exit(code=0)
        PID_FILE.unlink(missing_ok=True)  # stale file from a crash

    if not (PROJECT_ROOT / ".env").exists():
        typer.secho(
            "Warning: no .env file found in the project root. "
            "Copy .env.example to .env and fill it in — LLM/GitHub/Supabase features will fail without it.",
            fg="yellow",
        )

    for port, what in ((backend_port, "backend"), (frontend_port, "frontend")):
        if _port_in_use(port):
            typer.secho(f"Port {port} ({what}) is already in use by another process.", fg="red")
            raise typer.Exit(code=1)

    _build_flutter_web(rebuild)
    LOG_DIR.mkdir(exist_ok=True)

    typer.echo("Starting FastAPI backend...")
    backend = _spawn_detached(
        [sys.executable, "-m", "uvicorn", "backend.main:app",
         "--host", "127.0.0.1", "--port", str(backend_port)],
        LOG_DIR / "backend.log",
    )

    typer.echo("Starting frontend server...")
    frontend = _spawn_detached(
        [sys.executable, "-m", "http.server", str(frontend_port),
         "--bind", "127.0.0.1", "--directory", str(WEB_BUILD_DIR)],
        LOG_DIR / "frontend.log",
    )

    PID_FILE.write_text(json.dumps({
        "backend": backend.pid,
        "frontend": frontend.pid,
        "backend_port": backend_port,
        "frontend_port": frontend_port,
    }, indent=2))

    if not _wait_for_http(f"http://127.0.0.1:{backend_port}/api/health"):
        typer.secho(
            f"Backend did not come up — check {LOG_DIR / 'backend.log'}", fg="red"
        )
        stop()
        raise typer.Exit(code=1)
    if not _wait_for_http(f"http://127.0.0.1:{frontend_port}/"):
        typer.secho(
            f"Frontend did not come up — check {LOG_DIR / 'frontend.log'}", fg="red"
        )
        stop()
        raise typer.Exit(code=1)

    frontend_url = f"http://localhost:{frontend_port}"
    typer.secho("Deep Dive Tracker is up:", fg="green")
    typer.echo(f"  Frontend: {frontend_url}")
    typer.echo(f"  Backend:  http://localhost:{backend_port}  (docs: /docs)")
    typer.echo("Stop with: knowledge stop")

    if not no_browser:
        webbrowser.open(frontend_url)


@app.command()
def stop():
    """Stop the backend and frontend if they are running."""
    state = _read_pid_file()
    if not state:
        typer.echo("Nothing is running (no .knowledge_pids file found).")
        raise typer.Exit(code=0)

    alive = _running_processes(state)
    if not alive:
        typer.echo("Nothing is running (processes already exited). Cleaning up.")
        PID_FILE.unlink(missing_ok=True)
        raise typer.Exit(code=0)

    for name, proc in alive.items():
        typer.echo(f"Stopping {name} (pid {proc.pid})...")
        _terminate_tree(proc)

    PID_FILE.unlink(missing_ok=True)
    typer.secho("Stopped.", fg="green")


@app.command()
def status():
    """Show whether the backend and frontend are running."""
    state = _read_pid_file()
    alive = _running_processes(state) if state else {}
    if not alive:
        typer.echo("Not running.")
        raise typer.Exit(code=0)
    for name, proc in alive.items():
        port = state.get(f"{name}_port", "?")
        typer.echo(f"{name}: running (pid {proc.pid}, http://localhost:{port})")


if __name__ == "__main__":
    app()
