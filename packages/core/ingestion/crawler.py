"""Crawl4AI-backed web crawler that yields typed CrawledPage records."""

import hashlib
import logging
import re
from collections.abc import AsyncIterator
from dataclasses import dataclass

from crawl4ai import (
    AsyncWebCrawler,
    BrowserConfig,
    CrawlerRunConfig,
    DefaultMarkdownGenerator,
    PruningContentFilter,
)

_log = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class CrawledPage:
    url: str
    markdown: str
    html: str
    content_hash: str


@dataclass(frozen=True, slots=True)
class CrawlConfig:
    seed_urls: tuple[str, ...]
    max_pages: int = 50
    pruning_threshold: float = 0.4
    headless: bool = True


def _canonicalize(text: str) -> str:
    """Lowercase and collapse whitespace runs to a single space."""
    return re.sub(r"\s+", " ", text.lower()).strip()


async def crawl(config: CrawlConfig) -> AsyncIterator[CrawledPage]:
    """Yield CrawledPage records for each successfully crawled seed URL."""
    browser_cfg = BrowserConfig(headless=config.headless)
    content_filter = PruningContentFilter(threshold=config.pruning_threshold)
    md_generator = DefaultMarkdownGenerator(content_filter=content_filter)
    run_config = CrawlerRunConfig(markdown_generator=md_generator)

    async with AsyncWebCrawler(config=browser_cfg) as crawler:
        results = await crawler.arun_many(urls=list(config.seed_urls), config=run_config)
        for result in results:
            if not result.success:
                _log.warning("Skipping failed crawl result: %s", result.url)
                continue
            md_result = result.markdown
            if md_result is None:
                _log.warning("Skipping result with no markdown object: %s", result.url)
                continue
            text = md_result.fit_markdown or md_result.raw_markdown
            if not text:
                _log.warning("Skipping result with empty markdown: %s", result.url)
                continue
            content_hash = hashlib.sha256(_canonicalize(text).encode()).hexdigest()
            yield CrawledPage(
                url=result.url,
                markdown=text,
                html=result.html,
                content_hash=content_hash,
            )
