"""CLI: crawl a URL and ingest facts into the groundtruth KB."""

from __future__ import annotations

import argparse
import asyncio
import os
from urllib.parse import urlparse

import voyageai
from dotenv import load_dotenv
from packages.core import CrawlConfig, CrawledPage, Fact, crawl, extract_facts, get_conn


async def main() -> None:
    load_dotenv()

    parser = argparse.ArgumentParser(description="Crawl a URL and ingest facts.")
    parser.add_argument("url", help="URL to crawl")
    parser.add_argument(
        "--source-name",
        default=None,
        help="Source name (default: derived from URL host)",
    )
    args = parser.parse_args()

    url: str = args.url
    source_name: str = args.source_name or urlparse(url).hostname or url

    print("[crawl.py] crawling 1 URL...")

    config = CrawlConfig(seed_urls=(url,), max_pages=1)
    pages_and_facts: list[tuple[CrawledPage, list[Fact]]] = []

    async for page in crawl(config):
        facts = await extract_facts(page)
        pages_and_facts.append((page, facts))

    if not pages_and_facts:
        print("[crawl.py] no pages crawled.")
        return

    for i, (page, facts) in enumerate(pages_and_facts, 1):
        print(f"[crawl.py] page {i}: {page.url} ({len(facts)} facts kept)")

    flat_facts: list[Fact] = [f for _, facts in pages_and_facts for f in facts]
    total_facts = len(flat_facts)

    if total_facts > 0:
        voyage = voyageai.AsyncClient(api_key=os.environ["VOYAGE_API_KEY"])
        result = await voyage.embed(
            texts=[f.content for f in flat_facts],
            model="voyage-4-large",
            input_type="document",
        )
        embeddings: list[list[float]] = result.embeddings
        print(f"[crawl.py] embedded {total_facts} facts via voyage-4-large")
    else:
        embeddings = []
        print("[crawl.py] no facts to embed")

    async with get_conn() as conn:
        cur = await conn.execute(
            """
            INSERT INTO sources (name, base_url)
            VALUES (%s, %s)
            ON CONFLICT (name) DO UPDATE SET base_url = EXCLUDED.base_url
            RETURNING id
            """,
            (source_name, url),
        )
        row = await cur.fetchone()
        source_id = row[0]

        fact_idx = 0
        for page, facts in pages_and_facts:
            cur = await conn.execute(
                """
                INSERT INTO source_pages (source_id, url, content_hash, markdown, html, crawled_at)
                VALUES (%s, %s, %s, %s, %s, now())
                ON CONFLICT (url) DO UPDATE SET
                    content_hash = EXCLUDED.content_hash,
                    markdown = EXCLUDED.markdown,
                    html = EXCLUDED.html,
                    crawled_at = now()
                RETURNING id
                """,
                (source_id, page.url, page.content_hash, page.markdown, page.html),
            )
            row = await cur.fetchone()
            source_page_id = row[0]

            for fact in facts:
                embedding = embeddings[fact_idx]
                fact_idx += 1
                await conn.execute(
                    """
                    INSERT INTO facts
                        (source_page_id, kind, content, anchor, context, content_hash, embedding)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        source_page_id,
                        fact.kind,
                        fact.content,
                        fact.anchor,
                        fact.context,
                        fact.content_hash,
                        embedding,
                    ),
                )

        await conn.commit()

    print("[crawl.py] upserted to facts table")
    print("done.")


if __name__ == "__main__":
    asyncio.run(main())
