# Groundtruth Phase 0 — Substrate Execution Plan

**Status:** Ready to launch
**Worktree:** `/Users/derekb137/src/github/groundtruth-groundtruth-phase0`
**Branch:** `chore/groundtruth-phase0`
**Base:** `origin/develop @ 52ae77bfb`
**Driver:** Opus 4.7 orchestrator + mixed Opus 4.7 / Sonnet 4.6 workstreams
**Mode:** Autonomous (`--dangerously-skip-permissions`)
**PR strategy:** wave-grouped (one PR per wave, merged to `develop` before next wave starts)

**Phase goal:** ingest one URL, persist atomic facts with provenance to Postgres + pgvector, query them via embedding similarity. CLI-only. No notebook generation in this phase. Master plan at `../groundtruth/.claude/plans/master-plan.md`.

---

## 1. Items in scope (5)

| ID | Item | Wave | Effort | Model | Risk | Touches |
|---|---|---|---|---|---|---|
| T-2.1 | DB schema — pgvectorscale `diskann` index on `vector(1024)` for voyage-4-large; `fact_references` table | 2 | M | sonnet | low | `packages/core/kb/schema.sql`, `packages/core/kb/migrations/`, `packages/core/kb/connection.py`, `packages/core/kb/__init__.py` |
| T-2.2 | docker-compose + custom Dockerfile (`pgvector/pgvector:pg16-trixie` + apt `postgresql-16-pgvectorscale`); `init.sql` runs `CREATE EXTENSION vectorscale CASCADE` | 2 | S | sonnet | low | `docker-compose.yml`, `docker/Dockerfile.postgres`, `scripts/db/init.sql`, `scripts/db/seed.sh`, `scripts/db/reset.sh` |
| T-2.3 | Crawl4AI driver (`AsyncWebCrawler` + `arun_many` + `PruningContentFilter`) | 2 | M | sonnet | med | `packages/core/ingestion/crawler.py`, `packages/core/ingestion/__init__.py`, `tests/unit/test_crawler.py`, `tests/fixtures/sample_page.html` |
| T-2.4 | Fact extractor + DeepEval `FaithfulnessMetric` gate (threshold 0.85); Haiku 4.5 for batch extraction | 2 | L | opus | high | `packages/core/facts/extractor.py`, `packages/core/facts/types.py`, `packages/core/facts/__init__.py`, `packages/shared/eval/faithfulness.py`, `tests/unit/test_extractor.py`, `tests/evals/extractor/` |
| T-3.1 | End-to-end CLI — `crawl.py` + `query.py` against `docs.claude.com/en/docs/build-with-claude/overview` | 3 | M | sonnet | med | `scripts/crawl.py`, `scripts/query.py`, `packages/core/__init__.py`, `tests/integration/test_substrate.py` |

**Effort key:** S = ≤1h, M = 1–3h, L = 3+h
**Risk key:** low / med / high (orchestrator routes high-risk to Opus + extra retries)
**Touches:** every file the task is allowed to modify. Disjoint `Touches` within a wave = parallel-safe.

---

## 2. Wave grouping

```
Wave 2 (4 parallel) → PR A
  T-2.1 (kb)  ‖  T-2.2 (docker)  ‖  T-2.3 (crawler)  ‖  T-2.4 (extractor)
       ↓
Wave 3 (1 task) → PR B
  T-3.1 (end-to-end CLI)
```

**Parallel safety verified:** all four Wave-2 tasks have disjoint `Touches` — no shared `__init__.py`, no shared schema files. Wave 3 imports from all four Wave-2 modules; runs sequentially after Wave 2 PR merges.

---

## 3. Per-task specs

### T-2.1: DB schema + migrations
- **Goal:** SQL schema implementing the master plan's tables (`sources`, `source_pages`, `facts`, `fact_references`, `drift_events`, `eval_results`) with `diskann` index on `facts.embedding vector(1024)`.
- **Approach:** Single `schema.sql` plus a migrations folder convention (timestamped `.sql` files); a `connection.py` exposing an async `psycopg.AsyncConnection` factory; `__init__.py` re-exports.
- **Acceptance:** `psql -f schema.sql` against an empty Postgres+pgvectorscale DB succeeds; `SELECT * FROM pg_indexes WHERE indexname LIKE '%diskann%'` returns the `facts.embedding` index; `connection.py`'s `get_conn()` test passes against the docker-composed DB from T-2.2.
- **Out of scope:** application code, fact extraction logic, MCP server.

### T-2.2: docker-compose + Postgres image
- **Goal:** one-command local DB stack — `docker compose up -d` brings up Postgres 16 with pgvector 0.8.2 + pgvectorscale 0.9.0 ready to accept connections.
- **Approach:** `docker/Dockerfile.postgres` extends `pgvector/pgvector:pg16-trixie` with `RUN apt-get install -y postgresql-16-pgvectorscale`; `docker-compose.yml` builds it, mounts `scripts/db/init.sql`, exposes 5432, uses `${PROJECT_NAME}` env interpolation; `init.sql` creates the DB + runs `CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE`.
- **Acceptance:** `docker compose up -d && docker compose exec postgres psql -U groundtruth -c "\dx"` lists both `vector` and `vectorscale` extensions; T-2.1's `schema.sql` applies cleanly.
- **Out of scope:** Postgres tuning, replication, anything HA.

### T-2.3: Crawl4AI driver
- **Goal:** wrap Crawl4AI 0.8.x in a typed module that takes a base URL + crawl config and yields `(url, markdown, html, content_hash)` tuples ready for fact extraction.
- **Approach:** `crawler.py` defines `async def crawl(source: Source) -> AsyncIterator[CrawledPage]`; uses `AsyncWebCrawler` with `BrowserConfig(headless=True)` and `PruningContentFilter(threshold=0.4)`; supports `arun_many` for the seed-list mode.
- **Acceptance:** `pytest tests/unit/test_crawler.py` passes against the recorded `tests/fixtures/sample_page.html` fixture; `content_hash` is stable across runs (sha256 of the canonicalized markdown).
- **Out of scope:** adaptive crawling (Phase 1+), JS-heavy sites that need custom Playwright config, Crawl4AI's LLM extraction strategy (we use our own extractor in T-2.4).

### T-2.4: Fact extractor with faithfulness gate
- **Goal:** given a `CrawledPage`, return a list of `Fact` objects (kind, content, anchor, context, content_hash) with each fact passing `FaithfulnessMetric ≥ 0.85` against its source paragraph.
- **Approach:** Haiku 4.5 prompt for batch extraction (model strings, prices, code blocks, signatures, callouts); `Fact` dataclass in `types.py`; faithfulness eval in `packages/shared/eval/faithfulness.py` wrapping DeepEval's `LLMTestCase` + `FaithfulnessMetric(threshold=0.85)`; `tests/evals/extractor/` ships a curated 50-paragraph fixture with expected facts.
- **Acceptance:** unit tests pass; eval suite runs with average faithfulness ≥0.85 across the 50-paragraph fixture; failing facts dropped from output (logged, not raised — fail-soft at extraction, fail-hard at write).
- **Out of scope:** image fact extraction (Phase 1+), embedding generation (folded into T-3.1's persist step), drift detection, `fact_references` recording (Phase 1).

### T-3.1: End-to-end CLI
- **Goal:** prove the substrate by ingesting `https://docs.claude.com/en/docs/build-with-claude/overview` end-to-end. `python scripts/crawl.py <URL>` writes to DB; `python scripts/query.py "<text>"` returns top-k facts.
- **Approach:** `crawl.py` orchestrates T-2.3 → T-2.4 → embed via Voyage `voyage-4-large` → upsert to Postgres; `query.py` embeds the query, runs `<=>` vector cosine search via pgvectorscale `diskann`, returns rows with provenance URLs; `__init__.py` updates re-export the public API.
- **Acceptance:** `tests/integration/test_substrate.py` (marked `@pytest.mark.integration`) runs against the docker-composed DB, ingests one page, asserts ≥10 facts persisted, runs a known-good query, asserts top result is provenance-traceable.
- **Out of scope:** drift detection, MCP server, course/notebook generation, multi-page crawl scheduling.

---

## 4. Verification gates

Per-task (sub-worktree) — override at `scripts/parallel/verify-gate.sh` if needed:
```sh
uv run ruff format --check .
uv run ruff check .
uv run pytest -x --tb=short
```

Per-wave (after cherry-pick to `chore/groundtruth-phase0`):
```sh
uv run ruff format --check .
uv run ruff check .
uv run pytest --tb=short        # full suite
uv run mypy packages/           # NB: mypy targets packages/, not src/
```

`mypy` may be added in a follow-up if it's noisy on the bootstrap; for Wave 2 the priority is ruff+pytest green. All must pass to accept; otherwise retry the task with tighter spec, max 3 attempts.

---

## 5. PR plan

- **PR A** (Wave 2): `chore/groundtruth-phase0` after Wave 2 cherry-picks → `develop`. Title: `feat(substrate): Wave 2 — DB schema, docker, crawler, fact extractor`.
- **PR B** (Wave 3): same branch, additional commits → `develop`. Title: `feat(substrate): Wave 3 — end-to-end crawl + query CLIs`.
- Open PRs sequentially. Human reviews + merges between PRs. Orchestrator does NOT auto-merge.
- After PR B merges, Phase 0 ships. Tag `v0.0.1` optional. Then `groundtruth-phase1` slug starts.

---

## 6. Orchestration protocol (codified)

**Autonomous mode:** orchestrator proceeds wave→wave without check-ins. Stops only on:
- 3 consecutive failed retries on a single task
- Rate-limit halt (`ScheduleWakeup` to resume in 1800s)
- Spec ambiguity that would cause information loss
- T-2.4 faithfulness eval running below 0.5 average (signals systemic extraction breakage, not a tunable threshold issue)

**Model routing:**
- T-2.4 (high risk + design-heavy): Opus 4.7
- All others (low/med risk): Sonnet 4.6
- Inner Haiku 4.5 calls within T-2.4 are fine (batch extraction); orchestrator does not need Haiku as a workstream model

**Skill triggering:** sub-agents may consult `../groundtruth/skills/{docs-crawler,fact-extractor}/SKILL.md` if those land mid-phase, but Phase 0 doesn't author skills (that's Wave 4). For now, treat the four skill directories as placeholders.

User can monitor via `.claude/plans/progress.md`. User can inject feedback by editing `.claude/plans/USER_NOTES.md` — orchestrator reads it before each new wave.

---

## 7. Done criteria

- [ ] T-2.1 → T-2.4 all merged via PR A
- [ ] T-3.1 merged via PR B
- [ ] Phase 0 acceptance: `python scripts/crawl.py <url>` + `python scripts/query.py "..."` returns provenance-traceable facts against a real `docs.claude.com` page
- [ ] T-2.4 faithfulness eval ≥0.85 average on the 50-paragraph fixture
- [ ] `pytest` green (full suite, including integration mark gated behind running Postgres)
- [ ] `ruff check .` clean, format clean
- [ ] No new TODO/FIXME comments without linked issues
- [ ] `.claude/plans/progress.md` updated with per-task summaries + any followups
