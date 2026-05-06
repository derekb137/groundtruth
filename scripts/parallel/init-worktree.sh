#!/bin/bash
# init-worktree.sh — create a new isolated effort worktree
#
# Usage:
#   scripts/parallel/init-worktree.sh <slug> [--base <branch>] [--add-dir <path>]...
#
# Examples:
#   scripts/parallel/init-worktree.sh tech-debt-v2
#   scripts/parallel/init-worktree.sh feat-mcp-redesign --base main
#   scripts/parallel/init-worktree.sh deploy-canary-rebuild --add-dir ~/src/github/distru/distru-integrations-deploy
#
# Creates:
#   ../<repo>-<slug>/                       — the effort worktree on chore/<slug>-v1 (or feat/<slug>)
#   ../<repo>-<slug>/.claude/plans/         — plan, state, progress, USER_NOTES
#   ../<repo>-<slug>/.claude/settings.local.json
#   ../<repo>-<slug>/launch.sh              — autonomous launcher
#   ../<repo>-<slug>/EMERGENCY.md           — rollback recipes
#
# Idempotent: safe to re-run if previous attempt failed mid-way.

set -euo pipefail

# ----- arg parsing -----
if [ $# -lt 1 ]; then
    echo "usage: $0 <slug> [--base <branch>] [--add-dir <path>]..."
    exit 1
fi

SLUG="$1"; shift
BASE_BRANCH="develop"
ADD_DIRS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE_BRANCH="$2"; shift 2 ;;
        --add-dir) ADD_DIRS="$ADD_DIRS $2"; shift 2 ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

# Validate slug (kebab-case, no slashes, no spaces)
if ! [[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
    echo "ERROR: slug must be kebab-case (lowercase, hyphens, no leading/trailing dash)"
    exit 1
fi

# ----- resolve paths -----
REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$REPO_ROOT")"
PARENT_DIR="$(dirname "$REPO_ROOT")"
WORKTREE_PATH="$PARENT_DIR/$REPO_NAME-$SLUG"
BRANCH="chore/$SLUG"
SCRIPTS_DIR="$REPO_ROOT/scripts/parallel"
TEMPLATES_DIR="$SCRIPTS_DIR/templates"

# Effort title (humanized slug)
EFFORT_TITLE="$(echo "$SLUG" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1))substr($i,2)} 1')"

# ----- pre-flight -----
if [ -d "$WORKTREE_PATH" ]; then
    echo "ERROR: worktree path already exists: $WORKTREE_PATH"
    echo "       remove it first: scripts/parallel/cleanup.sh $SLUG --force"
    exit 1
fi

if ! git fetch origin "$BASE_BRANCH" 2>&1 | grep -v 'up to date' >/dev/null; then :; fi

BASE_COMMIT="$(git rev-parse --short=9 "origin/$BASE_BRANCH")"

# ----- create worktree -----
echo "Creating worktree: $WORKTREE_PATH (branch $BRANCH off origin/$BASE_BRANCH @ $BASE_COMMIT)"
git worktree add "$WORKTREE_PATH" -b "$BRANCH" "origin/$BASE_BRANCH"

# ----- scaffold .claude/plans -----
mkdir -p "$WORKTREE_PATH/.claude/plans"

# Substitute template placeholders
substitute() {
    sed \
        -e "s|{{SLUG}}|$SLUG|g" \
        -e "s|{{EFFORT_TITLE}}|$EFFORT_TITLE|g" \
        -e "s|{{WORKTREE_PATH}}|$WORKTREE_PATH|g" \
        -e "s|{{BRANCH}}|$BRANCH|g" \
        -e "s|{{BASE_BRANCH}}|$BASE_BRANCH|g" \
        -e "s|{{BASE_COMMIT}}|$BASE_COMMIT|g" \
        -e "s|{{REPO_ROOT}}|$REPO_ROOT|g" \
        -e "s|{{ADD_DIRS}}|$ADD_DIRS|g" \
        -e "s|{{INIT_TIMESTAMP}}|$(date -u +%Y-%m-%dT%H:%M:%SZ)|g" \
        -e "s|{{TASK_COUNT}}|0|g" \
        -e "s|{{PR_STRATEGY}}|wave-grouped|g" \
        -e "s|{{PR_STRATEGY_DETAILS}}|One PR per wave; opens against $BASE_BRANCH|g" \
        "$1"
}

substitute "$TEMPLATES_DIR/plan-template.md"        > "$WORKTREE_PATH/.claude/plans/plan.md"
substitute "$TEMPLATES_DIR/state-template.json"     > "$WORKTREE_PATH/.claude/plans/state.json"
substitute "$TEMPLATES_DIR/progress-template.md"    > "$WORKTREE_PATH/.claude/plans/progress.md"
substitute "$TEMPLATES_DIR/EMERGENCY-template.md"   > "$WORKTREE_PATH/EMERGENCY.md"

# settings.local.json (no substitutions needed — copy as-is)
mkdir -p "$WORKTREE_PATH/.claude"
cp "$TEMPLATES_DIR/settings-template.local.json" "$WORKTREE_PATH/.claude/settings.local.json"

# USER_NOTES.md (small enough to inline)
cat > "$WORKTREE_PATH/.claude/plans/USER_NOTES.md" <<EOF
# User notes for the orchestrator

The orchestrator reads this file before starting each new wave. Add timestamped
sections to inject feedback. Mark with [CONSUMED] once read so it isn't reprocessed.

## Active notes

_(none yet)_
EOF

# launch.sh
substitute "$TEMPLATES_DIR/launcher-template.sh" > "$WORKTREE_PATH/launch.sh"
chmod +x "$WORKTREE_PATH/launch.sh"

# Install auto-push post-commit hook
# In a worktree, .git is a FILE pointing to the real gitdir. Resolve it via git
# itself rather than assuming .git is a directory. (Same fix as spawn-wave.sh.)
GIT_HOOKS_DIR="$(git -C "$WORKTREE_PATH" rev-parse --git-path hooks)"
mkdir -p "$GIT_HOOKS_DIR"
cp "$REPO_ROOT/scripts/parallel/auto-push-hook.sh" "$GIT_HOOKS_DIR/post-commit"
chmod +x "$GIT_HOOKS_DIR/post-commit"

# Stage scaffolding (force-add since .claude is often gitignored)
cd "$WORKTREE_PATH"
git add -f .claude/plans/plan.md .claude/plans/state.json .claude/plans/progress.md .claude/plans/USER_NOTES.md .claude/settings.local.json launch.sh EMERGENCY.md 2>/dev/null

# Initial commit
git commit --no-verify -m "chore($SLUG): initialize parallel-orchestration scaffolding

Created via scripts/parallel/init-worktree.sh.

Worktree: $WORKTREE_PATH
Branch:   $BRANCH (base: origin/$BASE_BRANCH @ $BASE_COMMIT)
Plan:     .claude/plans/plan.md (TODO: fill in tasks)
Launcher: ./launch.sh (run after plan is filled)" >/dev/null

# Push the branch so it's backed up
git push -u origin "$BRANCH" --no-verify >/dev/null 2>&1 || \
    echo "warning: could not push $BRANCH to origin (continue manually)"

echo ""
echo "============================================"
echo "Worktree initialized successfully"
echo "============================================"
echo "Path:     $WORKTREE_PATH"
echo "Branch:   $BRANCH (pushed to origin)"
echo "Plan:     $WORKTREE_PATH/.claude/plans/plan.md"
echo ""
echo "Next steps:"
echo "  1. cd $WORKTREE_PATH"
echo "  2. Fill out .claude/plans/plan.md (replace template placeholders with real tasks)"
echo "  3. ./launch.sh   # starts the autonomous orchestrator"
echo ""
echo "Monitoring (from any terminal):"
echo "  watch -n 30 cat $WORKTREE_PATH/.claude/plans/progress.md"
echo "  scripts/parallel/cleanup.sh $SLUG --status"
echo ""
echo "Inject feedback mid-stream:"
echo "  edit $WORKTREE_PATH/.claude/plans/USER_NOTES.md"
echo ""
echo "Emergency: $WORKTREE_PATH/EMERGENCY.md"
