# Task T-2.1 — DB schema + migrations

**Wave:** 1
**Model:** Sonnet 4.6
**Risk:** low
**Effort:** M (1–3h)
**Plan reference:** `.claude/plans/plan.md` §3 T-2.1
**Master plan reference:** `../groundtruth/.claude/plans/master-plan.md` (locked stack table)

## Goal

Author the Postgres + pgvector + pgvectorscale schema for the substrate. The schema must implement the master plan's tables (`sources`, `source_pages`, `facts`, `fact_references`, `drift_events`, `eval_results`) with a `diskann` index on `facts.embedding vector(1024)` (sized for `voyage-4-large`).

## Allowed file touches (DO NOT touch anything else)

- `packages/core/kb/schema.sql` (new)
- `packages/core/kb/migrations/` (new directory; create at least `0001_initial.sql` mirroring `schema.sql` so future migrations follow the same convention)
- `packages/core/kb/connection.py` (new — async psycopg connection factory)
- `packages/core/kb/__init__.py` (re-exports only; do not add unrelated symbols)

## Schema requirements

Tables (concrete columns shown — extend with sensible types as needed; primary keys, FKs, timestamps, soft-delete columns where appropriate):

1. **sources** — top-level docs root: `id uuid pk`, `name text not null unique`, `base_url text not null`, `crawler_config jsonb`, `created_at timestamptz default now()`.
2. **source_pages** — one row per crawled URL: `id uuid pk`, `source_id uuid fk sources(id)`, `url text not null unique`, `content_hash text not null` (sha256 of canonical markdown), `markdown text`, `html text`, `crawled_at timestamptz`, `etag text null`.
3. **facts** — atomic facts: `id uuid pk`, `source_page_id uuid fk source_pages(id)`, `kind text not null` (e.g. `model_string`, `price`, `code_block`, `signature`, `callout`), `content text not null`, `anchor text` (URL fragment / DOM anchor for deep-linking), `context text` (the surrounding paragraph for faithfulness eval), `content_hash text not null`, `embedding vector(1024)`, `created_at timestamptz default now()`.
4. **fact_references** — fan-out moat (Phase 1 fills this; Phase 0 just creates the table): `id uuid pk`, `fact_id uuid fk facts(id) on delete cascade`, `notebook_path text not null`, `cell_index int`, `created_at timestamptz default now()`.
5. **drift_events** — re-crawl diffs (Phase 2 uses; create the table now): `id uuid pk`, `fact_id uuid fk facts(id)`, `old_content_hash text`, `new_content_hash text`, `detected_at timestamptz default now()`.
6. **eval_results** — DeepEval output: `id uuid pk`, `fact_id uuid fk facts(id) null`, `metric text not null`, `score float not null`, `passed bool not null`, `details jsonb`, `evaluated_at timestamptz default now()`.

Indexes:

- `CREATE INDEX facts_embedding_diskann ON facts USING diskann (embedding);` — pgvectorscale's `diskann` access method (NOT `ivfflat` or `hnsw`).
- `CREATE INDEX facts_source_page_id ON facts (source_page_id);`
- `CREATE INDEX fact_references_fact_id ON fact_references (fact_id);`
- `CREATE INDEX source_pages_source_id ON source_pages (source_id);`
- `CREATE UNIQUE INDEX source_pages_url ON source_pages (url);` (already enforced via `unique`, but make it explicit if you prefer)

`schema.sql` must:

- Begin with `CREATE EXTENSION IF NOT EXISTS vector;` and `CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;` (the docker image from T-2.2 makes both available; the init.sql there also runs them, but `schema.sql` should be idempotent on its own).
- Use `CREATE TABLE IF NOT EXISTS` so re-application is safe.
- Be runnable via `psql -f schema.sql` against any Postgres-16 + pgvectorscale DB.

## connection.py requirements

- Async-only API. Expose `get_conn() -> AsyncContextManager[psycopg.AsyncConnection]` (or equivalent) that:
  - Reads `DATABASE_URL` from env (fallback to `postgresql://groundtruth:groundtruth@localhost:5432/groundtruth` for local dev).
  - Registers the pgvector type adapter on the connection (`from pgvector.psycopg import register_vector_async; await register_vector_async(conn)`).
  - Returns a fresh connection per call (no pooling — Phase 1 adds pooling).
- Fully type-hinted. No bare `Any`.
- Docstrings on the public function.

## __init__.py requirements

Re-export only the public surface:

```python
from packages.core.kb.connection import get_conn

__all__ = ["get_conn"]
```

## Tests (optional but encouraged for Wave 1)

If you can add a unit test that does NOT require a running DB (e.g. asserts `schema.sql` parses or that `get_conn` returns a coroutine context manager when mocked), put it at `tests/unit/test_kb.py`. **Do not** add a test that requires a live Postgres — that's T-3.1's integration test.

## Acceptance

- [ ] `schema.sql` exists and contains all 6 tables + the `diskann` index.
- [ ] `migrations/0001_initial.sql` exists (can be a copy of `schema.sql` — pattern lock-in for Phase 1+).
- [ ] `connection.py` exposes `get_conn()` per spec.
- [ ] `packages/core/kb/__init__.py` re-exports `get_conn`.
- [ ] `uv run ruff check packages/core/kb/ tests/` passes.
- [ ] `uv run ruff format --check packages/core/kb/ tests/` passes.
- [ ] `uv run pytest -x` still passes (smoke test plus any new unit test).
- [ ] Commit message: `feat(kb): add schema + async connection factory (task: T-2.1)` — body should briefly note the diskann index choice and mention that migrations follow numbered SQL convention.

## Out of scope (do NOT do these — separate tasks)

- Application code beyond `connection.py` (no fact extractor, no crawler, no CLI).
- Live DB integration tests — wait for T-3.1.
- Postgres tuning / config / pgbouncer / connection pooling.
- MCP server.
- Adding new dependencies. (`psycopg[binary]` and `pgvector` are already in `pyproject.toml`.)

## Workflow

1. Read `.claude/plans/plan.md` and the master plan tables you need.
2. Write `schema.sql` first; verify it's syntactically valid (`uv run python -c "import sqlparse; sqlparse.parse(open('packages/core/kb/schema.sql').read())"` if `sqlparse` is available; otherwise just eyeball).
3. Copy to `migrations/0001_initial.sql`.
4. Write `connection.py` and `__init__.py`.
5. Run `uv run ruff format . && uv run ruff check . && uv run pytest -x` (must pass before committing).
6. Commit with the message format above. The post-commit hook auto-pushes to `origin/temp/groundtruth-phase0-T-2.1`.
7. Exit cleanly. If blocked, write the reason to `.claude/plans/logs/T-2.1.BLOCKED.md` and exit.
