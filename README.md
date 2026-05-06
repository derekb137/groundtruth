# groundtruth

> Drift-aware executable notebooks. Open source. Powered by a fact graph.

Point it at a documentation site (today: `docs.claude.com`). It crawls, extracts atomic facts with provenance, generates executable Cookbook-style notebooks, and validates them with Papermill. When the docs change, only the notebooks that depend on the changed facts regenerate — and they prove they still run.

```
docs site ──▶ facts (with provenance) ──▶ notebooks
                    ▲                         │
                    └──── drift detector ◀────┘
                              │
                              ▼
                         MCP server
                  (any agent can query)
```

## Status

Phase 0 — substrate. Not yet usable. See [`.claude/plans/master-plan.md`](.claude/plans/master-plan.md) for the locked 7-wave execution plan.

## Stack

- **Postgres 16 + pgvector 0.8.2 + pgvectorscale 0.9.0** — single source of truth, `diskann` index for vector search
- **Crawl4AI 0.8.x** — adaptive crawling, headless Playwright
- **Voyage AI `voyage-4-large`** — 1024-dim embeddings, 32k context
- **Claude Agent SDK** (`claude-agent-sdk` ≥0.1.75) — orchestrator with `AgentDefinition` subagents
- **MCP Python SDK** (FastMCP) — exposes the fact graph to any agent (stdio local, HTTP-ready)
- **Papermill** — executes every notebook; failures fail the build
- **DeepEval `FaithfulnessMetric`** — gates fact extraction and notebook prose at threshold 0.85

## Local dev

```sh
uv sync
docker compose up -d                        # Postgres + pgvectorscale
cp .env.example .env                        # add ANTHROPIC_API_KEY + VOYAGE_API_KEY
uv run python scripts/crawl.py https://docs.claude.com/en/docs/build-with-claude/overview
uv run python scripts/query.py "claude opus pricing"
```

## Renaming

Single hardcoded location: `[project] name` in `pyproject.toml`. Everywhere else reads via `importlib.metadata` or `${PROJECT_NAME}` env interpolation. To rename:

```sh
sed -i '' 's/^name = "groundtruth"/name = "newname"/' pyproject.toml
uv sync && export PROJECT_NAME=newname && docker compose down && docker compose up -d
```

## License

MIT.
