# Task T-2.4 — Fact extractor + DeepEval faithfulness gate

**Wave:** 1
**Model:** Opus 4.7 (you are Opus — design-heavy + high-risk)
**Risk:** high
**Effort:** L (3+h)
**Plan reference:** `.claude/plans/plan.md` §3 T-2.4
**Master plan reference:** `../groundtruth/.claude/plans/master-plan.md` — DeepEval `FaithfulnessMetric` at threshold 0.85, Haiku 4.5 for batch extraction, faithfulness applied at fact extraction (and again at notebook generation in Phase 1).

## Goal

Given a `CrawledPage` (the type T-2.3 defines), return a list of `Fact` objects whose `content` is faithful (DeepEval `FaithfulnessMetric ≥ 0.85`) to its `context` (the source paragraph). Fail-soft at extraction: facts that fail the gate are dropped + logged, not raised.

## Allowed file touches (DO NOT touch anything else)

- `packages/core/facts/extractor.py` (new)
- `packages/core/facts/types.py` (new)
- `packages/core/facts/__init__.py` (re-exports only)
- `packages/shared/eval/faithfulness.py` (new — wraps DeepEval)
- `tests/unit/test_extractor.py` (new — mock the LLM + DeepEval)
- `tests/evals/extractor/` (new directory — fixtures + a runner; **mark fixtures-only — do NOT add a pytest that calls live LLMs in this task; the eval runner is invoked separately by the orchestrator/dev when ready**)

**You may not edit `packages/core/ingestion/crawler.py`** (T-2.3 owns it). If you need `CrawledPage`, import it: `from packages.core.ingestion import CrawledPage`. T-2.3 runs in parallel — its file may not exist yet at task start. Solution: define `Fact` independently and import `CrawledPage` lazily inside the extractor function or behind a `TYPE_CHECKING` guard, so your unit tests can construct a stub object that quacks like `CrawledPage` (just `.url`, `.markdown`, `.content_hash` attributes).

## Types (`packages/core/facts/types.py`)

```python
from dataclasses import dataclass
from typing import Literal

FactKind = Literal["model_string", "price", "code_block", "signature", "callout"]

@dataclass(frozen=True, slots=True)
class Fact:
    kind: FactKind
    content: str          # the atomic claim, e.g. "claude-sonnet-4-6"
    anchor: str           # URL fragment / DOM anchor, e.g. "#models" or "" if unknown
    context: str          # the source paragraph used for faithfulness eval
    content_hash: str     # sha256 of content (for drift detection)
```

## Extractor (`packages/core/facts/extractor.py`)

```python
async def extract_facts(page: CrawledPage) -> list[Fact]: ...
```

Behavior:

1. Call **Haiku 4.5** (`claude-haiku-4-5-20251001`) via the Anthropic SDK to extract atomic facts in a single batch from the page markdown. Use prompt caching on the system prompt (`cache_control={"type": "ephemeral"}`) — the system prompt is reused across pages.
2. The prompt instructs Haiku to return JSON: a list of `{kind, content, anchor, context}` objects covering model names, prices, code blocks, function signatures, and callouts/notes. Fall back to an empty list on parse failure (log + return `[]`, do not raise).
3. For each candidate fact, run `evaluate_faithfulness(claim=fact.content, source=fact.context, threshold=0.85)`. Drop facts that score below 0.85. Log dropped facts with their score.
4. Compute `content_hash = sha256(content.encode()).hexdigest()` per surviving fact.
5. Return the surviving `Fact` list.

Type hints everywhere. Use `anthropic.AsyncAnthropic` (already a dep). Read API key from `os.environ["ANTHROPIC_API_KEY"]` — do NOT hardcode.

## Faithfulness wrapper (`packages/shared/eval/faithfulness.py`)

```python
async def evaluate_faithfulness(claim: str, source: str, threshold: float = 0.85) -> tuple[float, bool]:
    """Returns (score, passed). Score in [0.0, 1.0]; passed = score >= threshold."""
```

- Use `deepeval.metrics.FaithfulnessMetric(threshold=threshold)` and `deepeval.test_case.LLMTestCase(input=source, actual_output=claim, retrieval_context=[source])`.
- DeepEval's metric is sync; wrap the call in `asyncio.to_thread(...)` so it doesn't block the event loop.
- Return `(metric.score or 0.0, metric.is_successful())`.
- DeepEval will use `OPENAI_API_KEY` by default for its judge; document in a top-of-file comment that `DEEPEVAL_TELEMETRY_OPT_OUT=YES` and `OPENAI_API_KEY` (or a configured DeepEval model) are required at runtime — but tests must mock this so they don't call live APIs.

## Tests (`tests/unit/test_extractor.py`)

Mock everything — no live LLM calls.

1. `test_extractor_drops_below_threshold` — patch `evaluate_faithfulness` to return `(0.5, False)` for one fact and `(0.9, True)` for another; assert only the high-score fact survives.
2. `test_extractor_handles_invalid_json` — patch the Anthropic call to return non-JSON text; assert `extract_facts` returns `[]` and logs a warning (use `caplog`).
3. `test_extractor_returns_empty_for_empty_page` — patch the Anthropic call to return `"[]"`; assert empty list.
4. `test_fact_content_hash_is_stable` — construct two `Fact` objects with the same `content` after running them through the extractor's hash logic; assert hashes match.

You will need to monkeypatch `anthropic.AsyncAnthropic` (or your wrapper's client) to control the Haiku response. Use `pytest.MonkeyPatch` or `unittest.mock`.

## Eval fixtures (`tests/evals/extractor/`)

Create:

- `tests/evals/extractor/README.md` — short doc explaining the dataset is 50 paragraphs (or as many as you author; ≥10 is acceptable for Phase 0; full 50 is a Phase 1 followup) with expected facts + run instructions (`uv run python tests/evals/extractor/run_eval.py`).
- `tests/evals/extractor/fixtures.jsonl` — JSONL where each line is `{"paragraph": "...", "expected_facts": [{"kind": "...", "content": "..."}]}`. Author at minimum 10 paragraphs covering all 5 kinds (model_string, price, code_block, signature, callout). Real text from Anthropic docs is fine — copy short snippets.
- `tests/evals/extractor/run_eval.py` — a script (NOT a pytest) that loads the JSONL, runs `extract_facts` against each paragraph (wrap each as a fake `CrawledPage`-shaped object), and prints aggregate faithfulness pass-rate. Mark with a top-line comment: `# Run manually — calls live Haiku + DeepEval. Do NOT add a pytest wrapper.`

**Do not add a `pytest` test that runs the eval suite** — DeepEval calls would burn the orchestrator's quota during routine `pytest` runs. The eval runner is invoked manually (or by a future CI job that gates by env var).

## __init__.py

Re-export `Fact`, `FactKind`, `extract_facts`. Nothing more.

## Acceptance

- [ ] `Fact` + `FactKind` defined per spec.
- [ ] `extract_facts` implemented with the Haiku call + faithfulness gate + drop-and-log behavior.
- [ ] `evaluate_faithfulness` wraps DeepEval correctly and is async-friendly.
- [ ] All 4 unit tests pass with mocks (no network).
- [ ] Eval fixtures (`fixtures.jsonl`) and `run_eval.py` exist; running `run_eval.py` is NOT required for this task to land.
- [ ] `uv run ruff check packages tests` passes.
- [ ] `uv run ruff format --check packages tests` passes.
- [ ] `uv run pytest -x` passes (only the new unit tests run; the eval runner is not a pytest).
- [ ] Commit message: `feat(facts): add Haiku-batched extractor with DeepEval faithfulness gate (task: T-2.4)` — body should briefly note the fail-soft drop policy, the 0.85 threshold, and the manual-only eval runner pattern.

## Out of scope

- Image fact extraction (Phase 1+).
- Embedding generation — folded into T-3.1's persist step.
- Drift detection (Phase 2).
- `fact_references` recording (Phase 1, T-4.3).
- Wiring the extractor into a CLI — T-3.1.
- Adding new dependencies (`anthropic`, `deepeval` already in `pyproject.toml`).
- Live LLM calls in tests (forbidden for this task; mock everything).

## Workflow

1. Read the master plan's stack table to confirm Haiku 4.5 ID, DeepEval threshold, etc.
2. Define `types.py` first (pure data, easy to test).
3. Write `evaluate_faithfulness` (small, focused).
4. Write `extract_facts` with Haiku calls + the gate.
5. Write the 4 unit tests with mocks; iterate until they pass.
6. Author fixtures + `run_eval.py` (no execution required — just a working script).
7. `uv run ruff format . && uv run ruff check . && uv run pytest -x`.
8. Commit with the message format above. Post-commit hook auto-pushes.
9. Exit cleanly. If blocked (e.g., DeepEval API differs from expected), write `.claude/plans/logs/T-2.4.BLOCKED.md` with specifics and exit.

## Risk notes (for you, the high-risk task owner)

- DeepEval can be opinionated about the judge LLM. The wrapper sets a clean contract — score + passed — so the rest of the codebase doesn't depend on DeepEval internals. If DeepEval's `FaithfulnessMetric` constructor signature differs from `(threshold=...)` in the installed version, adapt and document in a comment.
- The Haiku batch prompt is the highest-risk artifact. Keep it short, structured (JSON output schema spelled out), and lean on Haiku's strength (instruction-following on narrow extraction tasks). Use `system` for the schema + role; `user` for the page markdown. Cache the system block.
- If Haiku returns JSON with extra commentary (preamble like "Here are the facts..."), strip everything before the first `[` and after the last `]` before `json.loads`.
- DO NOT lower the 0.85 threshold to make tests pass. The gate is part of the spec.
