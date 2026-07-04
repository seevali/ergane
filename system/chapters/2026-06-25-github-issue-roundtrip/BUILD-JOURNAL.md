# Build Journal — how Ideas 2–5 of this chapter were built (2026-07-04)

**Status:** living document, opened 2026-07-04, updated as each idea lands.
**What this is:** the narrative + decision record of the build sessions that implemented this chapter's remaining ideas after issue #1. The [PRD](prd.md) says *what and why*; the [ADR](adr-001-github-as-shared-mutable-state.md) pins the invariants; this file records *how the work actually happened*, what was decided along the way, and what the verification caught. It exists so a fresh reader (any LLM, any provider, no conversation history — file system only) can reconstruct the journey and its reasoning.

> **Cold-start note.** "The loop" is `scripts/ralph-loop.sh` at the repo root — a Bash
> orchestrator that builds software one story per fresh `claude -p` process. "Path A"
> is its `--issue N` mode (GitHub issue → PRD/epic/stories → build). This chapter
> (see [README.md](README.md)) planned five ideas; **issue #1 "The Round Trip"** was
> hand-built on 2026-06-26 (see the repo-root `TIMELINE.md` entry of that date).
> This journal covers the remaining four, built in order **#2 Triage → #3 Confessing
> PR → #4 Worktree → #5 Swarm v1** on 2026-07-04. (Chapter "Idea" numbers and GitHub
> issue numbers differ: Idea 4 = issue #2, Idea 2 = issue #3, Idea 3 = issue #4,
> Idea 5 = issue #5 — see prd.md §9 traceability.)

---

## The build method: supervised multi-agent orchestration

Issue #1 was built *by hand* (a human-supervised Claude session editing the script directly). Ideas 2–5 were built by a third method — neither by hand nor by the loop:

- **Why not by the loop (dogfooding)?** ADR-002 (`../../design/adr-002-orchestrator-runtime.md`): the loop cannot safely modify the script it is executing mid-run. Dogfooding remains this chapter's *validation* plan (a live `--write`-on run against a real issue), not its build plan — exactly as prd.md §6 prescribes.
- **What instead:** a single orchestrating agent session (Claude Code, 2026-07-04) that (1) read the chapter docs and the full loop script, (2) made the cross-cutting design decisions and wrote a **detailed slice spec per idea** (inlined below per idea), then (3) ran, per idea, a pipeline of specialist sub-agents:
  1. **Implementer** — one agent, following the slice spec verbatim against the repo, required to keep every mechanical gate green before finishing.
  2. **Two parallel adversarial reviewers** — an *ADR-invariant auditor* (hunting I1/I2/I3 violations, safety-contract touches, spec deviations) and a *bash edge-case hunter* (set -euo pipefail hazards, quoting, exit-code semantics, and whether the new smoke would actually fail on regression).
  3. **Fixer** — verifies each finding against the code (reviewers can be wrong), fixes real ones, re-runs all gates.
  4. **Orchestrator commit** — the orchestrating session independently re-ran every gate, audited the diff hunk map against the spec's allowed regions, spot-read the new code, then committed. One commit per idea, `feat(roundtrip): #N …`.
- **The mechanical gates** (unchanged from issue #1's discipline): `bash -n` on both loop scripts; every offline smoke under [`tests/`](tests/) (they stub `gh`, never touch the network); and the `--dry-run-prompts` **byte**-diff against `tests/dry-run-prompts.golden` (the prompt-cache stability gate).

This method is worth recording because it is the repo's first use of *fan-out verification* on System Track work: independent adversarial reviewers with different lenses, run before every commit, with their findings and dispositions logged here.

---

## Idea 4 / issue #2 — Triage Before Toil (landed 2026-07-04, commit `9f070ae`)

### Design decisions (made by the orchestrator, before implementation)

1. **The classifier is deterministic bash, not an LLM.** The issue's AC reads "the classification is deterministic given the issue content." An LLM scorer cannot promise that; a pure bash scoring function can, and it is offline-testable. The scoring: +2 body ≥ 140 chars (+1 more ≥ 400), +2 markdown structure (heading/list/checkbox), +2 acceptance/expected/criteria/repro-style signal words (word-boundary matched — see finding 2 below), +1 title ≥ 20 chars, −3 question-shaped title; ≥ 5 ⇒ `ready`, else `needs-info`. Label short-circuits first: `roadmap` ⇒ `excluded`, `wontfix`/`duplicate`/`invalid` ⇒ `wontfix-candidate`. A future LLM triage persona would sit *on top of* this gate, not replace it.
2. **Stage labels join one namespace.** `ralph:ready` / `ralph:needs-triage` / `ralph:blocked` were added to `RALPH_STATUS_LABELS` (4 → 7) rather than forming a second axis, preserving the "exactly ONE `ralph:` label per issue" projection and reusing `set_issue_label`'s single-edit atomic transition (I2). Consequence: promoting to `ralph:ready` and then starting the build (`ralph:building`) consumes the ready label — its persistence matters for the queue-scan case (issue #5), where promoted-but-not-yet-built is exactly the state scanned for.
3. **The gate gates even with `--write` off.** Labels/comments go dry (I1), but an unready issue still does not build. Rationale: classification is content-based; whether the network is dark should not change *what the loop is willing to build*. The explicit bypass is `--triage never`; `--triage always` re-scores an already-promoted issue.
4. **`excluded` (roadmap) writes nothing at all** — no comment, no label. The loop must not touch its own planning issues (prd.md §6's dogfooding-recursion guard). Promotion of a roadmap issue is a human act: add `ralph:ready`.
5. **Measurability = a local ledger.** Every decision appends `epoch⟨tab⟩issue⟨tab⟩classification` to `.ralph/triage-ledger.tsv` (a new gitignored `.ralph/` runtime-state directory that later ideas also use). Triage precision (prd.md §7: % of `ready` issues that reach a mergeable PR) is computed offline from ledger + GitHub; no automation shipped, deliberately.
6. **Parking semantics reuse issue #1's vocabulary:** triage stops are `exit 2` ("parked, human needed"), mirroring `phase0_park`, with next-step guidance in the message.

### What verification caught (both fixed before commit)

1. **False-green smoke (edge-case hunter):** the new offline smoke sourced the functions under test with `set +e`, so an errexit regression in the exact shell mode the live loop runs under (`set -euo pipefail`) would never fail the smoke. Fixed: the smoke's subshells now run `set -euo pipefail`, same as the loop.
2. **Substring keyword promotion (edge-case hunter):** readiness signals used substring matches — `repro` matched "reprogram", `goal` matched "goalkeeper" — so keyword-containing but underspecified issues could score `ready` and be built. Since a false *positive* (build the wrong thing) is precisely the failure this gate exists to prevent, the signal regexes were tightened to word-boundary matching, and the smoke's fixture table gained the boundary case.

### Outcome

Smoke `tests/idea4-triage-smoke.sh` 10/10; all six pre-existing smokes green; golden byte-identical; zero diff hunks in the protected regions (`run_claude()` → `run_intake_phase()`, and `main()`).

---

## Idea 2 / issue #3 — The Confessing PR (landed 2026-07-04, commit `4316c2a`)

### Design decisions

1. **Purity as the testability lever.** `render_pr_body()` reads ONLY the epic, the per-story artifacts (`<id>.md`, `<id>-done.md`), the intake PRD, and `git log` — no `gh`, no globals, no timestamps. That makes the AC "extractable and testable offline (fixture in → expected markdown out)" literal: the smoke builds a throwaway git repo with fixture artifacts and asserts byte-identical renders across runs and zero `gh` invocations during render.
2. **Guesses come first, and absence is stated.** The "I had to guess" section leads the body (the whole point: route reviewer attention to recorded uncertainty), and when no assumptions were recorded the body says so explicitly — silence would be indistinguishable from "nothing risky here."
3. **Extraction contract, not free parsing:** guesses are harvested from (a) sections whose heading *ends with* an uncertainty keyword (assumptions / open questions / uncertainty / risks / guesses) and (b) standalone `ASSUMPTION:` / `GUESS:` / `OPEN QUESTION:` lines (colon required). Both anchors were tightened by verification (below).
4. **One write site, late.** The PR is created at intake with the PRD as body (slice b, untouched); the confessing body lands via a single `update_issue_pr_body()` call in the all-green completion block, immediately before `mark_issue_pr_ready` — so the graduated PR the human is asked to review carries the confessing body, and mid-build churn on the PR body is avoided.
5. **The body is loop-owned only while draft.** `update_issue_pr_body` checks `isDraft` (an ungated read) and skips once the PR is ready — the footer printed into the body promises exactly this, and a `--write` re-run of a finished issue must not eat a reviewer's edits.

### What verification caught (all fixed before commit)

1. **Missing isDraft guard (ADR auditor):** as first implemented, a re-run would `gh pr edit` an already-ready PR, clobbering human edits and contradicting the body's own footer contract. Fixed with the mark_issue_pr_ready-parity read + a smoke regression check (zero `pr edit` calls when `isDraft=false`).
2. **Over-broad guess harvesting (edge-case hunter):** a heading merely *containing* "risk" — e.g. `## Risk Mitigations`, a list of *completed* defensive work — poured its bullets into the trust-critical guess section, and any prose bullet starting with the word "guess" matched too. Fixed: heading keywords are end-anchored, standalone labels require a colon.
3. **Narrative anchor too narrow (edge-case hunter):** the done-summary fallback only recognized `# ` H1 titles; an H2-titled done.md yielded a false "(no implementation summary)". Fixed to any heading level.
4. **Self-caught by the implementer:** awk's `exit` still runs `END` blocks, so the narrative paragraph printed twice; caught by the smoke's determinism assertion mid-implementation, before any gate ran.

### Outcome

Smoke `tests/idea2-confessing-pr-smoke.sh` 15/15 (14 + the isDraft regression check); all seven pre-existing smokes green; golden byte-identical; the only main() change is the one allowed additive call (+2-line comment) before `mark_issue_pr_ready`.

### Orchestration note (recorded for honesty)

The workflow harness had an args-plumbing fault: the implementer received the spec path as `undefined`. It recovered correctly — located the session's slice specs on disk, cross-checked the chapter's decided build order, and implemented the right spec (Confessing PR). The orchestrator hardened the workflow (literal-fallback spec paths) for the remaining ideas. Worth recording: *the agents' recovery behavior is part of why supervised orchestration with independent verification is trustworthy — but the correct response to a lucky save is to remove the luck.*

---

## Idea 3 / issue #4 — Worktree-per-Issue (landed 2026-07-04, commit `6ae7cf6`)

### Design decisions

1. **In-repo worktrees (deviation from the issue body).** The issue's literal `git worktree add ../ralph-issue-N` puts run state *outside* the repo, violating the root `CLAUDE.md` self-containment guardrail and polluting the parent (Metis) tree. Decision: `.ralph/worktrees/issue-N`, inside the repo, gitignored. Side effect: the "artifact seam" AC (planning docs readable from the main tree) is satisfied structurally instead of by symlinks or write-through copies — both of which would have dirtied the main tree's status and broken the *other* AC.
2. **Re-point, don't thread.** Rather than passing a worktree path through every function, `ensure_issue_worktree()` re-points the run's globals (`REPO_ROOT`, `PROJECT_DIR`, `STORIES_DIR`, epic/PRD paths) and `cd`s in. Every downstream step — Phase 0, story loop, completion greps, `gh` slug resolution — follows automatically, because they already resolve through those globals. `STORIES_DIR` is re-pointed only when it still equals the default (a System-Track env override is respected).
3. **Crash state is resumable state.** A crashed/interrupted run leaves its tree in place; the next run of the same issue *resumes* it. The reaper handles the genuinely-orphaned case (`git worktree prune` for manually-deleted dirs). Teardown (`worktree remove --force`) fires only on `RALPH_ALL_GREEN=1` + exit 0 — parks, `--plan-only`, crashes, and manual-review exits keep the tree because it may hold uncommitted planning work. `--force` is deliberate: untracked runtime droppings (the PR-URL file) would otherwise block removal, and they are recoverable (below). The branch is never deleted.
4. **Ordering: worktree → triage → Phase 0.** The tree is created before anything writes files so ALL planning artifacts land in it; triage (which writes no repo files) anchors its ledger to the main root via a new `RALPH_MAIN_ROOT` global.
5. **PR-URL recovery closes the loop worktree removal opens.** Success teardown discards the untracked `docs/prd/issue-N-pr.txt`; `ensure_issue_pr` now recovers the PR by branch (`gh pr view ralph/issue-N`) before ever creating. Two refinements mattered — see catches 2 and 3.

### What verification caught

1. **Missing `set -e` in the new smoke (ADR auditor, minor):** `set -uo pipefail` — a mandatory-rule violation that could let a broken fixture mask assertion failures. Fixed to full `set -euo pipefail` with the expected-failure capture properly guarded.
2. **Merged-PR resurrection (edge-case hunter, MAJOR — the catch of the day):** the recovery read was state-agnostic; after a human merges the PR and someone re-runs the issue, recovery would return the *merged* PR's URL, skip creation, and push fresh commits with **no open PR** — invisible work, precisely what the Round Trip exists to prevent. Fixed: recovery selects OPEN PRs only (`--json url,state` + `select(.state=="OPEN")`); a merged/closed PR falls through to a fresh `gh pr create`. The slice-b smoke's stub became state-aware and a regression test proves the fall-through.
3. **Implementer's own placement correction (recorded as a deviation, accepted):** the spec asked for recovery "before the create path" as an ungated read; placed literally it would have run `gh` even with `--write` off, breaking I1's byte-parity. It sits after the write-off dry-return instead — the spec's intent (idempotent recovery), the ADR's letter (network dark when off).

### Outcome

`idea3-worktree-smoke.sh` 10/10 (real local git fixtures — creation, resume, abort/reaper, forced teardown with droppings, main-tree-on-branch conflict, parity); `slice-b` 10/10 (+2); all others green; golden byte-identical; the only `main()` change is the allowed `RALPH_ALL_GREEN=1` line.

---

*(Section for issue #5 Swarm v1 is appended when it lands.)*
