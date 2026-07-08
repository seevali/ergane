# Single Track — strip the demo, ship the example, name the loop Ergane

**Status: In progress (opened 2026-07-07).**
**Track:** System (this is the last chapter that needs the tag — see Decision D6).
**Method:** supervised multi-agent orchestration (orchestrator specs → implementer → two adversarial reviewers → fixer → independent verification per slice), same as the [2026-06-25 round-trip chapter](../2026-06-25-github-issue-roundtrip/BUILD-JOURNAL.md) and the [2026-07-04 installer UX chapter](../2026-07-04-installer-ux-refresh/README.md).

---

## Cold-start context

**What this repo was on 2026-07-07, before this chapter.** A two-track repo named `ralph-loop-demo`:

- **Demo Track** — a clonable showcase at the repo root: a React + Vite + TypeScript app skeleton under `src/`, a fully-authored PRD for an "Exchange Rates Dashboard" at `docs/prd.md`, its epic at `docs/epics/exchange-rates-dashboard.md`, and stack rules in the root `CLAUDE.md`. The idea: clone the repo, run `scripts/ralph-loop.sh` (the **Ralph Loop** — an orchestrator that drives BMAD agent roles SM → Dev → Review → Fix through fresh Claude Code sessions, one story at a time; the pattern name comes from Geoff Huntley's "Ralph"), and watch it build the app. **The demo was never actually run** — `src/` still held the vanilla Vite scaffold and `docs/stories/` was empty; running it costs real API money and was deliberately skipped at setup (see `todo.md`, 2026-05-24).
- **System Track** — the maintainer's R&D lab under `system/`: dated chapters (this folder's siblings) that use the loop to improve the loop itself, driven by `system/ralph-loop-system.sh`.

**Why this chapter exists.** On 2026-07-07 the owner (Seevali) decided the dual state was no longer worth maintaining: the repo's real product is the loop + its installer (`installer/`, a Node CLI that installs the loop into any repo) + typed tools (`tools/`), and the demo added weight without ever having been shown. An evidence pass that day confirmed the demo was safe to remove (details in [`artifacts/recon-loop.md`](artifacts/recon-loop.md), [`artifacts/recon-installer.md`](artifacts/recon-installer.md), [`artifacts/recon-docs.md`](artifacts/recon-docs.md) — read those three before implementing anything here):

1. The demo app is **not load-bearing**: every chapter regression smoke builds its own synthetic fixtures; System Track runs use the repo's own tooling as the workload. The only hard dependencies on demo files are *accidental* — two call sites invoke `ralph-loop.sh --dry-run-prompts` bare and silently inherit the demo defaults.
2. The installer **could not yet replace** the demo experience: its `scaffold` task source writes TODO-placeholder PRD/epic stubs, so a fresh install has nothing runnable to watch. The demo's one genuinely valuable artifact is the authored Exchange Rates PRD + epic.
3. The repo name `ralph-loop-demo` becomes wrong the moment the repo *is* the loop rather than a demo of it.

So this chapter does three things at once: makes the loop **workload-neutral** (no baked-in demo defaults), moves the Exchange Rates content into the installer as a ready-to-run **example task source** (so "install it and watch it build an app" stays possible — better than the in-repo demo, because it exercises the real install path), and **renames the product to Ergane**.

**What stays out of scope.** The live `--write`-on dogfood run (the round-trip chapter's still-open validation gate) is the owner's own task, planned for the weekend of 2026-07-11 — nothing here blocks or depends on it. Publishing to npm remains a manual human step (`PUBLISHING.md`). Publishing blog changes is the owner's call (Decision D7). Moving the repo's directory inside the Metis parent monorepo is deferred (Decision D8).

---

## Decision ledger

### D1 — The name: **Ergane**

The loop and this repo are renamed **Ergane** (er-GAH-nee): *Athena Ergane*, "Athena the Worker," the goddess's epithet as patroness of craftsmen. Two reasons beyond sound:

- **It fits the ecosystem's naming pattern and its mythology.** The owner's components are Greek-mythology-named (Metis, Kleos, Nyx, Mneme, Moneta). In myth, Metis is Athena's mother — the Metis ecosystem giving rise to the working craftswoman is exactly the relationship this tool has to the monorepo it was born in.
- **It is the only fully-clean candidate.** A clearance pass on 2026-07-07 (npm registry, GitHub search, web/trademark search) found: `ergane` free on npm both scoped and unscoped, `seevali/ergane` free, and only dead or unrelated web hits (a 2008 Esperanto dictionary freeware, a furniture boutique). Runners-up and rejections: `kyklos` (usable but the unscoped npm name is taken and the brand space is crowded), `automedon` (two live AI-orchestration companies use the exact name — confusion risk), `telos` (**blocker**: 1.4k-star danielmiessler/Telos + a NASDAQ-listed security company with registered software trademarks), `talos` (**blocker**: Talos Linux, Cisco Talos).

npm package: **`@seevali/ergane`** (scoped — guaranteed available under the owner's account and consistent with the previously-planned `@seevali/ralph-loop`; this also resolves the installer chapter's open "Decision 5" on package naming). GitHub: **`seevali/ergane`** (GitHub redirects the old `ralph-loop-demo` URLs, so published links — including the 2026-05-25 blog post — keep working).

### D2 — Rename depth: brand-level now, engine-level deferred

**Renamed in this chapter:** the GitHub repo, the npm package name and its URL fields, README/docs titles and copy, installer display strings ("Ralph Loop" → "Ergane" in user-facing text), `PUBLISHING.md`, parent-monorepo references.

**Deliberately NOT renamed:** `scripts/ralph-loop.sh`, `scripts/ralph-watch.sh`, the `bin/ralph.js` command file, `RALPH_*` environment variables, the `.ralph/` runtime directory, and `ralph/issue-N` branch naming. Why: these are load-bearing engine names covered by byte-exact regression machinery (the `--dry-run-prompts` golden, the installer's `sync-templates.sh --check` drift gate, ten chapter smokes) and by the owner's muscle memory for the weekend dogfood run. The public story is simple and honest: **Ergane is the product; its engine speaks Ralph** — README credits the Ralph pattern (Geoff Huntley) explicitly. Engine-level renaming, if ever wanted, is a future mechanical chapter with the goldens regenerated once.

### D3 — Workload-neutrality: remove the demo defaults entirely (recon option c)

`scripts/ralph-loop.sh` currently defaults `EPIC_FILE=docs/epics/exchange-rates-dashboard.md`, `PROJECT_DIR_ARG=src`, `PRD_FILE=docs/prd.md` (lines 59–63) and hard-exits if they don't exist. After this chapter, **`--epic` and `--project-dir` are required flags** (Path B; Path A `--issue`/`--issues` mode already derives its own), failing fast with a clear error using the script's existing required-flag pattern (`:303-307`). No committed fake fixture ships in the production script's defaults (rejected recon option a: it papers over two call sites while leaving dead defaults; rejected option b alone: it fixes only the diagnostic path).

Companion fixes that fall out of the same decision:
- `system/ralph-loop-system.sh:128` `DEFAULT_CHECKPOINT` threads `--project-dir . --epic "$EPIC_REL"` into its `--dry-run-prompts` clause (values it already computes for the main invocation).
- `slice1-write-guard-smoke.sh` generates its own tiny synthetic epic + scratch dir inline and passes explicit flags; the golden is regenerated via the smoke's own `--update-golden` mode. The golden's story-ID line changes from the demo's `1.1,…,1.6` to the fixture's — expected, not a regression.
- The `COMPONENT_DISPLAY_NAME` special-case (`if [[ "$COMPONENT_NAME" == "src" ]] → "Exchange Rates Dashboard"`, `:332-336`) is deleted — it currently mislabels *every* installed user's banner whose app dir is `src`. Progress headers fall back to the epic's own `## Epic N: Title` header.
- `stage_paths`' unconditional `src/` and `docs/stories/` entries (`:3805-3806`) are replaced by `$PROJECT_DIR_ARG`- and `$STORIES_DIR`-derived paths, so a fork with an unrelated `src/` is never silently over-staged.
- `usage()` text and examples rewritten to show required flags.

**Prompt-layer neutrality (the second axis).** Deleting demo files does not fix the prompts: `scripts/prompts/common/project-conventions.md` (React/Vite/TS rules) and `scripts/prompts/review/overlay.md` (hardcoded `cd src && npm run build && npm test` string and React block-criteria) are injected into **every** role's system prompt, and the installer ships them verbatim to every target project regardless of the wizard's stack answers — a live bug. Fix, in this chapter:
- `load_prompt_layers()` Layer 3a resolution becomes: **read `$REPO_ROOT/docs/project-conventions.md` if it exists, else fall back to `scripts/prompts/common/project-conventions.md`**. The installer *already* renders a per-project `docs/project-conventions.md` from wizard answers into every install — this makes the loop actually read it, which `GETTING-STARTED.md` line 165 already (falsely, until now) claims happens.
- This repo commits its own `docs/project-conventions.md` carrying the single-track working rules (Bash + Markdown; Node.js permitted in `installer/` and `tools/` — content merged from `system/CLAUDE.md`'s stack rules).
- The shipped fallback `scripts/prompts/common/project-conventions.md` becomes stack-agnostic ("follow the project's `docs/project-conventions.md`; if absent, infer conventions from the existing code and change nothing you weren't asked to").
- `review/overlay.md` uses the existing `{{CHECKPOINT_CMD}}` substitution instead of the hardcoded string, and its block-criteria become stack-generic (build/test failure, security, imports escaping the app dir, violations of the project's conventions file).

### D4 — Installer: third task source `example`

A third wizard option (and `--task-source example`) alongside `scaffold`/`existing`: *"Use the shipped example (Exchange Rates Dashboard) — a complete, ready-to-run PRD + epic."* Design per [`artifacts/recon-installer.md`](artifacts/recon-installer.md) §6:

- Templates live at `installer/templates/example/prd.md` + `epic.md` — verbatim copies of the authored demo content (no `{{…}}` placeholders needed; verified none present). Written to the target at **`docs/prd.md` + `docs/epics/exchange-rates-dashboard.md`** — the same paths this repo itself used, so the example reads as a real project, and the epic keeps its `## Epic 1:` header (which the progress UI needs).
- Ownership: **user-owned** (the `getOwnership()` default) — `update` never clobbers a user's mid-demo edits; `uninstall` preserves them by default.
- `outro.js`'s two-way `scaffold` boolean becomes an explicit three-way switch; a `GETTING-STARTED` variant for the example path says "this one is ready to run — no TODOs to fill" and gives the exact loop invocation (which, post-D3, must pass `--epic`/`--project-dir` explicitly).
- `cli-parser.js`'s `taskSource` validate array gains `'example'`; `doctor.js:236`'s hardcoded two-path epic check is generalized (manifest-driven) so the example epic is actually validated rather than silently skipped.
- `appDir` default stays `src` (the example PRD's own text is keyed to `src/`).
- `sync-templates.sh` needs **zero changes** (it only polices the loop scripts + prompts tree).

### D5 — Strip scope (what is deleted / relocated / preserved)

- **Deleted:** `src/` (vanilla Vite scaffold, never built on), `docs/prd.md`, `docs/epics/exchange-rates-dashboard.md`, `docs/stories/` — *after* D4 has copied the PRD/epic content into installer templates.
- **Relocated:** `docs/github-issue-intake-prompt.md` → `system/design/` (zero inbound references; it documents System Track's Path A intake design and only accidentally lived under the demo's `docs/`).
- **`docs/` itself stays** — it is Path A's output surface (`docs/prd/issue-N/`, `docs/epics/issue-N.md`, …) and now hosts `docs/project-conventions.md` (D3).
- **Historical records are never edited**: TIMELINE entries, closed chapter folders (including test-fixture strings that mention old names), `todo.md` (a closed 2026-05-24 setup log — it gets a two-line "historical document" banner, nothing else).

### D6 — Docs rewrite: single-track

README rewritten per the section-by-section verdict table in [`artifacts/recon-docs.md`](artifacts/recon-docs.md) §2 — the repo presents as: *Ergane, an autonomous BMAD build loop; install it into your repo with `npx @seevali/ergane`; this repo is also where Ergane builds itself* (`system/chapters/` as the lab notebook). `system/CLAUDE.md`'s content (Bash/Markdown rules, definition of done) merges up into the root `CLAUDE.md` as the *only* rule set; `system/CLAUDE.md` becomes a three-line pointer to root. `TIMELINE.md`'s header explainer drops the two-track framing: historical entries keep their `[Demo]`/`[System]` tags, new entries are untagged. `system/README.md` loses its "separate from the demo track" framing. The living design doc `system/design/issue-native-bmad-loop.md` gets its repo-name references updated (it is *not* historical — Slice B #7–#11 is still open against it).

### D7 — Blog: banner + sequel, drafted here, published by the owner

The 2026-05-25 post *"Watching the Loop Forge Itself"* on seevali.dev narrates the two-track era and stays untouched as a record (consistent with this repo's own "history over tidiness" rule). This chapter drafts, as artifacts only: a two-sentence banner for the old post and a sequel post draft ("the loop leaves the nest": single-track, Ergane, install-the-example). Publishing means pushing to the seevali.dev repo, which auto-deploys — that is the owner's action, not this chapter's. Audio companion tracks stay as-is (historical, like the post).

### D8 — Parent monorepo: URL + names now, directory move later

`/home/seevali/projects/Metis/.gitmodules` gets the new remote URL; `Metis/CLAUDE.md`'s component map / quick-reference / submodule-table rows are updated to say Ergane with honest stack/test commands. The submodule's *path* stays `demos/ralph-loop-demo/` for now — moving it (to `agents/`? a new `tools/`?) changes the working directory of live sessions and the mount-allowlist story, so it is deferred to an explicit owner decision. The BMAD-install exception note in Metis/CLAUDE.md keeps applying to this path.

---

## Slices

Each slice = implement → two adversarial reviews (distinct lenses) → fix → verify, one commit per slice.

- **Slice 1 — Rename (brand level).** `gh repo rename` → `seevali/ergane`; origin URL update; `installer/package.json` name/repository/homepage/bugs; `pkg.js` fallback string; installer user-facing copy strings; `installer/README.md`; `PUBLISHING.md`; `system/design/` living-doc name refs; parent `.gitmodules` + `Metis/CLAUDE.md`. Gate: installer suite green (`cd installer && npm test`), `sync-templates.sh --check` green, grep shows no *living-doc* `ralph-loop-demo`/`@seevali/ralph-loop` stragglers (historical files exempt per D5).
- **Slice 2 — Workload-neutral loop (D3).** All `ralph-loop.sh` + `ralph-loop-system.sh` + smoke/golden + prompt-layer changes. Gate: `bash -n` both scripts; slice1 smoke green against regenerated golden; idea2–idea5 smokes green; `sync-templates.sh` resynced + `--check` green; a manual `--dry-run-prompts` run with explicit flags succeeds; a bare run fails with the new clear error.
- **Slice 3 — Installer example task source (D4).** Gate: installer suite green with new tests (wizard select, non-interactive flag, writeMap, outro 3-way, doctor epic validation, E2E install→doctor on the example path); fresh-install sandbox run shows a runnable example.
- **Slice 4 — Strip + docs (D5, D6, D7).** Deletions, relocation, README/CLAUDE.md/TIMELINE/system-README rewrites, `todo.md` banner, blog drafts under `artifacts/`. Gate: full re-verification (all suites + smokes + drift gate), no dangling references to deleted paths in living docs, cold-start read of the new README by a fresh reviewer agent.

## Definition of done

1. All four slice gates green, verified by an independent agent that re-runs everything from the artifacts (no trust in implementer self-reports).
2. `TIMELINE.md` entry appended; this README's status header flipped to **Complete** with commit hashes.
3. Commits pushed to `seevali/ergane`.
4. Explicitly still open after this chapter: npm publish (human step, `PUBLISHING.md`), the live `--write` dogfood run (owner, weekend of 2026-07-11), Metis directory move (D8), blog publication (D7), Slice B #7–#11 of the issue-native design.

## Glossary

- **Ralph Loop / Ralph pattern** — run a coding agent in a fresh session per step, in a loop, against a spec; named after Geoff Huntley's "Ralph". The engine script here: `scripts/ralph-loop.sh`.
- **Ergane** — this repo's product name as of this chapter (D1): the Ralph-pattern loop + BMAD integration + installer + watch/mission-control tooling.
- **BMAD** — the BMAD Method, a spec-driven agent workflow (PRD → epics → stories, with SM/Dev/Review roles). Installed at `_bmad/`; the loop loads its personas from `.claude/skills/bmad-*`.
- **Demo Track / System Track** — the two-track split this chapter dissolves (see cold-start context above).
- **Path A / Path B** — the loop's two intake modes: Path A plans from a GitHub issue (`--issue N`); Path B executes an existing epic file (`--epic <file>`).
- **Golden** — `system/chapters/2026-06-25-github-issue-roundtrip/tests/dry-run-prompts.golden`, a byte-exact snapshot of the composed agent prompts; regenerated deliberately, never casually.
- **Drift gate** — `installer/scripts/sync-templates.sh --check`: byte-compares the repo's loop scripts + prompts against the installer's shipped templates.
