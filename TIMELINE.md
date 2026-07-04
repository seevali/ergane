# Timeline

A chronological log of how this repo has evolved. Most-recent first.

Entries are tagged **`[Demo]`** (Demo Track — the frozen showcase) or **`[System]`** (System Track — loop-improvement work under [`system/`](system/)). See the [README's Two Tracks section](README.md#two-tracks) for the architecture.

For forward-looking design documents, browse [`system/chapters/`](system/chapters/) — one folder per improvement effort.

---

## [System] Worktree-per-Issue (issue #4) — isolation plumbing (2026-07-04)

Closed **issue #4 "Worktree-per-Issue"** — with `--worktree` (Path A only, default off), an issue run executes entirely inside its own `git worktree`, so runs never trample the main working tree, a crashed run's half-built state stays quarantined and resumable, and the Swarm (issue #5) has the isolation it stands on ([prd.md §3 Idea 3](system/chapters/2026-06-25-github-issue-roundtrip/prd.md)).

**One deliberate deviation from the issue spec, worth reading:** the issue body says `git worktree add ../ralph-issue-N` — a *sibling directory outside the repo*. That collides with the repo's oldest guardrail (root `CLAUDE.md`: self-contained, never reference `../` or the parent tree) and would litter the maintainer's parent directory. Worktrees therefore live **inside the repo at `.ralph/worktrees/issue-N`** (`.ralph/` is gitignored runtime state, introduced with issue #2). The artifact-seam AC collapses to a triviality as a bonus: planning artifacts are readable from the main tree at `.ralph/worktrees/issue-N/docs/…` while the main tree's *tracked* status stays clean throughout.

**Mechanics:** `ensure_issue_worktree()` runs before Triage/Phase 0 — prunes stale registrations (the reaper half), creates or **resumes** the tree on `ralph/issue-N` (a crashed tree is resumable state, not garbage), re-points `REPO_ROOT`/`PROJECT_DIR`/`STORIES_DIR`/epic/PRD paths so every downstream step — including completion greps — scopes to the tree automatically, writes a breadcrumb `.info`, and registers the run's only `EXIT` trap: teardown removes the tree **only on a fully-green run** (`RALPH_ALL_GREEN=1`); crashes, parks, `--plan-only`, and manual-review exits all keep the tree (uncommitted plans must never be destroyed). The branch is always kept for review — teardown never deletes it. Logs stay in the main tree (observability outlives the tree).

**The verification catch that mattered (major):** worktree removal discards the untracked PR-URL file, so `ensure_issue_pr` gained branch-based recovery — and the first cut used a state-agnostic `gh pr view <branch>`, which would *resurrect a merged/closed PR*: a re-run after merge would push new commits with **no open PR to review them**, silently. Now constrained to OPEN PRs (a merged PR falls through to a fresh `gh pr create`), with a smoke regression proving it. Also caught: the new smoke missing mandatory `set -e`. With `--worktree` absent, behavior is byte-observably unchanged (parity AC); smokes idea3 10/10, slice-b 10/10; golden byte-identical.

[Issue #4 spec](system/chapters/2026-06-25-github-issue-roundtrip/issues/03-worktree-per-issue.md) | [smoke](system/chapters/2026-06-25-github-issue-roundtrip/tests/idea3-worktree-smoke.sh) | commit `6ae7cf6`

---

## [System] The Confessing PR (issue #3) — the trust interface (2026-07-04)

Closed **issue #3 "The Confessing PR"** — the PR body is now *synthesized* from the per-story artifacts the loop already produces, so the reviewer's scarce attention lands on the risky decisions instead of a wall of confident-looking diff ([prd.md §3 Idea 2](system/chapters/2026-06-25-github-issue-roundtrip/prd.md)).

**What the body contains, in order:** an **"⚠️ I had to guess"** section *first* — assumptions and open questions harvested from the intake PRD, story specs, and done-summaries (with per-item source attribution), and when none were recorded, an explicit "none recorded" line rather than silence; then a **story → acceptance-criteria → commit map** (each `### Story N.k` with its ACs and the short hash of its `feat(N.k):` commit); then per-story **narratives** from the done-summaries; then a footer stating the body is loop-owned only until the PR is marked ready.

**How the invariants held:** `render_pr_body()` is a **pure function of on-disk artifacts + `git log`** — no `gh`, no globals, no timestamps, byte-deterministic (the offline smoke asserts two renders are identical and that the `gh` stub records zero calls during render). The single write site, `update_issue_pr_body()`, funnels through `gh_pr_op` (I1), converges on re-run (I2), never merges/closes (I3), and — a verification catch — **skips the edit once the PR is no longer a draft**, so a `--write` re-run of a finished issue can never clobber a human's edits to a ready PR (parity with `mark_issue_pr_ready`'s idempotency read). Wired as one additive call in main()'s all-green completion block, before graduation, so the human reviews a confessing body, not the intake PRD. Safety contract untouched; `--dry-run-prompts` golden byte-identical.

**Verification catches (fixed pre-commit):** the missing isDraft guard above; over-broad guess harvesting (a `## Risk Mitigations` section of *completed* work was being confessed as uncertainty — heading match now end-anchors the keyword, and standalone `ASSUMPTION:` lines require the colon); and the narrative extractor only recognizing H1 titles. The implementer also caught its own awk `exit`-runs-END double-print bug via the smoke's determinism assertion. Smoke 15/15; all seven prior smokes green. Method and details: [BUILD-JOURNAL](system/chapters/2026-06-25-github-issue-roundtrip/BUILD-JOURNAL.md).

[Issue #3 spec](system/chapters/2026-06-25-github-issue-roundtrip/issues/02-confessing-pr.md) | [smoke](system/chapters/2026-06-25-github-issue-roundtrip/tests/idea2-confessing-pr-smoke.sh) | commit `4316c2a`

---

## [System] Triage Before Toil (issue #2) — the judgment gate before Phase 0 (2026-07-04)

Closed **issue #2 "Triage Before Toil"** — the readiness pre-phase that runs ahead of Phase 0 in Path A (`--issue N`), so the loop *reads* an issue and decides whether it is even buildable **before** spending planning/build tokens on it. Once write-back exists (issue #1), the next-most-expensive failure is the loop confidently building the wrong thing from an underspecified issue; this gate is the cheapest guard against that ([prd.md §3 Idea 4](system/chapters/2026-06-25-github-issue-roundtrip/prd.md)).

**How it works:** `run_triage_phase()` fetches the issue (an ungated read) and classifies it with `triage_classify()` — a **pure, deterministic bash scorer** (no LLM call): structure, length, acceptance-criteria/repro signals, and question-shaped titles produce `ready` | `needs-info` | `wontfix-candidate` | `excluded`. Determinism is the point — the issue's AC demands "deterministic given the issue content," which an LLM scorer cannot promise; an LLM triage persona remains open as a possible later layer *on top of* the gate. Dispositions: **ready** → `ralph:ready`, promoted into Phase 0; **needs-info** → specific clarifying questions posted as ONE self-updating issue comment (its own `RALPH:TRIAGE` HTML-comment fences, fail-closed like the slice-c build comment) + `ralph:needs-triage`, then the run parks (exit 2) — ask, don't guess; **wontfix-candidate** → `ralph:blocked` + an explanatory comment, parked — the loop **never closes** an issue (ADR-001 I3); **excluded** (`roadmap` label) → parked with **zero writes** — the loop must not touch its own planning issues (the dogfooding-recursion guard, prd.md §6); a human promotes those deliberately by adding `ralph:ready`.

**Invariants:** all writes funnel through the slice-1 `gh_*_op` guards and go dry under `--write` off — but the *gate still gates* (classification is logged, unready issues still don't build; `--triage never` is the explicit bypass, `--triage always` re-scores a promoted issue). The three stage labels join the single mutually-exclusive `ralph:` status namespace (`RALPH_STATUS_LABELS` 4 → 7), preserving the "exactly one `ralph:` label at any time" projection; re-runs converge with zero label churn (I2). Each triage decision appends to a local, gitignored ledger (`.ralph/triage-ledger.tsv`) — the raw data for the triage-precision metric and its kill criterion (prd.md §7). The safety contract (`run_claude()`, routing, retry, budgets, `main()`) is untouched byte-for-byte, and `--dry-run-prompts` stays byte-identical to the golden.

**How it was built (a first for this repo):** not by hand and not by the loop, but by a **supervised multi-agent orchestration session** — a spec written by the orchestrating agent, one implementer agent, two parallel adversarial reviewers (an ADR-invariant auditor and a bash edge-case hunter), and a fixer. The reviewers earned their keep: they caught the offline smoke disabling `errexit` around the very functions it claimed to prove (a false-green class) and substring keyword matches (`repro` in "reprogram") that could promote underspecified issues — both fixed before commit. Offline smoke: 10/10; all six prior smokes stay green. See the chapter's [BUILD-JOURNAL](system/chapters/2026-06-25-github-issue-roundtrip/BUILD-JOURNAL.md).

[Issue #2 spec](system/chapters/2026-06-25-github-issue-roundtrip/issues/04-triage-before-toil.md) | [smoke](system/chapters/2026-06-25-github-issue-roundtrip/tests/idea4-triage-smoke.sh) | commit `9f070ae`

---

## [System] The Round Trip (issue #1) — write-back projection complete, hand-built slice by slice (2026-06-26)

Closed **issue #1 "The Round Trip"** — the spine of the GitHub Issue Round-Trip chapter that takes the Ralph Loop's `--issue N` mode from **read-only** against GitHub to **write-back**, behind a `--write` flag (default off). The loop now delivers a reviewable result where the human lives — a branch, a draft PR, a self-updating issue comment, verdict-gated labels, and finally a ready-for-review PR — instead of abandoning them at the finish line with results buried in the local `git log`. Built **by hand** (not by the loop) because the loop cannot safely edit the script it is executing (ADR-002), in six additive, individually-checkpointed slices of `scripts/ralph-loop.sh`:

- **Slice 1** — the central `--write` gate (`GITHUB_WRITE`, default `0`) + the three guarded helpers `gh_comment_op` / `gh_label_op` / `gh_pr_op` that log `[dry] gh …` and touch nothing when the flag is off (ADR-001 **I1**).
- **Slice a** — `ensure_issue_branch()`: branch-per-issue (`ralph/issue-N`) created/resumed before the dev loop, so story commits never land on `main`. Local only, no push.
- **Slice b** — `ensure_issue_pr()`: commits the intake plan as the PR's first commit, pushes the branch, opens exactly ONE draft PR, persists the URL to `docs/prd/issue-N-pr.txt`; idempotent via that file (re-create only on a genuine 404). Also priced the blast radius (ADR-001 **I4**).
- **Slice c** — `upsert_issue_comment()`: ONE self-updating issue comment, found by an HTML-comment marker and edited in place, rendered from local git state (🔵 planning → 🟡 building X/Y → 🟢 done + PR link), fail-closed on malformed fences.
- **Slice d** — `set_issue_label()` + `ensure_ralph_labels()`: a single `ralph:` status label driven off the `REVIEW_PASSED`/`REVIEW_FAILED` verdict (`ralph:building` → `needs-fix` ↔ `in-review` → `done`), each transition a single `gh issue edit --add-label/--remove-label` call, idempotent.
- **Finish slice** — `mark_issue_pr_ready()`: on all stories green, `gh pr ready` graduates the slice-b draft PR to ready-for-review. This is the ONE PR-state graduation the ADR allows — readying is **neither a merge nor a close**, so **I3** (the human's thumb stays on the merge button) holds. The "final linking comment" half of step 5 is the existing slice-c 🟢 `done` comment — no second comment.

**Invariants throughout:** `--write` defaults off, so an accidental run has zero external blast radius and CI never touches the network (**I1**); every phase converges rather than churns on re-run — one PR, one comment, one status label, skip-when-already-ready (**I2**); the loop never merges or closes its own PR/issue (**I3**). Every slice is purely additive (the safety contract — `run_claude()`, multi-model routing, retry/escalation, smart-salvage, upstream-fix cascade, budget caps — untouched byte-for-byte) and keeps `--dry-run-prompts` byte-identical to the golden (the prompt-cache stability gate). Each slice ships an offline, deterministic, agent-runnable bash smoke under the chapter's `tests/` (slice1 6/6, a 7/7, b 8/8, c 9/9, d 11/11, finish 9/9) that stubs `gh` and never hits the network.

**Still open:** the anti-drift AC (`prd.md` §3 Idea 1 matches shipped behavior) stays unticked pending a **live `--write`-on dogfood run** on a throwaway issue — the only thing the offline smokes cannot prove (live `gh` write scope). With #1 complete, the spine is in place for Ideas 2–5 (Confessing PR, Worktree-per-Issue, Triage, Swarm) to build on.

[Issue #1 spec](system/chapters/2026-06-25-github-issue-roundtrip/issues/01-round-trip.md) | [ADR-001](system/chapters/2026-06-25-github-issue-roundtrip/adr-001-github-as-shared-mutable-state.md) | [chapter tests](system/chapters/2026-06-25-github-issue-roundtrip/tests/)

---

## [System] ADR-002: keep the orchestrator in Bash (don't rewrite to TypeScript / Sandcastle) (2026-06-25)

Evaluated converting the Ralph Loop orchestrator (`scripts/ralph-loop.sh`) from Bash to a TypeScript tool like `mattpocock/sandcastle`. **Decision: stay Bash + a typed reconciler (strangler-fig); Sandcastle is plumbing, not substrate.** Rationale: language doesn't move the user outcome; the ADR-001 graduation tripwire fires on the reconciler slice already being carved into `tools/`, not the loop kernel; a rewrite re-derives ~1900 lines of battle-tested scar tissue and risks silent prompt-cache byte-drift (the cost lever); and the current roadmap (#1–#12) is serial — design §5 defers the Swarm's true concurrency to v2, so the one trigger that would force a graduation isn't present. Sandcastle's session-`.fork()` model also fights Ralph's clean-context-per-step. **The trigger to revisit:** v2 concurrency becomes P0 (then adopt Sandcastle for the concurrency/sandbox *plumbing*, keeping the loop's heart in owned source) or an observed self-modification corruption. Non-negotiables carried forward: a `--dry-run-prompts` byte-diff CI gate on prompt-adjacent changes; the loop's ~80-line heart stays readable/owned; clone-and-run in one move. From a BMAD party-mode roundtable (architect, dev, PM, UX).

[ADR-002](system/design/adr-002-orchestrator-runtime.md)

---

## [System] The Issue-Native BMAD Loop — unified system design (2026-06-25)

Accepted the overarching architecture that unifies **GitHub Issues + the BMAD method + the Ralph Loop** into one frictionless workflow: every work item (owner- or community-filed) enters as a GitHub issue, passes a maintainer review gate, and the loop builds it — small work as the issue itself (one PR), big work with the source issue becoming a BMAD **epic** whose **stories are native GitHub sub-issues** (one PR each). The in-repo PRD/epic/story **files stay the book of record; GitHub is a projection**, kept consistent by a derivable JSON **manifest** (`story N.k ↔ sub-issue #X`) and a convergent reconciliation pass that heals its own projection but *flags — never reverses* — human edits.

**The governing law** (four specialists converged on it): *the machine may think at any scale but act only at the scale the human last authorized; any change in authorized spend returns to the human.* It shows up as a 10-label state machine with a single human gate (`triage → loop:ready` authorizes spend + public writes), human-gated re-sizing (`bmad-correct-course` via append-and-supersede), and a scheduler that may only *continue* gated work, never introduce new work.

**Two architecture rulings:** (1) a typed `reconcile.ts` module owns the manifest + the three-source (files∪git∪GitHub) join + the re-sizing transaction, while Bash orchestrates — this trips the ADR's bash→typed-runtime tripwire and needs a CLAUDE.md Node-exception amendment before implementation; (2) supervised-default autonomy. Drafted from a BMAD party-mode roundtable (analyst, PM, architect, dev, UX). The `tools/` Node exception has since been applied to root + `system/` `CLAUDE.md`, and the tracker realigned to the design: umbrella epic **#12** plus Slice B component issues **#7–#11** (manifest/reconciler, native sub-issues, label workflow, intake binding, re-sizing); Slice A = the round-trip issues #1–#5, partial implementations. Design only — unimplemented.

[Design doc](system/design/issue-native-bmad-loop.md)

---

## [System] GitHub Issue Round-Trip & Autonomy — chapter planned (2026-06-25)

Opened the next System Track chapter, taking Path A from **read-only** to **write-back**. A BMAD party-mode roundtable (analyst, PM, architect, dev, UX, tech-writer) converged on five ideas — one product, five epics: **The Round Trip** (branch-per-issue → draft PR → self-updating issue comment → verdict-gated labels, behind a `--write` flag default-off), **The Confessing PR** (PR body synthesized from per-story artifacts with an "I had to guess" section), **Worktree-per-Issue** (`git worktree` isolation), **Triage Before Toil** (a readiness pre-phase that gates issues before building), and **Swarm + Mission Control** (serial multi-issue + `ralph watch` dashboard + brake; concurrency deferred to v2).

**Why it matters:** today the loop abandons the human at the finish line — results live only in the operator's local terminal and `git log`. This chapter closes the loop back to GitHub so work shows up where the human already lives, as a reviewable PR. Build order optimizes for *trust before scale*: `Round Trip → Triage → (Confessing PR, Worktree) → Swarm`.

**How the invariants are framed:** write-back crosses a "Rubicon" — GitHub becomes shared mutable state with multiple writers, making idempotency mandatory and `--write`-default-off a safety boundary (captured in [`adr-001`](system/chapters/2026-06-25-github-issue-roundtrip/adr-001-github-as-shared-mutable-state.md)). The PRD is the source of truth; GitHub issues are thin views of it (a fresh LLM cloning the repo can't see issues, so substance stays in-tree). The five planning issues carry a scan-excluded `roadmap` label so the loop doesn't pick up its own roadmap before the Triage gate exists. Planning only — no stories built yet.

[Chapter README](system/chapters/2026-06-25-github-issue-roundtrip/README.md) | [PRD](system/chapters/2026-06-25-github-issue-roundtrip/prd.md) | [ADR-001](system/chapters/2026-06-25-github-issue-roundtrip/adr-001-github-as-shared-mutable-state.md)

---

## [System] GitHub-issue intake / planning phase — two execution paths (2026-06-24)

`scripts/ralph-loop.sh` gained a **Phase 0 (Plan)** front-end, so the loop now has two execution paths. **Path B "execute"** is the existing behavior, byte-compatible and unchanged: `--epic … --stories … --checkpoint …` runs the SM→Dev→Review loop on an existing epic. **Path A "intake"** is new: `--issue N [--repo OWNER/NAME]` fetches a single GitHub issue with `gh`, runs a BMAD planning chain — PRD (`docs/prd/issue-N.md`), an optional architecture note (`docs/architecture/issue-N.md`), and an epic with namespaced stories (`docs/epics/issue-N.md`, headers `### Story N.k:`) — then feeds the existing loop unchanged. `--plan-only` stops after planning for human review.

**Why it matters:** the loop could only start from a hand-written epic. Path A lets it start from the place real work originates — a GitHub issue — while the entire downstream machinery (story slicing, `feat(N.k):` completion checks, per-story artifacts, budgets, parking) keeps working because Phase 0 emits the *exact* epic/story header format Phase 2 already parses.

**How the invariants held:** `main()` (the SM→Dev→Review loop, fix/upstream/cascade/auto-heal, smart-salvage, budget caps, `run_claude()` signature) is untouched — Phase 0 is a gate placed *before* the `main` call. The three new planning roles (`pm`, `architect`, `planner`) were added exactly like every existing role: a `prompts/<role>/overlay.md`, a `prompts/bmad-fallbacks/<role>.md`, an `AGENT_<ROLE>_FILE` → BMAD `SKILL.md`, and a `build_system_prompts()` line — so planning system prompts stay byte-stable within a run and the prompt cache still hits. The `--stories all` expansion + per-story tracking-array init were lifted verbatim into `finalize_story_plan()` (arrays kept global) so both paths share one copy: Path B calls it immediately (same timing as before), Path A after Phase 0 builds the epic. A failed planning step *parks* (clear message + exit 2), it does not crash the run; Phase 0 is skipped on re-run if its epic already exists (resumability).

Implemented interactively (not via a loop run — the loop script is read-only during its own runs). Verified with `bash -n`, `--dry-run-prompts` for both paths, and error-path smokes (mutual exclusion, missing `--issue`, non-existent issue pre-flight). A full end-to-end Path A build against a live issue is the next validation step.

[Chapter README](system/chapters/2026-06-24-github-issue-intake/README.md)

---

## [System] Ralph Loop Guided Installer chapter complete (2026-06-13)

The installer is now complete and published. A new developer can run `npx <package> install` in an empty directory or existing project and have a working, customized Ralph Loop in under 5 minutes. The wizard teaches the concepts interactively; a `--yes` flag enables fully non-interactive mode for CI.

**What was built:** A Node.js CLI (in `installer/`, permitted by story 1.1) that preflight-checks the environment, classifies the target directory, guides the user through project configuration, scaffolds the loop, manages BMAD installation, and includes update/uninstall/doctor lifecycle commands. The e2e suite (story 4.1) validates all major workflows. Documentation (this story) emphasizes the installer as the primary path, with manual steps as a fallback.

**Why it matters:** The Ralph Loop's manual setup was a significant barrier to adoption. This installer brings the setup experience in line with `bmad-method install` and modern CLI tools like `npm create astro@latest`. Estimated time-to-running-loop: now ≤ 5 min vs. the previous ~1 hour of careful README-following.

**Repo structure:** The `installer/` directory is the sole exception to the "everything is Bash + Markdown" rule outside that folder. The installed footprint mirrors this repo's layout (scripts/, docs/, GETTING-STARTED.md, .CLAUDE.md, .gitignore entries, .ralph/manifest.json), so all existing loop documentation applies to installed projects.

**Next:** Story 4.3 finalizes the package name and release checklist; the human publishes to npm (out of scope for the loop).

[Chapter README](system/chapters/2026-06-13-ralph-loop-installer/README.md) | [Epics](system/chapters/2026-06-13-ralph-loop-installer/epics/ralph-loop-installer.md)

---

## 2026-05-25 — `[System]` Chapter 1 closed: prompts modularized, BMAD personas live-loaded

The first System Track chapter — [`2026-05-24-modularize-loop-prompts`](system/chapters/2026-05-24-modularize-loop-prompts/) — closed with tag [`system-ch1-complete`](https://github.com/seevali/ralph-loop-demo/releases/tag/system-ch1-complete). The chapter delivered exactly what its [plan](system/chapters/2026-05-24-modularize-loop-prompts/README.md) promised: ~110 lines of hardcoded persona/execution-context heredocs are gone from `scripts/ralph-loop.sh`. A new `load_prompt_layers(role)` helper assembles each cached system prompt from three concatenated layers — an execution-context override from [`scripts/prompts/common/execution-context.md`](scripts/prompts/common/execution-context.md) (layer 1), the live BMAD persona from `.claude/skills/<role>/SKILL.md` (layer 2), and project-specific rules from [`scripts/prompts/common/project-conventions.md`](scripts/prompts/common/project-conventions.md) + a role overlay (layer 3). Future BMAD releases now flow into the loop automatically; the only place the demo's stack rules live is the `scripts/prompts/` directory, which cloners can edit when forking for a different stack.

A re-runnable [semantic equivalence script](system/chapters/2026-05-24-modularize-loop-prompts/artifacts/verify-semantic-equivalence.sh) confirms that every significant content line from the original heredoc assembly is still present in the new layered output (SM 366 lines, Dev 396 lines, Review 276 lines, all accounted for).

**The honest narrative.** The chapter ran in two passes. The first pass exposed three infrastructure bugs in the Ralph Loop itself that any future System Track chapter would also have hit — and that the first chapter wouldn't have surfaced as cleanly without using the loop on itself. Each fix landed as its own `fix(system):` commit so the bugs and their corrections are publicly readable in the git log:

- **`ad19753 fix(system): unblock first chapter run`** — surfaced when story 1.1 couldn't even start. `STORIES_DIR` was hardcoded to the Demo Track's `docs/stories/`, and the loop's epic parser required a specific `### Story X.Y:` header format my hand-written epic didn't match. The fix made `STORIES_DIR` honor an env-var override (the wrapper sets it to the chapter's own stories folder) and rewrote the epic headers.
- **`b93ed36 fix(system): make review verdict parser robust to title lines`** — surfaced when story 1.1's Code Review agent wrote a perfectly correct `REVIEW_PASSED` verdict but on line 3 of the file (after a `# Story 1.1 Code Review` markdown title), and the loop's parser was reading only line 1 with `head -1`. Three retry cycles burned before the loop gave up on a passing review. The fix introduced `is_review_passed()` — a lenient parser that finds `^REVIEW_PASSED` anywhere in the file — and replaced all seven call sites. Also strengthened the agent's prompt instructions to be more explicit about the literal-first-line requirement.
- **`fc26418 fix(system): EXTRA_STAGE_PATHS env-var override for auto-commit staging`** — the most subtle. Stories 1.2 and 1.3 *appeared* to land cleanly (the loop committed `feat(1.2)` and `feat(1.3)`), but those commits contained **only the story docs** — the actual `load_prompt_layers()` function and `--dry-run-prompts` flag the agents wrote were orphaned in the working tree. The loop's auto-commit step had a hardcoded narrow staging list (`src/` + `docs/stories/`) that was Demo-Track-correct but System-Track-blind. Discovered when story 1.4's Dev agent inherited the uncommitted code and burned $4 of budget trying to do its own work on top. The fix added an `EXTRA_STAGE_PATHS` env var (same shape as `STORIES_DIR`) that the wrapper sets to `scripts/ system/ README.md CLAUDE.md TIMELINE.md`. Then a separate `f1e9cf9 fix(1.2,1.3)` commit rescued the orphaned code from the working tree without rewriting history — chosen over a `rebase -i` because the messy-but-truthful trail is more valuable than a clean-but-misleading one.

Story 1.4 also surfaced a chapter-plan flaw: the original spec asked for a **byte-identical** diff between pre- and post-refactor prompt assemblies, but the chapter plan also specified a new layer ordering (Layer 1 Execution Context first, vs. the old structure with persona first). These two requirements are architecturally incompatible. Story 1.4's acceptance criterion was rewritten ([`4f42599 chore(1.4)`](https://github.com/seevali/ralph-loop-demo/commit/4f42599)) to a semantic equivalence check — same primitive (verify no content was dropped), achievable target. The 1.4 Dev agent then built the semantic verification script and it passed first try.

**What landed (15 commits, in chronological order):**

1. **[`9cf23d4`](https://github.com/seevali/ralph-loop-demo/commit/9cf23d4)** — scaffold the `system/` folder skeleton + wrapper
2. **[`6652282`](https://github.com/seevali/ralph-loop-demo/commit/6652282)** — first chapter directory + migrate plan into chapter
3. **[`9d3c573`](https://github.com/seevali/ralph-loop-demo/commit/9d3c573)** — root docs (README/CLAUDE.md/TIMELINE) made two-track aware
4. **[`ad19753`](https://github.com/seevali/ralph-loop-demo/commit/ad19753)** — `fix(system)` #1: unblock first chapter run (`STORIES_DIR` + epic headers)
5. **[`28eabe7`](https://github.com/seevali/ralph-loop-demo/commit/28eabe7)** — `feat(1.1)`: extract repo-local prompt files (manually accepted after parser misread the passing review)
6. **[`b93ed36`](https://github.com/seevali/ralph-loop-demo/commit/b93ed36)** — `fix(system)` #2: lenient `REVIEW_PASSED` parser
7. **[`5817069`](https://github.com/seevali/ralph-loop-demo/commit/5817069)** — `feat(1.2)`: docs only (loop staging bug, fixed below)
8. **[`2874bda`](https://github.com/seevali/ralph-loop-demo/commit/2874bda)** — `feat(1.3)`: docs only (same staging bug)
9. **[`f1e9cf9`](https://github.com/seevali/ralph-loop-demo/commit/f1e9cf9)** — `fix(1.2,1.3)`: rescue orphaned `load_prompt_layers()` and `--dry-run-prompts` code from working tree
10. **[`fc26418`](https://github.com/seevali/ralph-loop-demo/commit/fc26418)** — `fix(system)` #3: `EXTRA_STAGE_PATHS` env-var override; prevents this class of bug recurring
11. **[`4f42599`](https://github.com/seevali/ralph-loop-demo/commit/4f42599)** — `chore(1.4)`: rewrite story 1.4 from byte-diff to semantic equivalence
12. **[`330bdd9`](https://github.com/seevali/ralph-loop-demo/commit/330bdd9)** — `feat(1.4)`: semantic equivalence verification script
13. **[`5209248`](https://github.com/seevali/ralph-loop-demo/commit/5209248)** — `feat(1.5)` (code): rewire `build_system_prompts()` to call `load_prompt_layers()`; delete heredocs
14. **[`ef3a081`](https://github.com/seevali/ralph-loop-demo/commit/ef3a081)** — `feat(1.5)` (docs): story spec + done + review for 1.5
15. **[`137a8be`](https://github.com/seevali/ralph-loop-demo/commit/137a8be)** — `feat(1.6)`: root README + CLAUDE.md mention `scripts/prompts/`; chapter plan flipped to `Status: complete`

**Status:** chapter 1 closed and tagged. Chapter 2 (if/when) will inherit a much better-instrumented loop — three infrastructure fixes ahead of where the first chapter started. The recursion the demo set out to show is now public-record visible: a tool that used itself to forge itself, with every misstep traceable.

---

## 2026-05-24 — `[System]` Two-track restructure: introduced `system/` + chapter convention

Reshaped the repo into two tracks on the same branch:

- **Demo Track** stays at the root, untouched in shape — `docs/`, `src/`, `scripts/ralph-loop.sh`. Frozen showcase that cloners experience.
- **System Track** lives under [`system/`](system/) — its own README, CLAUDE.md, [`ralph-loop-system.sh`](system/ralph-loop-system.sh) wrapper, and a [`chapters/`](system/chapters/) folder where each loop-improvement effort is a self-contained dated folder with plan, PRD, epic, and stories.

The choice (single branch, two folders) over the alternative (two branches) was deliberate: keeping the System Track visible on the same branch as the demo means the public can see *both* the result and the path that got us there. The recursion (loop improving itself) becomes part of the demo's value, not a hidden development concern.

The migration also moved the prompt-modularization plan from `docs/plans/` into its new home as the first chapter — [`system/chapters/2026-05-24-modularize-loop-prompts/`](system/chapters/2026-05-24-modularize-loop-prompts/) — and replaced the `docs/plans/` convention with the chapter convention under `system/`.

**What landed (in commit order):**

- **`9cf23d4`** — scaffold `system/` skeleton + wrapper. Adds [`system/README.md`](system/README.md), [`system/CLAUDE.md`](system/CLAUDE.md) (system-track agent rules), [`system/ralph-loop-system.sh`](system/ralph-loop-system.sh) (thin wrapper that resolves a chapter and delegates to the canonical loop), and an empty `system/chapters/`.
- **`6652282`** — first chapter: `2026-05-24-modularize-loop-prompts`. Migrated the prompt-modularization plan from `docs/plans/` (now deleted) into [the chapter folder](system/chapters/2026-05-24-modularize-loop-prompts/), and operationalized it into a [PRD](system/chapters/2026-05-24-modularize-loop-prompts/prd.md) + [epic with 6 stories](system/chapters/2026-05-24-modularize-loop-prompts/epics/modularize-loop-prompts.md) that the System Track loop can execute.
- This commit — root [README](README.md), [CLAUDE.md](CLAUDE.md), and this TIMELINE updated for two-track awareness.

**Status:** ready to run `./system/ralph-loop-system.sh` against the first chapter.

---

## 2026-05-24 — `[System]` Plan: Modularize loop prompts & live-load BMAD personas

Drafted a refactor plan to extract the ~110 lines of hardcoded agent personas from `scripts/ralph-loop.sh` into a layered `scripts/prompts/` tree, and to live-load BMAD persona files at runtime so future BMAD updates flow in without touching the loop script. Recommended a 3-layer hybrid (repo-local execution-context override + live BMAD persona + repo-local stack rules) to satisfy both portability and update-resilience.

After the two-track restructure (above), the plan now lives as the README of its chapter folder:

Plan: [`system/chapters/2026-05-24-modularize-loop-prompts/`](system/chapters/2026-05-24-modularize-loop-prompts/)

**Status:** accepted, ready for loop execution.

---

## 2026-05-24 — `[Demo]` Phase 0: Scaffolding the demo

Initial scaffolding day. Brought the repo from empty to "ready to run the Ralph Loop overnight."

**What landed (in commit order):**

1. **[`752e46b`](https://github.com/seevali/ralph-loop-demo/commit/752e46b)** — Initial scaffold: `README.md`, `LICENSE` (MIT), `.gitignore`, empty `docs/`, `scripts/`, `src/`.
2. **[`e20d9d3`](https://github.com/seevali/ralph-loop-demo/commit/e20d9d3)** — `CLAUDE.md` with per-agent behavior rules + stack guardrails. Picked up automatically by every fresh Claude Code session inside the Ralph Loop.
3. **[`e80f1b7`](https://github.com/seevali/ralph-loop-demo/commit/e80f1b7)** — BMAD Method installed (`core` + `bmm` only) via `npx bmad-method install`. Both `_bmad/` and `.claude/skills/` are install products → gitignored. Decision: latest BMAD is v6.7+, which has no `bmad-agent-sm` — roles remapped to `bmad-create-story` (SM), `bmad-dev-story` (Dev), `bmad-code-review` (Reviewer).
4. **[`3296a08`](https://github.com/seevali/ralph-loop-demo/commit/3296a08)** — Vite + React + TypeScript app scaffolded in `src/`. Vitest + React Testing Library wired up. TS strict mode on.
5. **[`75ee4e1`](https://github.com/seevali/ralph-loop-demo/commit/75ee4e1)** — `scripts/ralph-loop.sh` copied verbatim from the upstream `ralph-affiant-v2.sh` (unmodified at this step, so the diff in the next commit is clean).
6. **[`0a14fd6`](https://github.com/seevali/ralph-loop-demo/commit/0a14fd6)** — PRD for the Exchange Rates monitoring dashboard generated by the BMAD PM agent. Decision: API = Frankfurter (`api.frankfurter.dev/v1`, keyless) instead of the keyed exchangerate.host originally suggested in the prompt — keyless is friendlier for a demo someone might clone and run on a whim.
7. **[`006f6d6`](https://github.com/seevali/ralph-loop-demo/commit/006f6d6)** — One epic + six small stories for the dashboard, generated by BMAD's epic/story workflow. Sized small intentionally so the overnight loop run lands in the tens-of-dollars range, not hundreds.
8. **[`998b283`](https://github.com/seevali/ralph-loop-demo/commit/998b283)** — Ralph loop script adapted to React/Vite/TS: stripped Affiant .NET specifics, replaced cached system prompts with React/TS conventions, baked in defaults so a bare `./scripts/ralph-loop.sh` invocation works. Loop semantics, model routing, retry, and budget caps left untouched.
9. **[`cf47cc5`](https://github.com/seevali/ralph-loop-demo/commit/cf47cc5)** — Setup marked complete in `todo.md` with a handoff summary.

**Status:** ready for first loop run. The Demo Track is now frozen — no further development planned here.

---
