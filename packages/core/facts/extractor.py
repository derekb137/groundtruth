"""Haiku-batched fact extractor with a DeepEval faithfulness gate.

Pipeline per page:
  1. Ask Haiku 4.5 (single batched call, system prompt cached) to emit JSON
     facts covering the 5 supported kinds.
  2. Parse — non-JSON / preamble-wrapped responses fall back to `[]`.
  3. Faithfulness-gate each candidate against its `context`. Drop + log any
     fact that scores below the 0.85 threshold (fail-soft, never raise).
  4. Hash surviving `content` (sha256) and emit `Fact` records.

The `CrawledPage` import is lazy so this module does not require T-2.3 to land
first — unit tests construct stubs that quack the right attributes.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
from typing import TYPE_CHECKING, Any

from anthropic import AsyncAnthropic

from packages.shared.eval.faithfulness import evaluate_faithfulness

from .types import Fact, FactKind

if TYPE_CHECKING:
    from packages.core.ingestion import CrawledPage

logger = logging.getLogger(__name__)

HAIKU_MODEL_ID = "claude-haiku-4-5-20251001"
FAITHFULNESS_THRESHOLD = 0.85
MAX_TOKENS = 4096

VALID_KINDS: frozenset[str] = frozenset(
    ("model_string", "price", "code_block", "signature", "callout")
)

SYSTEM_PROMPT = """You extract atomic, verifiable facts from technical documentation.

Return ONLY a JSON array. Each element must match this schema:
  {
    "kind":    one of "model_string" | "price" | "code_block" | "signature" | "callout",
    "content": the atomic claim (e.g. "claude-sonnet-4-6", "$3 / 1M input tokens"),
    "anchor":  a URL fragment / DOM anchor for the source location, or "" if unknown,
    "context": the smallest source paragraph that supports the claim, verbatim
  }

Rules:
- ONE claim per object. Split compound sentences.
- "content" must be self-contained — a reader should not need the page to interpret it.
- "context" must be copied verbatim from the source so faithfulness can be checked.
- Cover model identifiers, prices, code blocks, function signatures, and callouts/notes.
- If the page has nothing factual, return [].
- No prose, no preamble, no trailing commentary. JSON array only.
"""


def _strip_to_json_array(raw: str) -> str:
    """Trim any preamble/suffix around the outermost JSON array.

    Haiku occasionally wraps output ('Here are the facts: [...]'); trim defensively.
    """
    start = raw.find("[")
    end = raw.rfind("]")
    if start == -1 or end == -1 or end < start:
        return ""
    return raw[start : end + 1]


def _parse_facts_payload(raw: str) -> list[dict[str, Any]]:
    """Parse Haiku's JSON output. Returns [] on any structural failure."""
    trimmed = _strip_to_json_array(raw)
    if not trimmed:
        logger.warning("fact extractor: no JSON array found in model output")
        return []
    try:
        parsed = json.loads(trimmed)
    except json.JSONDecodeError as exc:
        logger.warning("fact extractor: invalid JSON from model: %s", exc)
        return []
    if not isinstance(parsed, list):
        logger.warning("fact extractor: model output was not a list")
        return []
    out: list[dict[str, Any]] = []
    for item in parsed:
        if not isinstance(item, dict):
            continue
        kind = item.get("kind")
        content = item.get("content")
        anchor = item.get("anchor", "")
        context = item.get("context")
        if kind not in VALID_KINDS:
            continue
        if not isinstance(content, str) or not content.strip():
            continue
        if not isinstance(context, str) or not context.strip():
            continue
        if not isinstance(anchor, str):
            anchor = ""
        out.append(
            {
                "kind": kind,
                "content": content,
                "anchor": anchor,
                "context": context,
            }
        )
    return out


def _hash_content(content: str) -> str:
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


async def _call_haiku(client: AsyncAnthropic, markdown: str) -> str:
    """Single batched extraction call. System prompt is cache-controlled."""
    response = await client.messages.create(
        model=HAIKU_MODEL_ID,
        max_tokens=MAX_TOKENS,
        system=[
            {
                "type": "text",
                "text": SYSTEM_PROMPT,
                "cache_control": {"type": "ephemeral"},
            }
        ],
        messages=[{"role": "user", "content": markdown}],
    )
    parts: list[str] = []
    for block in response.content:
        text = getattr(block, "text", None)
        if isinstance(text, str):
            parts.append(text)
    return "".join(parts)


async def extract_facts(page: CrawledPage) -> list[Fact]:
    """Extract faithfulness-gated `Fact`s from a `CrawledPage`.

    Fail-soft: drops facts that fail parsing or the faithfulness gate; never raises
    on extractor-level errors (network/parse). Caller-level errors (missing API key)
    will still surface from the SDK.
    """
    api_key = os.environ["ANTHROPIC_API_KEY"]
    client = AsyncAnthropic(api_key=api_key)

    try:
        raw = await _call_haiku(client, page.markdown)
    except Exception as exc:
        logger.warning("fact extractor: Haiku call failed: %s", exc)
        return []

    candidates = _parse_facts_payload(raw)
    if not candidates:
        return []

    surviving: list[Fact] = []
    for cand in candidates:
        kind: FactKind = cand["kind"]
        content: str = cand["content"]
        context: str = cand["context"]
        anchor: str = cand["anchor"]

        score, passed = await evaluate_faithfulness(
            claim=content,
            source=context,
            threshold=FAITHFULNESS_THRESHOLD,
        )
        if not passed:
            logger.info(
                "fact extractor: dropped fact (score=%.3f < %.2f): %r",
                score,
                FAITHFULNESS_THRESHOLD,
                content,
            )
            continue

        surviving.append(
            Fact(
                kind=kind,
                content=content,
                anchor=anchor,
                context=context,
                content_hash=_hash_content(content),
            )
        )

    return surviving
