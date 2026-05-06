---
description: Initialize an isolated worktree for a parallel-orchestration effort. Drops plan/state/progress scaffolding and a launch.sh ready to run.
argument-hint: <slug> [--base <branch>] [--add-dir <path>]...
---

You are helping the user kick off a parallel-orchestration effort using the toolkit at `scripts/parallel/`.

The user invoked `/parallel-start $ARGUMENTS`.

## What to do

1. **Validate the slug.** First arg is the effort slug (kebab-case, e.g. `tech-debt-v2`, `feat-mcp-redesign`). Reject if missing or invalid.

2. **Run the init script:**
   ```sh
   scripts/parallel/init-worktree.sh $ARGUMENTS
   ```
   This creates `../<repo>-<slug>/` with the worktree, plan, state, progress, launcher, and EMERGENCY doc.

3. **Walk the user through filling out the plan.** Open the new `.claude/plans/plan.md` in the new worktree. Help them fill in:
   - Effort title (replace `{{EFFORT_TITLE}}` if any leftover placeholders)
   - Task list with **Touches** column (critical for parallel safety)
   - Wave grouping
   - PR strategy (single PR vs wave-grouped train)
   - Per-task acceptance criteria

   For each task, ask the user (or infer if obvious):
   - **What's the deliverable?** (1 sentence)
   - **What files will it touch?** (the key parallelism input)
   - **Effort + risk?** (S/M/L, low/med/high)
   - **Model preference?** (sonnet for mechanical, opus for design-heavy)

4. **Confirm next steps.** Once plan is filled, tell the user:
   - `cd ../<repo>-<slug>`
   - `./launch.sh` (in a new terminal, autonomous run)
   - Monitor: `watch -n 30 cat .claude/plans/progress.md`
   - Inject feedback: edit `.claude/plans/USER_NOTES.md`
   - Cleanup after merge: `scripts/parallel/cleanup.sh <slug>`

## Notes

- Don't launch the orchestrator from this command — that's `parallel-launch` (or just `./launch.sh` from the new worktree).
- The new worktree's branch is auto-pushed to origin so it's backed up immediately.
- If init fails (worktree path collision), suggest `scripts/parallel/cleanup.sh <slug> --force` first.
- The user should be in the **main repo** when invoking this. Worktree is created at `../<repo>-<slug>/`.
