# Fact extractor faithfulness fixtures

Hand-authored paragraphs paired with the facts a perfect extractor would emit.
Used by `run_eval.py` to measure end-to-end Haiku + DeepEval pass-rate against
the 0.85 faithfulness threshold defined by the master plan.

## Layout

- `fixtures.jsonl` — one fixture per line: `{"paragraph": "...", "expected_facts": [{"kind": "...", "content": "..."}]}`.
  Phase 0 ships >=10 paragraphs covering all 5 supported `kind`s
  (`model_string`, `price`, `code_block`, `signature`, `callout`). Filling out
  to 50 paragraphs is a Phase 1 follow-up.
- `run_eval.py` — manual runner. **Not** wired into pytest because each
  invocation calls live Haiku (extraction) + the DeepEval judge (faithfulness),
  which would burn quota during routine `pytest` runs.

## Run

```bash
export ANTHROPIC_API_KEY=...
export OPENAI_API_KEY=...        # DeepEval default judge
export DEEPEVAL_TELEMETRY_OPT_OUT=YES

uv run python tests/evals/extractor/run_eval.py
```

Outputs an aggregate faithfulness pass-rate and a per-paragraph breakdown.

## CI

A future job may run this behind `RUN_FAITHFULNESS_EVAL=1` so it stays opt-in.
Do **not** add a pytest wrapper — keep the LLM costs explicit.
