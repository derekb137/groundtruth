# Groundtruth Phase 1 — Notebook Factory Execution Plan

**Status:** Ready to launch
**Worktree:** `/Users/derekb137/src/github/groundtruth-groundtruth-phase1`
**Branch:** `chore/groundtruth-phase1`
**Base:** `origin/develop @ 8168310cd` (Phase 0 merge commit, tagged `v0.0.1`)
**Driver:** Opus 4.7 orchestrator + mixed Opus 4.7 / Sonnet 4.6 workstreams
**Mode:** Autonomous (`--dangerously-skip-permissions`)
**PR strategy:** wave-grouped (one PR per wave to `develop`; orchestrator does NOT auto-merge)

**Phase goal:** generate 3 executable notebooks (`tool-use`, `structured-outputs`, `prompt-caching`) from the Phase-0 fact graph. Every cited fact persists a `fact_references` row (the moat). All notebooks Papermill-green. Faithfulness ≥0.85 on each notebook's prose. Master plan at `../groundtruth/.claude/plans/master-plan.md`.

---

## 1. Items in scope (5)

| ID | Item | Wave | Effort | Model | Risk | Touches |
|---|---|---|---|---|---|---|
| T-4.1 | `notebook-author` Skill (≤500-line SKILL.md, third-person trigger description, references one level deep) + author module | 1 | L | opus | high | `skills/notebook-author/SKILL.md`, `skills/notebook-author/references/`, `packages/courses/notebook/author.py`, `packages/courses/notebook/__init__.py`, `tests/unit/test_notebook_author.py` |
| T-4.2 | `notebook-validator` Skill — Papermill executes, captures `PapermillExecutionError`, reads partial `.ipynb` from disk on failure for repair-loop context (max 3 attempts); DeepEval faithfulness on prose cells | 1 | M | sonnet | med | `skills/notebook-validator/SKILL.md`, `packages/courses/notebook/validator.py`, `tests/unit/test_notebook_validator.py`, `tests/evals/notebook/` |
| T-4.3 | `kb.with_provenance()` context manager — every fact access during generation auto-records to `fact_references`; property test asserts no orphan references | 1 | M | opus | high | `packages/core/kb/provenance.py`, `packages/core/kb/references.py`, `tests/unit/test_provenance.py`, `tests/property/test_no_orphan_refs.py` |
| T-4.4 | Package `docs-crawler` + `fact-extractor` as filesystem Claude Code Skills (third-person descriptions, trigger-keyword tuned) | 1 | M | sonnet | low | `skills/docs-crawler/SKILL.md`, `skills/docs-crawler/references/`, `skills/fact-extractor/SKILL.md`, `skills/fact-extractor/references/` |
| T-5.1 | Build coordinator using `ClaudeSDKClient` + `AgentDefinition` subagents; prompt caching on shared fact corpus; generates 3 notebooks (tool-use, structured-outputs, prompt-caching) | 2 | L | opus | high | `packages/courses/build.py`, `scripts/build_notebooks.py`, `packages/core/kb/__init__.py` (export updates), `tests/integration/test_notebook_build.py` |

**Effort key:** S = ≤1h, M = 1–3h, L = 3+h
**Risk key:** low / med / high (orchestrator routes high-risk to Opus + extra retries)
**Touches:** every file the task is allowed to modify. Disjoint `Touches` within a wave = parallel-safe.

---

## 2. Wave grouping

```
Wave 1 (4 parallel) → PR A
  T-4.1 (author skill+module)  ‖  T-4.2 (validator)  ‖  T-4.3 (provenance)  ‖  T-4.4 (skill packaging)
       ↓
Wave 2 (1 task) → PR B
  T-5.1 (build coordinator + 3 notebooks)
```

**Parallel safety verified:** Wave 1's four tasks have disjoint `Touches`:
- T-4.1: `skills/notebook-author/`, `packages/courses/notebook/author.py` + its `__init__.py`
- T-4.2: `skills/notebook-validator/`, `packages/courses/notebook/validator.py` (DOES NOT touch `__init__.py`)
- T-4.3: `packages/core/kb/{provenance,references}.py`, NO touches in `kb/__init__.py`
- T-4.4: `skills/docs-crawler/`, `skills/fact-extractor/` only

**T-4.1 owns `packages/courses/notebook/__init__.py`.** T-4.2 must not write to it; the orchestrator reconciles re-exports during Wave 2 prep if needed.

Wave 2 imports from all four Wave-1 modules; runs sequentially after Wave 1 PR cherry-picks.

---

## 3. Per-task specs

Full per-task specs are stored at `.claude/plans/task-T-X.Y.md`. Summaries here:

### T-4.1: `notebook-author` Skill + author module
- **Goal:** filesystem Claude Code Skill that triggers on "generate notebook", "build notebook", "author lesson"; backed by `packages.courses.notebook.author.author_notebook(topic, kb)` returning a Papermill-ready `.ipynb` JSON.
- **Approach:** SKILL.md ≤500 lines, third-person description ("This skill authors executable notebooks from a fact graph..."), references/ holds expanded prompt patterns + cell templates one level deep. The Python module emits `nbformat.NotebookNode` with markdown + code cells; uses `kb.with_provenance()` from T-4.3 (lazy import — sub-agents run in parallel).
- **Acceptance:** unit tests assert notebook structure + cell ordering + provenance hooks fire (mocked); SKILL.md trigger description starts with the third person + lists ≥3 trigger keywords.
- **Out of scope:** Papermill execution (T-4.2), live LLM calls in tests (mock), the build coordinator (T-5.1).

### T-4.2: `notebook-validator` Skill + Papermill validator
- **Goal:** filesystem Skill for "validate notebook" / "execute notebook"; Python module `validate_notebook(path)` runs Papermill, catches `PapermillExecutionError`, reads the partial `.ipynb` from disk for repair context, retries up to 3 times.
- **Approach:** Wraps `papermill.execute_notebook(input_path, output_path)` with a try/except; on `PapermillExecutionError`, opens output_path with `nbformat.read` to extract failed cell + traceback. Faithfulness eval applied to prose cells via `packages.shared.eval.faithfulness.evaluate_faithfulness`. Cassette-based mocking via `vcr.py` for any LLM calls.
- **Acceptance:** unit tests cover success path, repair-loop, max-retry exhaustion. SKILL.md trigger keywords tuned. Eval suite at `tests/evals/notebook/` ships ≥3 fixture notebooks.
- **Out of scope:** Author logic (T-4.1), build coordinator (T-5.1), live Anthropic calls.

### T-4.3: `kb.with_provenance()` context manager + `fact_references` writer
- **Goal:** when notebook generation reads a fact, automatically write a `fact_references(fact_id, notebook_path, cell_index)` row. The moat depends on this — Phase 2's drift propagator queries `fact_references` to know what to regen.
- **Approach:** `provenance.py` defines `with_provenance(notebook_path, cell_index)` async context manager that swaps in an instrumented fact-fetcher; `references.py` is the bulk writer (`insert_fact_references(rows)`). Property test (Hypothesis) generates random notebook+fact mixes and asserts every accessed fact has a reference row + no orphans.
- **Acceptance:** unit tests for the context manager + writer; property test passes; both async-friendly.
- **Out of scope:** notebook authoring (T-4.1), drift propagation (Phase 2 / T-6.2).

### T-4.4: Package `docs-crawler` + `fact-extractor` as Skills
- **Goal:** thin filesystem Claude Code Skills wrapping the Phase-0 modules. Trigger descriptions tuned for "crawl docs", "ingest URL", "extract facts from page".
- **Approach:** SKILL.md per skill with third-person description, ≥3 trigger keywords, references/ subdir with one-level-deep usage patterns. NO new Python — these wrap existing `packages.core.ingestion.crawl` and `packages.core.facts.extract_facts`.
- **Acceptance:** SKILL.md files exist at the canonical paths; YAML frontmatter valid; references/ each have ≥1 .md file with usage example.
- **Out of scope:** modifying the underlying crawler or extractor; new Python.

### T-5.1: Build coordinator + 3 notebooks
- **Goal:** `python scripts/build_notebooks.py` produces 3 Papermill-green notebooks: `tool-use`, `structured-outputs`, `prompt-caching`. All against the shared Phase-0 fact corpus. Each notebook's prose cells score ≥0.85 on `FaithfulnessMetric`.
- **Approach:** `packages.courses.build.build_topic(topic)` orchestrates author → validate → re-author-on-failure (up to 3) using `ClaudeSDKClient` + `AgentDefinition` subagents (one per topic, parallelized). System prompt cached (`cache_control={"type":"ephemeral"}`) for the shared fact corpus. The CLI `scripts/build_notebooks.py` is a thin wrapper.
- **Acceptance:** `tests/integration/test_notebook_build.py` (`@pytest.mark.integration`) generates one notebook end-to-end against running Postgres; asserts `.ipynb` valid, all cells executed, `fact_references` rows match cell count, faithfulness ≥0.85.
- **Out of scope:** drift detection (Phase 2), MCP server (Phase 2), live deploy.

---

## 4. Verification gates

Per-task (sub-worktree) — defined in `scripts/parallel/verify-gate.sh`:
```sh
uv run --no-sync ruff check .
uv run --no-sync pytest --tb=short -q
# mypy runs against packages/ (already MYPY_TARGET-aware after Phase 0)
```

Per-wave (after cherry-pick to `chore/groundtruth-phase1`):
```sh
uv run ruff format --check .
uv run ruff check .
uv run pytest --tb=short        # full suite (integration tests skip when DB absent)
uv run mypy packages/           # info-only for Phase 1; ratchet to enforced in Phase 2
```

Wave 1 priority is ruff+pytest green (mypy still info-only — followup carried from Phase 0).

---

## 5. PR plan

- **PR A** (Wave 1): `chore/groundtruth-phase1` after Wave 1 cherry-picks → `develop`. Title: `feat(courses): Wave 4 — author skill, validator, provenance, skill packaging`.
- **PR B** (Wave 2): same branch, additional commits → `develop`. Title: `feat(courses): Wave 5 — build coordinator + 3 notebooks (Phase 1 ships)`.
- Per Phase 0's experience: orchestrator opens both PRs back-to-back without waiting for human merge between waves; if both share branch `chore/groundtruth-phase1`, PR #1 is retitled at Wave 2 boundary instead of opening a duplicate (same pattern as Phase 0 PR #1).
- Orchestrator does NOT auto-merge.
- After PR B merges, Phase 1 ships. Tag `v0.1.0` optional. Then `groundtruth-phase2` slug starts.

---

## 6. Orchestration protocol (codified)

**Autonomous mode:** orchestrator proceeds wave→wave without check-ins. Stops only on:
- 3 consecutive failed retries on a single task
- Rate-limit halt (`ScheduleWakeup` to resume in 1800s)
- Spec ambiguity that would cause information loss
- T-5.1 faithfulness eval running below 0.5 average across the 3 notebooks (signals systemic generation breakage)
- T-4.3 property test consistently failing (signals provenance fan-out is leaky — moat is broken)

**Model routing:**
- T-4.1, T-4.3, T-5.1 (high risk + design-heavy): Opus 4.7
- T-4.2, T-4.4 (low/med risk): Sonnet 4.6
- Inner Sonnet/Haiku 4.5 calls within T-5.1's subagents are fine (notebook generation); orchestrator does not need them as workstream models

**Skill triggering:** sub-agents may consult `../groundtruth/skills/{notebook-author,notebook-validator,docs-crawler,fact-extractor}/SKILL.md` once T-4.1 / T-4.2 / T-4.4 land mid-wave. Phase 1 is the wave that AUTHORS those skills, so cross-task referencing within Wave 1 is one-way: nothing depends on a sibling task's output before its commit lands. Wave 2 (T-5.1) consumes all four.

User can monitor via `.claude/plans/progress.md`. User can inject feedback by editing `.claude/plans/USER_NOTES.md` — orchestrator reads it before each new wave.

---

## 7. Done criteria

- [ ] T-4.1 → T-4.4 all merged via PR A
- [ ] T-5.1 merged via PR B
- [ ] Phase 1 acceptance: `python scripts/build_notebooks.py` produces 3 Papermill-green notebooks against the shared Phase-0 fact corpus
- [ ] Faithfulness ≥0.85 on every prose cell across all 3 notebooks
- [ ] `fact_references` populated: every fact cited in any notebook has a corresponding row (Hypothesis property test enforces)
- [ ] `pytest` green (full suite, including integration mark gated behind running Postgres)
- [ ] `ruff check .` clean, format clean
- [ ] All 4 SKILL.md files have third-person trigger descriptions + ≥3 keywords + valid YAML frontmatter
- [ ] No new TODO/FIXME comments without linked issues
- [ ] `.claude/plans/progress.md` updated with per-task summaries + any followups
