# Parallel Claude Orchestration Toolkit

Spin up isolated worktrees, run multiple Claude agents in parallel without
stepping on each other, merge their work back cleanly, ship as PR(s).

Built from the patterns proven in the v2 refactor (April 2026) and tech-debt
v1 (April 2026 autonomous run that finished in ~2h vs the planned ~7h).
First real-world use of *this* toolkit: tech-debt v2 (May 2026) — see
`docs/postmortems/parallel-toolkit-first-use-2026-05.md`.

## 5-line quick-start

```
1. /parallel-start <slug>           # in any Claude session in this repo
2. cd ../<repo>-<slug>              # cd into the new worktree
3. edit .claude/plans/plan.md       # fill in tasks, waves, Touches: [files]
4. ./launch.sh                      # NEW terminal — autonomous, no prompts
5. /parallel-cleanup <slug>         # after PRs merge
```

## Full TL;DR

```sh
# 1. Start a new effort
/parallel-start tech-debt-v2

# 2. Fill out the plan (interactive in current Claude session)
#    cd ../distru-integrations-tech-debt-v2
#    edit .claude/plans/plan.md

# 3. Launch the autonomous orchestrator (NEW terminal)
cd ../distru-integrations-tech-debt-v2
./launch.sh

# 4. Monitor (any terminal)
watch -n 30 cat .claude/plans/progress.md

# 5. Inject feedback mid-stream
edit .claude/plans/USER_NOTES.md

# 6. After PRs are merged
/parallel-cleanup tech-debt-v2
```

## First-time walkthrough (from tech-debt v2)

Concrete trace of the first real run, ~3h11min wall clock:

```
T+00:00  /parallel-start tech-debt-v2
         → init-worktree.sh creates ../distru-integrations-tech-debt-v2
         → drops plan/state/progress/launcher/EMERGENCY scaffolding
         → pushes chore/tech-debt-v2 to origin (immediate backup)

T+00:05  Edit .claude/plans/plan.md — fill in 16 tasks across 4 waves with
         Touches: file lists per task. Edit state.json to register tasks.

T+00:10  cd ../distru-integrations-tech-debt-v2
         nohup ./launch.sh > .claude/plans/logs/orchestrator.log 2>&1 &
         → claude spawns with --dangerously-skip-permissions
         → reads plan.md, executes Wave 1

T+00:20  Wave 1 spawn — 5 sub-worktrees, 5 headless agents, ~9min each
T+00:30  Wave 1 cherry-pick → effort branch
         → orchestrator reverts T-2 (env mismatch, see postmortem)
         → orchestrator marks T-4 BLOCKED per spec
T+00:45  PR #1704 (W1) opened against develop

T+00:50  Wave 2 spawn — 5 monolith splits in parallel
T+01:30  Wave 2 cherry-pick + mypy fixup commit
         → PR #1705 (W2) opened, base = chore/tech-debt-v2-w1 (stacked)

T+01:45  Wave 3 audit — taxonomy already adopted, no-op PR #1706

T+02:55  Wave 4 — 2 CI gates landed, PR #1707 opened
T+03:11  Orchestrator exits cleanly. 4 PRs ready for review.
```

You then review/merge the PRs at your pace. Run `/parallel-cleanup <slug>` after the last lands.

## What this gives you

- **Isolation**: every effort lives in its own worktree, every parallel task within an effort lives in its own sub-worktree. Agents physically can't see each other's edits.
- **Backup**: every commit auto-pushes to origin. State + plan files committed too. Crash-resistant.
- **Resumability**: state is JSON, branches are real git refs. `./launch.sh --resume` picks up exactly where the orchestrator stopped.
- **Safety**: per-wave safety tags, refuses cleanup with open PRs, archives plans before destruction.
- **Observability**: live `progress.md` dashboard, per-task logs, `parallel-status` snapshot command.
- **No permission prompts**: launchers use `--dangerously-skip-permissions` (bounded by branch + PR review).

## File layout

```
scripts/parallel/
├── README.md                         ← you are here
├── init-worktree.sh                  ← creates effort worktree from template
├── spawn-wave.sh                     ← fans out N sub-worktrees + agents per wave
├── cherry-pick-wave.sh               ← merges sub-worktree commits back
├── verify-gate.sh                    ← standard ruff/mypy/pytest gate
├── auto-push-hook.sh                 ← post-commit hook (auto-push to origin)
├── cleanup.sh                        ← removes worktrees + branches after PRs merge
└── templates/
    ├── plan-template.md              ← effort plan structure
    ├── state-template.json           ← orchestrator state schema
    ├── progress-template.md          ← live dashboard
    ├── launcher-template.sh          ← autonomous claude launcher
    ├── EMERGENCY-template.md         ← rollback recipes
    └── settings-template.local.json  ← permissions allowlist for the worktree

.claude/commands/
├── parallel-start.md                 ← /parallel-start <slug>
├── parallel-launch.md                ← /parallel-launch <slug> [--resume]
├── parallel-merge.md                 ← /parallel-merge --wave N
├── parallel-cleanup.md               ← /parallel-cleanup <slug>
└── parallel-status.md                ← /parallel-status
```

## The mental model

```
distru-integrations/                  ← main clone (on develop or main)
└── .git/                             ← shared git internals

../distru-integrations-tech-debt-v2/  ← effort worktree on chore/tech-debt-v2
├── .claude/plans/
│   ├── plan.md                       ← the contract
│   ├── state.json                    ← resumable state
│   ├── progress.md                   ← live dashboard
│   └── USER_NOTES.md                 ← async feedback channel
├── launch.sh                         ← starts headless orchestrator
└── EMERGENCY.md                      ← rollback recipes

../distru-integrations-tech-debt-v2-T1/  ← sub-worktree (one per parallel task)
../distru-integrations-tech-debt-v2-T2/
                                      ↓ cherry-pick after wave done
                                      → chore/tech-debt-v2 → PR → develop
```

Three layers of isolation:

1. **Effort worktrees** isolate parallel projects (refactor, tech-debt, feature work)
2. **Sub-worktrees** within an effort isolate parallel tasks within a wave
3. **Branches** isolate everything from `develop`/`main` until human-merged

## Lifecycle (4 stages)

### Stage 1: SCOPE — `/parallel-start <slug>`

Creates the effort worktree, drops scaffolding. You then collaborate with
Claude (in this session OR a fresh one in the worktree) to fill in `plan.md`:
what tasks, what waves, what model per task, what each task touches (file scope
declaration).

### Stage 2: EXECUTE — `./launch.sh`

In a NEW terminal in the effort worktree. The orchestrator:

1. Reads `plan.md`, derives wave assignments
2. For each wave:
   - Pre-flight: checks task `Touches:` declarations for overlap. If overlap, downgrades to sequential within that wave.
   - Spawns sub-worktree per task: `git worktree add ../<repo>-<slug>-<taskId> -b temp/<slug>-<taskId>`
   - Launches one Claude agent per sub-worktree
   - Waits for all to commit + report
   - `cherry-pick-wave.sh` merges task commits onto effort branch
   - `verify-gate.sh` runs the standard gate
   - Updates `progress.md`
3. After all waves: opens PR(s) per `plan.md` strategy
4. **Stops. Does NOT auto-merge.** That's your gate.

### Stage 3: MERGE — humans review, you click

You review each PR. Merge per the plan (single PR or train).

#### PR stacking caveat

When the plan uses wave-grouped PRs, the orchestrator opens them as a **stack** — each wave's branch bases on the previous wave's branch, not on `develop` directly:

```
PR #1704 (W1)  base: develop
PR #1705 (W2)  base: chore/<slug>-w1   ← stacked on W1
PR #1706 (W3)  base: chore/<slug>-w2   ← stacked on W2
PR #1707 (W4)  base: chore/<slug>-w3   ← stacked on W3
```

This means:

- **Merge in order: W1 → W2 → W3 → W4.** GitHub auto-retargets each PR's base to `develop` as the previous wave's PR merges. Don't merge out of order — you'll create dangling base refs.
- **Diff scope per PR is incremental.** Reviewing PR #1705 only shows W2's changes (not W1's), which is what you want.
- **CI runs against the stacked base.** That means W2's CI runs include W1's commits. So a passing CI on W2 = "W1 + W2 are jointly green," which is the strongest signal.
- **If you want to merge a later wave first** (say W3 looks important and W2 needs more review), you have to manually retarget W3's base to `develop`, resolve any conflicts, and accept that W2's PR may need rebasing afterward. Recommended only if you really need to.
- **`gh pr merge --squash`** preserves the stack semantics; merge commits also fine. Avoid `--rebase` on the stack since each PR's individual rebase invalidates the next.

Tools like [Graphite](https://graphite.dev) or [git-spice](https://abhinav.github.io/git-spice/) handle stacked PRs natively if you want a smoother merge experience. Plain `gh` works fine for small stacks (≤4 PRs).

### Stage 4: CLEANUP — `/parallel-cleanup <slug>`

After PRs merge:

- Snapshots `.claude/plans/` to `~/parallel-claude-archive/<slug>-<date>.tar.gz`
- Removes all sub-worktrees + effort worktree
- Deletes all temp branches + the effort branch (local + remote)
- Refuses if any PR is still open (use `--force` to override)

**Bulk cleanup modes** (added 2026-05-04 after the 5-concurrent-orchestrator stress test left ~70 stale worktrees):

```sh
# Auto-cleanup ALL efforts whose PRs are all merged (no open ones)
scripts/parallel/cleanup.sh --completed

# Snapshot of every active effort (worktree state + PRs) in one report
scripts/parallel/cleanup.sh --status --all
```

`--completed` is the recommended end-of-day routine when running multiple efforts. Refuses to remove anything with open PRs. Each effort cleaned gets its own `~/parallel-claude-archive/<slug>-<date>.tar.gz`.

## Safety story (5 layers)

1. **Auto-push every commit** via `auto-push-hook.sh`. Even a hard crash loses at most one commit's worth of work.
2. **State file committed.** `state.json` is in the repo, pushed to remote.
3. **Branch backup.** All effort + temp branches push to origin.
4. **Auto-archive on cleanup.** Plans tarballed before any destructive action.
5. **EMERGENCY.md per worktree.** Copy-paste rollback recipes for every realistic failure mode.

## Anti-conflict mechanism (3 layers)

1. **Plan-time disjointness.** Each task declares `Touches: [...]`. `spawn-wave.sh` pre-flight checks for overlap; downgrades wave to sequential if conflict detected.
2. **Sub-worktree-per-task.** Even with disjointness declared, agents physically can't see each other's edits. Eliminates race conditions.
3. **Cherry-pick conflict gate.** When merging back, conflicts surface immediately. Task marked BLOCKED, orchestrator continues with non-conflicting tasks. You resolve manually.

## Orchestration etiquette (codified in launcher-template.sh)

```
Per task:
  1. Spec → spawn agent → wait for completion
  2. verify-gate.sh. Pass → commit, update progress.md, next task.
  3. Fail → tighter respec, retry. Max 3 attempts.
  4. After 3 → mark BLOCKED, escalate, move to non-dependent tasks

Between waves:
  Read USER_NOTES.md. Apply user-injected feedback.

On rate limit:
  Save state, ScheduleWakeup(1800s), resume cleanly.

NEVER:
  - Auto-merge to develop/main
  - Force-push the effort branch
  - Delete sub-worktrees before cherry-pick
  - Skip the verification gate

ALWAYS:
  - Push after every commit (auto via hook)
  - Update progress.md in real time
  - Annotate commit body with task ID + spec + agent model for forensics
```

## Per-repo customization

Override the verification gate for repo-specific checks. Drop a file at:

```
.claude/plans/verify-gate.local.sh
```

In the effort worktree (not the template). Sourced by `verify-gate.sh` before
running default gates. Use to:

- Add custom gates (golden-file checks, OpenAPI shape checks, etc.)
- Change `MYPY_CEILING` env var
- Set `PYTEST_ARGS` (e.g., `--ignore=tests/integration` for unit-only gate)

Example:

```sh
# .claude/plans/verify-gate.local.sh
export MYPY_CEILING=395
export PYTEST_ARGS="--ignore=tests/integration"
```

## Future direction

This toolkit is the seed for the revived "goldfish" plugin (or its successor).
Stages:

- **Stage 1 (now):** lives in `distru-integrations` repo. Prove the pattern.
- **Stage 2:** extract to `~/.claude/scripts/parallel/` global so it works in any repo.
- **Stage 3:** package as plugin in `distru-plugin-marketplace`. Distribute.

## When NOT to use this

- Single-task work (just open a PR normally — no orchestration needed)
- Quick fixes (overhead > benefit)
- Anything where you genuinely want continuous human review (this is for trusted-mechanical or trusted-design work where the agent has clear specs)

## When to use this

- Multi-day efforts with ≥3 parallelizable tasks
- Refactors that touch many files
- Test-coverage campaigns (lots of small additions)
- Migration work (uv → poetry, structlog → loguru, etc.)
- Any time you want to "set it and forget it overnight"
