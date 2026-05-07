# Groundtruth Phase1 — Execution Plan

**Status:** Planning (fill out tasks below, then commit + run `./launch.sh`)
**Worktree:** `/Users/derekb137/src/github/groundtruth-groundtruth-phase1`
**Branch:** `chore/groundtruth-phase1`
**Base:** `origin/develop @ 8168310cd`
**Driver:** Opus orchestrator + mixed Opus/Sonnet workstreams
**Mode:** Autonomous (`--dangerously-skip-permissions`)
**PR strategy:** wave-grouped  <!-- "single" or "wave-grouped" -->

---

## 1. Items in scope (0)

| ID | Item | Wave | Effort | Model | Risk | Touches |
|---|---|---|---|---|---|---|
| T-1 | _Replace with task title_ | 1 | S | sonnet | low | `path/one.py`, `path/two.py` |
| T-2 | _..._ | 1 | M | sonnet | low | `path/three.py` |

**Effort key:** S = ≤1h, M = 1-3h, L = 3+h
**Risk key:** low / med / high (orchestrator routes high-risk to opus + extra retries)
**Touches:** declare every file the task is allowed to modify. Pre-flight check uses this for parallel safety.

---

## 2. Wave grouping

```
Wave 1 (parallel) → PR A
  T-1, T-2, ...
       ↓
Wave 2 (parallel after Wave 1) → PR B
  T-3, T-4, ...
```

Within each wave, tasks with disjoint `Touches` lists run in parallel sub-worktrees. Tasks that overlap downgrade to sequential automatically.

---

## 3. Per-task specs

Each task gets a dedicated spec at `.claude/plans/task-<id>.md` written by the orchestrator before spawning its agent. Quick summaries here; full specs added at execute time.

### T-1: _title_
- **Goal:** what success looks like
- **Approach:** the 1-paragraph plan
- **Acceptance:** verification commands that must pass
- **Out of scope:** what NOT to touch (helps the agent stay disciplined)

(Repeat per task.)

---

## 4. Verification gates

Per-task and per-wave. Override `scripts/parallel/verify-gate.sh` for repo-specific gates.

Default per-task:
```sh
uv run ruff check .
uv run mypy src/
uv run pytest -x --tb=short
```

Per-wave (after cherry-picks): same as above plus full pytest (no `-x`).

All must pass to accept; otherwise retry the task with tighter spec.

---

## 5. PR plan

- One PR per wave; opens against develop
- Open PRs sequentially. User reviews/merges between PRs.
- Orchestrator does NOT auto-merge — that's the human checkpoint.

---

## 6. Orchestration protocol (codified)

**Autonomous mode:** orchestrator proceeds wave→wave without check-ins. Stops only on:
- 3 consecutive failed retries on a single task
- Rate-limit halt (`ScheduleWakeup` to resume)
- A spec ambiguity that would otherwise cause information loss

User can monitor via `.claude/plans/progress.md`. User can inject feedback by editing `.claude/plans/USER_NOTES.md` — orchestrator reads it before each new wave.

---

## 7. Done criteria

- [ ] All tasks resolved (status = completed) or explicitly BLOCKED with reason
- [ ] All planned PRs opened (orchestrator's job) and merged (your job)
- [ ] Verification gates passing across all waves
- [ ] No new lint/type/test regressions vs base commit
- [ ] Followups (if any) captured at the bottom of `progress.md`
