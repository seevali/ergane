# The Issue-Native BMAD Loop — system design

**Status:** Accepted design (2026-06-25). Not yet implemented. Supersedes nothing; **frames** the `system/chapters/2026-06-25-github-issue-roundtrip/` chapter (its five issues become partial implementations of this design — see §11).
**Scope:** the overarching architecture that unifies three things into one workflow: **GitHub Issues** (the tracker), the **BMAD method** (PRD → epics → stories), and the **Ralph Loop** (the autonomous build engine). Individual chapters under `system/chapters/` implement slices of it.
**Authority:** this document is the source of truth for *how the three worlds harmonize*. Where a chapter PRD/ADR and this doc disagree, this doc wins on architecture; the chapter wins on its own implementation detail.

> **Cold-start note (fresh reader, any LLM, no prior context).** "The Ralph Loop" is `scripts/ralph-loop.sh` at this repo's root — a Bash orchestrator (`set -euo pipefail`) that builds software one *story* at a time, each step a fresh `claude -p` CLI process with no shared chat history (context is reloaded from the file system). Completion is tracked by grepping `git log` for `feat(<id>):` commits. "BMAD" is an agent-skill framework (installed under `.claude/skills/`) whose method goes PRD → Epics → Stories; the loop maps roles to BMAD skills (SM=`bmad-create-story`, Dev=`bmad-dev-story`, Review=`bmad-code-review`, plus planning roles PM/Architect/Planner). "System Track" vs "Demo Track" is this repo's two-track split (see root `CLAUDE.md`): Demo Track builds a sample React app under `src/`; System Track (this folder, `system/`) improves the loop itself. "Path A intake" is the loop's existing `--issue N` mode, which today reads ONE GitHub issue via the `gh` CLI and turns it into PRD/epic/story files, then builds it — but is read-only against GitHub. `gh` is the GitHub CLI and the *only* GitHub mechanism used (no octokit, no REST client). The full context dossier is §13; the glossary is §12.

---

## Cold-start reading order

1. **§1 Motivation & the three worlds** — what this unifies and why.
2. **§2 The governing law** — the single principle everything else obeys.
3. **§3 The unified lifecycle** — the end-to-end flow (a diagram), for both entry scenarios and both sizes.
4. **§4 The label system** — the state machine that drives it on GitHub.
5. **§5 Source of truth & the manifest** — how files, git, and GitHub stay consistent.
6. **§6 GitHub representation** — sub-issues, the source-issue-as-epic body, PRs.
7. **§7 Re-sizing (correct-course)** — handling "this is bigger than we thought."
8. **§8 Runtime split** and **§9 Autonomy bound** — the two architecture rulings.
9. **§10 Mapping to BMAD & the loop**, **§11 Traceability/roadmap** — what exists, what's new.
10. **§12 Glossary**, **§13 Context dossier**.

External dependencies this design assumes (install/verify before implementing): `gh` (GitHub CLI, authenticated with **write** scope), `git` (incl. `git worktree`), `jq`, a small **TypeScript/Node** runtime for the reconciler (§8 — a deliberate second exception to the System Track "Bash + Markdown only" rule; requires the CLAUDE.md amendment noted in §8), and the BMAD planning/build skills listed in §10.

---

## 1. Motivation & the three worlds

A maintainer wants to move a product forward without friction. Today three systems each solve part of that but don't connect:

- **GitHub Issues** is where work is *reported and tracked* (by the owner and by the community), but it has no notion of PRD/epic/story rigor and the Ralph Loop can't act on it natively (beyond reading one issue).
- **BMAD** brings *planning rigor* (PRD → epics → stories) but produces **files**, disconnected from the issue tracker.
- **The Ralph Loop** *builds autonomously* from files but, until now, delivers results only to the operator's local terminal and `git log` — invisible on GitHub.

This design makes them **one pipe**: every unit of work enters as a GitHub issue, BMAD's hierarchy *is* the issue hierarchy (epic = source issue, story = sub-issue), and the loop builds it and reflects progress back onto GitHub — all while keeping the in-repo files as the durable book of record.

**Two entry scenarios, one front door:**
1. **Owner-driven** — the owner files an issue capturing an idea, a module, or a feature (which may break into many sub-issues).
2. **Community-driven** — a contributor reports a bug or requests a feature.

Both become a GitHub issue and flow through the identical lifecycle (§3).

---

## 2. The governing law

Four specialists arrived at the same principle from four directions (architecture, dev, product, UX). It is the keystone of this entire design:

> **The machine may *think* at any scale, but it may only *act* at the scale the human last authorized. Any change in authorized spend or scope returns to the human who authorized it.**

Corollaries, each load-bearing:
- **Reconciliation flags human intent; it never reverses it.** The loop heals its own projection (mechanical truths) but never overrules a person's edit, close, or label.
- **A change in authorized spend re-enters the gate.** A "small" job that turns out "big" does not silently upgrade its own budget (§7).
- **Cool means the machine has it; warm means it needs you** (the visual law, §4) — the human's attention only ever lands where their decision is required.

---

## 3. The unified lifecycle

```
 owner: idea / feature / module ─┐
                                 ├─▶  ONE front door: a GitHub issue (label: triage)
 community: bug / feature req  ──┘
                                         │
                              ┌──────────▼─────────── MAINTAINER REVIEW GATE ───────────┐
                              │  human reads, validates, sizes, checks the contract     │
                              │  → loop:ready  (THE authorization: spend + public write)│
                              │  → needs-info | blocked | wontfix | duplicate (deflect) │
                              └──────────┬──────────────────────────────────────────────┘
                                         │ loop:ready  (+ size:small | size:big, set by planning agent at intake)
                  ┌──────────────────────┴───────────────────────────┐
              SIZE = small                                        SIZE = big
        the source issue IS the unit                       the source issue BECOMES the epic
        → brief + 1 story file                             → PRD + epic + story FILES (book of record)
        → loop:active → build → 1 PR                       → native GitHub SUB-ISSUES (1 per story)
        → loop:review → human merge → done                 → source-issue body APPENDED with sub-issue task-list
                                                           → per sub-issue: loop:active → build → 1 PR → review → merge
                                                           → all stories merged → source issue done
                                         │
                                  (any time, either size)
                                  loop hits the edge of its mandate
                                  → halts that unit, sets a WARM label
                                  → needs-info  (missing input)         §4
                                  → needs-resize (bigger than authorized) §7
                                  → human re-gates → loop resumes
```

The loop's trigger is identical whether invoked manually (`--issue N`) or by a scheduler: it claims work matching `label:loop:ready AND no open PR`. The *label*, not the invocation method, is the contract (§4, §9).

---

## 4. The label system

Designed to the test: *"who reads this label, and what do they do differently because of it?"* If nothing changes behavior, the label is cut. Two orthogonal axes plus orthogonal tags.

### Status (exactly one at a time; the loop reads this; setting a new one removes the old)

| Label | Set by | Meaning / effect |
|---|---|---|
| `triage` | auto (on every new issue) | Filed, unreviewed. Loop ignores. |
| `loop:ready` | **human — THE gate** | Reviewed, sized, contract satisfied. Loop may claim. Authorizes spend + public writes. |
| `loop:active` | loop | Claimed; planning/building underway. |
| `loop:review` | loop | PR open, awaiting the human merge decision. |
| `done` | auto (on merge/close) | Shipped. |

### Disposition / attention (terminal or holding — WARM, the only loud labels)

| Label | Set by | Meaning |
|---|---|---|
| `needs-info` | human or loop | Cannot proceed; question posted. Loop refuses. |
| `needs-resize` | loop | Bigger than the authorized size; promotion proposed (§7). Loop halts that unit. |
| `blocked` | human or loop | Dependency unmet. Loop refuses. |
| `wontfix` / `duplicate` | human | Closed, no work. |

### Orthogonal tags (not status; do not gate the lifecycle)
- **Size:** `size:small` | `size:big` — set by the planning agent at intake, confirmed by the human at the gate. Required for `loop:ready`.
- **Type:** `type:bug` | `type:feature` | `type:chore` | `type:docs` — selects the BMAD path (a bug fix is a brief, not a full PRD).
- **Priority** (optional) — a *scheduler ordering* input, not a lifecycle state.

### The visual law (UX)
**Cool-toned = the machine has it (relax); warm-toned = it needs you (look here).** Across a busy issue list the maintainer reads it like traffic: `loop:active`/`loop:review` are a calm river; `needs-info`/`needs-resize`/`blocked` are a raised hand. Never two status labels at once — that means the machine lied.

### The two human touches
1. **`triage → loop:ready`** — the single authorization for spend + public writes.
2. **`loop:review → done`** — the merge. (The loop never merges or closes its own PR/issue.)
Humans gate **entry** and **exit**; the loop owns the **middle**.

### Owner vs community — same pipe, same gate
Authorship does not lower the gate; it just means the same trusted hand may pass it instantly. The owner may apply `loop:ready` to their own issue in seconds; a stranger's issue gets full review. **The loop never auto-promotes `triage → loop:ready`, even for the owner** — otherwise a scheduler could spend with zero human in the loop.

### The `loop:ready` contract (or the loop refuses → `needs-info`)
`loop:ready` guarantees the loop can answer, **from the issue alone**: *what is the job, how big is it, how will I know I'm done, and is anything blocking it?* Concretely: (1) sized; (2) acceptance criteria stated (≥1 observable "done when…"); (3) scope bounded (small ⇒ one PR); (4) no open blocker; (5) type known.

### The outward experience (community)
The label is the maintainer's private control; **the comment is the author's experience.** `needs-info` must *feel like being heard* (a warm, templated-but-human comment); `loop:ready` must signal *accepted — the build has started*. A system legible to the operator but a black box to the community fails. Outward comments are a first-class deliverable, not an afterthought.

---

## 5. Source of truth & the manifest

**Files + git are authoritative. GitHub is a projection. The manifest is a derivable cache** — it asserts nothing; it *caches* what git already proves.

### Identity anchor
Every sub-issue carries an HTML-comment marker in its **body** (not its title — a maintainer editing a title would strip it and cause duplicates): `<!-- ralph:story=N.k source=S -->`. The story id `N.k` is *ours* to stamp; the sub-issue number is GitHub's to assign. So "does a sub-issue for `N.k` already exist?" is answerable from GitHub alone via a body search, independent of the manifest.

### The manifest
One file, committed to git: `docs/<component>/implementation/issue-manifest.json` (JSON, because it is a machine-read transactional ledger; its *human* projection is the fenced task-list in the source-issue body — §6). Per story it records: `sub_issue` (number, for URLs/grep), `node_id` (GraphQL ID, needed for the native link), `state` (`planned → issue_created → in_progress → pr_open → merged`, plus terminal `orphaned` / `superseded`), `pr_url`, and `commit` (the `feat(N.k):` SHA — **the join key to ground truth**).

### Consistency mechanisms
- **Atomic writes:** `mktemp` + `jq` + `mv -f` (same-filesystem rename is POSIX-atomic — a crash leaves the old or the new file, never a half-written one).
- **Write-after-confirm, one story at a time:** never batch; persist each sub-issue's manifest row immediately after `gh issue create` returns. A crash strands at most one un-recorded issue, which the marker search recovers.
- **Reconstructible:** if the manifest is lost/corrupt, rebuild it from `gh issue list --search "<marker>"` ∪ `git log --grep 'feat('`. A derivable cache can never strand you.

### Reconciliation algorithm (runs on every loop start)
1. Load manifest (or init from story files).
2. Pull **GitHub truth** (sub-issues by marker → `{story_id → #, state}`).
3. Pull **git truth** (`git log --grep "feat(N.k):"` → completed story ids + SHAs).
4. For each **story file on disk** (files authoritative):
   a. no sub-issue → **create** (with marker), record;
   b. sub-issue exists, no manifest row → **adopt** (heals lost cache);
   c. git shows `feat(N.k)` but issue open → **close issue** (git wins);
   d. issue closed but no `feat(N.k)` and not `superseded` → **flag** (do not reopen).
5. Sub-issue in GitHub with no story file (human-created out-of-band) → **flag only, never auto-delete.**
6. Rewrite manifest; regenerate the fenced block in the source-issue body.

**Invariant:** the loop reconciles its *own projection* freely (4a–4c) but **flags — never reverses — anything bearing human intent** (4d, 5). That is §2's governing law made mechanical.

---

## 6. GitHub representation

- **Native sub-issues** (GitHub's real parent/child hierarchy, not task-list checkboxes) created via the GraphQL `addSubIssue` mutation (REST has no equivalent): `gh issue create` → capture number + node id → resolve the parent's node id → `addSubIssue(input:{issueId:$parent, subIssueId:$child})`.
- **Source-issue-as-epic body:** the loop **appends** (never overwrites) a fenced managed block listing the sub-issues, so the reporter's original text is preserved. Splice is **fail-closed**: exactly one `<!-- RALPH:BEGIN -->` and one `<!-- RALPH:END -->` or it aborts and edits nothing; the block is rendered **from the manifest** (never parsed back from GitHub), so re-runs converge to identical bytes. Writes use `gh issue edit --body-file` (never `--body` — byte/newline-safe).
- **PR granularity:** **one PR per sub-issue** (granular, reviewable units). A small issue yields one PR directly.
- **The `--write` gate (from ADR-001 of the round-trip chapter):** every GitHub mutation is behind a `--write` flag (default off) via `gh_*_op` helpers that no-op (and log `[dry] …`) when off — so the entire write surface is dark under tests/CI, and the network is a flag flip.

---

## 7. Re-sizing (correct-course)

A unit estimated `small` turns out to be an epic (or a story under-sized at planning). The BMAD analog is `bmad-correct-course`. Two rules make it "always work as expected":

1. **Never edit a story into bigness in place** — that mutates the book of record under a running loop and breaks every join key. Promotion is **append-and-supersede**: split `N.k` into new ids `N.k.1, N.k.2, …` (new story files, new manifest rows), mark the parent `superseded` (a first-class terminal state — reconciliation rule 4d must treat it as terminal, not an orphan), and let the next reconcile pass create the children's sub-issues idempotently. **Promotion replays the exact BIG-intake code path on a subtree** — it is not a special subsystem.
2. **Detect autonomously; promote only through a fresh human gate.** The loop detects via a structured signal (the dev agent writes a sentinel, e.g. `.resize-request.json`, instead of a `feat()` commit; plus a heuristic guard: N iterations on one story with no `feat(N.k)` landing). On detection the loop **halts that unit**, sets the warm `needs-resize` label, and posts **one comment that shows its work** — what it found, the proposed epic breakdown, the rough PR count, and the option to scope down instead. It creates **no** sub-issues until the human swaps `size:small → size:big` and re-applies `loop:ready`. The rest of the sprint keeps moving; only the affected subtree blocks.

**Why human-gated:** a `loop:ready` on a *small* issue authorized *small spend*. Discovering "big" means categorically more spend — promoting silently would be the loop upgrading its own budget. Plan-shape is the maintainer's domain (§2). The inverse (big → small) follows the same symmetry. The promotion transaction is crash-safe: the sentinel exists iff a promotion is incomplete, every sub-step is idempotent, and **no story with a landed `feat()` commit is ever removed** (the `git log` ledger stays truthful).

---

## 8. Runtime split (decision, 2026-06-25)

> Full rationale + the whole-orchestrator "should we rewrite to TypeScript / adopt Sandcastle?" decision: [`adr-002-orchestrator-runtime.md`](adr-002-orchestrator-runtime.md). Summary: **stay Bash + a typed reconciler (strangler-fig); Sandcastle is plumbing, not substrate; the trigger to graduate the loop kernel is v2 concurrency.**

**Bash orchestrates and observes; one typed (TypeScript/Node) module owns the manifest and all GitHub-action derivation.**

- **Bash** keeps the linear, observable work: invoking `claude -p` per step, `gh issue create`, `git log --grep`, the fenced-block splice, triggering reconciliation.
- **`reconcile.ts`** (typed, unit-tested) owns: the three-source join (files ∪ git ∪ GitHub) from §5, and the re-sizing promotion transaction from §7. These are relational, partial-failure-prone state mutations — exactly where shell degrades into unverifiable `jq` pipelines and a stray unquoted variable silently drops a story.
- **git remains the only thing that proves "done."**

**This trips the ADR-001 "Bash → typed runtime" graduation tripwire deliberately.** Consequence: the reconciler is a **second Node exception** to the System Track "Bash + Markdown only outside `installer/`" rule. **Resolved (2026-06-25):** the reconciler lives in a new top-level **`tools/`** directory; root `CLAUDE.md` and `system/CLAUDE.md` have been amended to permit Node/TypeScript strictly within `installer/` and `tools/`, mirroring how `installer/` was carved out. The design is now implementable on this point.

The typed module must satisfy the project's testing mandate: deterministic, agent-runnable unit tests (golden-file assertions; pin any nondeterministic input like the git SHA via env). With `--write` off, all GitHub ops short-circuit, so the full reconcile/promote flows are testable offline with zero network.

---

## 9. Autonomy & the scheduler bound (decision, 2026-06-25)

**Default rung: supervised. A scheduler may only *continue* work a human already gated; it may NEVER introduce new work autonomously.**

- New work enters only by a human applying `loop:ready` (§4). The scheduler's job is to *advance* already-`loop:ready` / in-flight units (build the next story, resume an epic, reconcile) — never to self-promote `triage → loop:ready`.
- This bounds what "autonomous loop" means here: the loop is autonomous *within* an authorization, never *across* the authorization boundary.
- The autonomy ladder (from the round-trip chapter PRD) still applies; higher rungs (e.g. auto-gating narrow trusted issue classes) are explicitly **out of scope** for this design and would be a separate, deliberately-earned decision.

---

## 10. Mapping to BMAD & the Ralph Loop

| Issue-Native concept | BMAD artifact | Ralph Loop mechanism |
|---|---|---|
| Source issue (big) | the **PRD + Epic** | Path A intake (`--issue N`), extended to write the epic/stories *and* create sub-issues |
| Sub-issue | a **Story** | the per-story SM → Dev → Review cycle; one `feat(N.k):` commit; one PR |
| Source issue (small) | a **brief + one Story** | the same cycle, no sub-issues, one PR |
| Maintainer gate / sizing | (planning judgment) | the `triage → loop:ready` transition + `size:` tag set by the planning agent |
| Re-sizing | **`bmad-correct-course`** | §7 append-and-supersede |
| "Done" | (acceptance met) | `git log` `feat(N.k):` — the single completion truth |

**Relationship to today's Path A:** Path A already does *issue → PRD/epic/story files* but (a) writes only to Demo-Track `docs/` paths, (b) creates no sub-issues, and (c) is read-only against GitHub. This design extends Path A with the sub-issue hierarchy, the manifest, the write-back projection, and System-Track-aware routing. The PRD/epics/stories **files remain the book of record**; GitHub issues are the *view* (a fresh clone is fully sufficient without ever reading GitHub — code points to PRD anchors, never issue numbers).

---

## 11. Traceability & roadmap

All work is tracked under the umbrella epic **[#12 The Issue-Native BMAD Loop](https://github.com/seevali/ergane/issues/12)**. The `2026-06-25-github-issue-roundtrip` chapter's five issues (**Slice A**) are *partial implementations*; the design-level component issues (**Slice B**, #7–#11) complete the machinery. Issue body files: round-trip slice in the chapter's `issues/`; Slice B in `system/design/issues/`.

| Design component (§) | GitHub issue |
|---|---|
| **Umbrella — the whole design** | [#12 EPIC: The Issue-Native BMAD Loop](https://github.com/seevali/ergane/issues/12) |
| Write-back projection: branch → PR → comment → labels (§4, §6) | *partial* — [#1 Round Trip](https://github.com/seevali/ergane/issues/1) |
| Maintainer review gate / triage scoring (§4) | *partial* — [#2 Triage Before Toil](https://github.com/seevali/ergane/issues/2) |
| Per-sub-issue PR experience (§6) | *partial* — [#3 Confessing PR](https://github.com/seevali/ergane/issues/3) |
| Isolation for per-sub-issue / parallel builds (§6, §9) | *partial* — [#4 Worktree-per-Issue](https://github.com/seevali/ergane/issues/4) |
| Scheduler that *continues gated work* (§9) | *partial* — [#5 Swarm + Mission Control](https://github.com/seevali/ergane/issues/5) |
| Label state machine + `loop:ready` contract (§4) — authoritative; supersedes #1's narrower verdict-gated labels | [#7](https://github.com/seevali/ergane/issues/7) |
| Manifest + identity markers + typed `reconcile.ts` (§5, §8) | [#8](https://github.com/seevali/ergane/issues/8) |
| Native sub-issue creation + source-issue-as-epic body (§6) | [#9](https://github.com/seevali/ergane/issues/9) |
| Big-issue intake binding: issue → PRD/epic/stories + sub-issues, track-routed (§10) | [#10](https://github.com/seevali/ergane/issues/10) |
| Re-sizing / correct-course (§7) | [#11](https://github.com/seevali/ergane/issues/11) |

---

## 12. Glossary

- **Front door** — the single entry point: every work item begins as a GitHub issue.
- **The gate** — the `triage → loop:ready` transition; the one human act authorizing spend + public writes.
- **`loop:ready` contract** — the five guarantees (sized, acceptance, bounded, unblocked, typed) that must hold or the loop refuses.
- **Manifest** — the per-component JSON cache of `story_id ↔ sub_issue#` + state + commit; derivable from markers ∪ git; never authoritative.
- **Identity marker** — `<!-- ralph:story=N.k source=S -->` in a sub-issue *body*; the durable anchor.
- **Projection** — GitHub state (issues, labels, comments) as a *view* of the authoritative files+git; written, never read-as-truth.
- **Append-and-supersede** — re-sizing without in-place edits: new child story ids, parent marked `superseded`.
- **`superseded`** — a terminal manifest/story state for a story replaced by a re-size split; reconciliation treats it as done-by-replacement, not an orphan.
- **Governing law** — §2: think at any scale, act only at the authorized scale; spend/scope changes return to the human.
- **Cool / warm labels** — cool = machine owns it; warm = needs the human.
- **Path A / Path B** — Path A = `--issue N` intake; Path B = `--epic FILE` execute.
- **`gh` / `addSubIssue`** — the GitHub CLI; the GraphQL mutation that creates a *native* sub-issue link.
- **The Ralph pattern** — fresh `claude -p` per step, context reloaded from disk, completion proved by `git log`.

## 13. Context dossier

- **Originating motivation:** On 2026-06-25, after filing five roadmap issues for write-back features, the owner (Seevali) recognized a deeper need: a *unified* system where GitHub Issues, BMAD, and the Ralph Loop harmonize so a maintainer (owner or community-served) moves products forward without friction. He asked the team to reconcile "two worlds" (BMAD's PRD→epic→story vs GitHub issues as tracker).
- **Who is acting:** Seevali — owner/maintainer of `seevali/ergane` (a public repo; the System Track is his real Ralph-loop product, despite living under a `demos/` folder — relocating it is a flagged future cleanup). He may switch LLM providers, hence the cold-start discipline.
- **Current project state (2026-06-25):** Path A read-only intake is built but never run end-to-end live. The round-trip chapter (write-back) is planned with five issues filed (#1–#6). This design is accepted but unimplemented.
- **Decisions taken (with why):**
  - *Epic = source issue, Story = sub-issue* — maps BMAD's hierarchy onto GitHub's native sub-issues; small work collapses to issue=unit.
  - *Files+git authoritative, GitHub a projection, manifest a cache* — keeps a fresh clone fully sufficient (portability) and the loop's existing `git log` completion logic intact.
  - *Typed reconciler module* (§8) — the three-source join is unverifiable in Bash; chosen over pure Bash despite adding a Node exception.
  - *Scheduler continues-gated-work-only* (§9) — supervised default; new work always needs a human gate.
  - *Detection autonomous, promotion human-gated* (§7) — under-sizing is often a wrong-requirement symptom; plan-shape is the maintainer's domain.
- **Open decisions:** whether the NEW component-epics (§11) become their own chapter or extend the round-trip chapter; the outward community-comment templates (§4). *(Resolved 2026-06-25: reconciler directory = `tools/`, CLAUDE.md Node-exception amendment applied — see §8.)*
- **Provenance:** distilled from a BMAD party-mode roundtable (Mary/analyst, John/PM, Winston/architect, Amelia/dev, Sally/UX) on 2026-06-25.
