---
description: After PRs merge, remove the effort worktree, sub-worktrees, and branches. Snapshots plans/state to ~/parallel-claude-archive/ before removal.
argument-hint: <slug> [--force | --status]
---

The user invoked `/parallel-cleanup $ARGUMENTS` to wind down a finished effort.

## What to do

1. **Default mode is SAFE.** The script refuses if any PR is open or the effort worktree has uncommitted changes. Use `--force` only if the user explicitly insists.

2. **Always offer `--status` first** when the user might be uncertain. It's a no-op listing of what's there:
   ```sh
   scripts/parallel/cleanup.sh <slug> --status
   ```

3. **Run cleanup:**
   ```sh
   scripts/parallel/cleanup.sh $ARGUMENTS
   ```
   The script will:
   - Snapshot `.claude/plans/` to `~/parallel-claude-archive/<slug>-<date>.tar.gz`
   - Remove all sub-worktrees (`<repo>-<slug>-T*`)
   - Remove the effort worktree (`<repo>-<slug>`)
   - Delete all temp branches (`temp/<slug>-*`) locally + on origin
   - Delete the effort branch (`chore/<slug>`) locally + on origin
   - `git worktree prune`

4. **Report back:**
   - Confirm the archive path (in case the user wants to reference plan/state later)
   - Confirm worktrees + branches are gone
   - Note that the merged commits live forever in `main`/`develop` history — this only removes the working scaffolding

## When NOT to run

- If any PR is still open (script refuses without `--force`)
- If you're not sure the effort completed cleanly — run `--status` first
- If the user wants to keep the worktree around for some reason (manual rollback, debugging)

## Notes

- The script auto-archives plans + state before any destructive action. Your context is preserved.
- The Git history of merged work is untouched. This only removes the working-copy scaffolding.
- If something unexpected exists at the worktree path (e.g., user dropped notes there), `--force` will remove it. Refuse to use `--force` without explicit user confirmation.
