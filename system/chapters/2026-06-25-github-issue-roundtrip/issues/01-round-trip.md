> **Idea 1 / 5 · the spine** · epic: GitHub Issue Round-Trip & Autonomy
> Source of truth: [`prd.md` §3 Idea 1](https://github.com/seevali/ralph-loop-demo/blob/main/system/chapters/2026-06-25-github-issue-roundtrip/prd.md) · invariants: [`adr-001`](https://github.com/seevali/ralph-loop-demo/blob/main/system/chapters/2026-06-25-github-issue-roundtrip/adr-001-github-as-shared-mutable-state.md)

## Context (cold-start)

As of 2026-06-25, the Ralph Loop's `--issue N` mode (Path A) reads a GitHub issue via the `gh` CLI, plans it (PRD + epic), and builds it — but is **read-only against GitHub**. The work lands as local `feat(<id>):` commits; the issue author sees nothing. `gh` is currently called at four read-only sites in `scripts/ralph-loop.sh` (auth check, repo view, issue view).

## Problem

The loop abandons the human at the finish line. There is no reviewable result where the human lives — no branch, no pull request, no status on the issue. To act on the loop's output, a human must excavate the local `git log`.

## Proposed mechanism

Add GitHub **write-back**, `gh`-only (no octokit/REST), behind a `--write` flag (default off):

1. **Central guard first.** Add `GITHUB_WRITE` (default `0`) and three helpers — `gh_comment_op`, `gh_label_op`, `gh_pr_op` — that execute `gh` only when `GITHUB_WRITE=1`, else log `[dry] gh …` and return 0.
2. **Branch + draft PR at intake.** After `run_intake_phase()` writes `docs/epics/issue-N.md`: create branch `ralph/issue-N`, push, `gh pr create --draft --base main --head ralph/issue-N --title … --body-file docs/prd/issue-N.md`; capture the URL → persist to `docs/prd/issue-N-pr.txt`.
3. **Self-updating issue comment.** One comment, edited in place via HTML-comment fences (`<!-- RALPH:BEGIN -->` … `<!-- RALPH:END -->`), regenerated from local git state each update (🔵 planning → 🟡 building story X/Y → 🟢 done, PR link). Fail closed on malformed fences.
4. **Verdict-gated labels.** Drive labels off the existing review contract (first line `REVIEW_PASSED` / `REVIEW_FAILED`): build start `ralph:building`; per story `ralph:needs-fix` ↔ `ralph:in-review`; all green → `ralph:done`. Each transition is a single `gh issue edit --add-label NEW --remove-label OLD` call.
5. **Finish.** On all stories green: `gh pr ready`, and a final issue comment linking the PR.

**Files touched:** `scripts/ralph-loop.sh` (intake, per-story commit, completion blocks); new artifacts `docs/prd/issue-N-pr.txt`.

## Acceptance criteria

- [ ] With `--write` **off**, externally observable behavior is byte-identical to today's read-only Path A (verified by `--dry-run-prompts` + an error-path smoke; network never touched).
- [ ] With `--write` **on**, running `--issue N --write` creates branch `ralph/issue-N`, opens exactly one draft PR, and posts exactly one issue comment linking it.
- [ ] **Idempotency:** re-running the same issue does not create a second PR or a second comment, and does not churn labels (PR found via `docs/prd/issue-N-pr.txt`; comment edited in place; labels via single add/remove calls).
- [ ] **Branch-before-commit invariant:** assert `git rev-parse --abbrev-ref HEAD == ralph/issue-N` before the dev loop; hard-fail otherwise (so story commits never land on `main`).
- [ ] **Blast-radius answer (ADR I4):** the issue documents the undo path and cost of a wrong `--write` action on a watched repo. *(Resolve before merge.)*
- [ ] No auto-merge, no auto-close (ADR I3).
- [ ] `prd.md` §3 Idea 1 matches shipped behavior (anti-drift DoD).

## Dependencies & sequencing

- **Blocks:** Confessing PR, Worktree-per-Issue, Triage, Swarm — all of them. This is the spine.
- **Blocked by:** nothing. Build **first, by hand** (do not dogfood the spine — see `prd.md` §6).
- **External deps:** `gh` CLI authenticated with **write** scope (comment/label/PR) on the target repo; `git` ≥ branch/push.

## Out of scope

Worktree isolation (separate issue), the synthesized PR body (Confessing PR issue), triage gating (Triage issue), any concurrency, auto-merge/auto-close.

## Glossary

**Verdict-gated label** — a label driven by the review step's first-line contract (`REVIEW_PASSED`/`REVIEW_FAILED`). **`--write`** — the master flag gating all GitHub mutations, default off. **The Rubicon** — see ADR-001: write-back makes GitHub shared mutable state.
