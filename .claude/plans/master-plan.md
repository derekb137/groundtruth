# groundtruth — master execution plan

**Status:** Wave 1 complete (this scaffold). Ready for Wave 2.
**Last updated:** 2026-05-06
**Source-of-truth versions captured at plan time** — re-verify before each phase ships.

## Thesis (locked)

Drift-aware executable notebooks. Open source. Powered by a fact graph.
Crawl docs → extract atomic facts with provenance → generate notebooks → re-crawl → regenerate only the notebooks that depend on changed facts → Papermill validates they still run.

## Audiences (locked)

1. Anthropic role (primary)
2. OSS portfolio (secondary)

Distru dropped — notebook output type doesn't fit Distru ops.

## Cut list (locked, no debate)

Hyperframes / video / FFmpeg, ElevenLabs / Inworld / narration, slide / quiz / course-packager, cmi5 / SCORM, Argo / Cloud Run / GCS, codedocs sister, 12 of the original 16 skills.

## Keep list (locked)

Postgres + pgvector + pgvectorscale, `fact_references` (the moat), Crawl4AI, Voyage-4-large, Agent SDK orchestration, MCP server (deferred to Phase 2), DeepEval `FaithfulnessMetric` at threshold 0.85 (used at fact extraction AND notebook generation), Papermill, four skills only: `docs-crawler`, `fact-extractor`, `notebook-author`, `notebook-validator`.

## Locked stack

| Component | Version / pick | Notes |
|---|---|---|
| Postgres | 16 | image: `pgvector/pgvector:pg16-trixie` |
| pgvector | 0.8.2 | bundled in image |
| pgvectorscale | 0.9.0 | added via `apt install postgresql-16-pgvectorscale` in custom Dockerfile |
| Embeddings | `voyage-4-large` | 1024 dim, 32k ctx, $0.12/Mtok, 200M free |
| Crawl4AI | 0.8.x | `AsyncWebCrawler` + `AdaptiveCrawler.digest()` + `PruningContentFilter` |
| Agent SDK | `claude-agent-sdk` ≥0.1.75 | `ClaudeSDKClient` + `AgentDefinition` + `@tool` + `create_sdk_mcp_server` |
| MCP | official `mcp` SDK (FastMCP built-in) | `from mcp.server.fastmcp import FastMCP`; stdio default, `streamable-http` flag for Phase 3 |
| Models | Opus 4.7 (design-heavy only), Sonnet 4.6 (default), Haiku 4.5 (high-volume narrow) | per Anthropic guidance: Sonnet=default |
| Notebook exec | Papermill | catches `PapermillExecutionError`; reads partial output from disk on failure |
| Eval | DeepEval `FaithfulnessMetric` | threshold 0.85 (project-specific, stricter than 0.7 default example) |
| Prompt caching | `cache_control={"type":"ephemeral"}` top-level | 5-min TTL default; 90% discount on reads |

## Phase → wave mapping

| Phase | Waves | Slug | Acceptance |
|---|---|---|---|
| 0 — Substrate | 1, 2, 3 | `groundtruth-phase0` | `crawl.py URL` + `query.py "..."` returns provenance-traceable facts; faithfulness ≥0.85 on extracted facts |
| 1 — Notebook factory | 4, 5 | `groundtruth-phase1` | 3 notebooks generated against shared fact set; all Papermill-green; `fact_references` fan-out populated; faithfulness ≥0.85 on each |
| 2 — Drift + MCP | 6, 7 | `groundtruth-phase2` | Mutate one fact → only N affected notebooks regenerate (N from `fact_references`), nothing else; MCP server answers `find_references(fact_id)` |

PR train: one PR per wave merging to `develop`. Phase ships when its last wave merges. Tag `v0.1.0` after Phase 2.

---

## Wave 1 — Foundation (DONE — this commit)

| ID | Title | Touches | Status |
|---|---|---|---|
| T-1.1 | Repo bootstrap | `pyproject.toml`, `ruff.toml`, `.pre-commit-config.yaml`, `.gitignore`, `.env.example`, `README.md`, package + skill + test directory tree, parallel toolkit copy | ✅ |

## Wave 2 — Substrate fan-out (4 parallel)

| ID | Title | Touches | Effort | Risk | Model |
|---|---|---|---|---|---|
| T-2.1 | DB schema (`diskann` index on `vector(1024)` for voyage-4-large; `fact_references` table) | `packages/core/kb/schema.sql`, `packages/core/kb/migrations/`, `packages/core/kb/connection.py`, `packages/core/kb/__init__.py` | M | low | sonnet |
| T-2.2 | docker-compose with custom `pgvector/pgvector:pg16-trixie` + pgvectorscale Dockerfile; `init.sql` runs `CREATE EXTENSION vectorscale CASCADE` | `docker-compose.yml`, `docker/Dockerfile.postgres`, `scripts/db/init.sql`, `scripts/db/seed.sh`, `scripts/db/reset.sh` | S | low | sonnet |
| T-2.3 | Crawl4AI driver (`AsyncWebCrawler` + `arun_many` + `PruningContentFilter`) | `packages/core/ingestion/crawler.py`, `packages/core/ingestion/__init__.py`, `tests/unit/test_crawler.py`, `tests/fixtures/sample_page.html` | M | med | sonnet |
| T-2.4 | Fact extractor + DeepEval faithfulness gate (threshold 0.85); Haiku 4.5 for batch extraction | `packages/core/facts/extractor.py`, `packages/core/facts/types.py`, `packages/core/facts/__init__.py`, `packages/shared/eval/faithfulness.py`, `tests/unit/test_extractor.py`, `tests/evals/extractor/` | L | high | opus |

## Wave 3 — Substrate integration (1 task)

| ID | Title | Touches | Effort | Risk | Model |
|---|---|---|---|---|---|
| T-3.1 | `scripts/crawl.py` + `scripts/query.py` end-to-end against `docs.claude.com/en/docs/build-with-claude/overview` | `scripts/crawl.py`, `scripts/query.py`, `packages/core/__init__.py`, `tests/integration/test_substrate.py` | M | med | sonnet |

**Phase 0 ships here.**

## Wave 4 — Notebook factory fan-out (4 parallel)

| ID | Title | Touches | Effort | Risk | Model |
|---|---|---|---|---|---|
| T-4.1 | `notebook-author` Skill (third-person description, ≤500-line SKILL.md, references one level deep) + author module | `skills/notebook-author/SKILL.md`, `skills/notebook-author/references/`, `packages/courses/notebook/author.py`, `tests/unit/test_notebook_author.py` | L | high | opus |
| T-4.2 | `notebook-validator` Skill — Papermill executes, captures `PapermillExecutionError`, reads partial output `.ipynb` from disk on failure for repair-loop context (max 3 attempts); DeepEval faithfulness on prose | `skills/notebook-validator/SKILL.md`, `packages/courses/notebook/validator.py`, `tests/unit/test_notebook_validator.py`, `tests/evals/notebook/` | M | med | sonnet |
| T-4.3 | `kb.with_provenance()` context manager — every fact access during generation auto-records to `fact_references`; property test asserts no orphan references | `packages/core/kb/provenance.py`, `packages/core/kb/references.py`, `tests/unit/test_provenance.py`, `tests/property/test_no_orphan_refs.py` | M | high | opus |
| T-4.4 | Package `docs-crawler` + `fact-extractor` as Skills (third-person descriptions, trigger-keyword tuned) | `skills/docs-crawler/SKILL.md`, `skills/docs-crawler/references/`, `skills/fact-extractor/SKILL.md`, `skills/fact-extractor/references/` | M | low | sonnet |

## Wave 5 — Notebook factory integration (1 task)

| ID | Title | Touches | Effort | Risk | Model |
|---|---|---|---|---|---|
| T-5.1 | Build coordinator using `ClaudeSDKClient` + `AgentDefinition` subagents; prompt caching on shared fact corpus; generates 3 notebooks: tool-use, structured-outputs, prompt-caching | `packages/courses/build.py`, `scripts/build_notebooks.py`, `packages/core/kb/__init__.py` (export updates), `notebooks/` (output, gitignored), `tests/integration/test_notebook_build.py` | L | high | opus |

**Phase 1 ships here.**

## Wave 6 — Drift + MCP fan-out (3 parallel)

| ID | Title | Touches | Effort | Risk | Model |
|---|---|---|---|---|---|
| T-6.1 | Drift detector (re-crawl + `content_hash` diff per fact) | `packages/core/drift/detector.py`, `packages/core/drift/__init__.py`, `tests/unit/test_drift_detector.py` | M | med | sonnet |
| T-6.2 | Change propagator + regen coordinator (uses `fact_references` for fan-out; regenerates only affected notebooks) | `packages/core/drift/propagator.py`, `packages/core/drift/coordinator.py`, `tests/unit/test_propagator.py` | M | high | opus |
| T-6.3 | MCP server (`from mcp.server.fastmcp import FastMCP`, `--transport stdio\|streamable-http` flag) exposing `query_facts`, `find_references`, `get_fact_history` | `packages/core/mcp_server/server.py`, `packages/core/mcp_server/tools.py`, `packages/core/mcp_server/__init__.py`, `tests/unit/test_mcp_tools.py` | M | low | sonnet |

## Wave 7 — Drift demo (1 task)

| ID | Title | Touches | Effort | Risk | Model |
|---|---|---|---|---|---|
| T-7.1 | `scripts/drift_demo.py` mutates fact in fixture, asserts only-affected regen, README hero + asciinema demo | `scripts/drift_demo.py`, `tests/integration/test_drift_demo.py`, `README.md`, `docs/DEMO.md` | M | med | opus |

**Phase 2 ships here. Tag `v0.1.0`. Demo lands.**

---

## Critical-path serialization

```
Wave 1 ✅ (this commit)
   ↓
Wave 2 (T-2.1 ‖ T-2.2 ‖ T-2.3 ‖ T-2.4)
   ↓
Wave 3 (T-3.1)            ← Phase 0 ships
   ↓
Wave 4 (T-4.1 ‖ T-4.2 ‖ T-4.3 ‖ T-4.4)
   ↓
Wave 5 (T-5.1)            ← Phase 1 ships
   ↓
Wave 6 (T-6.1 ‖ T-6.2 ‖ T-6.3)
   ↓
Wave 7 (T-7.1)            ← Phase 2 ships
```

## Risk register

1. **Fact extractor faithfulness <0.85.** Likeliest blocker. T-2.4 ships with curated 50-paragraph eval set; if gate fails, ship Phase 0 with eval set as known-failing benchmark and iterate in side branch — don't block Wave 3.
2. **`fact_references` recording incomplete.** Silent fan-out misses. T-4.3 ships property-based test asserting every fact mentioned in generated content has corresponding `fact_references` row.
3. **Papermill timeouts on real Anthropic API calls.** Cassette-based mocking via `vcr.py` in T-4.2; real-API runs gated behind CI flag.
4. **Crawl4AI Playwright friction.** docker-composed crawler in Phase 3 if needed; Phase 0–2 runs locally.
5. **MCP SDK lags spec.** Python SDK on 2025-06-18, current stable spec is 2025-11-25. Read-only fact-graph use case doesn't need the new primitives. Re-evaluate at Phase 3.

## Locked decisions (no further debate)

- Single hardcoded name in `pyproject.toml`; everything else via `importlib.metadata` or `${PROJECT_NAME}`
- Skills are filesystem-based Claude Code skills (no API beta headers); API packaging deferred
- DeepEval threshold 0.85 (one metric: faithfulness)
- Papermill: fail loudly, no `allow_errors=True`
- Repo language: Python end-to-end. No Node, no React, no FFmpeg
- Local-first. No cloud deploy in Phase 0–2
- Three notebook topics for T-5.1: `tool-use`, `structured-outputs`, `prompt-caching`

## Next action

`/parallel-start groundtruth-phase0` — drops a worktree at `../groundtruth-groundtruth-phase0/`. Fill its `.claude/plans/plan.md` with Wave 2 + 3 task table from above. `./launch.sh` runs the orchestrator.

**Prereq:** `origin/develop` must exist on a remote (GitHub). The `init-worktree.sh` script branches off `origin/develop` and `git push -u`s the new branch.
