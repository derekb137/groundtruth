#!/bin/bash
# verify-gate.sh — run the standard quality gate
#
# Usage: scripts/parallel/verify-gate.sh
#
# Exit 0 if all gates pass, non-zero otherwise.
# Per-repo gate set is configured by:
#   - .claude/plans/verify-gate.local.sh   (if present, sourced for overrides)
#
# Default gates:
#   - ruff check
#   - mypy (with ceiling check via env MYPY_CEILING)
#   - pytest (with --tb=short for readable output)
#
# Each gate's pass/fail is reported. First failure does NOT short-circuit —
# we want to see all gate results, not just the first one to fail.

set +e  # don't exit on first failure; collect all results

# Belt-and-suspenders: prevent `uv run` from auto-syncing the venv. The venv
# was set up by spawn-wave.sh with `uv sync --all-groups`. If `uv run` is
# allowed to re-sync, it defaults to lockfile groups only — losing dev/etl
# deps (bcrypt, mcp, anthropic, dagster, etc.) and breaking pytest collection.
# Caught during 5-concurrent-orchestrator stress test on 2026-05-04.
# We also pass --no-sync explicitly to every uv run below as primary defense.
export UV_NO_SYNC=1

EFFORT_ROOT="$(git rev-parse --show-toplevel)"
PASS=0
FAIL=0
RESULTS=()

# Per-repo overrides (e.g., custom test command, additional gates)
LOCAL_GATE="$EFFORT_ROOT/.claude/plans/verify-gate.local.sh"
if [ -f "$LOCAL_GATE" ]; then
    # shellcheck disable=SC1090
    source "$LOCAL_GATE"
fi

run_gate() {
    local name="$1"
    local cmd="$2"
    echo ""
    echo "──────────── $name ────────────"
    echo "$ $cmd"
    if eval "$cmd"; then
        RESULTS+=("✓ $name")
        PASS=$((PASS + 1))
    else
        RESULTS+=("✗ $name")
        FAIL=$((FAIL + 1))
    fi
}

# --- ruff ---
if command -v uv >/dev/null && [ -f pyproject.toml ]; then
    run_gate "ruff" "uv run --no-sync ruff check ."
elif command -v ruff >/dev/null; then
    run_gate "ruff" "ruff check ."
fi

# --- mypy with ceiling ---
MYPY_CEILING="${MYPY_CEILING:-}"  # if unset, just runs mypy without ceiling check
if command -v uv >/dev/null && [ -f pyproject.toml ]; then
    if [ -n "$MYPY_CEILING" ]; then
        run_gate "mypy (≤ $MYPY_CEILING errors)" "errors=\$(uv run --no-sync mypy src/ 2>&1 | grep -E '^Found [0-9]+ errors?' | grep -oE '[0-9]+' | head -1); [ -n \"\$errors\" ] && [ \"\$errors\" -le $MYPY_CEILING ] && echo \"mypy: \$errors errors (ceiling $MYPY_CEILING)\""
    else
        run_gate "mypy" "uv run --no-sync mypy src/ 2>&1 | tail -1"
    fi
fi

# --- pytest ---
PYTEST_ARGS="${PYTEST_ARGS:-}"
if command -v uv >/dev/null && [ -f pyproject.toml ]; then
    run_gate "pytest" "uv run --no-sync pytest --tb=short -q $PYTEST_ARGS"
elif command -v pytest >/dev/null; then
    run_gate "pytest" "pytest --tb=short -q $PYTEST_ARGS"
fi

# --- migration round-trip (when migrations changed) ---
# Check committed changes vs parent; fall back to staged/unstaged on fresh worktrees
# that have no HEAD~1 (new branch with a single commit or no commits at all).
_mig_committed=$(git diff --name-only HEAD~1..HEAD -- 'src/distru_integrations/api/migrations/versions/*.py' 2>/dev/null || true)
_mig_staged=$(git diff --cached --name-only -- 'src/distru_integrations/api/migrations/versions/*.py' 2>/dev/null || true)
_mig_unstaged=$(git diff --name-only -- 'src/distru_integrations/api/migrations/versions/*.py' 2>/dev/null || true)
_migration_files=$(printf '%s\n%s\n%s' "$_mig_committed" "$_mig_staged" "$_mig_unstaged" | sort -u | grep -v '^$' || true)

if [ -n "$_migration_files" ]; then
    echo ""
    echo "Migration files detected in diff:"
    printf '%s\n' "$_migration_files" | sed 's/^/  /'

    # Determine DB availability: Docker present and running, or external Postgres reachable
    _db_available=0
    if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
        _db_available=1
    elif [ -n "$DATABASE_HOST" ] && command -v pg_isready >/dev/null 2>&1 && pg_isready -h "$DATABASE_HOST" >/dev/null 2>&1; then
        _db_available=1
    fi

    if [ "$_db_available" -eq 1 ]; then
        _alembic_roundtrip="uv run --no-sync alembic upgrade head"
        _alembic_roundtrip="$_alembic_roundtrip && uv run --no-sync alembic downgrade -1"
        _alembic_roundtrip="$_alembic_roundtrip && uv run --no-sync alembic upgrade head"
        run_gate "migration round-trip" "$_alembic_roundtrip"
    else
        echo "NOTICE: migration round-trip skipped — DB unavailable (Docker not running, DATABASE_HOST unset or unreachable)."
        echo "  Re-run locally with Docker to exercise the full alembic round-trip."
        RESULTS+=("~ migration-roundtrip (DB unavailable, skipped)")
    fi
fi

# --- repo-specific golden-file checks (if present) ---
if [ -x "$EFFORT_ROOT/scripts/refactor/check_golden_files.py" ]; then
    run_gate "golden-files" "uv run --no-sync python scripts/refactor/check_golden_files.py"
fi
if [ -x "$EFFORT_ROOT/scripts/refactor/check_api_shape.py" ]; then
    run_gate "api-shape" "uv run --no-sync python scripts/refactor/check_api_shape.py"
fi

# --- summary ---
echo ""
echo "════════════ verify-gate summary ════════════"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "  ─────────────"
echo "  $PASS passed, $FAIL failed"
echo ""

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
