"""Unit tests for `packages.core.facts.extractor`.

All LLM calls (Haiku + DeepEval judge) are mocked - these tests never touch
the network. The faithfulness runner in `tests/evals/extractor/` is invoked
manually and is not collected by pytest.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any

import pytest
from packages.core.facts import Fact, extract_facts
from packages.core.facts import extractor as extractor_mod


@dataclass
class _CrawledPageStub:
    url: str
    markdown: str
    content_hash: str


def _haiku_response(text: str) -> Any:
    """Minimal stand-in for `anthropic.types.Message`."""

    class _Block:
        def __init__(self, t: str) -> None:
            self.text = t

    class _Resp:
        def __init__(self, t: str) -> None:
            self.content = [_Block(t)]

    return _Resp(text)


class _FakeMessages:
    def __init__(self, payload: str) -> None:
        self._payload = payload

    async def create(self, **_kwargs: Any) -> Any:
        return _haiku_response(self._payload)


class _FakeClient:
    def __init__(self, payload: str) -> None:
        self.messages = _FakeMessages(payload)


def _patch_anthropic(monkeypatch: pytest.MonkeyPatch, payload: str) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    monkeypatch.setattr(
        extractor_mod,
        "AsyncAnthropic",
        lambda **_kwargs: _FakeClient(payload),
    )


@pytest.mark.asyncio
async def test_extractor_drops_below_threshold(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = (
        "["
        '{"kind": "model_string", "content": "claude-sonnet-4-6",'
        ' "anchor": "#models", "context": "Sonnet 4.6 is claude-sonnet-4-6."},'
        '{"kind": "price", "content": "$3 per 1M input tokens",'
        ' "anchor": "#pricing", "context": "Sonnet costs $3 per 1M input tokens."}'
        "]"
    )
    _patch_anthropic(monkeypatch, payload)

    scores = iter([(0.9, True), (0.5, False)])

    async def fake_score(claim: str, source: str, threshold: float = 0.85) -> tuple[float, bool]:
        return next(scores)

    monkeypatch.setattr(extractor_mod, "evaluate_faithfulness", fake_score)

    page = _CrawledPageStub(url="https://x", markdown="hello", content_hash="abc")
    facts = await extract_facts(page)

    assert len(facts) == 1
    assert facts[0].content == "claude-sonnet-4-6"
    assert facts[0].kind == "model_string"


@pytest.mark.asyncio
async def test_extractor_handles_invalid_json(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    _patch_anthropic(monkeypatch, "this is not json at all, just prose")

    async def fake_score(*_a: Any, **_k: Any) -> tuple[float, bool]:
        raise AssertionError("faithfulness must not be called when parsing fails")

    monkeypatch.setattr(extractor_mod, "evaluate_faithfulness", fake_score)

    page = _CrawledPageStub(url="https://x", markdown="hello", content_hash="abc")
    with caplog.at_level("WARNING", logger="packages.core.facts.extractor"):
        facts = await extract_facts(page)

    assert facts == []
    assert any("fact extractor" in rec.message for rec in caplog.records)


@pytest.mark.asyncio
async def test_extractor_returns_empty_for_empty_page(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_anthropic(monkeypatch, "[]")

    async def fake_score(*_a: Any, **_k: Any) -> tuple[float, bool]:
        raise AssertionError("faithfulness must not be called when no candidates")

    monkeypatch.setattr(extractor_mod, "evaluate_faithfulness", fake_score)

    page = _CrawledPageStub(url="https://x", markdown="", content_hash="abc")
    facts = await extract_facts(page)

    assert facts == []


@pytest.mark.asyncio
async def test_fact_content_hash_is_stable(monkeypatch: pytest.MonkeyPatch) -> None:
    content = "claude-haiku-4-5-20251001"
    payload = (
        "["
        f'{{"kind": "model_string", "content": "{content}",'
        f' "anchor": "", "context": "Haiku 4.5 ships as {content}."}}'
        "]"
    )

    async def always_pass(*_a: Any, **_k: Any) -> tuple[float, bool]:
        return (0.95, True)

    monkeypatch.setattr(extractor_mod, "evaluate_faithfulness", always_pass)

    _patch_anthropic(monkeypatch, payload)
    facts_a = await extract_facts(_CrawledPageStub(url="https://x", markdown="m", content_hash="h"))

    _patch_anthropic(monkeypatch, payload)
    facts_b = await extract_facts(_CrawledPageStub(url="https://y", markdown="m", content_hash="h"))

    assert len(facts_a) == 1
    assert len(facts_b) == 1
    assert facts_a[0].content_hash == facts_b[0].content_hash
    assert facts_a[0].content_hash == hashlib.sha256(content.encode("utf-8")).hexdigest()
    assert isinstance(facts_a[0], Fact)
