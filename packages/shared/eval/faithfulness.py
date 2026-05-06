"""DeepEval `FaithfulnessMetric` wrapper.

Runtime requirements (NOT tests — tests must mock):
  - `OPENAI_API_KEY` (or a configured DeepEval judge model) — DeepEval's default
    judge is OpenAI. If the team swaps to an Anthropic judge later, only this
    file needs to change.
  - `DEEPEVAL_TELEMETRY_OPT_OUT=YES` — silence DeepEval's telemetry pings.

The metric itself is sync, so we hop to a thread to keep the event loop free.
The return contract — `(score, passed)` — is intentionally narrow so callers
do not import DeepEval types.
"""

from __future__ import annotations

import asyncio

from deepeval.metrics import FaithfulnessMetric
from deepeval.test_case import LLMTestCase


async def evaluate_faithfulness(
    claim: str,
    source: str,
    threshold: float = 0.85,
) -> tuple[float, bool]:
    """Run DeepEval's FaithfulnessMetric on (claim, source).

    Returns:
        (score, passed) where score is in [0.0, 1.0] and
        passed = score >= threshold.
    """

    def _run() -> tuple[float, bool]:
        metric = FaithfulnessMetric(threshold=threshold)
        test_case = LLMTestCase(
            input=source,
            actual_output=claim,
            retrieval_context=[source],
        )
        metric.measure(test_case)
        return (metric.score or 0.0, metric.is_successful())

    return await asyncio.to_thread(_run)
