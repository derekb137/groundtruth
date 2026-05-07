# Task T-4.4 — Package `docs-crawler` + `fact-extractor` as Skills

**Wave:** 1 (= master-plan Wave 4)
**Model:** Sonnet 4.6
**Risk:** low
**Effort:** M (1–3h)
**Plan reference:** `.claude/plans/plan.md` §3 T-4.4
**Master plan reference:** `../groundtruth/.claude/plans/master-plan.md` (locked decision: filesystem-based Claude Code skills, NOT API-beta-header skills; four total skills in this codebase)

## Goal

Wrap two existing Phase-0 modules as filesystem Claude Code Skills with third-person trigger descriptions, ≥3 trigger keywords each, and one-level-deep references/.

This is a **packaging task** — NO new Python code. The actual implementations (`packages.core.ingestion.crawl`, `packages.core.facts.extract_facts`) are already merged on `develop`. Your job is to make these capabilities discoverable to downstream agents via the SKILL.md trigger surface.

## Allowed file touches (DO NOT touch anything else)

- `skills/docs-crawler/SKILL.md` (new)
- `skills/docs-crawler/references/*.md` (new — at least 1 file, 1-level-deep)
- `skills/fact-extractor/SKILL.md` (new)
- `skills/fact-extractor/references/*.md` (new — at least 1 file, 1-level-deep)

**No Python.** No tests. No edits to `packages/`. If you find yourself wanting to modify the underlying modules, stop — that's a separate task.

## SKILL.md format (both skills)

Frontmatter (YAML, must parse with PyYAML):

```yaml
---
name: <skill-name>
description: <third-person trigger description, 1–3 sentences, leads with the verb the user would say>
---
```

Body (markdown, ≤500 lines, but realistically ≤200 for these wrapper skills):

1. **When to use** — third-person, leading with the verb. ("This skill crawls documentation sites...")
2. **Trigger keywords** — ≥3 explicit phrases the description should pattern-match against.
3. **Inputs** — what the user / outer agent provides.
4. **Outputs** — what shape comes back.
5. **How it wraps** — point to `packages.core.ingestion.crawl` (or `extract_facts`) with a short usage example.
6. **Pointer to references/** — one-level-deep usage patterns.

## docs-crawler SKILL.md

Frontmatter description (verbatim shape — adapt wording):

> This skill crawls documentation sites and yields cleaned markdown + content hashes for each page. Use when the user asks to "crawl docs", "ingest a documentation URL", "scrape docs site", or otherwise needs to convert one or more URLs into structured CrawledPage records suitable for fact extraction. Wraps the Crawl4AI-based driver at packages.core.ingestion.crawl.

Trigger keywords to call out: "crawl docs", "ingest URL", "scrape documentation", "fetch and clean a docs page".

`references/usage.md`: a short example showing `from packages.core.ingestion import crawl, CrawlConfig` + an `async for page in crawl(CrawlConfig(seed_urls=("...",)))` loop.

`references/content-hash.md`: explain the canonicalization rule (lowercase + whitespace-collapse → sha256) and that this hash is the contract Phase 2 drift detection depends on.

## fact-extractor SKILL.md

Frontmatter description:

> This skill extracts atomic facts (model strings, prices, code blocks, signatures, callouts) from a CrawledPage and applies a faithfulness gate (≥0.85) per fact. Use when the user asks to "extract facts", "pull structured data from page", "find model names + prices in docs", or otherwise needs typed Fact records with provenance metadata for the fact graph. Wraps Haiku 4.5 batch extraction at packages.core.facts.extract_facts.

Trigger keywords: "extract facts", "pull facts from page", "fact extraction", "structured extraction from docs".

`references/usage.md`: short example calling `extract_facts(page)` with a `CrawledPage`. Mention that environment variables `ANTHROPIC_API_KEY` (for Haiku) and `OPENAI_API_KEY` (DeepEval judge) are required at runtime.

`references/fact-kinds.md`: enumerate the five `FactKind` literals (`model_string`, `price`, `code_block`, `signature`, `callout`) with one-sentence explanation each.

## Acceptance

- [ ] All 4 files (2 SKILL.md + 2 references/) exist at the canonical paths.
- [ ] YAML frontmatter parses cleanly: `python3 -c "import yaml; yaml.safe_load(open('skills/docs-crawler/SKILL.md').read().split('---')[1])"` returns a dict with `name` + `description` keys for both skills.
- [ ] Third-person trigger descriptions (no "I", no second-person "you" in the description field).
- [ ] ≥3 trigger keywords explicit in the body.
- [ ] No new Python files. `git diff --stat` shows only `.md` files changed.
- [ ] `uv run ruff check .` passes (no Python touched, so no-op — run anyway).
- [ ] `uv run pytest -x` passes (no test changes, just the safety check).
- [ ] Commit message: `feat(skills): package docs-crawler + fact-extractor as filesystem skills (task: T-4.4)` — body should briefly note that both skills wrap pre-existing Phase-0 implementations with no underlying behavior change.

## Out of scope

- ANY change to `packages/core/ingestion/` or `packages/core/facts/`.
- New Python code.
- Tests.
- Documentation outside the skill files (no README updates, no master-plan tweaks).

## Workflow

1. Read the relevant Phase-0 modules (`packages/core/ingestion/crawler.py`, `packages/core/facts/extractor.py`) to ground your trigger descriptions in real signatures.
2. Author `skills/docs-crawler/SKILL.md` first, then its references/.
3. Author `skills/fact-extractor/SKILL.md` and its references/.
4. Validate YAML frontmatter parses (run the one-liner above).
5. `uv run ruff format . && uv run ruff check . && uv run pytest -x` (mostly no-op).
6. Commit. Post-commit hook auto-pushes.
7. If blocked, write `.claude/plans/logs/T-4.4.BLOCKED.md` and exit.

## Notes for the agent

- The trigger description is the only thing downstream agents read at discovery time. Lead with the verb. Be specific about inputs and outputs.
- One-level-deep means: SKILL.md → references/*.md, and references/ files do NOT link to deeper subdirs. Keep it shallow.
- "Third-person" specifically means the description field uses "This skill..." not "I..." or "You can...". Body sections can be more conversational.
- Don't over-engineer the references/. Two files per skill is plenty for Phase 1.
