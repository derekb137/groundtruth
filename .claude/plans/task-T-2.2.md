# Task T-2.2 — docker-compose + custom Postgres image

**Wave:** 1
**Model:** Sonnet 4.6
**Risk:** low
**Effort:** S (≤1h)
**Plan reference:** `.claude/plans/plan.md` §3 T-2.2
**Master plan reference:** `../groundtruth/.claude/plans/master-plan.md` (locked stack table — Postgres 16, pgvector 0.8.2, pgvectorscale 0.9.0)

## Goal

`docker compose up -d` brings up Postgres 16 with both `vector` (pgvector 0.8.2, bundled in the base image) and `vectorscale` (pgvectorscale 0.9.0, added via apt) extensions enabled and ready to accept connections from `localhost:5432`.

## Allowed file touches (DO NOT touch anything else)

- `docker-compose.yml` (new)
- `docker/Dockerfile.postgres` (new)
- `scripts/db/init.sql` (new)
- `scripts/db/seed.sh` (new — minimal placeholder is fine; full seed logic is Phase 1)
- `scripts/db/reset.sh` (new — `docker compose down -v && docker compose up -d`)

## Dockerfile requirements (`docker/Dockerfile.postgres`)

```dockerfile
FROM pgvector/pgvector:pg16-trixie

RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-16-pgvectorscale \
    && rm -rf /var/lib/apt/lists/*
```

The `pgvector/pgvector:pg16-trixie` image already includes pgvector 0.8.2; pgvectorscale ships in Debian Trixie's Postgres apt repo as `postgresql-16-pgvectorscale`. No third-party apt repo needed.

## docker-compose.yml requirements

- Service name: `postgres`
- Build from `./docker/Dockerfile.postgres`
- Image tag: `groundtruth/postgres:16-vectorscale` (so it's reusable across worktrees)
- Container name: `${PROJECT_NAME:-groundtruth}-postgres`
- Env (with sane defaults):
  - `POSTGRES_USER: ${POSTGRES_USER:-groundtruth}`
  - `POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-groundtruth}`
  - `POSTGRES_DB: ${POSTGRES_DB:-groundtruth}`
- Port: `${POSTGRES_PORT:-5432}:5432`
- Volume: named volume `groundtruth_pgdata` mounted at `/var/lib/postgresql/data`
- Mount `./scripts/db/init.sql` at `/docker-entrypoint-initdb.d/init.sql:ro` (Postgres image runs `/docker-entrypoint-initdb.d/*.sql` on first boot)
- Healthcheck: `pg_isready -U ${POSTGRES_USER:-groundtruth} -d ${POSTGRES_DB:-groundtruth}`, interval 5s, retries 10

Use Compose v2 syntax (no top-level `version:` key — it's deprecated).

## init.sql requirements (`scripts/db/init.sql`)

```sql
-- Runs once on first container boot via /docker-entrypoint-initdb.d.
-- Idempotent in spirit: CREATE EXTENSION IF NOT EXISTS is safe to re-run.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
```

`CASCADE` ensures vectorscale's transitive deps (notably pgvector) are created if not already present. Do NOT apply `schema.sql` from T-2.1 here — that lives in T-2.1's territory and integration tests in T-3.1 will run it explicitly.

## seed.sh + reset.sh

- `seed.sh`: stub for now. Echo `"Seed step is intentionally empty in Phase 0; Phase 1 will load fixture data."` and exit 0. Make it executable.
- `reset.sh`: tear down + recreate.
  ```sh
  #!/bin/bash
  set -euo pipefail
  cd "$(dirname "$0")/../.."
  docker compose down -v
  docker compose up -d
  echo "Postgres reset complete."
  ```
  Make it executable.

Both scripts should have `#!/bin/bash` shebang and `set -euo pipefail`.

## Acceptance

- [ ] All 5 files exist with the contents above.
- [ ] `docker-compose.yml` validates (`docker compose config` parses cleanly — you don't have to actually start docker, but the YAML must be valid).
- [ ] No top-level `version:` key in `docker-compose.yml`.
- [ ] `seed.sh` and `reset.sh` are executable (`chmod +x`).
- [ ] `uv run ruff check .` and `uv run pytest -x` still pass (this task adds no Python so they should be green by default).
- [ ] Commit message: `feat(docker): add Postgres 16 + pgvector + pgvectorscale stack (task: T-2.2)` — body briefly notes the apt package for pgvectorscale and the named-volume strategy.

## Out of scope

- Postgres tuning (shared_buffers, work_mem, etc.).
- Replication, HA, backups.
- Loading any data — that's seed.sh in Phase 1 and integration tests in T-3.1.
- CI workflow files (no `.github/workflows/` changes).
- Adding pgadmin or other supporting services.

## Workflow

1. Write the Dockerfile.
2. Write `init.sql`.
3. Write `docker-compose.yml`. Verify with `docker compose config` if Docker is available (it should be, but if not, just eyeball the YAML).
4. Write + chmod the two helper scripts.
5. `uv run ruff format . && uv run ruff check . && uv run pytest -x` (no Python changes, so these should be no-ops; run them anyway).
6. Commit with the message format above. Post-commit hook auto-pushes.
7. Exit. If blocked, write `.claude/plans/logs/T-2.2.BLOCKED.md` and exit.
