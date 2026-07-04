> **Idea 2 / 5 · the trust interface** · epic: GitHub Issue Round-Trip & Autonomy
> Source of truth: [`prd.md` §3 Idea 2](https://github.com/seevali/ralph-loop-demo/blob/main/system/chapters/2026-06-25-github-issue-roundtrip/prd.md)

## Context (cold-start)

The Ralph Loop builds an issue story-by-story, producing per-story artifacts: `docs/stories/<id>.md` (the SM spec with acceptance criteria), `<id>-done.md` (the Dev summary), `<id>-review.md` (the review verdict). The "Round Trip" issue (Idea 1) adds a draft PR. This issue is about *what goes in that PR's body*.

## Problem

A draft PR with a thin "implemented the feature" description just moves the trust vacuum downstream. Faced with a wall of diff and a one-line description, the reviewer either rubber-stamps or re-reads everything. Neither uses the human's scarce attention well.

## Proposed mechanism

Synthesize the PR body from artifacts the loop **already produces**, so the PR reads like a careful colleague wrote it:

1. **"I had to guess" section, up top.** Collect the assumptions the planning/dev agents recorded (Phase 0 records assumptions explicitly; per-story specs note open questions). Surface them first — that is where the human's judgment is actually needed.
2. **Story → acceptance-criterion → commit map.** For each `### Story N.k`, list its acceptance criteria and the `feat(N.k):` commit(s) that satisfy them (from `git log`).
3. **Narrative breakdown.** "Closes #N. Broke this into K stories: …" — a synthesis of the per-story `-done.md` summaries.

**Files touched:** `scripts/ralph-loop.sh` (PR-body builder reading `docs/stories/*` + `git log`); feeds the `gh pr create --body-file` / `gh pr edit` from Idea 1.

## Acceptance criteria

**Shipped (2026-07-04):** `render_pr_body()` is a pure function of on-disk artifacts + `git log` (offline fixture smoke proves byte-determinism and zero `gh` calls during render); body lands once via `update_issue_pr_body` in the all-green completion block BEFORE the PR graduates; the body is loop-owned only while the PR is a draft (isDraft guard — human edits on a ready PR are never overwritten); guess extraction uses end-anchored uncertainty headings + colon-required `ASSUMPTION:`/`GUESS:`/`OPEN QUESTION:` labels to avoid confessing completed work.

- [x] The PR body contains an "I had to guess" / uncertainties section listing recorded assumptions; when none were recorded, it says so explicitly (never silently empty).
- [x] Every shipped story appears with its acceptance criteria mapped to the satisfying commit hash.
- [x] The body builder is a **pure function of on-disk artifacts + `git log`** — extractable and testable offline (fixture in → expected markdown out) with no `gh` call.
- [x] Re-running regenerates the same body deterministically (idempotent; pairs with Idea 1's `gh pr edit`).
- [x] `prd.md` §3 Idea 2 matches shipped behavior (anti-drift DoD).

## Dependencies & sequencing

- **Blocked by:** The Round Trip (Idea 1) — the PR must exist before its body can be synthesized. Pulled up to build *next to* Idea 1 (it is the trust interface), as soon as the PR exists.
- **Blocks:** nothing hard, but materially improves Swarm review ergonomics.

## Out of scope

Opening the PR (Idea 1), worktree isolation, triage, any auto-merge based on confidence (explicitly forbidden — confidence is surfaced for the *human*, never acted on automatically).

## Glossary

**Confessing PR** — a PR whose body surfaces the agent's recorded uncertainties at the top, so review attention lands on the risky decisions. **Per-story artifacts** — `docs/stories/<id>.md` / `<id>-done.md` / `<id>-review.md`, written by the loop during a build.
