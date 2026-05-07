# Task T-4.3 — `kb.with_provenance()` + `fact_references` writer

**Wave:** 1 (= master-plan Wave 4)
**Model:** Opus 4.7 (you are Opus — design-heavy + high-risk)
**Risk:** high
**Effort:** M (1–3h)
**Plan reference:** `.claude/plans/plan.md` §3 T-4.3
**Master plan reference:** `../groundtruth/.claude/plans/master-plan.md` (the `fact_references` table is THE moat — Phase 2's drift propagator queries it to know what to regenerate when a fact changes)

## Goal

Two deliverables:

1. **`packages/core/kb/provenance.py`** — async context manager `with_provenance(notebook_path: str, cell_index: int)` that swaps in an instrumented fact-fetcher; every fact access inside the with-block records a `fact_references(fact_id, notebook_path, cell_index)` row.
2. **`packages/core/kb/references.py`** — bulk writer `insert_fact_references(rows: list[FactReference]) -> None` that batches inserts. Plus a `FactReference` dataclass.

Plus a property test using Hypothesis that asserts: for any random sequence of fact accesses inside a `with_provenance(...)` block, every accessed `fact_id` shows up exactly once per (notebook_path, cell_index) tuple in the resulting `fact_references` rows. Zero orphans.

## Allowed file touches (DO NOT touch anything else)

- `packages/core/kb/provenance.py` (new)
- `packages/core/kb/references.py` (new)
- `tests/unit/test_provenance.py` (new — unit tests)
- `tests/property/test_no_orphan_refs.py` (new — Hypothesis property test)

**You may NOT edit `packages/core/kb/__init__.py`.** T-5.1 reconciles re-exports in Wave 2. Imports of your symbols use the deep paths (`from packages.core.kb.provenance import with_provenance`).

You may read but NOT modify `packages/core/kb/connection.py` and `packages/core/kb/schema.sql` (Phase 0 fixed contracts).

## provenance.py requirements

```python
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass

@dataclass(frozen=True, slots=True)
class FactReference:
    fact_id: str           # uuid string
    notebook_path: str
    cell_index: int

class ProvenanceRecorder:
    """In-memory accumulator handed to fact-fetcher wrappers. Tests assert against this directly."""
    def __init__(self, notebook_path: str, cell_index: int) -> None: ...
    def record(self, fact_id: str) -> None: ...  # idempotent — dedupes within (notebook_path, cell_index)
    def drain(self) -> list[FactReference]: ...

@asynccontextmanager
async def with_provenance(notebook_path: str, cell_index: int) -> AsyncIterator[ProvenanceRecorder]:
    """Yields a ProvenanceRecorder; on context exit, flushes accumulated FactReference rows
    to the database via insert_fact_references(). Safe to use even when DB is absent (in tests):
    the flush call is a no-op if the recorder is empty."""
```

Behavior:

1. The context manager yields a `ProvenanceRecorder`. The caller (T-4.1's author module) records each fact_id it accesses via `recorder.record(fact_id)`.
2. On exit (success path), the recorder's accumulated rows are flushed via `await insert_fact_references(rows)`.
3. On exception, decide policy: prefer "still flush partial provenance — the half-built notebook is real" — propagating the original exception after.
4. Idempotency: `recorder.record(fact_id)` called twice with the same fact_id within the same context produces ONE row, not two. (We're recording cell→fact references, not access counts.)

## references.py requirements

```python
async def insert_fact_references(rows: list[FactReference]) -> None:
    """Bulk-insert fact_references rows. Uses a single INSERT ... VALUES (...), (...), ...
    or executemany() under one transaction. Empty list is a no-op."""
```

Use `packages.core.kb.connection.get_conn()` (Phase 0 fixed). Write idempotency via `ON CONFLICT (fact_id, notebook_path, cell_index) DO NOTHING` if a unique index exists, OR via a pre-INSERT existence check. The fact_references schema (Phase 0) does NOT currently have that unique index — add it ONLY if your design requires it (note in commit message). Otherwise, accept that rows can be duplicated at the DB level and rely on the in-memory dedupe in `ProvenanceRecorder` to prevent it.

## Unit tests (`tests/unit/test_provenance.py`)

NO live DB calls. Mock `insert_fact_references` (or the `get_conn` it uses).

1. `test_recorder_dedupes_within_block` — record same fact_id 3 times; `drain()` returns 1 FactReference.
2. `test_with_provenance_flushes_on_exit` — patch `insert_fact_references`; enter context, record 2 fact_ids, exit; assert `insert_fact_references` called once with 2-row list.
3. `test_with_provenance_flushes_on_exception` — record 2, raise inside context; assert `insert_fact_references` STILL called with 2-row list, then exception propagates.
4. `test_empty_context_no_flush` — enter context, do nothing, exit; assert `insert_fact_references` was NOT called (or called with empty list — your choice; document it).

## Property test (`tests/property/test_no_orphan_refs.py`)

Use `hypothesis` (already in dev deps).

```python
from hypothesis import given, strategies as st

@given(
    fact_ids=st.lists(st.uuids().map(str), min_size=1, max_size=20, unique=True),
    cell_index=st.integers(min_value=0, max_value=50),
)
async def test_every_recorded_fact_appears_exactly_once(fact_ids, cell_index):
    recorder = ProvenanceRecorder("notebooks/test.ipynb", cell_index)
    for fid in fact_ids:
        recorder.record(fid)
        recorder.record(fid)  # double-record — should still dedupe
    rows = recorder.drain()
    assert len(rows) == len(set(fact_ids))
    assert {r.fact_id for r in rows} == set(fact_ids)
    assert all(r.notebook_path == "notebooks/test.ipynb" for r in rows)
    assert all(r.cell_index == cell_index for r in rows)
```

This is the property the moat depends on. Don't water it down.

Add a second property covering the multi-cell case:

```python
@given(
    cells=st.lists(
        st.tuples(
            st.integers(min_value=0, max_value=20),
            st.lists(st.uuids().map(str), min_size=0, max_size=5, unique=True),
        ),
        min_size=1, max_size=10,
    ),
)
async def test_no_cross_cell_leakage(cells):
    """Recording in one cell index never produces rows for another."""
    all_rows: list[FactReference] = []
    for ci, fids in cells:
        rec = ProvenanceRecorder("nb.ipynb", ci)
        for fid in fids:
            rec.record(fid)
        all_rows.extend(rec.drain())
    by_cell: dict[int, set[str]] = {}
    for r in all_rows:
        by_cell.setdefault(r.cell_index, set()).add(r.fact_id)
    for ci, fids in cells:
        assert by_cell.get(ci, set()) >= set(fids)
```

## Acceptance

- [ ] `provenance.py` exposes `with_provenance` + `ProvenanceRecorder` + `FactReference`.
- [ ] `references.py` exposes `insert_fact_references`.
- [ ] All 4 unit tests pass.
- [ ] Both Hypothesis property tests pass (run for default 100 examples; can lower to 50 if too slow).
- [ ] `uv run ruff check packages/core/kb/ tests/` clean.
- [ ] `uv run ruff format --check packages/core/kb/ tests/` clean.
- [ ] `uv run pytest -x` passes.
- [ ] Commit message: `feat(kb): add with_provenance() context manager + fact_references writer (task: T-4.3)` — body must mention the dedupe-on-record contract, the flush-even-on-exception policy, and whether you added a unique constraint to `fact_references`.

## Out of scope

- The author module (T-4.1) — only depends on the public interface you provide.
- Drift detection / propagation (Phase 2 / T-6.x).
- Live DB integration test — Phase 1 integration test is T-5.1.
- Modifying schema.sql or adding migrations (only flag if a unique index is critical — defer the migration to a follow-up otherwise).

## Workflow

1. Define `FactReference` + `ProvenanceRecorder` first; lock the in-memory contract.
2. Write `provenance.py` with the `@asynccontextmanager`.
3. Write `references.py` with the bulk INSERT.
4. Write the 4 unit tests; iterate until they pass.
5. Write the property tests; iterate until they pass on default Hypothesis settings.
6. `uv run ruff format . && uv run ruff check . && uv run pytest -x`.
7. Commit. Post-commit hook auto-pushes.
8. If blocked, write `.claude/plans/logs/T-4.3.BLOCKED.md` and exit.

## Notes for the agent (high-risk task owner)

- This is the moat. If `fact_references` is leaky, Phase 2's drift propagator regenerates the wrong notebooks. The property test is the safety net — make it strict.
- The dedupe-on-record contract matters: if the author module reads the same fact 3 times to build different cells, that's 3 separate `(notebook_path, cell_index)` tuples — not one. Dedupe is per-(cell_index, fact_id), not just per-fact_id.
- Flush-on-exception: think hard about this. The argument for flushing: a partial notebook is real and might be repaired and shipped. The argument against: a failed generation should leave no trace. We chose "still flush" because the moat is more valuable than the cleanliness — but you may legitimately disagree. Document your choice in the commit message.
- Don't import `with_provenance` into `__init__.py` — T-5.1 owns reconciliation of the public KB surface.
