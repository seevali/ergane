# PRD — GitHub Issue Round-Trip & Autonomy (Ralph Loop System Track)

**Chapter:** `system/chapters/2026-06-25-github-issue-roundtrip/`
**Status:** **Built** — drafted 2026-06-25; all five ideas shipped (Idea 1: 2026-06-26, hand-built; Ideas 2–5: 2026-07-04, supervised multi-agent orchestration — see `BUILD-JOURNAL.md`). Each §3 idea carries a dated **Shipped** note recording final behavior and deviations (the anti-drift discipline of §9). Open: the live `--write`-on dogfood run (§6) and the merge-as-is-rate measurement (§7).
**Supersedes nothing. Builds on:** `system/chapters/2026-06-24-github-issue-intake/` (the completed read-only "Path A" intake).
**Part of the larger architecture:** `system/design/issue-native-bmad-loop.md` (the parent design that unifies GitHub Issues + BMAD + the Ralph Loop). That doc is the source of truth for cross-cutting architecture; this PRD is the source of truth for *this chapter's* features.
**This document is the source of truth for this chapter.** GitHub issues are *views* of it (see §9 Traceability). A fresh reader should be able to act on this file alone.

---

## Cold-start reading order (read in this order, no prior context assumed)

1. **§1 Context & current state** below — what the Ralph Loop is, and exactly what its GitHub support does *today* (2026-06-25).
2. **§2 The problem & the job** — why we are extending it.
3. **§3 The five ideas**, read in *build order* (not idea-number order): Round Trip → Triage Before Toil → (Confessing PR, Worktree-per-Issue) → Swarm + Mission Control.
4. **`adr-001-github-as-shared-mutable-state.md`** (same folder) — the one irreversible architecture decision and its invariants. Read before implementing *any* write-back.
5. **`scripts/ralph-loop.sh`** at the repo root — the current `--issue` implementation (the read-only Path A this chapter extends).
6. **GitHub issues** labeled `ralph:issue-support` — live status & discussion. *Available, never required:* this PRD is self-sufficient; the issues track work, they do not define it.

---

## 1. Context & current state (as of 2026-06-25)

**The Ralph Loop** is `scripts/ralph-loop.sh` — a Bash orchestrator (`set -euo pipefail`) that builds software one story at a time. Each step (plan a story → implement → review → fix) runs in a **fresh `claude -p` CLI process** with no shared chat history; all context is reloaded from the file system (PRD, epic, story spec, diff). This "clean context per step" is the Ralph pattern; prompt caching makes the repeated context cheap. Roles map to BMAD agent skills (BMAD = the agent-skill framework installed under `.claude/skills/`): Scrum Master = `bmad-create-story`, Developer = `bmad-dev-story`, Reviewer = `bmad-code-review`. Multi-model routing: SM=haiku, Dev=sonnet, Review=opus.

This repo has **two tracks** (see root `CLAUDE.md`): the **Demo Track** (a frozen Exchange Rates Dashboard at `src/`) and the **System Track** (`system/`, where the loop improves itself, organized as dated "chapters"). This PRD is System Track work — it evolves the loop itself.

**What GitHub support does today** — the "Path A intake" built in the `2026-06-24-github-issue-intake` chapter:

- `--issue N [--repo OWNER/NAME]` fetches **one** issue via the `gh` CLI (`gh issue view N --json number,title,body,labels,milestone`), then runs a **Phase 0 (Plan)**: PM produces a PRD (`docs/prd/issue-N.md`), an optional Architecture pass (`docs/architecture/issue-N.md`), and a Planner produces an epic+stories (`docs/epics/issue-N.md`) whose `## Epic N:` / `### Story N.k:` headers the existing build loop (Phase 2) already parses. Story IDs are namespaced under the issue number (issue 42 → `42.1`, `42.2`, …).
- It is **read-only against GitHub.** `gh` is invoked at exactly four sites — auth check, repo view, issue view — and never writes. No comments, no labels, no branch, no pull request, no issue close.
- **Completion is tracked locally:** `is_story_complete()` greps `git log` for `feat(<id>):`; durable state is git history + on-disk markdown. The loop is stateless in memory.
- **One issue per invocation.** No queue, no polling, no scheduling, no concurrency.
- The 06-24 chapter was **built and statically verified** (`bash -n`, `--dry-run-prompts`, error-path smokes) but, as of 2026-06-25, **never run end-to-end against a live issue.** A first live Path A run is itself a prerequisite validation for this chapter.

**Deliberately deferred by the 06-24 chapter (this chapter picks them up):** git-branch-per-issue, draft-PR tail, issue claiming / label flips, autonomy gating, scheduler/cron, auto-close, multi-issue queue.

---

## 2. The problem & the job

Today the loop does the work and then **abandons the human at the finish line**: the result lives only in the operator's local terminal and file system. The issue author on GitHub sees nothing; the operator must spelunk through `git log` to learn what happened. The back half of the lifecycle a human actually cares about — *reviewable result → merged/closed* — does not exist.

**The core job (Jobs-to-be-Done), in the user's voice:**

> *"When I point the loop at a GitHub issue, I want the result to show up where I already live — on the issue, as a reviewable pull request — so I can review and merge without babysitting a terminal or excavating a local git log."*

**Primary users and their distinct jobs:**

| User | The job they hire the loop for |
|------|--------------------------------|
| **Solo maintainer** (Seevali) | "Burn down my own backlog: file an issue, get a reviewable PR back." |
| **OSS triager** | "Tell me which stranger-filed issues are even *ready* to build before spending tokens on them." |
| **Team / burn-down mode** | "Work many issues in parallel, isolated, and surface a stack of PRs I can review." |

**This is a real product, not a demo.** That reframing (decided 2026-06-25) changes priorities in three concrete ways, carried throughout this PRD:
1. **Order optimizes for *trust earned*, not *capability shown*.** We do not fan out to N issues until the round trip is trustworthy on *one*. (See §4 build order.)
2. **Write-back is a safety boundary, not a feature toggle.** See the ADR and the `--write` invariant (§5).
3. **Success is measured by whether output is *shippable*, not whether it *ran*.** See §7 metrics (the merge-as-is rate).

---

## 3. The five ideas

Each idea is one **epic** of this one product. Idea numbers (1–5) are *stable identities* that match the GitHub `ralph:<feature>` labels and the issue body files in `issues/`. **Idea number ≠ build order** — build order is the dependency arrow in §4.

### Idea 1 — The Round Trip *(label: `ralph:round-trip`, `type:feature`)*
**JTBD:** "When I run the loop on an issue, I want a reviewable PR linked back to that issue — not a result buried locally."
**Mechanism:** branch-per-issue (`ralph/issue-N`) → draft PR opened at intake → a single self-updating issue comment narrating progress → verdict-gated labels. All via `gh` write verbs (`gh pr create --draft`, `gh issue comment`, `gh issue edit --add-label/--remove-label`), staying at the existing `gh` boundary — no octokit, no REST. Gated behind a `--write` flag (default **off**); with the flag off the loop is observably identical to today's read-only behavior.
**Why it's the spine:** every other idea depends on this. Without a reviewable result delivered where the human lives, the rest is decoration on a pipeline that doesn't deliver.
**Shipped (2026-06-26, hand-built):** exactly as specified — `--write` default-off central gate + `gh_comment_op`/`gh_label_op`/`gh_pr_op` guards, `ralph/issue-N` branch, one idempotent draft PR (URL persisted to `docs/prd/issue-N-pr.txt`), one fenced self-updating comment, single-edit label transitions, `gh pr ready` graduation on all-green. See the 2026-06-26 TIMELINE entry. Later hardening from Idea 3 (2026-07-04): PR recovery by branch, constrained to OPEN PRs, so a discarded URL file can never cause a duplicate create or resurrect a merged PR.

### Idea 2 — The Confessing PR *(label: `ralph:confessing-pr`, `type:feature`)*
**JTBD:** "When the loop hands me a PR, I want to know what it was *unsure* about, so my limited attention lands on the risky decisions — not on re-reading 600 confident-looking lines."
**Mechanism:** the PR body is *synthesized* from the per-story artifacts the loop already produces (`docs/stories/<id>.md` spec, `<id>-done.md` summary, `<id>-review.md` verdict). It maps each acceptance criterion to the `feat(<id>):` commit that satisfies it, and surfaces an **"I had to guess"** section at the top listing the assumptions the planning/dev agents recorded.
**Why it matters:** this is the *trust interface* — the instrument that lets the human calibrate the autonomy dial. An agent that says "I guessed on the token-refresh strategy, please check" earns far more trust than one presenting a flawless-looking wall. Pulled up next to Idea 1 in build order for this reason.
**Shipped (2026-07-04, commit `4316c2a`):** `render_pr_body()` is a pure function of on-disk artifacts + `git log` (no `gh`, byte-deterministic — proven by an offline fixture smoke). Sections in order: "⚠️ I had to guess" (harvested from headings *ending in* an uncertainty keyword and colon-required `ASSUMPTION:`-style labels — end-anchoring keeps completed work like "Risk Mitigations" out of the confession; explicit "none recorded" line when empty), story → AC → `feat(N.k):` commit map, per-story narratives, loop-ownership footer. One write site: `update_issue_pr_body()` in the all-green completion block, before graduation — and only while the PR is still a draft (isDraft guard), so a re-run never overwrites human edits on a ready PR. The PR is *created* with the PRD as body (Idea 1, unchanged); the confessing body supersedes it at completion.

### Idea 3 — Worktree-per-Issue *(label: `ralph:worktree`, `type:plumbing`)*
**JTBD:** "When I run more than one issue, I want each to build in its own clean tree, so they don't trample each other or contaminate `git status`."
**Mechanism:** `git worktree add ../ralph-issue-N ralph/issue-N` at the start of an issue run; every `claude -p` step runs with cwd set to the worktree. The filesystem-native take on sandcastle's "branch" strategy — no daemon, no in-memory queue. Completion checks (`git log` grep) stay correct because each worktree's log sees only that branch.
**Why it's plumbing:** it is the isolation that Idea 5 (concurrency) stands on, and it makes Idea 1's branches clean. It reads first in build order even though it isn't the headline. Known cost: worktrees leak on crash — requires a reaper (`git worktree prune` + an `EXIT` trap).
**Shipped (2026-07-04, commit `6ae7cf6`) — one deliberate deviation:** worktrees live **in-repo at `.ralph/worktrees/issue-N`** (gitignored), not the sibling `../ralph-issue-N` sketched above — the root `CLAUDE.md` self-contained-repo guardrail forbids `../` references, and the in-repo location satisfies the artifact seam structurally (planning docs readable from the main tree at that path, plus a breadcrumb `.info`; the main tree's tracked status stays clean). `--worktree` is Path A-only, default off (absent = byte-identical behavior). Setup runs before Triage/Phase 0 and re-points the run's roots so every downstream step, including completion greps, scopes to the tree. Teardown: only a fully-green run removes the tree (`--force`, branch always kept); crashes/parks/`--plan-only` keep it as *resumable state* — the next run of the same issue resumes it; `git worktree prune` at setup reaps manually-deleted trees. Companion hardening: `ensure_issue_pr` recovers the PR by branch, OPEN PRs only.

### Idea 4 — Triage Before Toil *(label: `ralph:triage`, `type:feature`)*
**JTBD:** "When a stranger files an issue, I want the loop to *read* it and tell me whether it's even buildable — before spending tokens trying to build it."
**Mechanism:** a readiness **pre-phase** ahead of Phase 0. It scores the issue, posts clarifying questions *as an issue comment* when the issue is underspecified, and applies a stage label (`ralph:ready` / `ralph:needs-triage` / `ralph:blocked` or a `wontfix-candidate` marker). Only `ralph:ready` issues are promoted into the build loop.
**Why it's high in the order:** the moment write-back exists (Idea 1), the next-most-expensive failure is the loop *confidently building the wrong thing* from an underspecified issue. Triage is the cheapest guard against that. It also produces the stage-label vocabulary the rest of the system shares (§8 glossary). **Also the dogfooding safety gate** — see §6.
**Shipped (2026-07-04, commit `9f070ae`):** the scorer is a **pure deterministic bash classifier** (`triage_classify`), not an LLM persona — the "deterministic given the issue content" AC rules an LLM out; one could layer on later, *behind* this gate. Classifications: `ready` → `ralph:ready`, promoted into Phase 0; `needs-info` → clarifying questions posted as ONE fenced self-updating comment (`RALPH:TRIAGE` markers, fail-closed) + `ralph:needs-triage`, parked; `wontfix-candidate` → `ralph:blocked` + explanatory comment, parked (humans close — I3); `roadmap` label → parked with **zero writes** (§6's recursion guard made mechanical). The stage labels joined the single mutually-exclusive `ralph:` namespace (`RALPH_STATUS_LABELS` 4 → 7), so "exactly one `ralph:` label" still holds repo-wide. Modes: `--triage auto|always|never`; `auto` fast-paths an already-`ralph:ready` issue with zero writes. **The gate gates even with `--write` off** (writes dry, classification logged, unready issues still not built) — `never` is the explicit bypass. Every decision appends to the local gitignored ledger `.ralph/triage-ledger.tsv` (the §7 precision metric's raw data).

### Idea 5 — The Swarm + Mission Control *(label: `ralph:swarm`, `type:feature`)*
**JTBD:** "When I have 40 stale issues and a weekend, I want to work many in parallel, isolated, and get back a reviewable stack of PRs — and I want to know which of the running jobs needs me *right now*."
**Mechanism:** multi-issue fan-out built on Worktree-per-Issue (Idea 3), plus a `ralph watch` terminal dashboard (one row per job: issue, phase, story X/Y, elapsed, cost, health glyph) and a **per-job pause/resume/abort brake**.
**Scope decision (v1):** **concurrency is deferred.** v1 ships *serial* multi-issue (a queue of issues worked one after another) plus the dashboard and brake. True parallel execution is a separately-justified v2 bet — "fan-out + dashboard + pause/abort" is three products, and the bet does not need concurrency to prove itself. The brake must ship in the *same* increment as any throttle.
**Hard rule (all ideas, Idea 5 especially):** the loop never merges or closes its own PR/issue. Auto-merge/auto-close is explicitly out of scope — the day the tool closes its own issues unwatched is the day people stop reading what it does.
**Shipped (2026-07-04, commit `07c1316`) — serial v1 exactly as scoped:** `--issues 12,15,19` or `--issues ready` (open issues labeled `ralph:ready` — Triage's promotion gate, so the §6 recursion guard composes structurally; fails closed on `gh` errors). The driver re-invokes the loop itself per issue (`--issue N --worktree` + forwarded flags), strictly one child at a time; a failing job never stops the queue; exits map to per-job status files under gitignored `.ralph/jobs/`. "`ralph watch`" shipped as **`scripts/ralph-watch.sh`**: a read-only dashboard (issue, state, story X/Y, elapsed, cost, health glyph; flags a stale/stuck running job) whose only writes are the brake's control files. **The brake shipped in the same increment**: `pause|resume|abort N` control files honored between every step inside `check_interrupted()` — inert unless the driver exported `RALPH_JOBS_DIR` (standalone runs byte-identical); abort exits 4; Ctrl-C beats pause. Every driver summary prints the reviewer-despair guard; the §7 kill decision stays human. Concurrency remains v2, unbuilt, deliberately.

---

## 4. Build order (the dependency arrow)

Decided 2026-06-25 (the "product-revised" arrow — optimizes for trust before scale):

```
        ┌──────────────────────────────────────────────┐
        │                                              ▼
  [1 Round Trip] ──▶ [4 Triage] ──▶ [2 Confessing PR]  [3 Worktree] ──▶ [5 Swarm]
        │                                                   ▲              (serial v1;
        └───────────────────────────────────────────────────┘               concurrency = v2)
```

- **1 Round Trip** — no blockers. The spine. Build first, **by hand** (not via the loop — see §6).
- **4 Triage** — blocked by 1. Promoted ahead of 2/3 because it guards the most expensive failure once write-back exists.
- **2 Confessing PR** — blocked by 1. Pulled up next to 1 as the trust interface; can begin once the PR exists.
- **3 Worktree** — blocked by 1. Plumbing for isolation; prerequisite for 5.
- **5 Swarm + Mission Control** — blocked by 3 (and effectively by 1 and 4). The capstone. Serial-only in v1.

These edges are encoded as GitHub `blocked-by` relationships on the issues and as the checklist in the epic issue.

---

## 5. Cross-cutting invariants (apply to every write-touching increment)

These are **non-negotiable acceptance criteria** on every story that writes to GitHub. The reasoning lives in `adr-001-github-as-shared-mutable-state.md`; restated here so no implementer misses them.

1. **`--write` default-off.** Every code path that mutates GitHub state (comments, labels, branches, PRs) is gated behind a `--write` flag that defaults to off. With it off, behavior is byte-observably identical to today's read-only loop. Implement as `GITHUB_WRITE`-guarded helpers (`gh_comment_op`, `gh_label_op`, `gh_pr_op`) that log `[dry] gh …` and return 0 when the flag is off. Build these three helpers *first*; features are thin callers on top. This is what keeps "agent-runnable, deterministic, no manual testing" true — the network is a flag flip, and every smoke runs with it off.
2. **Idempotency.** Re-running any phase must converge to the same GitHub state, never duplicate it. "Running phase N twice produces the same GitHub state as running it once." Mechanisms: find-by-marker-and-edit for the self-updating comment (HTML-comment fences, fail-closed if fences are malformed); check-existing-before-create for the PR (persist the PR URL to `docs/prd/issue-N-pr.txt`); single `gh issue edit --add-label X --remove-label Y` calls so a crash mid-transition lands the same terminal state.
3. **Undo / blast radius is priced in.** Open question to resolve before Idea 1 ships: *when `--write` is on and the loop opens a wrong PR on a repo others watch, what is the undo, and what does the misfire cost?* This answer becomes the first acceptance criterion of Idea 1. A read-only loop that misfires wastes tokens; a write-back loop that misfires spams a real repo and real people.

---

## 6. The autonomy dial (a first-class product decision, with a default)

Autonomy is a **trust ladder**, not a boolean. Default position (decided 2026-06-25): **supervised.**

| Rung | What's on | Unlock condition |
|------|-----------|------------------|
| **0 — Read-only** (today) | No writes. `--write` off. | n/a (default, always available) |
| **1 — Supervised write** (this chapter's default) | `--write` on; opens draft PR + comments + labels; **Triage asks before building**; never merges/closes. | Operator opts in per run. |
| **2 — Trusted write** | Skips clarifying-question gate for issues scoring "ready"; still draft PRs, still no auto-merge. | Earned per-repo after merge-as-is rate clears a bar (§7). |
| **3 — Fire-and-forget** (scheduler/cron) | Loop polls and works `ralph:ready` issues unattended. | Earned; explicitly *out of scope* for this chapter — it is the reward for trust, not the path to it. |

**Rationale:** the cost of a wrong autonomous action on shared GitHub state is high; the cost of one extra confirmation is near zero. So default supervised, and let the dial climb per-repo as trust accumulates.

### Dogfooding (validation strategy, NOT build strategy)

The five issues this chapter files can themselves be fed to Path A — the most honest acceptance test there is ("can the loop build the thing that lets the loop build things?"). But:

- **Build Idea 1 by hand.** Coupling an unproven capability to its own bootstrap deadlocks. Round Trip is hand-authored; then Ideas 2–5 may be fed to the loop and the **merge-as-is rate measured** (§7). Dogfooding is the validation plan, not the implementation plan.
- **Roadmap-recursion guard.** These five planning issues live in the same repo the loop scans. Until Triage (Idea 4) exists to promote "ready" deliberately, all five carry a scan-excluded **`roadmap`** label, and any loop run uses a curated allowlist rather than scanning open issues. Widen the filter only once Triage can defend the boundary. This is cheap insurance against the loop picking up "implement The Swarm" as a work item before the gate exists.

---

## 7. Success metrics & kill criteria

A bet has stakes; stakes mean some increments can lose. "It ran" is not success.

**Adoption / success metrics:**
- **Merge-as-is rate** (the headline trust gauge): % of loop-opened PRs merged without the operator hand-editing the diff. Target: rising over successive runs; Idea 5 is not justified until this clears a per-repo bar on serial runs.
- **Time from issue-filed → draft-PR-opened.**
- **Triage precision** (Idea 4): % of issues Triage labels `ready` that the loop then builds to a merge-able PR (i.e., Triage didn't wave through garbage).
- **Operator-touch count:** number of terminal interventions per issue resolved (target: trends toward zero at higher autonomy rungs).

**Kill criteria (when to rip an increment out):**
- **Round Trip:** if supervised write-back produces PRs the operator never merges as-is (merge-as-is rate ≈ 0 across a meaningful sample) → the loop's output isn't trustworthy; stop and fix quality before adding surface.
- **Triage:** if `ready`-labeled issues fail to build more often than unlabeled ones, Triage is anti-signal → remove it.
- **Swarm:** if serial multi-issue produces more PRs than the operator can review (reviewer despair) → do not proceed to concurrency; the bottleneck is review, not throughput.

---

## 8. Glossary

- **Path A / Path B** — Path A = `--issue N` intake (read-only today); Path B = `--epic FILE` execute (the original loop). Selected by presence/absence of `--issue`.
- **Phase 0** — the planning phase Path A runs before the build loop (PRD → optional architecture → epic).
- **Round trip** — the full lifecycle issue-filed → work done → reviewable PR → human merges/closes.
- **Confessing PR** — a PR whose body surfaces the agent's recorded uncertainties ("I had to guess") at the top.
- **Verdict-gated label** — a GitHub label driven by the existing review contract (first line `REVIEW_PASSED` / `REVIEW_FAILED`).
- **Readiness pre-phase / Triage** — a gate that scores an issue's buildability and labels it before any build tokens are spent.
- **The Rubicon** — the state-model shift introduced by write-back: from "local git is the source of truth" to "GitHub is shared mutable state with other writers." Makes idempotency mandatory. See ADR-001.
- **`roadmap` label** — a scan-excluded label marking issues the loop must NOT pick up as work (e.g., this chapter's own planning issues) until Triage can promote them.
- **Merge-as-is rate** — % of loop-opened PRs merged with no human edits to the diff; the primary trust metric.
- **`gh`** — the GitHub CLI (`github.com/cli/cli`); the *only* GitHub mechanism the loop uses (no octokit, no REST).

---

## 9. Traceability (PRD ↔ issue ↔ code)

GitHub issues are **not in the file system** — a fresh LLM that clones this repo sees this PRD and the code, but not the issues. Therefore: **this PRD holds the substance; each issue is a thin pointer into it; code comments point to PRD anchors, never to an issue number** (a `// see #42` rots when trackers migrate; `// implements Round Trip — …/prd.md#idea-1` survives). Issue numbers below are informational; the PRD section anchors are the real keys. The numbers are filled in once `issues/create-github-issues.sh` runs (see chapter README).

| Idea | PRD section | GitHub issue | Code home (when built) |
|------|-------------|--------------|------------------------|
| Round Trip | §3 Idea 1 | [#1](https://github.com/seevali/ralph-loop-demo/issues/1) | `scripts/ralph-loop.sh` (intake + commit + completion blocks) |
| Confessing PR | §3 Idea 2 | [#3](https://github.com/seevali/ralph-loop-demo/issues/3) | `scripts/ralph-loop.sh` + PR-body synthesis from `docs/stories/*` |
| Worktree-per-Issue | §3 Idea 3 | [#4](https://github.com/seevali/ralph-loop-demo/issues/4) | `scripts/ralph-loop.sh` (run setup/teardown) |
| Triage Before Toil | §3 Idea 4 | [#2](https://github.com/seevali/ralph-loop-demo/issues/2) | `scripts/ralph-loop.sh` (pre-Phase-0 gate) |
| Swarm + Mission Control | §3 Idea 5 | [#5](https://github.com/seevali/ralph-loop-demo/issues/5) | `scripts/ralph-loop.sh` + a `ralph watch` view |
| **Epic (umbrella)** | this PRD | [#6](https://github.com/seevali/ralph-loop-demo/issues/6) | — |

**Anti-drift discipline:** substance lives here, so there is little to drift. Each idea's GitHub issue includes a Definition-of-Done checkbox `[ ] PRD section matches shipped behavior`; because the loop builds against acceptance criteria, this makes the loop keep its own book of record current. A future drift-check script can assert "every `ralph:<feature>` label has a matching PRD section, and every flag the PRD names appears in `--help`" — making drift a failing test, not a vibe.
