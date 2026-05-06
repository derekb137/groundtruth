"""CLI: query the groundtruth KB and return top-k facts with provenance URLs."""

from __future__ import annotations

import argparse
import asyncio
import os

import voyageai
from dotenv import load_dotenv
from packages.core import get_conn


async def main() -> None:
    load_dotenv()

    parser = argparse.ArgumentParser(description="Query the groundtruth KB.")
    parser.add_argument("query_text", help="Query text")
    parser.add_argument("--top-k", type=int, default=10, help="Number of results (default: 10)")
    parser.add_argument("--source-name", default=None, help="Filter by source name")
    args = parser.parse_args()

    query_text: str = args.query_text
    top_k: int = args.top_k

    print("[query.py] embedding query...")

    voyage = voyageai.AsyncClient(api_key=os.environ["VOYAGE_API_KEY"])
    result = await voyage.embed(
        texts=[query_text],
        model="voyage-4-large",
        input_type="query",
    )
    query_embedding: list[float] = result.embeddings[0]

    async with get_conn() as conn:
        cur = await conn.execute(
            """
            SELECT
                f.kind,
                f.content,
                f.anchor,
                sp.url,
                1 - (f.embedding <=> %s::vector) AS similarity
            FROM facts f
            JOIN source_pages sp ON f.source_page_id = sp.id
            ORDER BY f.embedding <=> %s::vector
            LIMIT %s
            """,
            (query_embedding, query_embedding, top_k),
        )
        rows = await cur.fetchall()

    print(f"[query.py] top {top_k} facts:")
    for i, row in enumerate(rows, 1):
        kind, content, _anchor, url, similarity = row
        short = content[:80] + "..." if len(content) > 80 else content
        print(f'  {i}. ({kind}, {similarity:.3f}) "{short}" → {url}')


if __name__ == "__main__":
    asyncio.run(main())
