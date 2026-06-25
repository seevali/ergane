# Chapter: GitHub Issue Round-Trip & Autonomy

**Status:** Planning — drafted 2026-06-25 (System Track). Issues filed; no stories built yet.
**Work surface:** `scripts/ralph-loop.sh` + `scripts/prompts/**` + `gh` write paths + docs.
**Part of:** [`../../design/issue-native-bmad-loop.md`](../../design/issue-native-bmad-loop.md) — the parent architecture (how GitHub Issues + BMAD + the Ralph Loop unify). This chapter's five issues are *partial implementations* of that design (see its §11 traceability).
**Builds on:** [`../2026-06-24-github-issue-intake/`](../2026-06-24-github-issue-intake/) — the completed *read-only* Path A intake. This chapter takes intake from **read-only** to **write-back**.
**Driver:** authored interactively (BMAD party-mode roundtable: Mary/analyst, John/PM, Winston/architect, Amelia/dev, Sally/UX, Paige/tech-writer), 2026-06-25. Build work is not yet scheduled into a loop run.

> **Cold-start note (fresh reader, any LLM, no prior context).** "The loop" is
> `scripts/ralph-loop.sh`, a Bash orchestrator (`set -euo pipefail`) that builds
> software one story at a time, each step a fresh `claude -p` process (the "Ralph"
> pattern: clean context per step). BMAD is the agent-skill framework under
> `.claude/skills/`. "System Track" vs "Demo Track" is the repo's two-track split
> (root `CLAUDE.md`): Demo Track builds the React app under `src/`; System Track
> improves the loop itself, as dated chapters here. "Path A" is the loop's
> `--issue N` mode — today it *reads* a GitHub issue via the `gh` CLI and
> plans+builds it, but never writes back. This chapter adds the write-back.

## Why this chapter exists

Today the loop, after building from an issue, **abandons the human at the finish line**: the result lives only in the operator's local terminal and `git log`. The issue author on GitHub sees nothing — no comment, no status, no PR. This chapter closes the loop back to GitHub so the result shows up *where the human already lives*: a reviewable pull request linked to the issue.

**This is real product work, not a demo.** (The repo folder is named `demos/ralph-loop-demo`, but the System Track is the maintainer's real Ralph-loop evolution — a product being bet on. Note: relocating the System Track out of a `demos/`-named folder is a flagged future cleanup, not part of this chapter.)

## Reading order

1. [`prd.md`](prd.md) — the evolution PRD (the **source of truth**). Start at its §1 Context.
2. [`adr-001-github-as-shared-mutable-state.md`](adr-001-github-as-shared-mutable-state.md) — the one irreversible decision (write-back makes GitHub shared mutable state) and its invariants. **Read before implementing any write path.**
3. [`issues/`](issues/) — the GitHub-issue body files (one epic + five children) and the idempotent `create-github-issues.sh` that files them.
4. `scripts/ralph-loop.sh` (repo root) — the current read-only `--issue` implementation this chapter extends.

## The five ideas (one product, five epics)

Idea numbers are stable identities (they match the `ralph:<feature>` labels). **Build order is the dependency arrow, not the idea numbers.**

| # | Idea | Label | What it adds |
|---|------|-------|--------------|
| 1 | **The Round Trip** | `ralph:round-trip` | branch-per-issue → draft PR → self-updating issue comment → verdict-gated labels, behind `--write` (default off). The spine. |
| 2 | **The Confessing PR** | `ralph:confessing-pr` | PR body synthesized from per-story artifacts, with an "I had to guess" uncertainty section up top. The trust interface. |
| 3 | **Worktree-per-Issue** | `ralph:worktree` | `git worktree` isolation for clean, concurrent-capable runs. Plumbing. |
| 4 | **Triage Before Toil** | `ralph:triage` | a readiness pre-phase: read the issue, ask clarifying Qs as a comment, label, only promote `ready`. The judgment gate. |
| 5 | **Swarm + Mission Control** | `ralph:swarm` | serial multi-issue (v1) + `ralph watch` dashboard + per-job pause/abort brake. Concurrency deferred to v2. |

**Build order (decided 2026-06-25 — trust before scale):**
`1 Round Trip → 4 Triage → (2 Confessing PR, 3 Worktree) → 5 Swarm`.
Build Idea 1 **by hand**; then Ideas 2–5 may be dogfooded through Path A while measuring the merge-as-is rate (see `prd.md` §6–§7).

## Key design decisions (the *why*)

- **`gh`-only, no octokit/REST.** Write-back adds *verbs* (`gh issue comment`, `gh pr create --draft`, `gh issue edit --add-label`) to the existing four read sites. Stay at the `gh` boundary.
- **`--write` default-off is a safety boundary, not a toggle.** With it off, the loop is observably identical to today's read-only behavior. All writes funnel through `GITHUB_WRITE`-guarded helpers so every test runs with the network dark. (ADR I1.)
- **Idempotency is mandatory** the moment we cross the Rubicon — self-updating comment via fail-closed HTML-comment fences, PR-URL persisted to avoid duplicates, single-call label transitions. (ADR I2.)
- **No auto-merge / auto-close, ever.** The human's thumb stays on the merge button. (ADR I3.)
- **Dogfooding is the validation plan, not the build plan.** Build the spine by hand; measure the loop building the rest.

## Dogfooding-recursion guard (important)

These five planning issues live in the same repo the loop scans. Until Triage (Idea 4) exists to promote `ready` issues deliberately, **all five carry a scan-excluded [`roadmap`] label**, and any loop run uses a curated allowlist instead of scanning open issues. This stops the loop from picking up "implement The Swarm" as a work item before the gate exists. See `prd.md` §6.

## Out of scope (this chapter)

Scheduler/cron fire-and-forget autonomy (the top rung of the autonomy ladder — earned later, not now), true concurrent execution (Swarm v2), auto-merge/auto-close, any non-`gh` GitHub client, and relocating the System Track out of the `demos/` folder.

## How the issues were filed

`issues/create-github-issues.sh` is the idempotent bootstrap that creates the label taxonomy, the epic, and the five child issues from the body files in `issues/`. It is safe to re-run (it skips issues that already exist by title and `gh label create … || true`s the labels). Requires `gh` authenticated with write scope on `seevali/ralph-loop-demo`.
