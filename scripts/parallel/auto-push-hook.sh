#!/bin/bash
# auto-push-hook.sh — installed as .git/hooks/post-commit in every parallel worktree
#
# After every commit, push the current branch to origin so work is backed up.
# Failures are logged but don't block the commit (post-commit hooks can't anyway,
# but we want clear signal that backup didn't happen).

BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null)"
[ -z "$BRANCH" ] && exit 0  # detached HEAD, skip

# Skip pushing main/develop/master — never auto-push core branches
case "$BRANCH" in
    main|master|develop|staging|production)
        exit 0
        ;;
esac

# Push to origin in the background so the commit feels instant
{
    if git push origin "$BRANCH" --no-verify 2>&1 | tail -3 > /tmp/parallel-autopush.last; then
        :
    else
        echo "[auto-push-hook] push to origin/$BRANCH failed:" >&2
        cat /tmp/parallel-autopush.last >&2
    fi
} &
disown 2>/dev/null || true
