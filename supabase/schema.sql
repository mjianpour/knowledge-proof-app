-- Deep Dive Tracker — Supabase schema
-- Run this in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- The backend connects with the service-role key, which bypasses RLS, so no
-- policies are needed. RLS stays disabled since this is a single-user tool
-- and the anon key is never used.

create extension if not exists pgcrypto;

-- Topics: one row per subject with its spaced-repetition state.
create table if not exists topics (
  id               uuid primary key default gen_random_uuid(),
  name             text not null unique,
  book_reference   text not null default '',   -- e.g. "Electrodynamics, Reitz & Milford, 2nd ed., ch. 13"
  interval_days    integer not null default 1,
  next_review_date date not null default current_date,
  created_at       timestamptz not null default now()
);

-- Notes: markdown files synced from the Obsidian vault on GitHub.
create table if not exists notes (
  id        uuid primary key default gen_random_uuid(),
  path      text not null unique,              -- path inside the repo, e.g. "Quantum Mechanics/spin.md"
  folder    text not null default '',          -- top-level folder, used as topic tag
  topic_id  uuid references topics(id) on delete set null,
  content   text not null,
  synced_at timestamptz not null default now()
);

create index if not exists notes_topic_idx on notes (topic_id);

-- PDF excerpts: raw extracted text chunks plus one LLM-generated digest per file.
create table if not exists pdf_excerpts (
  id          uuid primary key default gen_random_uuid(),
  topic_id    uuid not null references topics(id) on delete cascade,
  filename    text not null,
  chunk_index integer not null default 0,
  content     text not null,
  is_digest   boolean not null default false,  -- true = the one-time LLM distillation of the PDF
  created_at  timestamptz not null default now()
);

create index if not exists pdf_excerpts_topic_idx on pdf_excerpts (topic_id);

-- Challenges: one row per generated question, updated in place when answered.
create table if not exists challenges (
  id             uuid primary key default gen_random_uuid(),
  topic_id       uuid not null references topics(id) on delete cascade,
  challenge_date date not null default current_date,
  question       text not null,
  user_answer    text,
  evaluation     text,
  score          integer check (score >= 0 and score <= 100),
  status         text not null default 'pending' check (status in ('pending', 'answered')),
  created_at     timestamptz not null default now()
);

create index if not exists challenges_date_idx on challenges (challenge_date);
create index if not exists challenges_topic_idx on challenges (topic_id);

-- Settings: simple key/value store for non-secret app settings
-- (github_repo_url, llm_provider, llm_model). Secrets stay in .env.
create table if not exists settings (
  key        text primary key,
  value      text not null default '',
  updated_at timestamptz not null default now()
);

-- Seed the six starting topics (each with its own review schedule).
insert into topics (name) values
  ('Flutter'),
  ('FastAPI'),
  ('Waves'),
  ('Quantum Mechanics'),
  ('Linear Algebra'),
  ('Thermal Physics')
on conflict (name) do nothing;
