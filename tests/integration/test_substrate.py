"""End-to-end integration test: crawl → embed → upsert → query.

Gated on @pytest.mark.integration — NOT run by plain `pytest -x`.
Run with: uv run pytest -x -m integration
"""

from __future__ import annotations

import os
import subprocess
import sys

import psycopg
import pytest

_TEST_URL = "https://docs.claude.com/en/docs/build-with-claude/overview"
_QUERY = "what is the recommended model for fast narrow tasks"


def _pg_is_ready() -> bool:
    db_url = os.environ.get(
        "DATABASE_URL",
        "postgresql://groundtruth:groundtruth@localhost:5432/groundtruth",
    )
    try:
        conn = psycopg.connect(db_url, connect_timeout=3)
        conn.close()
        return True
    except Exception:
        return False


@pytest.mark.integration
@pytest.mark.asyncio
async def test_crawl_and_query() -> None:
    if not _pg_is_ready():
        pytest.skip("requires running Postgres")

    if not (os.environ.get("VOYAGE_API_KEY") and os.environ.get("ANTHROPIC_API_KEY")):
        pytest.skip("requires VOYAGE_API_KEY + ANTHROPIC_API_KEY")

    db_url = os.environ.get(
        "DATABASE_URL",
        "postgresql://groundtruth:groundtruth@localhost:5432/groundtruth",
    )

    source_page_id: str | None = None
    source_id: str | None = None

    try:
        result = subprocess.run(
            [sys.executable, "scripts/crawl.py", _TEST_URL],
            capture_output=True,
            text=True,
            check=True,
        )
        assert "done." in result.stdout, (
            f"crawl.py unexpected output:\n{result.stdout}\n{result.stderr}"
        )

        conn = await psycopg.AsyncConnection.connect(db_url)
        try:
            cur = await conn.execute(
                "SELECT id, source_id FROM source_pages WHERE url = %s",
                (_TEST_URL,),
            )
            row = await cur.fetchone()
            assert row is not None, f"source_pages row missing for {_TEST_URL}"
            source_page_id, source_id = str(row[0]), str(row[1])

            cur = await conn.execute(
                "SELECT COUNT(*) FROM facts WHERE source_page_id = %s",
                (source_page_id,),
            )
            count_row = await cur.fetchone()
            fact_count = count_row[0]
            assert fact_count >= 10, f"expected ≥10 facts, got {fact_count}"

            result2 = subprocess.run(
                [sys.executable, "scripts/query.py", _QUERY, "--top-k", "5"],
                capture_output=True,
                text=True,
                check=True,
            )
            assert "docs.claude.com" in result2.stdout, (
                f"query.py output did not reference ingested URL:\n{result2.stdout}"
            )
        finally:
            await conn.close()

    finally:
        if source_page_id is not None:
            conn = await psycopg.AsyncConnection.connect(db_url)
            try:
                await conn.execute(
                    "DELETE FROM facts WHERE source_page_id = %s",
                    (source_page_id,),
                )
                await conn.execute(
                    "DELETE FROM source_pages WHERE id = %s",
                    (source_page_id,),
                )
                if source_id is not None:
                    await conn.execute(
                        "DELETE FROM sources WHERE id = %s",
                        (source_id,),
                    )
                await conn.commit()
            finally:
                await conn.close()
