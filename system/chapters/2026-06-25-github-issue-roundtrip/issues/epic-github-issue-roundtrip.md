> **Epic** · part of the System Track chapter `system/chapters/2026-06-25-github-issue-roundtrip/`
> Source of truth: [`prd.md`](https://github.com/seevali/ralph-loop-demo/blob/main/system/chapters/2026-06-25-github-issue-roundtrip/prd.md) · Decision record: [`adr-001`](https://github.com/seevali/ralph-loop-demo/blob/main/system/chapters/2026-06-25-github-issue-roundtrip/adr-001-github-as-shared-mutable-state.md)

## Context (cold-start)

The **Ralph Loop** (`scripts/ralph-loop.sh`) builds software one story at a time, each step a fresh `claude -p` process. Its **Path A** mode (`--issue N`) today *reads* a GitHub issue via the `gh` CLI and plans+builds it, but is **read-only against GitHub** — no comment, no label, no branch, no PR. As of 2026-06-25 the result of a loop run lives only in the operator's local terminal and `git log`; the issue author sees nothing.

This epic takes Path A from **read-only** to **write-back**: closing the loop so the loop's work shows up where the human already lives — as a reviewable pull request linked to the issue.

## The product (five child issues, one product)

Build order optimizes for **trust before scale** (idea numbers are stable identities, *not* build order):

```
1 Round Trip → 4 Triage → (2 Confessing PR, 3 Worktree) → 5 Swarm
```

<!-- RALPH:CHILDREN -->
_(child issue checklist injected here by `issues/create-github-issues.sh`)_
<!-- /RALPH:CHILDREN -->

## Cross-cutting invariants (every write-touching child inherits these)

1. **`--write` default-off** — every GitHub mutation gated behind a `--write` flag (backed by `GITHUB_WRITE`, default `0`), funneled through `gh_comment_op` / `gh_label_op` / `gh_pr_op` helpers that no-op (log `[dry] gh …`, return 0) when off. With the flag off, behavior is byte-identical to today's read-only loop. **Build these three helpers first.**
2. **Idempotency** — re-running any phase converges to the same GitHub state, never duplicates it (find-by-marker comment edits, PR-URL persisted to avoid duplicate PRs, single-call label transitions).
3. **No auto-merge / auto-close** — the human's thumb stays on the merge button.

See [`adr-001-github-as-shared-mutable-state.md`](https://github.com/seevali/ralph-loop-demo/blob/main/system/chapters/2026-06-25-github-issue-roundtrip/adr-001-github-as-shared-mutable-state.md) for the reasoning (the "Rubicon": write-back makes GitHub shared mutable state with multiple writers).

## Autonomy ladder (default: supervised)

Rung 0 read-only (today) → **Rung 1 supervised write (this chapter's default)**: `--write` on, draft PR + comments + labels, Triage asks before building, never merges/closes → Rung 2 trusted write (earned per-repo) → Rung 3 fire-and-forget scheduler (out of scope, earned later).

## Dogfooding guard

All child issues carry a scan-excluded **`roadmap`** label so the loop does not pick up its own roadmap as work before the Triage gate (Idea 4) exists. Build the Round Trip **by hand**; then dogfood Ideas 2–5 through Path A while measuring the **merge-as-is rate** (% of loop-opened PRs merged without hand-edits — the primary trust metric).

## Definition of done (epic)

- [ ] All five child issues closed (or explicitly killed per their kill criteria).
- [ ] `prd.md` §9 traceability table reflects shipped behavior.
- [ ] Merge-as-is rate measured on serial runs before any move to Swarm concurrency (v2).
