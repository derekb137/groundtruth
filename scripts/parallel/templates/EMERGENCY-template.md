# EMERGENCY — {{SLUG}}

Quick recipes for when the orchestrator goes sideways or you need to bail.

**Effort branch:** `{{BRANCH}}`
**Worktree:** `{{WORKTREE_PATH}}`
**Base:** `origin/{{BASE_BRANCH}} @ {{BASE_COMMIT}}`

---

## Stop the orchestrator immediately

```sh
pkill -f 'claude.*{{SLUG}}'
# or Ctrl+C in the terminal running ./launch.sh
```

State + commits are preserved. Resume with `./launch.sh --resume` later.

---

## "I want to abandon this effort entirely"

Closes any open PRs, deletes all branches + worktrees, removes traces.

```sh
# From your repo root (NOT this worktree):
{{REPO_ROOT}}/scripts/parallel/cleanup.sh {{SLUG}} --force
```

---

## "The orchestrator pushed garbage to the remote"

Branches go to `origin/{{BRANCH}}` and `origin/temp/{{SLUG}}-T*`. Delete:

```sh
git push origin :{{BRANCH}}
for ref in $(git ls-remote origin "temp/{{SLUG}}-*" | awk '{print $2}' | sed 's|refs/heads/||'); do
    git push origin :"$ref"
done
```

`main`/`{{BASE_BRANCH}}` is untouched — there's no merge yet, no production impact.

---

## "I need to recover work from a crashed sub-worktree"

Sub-worktrees live at `{{WORKTREE_PATH}}-T<id>/`. Each is a normal git checkout
on branch `temp/{{SLUG}}-T<id>`. Their commits are also pushed to `origin/temp/...`.

```sh
git -C {{WORKTREE_PATH}}-T1 log --oneline -10  # see what they did
git fetch origin temp/{{SLUG}}-T1                # pull from remote if local is gone
git log origin/temp/{{SLUG}}-T1 --oneline -10
```

You can cherry-pick any of those commits onto a recovery branch by hand.

---

## "I want to merge what's done and abandon the rest"

```sh
# From inside this worktree:
{{REPO_ROOT}}/scripts/parallel/cherry-pick-wave.sh --wave 1  # pick whichever wave is partially done
{{REPO_ROOT}}/scripts/parallel/verify-gate.sh
git push origin {{BRANCH}}
gh pr create --base {{BASE_BRANCH}} --head {{BRANCH}} --draft \
    --title "[partial] {{EFFORT_TITLE}}" \
    --body "Partial completion. See state.json for what's done vs blocked."
```

---

## "Production is on fire because of something this effort merged"

This branch is `{{BRANCH}}` — pre-merge to `{{BASE_BRANCH}}` it has zero prod impact.
After merge, follow the standard repo rollback procedure:
1. `git revert -m 1 <merge-sha>` on `{{BASE_BRANCH}}` → push → ArgoCD syncs
2. If image is the issue: rollback in deploy repo `values.yaml`

This document is NOT a substitute for the repo's rollback runbook (`{{REPO_ROOT}}/docs/RUNBOOK.md` or deploy repo equivalent).

---

## "I'm not sure what state things are in"

```sh
{{REPO_ROOT}}/scripts/parallel/cleanup.sh {{SLUG}} --status   # safe; just lists
cat .claude/plans/state.json | python3 -m json.tool
cat .claude/plans/progress.md
git -C {{WORKTREE_PATH}} log --oneline -10
git -C {{WORKTREE_PATH}} branch -av | grep '{{SLUG}}'
gh pr list --head {{BRANCH}}
```
