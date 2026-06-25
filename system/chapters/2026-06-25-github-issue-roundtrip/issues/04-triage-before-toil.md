> **Idea 4 / 5 · the judgment gate** · epic: GitHub Issue Round-Trip & Autonomy
> Source of truth: [`prd.md` §3 Idea 4](https://github.com/seevali/ralph-loop-demo/blob/main/system/chapters/2026-06-25-github-issue-roundtrip/prd.md)

## Context (cold-start)

The Ralph Loop's Path A (`--issue N`) today assumes every issue it is pointed at is a well-formed work item: it goes straight to Phase 0 planning and builds. Strangers filing OSS issues do not file work items — they file complaints, wishes, duplicates, and vague repros.

## Problem

A loop that *builds* every issue burns tokens (and, once Idea 1 lands, opens PRs) on issues that were never buildable. The triager's real hours go into *reading* — deciding which issues are ready. The loop does none of that judgment today.

## Proposed mechanism

A **readiness pre-phase** that runs *before* Phase 0:

1. **Score readiness.** Read the issue (title, body, labels) and classify: `ready` (clear problem + enough detail), `needs-info` (underspecified), or `wontfix-candidate` (out of scope / duplicate / not actionable).
2. **Ask, don't guess.** For `needs-info`, post the specific clarifying questions *as an issue comment* (via Idea 1's `gh_comment_op`) and stop — do not build.
3. **Label the stage.** Apply `ralph:ready` / `ralph:needs-triage` / `ralph:blocked` (the stage vocabulary the rest of the system shares).
4. **Promote only `ready`.** Only `ralph:ready` issues flow into Phase 0. This is also the gate that makes it safe to widen the loop's scan beyond a curated allowlist (it can finally retire the `roadmap` exclusion for promoted issues — see `prd.md` §6).

**Files touched:** `scripts/ralph-loop.sh` (a pre-Phase-0 gate); a new `triage` role prompt overlay if scoring warrants its own persona.

## Acceptance criteria

- [ ] Each scored issue receives exactly one stage label; the classification is deterministic given the issue content.
- [ ] `needs-info` issues get a clarifying-questions comment and are **not** built (no PR, no branch).
- [ ] Only `ralph:ready` issues are promoted into Phase 0.
- [ ] **Triage precision** is measurable: of issues labeled `ready`, the % that subsequently build to a merge-able PR is tracked (kill criterion if `ready` is anti-signal — see `prd.md` §7).
- [ ] Honors `--write` default-off (no labels/comments written when the flag is off; classification still logged).
- [ ] `prd.md` §3 Idea 4 matches shipped behavior (anti-drift DoD).

## Dependencies & sequencing

- **Blocked by:** The Round Trip (Idea 1) — Triage needs the `gh_comment_op` / `gh_label_op` write helpers.
- **Promoted ahead of Ideas 2 & 3** in build order: once write-back exists, the next-most-expensive failure is confidently building the wrong thing. Triage is the cheapest guard against it.
- **Unblocks the dogfooding widen:** it retires the `roadmap` scan-exclusion for issues it promotes.

## Out of scope

Auto-closing `wontfix-candidate` issues (humans close; ADR I3), scheduling/polling for new issues (autonomy ladder rung 3, out of chapter scope), building anything (that is Phase 0 onward).

## Glossary

**Readiness pre-phase / Triage** — a gate that scores an issue's buildability and labels it before any build tokens are spent. **Stage label** — `ralph:ready` / `ralph:needs-triage` / `ralph:blocked`; shared vocabulary defined once in `prd.md` §8. **`roadmap` label** — scan-exclusion marker the loop must skip; Triage is what eventually promotes excluded issues deliberately.
