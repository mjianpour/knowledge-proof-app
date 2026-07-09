# Deep Dive Tracker

Test your fluency in a subject. Connect the app to your notes, reference your sources — the rest of the weight is carried by the app.

A personal spaced-repetition learning app: one LLM-generated **conceptual** challenge per day (find the subtle bug, explain the mechanism — never fact-recall), grounded in *your* Obsidian notes and reference books. Answers are graded 0–100, symptom-patching is called out explicitly, and a spaced-repetition scheduler decides which topic you see next.

Everything runs on your machine — Flutter frontend + FastAPI backend on localhost. Only Supabase (your own project) and the LLM/GitHub APIs are reached over the internet.

```
Flutter web (localhost:8080)  ──►  FastAPI (localhost:8000)  ──►  Supabase (Postgres)
                                        │
                                        ├──►  Anthropic / OpenAI (challenges, grading, PDF digests)
                                        └──►  GitHub API (Obsidian vault sync)
```

Secrets (API keys, GitHub token, Supabase service key) live only in `.env` and are only read by the backend. The frontend never sees them.

## Initial setup

### 1. Prerequisites

- **Python 3.10+**
- **Flutter SDK** (stable channel) with web support — `flutter doctor` should be happy
- A **Supabase** account (free tier is fine)

### 2. Supabase project

1. Go to [supabase.com](https://supabase.com) → **New project** (any name/region; note the database password, you won't need it here).
2. In the dashboard: **SQL Editor → New query**, paste the contents of [`supabase/schema.sql`](supabase/schema.sql), and **Run**. This creates the `topics`, `notes`, `pdf_excerpts`, `challenges`, and `settings` tables and seeds six topics (Flutter, FastAPI, Waves, Quantum Mechanics, Linear Algebra, Thermal Physics).
3. In **Project Settings → API**, copy:
   - the **Project URL**
   - the **`service_role` secret key** (not the anon key — the backend runs locally and bypasses RLS)

### 3. `.env`

```bash
cp .env.example .env
```

Fill in:

| Variable | What |
|---|---|
| `SUPABASE_URL` | Project URL from step 2 |
| `SUPABASE_SERVICE_KEY` | `service_role` key from step 2 |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` | At least the provider you'll select in Settings (can also be pasted on the Settings page later) |
| `GITHUB_TOKEN` | Personal access token with read access to your Obsidian vault repo (needed for private repos) |

### 4. Python dependencies + CLI

```bash
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -e .
```

This installs the backend and the `knowledge` command into the venv.

### 5. Flutter dependencies

```bash
cd frontend && flutter pub get && cd ..
```

(The first `knowledge run` builds the web bundle automatically.)

## Running

```bash
knowledge run      # starts backend (localhost:8000) + frontend (localhost:8080), opens your browser
knowledge status   # shows what's running
knowledge stop     # stops both cleanly
```

Notes:

- `knowledge run` builds the Flutter web app on first run (a few minutes); afterwards it reuses the build. After changing frontend code, use `knowledge run --rebuild`.
- Running `knowledge run` twice won't double-start — it tells you it's already up. `knowledge stop` with nothing running exits gracefully.
- PIDs are tracked in `.knowledge_pids`; logs go to `.knowledge_logs/backend.log` and `.knowledge_logs/frontend.log`.
- Ports are configurable: `knowledge run --backend-port 9000 --frontend-port 9090`.
- Backend API docs (Swagger) are at `http://localhost:8000/docs`.

## Using the app

1. **Settings** (gear icon):
   - Pick the LLM provider (Anthropic / OpenAI) and optionally paste the API key — it's written to `.env`.
   - Set your Obsidian vault's GitHub repo URL and hit **Sync vault now**. Top-level vault folders are matched to topics by name (case-insensitive), so a `Quantum Mechanics/` folder feeds the Quantum Mechanics topic.
   - For each topic, set the **reference book** as a citation string (e.g. *"Electrodynamics, Reitz & Milford, 2nd ed., ch. 13"*) — famous books don't need uploading; the LLM is told you study from them.
   - For niche/small PDFs, use the upload icon on a topic: the backend extracts the text **and runs a one-time LLM distillation pass** over the file (sent natively to Anthropic when selected, otherwise via extracted text). The digest is reused for every future challenge.
2. **Today's Challenge** on the home page: the scheduler picks the most overdue topic, the LLM writes one conceptual problem from your material, you answer in free text, and the LLM grades it with feedback — flagging when you patched the symptom without understanding the mechanism.
3. **Scheduler**: every topic starts daily. Score > 75 doubles the review interval (capped at 30 days); ≤ 75 resets it to 1 day. You can do multiple challenges per day — the button keeps serving the next most-overdue topic.
4. **Heatmap**: bottom of the home page, GitHub-style, past 12 months. Intensity = challenges completed that day; hover a square for the date and topics.

## Project layout

```
cli/                 knowledge run / stop / status (typer + psutil)
backend/             FastAPI app: llm routing, GitHub sync, PDF ingest, scheduler, challenges
frontend/            Flutter web app (home / challenge / settings pages, heatmap widget)
supabase/schema.sql  run once in the Supabase SQL editor
.env.example         template for secrets
```

## Troubleshooting

- **"Supabase is not configured"** — fill `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` in `.env`, then `knowledge stop && knowledge run`.
- **"ANTHROPIC_API_KEY is not set"** — paste the key on the Settings page (or in `.env`) for the provider you selected.
- **GitHub sync 404** — private repo without a valid `GITHUB_TOKEN`, or a wrong repo URL.
- **PDF upload fails with "no extractable text"** — the PDF is a pure image scan; pypdf can't read it.
- Backend errors: `tail -f .knowledge_logs/backend.log`.
