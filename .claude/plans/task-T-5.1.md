# Task T-5.1 — Build coordinator + 3 notebooks (Phase 1 ships)

**Wave:** 2 (= master-plan Wave 5)
**Model:** Opus 4.7 (you are Opus — design-heavy + high-risk)
**Risk:** high
**Effort:** L (3+h)
**Plan reference:** `.claude/plans/plan.md` §3 T-5.1
**Master plan reference:** `../groundtruth/.claude/plans/master-plan.md` (locked: 3 topics — `tool-use`, `structured-outputs`, `prompt-caching`; ClaudeSDKClient + AgentDefinition + @tool + create_sdk_mcp_server; prompt caching on shared fact corpus)

## Goal

`python scripts/build_notebooks.py` produces 3 Papermill-green notebooks against the shared Phase-0 fact corpus. Each notebook's prose cells score ≥0.85 on `FaithfulnessMetric`. Every fact cited has a corresponding `fact_references` row.

## Allowed file touches (DO NOT touch anything else)

- `packages/courses/build.py` (new — the coordinator)
- `scripts/build_notebooks.py` (new — CLI wrapper)
- `packages/core/kb/__init__.py` (UPDATE — add `with_provenance` + `ProvenanceRecorder` re-exports from T-4.3)
- `packages/courses/notebook/__init__.py` (UPDATE — add `validate_notebook` + `ValidationResult` re-exports from T-4.2 alongside T-4.1's `author_notebook`)
- `tests/integration/test_notebook_build.py` (new — `@pytest.mark.integration`, gated)

You may NOT modify any module in `packages/core/kb/`, `packages/core/facts/`, `packages/core/ingestion/`, `packages/courses/notebook/author.py`, or `packages/courses/notebook/validator.py`. They are fixed contracts from Wave 1. If you find a defect that blocks you, write `.claude/plans/logs/T-5.1.BLOCKED.md` describing the fix needed and exit.

## packages.courses.build

```python
async def build_topic(
    topic: str,
    *,
    output_dir: Path = Path("notebooks"),
    max_repair_attempts: int = 3,
) -> ValidationResult:
    """Author → execute → on failure, repair → re-execute. Persists fact_references."""

async def build_all() -> dict[str, ValidationResult]:
    """Parallel build of the three locked topics. Returns {topic: result}."""
```

Behavior of `build_topic(topic)`:

1. Open `with_provenance(notebook_path=str(output_dir/f"{topic}.ipynb"), cell_index=0)` — but note that the recorder needs cell-by-cell granularity. **Refinement:** open one `with_provenance` per cell during authoring. The author module receives the recorder; T-4.1's spec covers this via `provenance_cm` injection. Wire `with_provenance` from `packages.core.kb` (re-exported in your update to `__init__.py`).
2. Use a `ClaudeSDKClient` with an `AgentDefinition` per topic for parallel generation. System prompt includes the shared fact corpus (`SELECT * FROM facts`) wrapped in a cache_control ephemeral block — three subagents share the cache, paying 90% discount on reads after first.
3. Call `author_notebook(topic, kb, provenance_cm=with_provenance)` (T-4.1's surface).
4. Call `validate_notebook(input_path, output_path)` (T-4.2's surface).
5. If `result.success is False`: feed `result.final_traceback` + the failed cell back to the same subagent with a repair prompt; re-author the failing cell only; re-validate. Up to `max_repair_attempts` cycles.
6. Return the final `ValidationResult`.

`build_all()` runs `build_topic` for all three locked topics concurrently via `asyncio.gather`. If any fails after max retries, the dict still contains it with `success=False`.

## scripts/build_notebooks.py

Thin CLI wrapper:

```sh
$ python scripts/build_notebooks.py
[build_notebooks] building 3 topics in parallel...
[build_notebooks] tool-use:           ✅ 11 cells, faithfulness avg 0.91, 14 fact_refs
[build_notebooks] structured-outputs: ✅ 9 cells,  faithfulness avg 0.88, 12 fact_refs
[build_notebooks] prompt-caching:     ✅ 13 cells, faithfulness avg 0.93, 18 fact_refs
done. notebooks at notebooks/{tool-use,structured-outputs,prompt-caching}.ipynb
```

`argparse`: optional `--topic <name>` to build just one; `--max-repair-attempts N` (default 3).

## __init__.py updates

`packages/core/kb/__init__.py` — append:

```python
from packages.core.kb.provenance import ProvenanceRecorder, with_provenance

__all__ = ["get_conn", "ProvenanceRecorder", "with_provenance"]
```

(Preserve existing `get_conn` export.)

`packages/courses/notebook/__init__.py` — append T-4.2's symbols alongside T-4.1's:

```python
from packages.courses.notebook.author import author_notebook, KBFactSource
from packages.courses.notebook.validator import validate_notebook, ValidationResult, CellValidationResult

__all__ = [
    "author_notebook",
    "KBFactSource",
    "validate_notebook",
    "ValidationResult",
    "CellValidationResult",
]
```

## Integration test (`tests/integration/test_notebook_build.py`)

Gated on `@pytest.mark.integration`. Skips when DB or API keys unavailable.

1. Skip with `pytest.skip("requires running Postgres")` if `pg_isready` fails.
2. Skip with `pytest.skip("requires API keys")` if `ANTHROPIC_API_KEY`, `VOYAGE_API_KEY`, or `OPENAI_API_KEY` (for DeepEval judge) is unset.
3. Run `result = await build_topic("tool-use")`; assert `result.success is True`.
4. Open the produced `.ipynb`; assert ≥6 cells; assert at least one is markdown and one is code.
5. Query `SELECT COUNT(*) FROM fact_references WHERE notebook_path = 'notebooks/tool-use.ipynb'`; assert ≥1 (the moat is alive).
6. Walk every prose cell's faithfulness (re-run via `validate_notebook` if needed); assert avg ≥0.85.
7. Cleanup: delete the produced .ipynb + fact_references rows in a finally.

This integration test does NOT need to run during routine `pytest -x` — the marker keeps it gated.

## Acceptance

- [ ] `packages/courses/build.py` exposes `build_topic` + `build_all` per spec.
- [ ] `scripts/build_notebooks.py` runs end-to-end manually (smoke-tested by the integration test or by running it locally with the DB+keys).
- [ ] `__init__.py` updates re-export the documented public APIs.
- [ ] Integration test exists, marked, and skips cleanly when DB/keys absent.
- [ ] `uv run ruff check . && uv run ruff format --check .` clean.
- [ ] `uv run pytest -x` passes (integration test does NOT run; only unit tests).
- [ ] (Optional, requires DB+keys) `uv run pytest -x -m integration` passes locally.
- [ ] Commit message: `feat(courses): add build coordinator + 3 locked-topic notebooks (task: T-5.1)` — body should mention the prompt-cache strategy across the three subagents, the cell-granular provenance pattern, and the LLM repair loop.

## Out of scope

- Drift detection (Phase 2).
- MCP server (Phase 2).
- Adaptive crawl, multi-page scheduling, image extraction.
- New dependencies (`claude-agent-sdk`, `papermill`, `nbformat`, `anthropic`, `deepeval` already present).
- Modifying any Wave-1 module's behavior.

## Workflow

1. Verify Wave-1 surfaces are importable: `from packages.courses.notebook import author_notebook, validate_notebook` and `from packages.core.kb import with_provenance`. If any fails, your `__init__.py` updates need to come first — write them now.
2. Sketch `build_topic` end-to-end on paper. Identify where caching kicks in (system prompt with fact corpus).
3. Write `build.py`. Get the happy path running with a stub `ClaudeSDKClient` (mocks).
4. Add the LLM repair loop with `final_traceback` feedback.
5. Wire `build_all` with `asyncio.gather`.
6. Write `scripts/build_notebooks.py`.
7. Write the integration test with skip guards.
8. `uv run ruff format . && uv run ruff check . && uv run pytest -x` (must pass — integration test should skip cleanly when DB absent).
9. Commit. Post-commit hook auto-pushes.
10. If blocked, write `.claude/plans/logs/T-5.1.BLOCKED.md` and exit.

## Notes for the agent (high-risk task owner)

- The prompt cache is the cost lever. Three subagents reading the same fact corpus in their system prompt → first read pays full price, two subsequent reads pay 10%. Validate by inspecting the SDK's response metadata (`cache_read_input_tokens > 0` after the second subagent runs).
- The repair loop is bounded: 3 attempts total per failing cell, NOT per notebook. If a notebook still fails after 3 repairs, mark `success=False` and let the user re-run.
- `fact_references` rows are the moat. The integration test's COUNT(*) ≥ 1 assertion is the bare minimum — manually verify locally that the count looks right (one row per fact citation per cell).
- Don't reach into Wave-1 modules to "improve" them mid-task. Their contracts are locked. If something feels broken, it's a follow-up bug fix in a separate task.
