#!/bin/bash
# cleanup.sh — verify all PRs merged then remove worktrees + branches for an effort
#
# Usage:
#   scripts/parallel/cleanup.sh <slug>              # safe; checks state, refuses if dirty
#   scripts/parallel/cleanup.sh <slug> --force      # remove regardless (destructive)
#   scripts/parallel/cleanup.sh <slug> --status     # just print current state, no changes
#   scripts/parallel/cleanup.sh --completed         # auto-cleanup ALL efforts whose PRs all merged
#   scripts/parallel/cleanup.sh --status --all      # status snapshot of every active effort
#
# Removes:
#   - All sub-worktrees ../<repo>-<slug>-T*
#   - The effort worktree ../<repo>-<slug>
#   - All temp branches (local + remote)
#   - The effort branch (local + remote)
#
# Snapshots .claude/plans/ to ~/parallel-claude-archive/<slug>-<date>.tar.gz before removal.

set -euo pipefail

# --- arg parsing (supports --completed and --status --all in addition to per-slug) ---
SLUG=""
MODE="check"
ALL_FLAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force) MODE="force"; shift ;;
        --status) MODE="status"; shift ;;
        --completed) MODE="completed"; shift ;;
        --all) ALL_FLAG="all"; shift ;;
        --) shift; break ;;
        -*) echo "unknown arg: $1"; exit 1 ;;
        *)  SLUG="$1"; shift ;;
    esac
done

# --- multi-effort modes (--completed, --status --all) require no slug ---
if [ "$MODE" = "completed" ] || ([ "$MODE" = "status" ] && [ "$ALL_FLAG" = "all" ]); then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    PARENT_DIR="$(dirname "$REPO_ROOT")"
    REPO_NAME="$(basename "$REPO_ROOT")"

    # Find every effort branch (chore/<slug>) AND match it to a worktree
    EFFORT_SLUGS=$(git worktree list --porcelain 2>/dev/null \
        | awk -v rn="$REPO_NAME" '/^worktree / { p=$2 } /^branch refs\/heads\/chore\// { sub("refs/heads/chore/","",$2); print $2 }' \
        | sort -u)

    if [ -z "$EFFORT_SLUGS" ]; then
        echo "(no parallel-orchestration efforts active)"
        exit 0
    fi

    if [ "$MODE" = "status" ]; then
        echo "═══ All active parallel-orchestration efforts ═══"
        for s in $EFFORT_SLUGS; do
            echo ""
            echo "── $s ──"
            "$0" "$s" --status 2>&1 | sed 's/^/  /'
        done
        exit 0
    fi

    # --completed: per-slug, check if ALL its PRs are merged + no open ones; if yes, clean up
    echo "Scanning for completed efforts (all PRs merged, no open PRs)..."
    CLEANED=()
    SKIPPED=()
    for s in $EFFORT_SLUGS; do
        # An effort is "completed" if its branch has at least one merged PR AND zero open PRs
        OPEN=$(gh pr list --head "chore/$s" --state open --json number 2>/dev/null \
            | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        # Also check stacked wave branches (chore/<slug>-w*)
        STACK_OPEN=$(gh pr list --search "head:chore/$s- state:open" --json number 2>/dev/null \
            | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        TOTAL_OPEN=$((OPEN + STACK_OPEN))

        MERGED=$(gh pr list --head "chore/$s" --state merged --json number 2>/dev/null \
            | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        STACK_MERGED=$(gh pr list --search "head:chore/$s- state:merged" --json number 2>/dev/null \
            | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        TOTAL_MERGED=$((MERGED + STACK_MERGED))

        if [ "$TOTAL_OPEN" = "0" ] && [ "$TOTAL_MERGED" -gt 0 ]; then
            echo ""
            echo "  ✓ $s: $TOTAL_MERGED merged, 0 open — cleaning up"
            "$0" "$s" 2>&1 | sed 's/^/      /'
            CLEANED+=("$s")
        else
            echo "  ⏸ $s: $TOTAL_OPEN open / $TOTAL_MERGED merged — skipping"
            SKIPPED+=("$s")
        fi
    done

    echo ""
    echo "════════════ summary ════════════"
    echo "  cleaned: ${#CLEANED[@]} (${CLEANED[*]:-none})"
    echo "  skipped: ${#SKIPPED[@]} (${SKIPPED[*]:-none})"
    exit 0
fi

# --- single-effort modes require a slug ---
if [ -z "$SLUG" ]; then
    echo "usage:"
    echo "  $0 <slug> [--force | --status]    # per-effort"
    echo "  $0 --completed                     # auto-cleanup all merged efforts"
    echo "  $0 --status --all                  # snapshot all active efforts"
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
PARENT_DIR="$(dirname "$REPO_ROOT")"
REPO_NAME="$(basename "$REPO_ROOT")"
EFFORT_PATH="$PARENT_DIR/$REPO_NAME-$SLUG"
EFFORT_BRANCH="chore/$SLUG"
ARCHIVE_DIR="$HOME/parallel-claude-archive"

# Find sub-worktrees
SUBWORKTREES=$(git worktree list | awk '{print $1}' | grep "$REPO_NAME-$SLUG-" || true)
TEMP_BRANCHES=$(git branch -a | grep -oE "temp/$SLUG-[A-Za-z0-9_-]+" | sort -u || true)

# Status mode: just report
if [ "$MODE" = "status" ]; then
    echo "Effort:        $SLUG"
    echo "Effort branch: $EFFORT_BRANCH ($(git rev-parse --verify "$EFFORT_BRANCH" 2>/dev/null || echo 'not found locally'))"
    echo "Effort path:   $EFFORT_PATH ($([ -d "$EFFORT_PATH" ] && echo 'exists' || echo 'missing'))"
    echo ""
    echo "Sub-worktrees:"
    if [ -z "$SUBWORKTREES" ]; then
        echo "  (none)"
    else
        echo "$SUBWORKTREES" | sed 's/^/  /'
    fi
    echo ""
    echo "Temp branches:"
    if [ -z "$TEMP_BRANCHES" ]; then
        echo "  (none)"
    else
        echo "$TEMP_BRANCHES" | sed 's/^/  /'
    fi
    echo ""
    echo "PRs:"
    gh pr list --head "$EFFORT_BRANCH" --state all 2>/dev/null || echo "  (gh not available or no PRs)"
    exit 0
fi

# Safety check: refuse if any PR is open or unmerged
if [ "$MODE" = "check" ]; then
    OPEN_PRS=$(gh pr list --head "$EFFORT_BRANCH" --state open --json number 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" || echo 0)
    if [ "$OPEN_PRS" -gt 0 ]; then
        echo "ERROR: $OPEN_PRS open PR(s) for $EFFORT_BRANCH. Merge or close first, or use --force."
        gh pr list --head "$EFFORT_BRANCH" --state open
        exit 1
    fi

    # Refuse if effort worktree has uncommitted changes
    if [ -d "$EFFORT_PATH" ]; then
        if [ -n "$(git -C "$EFFORT_PATH" status --porcelain 2>/dev/null)" ]; then
            echo "ERROR: effort worktree has uncommitted changes:"
            git -C "$EFFORT_PATH" status --short
            echo ""
            echo "Commit/discard them first, or use --force."
            exit 1
        fi
    fi
fi

# Snapshot plans/state/progress before removal
if [ -d "$EFFORT_PATH/.claude/plans" ]; then
    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE="$ARCHIVE_DIR/${SLUG}-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$ARCHIVE" -C "$EFFORT_PATH/.claude" plans 2>/dev/null
    echo "Archived plans to: $ARCHIVE"
fi

# Remove sub-worktrees
if [ -n "$SUBWORKTREES" ]; then
    echo ""
    echo "Removing sub-worktrees:"
    for wt in $SUBWORKTREES; do
        echo "  $wt"
        git worktree remove "$wt" --force 2>&1 | grep -v 'is locked' || true
    done
fi

# Remove effort worktree
if [ -d "$EFFORT_PATH" ]; then
    echo ""
    echo "Removing effort worktree: $EFFORT_PATH"
    git worktree remove "$EFFORT_PATH" --force 2>&1 | grep -v 'is locked' || true
    # If git worktree remove failed, force rm
    [ -d "$EFFORT_PATH" ] && rm -rf "$EFFORT_PATH"
fi

# Remove temp branches (local + remote)
if [ -n "$TEMP_BRANCHES" ]; then
    echo ""
    echo "Removing temp branches:"
    for b in $TEMP_BRANCHES; do
        local_b="${b#remotes/origin/}"
        echo "  $local_b"
        git branch -D "$local_b" 2>/dev/null || true
        git push origin ":$local_b" 2>/dev/null || true
    done
fi

# Remove effort branch (local + remote)
echo ""
echo "Removing effort branch: $EFFORT_BRANCH"
git branch -D "$EFFORT_BRANCH" 2>/dev/null || true
git push origin ":$EFFORT_BRANCH" 2>/dev/null || true

# Prune
git worktree prune

echo ""
echo "Cleanup complete for $SLUG."
[ -n "${ARCHIVE:-}" ] && echo "Archive: $ARCHIVE"
