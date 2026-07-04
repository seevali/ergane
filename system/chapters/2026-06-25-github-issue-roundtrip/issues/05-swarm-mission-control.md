> **Idea 5 / 5 · the capstone** · epic: GitHub Issue Round-Trip & Autonomy
> Source of truth: [`prd.md` §3 Idea 5](https://github.com/seevali/ralph-loop-demo/blob/main/system/chapters/2026-06-25-github-issue-roundtrip/prd.md)

## Context (cold-start)

The Ralph Loop runs **one issue per invocation** today. With Round Trip (Idea 1) it produces a reviewable PR per issue, and with Worktree-per-Issue (Idea 3) each run is isolated in its own tree. This issue is about working **many** issues and giving the operator a way to watch — and stop — them.

## Problem

Burn-down at scale ("40 stale issues and a weekend") is impossible one-`--issue`-at-a-time. And the moment more than one job runs, the operator's job changes from "watch a log scroll" to "know which of N jobs needs me *right now*." Parallelism without observability is panic at scale; throughput without a brake is how you teach a maintainer never to run the tool twice.

## Proposed mechanism

1. **Serial multi-issue (v1).** Accept a list/queue of issues (e.g. `--issues 12,15,19` or all `ralph:ready`) and work them one after another, each in its own worktree (Idea 3), each producing its own PR (Idea 1). **No concurrency in v1.**
2. **`ralph watch` dashboard.** One terminal pane, one row per job: issue, current phase, story X/Y, elapsed, cost-so-far, health glyph. Surfaces the *one anomaly* among healthy jobs (e.g. a job stuck retrying) — triage, not monitoring. Aggregates the per-story status/duration/cost the loop already tracks.
3. **The brake (ships in the SAME increment as the throttle).** Per-job pause / resume / abort, so the operator can rescue the one job that needs a human without killing the others.

**Scope split:** true **concurrent** execution is **v2**, separately justified. "Fan-out + dashboard + pause/abort" is three products; the bet does not need concurrency to prove itself, and serial-first lets the merge-as-is rate be measured before scaling (`prd.md` §7).

**Files touched:** `scripts/ralph-loop.sh` (issue-list driver) + a new `ralph watch` view (bash/terminal, reading the loop's per-job status artifacts).

## Acceptance criteria

**Shipped (2026-07-04):** strictly serial driver (`--issues LIST|ready`) re-invoking the loop per issue with `--worktree` and forwarded flags; per-job status files under gitignored `.ralph/jobs/`; `scripts/ralph-watch.sh` = dashboard (issue/state/story X/Y/elapsed/cost/health glyph, stuck-job flag) + brake CLI; brake = control files honored between steps inside `check_interrupted` (pause/resume/abort; abort exit code 4; inert unless the driver exports `RALPH_JOBS_DIR`, so standalone runs are unchanged); `ready` mode = open issues labeled `ralph:ready` (Triage's promotion gate keeps the roadmap recursion guard) and fails closed on `gh` errors; driver summary prints the reviewer-despair guard; concurrency explicitly deferred to v2.

- [x] `--issues <list>` (or `--issues ready`) works the issues serially, each isolated in its own worktree, each opening its own PR.
- [x] `ralph watch` shows live per-job rows (issue, phase, story X/Y, elapsed, cost, health) and visibly flags an unhealthy/stuck job.
- [x] Per-job **pause / resume / abort** works and is shipped in the same change as the multi-issue driver (no throttle without a brake).
- [x] **Reviewer-despair kill check:** if serial runs produce more PRs than the operator reviews, do **not** proceed to v2 concurrency (`prd.md` §7). — enforced as a documented guard line in every driver summary; the human decides.
- [x] No auto-merge / auto-close (ADR I3); concurrency explicitly deferred and documented as v2. — driver and watch never invoke merge/close; smoke asserts it.
- [x] `prd.md` §3 Idea 5 matches shipped behavior (anti-drift DoD).

## Dependencies & sequencing

- **Blocked by:** Worktree-per-Issue (Idea 3) primarily; effectively also The Round Trip (Idea 1, per-issue PRs) and Triage (Idea 4, the `ready` queue source). The capstone — build last.

## Out of scope

True parallel/concurrent execution (v2), the scheduler/cron fire-and-forget rung (autonomy ladder rung 3), sandboxing beyond git worktrees, auto-merge/auto-close, any web GUI (surfaces are terminal + GitHub only).

## Glossary

**Swarm** — working many issues, isolated, with results merged back. **Mission Control / `ralph watch`** — a terminal dashboard that ranks running jobs by which needs the operator's attention. **The brake** — per-job pause/resume/abort; non-negotiable companion to any throttle. **Merge-as-is rate** — the trust metric gating the move from serial (v1) to concurrent (v2).
