# Task T-2.3 — Crawl4AI driver

**Wave:** 1
**Model:** Sonnet 4.6
**Risk:** med
**Effort:** M (1–3h)
**Plan reference:** `.claude/plans/plan.md` §3 T-2.3
**Master plan reference:** `../groundtruth/.claude/plans/master-plan.md` — Crawl4AI 0.8.x is locked, with `AsyncWebCrawler` + `PruningContentFilter` (NOT the LLM extraction strategy — extraction is T-2.4's job).

## Goal

Wrap Crawl4AI 0.8.x in a typed module that takes a base URL (+ a small config) and yields `CrawledPage` records ready for the fact extractor (T-2.4) to consume.

## Allowed file touches (DO NOT touch anything else)

- `packages/core/ingestion/crawler.py` (new)
- `packages/core/ingestion/__init__.py` (re-exports only)
- `tests/unit/test_crawler.py` (new)
- `tests/fixtures/sample_page.html` (new — a small static HTML doc you author yourself, NOT a real crawled page)

## Public API (`crawler.py`)

```python
from collections.abc import AsyncIterator
from dataclasses import dataclass

@dataclass(frozen=True, slots=True)
class CrawledPage:
    url: str
    markdown: str         # the pruned/cleaned markdown
    html: str             # the raw HTML for fallback
    content_hash: str     # sha256 of canonicalized markdown (lowercased, whitespace-collapsed)

@dataclass(frozen=True, slots=True)
class CrawlConfig:
    seed_urls: tuple[str, ...]
    max_pages: int = 50
    pruning_threshold: float = 0.4
    headless: bool = True

async def crawl(config: CrawlConfig) -> AsyncIterator[CrawledPage]: ...
```

Implementation must:

- Use `crawl4ai.AsyncWebCrawler` with `crawl4ai.BrowserConfig(headless=config.headless)`.
- Pass each seed URL through `crawler.arun_many(urls=list(config.seed_urls), config=run_config)` where `run_config` is a `CrawlerRunConfig` configured with `PruningContentFilter(threshold=config.pruning_threshold)` (use the fit_markdown / pruning content filter; if API surface differs in 0.8.x, adapt — Crawl4AI 0.8 stable docs name it `PruningContentFilter` under `crawl4ai.content_filter_strategy`).
- For each successful result, yield `CrawledPage(url=..., markdown=result.markdown.fit_markdown or result.markdown.raw_markdown, html=result.html, content_hash=...)`.
- `content_hash` = `hashlib.sha256(canonicalize(markdown).encode()).hexdigest()` where `canonicalize` lowercases and collapses runs of whitespace to a single space. The hash MUST be stable across runs of the same input markdown — this is the contract the drift detector (Phase 2) depends on.
- Skip results where `success is False` or markdown is empty (log via `logging.getLogger(__name__).warning(...)`, do not raise).

`__init__.py` re-exports only `crawl`, `CrawledPage`, `CrawlConfig`. No more.

## Tests (`tests/unit/test_crawler.py`)

The tests must NOT hit the network. Mock the `AsyncWebCrawler` via `unittest.mock.AsyncMock` (or `pytest-asyncio` patterns) so it returns a synthetic `CrawlResult` whose `markdown.fit_markdown` is the contents of `tests/fixtures/sample_page.html` after a trivial markdown conversion (you can just use the file's text — the test isn't verifying Crawl4AI's HTML→MD logic).

Required test cases:

1. `test_crawl_yields_pages_with_stable_hash` — call `crawl()` twice with the same mocked input; assert `content_hash` matches across runs.
2. `test_crawl_skips_empty_markdown` — mocked result with empty `fit_markdown` is dropped (no yield).
3. `test_crawl_skips_failed_results` — mocked result with `success=False` is dropped.
4. `test_canonicalize_collapses_whitespace` — direct unit on the canonicalize helper (export it from `crawler.py` for test access — `_canonicalize` is fine, prefix-underscore is allowed by the test file).

Use `pytest-asyncio` (already in dev deps; `asyncio_mode = "auto"` is set in `pyproject.toml`, so just write `async def test_...` without decorators).

## sample_page.html requirements

Author a small but realistic HTML doc — NOT a real crawled page. Include:

- One `<h1>`, two `<h2>` sections.
- A `<pre><code>` block with a Python snippet.
- A short paragraph mentioning a model name (e.g. `claude-sonnet-4-6`).
- A pricing-style snippet (e.g. "Input: $3 / MTok").

Keep it under 1.5 KB. This file is also useful for T-2.4's fixtures so make it clean and self-contained.

## Acceptance

- [ ] `crawler.py` exposes the API above with full type hints.
- [ ] `__init__.py` re-exports only `crawl`, `CrawledPage`, `CrawlConfig`.
- [ ] `tests/unit/test_crawler.py` passes offline with mocks (no network calls).
- [ ] `content_hash` is byte-identical across two runs of the same input (asserted in test 1).
- [ ] `sample_page.html` exists at `tests/fixtures/sample_page.html`.
- [ ] `uv run ruff check packages/core/ingestion/ tests/` passes (no warnings).
- [ ] `uv run ruff format --check packages/core/ingestion/ tests/` passes.
- [ ] `uv run pytest -x packages tests/unit/test_crawler.py` passes.
- [ ] Commit message: `feat(ingestion): add Crawl4AI driver with stable content hashing (task: T-2.3)` — body should mention the canonicalization rule and the stability contract for drift detection.

## Out of scope

- Adaptive crawling (`AdaptiveCrawler.digest`) — Phase 1.
- JS-heavy sites with custom Playwright config — Phase 1+.
- Crawl4AI's `LLMExtractionStrategy` — we have our own extractor in T-2.4.
- Persisting `CrawledPage` to DB — T-3.1 wires this up.
- Live integration tests — T-3.1 owns those.
- Adding new dependencies (`crawl4ai>=0.8.0` is already in `pyproject.toml`).

## Workflow

1. Read Crawl4AI 0.8 quick reference if needed (the API surface is stable — `AsyncWebCrawler`, `arun_many`, `CrawlerRunConfig`, `BrowserConfig`, `PruningContentFilter`).
2. Write the canonicalize helper + dataclasses first (these are pure-Python; easy to test).
3. Wire up `crawl()`.
4. Write tests with `AsyncMock`.
5. `uv run ruff format . && uv run ruff check . && uv run pytest -x`.
6. Commit with the message format above. Post-commit hook auto-pushes.
7. Exit. If blocked (e.g., Crawl4AI's API differs from documented), write `.claude/plans/logs/T-2.3.BLOCKED.md` with the specific import errors / API mismatches and exit.
