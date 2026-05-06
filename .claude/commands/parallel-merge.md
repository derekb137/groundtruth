---
description: Cherry-pick the current wave's task commits onto the effort branch and run the verification gate. Used by the orchestrator (typically) but invokable manually.
argument-hint: --wave <N>
---

The user invoked `/parallel-merge $ARGUMENTS` to cherry-pick a wave's task commits onto the effort branch.

## What to do

1. **Verify you're inside an effort worktree:**
   ```sh
   [ -f .claude/plans/state.json ] || echo "ERROR: not in an effort worktree (no .claude/plans/state.json)"
   ```

2. **Run the cherry-pick script:**
   ```sh
   scripts/parallel/cherry-pick-wave.sh $ARGUMENTS
   ```
   This will:
   - Tag the effort branch tip as a safety rollback point
   - Cherry-pick each task's commits from `temp/<slug>-<task-id>` branches
   - On conflict: mark the task BLOCKED in state.json, abort that pick, continue with next
   - Run `scripts/parallel/verify-gate.sh` after all picks
   - Push the effort branch to origin if the gate passes

3. **Read the script's output** and report:
   - Which tasks merged cleanly
   - Which tasks went BLOCKED (with reason)
   - Whether the verification gate passed
   - The safety tag (in case rollback is needed)

4. **If anything blocked:** suggest next steps:
   - For conflict-blocked tasks: the user can manually resolve in the sub-worktree, then re-run `parallel-merge --wave N`
   - For no-commits tasks: the agent likely failed silently — check `.claude/plans/logs/<task-id>.log`

5. **If gate passed:** confirm the next step is opening a PR. If the plan calls for wave-grouped PRs, this is the moment. Suggest:
   ```
   gh pr create --base <BASE_BRANCH> --head chore/<slug> --draft \
       --title "[wave N] <effort title>" \
       --body-file .claude/plans/progress.md
   ```
   (Adjust title/body per the user's plan PR strategy.)

## Notes

- This command modifies the effort branch (cherry-picks commits + pushes). Not destructive in the worktree-isolation sense (sub-worktrees + temp branches survive), but it does modify history on the effort branch.
- Safety tag (`parallel/safety/wave-<N>-<timestamp>`) is created. Rollback: `git reset --hard parallel/safety/wave-<N>-<ts>`.
- `--wave` is required.
