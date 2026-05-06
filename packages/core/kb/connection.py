"""Async psycopg connection factory for the groundtruth KB."""

import os
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import psycopg
from pgvector.psycopg import register_vector_async

_DEFAULT_DATABASE_URL = "postgresql://groundtruth:groundtruth@localhost:5432/groundtruth"


@asynccontextmanager
async def get_conn() -> AsyncGenerator[psycopg.AsyncConnection, None]:
    """Yield a fresh async psycopg connection with pgvector types registered.

    Reads DATABASE_URL from the environment; falls back to the local-dev default
    (postgresql://groundtruth:groundtruth@localhost:5432/groundtruth).

    No connection pooling — Phase 1 adds pgbouncer / asyncpg pool on top.
    """
    url = os.environ.get("DATABASE_URL", _DEFAULT_DATABASE_URL)
    conn: psycopg.AsyncConnection = await psycopg.AsyncConnection.connect(url)
    try:
        await register_vector_async(conn)
        yield conn
    finally:
        await conn.close()
