# Ralph Loop — Workload-Neutral Defaults: Mechanics Brief & Recommendation

Read-only investigation. No files modified. All line numbers verified against the current working tree (`main`, commit `596b222`).

---

## 1. The `--dry-run-prompts` code path

### 1.1 What it reads

`--dry-run-prompts` is a flag (`scripts/ralph-loop.sh:65,213,271`) that short-circuits the script near the very end, at `scripts/ralph-loop.sh:3941-3967`, **after** all function definitions and persona loading but **before** the Phase-0 gate and `main` (`scripts/ralph-loop.sh:4023`). Despite living near the bottom of the file, everything from the top of the script down to that point still runs unconditionally on every invocation, including epic parsing:

1. **Arg/dependency validation** (`:300-315`) — `--project-dir`/`--checkpoint` required, `claude`/`jq`/`git` on `PATH`.
2. **Path resolution** (`:317-361`):
   - `PROJECT_DIR` resolved from `PROJECT_DIR_ARG` (default `"src"`, `:62`) relative to `REPO_ROOT`; **hard exit** if the directory doesn't exist (`:326`: `[[ ! -d "$PROJECT_DIR" ]] && { echo Error...; exit 1; }`).
   - `EPIC_FILE` (default `"docs/epics/exchange-rates-dashboard.md"`, `:59`) checked for existence relative to cwd, then relative to `REPO_ROOT`; **hard exit** at `:347-354` unless `--issue`/`--issues` was passed (deferred/skipped for Path A/driver mode).
   - `PRD_FILE` (default `"docs/prd.md"`, `:63`) resolved via `resolve_optional_doc()` (`:363-375`) — only warns if missing (`:382`), doesn't exit.
3. **BMAD persona loading** (`:400-605`) — reads `.claude/skills/bmad-create-story/SKILL.md`, `bmad-dev-story/SKILL.md`, `bmad-code-review/SKILL.md` (+ its `steps/*.md`), and (for Path A roles) `bmad-create-prd`, `bmad-create-architecture`, `bmad-create-epics-and-stories`. Each load emits a `log_info "Loaded … agent persona from …"` line — this is what golden lines 2-7 capture.
4. **`load_prompt_layers()` defined** (`:613-668`) — see §3 below for its exact composition.
5. **Story plan finalization, `finalize_story_plan()`** (`:429-451`), invoked at `:458-460` for Path B (no `--issue`/`--issues`) *before* the dry-run block is even reached:
   - If `STORIES_ARG == "all"` (the default, `:60`), it greps `EPIC_FILE` for `^### Story [0-9]+\.[0-9]+` headers (`:431-432`), joins the extracted `X.Y` IDs with commas, and **prints** `echo -e "${CYAN}--stories all -> $STORIES_ARG${NC}"` (`:435`). This is golden line 1: `--stories all -> 1.1,1.2,1.3,1.4,1.5,1.6` — literally the six story headers in `docs/epics/exchange-rates-dashboard.md`.
   - Hard exit if the epic has zero matching headers (`:433-434`).
6. **The dry-run block itself** (`:3941-3967`): builds `_dryrun_roles=(sm dev review)`, adding `pm architect planner` only if `$ISSUE_NUMBER` is set (never true for a bare invocation). For each role it calls `load_prompt_layers "$role"`, prints `=== ROLE ===`, then the resolved prompt, then a blank line. Exits 0 if all roles resolved, 1 otherwise. **No `claude` CLI invocation ever happens** — this is the whole point of the flag (byte-stable, offline, free).

### 1.2 What lands in the golden, and where it lives

Golden file: `system/chapters/2026-06-25-github-issue-roundtrip/tests/dry-run-prompts.golden` (1505 lines). Structure:
- Line 1: the `--stories all -> 1.1,1.2,1.3,1.4,1.5,1.6` line (from `finalize_story_plan`, §1.1 step 5).
- Lines 2-7: the six `Loaded … persona/workflow from …` lines (timestamps normalized to `[TIMESTAMP]`, absolute paths normalized to `<REPO_ROOT>`).
- Line 8: `=== SM ===`, then the fully composed SM system prompt (through line 488).
- Line 489: `=== DEV ===` (through 1025).
- Line 1026: `=== REVIEW ===` (through end, 1505 total lines).

Consumer: `system/chapters/2026-06-25-github-issue-roundtrip/tests/slice1-write-guard-smoke.sh:38,57-95`.

**Exact regeneration procedure** (from the smoke script itself, `:30,74-79`):
```
system/chapters/2026-06-25-github-issue-roundtrip/tests/slice1-write-guard-smoke.sh --update-golden
```
Internally this runs `capture_dryrun()` (`:57-62`): `"$LOOP" --dry-run-prompts 2>/dev/null | normalize` where `$LOOP` = `scripts/ralph-loop.sh` (absolute path) and `normalize()` (`:50-55`) is a `sed` pass that strips ANSI color codes, collapses `[YYYY-MM-DD HH:MM:SS]` timestamps to `[TIMESTAMP]`, and replaces the literal `$REPO_ROOT` string with `<REPO_ROOT>`. The normalized stream is written straight to `$GOLDEN` (`:76`). The comparison in the default (non-update) run mode is a byte-exact `diff -u "$GOLDEN" <(capture_dryrun)` (`:89`).

Everything upstream of `--update-golden` is transitively coupled to Demo Track state: the golden's content is a direct function of (a) `docs/epics/exchange-rates-dashboard.md`'s six `### Story X.Y` headers, (b) the `src/` directory's mere existence (only the `-d` check matters, not its content), (c) `scripts/prompts/**` content (React/Vite/TS-specific, see §3), and (d) whatever `.claude/skills/bmad-*` happens to be installed locally (BMAD-version-dependent, already a source of golden drift unrelated to this investigation).

---

## 2. `system/ralph-loop-system.sh` — invocation, env vars, prompt layers, CLAUDE.md reads

### 2.1 Every flag/env var it sets

`system/ralph-loop-system.sh:152-157` execs the canonical loop with:
```
--prd "$PRD_REL" --epic "$EPIC_REL" --project-dir . --checkpoint "$DEFAULT_CHECKPOINT" "${PASSTHROUGH[@]}"
```
where `PRD_REL`/`EPIC_REL` (`:121-122`) are derived from the resolved chapter's `prd.md` and first file under `<chapter>/epics/*.md` (`:104-118`), and `PROJECT_DIR_ARG` is always literally `.` (the whole repo root is the work surface for System Track — `:134,155`).

Env vars exported before the `exec`:
- `STORIES_DIR="$REPO_ROOT/$STORIES_REL"` (`:141`, `STORIES_REL = <chapter_dir>/stories`) — overrides the loop's own default at `scripts/ralph-loop.sh:390` (`STORIES_DIR="${STORIES_DIR:-$REPO_ROOT/docs/stories}"`), redirecting story specs away from `docs/stories/` (Demo Track).
- `EXTRA_STAGE_PATHS="scripts/ system/ README.md CLAUDE.md TIMELINE.md"` (`:149`) — consumed by `scripts/ralph-loop.sh:3808-3813` and appended to the git-add `stage_paths` array at commit time (see §4).

### 2.2 `DEFAULT_CHECKPOINT` — the critical Demo Track coupling

`system/ralph-loop-system.sh:128`:
```bash
DEFAULT_CHECKPOINT="bash -n $LOOP_SCRIPT && bash -n $SCRIPT_DIR/ralph-loop-system.sh && $LOOP_SCRIPT --dry-run-prompts >/dev/null"
```
This is the checkpoint command handed to `ralph-loop.sh --checkpoint`. Note the third clause: `$LOOP_SCRIPT --dry-run-prompts` is invoked **bare** — no `--project-dir`, no `--epic`. That means every System Track run's own checkpoint re-triggers the two hard-exit checks from §1.1 against the loop's **built-in defaults** (`PROJECT_DIR_ARG="src"`, `EPIC_FILE="docs/epics/exchange-rates-dashboard.md"`), not against the chapter it's actually building. **This is the load-bearing coupling**: deleting `src/` or `docs/epics/exchange-rates-dashboard.md` breaks every System Track run's checkpoint, independent of anything the chapter itself touches.

### 2.3 Prompt layers a System Track run composes

Identical to any Path B run — `system/ralph-loop-system.sh` passes no role/prompt-related flags and there is no separate System-Track prompt layer set. A System Track run's SM/Dev/Review agents receive **the same React/Vite/TS-flavored Layer 3** described in §3 (`scripts/prompts/common/project-conventions.md` + `scripts/prompts/review/overlay.md`), even though System Track work is Bash/Markdown (per `system/CLAUDE.md`). Today this is silently tolerated (System Track stories don't hit the React-specific blocking criteria in practice), but it's a live latent mismatch, not a designed feature.

### 2.4 Does any script programmatically read `CLAUDE.md`?

No. `grep -rn "CLAUDE.md" scripts/ system/*.sh installer/src installer/bin installer/templates` turns up exactly two live references, both in `scripts/ralph-loop.sh` (and its byte-identical installer template copy):
- `:407-408` — `if [[ ! -f "CLAUDE.md" && ! -f "$REPO_ROOT/CLAUDE.md" ]]; then echo -e "${YELLOW}Warning: no CLAUDE.md found…${NC}"; fi` — an **existence check only**, no content is read, no branching on which CLAUDE.md (root vs. `system/CLAUDE.md`) is present.
- `:2976` — a comment referencing the root CLAUDE.md guardrail (`never reference ../`), not a runtime read.

Every "CLAUDE.md / memory files (load if exist)" line visible in `scripts/logs/*.log` originates from the `claude` CLI's own context-loading (it reads `CLAUDE.md` in cwd automatically when invoked), not from anything `ralph-loop.sh` or `ralph-loop-system.sh` does. `system/ralph-loop-system.sh` itself contains zero `CLAUDE.md` references.

---

## 3. The prompt layer system

### 3.1 `load_prompt_layers()` — layer inventory

Function at `scripts/ralph-loop.sh:613-668`, documented cold-start-portably in `scripts/prompts/README.md`. Three layers, joined with `\n\n---\n\n`:

| Layer | Source | Unconditional across roles? | Demo-specific content? |
|---|---|---|---|
| 1 — Execution Context | `scripts/prompts/common/execution-context.md` (`:620`) | Yes — every role (`sm/dev/review/pm/architect/planner`) gets the identical file | No — verified `grep -niE "react\|vite\|typescript\|src/\|demo\|exchange"` → zero matches. Generic non-interactive/no-HALT instructions. |
| 2 — BMAD Persona | Live `.claude/skills/<skill>/SKILL.md`, falls back to `scripts/prompts/bmad-fallbacks/<role>.md` if the skill dir/file is missing (`:624-638`) | Per-role, not demo-specific | No — fallbacks and skills are generic BMAD content. |
| 3a — Conventions | `scripts/prompts/common/project-conventions.md` (`:641`) | **Yes — every role**, including `pm`/`architect`/`planner` used by Path A issue-driven builds | **Yes, entirely.** Its only content section (`## Project Conventions (React / Vite / TypeScript)`) hardcodes React 19/Vite/TS-strict, `src/`, native `fetch`, `localStorage`-only persistence, Vitest+RTL. This is the file `scripts/prompts/README.md:81` explicitly tells forkers to edit. |
| 3b — Role overlay | `scripts/prompts/<role>/overlay.md` (`:644`) | Per-role | **Partial.** `sm/overlay.md`, `dev/overlay.md`, `architect/overlay.md` are stack-neutral (checked, zero React/Vite/TS/`src/` hits). `review/overlay.md:4,10,11,13` hardcodes the literal checkpoint string `cd src && npm run build && npm test --if-present` (not via `{{CHECKPOINT_CMD}}` — a separate, undocumented hardcode) and stack-rule block criteria (`tsc`/Vite build errors, `src/package.json` dependency additions, non-`fetch` HTTP, imports outside `src/`). `scripts/prompts/README.md:82` also flags this file as the second fork-point. |

The only substitution performed is `{{CHECKPOINT_CMD}}` → `$CHECKPOINT_CMD` (`:662-665`), applied to the full concatenated `result`, so it fires wherever the placeholder literally appears in Layer 3 files — currently only in `project-conventions.md:20`. `review/overlay.md`'s checkpoint mention is **not** placeholder-driven text, so it drifts independently if `--checkpoint` is overridden.

**Consequence for workload-neutrality**: even after fixing `EPIC_FILE`/`PROJECT_DIR_ARG` defaults, every Dev/Review/SM/PM/Architect/Planner invocation — Demo Track *or* System Track *or* a future Path A issue build on some other stack — still gets force-fed "you are building a React/Vite/TS app in `src/`" as the freshest instruction in its system prompt (`scripts/prompts/README.md:19`: "Layer 3 comes last so demo-specific stack rules … are the freshest instruction"). This is baked into the golden's SM/DEV/REVIEW bodies (golden lines 8-1505 all end with this Layer 3 content) and is a second, independent axis of "Demo Track dependency" beyond the CLI-default axis.

### 3.2 `installer/scripts/sync-templates.sh` — comparison set, direction, gate mechanics

`installer/scripts/sync-templates.sh:4-11` fixes source/dest pairs:
- `scripts/ralph-loop.sh` → `installer/templates/loop/ralph-loop.sh`
- `scripts/ralph-watch.sh` → `installer/templates/loop/ralph-watch.sh`
- `scripts/prompts/` (whole tree) → `installer/templates/loop/prompts/` (whole tree)

**Direction**: repo canonical source (`scripts/`) → installer template copy (`installer/templates/loop/`), never the reverse. `--sync` (default, `:13-45`) does `cp -p` for the two scripts and `rm -rf "$DEST_PROMPTS" && cp -rp "$SOURCE_PROMPTS" "$DEST_PROMPTS"` for the prompts tree (full clobber-and-recopy, so files deleted from source disappear from dest on next sync). `--check` (`:47-92`) does `cmp -s` byte comparison for the two named scripts, then walks every file under `$SOURCE_PROMPTS` via `find "$SOURCE_PROMPTS" -type f -print0` (`:83`) and `cmp -s` each against its computed dest path; missing or differing files each print a `Drift detected: …` line to stderr and set `drift=1`; any drift → exit 1 with a "Run 'installer/scripts/sync-templates.sh' to resync." hint (`:87`).

Verified today: `installer/templates/loop/ralph-loop.sh` is byte-identical to `scripts/ralph-loop.sh` (`diff` empty), and `installer/templates/loop/prompts/common/project-conventions.md` is byte-identical to `scripts/prompts/common/project-conventions.md` — i.e. **the installer currently ships the React-specific conventions file verbatim into every fresh install**, regardless of the target stack.

**How to add/remove a file from the gate**:
- *Add a new prompt file*: drop it anywhere under `scripts/prompts/` — `sync-templates.sh --check`'s `find` picks it up automatically on the next check (no script edit needed); run `sync-templates.sh` (`--sync`) once to materialize the copy so `--check` stops reporting it missing.
- *Remove a prompt file*: delete it from `scripts/prompts/`; `--check`'s `find` no longer walks it (auto-drops from the gate). **Caveat**: `--check` never looks for *extra* files present only in `$DEST_PROMPTS` — a stale file left behind in `installer/templates/loop/prompts/` after a source deletion will NOT be flagged as drift unless `--sync` (full `rm -rf`+recopy) is run to physically remove it. Running `--sync` right after any prompt-file deletion is the only way to actually drop it from the shipped template.
- *Add/remove one of the two named scripts* (`ralph-loop.sh`, `ralph-watch.sh`): requires editing the `for pair in …` loop at `:52` (hardcoded two-element list) — these are not tree-walked like the prompts dir.

There is a separate, installer-owned generic conventions asset — `installer/templates/loop/project-conventions.md` (top-level, **not** under `prompts/`, so untouched by `sync-templates.sh`) — with `{{STACK_DESCRIPTION}}`/`{{CHECKPOINT_COMMAND}}`/`{{APP_DIR}}` placeholders, rendered by `installer/src/writer.js:184-188` into the *target* project's `docs/project-conventions.md`. This file is **never read by `ralph-loop.sh` at runtime** (only `scripts/prompts/common/project-conventions.md` is, per `load_prompt_layers():641`) — `installer/templates/loop/GETTING-STARTED.md:165` claims "The agents read this file" but that claim doesn't match `load_prompt_layers()`'s actual read path. This is an existing, orthogonal installer bug (out of this brief's direct scope, flagged for awareness — see recommendation §5.4) but structurally relevant: it's already-existing prior art for a generic/placeholder-driven conventions template that a workload-neutral fix could reuse or converge with.

---

## 4. `stage_paths` hardcoding and other hardcodes

`scripts/ralph-loop.sh:3801-3807`, inside the per-story checkpoint-success commit block:
```bash
local -a stage_paths=(
  "${STORIES_DIR}/${story_id}.md"
  "${STORIES_DIR}/${story_id}-done.md"
  "${STORIES_DIR}/${story_id}-review.md"
  src/
  docs/stories/
)
if [[ -n "${EXTRA_STAGE_PATHS:-}" ]]; then
  local -a extra=(${EXTRA_STAGE_PATHS})
  stage_paths+=("${extra[@]}")
fi
( cd "$REPO_ROOT" && git add "${stage_paths[@]}" 2>/dev/null ) || true
```
`src/` and `docs/stories/` are **unconditionally always present** — `EXTRA_STAGE_PATHS` only appends, never replaces. `git add … 2>/dev/null || true` means staging a now-nonexistent `src/`/`docs/stories/` pathspec fails silently (git just warns "pathspec … did not match any files" to the suppressed stderr) so this wouldn't hard-crash a run against a deleted Demo Track — but it's dead weight and, worse, on a repo that legitimately has a *different* `src/` directory in a fork it would silently over-stage unrelated app code into every story commit.

Full grep of the script for the other hardcode sites (`grep -n "docs/prd\|docs/epics\|docs/stories\|exchange-rates\|\"src\"\|'src'\| src/\|/src\b" scripts/ralph-loop.sh`):
- `:59,62-63` — the three top-level defaults (already covered).
- `:138,143,146,218-227` — `usage()` help text and the worked examples, all showing demo values (`docs/epics/exchange-rates-dashboard.md`, `src`, `docs/prd.md`, `cd src && npm run build && npm test --if-present`).
- `:332-336` — `COMPONENT_DISPLAY_NAME`: `if [[ "$COMPONENT_NAME" == "src" ]]; then COMPONENT_DISPLAY_NAME="Exchange Rates Dashboard"` — a purely cosmetic banner/progress-header label special-case, harmless to leave or remove.
- `:390` — `STORIES_DIR` default `docs/stories` (already overridable via env var, which System Track already exercises).
- `:342-343,1670,1703,1813,1873-1875,1897-1898,1964,2053,2288,2303,2757,2918,3055-3056,3059-3060,3079,3093,3264-3265,4005` — all under `docs/prd/issue-N*`, `docs/epics/issue-N.md`, `docs/architecture/issue-N.md`. These are **Path A's own generated-artifact convention**, not Demo Track leakage — they're issue-numbered paths nested under `docs/`, independent of `docs/prd.md`/`docs/epics/exchange-rates-dashboard.md`/`src/`. Safe to leave as-is; they don't reference the Demo Track PRD/epic/app dir at all.
- `:3203-3204` — comment noting the `cd "$PROJECT_DIR"` (into `src/`) happens before driver-mode `$0` resolution; a correctness note, not itself a new hardcode.
- `:3780-3807` — the `stage_paths` block above.

Net: outside of `usage()` text and the three CLI defaults, the script's substantive Demo Track coupling is narrow — `PROJECT_DIR_ARG`/`EPIC_FILE`/`PRD_FILE` defaults (§1.1), the `stage_paths` array (§4), and (transitively) `scripts/prompts/common/project-conventions.md` + `scripts/prompts/review/overlay.md` (§3.1).

---

## 5. Recommendation

### 5.1 Evaluating the three options

**(a) Committed neutral fixture epic+dir that the two bare call sites point at explicitly.**
Requires: a new fixture epic under version control (e.g. `system/fixtures/` or similar — a new top-level-ish path, which the repo's CLAUDE.md guardrail against new top-level dirs would need to accommodate, though a subdirectory of an existing allowed dir like `scripts/` avoids that) with at least one `### Story X.Y` header, a `-d`-passing directory, and updating both bare call sites — `system/ralph-loop-system.sh:128`'s `DEFAULT_CHECKPOINT` and `slice1-write-guard-smoke.sh:61`'s `capture_dryrun()` — to pass `--project-dir <fixture>` and `--epic <fixture-epic>` explicitly instead of relying on script defaults. **Downside**: doesn't change the *defaults* themselves, so a bare `./scripts/ralph-loop.sh` (the documented "just run it" entry point, `usage():218-224`) still hard-exits once `src/`/`docs/epics/exchange-rates-dashboard.md` are gone, unless the two call sites *and* the defaults are both changed — meaning this option, if it stops at "just the two call sites," doesn't actually make the loop's *defaults* workload-neutral, it just papers over the two known consumers. It also leaves a permanently-fake "Exchange Rates Dashboard"-shaped fixture sitting in the repo purely to satisfy a checkpoint, which is exactly the kind of ballast a "delete the Demo Track" cleanup is trying to remove.

**(b) Make `--dry-run-prompts` skip existence checks.**
The existence checks are at `:326` (`PROJECT_DIR`) and `:347-354` (`EPIC_FILE`), both **upstream** of the `DRY_RUN_PROMPTS` flag check at `:3941` — they'd need to be reordered or short-circuited specifically when `$DRY_RUN_PROMPTS` is true. This directly fixes the golden/checkpoint's ability to run without `src/`/the demo epic — but `finalize_story_plan()` (`:429-451`, invoked at `:458-460`) still greps `EPIC_FILE` for story headers and hard-exits at `:433-434` if it finds none, and that call site doesn't currently know about `DRY_RUN_PROMPTS` either (it runs before the flag's block). **Also**: this only fixes the *diagnostic* path (`--dry-run-prompts`); it does nothing for a real, non-dry-run invocation of the loop with no `src/`/epic present — that's still a hard failure by design (correctly so — you can't build stories against a nonexistent epic). So (b) is necessary-but-insufficient on its own: it would make the *checkpoint* pass without touching real defaults, but leaves the actual `--project-dir`/`--epic`/`--prd` defaults still pointing at deleted paths for any real run.

**(c) Remove demo defaults entirely — `--project-dir`/`--epic` become required, with a clear error.**
Delete `EPIC_FILE="docs/epics/exchange-rates-dashboard.md"` (`:59`), `PROJECT_DIR_ARG="src"` (`:62`), `PRD_FILE="docs/prd.md"` (`:63`) as *defaults*; instead leave them empty and let the existing "required" validation pattern already used elsewhere in the script (`:303-307`: `[[ -z "$EPIC_FILE" ]] && { echo Error: --epic is required; usage; }` — currently only exercised on the Path A branch) apply universally. Then:
- `system/ralph-loop-system.sh:128`'s `DEFAULT_CHECKPOINT` must stop calling `$LOOP_SCRIPT --dry-run-prompts` bare — it needs `--project-dir . --epic "$EPIC_REL"` (values it already computes at `:121-123` and already passes to the *main* invocation at `:154`) threaded through to the checkpoint string too.
- `slice1-write-guard-smoke.sh:61`'s `capture_dryrun()` must pass `--project-dir <something>` and `--epic <something>` explicitly — which means it needs its own tiny fixture (this is where option (a) becomes a *sub-component* of (c), scoped only to the test's own throwaway needs, not a permanent repo fixture).
- `usage()`'s example block (`:218-227`) and flag docs (`:135-147`) need rewriting to show `--project-dir`/`--epic` as required with no defaults shown.
- `COMPONENT_DISPLAY_NAME`'s `"src"` special-case (`:332-336`) and `stage_paths`' hardcoded `src/`/`docs/stories/` (`:3805-3806`) become genuinely dead/wrong weight and should go — with `STORIES_DIR` (already parameterized, `:390`) doing the job `docs/stories/` used to, and `EXTRA_STAGE_PATHS`/an equivalent mechanism covering the app dir.

### 5.2 Recommendation: **(c), with a minimal (b)-shaped carve-out for `--dry-run-prompts`'s own smoke test, and no (a)**

Pick (c) as the primary fix because it's the only option that makes the loop's *actual default behavior* — not just its diagnostic mode — workload-neutral: after (c), `./scripts/ralph-loop.sh` with no flags fails fast with "Error: --project-dir is required" / "Error: --epic is required" (using the pattern already proven at `:303-307`), which is honest and correct for a generic loop with no fixed workload, rather than silently defaulting to a deleted demo app.

Combine with a scoped version of (b)/(a) **only inside the test harness**, not the production script: give `slice1-write-guard-smoke.sh` its own tiny synthetic epic + directory (e.g. a 2-line epic with one `### Story 1.1` header and an empty scratch dir, generated inline by the smoke script itself, or a small fixture file committed under the chapter's own `tests/` folder — chapter-scoped, not a new top-level repo concept) and pass `--project-dir`/`--epic` explicitly in `capture_dryrun()` (`:61`). This keeps the production script's design pure ("no defaults, required flags, clear error") while giving the test something deterministic and stack-agnostic to exercise `--dry-run-prompts` against.

`system/ralph-loop-system.sh`'s `DEFAULT_CHECKPOINT` should do the same: since it already resolves `EPIC_REL`/`PROJECT_DIR_ARG` (`.`) for the main invocation, thread those same values into the `--dry-run-prompts` checkpoint clause instead of relying on a bare call. This is a pure fix at `system/ralph-loop-system.sh:128` regardless of which of (a)/(b)/(c) is chosen for the main script — it's currently broken independent of the Demo Track question, in that it silently depends on demo defaults that a System-Track-only clone would never think to preserve.

### 5.3 What the new golden should be derived from

Once `--dry-run-prompts` no longer depends on `src/`/`docs/epics/exchange-rates-dashboard.md` (via the test-harness fixture above), regenerate `dry-run-prompts.golden` by running the smoke script's `--update-golden` mode (`slice1-write-guard-smoke.sh:74-79`) against the fixture-driven `capture_dryrun()`. The new golden's line 1 will read `--stories all -> 1.1` (or whatever story IDs the fixture epic declares) instead of `1.1,1.2,1.3,1.4,1.5,1.6` — this is expected and correct, not a regression.

### 5.4 Every test/smoke/doc that must change

1. `scripts/ralph-loop.sh` — remove/replace the three defaults (`:59,62-63`), add required-flag checks for `--project-dir`/`--epic` (extending the existing pattern at `:303-307` to Path B, not just Path A), drop the `"src"` display-name special-case (`:332-336`), drop `src/`/`docs/stories/` from `stage_paths` (`:3805-3806`, keeping `STORIES_DIR`-derived paths + `EXTRA_STAGE_PATHS`), rewrite `usage()` flag docs and examples (`:134-227`).
2. `system/ralph-loop-system.sh:128` — `DEFAULT_CHECKPOINT` must pass `--project-dir . --epic "$EPIC_REL"` into its `--dry-run-prompts` clause.
3. `system/chapters/2026-06-25-github-issue-roundtrip/tests/slice1-write-guard-smoke.sh` — `capture_dryrun()` (`:57-62`) needs a fixture epic/dir and explicit `--project-dir`/`--epic` flags; regenerate `dry-run-prompts.golden` via `--update-golden` afterward.
4. `system/chapters/2026-06-25-github-issue-roundtrip/tests/dry-run-prompts.golden` — regenerated (new story-ID line, and if `scripts/prompts/common/project-conventions.md`/`review/overlay.md` are also genericized per §5.5, the entire SM/DEV/REVIEW bodies change too).
5. Any other smoke in that same `tests/` directory that shells out to the loop bare (worth an explicit re-check of `idea2-confessing-pr-smoke.sh`, `idea3-worktree-smoke.sh`, `idea4-triage-smoke.sh`, `idea5-swarm-smoke.sh`, `slice-a` through `slice-e` — confirmed by grep that `idea3-worktree-smoke.sh` and others reference `EPIC_FILE` but as an *observed output field* of Path A runs (which always pass `--issue`, deriving their own `docs/epics/issue-N.md` — not the demo epic), so those are not expected to need changes; worth a final `grep -L -- '--project-dir\|--epic' system/chapters/*/tests/*.sh` sweep before landing to be certain none silently rely on the Path-B bare defaults).
6. `README.md` and `CLAUDE.md` (root) — repo-layout / quick-reference sections that document `docs/epics/exchange-rates-dashboard.md`, `src/`, `docs/prd.md` as the canonical Demo Track paths need updating once those paths cease to exist; the `## Stack rules` section in root `CLAUDE.md` (React/Vite/TS) becomes vestigial documentation for a deleted track and should either be removed or explicitly marked historical.

### 5.5 A necessary companion fix, surfaced by this investigation but adjacent to the CLI-defaults question

Deleting `src/`/the demo epic/PRD does **not** make the loop's *prompts* workload-neutral on its own (§3.1): `scripts/prompts/common/project-conventions.md` and the block-criteria in `scripts/prompts/review/overlay.md` are unconditionally injected into every role's system prompt (Path B and Path A alike) and are entirely React/Vite/TS/`src/`-specific. `scripts/prompts/README.md:77-84` already documents these as the two fork-points, and `installer/templates/loop/project-conventions.md` already demonstrates the placeholder pattern (`{{STACK_DESCRIPTION}}`/`{{CHECKPOINT_COMMAND}}`/`{{APP_DIR}}`) this repo could adopt for its own `scripts/prompts/common/project-conventions.md`. Doing so would also incidentally fix an existing, independent installer bug: `installer/src/writer.js:184-188` renders a stack-aware `docs/project-conventions.md` in every fresh install, but `load_prompt_layers()` never reads that file (`scripts/ralph-loop.sh:641` only reads `scripts/prompts/common/project-conventions.md`, which the installer ships as a byte-identical copy of *this* repo's React-specific file per `sync-templates.sh`) — so installed copies currently get React conventions regardless of the wizard's `--stack-description` answer. This is out of scope for "delete the Demo Track" strictly, but the same edit (genericizing `scripts/prompts/common/project-conventions.md` with `{{PLACEHOLDER}}`s) closes both gaps at once and is worth scoping into the same chapter rather than deferring.