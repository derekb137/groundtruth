"""Fact data types — atomic claims extracted from a CrawledPage.

`Fact` is intentionally tiny and frozen so it slots cleanly into hash/equality
checks downstream (drift detection, dedup, persistence). The faithfulness gate
runs against `content` vs `context`; `anchor` lets the notebook layer surface a
deep link back to the source.
"""

from dataclasses import dataclass
from typing import Literal

FactKind = Literal["model_string", "price", "code_block", "signature", "callout"]


@dataclass(frozen=True, slots=True)
class Fact:
    kind: FactKind
    content: str
    anchor: str
    context: str
    content_hash: str
