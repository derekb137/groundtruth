# EMERGENCY — groundtruth-phase0

Quick recipes for when the orchestrator goes sideways or you need to bail.

**Effort branch:** `chore/groundtruth-phase0`
**Worktree:** `/Users/derekb137/src/github/groundtruth-groundtruth-phase0`
**Base:** `origin/develop @ 52ae77bfb`

---

## Stop the orchestrator immediately

```sh
pkill -f 'claude.*groundtruth-phase0'
# or Ctrl+C in the terminal running ./launch.sh
```

State + commits are preserved. Resume with `./launch.sh --resume` later.

---

## "I want to abandon this effort entirely"

Closes any open PRs, deletes all branches + worktrees, removes traces.

```sh
# From your repo root (NOT this worktree):
/Users/derekb137/src/github/groundtruth/scripts/parallel/cleanup.sh groundtruth-phase0 --force
```

---

## "The orchestrator pushed garbage to the remote"

Branches go to `origin/chore/groundtruth-phase0` and `origin/temp/groundtruth-phase0-T*`. Delete:

```sh
git push origin :chore/groundtruth-phase0
for ref in $(git ls-remote origin "temp/groundtruth-phase0-*" | awk '{print $2}' | sed 's|refs/heads/||'); do
    git push origin :"$ref"
done
```

`main`/`develop` is untouched — there's no merge yet, no production impact.

---

## "I need to recover work from a crashed sub-worktree"

Sub-worktrees live at `/Users/derekb137/src/github/groundtruth-groundtruth-phase0-T<id>/`. Each is a normal git checkout
on branch `temp/groundtruth-phase0-T<id>`. Their commits are also pushed to `origin/temp/...`.

```sh
git -C /Users/derekb137/src/github/groundtruth-groundtruth-phase0-T1 log --oneline -10  # see what they did
git fetch origin temp/groundtruth-phase0-T1                # pull from remote if local is gone
git log origin/temp/groundtruth-phase0-T1 --oneline -10
```

You can cherry-pick any of those commits onto a recovery branch by hand.

---

## "I want to merge what's done and abandon the rest"

```sh
# From inside this worktree:
/Users/derekb137/src/github/groundtruth/scripts/parallel/cherry-pick-wave.sh --wave 1  # pick whichever wave is partially done
/Users/derekb137/src/github/groundtruth/scripts/parallel/verify-gate.sh
git push origin chore/groundtruth-phase0
gh pr create --base develop --head chore/groundtruth-phase0 --draft \
    --title "[partial] Groundtruth Phase0" \
    --body "Partial completion. See state.json for what's done vs blocked."
```

---

## "Production is on fire because of something this effort merged"

This branch is `chore/groundtruth-phase0` — pre-merge to `develop` it has zero prod impact.
After merge, follow the standard repo rollback procedure:
1. `git revert -m 1 <merge-sha>` on `develop` → push → ArgoCD syncs
2. If image is the issue: rollback in deploy repo `values.yaml`

This document is NOT a substitute for the repo's rollback runbook (`/Users/derekb137/src/github/groundtruth/docs/RUNBOOK.md` or deploy repo equivalent).

---

## "I'm not sure what state things are in"

```sh
/Users/derekb137/src/github/groundtruth/scripts/parallel/cleanup.sh groundtruth-phase0 --status   # safe; just lists
cat .claude/plans/state.json | python3 -m json.tool
cat .claude/plans/progress.md
git -C /Users/derekb137/src/github/groundtruth-groundtruth-phase0 log --oneline -10
git -C /Users/derekb137/src/github/groundtruth-groundtruth-phase0 branch -av | grep 'groundtruth-phase0'
gh pr list --head chore/groundtruth-phase0
```
