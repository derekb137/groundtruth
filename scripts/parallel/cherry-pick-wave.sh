#!/bin/bash
# cherry-pick-wave.sh — merge sub-worktree task commits onto the effort branch
#
# Usage (from inside effort worktree):
#   scripts/parallel/cherry-pick-wave.sh --wave 1
#
# For each completed task in the given wave:
#   1. Find the sub-worktree's commits since the wave's base
#   2. Cherry-pick them onto the effort branch
#   3. On conflict: mark the task BLOCKED, skip, continue with next task
#   4. After all tasks: run verify-gate.sh, report status

set -euo pipefail

WAVE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --wave) WAVE="$2"; shift 2 ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

[ -z "$WAVE" ] && { echo "ERROR: --wave required"; exit 1; }

EFFORT_ROOT="$(git rev-parse --show-toplevel)"
SCRIPTS_DIR="$EFFORT_ROOT/scripts/parallel"
STATE_FILE="$EFFORT_ROOT/.claude/plans/state.json"
PROGRESS_FILE="$EFFORT_ROOT/.claude/plans/progress.md"

if [ ! -f "$STATE_FILE" ]; then
    echo "ERROR: not in an orchestration worktree"
    exit 1
fi

SLUG="$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['slug'])")"
EFFORT_BRANCH="$(git branch --show-current)"
PARENT_DIR="$(dirname "$EFFORT_ROOT")"
REPO_NAME="$(basename "$EFFORT_ROOT" | sed "s/-$SLUG\$//")"

# Tasks in this wave with status != merged_to_branch and != blocked
TASKS=$(python3 -c "
import json
state = json.load(open('$STATE_FILE'))
for tid, t in state['tasks'].items():
    if t.get('wave') != $WAVE:
        continue
    if t.get('status') in ('merged_to_branch', 'blocked'):
        continue
    print(tid)
")

if [ -z "$TASKS" ]; then
    echo "No unmerged tasks for wave $WAVE"
    exit 0
fi

# Snapshot the effort branch tip so we can roll back per-task on failure
SAFETY_TAG="parallel/safety/wave-$WAVE-$(date +%s)"
git tag "$SAFETY_TAG" HEAD
echo "Safety tag: $SAFETY_TAG (rollback with: git reset --hard $SAFETY_TAG)"
echo ""

MERGED=()
BLOCKED=()

for TASK_ID in $TASKS; do
    SUBWORKTREE="$PARENT_DIR/$REPO_NAME-$SLUG-$TASK_ID"
    SUB_BRANCH="temp/$SLUG-$TASK_ID"

    if [ ! -d "$SUBWORKTREE" ]; then
        echo "  $TASK_ID: sub-worktree missing ($SUBWORKTREE), skipping"
        BLOCKED+=("$TASK_ID:no-worktree")
        continue
    fi

    # Find commits the sub-worktree added beyond the effort branch
    # (compare to where the sub branch was created from)
    SUB_COMMITS=$(git log "$EFFORT_BRANCH..$SUB_BRANCH" --oneline 2>/dev/null | wc -l | tr -d ' ')

    if [ "$SUB_COMMITS" = "0" ]; then
        echo "  $TASK_ID: no new commits in $SUB_BRANCH — agent may have failed silently"
        BLOCKED+=("$TASK_ID:no-commits")
        continue
    fi

    echo "  $TASK_ID: cherry-picking $SUB_COMMITS commit(s) from $SUB_BRANCH"

    # Cherry-pick all commits in order (oldest first)
    if git cherry-pick "$EFFORT_BRANCH..$SUB_BRANCH" 2>&1 | tail -5; then
        echo "    ✓ merged"
        MERGED+=("$TASK_ID")
        # Update state.json
        python3 -c "
import json
state = json.load(open('$STATE_FILE'))
state['tasks']['$TASK_ID']['status'] = 'merged_to_branch'
state['tasks']['$TASK_ID']['cherry_pick_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
json.dump(state, open('$STATE_FILE', 'w'), indent=2)
"
    else
        echo "    ✗ conflict — marking BLOCKED, restoring tip"
        git cherry-pick --abort 2>/dev/null || true
        git reset --hard "$SAFETY_TAG"
        BLOCKED+=("$TASK_ID:conflict")
        python3 -c "
import json
state = json.load(open('$STATE_FILE'))
state['tasks']['$TASK_ID']['status'] = 'blocked'
state['tasks']['$TASK_ID']['blocked_reason'] = 'cherry-pick conflict during wave $WAVE merge'
state.setdefault('blocked_tasks', []).append('$TASK_ID')
json.dump(state, open('$STATE_FILE', 'w'), indent=2)
"
    fi
done

echo ""
echo "Wave $WAVE merge summary:"
echo "  merged:  ${MERGED[*]:-none}"
echo "  blocked: ${BLOCKED[*]:-none}"
echo ""

# Run verification gate
echo "Running verification gate..."
if "$SCRIPTS_DIR/verify-gate.sh"; then
    echo "✓ Wave $WAVE gate PASSED"
    # Push effort branch
    git push origin "$EFFORT_BRANCH" --no-verify >/dev/null 2>&1 || \
        echo "warning: push failed, do it manually"
else
    echo "✗ Wave $WAVE gate FAILED — manual investigation required"
    echo "  Rollback: git reset --hard $SAFETY_TAG"
    exit 1
fi
