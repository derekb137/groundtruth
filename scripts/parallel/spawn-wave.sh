#!/bin/bash
# spawn-wave.sh — fan out sub-worktrees + spawn one Claude agent per task
#
# Called by the orchestrator (or manually). Reads .claude/plans/state.json + plan.md
# to determine which tasks are in the current wave, creates a sub-worktree per task,
# and spawns a headless `claude` process per task with a task-specific spec.
#
# Usage (from inside the effort worktree):
#   scripts/parallel/spawn-wave.sh --wave 1
#   scripts/parallel/spawn-wave.sh --wave 1 --task T-1   # single-task mode
#
# Each sub-worktree:
#   ../<repo>-<slug>-<taskId>/   on branch temp/<slug>-<taskId>
#
# After all tasks in the wave complete, call cherry-pick-wave.sh to merge back.

set -euo pipefail

WAVE=""
SINGLE_TASK=""

while [ $# -gt 0 ]; do
    case "$1" in
        --wave) WAVE="$2"; shift 2 ;;
        --task) SINGLE_TASK="$2"; shift 2 ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

if [ -z "$WAVE" ]; then
    echo "ERROR: --wave required"
    exit 1
fi

EFFORT_ROOT="$(git rev-parse --show-toplevel)"
SCRIPTS_DIR="$EFFORT_ROOT/scripts/parallel"
STATE_FILE="$EFFORT_ROOT/.claude/plans/state.json"

if [ ! -f "$STATE_FILE" ]; then
    echo "ERROR: not in an orchestration worktree (no $STATE_FILE)"
    exit 1
fi

# Read state.json to get slug + branch
SLUG="$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['slug'])")"
EFFORT_BRANCH="$(git branch --show-current)"
PARENT_DIR="$(dirname "$EFFORT_ROOT")"
REPO_NAME="$(basename "$EFFORT_ROOT" | sed "s/-$SLUG\$//")"

# Get tasks for this wave from state.json
TASKS=$(python3 -c "
import json, sys
state = json.load(open('$STATE_FILE'))
single = '$SINGLE_TASK'
for tid, t in state['tasks'].items():
    if t.get('wave') == $WAVE and t.get('status') == 'pending':
        if single and tid != single:
            continue
        print(tid)
")

if [ -z "$TASKS" ]; then
    echo "No pending tasks for wave $WAVE${SINGLE_TASK:+ matching $SINGLE_TASK}"
    exit 0
fi

echo "Spawning wave $WAVE — tasks: $(echo $TASKS | tr '\n' ' ')"
echo ""

# Pre-flight: file disjointness check
# (Future: parse Touches column from plan.md and warn on overlap. For MVP, trust the plan.)

# Spawn each task
for TASK_ID in $TASKS; do
    SUBWORKTREE="$PARENT_DIR/$REPO_NAME-$SLUG-$TASK_ID"
    SUB_BRANCH="temp/$SLUG-$TASK_ID"
    TASK_SPEC="$EFFORT_ROOT/.claude/plans/task-$TASK_ID.md"

    # Skip if sub-worktree already exists
    if [ -d "$SUBWORKTREE" ]; then
        echo "  $TASK_ID: sub-worktree exists at $SUBWORKTREE — skipping spawn"
        continue
    fi

    # Create sub-worktree off effort branch
    echo "  $TASK_ID: creating $SUBWORKTREE on $SUB_BRANCH"
    git worktree add "$SUBWORKTREE" -b "$SUB_BRANCH" "$EFFORT_BRANCH" >/dev/null

    # Install auto-push hook (worktree .git is a file pointing at the real gitdir)
    SUB_GITDIR="$(git -C "$SUBWORKTREE" rev-parse --git-dir)"
    mkdir -p "$SUB_GITDIR/hooks"
    cp "$SCRIPTS_DIR/auto-push-hook.sh" "$SUB_GITDIR/hooks/post-commit"
    chmod +x "$SUB_GITDIR/hooks/post-commit"

    # Pre-sync deps so the agent's verify-gate measures a complete environment.
    # Caught by tech-debt v2 T-2: a sub-agent measured mypy in a partial venv
    # (only "core" group installed) and got 338 errors; orchestrator's
    # --all-groups env had 395; sub-agent's "ratchet to 343" was rejected as
    # incorrect. Pre-sync prevents this class of env-mismatch from recurring.
    if [ -f "$SUBWORKTREE/pyproject.toml" ] && command -v uv >/dev/null 2>&1; then
        echo "  $TASK_ID: pre-syncing deps (uv sync --all-groups)"
        (cd "$SUBWORKTREE" && uv sync --all-groups >/dev/null 2>&1) || \
            echo "  WARN: uv sync failed in $SUBWORKTREE — agent may see partial env"
    fi

    # Verify task spec exists
    if [ ! -f "$TASK_SPEC" ]; then
        echo "  WARN: $TASK_SPEC not found — orchestrator should write it before spawn"
        echo "  Skipping $TASK_ID until spec exists"
        continue
    fi

    # Determine model + spawn
    MODEL=$(python3 -c "
import json
state = json.load(open('$STATE_FILE'))
print(state['tasks']['$TASK_ID'].get('model', 'sonnet'))
")

    LOG="$EFFORT_ROOT/.claude/plans/logs/$TASK_ID.log"
    mkdir -p "$EFFORT_ROOT/.claude/plans/logs"

    echo "  $TASK_ID: spawning claude (model=$MODEL) → log: $LOG"

    # Spawn headless claude in the sub-worktree
    # The orchestrator (caller) is responsible for monitoring + collecting results
    (
        cd "$SUBWORKTREE"
        nohup claude \
            --dangerously-skip-permissions \
            --model "$MODEL" \
            --print \
            "Read $TASK_SPEC for your full assignment. Execute it autonomously in this worktree (you are at $SUBWORKTREE on branch $SUB_BRANCH). Commit your changes with a clear message including 'task: $TASK_ID' in the body. The post-commit hook auto-pushes to origin/$SUB_BRANCH. When done, exit cleanly. If blocked: write reason to $EFFORT_ROOT/.claude/plans/logs/$TASK_ID.BLOCKED.md and exit." \
            >"$LOG" 2>&1 &
        echo $! > "$EFFORT_ROOT/.claude/plans/logs/$TASK_ID.pid"
    )
done

echo ""
echo "Wave $WAVE spawned. Monitor with:"
echo "  tail -f $EFFORT_ROOT/.claude/plans/logs/T-*.log"
echo ""
echo "When all tasks have committed (check sub-worktrees' git logs), run:"
echo "  scripts/parallel/cherry-pick-wave.sh --wave $WAVE"
