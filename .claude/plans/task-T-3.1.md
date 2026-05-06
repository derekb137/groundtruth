# Task T-3.1 — End-to-end CLI (crawl + query)

**Wave:** 2
**Model:** Sonnet 4.6
**Risk:** med
**Effort:** M (1–3h)
**Plan reference:** `.claude/plans/plan.md` §3 T-3.1
**Master plan reference:** `../groundtruth/.claude/plans/master-plan.md` — Voyage `voyage-4-large` (1024 dims), pgvectorscale `<=>` cosine search

## Goal

Prove the substrate end-to-end. `python scripts/crawl.py <URL>` ingests a page through Wave-1's pipeline (crawler → fact extractor → embed → upsert). `python scripts/query.py "<text>"` embeds the query and returns top-k facts via pgvectorscale cosine search with provenance URLs.

## Allowed file touches (DO NOT touch anything else)

- `scripts/crawl.py` (new)
- `scripts/query.py` (new)
- `packages/core/__init__.py` (re-export the public API the CLIs depend on)
- `tests/integration/test_substrate.py` (new — gated on `@pytest.mark.integration`)

You may NOT edit any Wave-1 file (`packages/core/{kb,ingestion,facts}/**`, `packages/shared/eval/**`). Treat them as fixed contracts. If you find a defect that prevents you from finishing, write `.claude/plans/logs/T-3.1.BLOCKED.md` describing the fix needed and exit — the orchestrator will queue a follow-up.

## crawl.py requirements

```sh
$ python scripts/crawl.py https://docs.claude.com/en/docs/build-with-claude/overview
[crawl.py] crawling 1 URL...
[crawl.py] page 1: <url> (47 facts kept / 50 candidates)
[crawl.py] embedded 47 facts via voyage-4-large
[crawl.py] upserted to facts table
done.
```

Implementation outline:

1. Parse args via `argparse`: positional `url` (required), optional `--source-name` (default: derived from URL host).
2. Build a `CrawlConfig(seed_urls=(url,), max_pages=1)` and call `crawl()` from `packages.core.ingestion`.
3. For each `CrawledPage`, call `extract_facts()` from `packages.core.facts`.
4. Embed each fact's `content` via Voyage. Use `voyageai.AsyncClient()` and `await client.embed(texts=[fact.content for fact in facts], model="voyage-4-large", input_type="document")`. Batch all facts in one call. The result is `embeddings.embeddings` (list[list[float]]).
5. Persist:
   - Upsert `sources` row (`name`, `base_url`).
   - Upsert `source_pages` row (`source_id`, `url`, `content_hash`, `markdown`, `html`, `crawled_at=now()`).
   - Insert facts: `INSERT INTO facts (source_page_id, kind, content, anchor, context, content_hash, embedding) VALUES (...)` — one row per fact.
   - Use `ON CONFLICT (content_hash) DO NOTHING` if you add a unique constraint on facts.content_hash; otherwise just insert. Phase 0 doesn't need re-ingestion logic.
6. Use `packages.core.kb.get_conn()` for the connection.
7. Async throughout. Use `asyncio.run(main())`.
8. Read `VOYAGE_API_KEY` and `ANTHROPIC_API_KEY` from env; `python-dotenv` (already a dep) loads `.env` if present.
9. Print short progress lines (per the format above). No noisy logs by default.

## query.py requirements

```sh
$ python scripts/query.py "what model should I use for high-volume narrow tasks?" --top-k 5
[query.py] embedding query...
[query.py] top 5 facts:
  1. (callout, 0.823) "Use Haiku 4.5 for high-volume narrow tasks." → https://docs.claude.com/en/docs/...
  2. (model_string, 0.787) "claude-haiku-4-5-20251001" → https://docs.claude.com/en/docs/...
  3. ...
```

Implementation outline:

1. Parse args: positional `query_text` (required), optional `--top-k` (default 10), `--source-name`.
2. Embed the query via Voyage with `input_type="query"` (different from documents — this is required by Voyage embedding contracts).
3. Run `SELECT id, kind, content, anchor, context, source_pages.url, 1 - (embedding <=> $1::vector) AS similarity FROM facts JOIN source_pages ON facts.source_page_id = source_pages.id ORDER BY embedding <=> $1::vector LIMIT $2;` against the DB. The `<=>` is cosine distance; pgvectorscale's `diskann` index accelerates this.
4. Print top-k with similarity, kind, content, and provenance URL (per the format above).
5. Same env-loading + connection pattern as `crawl.py`.

## packages/core/__init__.py

Re-export the public API for downstream callers:

```python
from packages.core.facts import Fact, extract_facts
from packages.core.ingestion import CrawledPage, CrawlConfig, crawl
from packages.core.kb import get_conn

__all__ = [
    "CrawlConfig",
    "CrawledPage",
    "Fact",
    "crawl",
    "extract_facts",
    "get_conn",
]
```

## Integration test (`tests/integration/test_substrate.py`)

Gated on `@pytest.mark.integration` (the marker is registered in `pyproject.toml`). The test:

1. Skips with `pytest.skip("requires running Postgres")` if `pg_isready` against `DATABASE_URL` host fails.
2. Skips with `pytest.skip("requires VOYAGE_API_KEY + ANTHROPIC_API_KEY")` if either env var is unset.
3. Runs `subprocess.run(["python", "scripts/crawl.py", "https://docs.claude.com/en/docs/build-with-claude/overview"])` (or imports + calls `main()` directly — your choice; subprocess is more end-to-end).
4. Asserts ≥10 facts persisted: `SELECT COUNT(*) FROM facts WHERE source_page_id = ?` ≥ 10.
5. Runs `query.py` (or imports the query function) with a known-good query (e.g. "what is the recommended model for fast narrow tasks") and asserts the top result's `source_pages.url` matches the ingested URL.
6. Cleans up: `DELETE FROM facts WHERE source_page_id = ?; DELETE FROM source_pages WHERE id = ?; DELETE FROM sources WHERE id = ?;` in a finally block.

This test is OPTIONAL to actually run — if Postgres isn't available locally, the test should skip gracefully. Standard `pytest -x` should NOT trigger it (it's `@pytest.mark.integration`).

## Acceptance

- [ ] `scripts/crawl.py` runs and ingests a page (smoke-tested by the integration test or manually).
- [ ] `scripts/query.py` returns top-k facts with provenance URLs.
- [ ] `packages/core/__init__.py` re-exports the documented public API.
- [ ] `tests/integration/test_substrate.py` exists, is marked `@pytest.mark.integration`, and skips cleanly when DB or API keys are absent.
- [ ] `uv run ruff check . && uv run ruff format --check .` passes.
- [ ] `uv run pytest -x` passes (integration test does NOT run by default; only unit tests run).
- [ ] `uv run pytest -x -m integration` passes IF Postgres is available locally (not a hard requirement for landing).
- [ ] Commit message: `feat(cli): end-to-end crawl + query against pgvectorscale (task: T-3.1)` — body should mention the Voyage embedding model + dim count, the cosine `<=>` operator, and the integration-test skip strategy.

## Out of scope

- Drift detection (Phase 2).
- MCP server (Phase 2).
- Multi-page crawl scheduling.
- Course/notebook generation (Phase 1).
- Adding new dependencies (`voyageai`, `anthropic`, `psycopg`, `python-dotenv` all present).

## Workflow

1. Verify Wave-1 surfaces: `from packages.core.ingestion import crawl, CrawlConfig, CrawledPage`, `from packages.core.facts import extract_facts, Fact`, `from packages.core.kb import get_conn`. If any import fails, write `T-3.1.BLOCKED.md` and exit.
2. Write `crawl.py` end-to-end. Wire each step. Use small functions.
3. Write `query.py`.
4. Write `packages/core/__init__.py` re-exports.
5. Write the integration test with skip guards.
6. `uv run ruff format . && uv run ruff check . && uv run pytest -x` (must pass — integration test should skip cleanly when DB is absent).
7. Commit with the message format above. Post-commit hook auto-pushes.
8. Exit cleanly. If blocked, write `.claude/plans/logs/T-3.1.BLOCKED.md` and exit.

## Notes for the agent

- Voyage's `embed()` returns an `EmbedResult` with `.embeddings: list[list[float]]`. Be sure to use `input_type="document"` when ingesting and `input_type="query"` when querying — Voyage's docs are explicit that this materially affects retrieval quality.
- pgvector's psycopg adapter expects `numpy.ndarray` or list-of-floats; make sure `register_vector_async` is called on each connection (T-2.1's `get_conn()` already does this).
- For the `<=>` cosine distance operator, lower is more similar; for similarity-as-percentage, use `1 - distance`.
