-- Runs once on first container boot via /docker-entrypoint-initdb.d.
-- Idempotent in spirit: CREATE EXTENSION IF NOT EXISTS is safe to re-run.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
