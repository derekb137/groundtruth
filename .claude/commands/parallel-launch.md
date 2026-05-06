---
description: Print the exact command to launch the autonomous orchestrator for an existing effort worktree. Verifies the worktree + plan are ready first.
argument-hint: <slug> [--resume]
---

The user invoked `/parallel-launch $ARGUMENTS` to start the autonomous orchestrator for an existing effort.

## What to do

1. **Resolve the worktree path.** First arg is the slug. Compute `../$(basename $(git rev-parse --show-toplevel))-<slug>`.

2. **Verify the worktree exists + plan is ready:**
   ```sh
   WT="../$(basename $(git rev-parse --show-toplevel))-<slug>"
   [ -d "$WT" ] || echo "ERROR: worktree missing — run /parallel-start <slug> first"
   [ -f "$WT/.claude/plans/plan.md" ] || echo "ERROR: plan missing"
   grep -q '_Replace with task title_' "$WT/.claude/plans/plan.md" && \
       echo "ERROR: plan still has template placeholders. Fill out tasks before launching."
   ```

3. **If checks pass, print the launch command.** Don't run it from this session — the user should open a new terminal so:
   - The launcher can take over the terminal cleanly
   - This Claude Code session stays available for monitoring + feedback

   ```
   In a NEW terminal:

       cd $WT
       ./launch.sh${RESUME:+ --resume}

   Monitor (any terminal):

       watch -n 30 cat $WT/.claude/plans/progress.md
       tail -f $WT/.claude/plans/logs/T-*.log
       gh pr list --head chore/<slug>

   Inject feedback mid-stream:

       edit $WT/.claude/plans/USER_NOTES.md
       (orchestrator reads it before each new wave)

   Stop the orchestrator:

       pkill -f 'claude.*<slug>'
       (state preserved; resume with: ./launch.sh --resume)

   Emergency: see $WT/EMERGENCY.md
   ```

4. **If `--resume` was passed**, mention the launcher will pick up from `.claude/plans/state.json` (current wave, in-flight tasks).

5. **Don't actually invoke claude here.** This command's job is to verify + print instructions.
