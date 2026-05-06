"""Fact extraction — faithfulness-gated atomic claims from CrawledPages."""

from .extractor import extract_facts
from .types import Fact, FactKind

__all__ = ["Fact", "FactKind", "extract_facts"]
