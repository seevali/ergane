# Mechanics Brief: Adding an 'example' Task Source to the Ralph Loop Installer

Scope: `/home/seevali/projects/Metis/demos/ralph-loop-demo/installer/`. All line numbers verified against the current tree (no changes made).

---

## 1. Task-source plumbing end-to-end

**Wizard question** — `installer/src/wizard.js:288-306` (Step 6). A `select` prompt with two options today:

```js
options: [
  { value: 'scaffold', label: 'Start with a template PRD and epic (recommended)', hint: '...' },
  { value: 'existing',  label: 'Point to an existing PRD and epic', hint: '...' },
],
initialValue: 'scaffold',
```

If `taskSource === 'existing'`, a follow-up `text` prompt collects `taskSourcePath` (`wizard.js:308-317`, default `docs/prd.md`).

**Non-interactive path** — `buildNonInteractivePlan()` (`wizard.js:61-137`) reads `cliAnswers.taskSource ?? 'scaffold'` (line 70) and **hardcodes `taskSourcePath: undefined`** at both line 109 and line 128, regardless of what `existing` would need. There is no `--task-source-path` CLI flag anywhere — `cli-parser.js`'s `FLAG_DEFINITIONS` (lines 7-74) has no such entry, and `bin/ralph.js`'s `.option(...)` chain (lines 50-60) doesn't register one either. **This is the known gap**: `--yes --task-source existing` produces a plan with `taskSourcePath: undefined`, and downstream code (`outro.js:50`) falls back to the literal string `'docs/prd.md'` regardless of where the user's real file lives. Confirmed dead-end by test: `wizard.test.js:485-492` asserts only `plan.taskSource === 'existing'`, never checks `taskSourcePath` in the non-interactive branch — nobody has ever wired this up.

**Where `taskSource` branches** (`installer/src/*.js`):
- `writer.js:218` — `buildWriteMap()`: `if (plan.taskSource === 'scaffold')` writes the two scaffold docs; any other value (including `'existing'` or a hypothetical `'example'`) skips that block and writes nothing task-source-specific.
- `outro.js:44-51` — `const scaffold = plan.taskSource !== 'existing';` (binary, not a switch — a third value falls into the `scaffold` branch by default, which would be wrong for a not-yet-considered `'example'`).
- `writer.js` and `outro.js` never read `taskSourcePath` to *copy* anything — `existing` is purely advisory: the installer trusts the user's path already has real content and just names it in the outro/GETTING-STARTED text.

**Writes and manifest ownership per source:**
| taskSource | Files written by `buildWriteMap` | Ownership (`getOwnership`, `writer.js:92-107`) |
|---|---|---|
| `scaffold` | `docs/epics/project-prd.md`, `docs/epics/project-stories.md` (both template-rendered via `renderTemplate` + `validateNoUnsubstituted`) | **user-owned** (falls through to the default at line 106 — anything not explicitly listed as installer-owned) |
| `existing` | nothing task-specific | n/a — no files to own |
| always, regardless of taskSource | `docs/project-conventions.md`, `scripts/ralph-loop.sh`, `scripts/ralph-watch.sh`, `scripts/prompts/**`, `GETTING-STARTED.md`, `{appDir}/.gitkeep`, `.gitignore` | installer-owned except `GETTING-STARTED.md`, `.gitkeep`, and `.gitignore` (special-cased, see §2) |

**GETTING-STARTED.md rendering** — `writer.js:207-210` always loads and renders the *same* template through `renderTemplate(gettingStartedTpl, substitutions)` with `APP_DIR`, `CHECKPOINT_COMMAND`, `STACK_DESCRIPTION`, `PACKAGE_NAME`, `CLI_INVOCATION`. **There are no conditional blocks by task source today** — `GETTING-STARTED.md` (`installer/templates/loop/GETTING-STARTED.md`) unconditionally tells the reader "The installer scaffolded two files under `docs/epics/`" (line 19) and gives a run command hardcoded to `docs/epics/project-prd.md` / `docs/epics/project-stories.md` (lines 28-33), which is simply wrong copy when `taskSource === 'existing'` today (a pre-existing, unrelated gap — the doc never branches). Any new task source needs either a new template variant or new `{{...}}`-substituted blocks in this same file, since none of that infrastructure exists yet.

---

## 2. Manifest semantics

Manifest schema (`writer.js:582-591`): `{version, installedAt, updatedAt, files: {path: {ownership, checksum, path}}, createdDirs, wizardAnswers, targetClass, installedVersion}`.

- **Checksums**: `hashFile`/`hashString` (`writer.js:57-70`) — SHA-256 over CRLF→LF-normalized content, prefixed `sha256:`. Used identically by `writeManifest`, `detectConflicts`, `detectUpdate`, and doctor's drift check.
- **Ownership** is a single dichotomy, computed once at write time by `getOwnership()` (`writer.js:92-107`) from the relative path — **not stored anywhere else, not passed in by the caller**. It's a hardcoded path allowlist:
  - `installer-owned`: `scripts/ralph-loop.sh`, `scripts/ralph-watch.sh`, `scripts/prompts/*`, `docs/project-conventions.md`, `.gitignore`.
  - `user-owned`: everything else, by default (line 106 comment literally says "Scaffold docs (docs/epics/, docs/prd.md) are user-owned").
- **`update`** (`executeUpdate`, `writer.js:691-752`): only ever writes files where `getOwnership(filePath) === 'user-owned'` is **false** (line 705 skip). Since `getOwnership` is a static function of path, not a manifest lookup, update will **never touch any file under `docs/epics/`** (or a hypothetical `docs/prd.md`) no matter what's in the manifest — this is what "never clobbers user edits" already means structurally for scaffold docs.
- **`doctor`** (`doctor.js:101-139`): checksum-mismatch on a `user-owned` file is never checked at all — the checksum-match loop (`doctor.js:102-139`) runs over **every** manifest entry regardless of ownership, but the only special-case is `isUserEditableInstalledFile()` (`doctor.js:20-23`), which is narrower than "user-owned" — it only names `docs/project-conventions.md` and `scripts/prompts/**` (both *installer-owned* files the user is invited to edit) as INFO-not-FAIL. A drifted *user-owned* file (e.g. an edited `docs/epics/project-prd.md`) still hits the checksum-mismatch branch (`doctor.js:129-135`) and is reported as a **hard FAIL** telling the user to run `update` — which is misleading copy for a file update will never touch. This is a pre-existing wart, not something the example source introduces, but it means: **whatever ownership the example PRD/epic get, doctor will flag user edits to them as "File modified... run update to restore" even though update can't/won't restore them.**
- **`uninstall`** (`uninstall.js:236-328`): `categorizeFiles()` splits by the *manifest's recorded* `ownership` field (not recomputed). `installer-owned` files are removed unconditionally (phase 3). `user-owned` files are preserved by default, prompted/force-removed otherwise (phase 4).
- **`createdDirs`** (`writer.js:511-531`, `computeCreatedDirs`): snapshotted *before* `executeWrite` runs, recording only ancestor dirs that don't yet exist. Used by `pruneEmptyInstallerDirs` (`uninstall.js:83-115`) so uninstall only removes dirs the installer itself created — a pre-existing `docs/` survives.

**Recommendation for example PRD/epic ownership**: keep them **user-owned**, exactly like scaffold docs — that already falls out of `getOwnership()`'s default (line 106) as long as the new files don't literally match the `installer-owned` allowlist paths. This guarantees `update` never rewrites a user's edited example content, and `uninstall` preserves them by default. The only wrinkle: pick paths that don't collide with the existing `scaffold` scaffold paths (`docs/epics/project-prd.md`, `docs/epics/project-stories.md`) if you want `scaffold` and `example` to coexist as genuinely separate options — see §6.

---

## 3. sync-templates.sh drift gate

`installer/scripts/sync-templates.sh` (full read). `check_mode()` (lines 47-92) compares **exactly three things**, byte-for-byte via `cmp -s`:
1. `scripts/ralph-loop.sh` (repo root) ↔ `installer/templates/loop/ralph-loop.sh`
2. `scripts/ralph-watch.sh` (repo root) ↔ `installer/templates/loop/ralph-watch.sh`
3. every file under `scripts/prompts/` (repo root) ↔ the same tree under `installer/templates/loop/prompts/`

**It does not enumerate or care about any other file in `installer/templates/loop/`** — `GETTING-STARTED.md`, `epic-stub-prd.md`, `epic-stub-stories.md`, `project-conventions.md` are all hand-authored installer content with no repo-root source of truth, and the gate never looks at them. **Adding new template files (an `example/` PRD + epic, or a new GETTING-STARTED variant) requires zero changes to `sync-templates.sh`** — it's structurally scoped to the loop-script/prompts sync only.

---

## 4. Test suite

**Location & framework**: `node --test` (Node's built-in test runner, no Jest/Vitest/Mocha — Node v24.14.0 in this environment). Entry point: `installer/package.json:42` — `"test": "node --test 'src/**/*.test.js' 'test/**/*.test.js'"`. Confirmed via a live run: **288 tests, 1 suite, 0 failures**, ~19.7s.

Two test-file locations, both matched by the glob:
- `installer/src/*.test.js` — co-located unit tests (`wizard.test.js`, `writer.test.js`, `doctor.test.js`, `uninstall.test.js`, `manifest.test.js`, `updateDetector.test.js`, `updateConflictResolver.test.js`, `cli-parser.test.js`, `bmad.test.js`, `colors.test.js`, `outro.test.js`, `preflight.test.js`).
- `installer/test/*.test.js` — cross-cutting E2E/integration (`e2e.test.js`, `e2e-update.test.js`, `lifecycle.test.js`, `noninteractive.test.js`, `refresh.test.js`, `classify.test.js`, `placeholder.test.js`) plus shared helpers `fixtures.js` and `assertions.js` (not test files themselves — no `.test.js` suffix, so the glob skips them).

**Wizard-answer stubbing convention** (`wizard.test.js:13-25`, `buildMockPrompts()`): a mock `{intro, outro, isCancel, cancel, confirm, select, text}` bundle where each prompt type auto-answers with `opts.initialValue` unless overridden via positional-index arrays: `{ confirms: [...], texts: [...], selects: [...] }`, consumed in call order via internal counters. E.g. `wizard.test.js:115-124` overrides just `selects: ['existing']` to drive the taskSource choice, leaving all `text`/`confirm` prompts at defaults — this is the pattern a new `'example'` option (or any select-branch test) should reuse.

**Scaffold-output assertion convention** — `installer/test/assertions.js`:
- `assertFR6FilesPresent(dir)` (lines 39-82) — requires `docs/epics/` to exist as a *directory*, generically (doesn't hardcode filenames inside it beyond requiring `scripts/prompts/` to be non-empty).
- `assertEpicStubsParseable(dir)` (lines 92-126) — reads every `.md` in `docs/epics/` **except files ending `-prd.md`**, and regex-checks each has `/^###\s+Story\s+\d+\.\d+:\s+.+/m`. This convention (`*-prd.md` = skip, everything else in `docs/epics/` = must have story headers) is filename-suffix-driven, not task-source-aware — an example epic at, say, `docs/epics/exchange-rates-dashboard.md` would satisfy this check as-is; a PRD placed outside `docs/epics/` (e.g. bare `docs/prd.md`, matching the real repo's actual layout) would simply not be scanned by this assertion at all (neither pass nor fail — it's just not `docs/epics/`).
- `assertManifestValid(dir)` (lines 140-191) — generic manifest-shape + installer-owned-checksum check, ownership-agnostic; works unmodified for any new task source.
- `sha256File`, `assertNoANSIEscapes`, `assertFilesUnchanged`, `assertDirEmpty` — generic, reusable as-is.

**Which existing test files a new `'example'` task source must extend:**
- `installer/src/cli-parser.js` + `installer/src/cli-parser.test.js` — the `taskSource` flag's `validate()` (`cli-parser.js:57-61`) hardcodes `['scaffold', 'existing'].includes(v)`; adding `'example'` requires updating this array and its test.
- `installer/src/wizard.js` + `installer/src/wizard.test.js` — the `select` options list (`wizard.js:292-303`), `buildNonInteractivePlan`'s taskSource default handling is already permissive (any string flows through), but new tests should assert the third branch like `wizard.test.js:485-492` does for `existing`.
- `installer/src/writer.js` + `installer/src/writer.test.js:770-791` (`'buildWriteMap includes scaffold docs only when taskSource is scaffold'`) — this test's title and assertions are literally binary (`scaffoldMap` vs `existingMap`); it needs a third case added, and `buildWriteMap`'s `if (plan.taskSource === 'scaffold')` block (`writer.js:218`) needs an `else if (plan.taskSource === 'example')` sibling.
- `installer/src/outro.js` + `installer/src/outro.test.js` — `const scaffold = plan.taskSource !== 'existing'` (`outro.js:44`) is a two-way boolean; a third source needs this rewritten as an explicit switch or the boolean renamed/extended, plus new assertions mirroring `outro.test.js`'s `'outro run-the-loop step points at the scaffolded epic/prd and app dir'` and `'outro existing-mode points --prd and --epic at the same brought file'`.
- `installer/test/noninteractive.test.js` and `installer/test/e2e.test.js` — add an E2E case analogous to `e2e.test.js`'s existing criteria (install → doctor → assertions), and a CLI-flag test analogous to `noninteractive.test.js:170` (`'E2E: --app-dir flag embeds custom dir in scaffold epic stubs'`).
- `installer/src/doctor.js` + `installer/src/doctor.test.js` — the epic-headers check (`doctor.js:236`) **hardcodes exactly two paths**: `['docs/epics/project-stories.md', 'docs/epics/project-prd.md']`. If the example source ships files under different names (e.g. `docs/epics/exchange-rates-dashboard.md`, `docs/prd.md`), doctor's story-header validation **silently never runs on them** — no fail, no pass finding, just skipped. This needs to either read the manifest-recorded epic path(s) generically, or the hardcoded array needs extending. Flagged again in §6 as the most consequential wrinkle.

**E2E pattern** (`e2e.test.js`): spins up a real temp dir via `createEmptyFixture()`/`createInstalledFixture()` (`test/fixtures.js:90-153`), shells out to the actual `bin/ralph.js` via `runCli()` (`fixtures.js:38-57`, `spawnSync` with `NO_COLOR=1`, piped stdio so no TTY), then asserts on real filesystem state. `createInstalledFixture` always passes `--use-bmad no` to avoid network calls during tests (`fixtures.js:125,137`).

---

## 5. Naming surfaces (`@seevali/ralph-loop`, `github.com/seevali/ralph-loop-demo`, "Ralph Loop" branding)

**Package identity, single source of truth**: `installer/src/pkg.js` (full file, 37 lines) — `getPackageName()` reads `installer/package.json`'s `name` field with a hardcoded fallback `'@seevali/ralph-loop'` (lines 24, 26); `cliInvocation()` returns `` `npx ${getPackageName()}` ``. Every other file that needs the CLI name calls through this helper (`writer.js:174,179`, `outro.js:1,21`, `doctor.js:4,46`), so **a package rename only requires editing `installer/package.json`'s `name` field** for the CLI-invocation strings — they're not hardcoded elsewhere in `.js` source.

**`installer/package.json`** (full file read) — the actual identity record:
```
name: "@seevali/ralph-loop"                                    (line 2)
repository.url: "https://github.com/seevali/ralph-loop-demo.git" (line 18)
homepage: "https://github.com/seevali/ralph-loop-demo#readme"    (line 21)
bugs.url: "https://github.com/seevali/ralph-loop-demo/issues"    (line 23)
funding.url: "https://github.com/sponsors/seevali"                (line 26)
bin.ralph: "./bin/ralph.js"                                        (line 32)
```

**Files containing the literal string `@seevali/ralph-loop` or `github.com/seevali/ralph-loop-demo`** (exhaustive, via `grep`):
- `installer/package.json` (lines 2, 18, 21, 23)
- `installer/src/pkg.js` (lines 18, 24, 26, 32 — doc comments + fallback string)
- `installer/README.md` (line 8: `npx @seevali/ralph-loop install`; line 28: main-README link)
- `installer/templates/loop/GETTING-STARTED.md` (line 204: hardcoded link to `github.com/seevali/ralph-loop-demo/tree/main/system/chapters/...`)
- `PUBLISHING.md` (repo root, full file read — 167 lines) — the manual npm-publish checklist. Contains `@seevali/ralph-loop` **13 times** (lines 3, 33, 34, 87, 91, 99, 100, 108, 120, 135, 149, 158, 167) and `github.com/seevali/ralph-loop-demo` **3 times** (lines 163-165), plus a literal local path `cd /path/to/ralph-loop-demo/installer` (line 45).

**Files containing the "Ralph Loop" branding string** (exhaustive, via `find`+`grep`, excluding `*.test.js`):
`installer/README.md`, `installer/package.json` (description field, line 4), `installer/src/wizard.js` (lines 199, 204, 217, 219, 220 — intro banner + classification messages), `installer/src/updateDetector.js`, `installer/src/manifest.js` (`MANIFEST_NOT_FOUND_MESSAGE` etc.), `installer/src/writer.js` (comments), `installer/src/preflight.js:82` (`'bash not found. The Ralph Loop requires a bash environment.'`), `installer/src/doctor.js`, `installer/src/uninstall.js`, `installer/src/classify.js:20` (doc comment), `installer/src/outro.js`, `installer/bin/ralph.js` (command descriptions, e.g. line 49: `'Install or update a Ralph Loop project'`), `installer/test/assertions.js` (comments only), `installer/templates/loop/epic-stub-prd.md`, `installer/templates/loop/project-conventions.md`, `installer/templates/loop/GETTING-STARTED.md`, `installer/templates/loop/epic-stub-stories.md`, `installer/templates/loop/prompts/README.md`.

A rename touches: the package name (1 field), 3 URL fields, the `pkg.js` fallback string, and dozens of user-facing copy strings across `bin/ralph.js`, `wizard.js`, template markdown — the copy strings are cosmetic (no functional dependency on the literal text "Ralph Loop"), but they're numerous and not centralized the way the package name is.

---

## 6. Recommended insertion design

**Add a third `taskSource` value: `'example'`.** Reasons over "a flag on scaffold": the wizard's Step 6 is already a `select` with a `hint` field per option — a third option (`'Use the shipped example (Exchange Rates Dashboard)'`, hint explaining it's a complete, ready-to-run PRD+epic for first-run learning) fits the existing UI pattern with zero new prompt steps. A flag layered onto `scaffold` would require the wizard to ask a *second* question conditionally, which the current flow has no precedent for (compare: `taskSourcePath` is the only conditional follow-up, gated on `taskSource === 'existing'`).

**Template files**: `installer/templates/example/` (new directory), containing `prd.md` and `epic.md` (or reuse the repo's actual filenames — `exchange-rates-dashboard-prd.md` / `exchange-rates-dashboard.md` — either works; sync-templates.sh doesn't police this dir per §3). These are **not** rendered through `renderTemplate()`/`validateNoUnsubstituted()` — confirmed via `grep` that neither `docs/prd.md` nor `docs/epics/exchange-rates-dashboard.md` (repo root, the real content) contains any `{{...}}` placeholder or hardcoded App-directory/checkpoint/stack line the way `epic-stub-*.md` do (those template stubs interpolate `{{APP_DIR}}`, `{{CHECKPOINT_COMMAND}}`, `{{STACK_DESCRIPTION}}` at their top; the real PRD/epic have none). So `buildWriteMap`'s new `else if (plan.taskSource === 'example')` branch should just `loadTemplateFile` and write the content verbatim (no substitution pass needed) — simpler than the scaffold branch.

**Ownership**: per §2, leave these **user-owned** — the default `getOwnership()` fallthrough already does this as long as the paths don't literally match the installer-owned allowlist (`writer.js:95-101`). This means `update` will never overwrite a user's edits mid-demo, matching how scaffold docs already behave.

**Where they land / naming collision to resolve**: writing to `docs/epics/project-prd.md` + `docs/epics/project-stories.md` (the same paths `scaffold` uses) would let `outro.js` and `GETTING-STARTED.md`'s existing hardcoded paths (§1) work unmodified — but it erases the useful signal that this is "the real exchange-rates demo, not your blank scaffold," and collides with `assertEpicStubsParseable`'s convention if two different task sources both land at the same path (no functional problem, since only one taskSource is chosen per install, but it makes the manifest/outro text generic instead of naming the actual app). Recommend instead: write to `docs/prd.md` + `docs/epics/exchange-rates-dashboard.md` — **matching the real repo's own paths exactly** — so the outro/GETTING-STARTED run command can read naturally as "here's a real example, here's its real path," and so a user diffing their install against the public demo repo sees identical structure. This requires:
1. `outro.js:44-51` rewritten from the `scaffold` boolean to a 3-way switch (`scaffold` / `existing` / `example`), each producing its own `prdFile`/`epicFile` pair.
2. `GETTING-STARTED.md` gets a new `{{...}}`-gated block (or a wholly separate `GETTING-STARTED.example.md` variant, chosen by `buildWriteMap` — cleaner given §1's finding that there's currently zero conditional-block infrastructure in the template) that says "the example app is already ready to build — just run the loop" instead of "fill in the TODOs first."
3. **`doctor.js:236`'s hardcoded epic-path array must be extended** (or generalized to iterate `Object.keys(manifest.files)` filtered by `.md` under `docs/`) — otherwise doctor silently skips validating the example epic's story headers, which is the single most consequential wrinkle found in this recon: doctor would report a false "all checks passed" on an example install whose epic file it never actually looked at.

**APP_DIR default for the example path**: default to `src` specifically when `taskSource === 'example'` (already the installer's global default at `wizard.js:245`, `cli-parser.js:12` — no change needed if the user takes the default, but worth locking `src` as non-overridable-in-spirit for this path since the real app's `Component.tsx`/`Component.test.tsx` convention and CSS Modules stack description are all keyed to that directory name in the shipped PRD's own text — confirmed at `docs/prd.md:11`: *"the React + Vite + TypeScript app under `src/`"*).

**A synergistic (and slightly alarming) existing wrinkle**: `scripts/ralph-loop.sh` — which is copied byte-for-byte into every install via `sync-templates.sh` (§3) — special-cases `appDir == "src"` to display `COMPONENT_DISPLAY_NAME="Exchange Rates Dashboard"` in banners/progress headers (verified live in the source, `scripts/ralph-loop.sh` around the `COMPONENT_NAME`/`COMPONENT_DISPLAY_NAME` block). Today this is a vestigial dogfooding leftover baked into every installed user's loop script regardless of their actual project — if their `appDir` happens to be `src` (the wizard's own default), their build banners already say "Exchange Rates Dashboard" even when building something unrelated. Adding the `example` task source turns this from a latent bug into a *correct* default for that one path, but it means: **any cleanup of that hardcoded string (to fix the pre-existing bug for `scaffold`/`existing` users) must not break the `example` path**, and conversely, shipping `example` should not be used as an excuse to leave the bug unaddressed for the other two paths.

**Story-file convention wrinkle**: the loop (`scripts/ralph-loop.sh`) writes SM-produced story specs and progress files to `docs/stories/` (`STORIES_DIR` default, confirmed in script), namespaced by `EPIC_ID` parsed from the epic's `## Epic N: Title` header (confirmed present at `docs/epics/exchange-rates-dashboard.md:67`, `## Epic 1: Exchange Rates Dashboard MVP`) — the real epic already has this header in the right format, so no changes needed there; just confirm any newly-authored `example/epic.md` template preserves the `## Epic N: Title` line, since `epic-stub-stories.md` (the current scaffold template) has **no such header at all** — only `### Story X.Y:` lines — meaning the scaffold path currently relies on a fallback ("Epic is missing a header — progress will show a generic title," per a warning line in `ralph-loop.sh`). The example source, being copied from a file that already has the header, sidesteps that scaffold-only degradation for free.