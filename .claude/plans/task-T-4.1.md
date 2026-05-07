# Task T-4.1 — `notebook-author` Skill + author module

**Wave:** 1 (= master-plan Wave 4)
**Model:** Opus 4.7 (you are Opus — design-heavy + high-risk)
**Risk:** high
**Effort:** L (3+h)
**Plan reference:** `.claude/plans/plan.md` §3 T-4.1
**Master plan reference:** `../groundtruth/.claude/plans/master-plan.md` (locked decisions: filesystem-based Claude Code skills; three notebook topics for T-5.1: tool-use, structured-outputs, prompt-caching)

## Goal

Two deliverables that together enable T-5.1's coordinator to author notebooks:

1. **`skills/notebook-author/SKILL.md`** — a filesystem Claude Code skill with a third-person trigger description (≤500 lines, references one level deep) that triggers on "generate notebook", "author lesson", "build notebook from facts".
2. **`packages/courses/notebook/author.py`** — a Python module exposing `author_notebook(topic: str, kb: KBFactSource) -> nbformat.NotebookNode`. The module produces a Papermill-ready `.ipynb` JSON with markdown + code cells, sourcing all factual claims from the fact graph via the `kb.with_provenance()` context manager (T-4.3).

## Allowed file touches (DO NOT touch anything else)

- `skills/notebook-author/SKILL.md` (new — the skill manifest)
- `skills/notebook-author/references/*.md` (new — one-level-deep expansion files)
- `packages/courses/notebook/author.py` (new)
- `packages/courses/notebook/__init__.py` (new — re-exports `author_notebook` only)
- `tests/unit/test_notebook_author.py` (new)

**You may NOT edit `packages/courses/notebook/validator.py` (T-4.2 owns it).** T-4.2 will not write to `__init__.py` — you own it.

**T-4.3's `with_provenance()` may not exist when you start (parallel sibling task).** Solution: import lazily inside the function or behind `TYPE_CHECKING`, and have the unit tests inject a mock context manager via dependency injection (e.g., `author_notebook(topic, kb, *, provenance_cm=default_provenance)`).

## SKILL.md requirements

Frontmatter (YAML):

```yaml
---
name: notebook-author
description: This skill authors executable Jupyter notebooks from a fact graph. Use when the user asks to "generate a notebook", "author a lesson notebook", "build notebook from facts", or otherwise needs to convert a topic + fact corpus into a runnable notebook with provenance-tracked claims. Produces nbformat-valid output with markdown prose cells and Anthropic SDK code cells, ready for Papermill execution.
---
```

Body (markdown, ≤500 lines):

- 1-paragraph "When to use" section (third person — "This skill...").
- "Trigger keywords" section listing ≥3 explicit phrases.
- "Inputs" section: `topic` string, `kb` fact source.
- "Outputs" section: nbformat NotebookNode + metadata.
- "How it works" section walking through cell ordering (intro → setup → 3-5 code cells with prose → recap).
- Pointer to `references/cell-templates.md` (the next level deep) for the actual cell template strings.

Body must NOT inline 500 lines of templates — push templates into `references/cell-templates.md`. Per the locked decision and the standard skill pattern, references are one level deep only (not nested deeper).

## references/ requirements (one-level-deep only)

At minimum:
- `references/cell-templates.md` — the markdown + code cell skeletons keyed by topic. Include templates for `tool-use`, `structured-outputs`, `prompt-caching` (the three topics T-5.1 will request).
- `references/prompt-patterns.md` — the prose patterns the author module uses to compose cell content (intro sentence, fact citation format, recap).

## author.py requirements

```python
from typing import Protocol
import nbformat

class KBFactSource(Protocol):
    """The minimum kb interface author_notebook depends on."""
    async def get_facts(self, topic: str, *, limit: int = 50) -> list["Fact"]: ...

async def author_notebook(
    topic: str,
    kb: KBFactSource,
    *,
    provenance_cm = None,  # injected by T-5.1 via T-4.3's with_provenance
) -> nbformat.NotebookNode:
    """Build a Papermill-ready notebook for the given topic from the fact corpus.

    The provenance_cm parameter is the context manager from T-4.3's
    kb.with_provenance(notebook_path, cell_index). When set, every fact
    access inside the with-block records a fact_references row.
    """
```

Behavior:

1. Look up facts via `kb.get_facts(topic)` (interface — T-4.3's real KB will provide this; tests inject mocks).
2. Build cells in order: title markdown → setup code (`!pip install anthropic` etc) → 3–5 topic-specific code cells, each preceded by a prose markdown cell that cites the underlying facts inline (e.g., "Per the Anthropic docs (`fact_id=...`), the recommended model is `claude-sonnet-4-6`."). Final recap markdown cell.
3. Each cell access happens inside `provenance_cm(notebook_path, cell_index)` if provided. If `provenance_cm is None`, fact access still works but no `fact_references` row is written (this is the test-time path).
4. Return a `nbformat.v4.new_notebook()` populated with the cells.
5. Use `nbformat.v4.new_markdown_cell(...)` and `nbformat.v4.new_code_cell(...)`.

Type hints throughout. Public docstring on `author_notebook`.

## __init__.py

```python
from packages.courses.notebook.author import author_notebook, KBFactSource

__all__ = ["author_notebook", "KBFactSource"]
```

T-4.2's `validator.py` will export from its own module; T-5.1 reconciles the joint surface during Wave 2 prep.

## Tests (`tests/unit/test_notebook_author.py`)

NO live LLM calls. NO live KB calls. Mock everything.

1. `test_author_returns_nbformat_node` — mocked `kb.get_facts` returns 3 fake `Fact` objects; assert returned object is a `nbformat.NotebookNode` with `nbformat_minor` set.
2. `test_cell_order_intro_setup_body_recap` — assert the cell list starts with markdown intro, has setup code cell second, and ends with markdown recap.
3. `test_provenance_cm_invoked_per_cell` — pass a `MagicMock` as `provenance_cm`; assert it's called once per generated cell with `(notebook_path, cell_index)` shape.
4. `test_provenance_cm_optional` — call with `provenance_cm=None`; assert no error + same cell output.
5. `test_topic_specific_template_selected` — call with `topic="tool-use"`, `topic="structured-outputs"`, `topic="prompt-caching"`; assert each produces topic-tagged code cells (e.g. presence of `tools=` in the tool-use code cell, `response_format=` for structured-outputs, `cache_control=` for prompt-caching).

Use `pytest-asyncio` (auto mode is set in `pyproject.toml`).

## Acceptance

- [ ] `skills/notebook-author/SKILL.md` exists with valid YAML frontmatter (parseable by PyYAML).
- [ ] SKILL.md body is ≤500 lines.
- [ ] At least `references/cell-templates.md` and `references/prompt-patterns.md` exist.
- [ ] `author.py` exposes `author_notebook` per the signature above.
- [ ] `packages/courses/notebook/__init__.py` re-exports `author_notebook` and `KBFactSource`.
- [ ] All 5 unit tests pass.
- [ ] `uv run ruff check packages/courses/ tests/` clean.
- [ ] `uv run ruff format --check packages/courses/ tests/` clean.
- [ ] `uv run pytest -x` passes.
- [ ] Commit message: `feat(courses): add notebook-author skill + author module (task: T-4.1)` — body should mention the third-person trigger description, the cell-ordering convention, and the provenance_cm dependency-injection pattern that lets the test suite stay decoupled from T-4.3.

## Out of scope

- Papermill execution (T-4.2).
- The actual `with_provenance()` implementation (T-4.3 — you only depend on the interface).
- The build coordinator (T-5.1).
- Live Anthropic / Voyage calls in tests.
- Adding new dependencies (`nbformat` is already pulled in via `papermill` chain).

## Workflow

1. Read the master-plan locked decisions on skills + the three locked notebook topics.
2. Sketch the cell template per topic — what does a "tool-use" notebook look like? What about "prompt-caching"? Reference the Anthropic docs structure as your guide.
3. Write the templates into `references/cell-templates.md` first (so SKILL.md stays lean).
4. Write `author.py` referencing the templates.
5. Write the 5 unit tests with mocks.
6. Write `SKILL.md` last (now that the implementation shape is concrete).
7. `uv run ruff format . && uv run ruff check . && uv run pytest -x`.
8. Commit with the message format above. Post-commit hook auto-pushes to `origin/temp/groundtruth-phase1-T-4.1`.
9. Exit cleanly. If blocked, write `.claude/plans/logs/T-4.1.BLOCKED.md` and exit.

## Notes for the agent (high-risk task owner)

- The third-person trigger description is the most-read part of the skill — agents downstream pattern-match on it. Lead with the verb the user would say ("authors executable Jupyter notebooks…").
- Templates should be model-agnostic — they generate Anthropic SDK code, but the prose templates should not bake in specific model strings. Those come from facts at runtime.
- If you find yourself wanting to call out to Claude inside `author.py`, stop — that belongs in T-5.1's coordinator. `author.py` is pure assembly: facts in, notebook structure out.
- The `provenance_cm` parameter is a small interface seam that protects you from T-4.3 being incomplete at parallel-spawn time. Don't try to be clever and import `with_provenance` directly — the lazy-injection pattern is the contract.
