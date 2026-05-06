# Run manually - calls live Haiku + DeepEval. Do NOT add a pytest wrapper.
"""Manual faithfulness runner for `extract_facts`.

Reads `fixtures.jsonl`, treats each `paragraph` as a single-page markdown body,
runs the full extractor (Haiku + DeepEval gate), and prints aggregate stats.

Required env: ANTHROPIC_API_KEY, OPENAI_API_KEY, DEEPEVAL_TELEMETRY_OPT_OUT=YES.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from pathlib import Path

from packages.core.facts import extract_facts

FIXTURES_PATH = Path(__file__).parent / "fixtures.jsonl"


@dataclass
class _PageStub:
    url: str
    markdown: str
    content_hash: str


def _load_fixtures() -> list[dict[str, object]]:
    with FIXTURES_PATH.open("r", encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


async def _run_one(idx: int, paragraph: str) -> tuple[int, int]:
    page = _PageStub(
        url=f"fixture://{idx}",
        markdown=paragraph,
        content_hash=f"fixture-{idx}",
    )
    facts = await extract_facts(page)
    return (idx, len(facts))


async def main() -> None:
    fixtures = _load_fixtures()
    print(f"loaded {len(fixtures)} fixtures from {FIXTURES_PATH}")

    total_emitted = 0
    total_expected = 0

    for idx, fx in enumerate(fixtures):
        paragraph = str(fx["paragraph"])
        expected = fx.get("expected_facts", [])
        expected_n = len(expected) if isinstance(expected, list) else 0

        _, emitted_n = await _run_one(idx, paragraph)
        total_emitted += emitted_n
        total_expected += expected_n

        print(f"  fixture[{idx:02d}] expected={expected_n:>2} emitted_after_gate={emitted_n:>2}")

    if total_expected:
        rate = total_emitted / total_expected
        print(
            f"\naggregate: emitted_after_gate={total_emitted} / "
            f"expected={total_expected}  ({rate:.1%})"
        )
    else:
        print("\naggregate: no expected facts in dataset")


if __name__ == "__main__":
    asyncio.run(main())
