---
description: Show all active parallel-orchestration efforts — worktrees, branches, in-flight tasks, open PRs. The "what's going on" command.
---

The user invoked `/parallel-status` to get a snapshot of all in-flight parallel efforts.

## What to do

Walk the user through the current state across three layers:

### 1. Worktrees

```sh
git worktree list
```
Highlight any whose path contains `-<slug>-` style suffixes (effort worktrees from the parallel toolkit).

### 2. Effort branches

```sh
git branch -a | grep -E '(chore|temp)/' | head -30
```
Group by effort slug. For each slug:
- effort branch (`chore/<slug>` or `feat/<slug>`)
- temp branches (`temp/<slug>-T*`)
- their commit counts vs base

### 3. Open PRs

```sh
gh pr list --author '@me' --state open --limit 30
```
Highlight any whose head branch starts with `chore/` or `feat/`.

### 4. For each active effort, run the status check

For every slug detected:
```sh
scripts/parallel/cleanup.sh <slug> --status
```
This produces a per-effort summary (worktree state, branches, PRs).

### 5. Output format

Produce a tight summary grouped by effort:

```
═══ Effort: tech-debt-v2 ═══
  Worktree:    ../distru-integrations-tech-debt-v2 (clean / dirty)
  Branch:      chore/tech-debt-v2 (N commits ahead of develop)
  Sub-worktrees: 3 active (T-1, T-2, T-3)
  Open PRs:    #1700 (draft)
  State:       Wave 2 of 4, 8/14 tasks complete
  Last activity: 2h ago

═══ Effort: feat-mcp-redesign ═══
  ...

═══ Stale / abandoned ═══
  ...
```

### 6. Recommendations

If anything looks stale (no commits in N days), suggest cleanup:
```
Stale effort: 'old-thing' — 9 days since last commit, 0 open PRs.
Consider: scripts/parallel/cleanup.sh old-thing
```

If anything looks blocked, surface it:
```
Effort 'tech-debt-v2' has T-7 in BLOCKED state (cherry-pick conflict).
Resolve: see ../distru-integrations-tech-debt-v2/.claude/plans/state.json
```

## Notes

- Read-only by default. Don't suggest destructive actions without explicit user confirmation.
- If no parallel efforts are active, just report that. The toolkit shouldn't fail when nothing's running.
