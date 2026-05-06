-- groundtruth KB schema
-- Requires: Postgres 16+, pgvector, pgvectorscale
-- Safe to re-run (idempotent).

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;

-- Top-level documentation source (e.g. an SDK docs site).
CREATE TABLE IF NOT EXISTS sources (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name           text NOT NULL UNIQUE,
    base_url       text NOT NULL,
    crawler_config jsonb,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- One row per crawled URL belonging to a source.
CREATE TABLE IF NOT EXISTS source_pages (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id    uuid NOT NULL REFERENCES sources (id) ON DELETE CASCADE,
    url          text NOT NULL UNIQUE,
    content_hash text NOT NULL,  -- sha256 of canonical markdown
    markdown     text,
    html         text,
    crawled_at   timestamptz,
    etag         text
);

CREATE INDEX IF NOT EXISTS source_pages_source_id ON source_pages (source_id);

-- Atomic facts extracted from a source page.
CREATE TABLE IF NOT EXISTS facts (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_page_id uuid NOT NULL REFERENCES source_pages (id) ON DELETE CASCADE,
    kind           text NOT NULL,   -- model_string | price | code_block | signature | callout
    content        text NOT NULL,
    anchor         text,            -- URL fragment / DOM anchor for deep-linking
    context        text,            -- surrounding paragraph for faithfulness eval
    content_hash   text NOT NULL,
    embedding      vector(1024),    -- voyage-4-large output dimension
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- diskann is pgvectorscale's approximate-nearest-neighbour access method.
-- Chosen over ivfflat/hnsw because pgvectorscale's DiskANN implementation
-- provides better recall/latency trade-offs at large scale with SSD-friendly
-- graph layout.
CREATE INDEX IF NOT EXISTS facts_embedding_diskann ON facts USING diskann (embedding);
CREATE INDEX IF NOT EXISTS facts_source_page_id ON facts (source_page_id);

-- Fan-out: which notebook cells cite a fact (Phase 1 populates).
CREATE TABLE IF NOT EXISTS fact_references (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fact_id       uuid NOT NULL REFERENCES facts (id) ON DELETE CASCADE,
    notebook_path text NOT NULL,
    cell_index    int,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS fact_references_fact_id ON fact_references (fact_id);

-- Re-crawl diff events (Phase 2 populates).
CREATE TABLE IF NOT EXISTS drift_events (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fact_id          uuid NOT NULL REFERENCES facts (id) ON DELETE CASCADE,
    old_content_hash text,
    new_content_hash text,
    detected_at      timestamptz NOT NULL DEFAULT now()
);

-- DeepEval metric results (Phase 0 eval harness populates).
CREATE TABLE IF NOT EXISTS eval_results (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fact_id      uuid REFERENCES facts (id) ON DELETE SET NULL,
    metric       text NOT NULL,
    score        float NOT NULL,
    passed       bool NOT NULL,
    details      jsonb,
    evaluated_at timestamptz NOT NULL DEFAULT now()
);
