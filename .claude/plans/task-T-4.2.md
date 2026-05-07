# Task T-4.2 — `notebook-validator` Skill + Papermill validator

**Wave:** 1 (= master-plan Wave 4)
**Model:** Sonnet 4.6
**Risk:** med
**Effort:** M (1–3h)
**Plan reference:** `.claude/plans/plan.md` §3 T-4.2
**Master plan reference:** `../groundtruth/.claude/plans/master-plan.md` (locked: Papermill, fail loudly — no `allow_errors=True`; cassette-based mocking via `vcr.py` per risk register #3)

## Goal

Two deliverables:

1. **`skills/notebook-validator/SKILL.md`** — filesystem Claude Code skill triggering on "validate notebook", "execute notebook", "test notebook".
2. **`packages/courses/notebook/validator.py`** — `validate_notebook(input_path, output_path) -> ValidationResult` runs Papermill, captures `PapermillExecutionError`, reads the partial `.ipynb` from disk for repair-loop context, retries up to 3 times. Also runs `evaluate_faithfulness` on every markdown prose cell.

## Allowed file touches (DO NOT touch anything else)

- `skills/notebook-validator/SKILL.md` (new)
- `skills/notebook-validator/references/*.md` (new — one-level-deep)
- `packages/courses/notebook/validator.py` (new)
- `tests/unit/test_notebook_validator.py` (new)
- `tests/evals/notebook/` (new directory — fixtures + manual-only runner, NOT a pytest)

**You may NOT edit `packages/courses/notebook/__init__.py` — T-4.1 owns it.** T-5.1 will reconcile the joint export surface in Wave 2. From `__init__.py`'s perspective, `validator.py` simply lives next to `author.py`.

You may import from `packages.shared.eval.faithfulness` (Phase 0 — already in develop).

## SKILL.md requirements

Frontmatter:

```yaml
---
name: notebook-validator
description: This skill validates and executes Jupyter notebooks via Papermill, surfacing partial output on failure for repair workflows. Use when the user asks to "validate a notebook", "execute the notebook", "test that the notebook runs", or needs to verify nbformat-valid output is also Papermill-green. Captures PapermillExecutionError, reads the partial .ipynb from disk for traceback context, and retries up to 3 times. Also runs FaithfulnessMetric on every prose cell against the fact corpus.
---
```

Body (markdown, ≤500 lines):
- "When to use" (third person, leading with the verb)
- "Trigger keywords" (≥3)
- "Inputs/outputs"
- "Error handling" — explains the partial-output-on-failure read and the 3-retry budget
- Pointer to `references/repair-prompts.md` (the next level — the actual prompts an outer agent would use to repair a failed cell)

## references/

At minimum:
- `references/repair-prompts.md` — prompt patterns the outer agent (T-5.1) uses to repair a failed cell given the traceback.
- `references/papermill-gotchas.md` — short list of common Papermill pitfalls (ipykernel must be installed; `parameters` cell tag for parameterization; `--log-output` for stream capture).

## validator.py requirements

```python
from dataclasses import dataclass
from pathlib import Path

@dataclass(frozen=True, slots=True)
class CellValidationResult:
    cell_index: int
    passed: bool
    score: float | None       # faithfulness score for prose cells; None for code cells
    error: str | None         # traceback for failed code cells

@dataclass(frozen=True, slots=True)
class ValidationResult:
    success: bool
    output_path: Path
    cells: list[CellValidationResult]
    attempts: int             # how many Papermill executions it took (1..3)
    final_traceback: str | None

async def validate_notebook(
    input_path: Path,
    output_path: Path,
    *,
    max_attempts: int = 3,
    fact_corpus_for_faithfulness: list[str] | None = None,
) -> ValidationResult: ...
```

Behavior:

1. Try `papermill.execute_notebook(str(input_path), str(output_path))` (do NOT pass `allow_errors=True` — fail loudly per locked decision).
2. On `PapermillExecutionError` raised: read `output_path` via `nbformat.read(output_path, as_version=4)` to extract the partial output. Capture failed cell index + traceback. If attempts remaining, the validator does NOT itself attempt the repair (the outer agent does that) — return `ValidationResult(success=False, ..., final_traceback=...)` and let the caller decide whether to re-author and re-call. The `max_attempts` parameter governs only the LIVE retry-papermill loop after intermediate failures (e.g., kernel hiccups), not the LLM repair loop. Document this distinction clearly in the docstring.
3. On success: open the executed notebook from `output_path`, walk every markdown cell, and run `evaluate_faithfulness(claim=cell.source, source="\n".join(fact_corpus_for_faithfulness))` if the corpus is provided. Skip if not. Score each cell; build the `CellValidationResult` list.
4. Return `ValidationResult(success=True/False, ...)`.

Cassette-based mocking strategy (per master plan risk #3): if any of validator's helpers makes live HTTP calls (none should — Papermill is local, faithfulness via DeepEval is sync), they're already mocked at the unit-test layer. `vcr.py` is on standby for T-5.1 integration tests but not strictly required here.

## Tests (`tests/unit/test_notebook_validator.py`)

NO live LLM calls. NO live Papermill (mock with `unittest.mock`).

1. `test_success_path` — patch `papermill.execute_notebook` to write a tiny success notebook to output_path. Assert `ValidationResult(success=True, attempts=1, ...)`.
2. `test_papermill_error_returns_traceback` — patch `papermill.execute_notebook` to raise `PapermillExecutionError`. Patch `nbformat.read` to return a partial notebook with a failed cell. Assert `ValidationResult(success=False, final_traceback="...", attempts=1)`.
3. `test_max_attempts_exhausted` — patch `papermill.execute_notebook` to raise twice then succeed. With `max_attempts=3`, success returned with `attempts=3`. With `max_attempts=2`, failure returned.
4. `test_faithfulness_run_on_markdown_cells` — patch `evaluate_faithfulness` to return `(0.9, True)`; success notebook has 1 markdown cell + 1 code cell; assert only the markdown cell got scored.
5. `test_faithfulness_skipped_when_corpus_none` — `fact_corpus_for_faithfulness=None`; assert `evaluate_faithfulness` is never called.

## Eval fixtures (`tests/evals/notebook/`)

- `tests/evals/notebook/README.md` — describes the fixture set + manual run command.
- `tests/evals/notebook/fixtures/{ok,broken_code,unfaithful_prose}.ipynb` — three minimal `.ipynb` files: one that should validate cleanly, one with a known code error, one with prose that contradicts a fact (for faithfulness testing).
- `tests/evals/notebook/run_eval.py` — manual runner; loads each fixture, calls `validate_notebook`, prints results. Top comment: `# Run manually — calls live Papermill + DeepEval. Not a pytest.`

Do NOT add a pytest that runs these fixtures live (would slow `pytest -x`).

## Acceptance

- [ ] SKILL.md exists with valid YAML frontmatter.
- [ ] `references/repair-prompts.md` and `references/papermill-gotchas.md` exist.
- [ ] `validator.py` exposes `validate_notebook` per spec.
- [ ] All 5 unit tests pass with mocks.
- [ ] Eval fixtures in place (3 `.ipynb` files + README + run_eval.py); pytest does NOT pick them up.
- [ ] `uv run ruff check packages/courses/ tests/` clean.
- [ ] `uv run ruff format --check packages/courses/ tests/` clean.
- [ ] `uv run pytest -x` passes (only the new unit tests run; eval runner stays manual).
- [ ] Commit message: `feat(courses): add notebook-validator skill + Papermill validator (task: T-4.2)` — body should mention the no-`allow_errors`-True policy, the partial-output-on-failure pattern, and that LLM-repair retries live in the outer agent (T-5.1).

## Out of scope

- The author module (T-4.1).
- The provenance writer (T-4.3).
- The build coordinator + LLM repair loop (T-5.1).
- Live LLM calls in pytest.
- Touching `packages/courses/notebook/__init__.py` (T-4.1's territory).

## Workflow

1. Sketch the `ValidationResult` shape; lock the public surface first.
2. Write `validator.py`. Get the success path working.
3. Wire in the partial-output-on-failure read.
4. Add the faithfulness loop on prose cells.
5. Write the 5 unit tests with mocks.
6. Author the 3 `.ipynb` fixtures (use `nbformat.v4.new_notebook` programmatically — don't hand-write JSON).
7. Write the SKILL.md last.
8. `uv run ruff format . && uv run ruff check . && uv run pytest -x`.
9. Commit. Post-commit hook auto-pushes.
10. If blocked, write `.claude/plans/logs/T-4.2.BLOCKED.md` and exit.

## Notes for the agent

- Papermill's `execute_notebook` writes the in-progress notebook to `output_path` BEFORE failing. That's why we can read it back for partial output. This behavior is documented in Papermill's docs and is the single most useful thing about Papermill — preserve it in your design.
- The `max_attempts` knob covers ONLY transient Papermill failures (kernel hiccups, race conditions). LLM-driven repair (re-author the cell) is the outer agent's responsibility — don't conflate them.
- `vcr.py` is on standby per master-plan risk #3 but not needed for unit tests since you mock at the function boundary.
