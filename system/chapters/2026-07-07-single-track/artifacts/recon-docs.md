# Edit Inventory — Demo Track Deletion + Repo Rename

## 1. Every occurrence of `ralph-loop-demo`

**Living/current files (need editing for both operations):**
- `PUBLISHING.md:45,163,164,165` — path example + npm metadata (repository/bugs/homepage URLs)
- `installer/README.md:28` — link to main README
- `installer/package.json:18,21,23` — `repository.url`, `homepage`, `bugs.url`
- `installer/templates/loop/GETTING-STARTED.md:204` — link to issue-roundtrip chapter (this is a template shipped to *installed* downstream projects, not this repo itself — decide whether it should point at the new name or stay pinned to the historical chapter path)
- `system/design/issue-native-bmad-loop.md:234,238-248,271` — links to issue #12 tracker and self-description ("owner/maintainer of `seevali/ralph-loop-demo`") — **living design doc**, still in progress (Slice B #7–#11 open per memory), so these need updating, not preserving
- `system/design/issues/*.md` (n1–n5, epic) — links back to the design doc and to issues #1–#5 — same status as above, living
- `system/design/issues/create-design-issues.sh:9,12` — default repo slug fallback

**Parent monorepo (outside this repo, read-only per task but must be edited as part of the rename op):**
- `/home/seevali/projects/Metis/.gitmodules:25-27` — submodule path/URL
- `/home/seevali/projects/Metis/CLAUDE.md:27,61,106,167` — component map, quick-reference table, submodule table, BMAD exception note

**Historical records — DO NOT EDIT (frozen; only note the old name in context, doc portability satisfied by leaving as-is):**
- `TIMELINE.md:164,174,178-192,237-245` — narrates commits under the old repo name/URL
- `system/chapters/2026-05-24-modularize-loop-prompts/stories/1.6.md:196`, `ralph-sprint-progress*.md` — story/progress artifacts
- `system/chapters/2026-06-13-ralph-loop-installer/stories/*.md` (4.3, 2.4, ralph-sprint-progress*, 4.2, 3.1-done, 1.2, 1.1, 4.1, 2.5) — story specs referencing old paths/URLs
- `system/chapters/2026-06-13-ralph-loop-installer/artifacts/prd-draft-2026-06-12.md:13,33,67`
- `system/chapters/2026-06-25-github-issue-roundtrip/**` (README.md, prd.md, issues/*.md, tests/*.sh) — chapter is closed (per TIMELINE, 2026-07-04 close-out); all these are historical, including the test fixture strings that hardcode `seevali/ralph-loop-demo` as a mock repo slug (functionally inert, not living docs)
- `system/chapters/2026-07-04-installer-ux-refresh/ux-audit-findings.json:283` — audit evidence log, historical

## 2. README.md structure (282 lines) — KEEP/REWRITE/DELETE for single-track repo

| Line | Heading | Verdict |
|---|---|---|
| 1 | `# Ralph Loop + BMAD Agents — Demo` | REWRITE (title + rename) |
| 9 | `## Quick Start` | KEEP shape, REWRITE content (drop Exchange Rates framing) |
| 11 | `### Prerequisites` | KEEP |
| 18 | `### Install in 5 minutes` | KEEP shape, verify install steps still apply |
| 32 | `### Why this approach?` | REWRITE (currently sells the demo pattern) |
| 36 | `## What is this?` | REWRITE (currently defines "this demo") |
| 45 | `## What gets built` | DELETE (describes the Exchange Rates dashboard) |
| 51 | `## Repo layout` | REWRITE (drop `src/`, `docs/prd.md`, `docs/epics/`, `docs/stories/`) |
| 67 | `## Running the loop` | KEEP, scrub Exchange Rates example (line 75 epic path) |
| 82 | `### Two execution paths` | KEEP |
| 96,100 | Path A examples | KEEP shape, scrub sample paths if they reference the deleted epic |
| 111 | `### Useful flags` | KEEP |
| 127 | `## How the loop works` | KEEP |
| 145 | `## Watching the run` | KEEP |
| 149 | `## Cost expectations` | KEEP, re-verify numbers if they assumed 6 small demo stories |
| 160 | `## Limitations` | KEEP, review content |
| 166 | `## Adapting this to your project` | DELETE or heavily REWRITE — this section exists *because* the repo was a forkable demo; once the repo IS the loop (no app to adapt away from), this framing inverts |
| 176 | `### Files you'll customize` | DELETE (same reason) |
| 178 | `#### 1. Replace the demo content` | DELETE |
| 188 | `#### 2. Customize the prompts` | fold into a REWRITE'd "customizing the loop" section if kept |
| 195 | `#### 3. Set your checkpoint command` | fold in / KEEP concept |
| 205 | `#### 4. Update CLAUDE.md` | fold in / KEEP concept |
| 209 | `#### 5. Run` | fold in |
| 217 | `### How long does adoption take?` | DELETE (demo-framing) |
| 221 | `## Two Tracks` | REWRITE — the whole two-track/Demo-vs-System distinction disappears once Demo Track is deleted; this becomes single-track and the section either goes away or is replaced by an explanation of `system/chapters/` as *the* history |
| 230 | `## Credits` | KEEP |
| 237 | `## Manual Install (Fallback)` | KEEP shape |
| 241 | `### Prerequisites` | KEEP |
| 253 | `### Setup` | REWRITE — steps 256-272 install BMAD, scaffold Vite app, reference `docs/prd.md` / `docs/epics/exchange-rates-dashboard.md` by name; all Exchange-Rates-specific |
| 280 | `## License` | KEEP |

## 3. CLAUDE.md merge (root 81 lines + system/CLAUDE.md 49 lines → single-track root)

**Root CLAUDE.md** (`/home/seevali/projects/Metis/demos/ralph-loop-demo/CLAUDE.md`):
| Section | Verdict |
|---|---|
| Title + intro (lines 1-7, incl. "Two-track repo" callout) | REWRITE — drop the two-track pointer entirely once `system/CLAUDE.md` is merged in |
| `## Repo layout` (9-19) | REWRITE — remove `src/`, `docs/` demo entries |
| `## Stack rules` (21-30, React/Vite/TS/CSS/fetch/localStorage) | DELETE — these are Demo Track app-stack rules; replaced wholesale by system/CLAUDE.md's Bash+Markdown(+Node in installer/tools) rules |
| `## Agent behavior inside the loop` (32-54, SM/Dev/Reviewer for React stories) | DELETE — Demo Track-specific; system/CLAUDE.md's "additions" section becomes the base rules instead |
| `## Guardrails` (56-63) | MERGE — self-contained-repo rule, BMAD-modules-locked rule, loop-script-read-only rule, checkpoint discipline, no-CI/CD, no-new-top-level-dirs (with installer/tools exceptions) all survive; drop anything demo-specific |
| `## Definition of done` (65-72, references `cd src && npm run build`) | REPLACE with system/CLAUDE.md's Definition of done (bash -n checks, chapter-specific gates) |
| `## Logging repo evolution` (74-81) | KEEP — TIMELINE.md + chapter convention still apply |

**system/CLAUDE.md** (49 lines): the entire content becomes the *new baseline* for the merged file — its stack rules (line 9-14), agent behavior additions (16-35, minus the "root CLAUDE.md rules apply unchanged" framing since there's no longer a separate root to defer to), definition of done (37-45), and logging (47-49) all survive, with the "override the root CLAUDE.md React rules" framing (line 3, 9) deleted since there's nothing to override anymore. The `docs/`/`src/` Demo Track carve-outs (lines 26, 31) should be dropped once those paths no longer exist.

**Programmatic reads found** (`grep -rn "CLAUDE.md" scripts/ system/*.sh installer/ tools/`):
- `scripts/ralph-loop.sh:407-408` and `installer/templates/loop/ralph-loop.sh:407-408` — generic existence check (`-f "CLAUDE.md" || -f "$REPO_ROOT/CLAUDE.md"`), not path-specific to root vs system — no change needed
- `scripts/ralph-loop.sh:2976` (comment only) references "root CLAUDE.md: never reference `../`" — comment, low priority
- `system/ralph-loop-system.sh:149` — `EXTRA_STAGE_PATHS="scripts/ system/ README.md CLAUDE.md TIMELINE.md"` — generic filename, not path-specific, no change needed
- No script hardcodes a load of `system/CLAUDE.md` specifically as a distinct file — safe to merge/delete it once content is folded into root.

## 4. TIMELINE.md / todo.md / PUBLISHING.md / LICENSE

- **TIMELINE.md** — tag convention is `[Demo]` / `[System]` (line 5 explainer, entries at 11, 25, 39, 53, 67, 81, 100, 108, 120, 132, 146, 162, 198, 219, 231). Header explainer line 5 must be REWRITTEN to drop the two-track framing once Demo Track is gone (post-deletion, everything is one track — either retire the tags going forward or repurpose `[System]`-equivalent as the only tag). **All existing entries are historical — do not retag or edit them.** Only the top-of-file explainer (line 5) and future entries change.
- **todo.md** — entirely about Demo Track setup ("Preparing a Demo Repository to Showcase Ralph Loop + BMAD Agents", Exchange Rates PRD, Vite scaffold). Status block already marks it `✅ all 6 tasks complete (2026-05-24)`. Treat as a closed historical setup log, not a living doc — leave in place (or move under a chapter/archive) rather than rewrite; nothing here is consulted by scripts.
- **PUBLISHING.md** (167 lines, all about npm-publishing the installer) — REWRITE the `ralph-loop-demo` path references (§ "Publish workflow" step 1 line 45, Appendix npm metadata 163-165) to the new name. Otherwise content is installer-specific and orthogonal to the Demo Track deletion.
- **LICENSE** — MIT, `Copyright (c) 2026 Seevali Rathnayake`. No repo-name string in it; no change needed for either operation.

## 5. `docs/github-issue-intake-prompt.md` and `docs/project-conventions.md`

- **`docs/github-issue-intake-prompt.md`** (64 lines) — **zero references anywhere else in the repo** (confirmed via `grep -rln "github-issue-intake-prompt"` returning only itself). Safe to relocate to `system/design/` with no broken links. Since `docs/` is being deleted as part of the Demo Track removal, this file needs a new home regardless — `system/design/` is a reasonable landing spot per the task's suggestion.
- **`docs/project-conventions.md` (repo-level) does not exist** in this repo. All hits for "docs/project-conventions.md" are either:
  - the **installer's generated-artifact target name** — a file the installer *writes into downstream projects* (`installer/src/writer.js:99,184,188`, `installer/src/manifest.js:95`, `installer/src/doctor.js:22`, `installer/src/outro.js:86`, plus their tests) — unrelated to this repo's own `docs/`, no action needed
  - the **installer's template source** for that generated file: `installer/templates/loop/project-conventions.md` — unrelated, no action needed
  - There is a *different*, same-named-by-coincidence file this repo does use for its own loop: `scripts/prompts/common/project-conventions.md` (and its installer-template mirror `installer/templates/loop/prompts/common/project-conventions.md`) — this is a **Demo Track stack-rules prompt file** (React/Vite/TS specifics, `src/` references) consumed by `scripts/ralph-loop.sh`'s `load_prompt_layers()`. This one **must be rewritten** for single-track — it currently defines the React app stack rules that get injected into every agent's system prompt.

## 6. Chapter-folder template shape

**`system/chapters/2026-07-04-installer-ux-refresh/`** (files only, depth 1):
```
README.md
ux-audit-findings.json
```
(Minimal chapter — plan doc + one artifact; no `prd.md`/`epics/`/`stories/` because per system/README.md this chapter was audit-first, not story-driven in the usual sense — worth checking its README.md status header before using as a template if a new chapter needs the full PRD→epics→stories shape.)

**`system/chapters/2026-06-25-github-issue-roundtrip/`** (depth 2):
```
BUILD-JOURNAL.md
README.md
adr-001-github-as-shared-mutable-state.md
prd.md
issues/
  01-round-trip.md … 05-swarm-mission-control.md
  create-github-issues.sh
  epic-github-issue-roundtrip.md
tests/
  dry-run-prompts.golden
  idea2…5-*-smoke.sh, slice-a…e-*-smoke.sh, slice1-write-guard-smoke.sh
```

**`system/chapters/2026-06-13-ralph-loop-installer/`** (canonical full-shape example, depth 2 — matches `system/README.md`'s documented convention exactly):
```
README.md
prd.md  (+ prd-ralph-loop-installer.md legacy name)
artifacts/
  prd-draft-2026-06-12.md
epics/
  ralph-loop-installer.md
stories/
  N.M.md, N.M-done.md, N.M-review.md  (per story)
```
For a new chapter, `system/README.md`'s documented shape (lines 8-17) is: `README.md` (plan), `prd.md`, `epics/`, `stories/` (populated at runtime by SM), `artifacts/` (optional). The 2026-06-13 installer chapter is the cleanest reference instance of this full shape.

## 7. Other `src/` / Exchange Rates references outside `scripts/`

**Living docs needing rewrite (Demo Track deletion):**
- `README.md:5,47,75,225,269` — see §2 table
- `CLAUDE.md:3,7` — see §3
- `system/README.md:5,17,45,54` — describes itself as separate from "the demo track... the dashboard at `src/`"; needs full rewrite once there's no Demo Track to be separate from (the two-track architecture this file documents disappears)
- `todo.md:9,28,38` — historical setup log, see §4 (leave as historical, don't rewrite)
- `docs/prd.md`, `docs/epics/exchange-rates-dashboard.md` — the files being deleted themselves

**Prompt/config files that ARE the Demo Track's stack rules (need rewrite, not historical):**
- `scripts/prompts/review/overlay.md:11,13` — React-specific reviewer rules
- `scripts/prompts/common/project-conventions.md:3,6,10` — React/Vite/TS stack conventions
- Their mirrors under `installer/templates/loop/prompts/...` are **installer template sources for downstream projects**, not this repo's own config — leave alone unless the installer's own generic scaffolding is also being renamed/changed (out of scope here)

**Historical chapter files (DO NOT EDIT — frozen records):**
- `TIMELINE.md` (multiple lines)
- `system/chapters/2026-06-13-ralph-loop-installer/stories/*.md` (1.4, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3 + `-done`/`-review` variants), `epics/ralph-loop-installer.md`
- `system/chapters/2026-05-24-modularize-loop-prompts/stories/1.1.md`, `1.5.md`
- `system/chapters/2026-06-25-github-issue-roundtrip/prd.md`, `BUILD-JOURNAL.md`