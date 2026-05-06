"""Unit tests for packages.core.ingestion.crawler (no network calls)."""

from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

from packages.core.ingestion.crawler import CrawlConfig, CrawledPage, _canonicalize, crawl

FIXTURES = Path(__file__).parent.parent / "fixtures"
SAMPLE_HTML = (FIXTURES / "sample_page.html").read_text()


def _make_md_result(fit_markdown: str | None = None, raw_markdown: str = "") -> MagicMock:
    md = MagicMock()
    md.fit_markdown = fit_markdown
    md.raw_markdown = raw_markdown
    return md


def _make_crawl_result(
    url: str = "https://example.com",
    success: bool = True,
    fit_markdown: str | None = None,
    raw_markdown: str = "",
    html: str = "<html/>",
) -> MagicMock:
    result = MagicMock()
    result.url = url
    result.success = success
    result.html = html
    result.markdown = _make_md_result(fit_markdown=fit_markdown, raw_markdown=raw_markdown)
    return result


def _patch_crawler(results: list) -> patch:
    """Return a context-manager patch that makes AsyncWebCrawler.arun_many return results."""
    mock_crawler = MagicMock()
    mock_crawler.__aenter__ = AsyncMock(return_value=mock_crawler)
    mock_crawler.__aexit__ = AsyncMock(return_value=False)
    mock_crawler.arun_many = AsyncMock(return_value=results)
    return patch("packages.core.ingestion.crawler.AsyncWebCrawler", return_value=mock_crawler)


async def test_crawl_yields_pages_with_stable_hash() -> None:
    content = SAMPLE_HTML
    config = CrawlConfig(seed_urls=("https://example.com",))

    with _patch_crawler([_make_crawl_result(fit_markdown=content, html="<html/>")]):
        pages_first = [p async for p in crawl(config)]

    with _patch_crawler([_make_crawl_result(fit_markdown=content, html="<html/>")]):
        pages_second = [p async for p in crawl(config)]

    assert len(pages_first) == 1
    assert len(pages_second) == 1
    assert pages_first[0].content_hash == pages_second[0].content_hash
    assert isinstance(pages_first[0], CrawledPage)


async def test_crawl_skips_empty_markdown() -> None:
    config = CrawlConfig(seed_urls=("https://example.com",))

    # fit_markdown=None, raw_markdown="" → both empty → should be skipped
    with _patch_crawler([_make_crawl_result(fit_markdown=None, raw_markdown="")]):
        pages = [p async for p in crawl(config)]

    assert pages == []


async def test_crawl_skips_failed_results() -> None:
    config = CrawlConfig(seed_urls=("https://example.com",))

    with _patch_crawler([_make_crawl_result(success=False, fit_markdown="some content")]):
        pages = [p async for p in crawl(config)]

    assert pages == []


def test_canonicalize_collapses_whitespace() -> None:
    assert _canonicalize("Hello   World\n\tFoo") == "hello world foo"
    assert _canonicalize("  LEADING AND TRAILING  ") == "leading and trailing"
    assert _canonicalize("already clean") == "already clean"
    # Same input → same output (stability)
    text = "Some   TEXT\n with   SPACES"
    assert _canonicalize(text) == _canonicalize(text)
