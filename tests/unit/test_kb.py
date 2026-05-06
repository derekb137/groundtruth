"""Unit tests for packages.core.kb — no live DB required."""

import inspect
import re
from pathlib import Path


def test_schema_sql_has_all_tables() -> None:
    schema = Path("packages/core/kb/schema.sql").read_text()
    tables = ["sources", "source_pages", "facts", "fact_references", "drift_events", "eval_results"]
    for table in tables:
        assert f"CREATE TABLE IF NOT EXISTS {table}" in schema, f"Missing table: {table}"


def test_schema_sql_has_diskann_index() -> None:
    schema = Path("packages/core/kb/schema.sql").read_text()
    assert "USING diskann" in schema


def test_migration_mirrors_schema() -> None:
    schema = Path("packages/core/kb/schema.sql").read_text()
    migration = Path("packages/core/kb/migrations/0001_initial.sql").read_text()
    assert schema == migration


def test_get_conn_is_async_context_manager() -> None:
    from packages.core.kb import get_conn

    # get_conn must be decorated with @asynccontextmanager — verify it exposes
    # __aenter__ / __aexit__ when called (without actually connecting).
    cm = get_conn()
    assert hasattr(cm, "__aenter__")
    assert hasattr(cm, "__aexit__")


def test_get_conn_signature() -> None:
    from packages.core.kb.connection import get_conn

    sig = inspect.signature(get_conn)
    assert len(sig.parameters) == 0


def test_schema_uses_extensions() -> None:
    schema = Path("packages/core/kb/schema.sql").read_text()
    assert re.search(r"CREATE EXTENSION IF NOT EXISTS vector", schema)
    assert re.search(r"CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE", schema)
