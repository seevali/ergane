> **Idea 3 / 5 · plumbing** · epic: GitHub Issue Round-Trip & Autonomy
> Source of truth: [`prd.md` §3 Idea 3](https://github.com/seevali/ralph-loop-demo/blob/main/system/chapters/2026-06-25-github-issue-roundtrip/prd.md)

## Context (cold-start)

The Ralph Loop runs `--issue N` in the repo's working directory. Each `claude -p` step operates on that one tree. As of 2026-06-25 two issues cannot run without colliding, and a half-built issue contaminates `git status`.

## Problem

There is no isolation. Concurrent or back-to-back issue runs trample each other's working tree; a crashed run leaves the main tree dirty. This blocks any multi-issue capability (Swarm, Idea 5) and makes Round Trip branches messier than they need to be.

## Proposed mechanism

The filesystem-native take on sandcastle's "branch" strategy — using the tool the loop already trusts, `git worktree`:

1. At the start of an issue run: `git worktree add ../ralph-issue-N ralph/issue-N` (branch from default-branch HEAD).
2. Every `claude -p` step for that issue runs with cwd set to the worktree; the diff, the `feat(N.x):` commits, and the `git log` completion greps all scope to that tree automatically.
3. **Teardown / reaper:** on success, leave the branch for review and `git worktree remove`; on crash, an `EXIT` trap plus `git worktree prune` reclaims leaked trees.
4. **Artifact seam (decide explicitly):** keep planning artifacts (`docs/…`) discoverable in the main tree while code work happens in the worktree (symlink or write-through), so a viewer can still `cat docs/epics/issue-N.md`.

**Files touched:** `scripts/ralph-loop.sh` (run setup/teardown + cwd handling for each `claude -p` invocation).

## Acceptance criteria

**Shipped (2026-07-04):** DELIBERATE DEVIATION — worktrees live IN-REPO at `.ralph/worktrees/issue-N` (gitignored), not the sibling `../ralph-issue-N` this issue proposed. The root `CLAUDE.md` self-contained-repo guardrail forbids `../` references, and the in-repo location makes the artifact seam structural. `ensure_issue_pr` also gained OPEN-only branch-based PR recovery so success teardown discarding the untracked `pr.txt` can never resurrect a merged PR or double-create.

- [x] An issue run executes entirely inside `../ralph-issue-N`; the main working tree's `git status` stays clean throughout. — shipped location: `.ralph/worktrees/issue-N` (see deviation)
- [x] Completion checks (`is_story_complete` / `git log` greps) remain correct when run from the worktree.
- [x] **Reaper:** a crashed/interrupted run leaves no orphaned worktree or dangling branch after the next run's prune (verified by a smoke that simulates an abort). — crashed trees are RESUMED by the next run of the same issue (resumable state, not garbage); prune reclaims manually-deleted trees; success teardown (all-green only) force-removes the tree and always keeps the branch.
- [x] Planning artifacts remain readable from the main tree (the artifact seam is implemented, not hand-waved). — structural: main-tree path `.ralph/worktrees/issue-N/docs/…` + breadcrumb `.info` file.
- [x] Behavior with worktrees disabled is unchanged (feature flag or default-path parity). — `--worktree` default off; absent = byte-identical behavior.
- [x] `prd.md` §3 Idea 3 matches shipped behavior (anti-drift DoD).

## Dependencies & sequencing

- **Blocked by:** The Round Trip (Idea 1) — branches/PRs define the branch a worktree checks out.
- **Blocks:** Swarm + Mission Control (Idea 5) — concurrency stands on per-issue isolation.

## Out of scope

Parallel execution / scheduling (Idea 5), sandboxing beyond git worktrees (no Docker/microVM — that is the explicit non-goal vs sandcastle; the loop stays bash + filesystem), the PR body content (Idea 2).

## Glossary

**Worktree** — a second working directory attached to the same git repository, checked out to its own branch (`git worktree`). **Reaper** — cleanup that removes leaked worktrees/branches after a crash. **Artifact seam** — the boundary where planning docs (main tree) and code (worktree) meet; a known place demos break if mishandled.
