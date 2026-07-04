# Chapter: Installer UX Refresh & Freshness

**Status:** **Built — both slices shipped 2026-07-04** (slice 1: freshness + first-run UX, commit `daa4eab`; slice 2: lifecycle correctness L1–L11, commit `661ca64`). Installer tests: 227 (1 red) → **288/288**; the `sync-templates.sh --check` hard-block gate is green. Open: publish `@seevali/ralph-loop@0.2.0` to npm (a human release decision), and the known CLI-contract gap that non-interactive `--task-source existing` has no `--task-source-path` flag (recorded, deliberately out of scope).
**Work surface:** `installer/**` only (the Node CLI package; the Node exception to the System Track bash-only rule was granted by Story 1.1 of the [2026-06-13 installer chapter](../2026-06-13-ralph-loop-installer/)).
**Builds on:** the completed [Ralph Loop Guided Installer chapter (2026-06-13)](../2026-06-13-ralph-loop-installer/) and the just-completed [GitHub Issue Round-Trip chapter (2026-06-25)](../2026-06-25-github-issue-roundtrip/) — whose new loop features are exactly what the installer no longer reflects.

> **Cold-start note.** The "installer" is the npm package at `installer/` (`@seevali/ralph-loop`,
> Node ≥ 20): a guided wizard (`npx @seevali/ralph-loop install`) that scaffolds the Ralph
> Loop — `scripts/ralph-loop.sh`, prompt layers, doc stubs — into a user's project, plus
> `doctor`/`update`/`uninstall` lifecycle commands. Its `templates/loop/` holds SYNCED COPIES
> of the repo's loop scripts, kept honest by `installer/scripts/sync-templates.sh --check`,
> a repo-wide hard-block gate (`system/CLAUDE.md`). "The loop" and its 2026-07-04 features
> (`--issue`, `--write`, `--triage`, `--worktree`, `--issues`, `scripts/ralph-watch.sh`) are
> documented in the round-trip chapter and `TIMELINE.md`.

## Why this chapter exists

Two forces converged on 2026-07-04:

1. **Freshness debt, measurable.** The round-trip chapter changed `scripts/ralph-loop.sh` substantially and added a second script (`ralph-watch.sh`). The installer's synced template went stale — `sync-templates.sh --check` (a hard-block gate) began failing, and 1 of 227 installer tests (the drift-gate e2e) turned red. Worse than the drift itself: an installed project would get a loop advertising swarm/brake features whose companion script (`ralph-watch.sh`) the installer never ships.
2. **The owner asked for intuition.** Beyond freshness, the standing request (Seevali, 2026-07-04): *"Improve the installation process, making it an intuitive experience for the users."*

## Method — audit first, then build (same orchestration as the round-trip chapter)

A four-lens, read-only **UX audit fan-out** ran the real CLI in throwaway sandboxes before any code was written (method precedent: `../2026-06-25-github-issue-roundtrip/BUILD-JOURNAL.md`):

| Lens | What it did |
|---|---|
| **fresh-user** | Non-interactive install into an empty dir; followed the outro + GETTING-STARTED literally to the first loop run; audited wizard copy from source. |
| **lifecycle** | Install over an existing project; re-install, `update`, `doctor` (healthy + deliberately broken), `uninstall`. |
| **error-edge** | Preflight failures, invalid flags, interrupted installs, never-installed dirs, manual-install collisions. |
| **docs-copy** | Every user-facing string + doc read as a total newcomer; jargon hunt; verified every documented command parses. |

**Result: 34 findings — 5 blockers, 11 major — and 27 recorded delights (strengths the fixes must not regress).** Full evidence with verbatim repro output: [`ux-audit-findings.json`](ux-audit-findings.json) (lens order: fresh-user, lifecycle, error-edge, docs-copy).

### The headline findings (why users found it unintuitive)

- **The first success moment errors.** After a clean install, the outro's own "next command" dies (`Project directory not found: …/src` — the configured app dir is never created; the loop's default PRD/epic paths point at files the scaffold didn't write). Steps 3–5 reference nonexistent files. Nothing says "author your PRD before looping."
- **`npx <package>` ships literally.** Every update/doctor instruction contains the unsubstituted placeholder `<package>` — the entire lifecycle story is un-runnable as printed.
- **Lifecycle data loss:** non-interactive `uninstall` crashes mid-delete; `update` silently replaces the user's stack/checkpoint/app-dir config with wizard defaults.
- **BMAD failure theater:** the BMAD step fails for everyone (bmad-method dropped `--artifact-folder`), the banner still says "✓ installed successfully!", and the printed remediation repeats the exact broken flag.
- **Money is never mentioned.** No copy warns the loop makes paid API calls; installed defaults are uncapped (50 iterations, empty budget caps).
- **Docs drift:** GETTING-STARTED describes a wizard the loop doesn't have and tuning variables that don't exist; none of the new round-trip capabilities are taught.

## The plan — two slices, same build pipeline as the round-trip chapter

Each slice: orchestrator-authored spec → implementer agent → two parallel adversarial reviewers (contract auditor + edge-case hunter, spec-driven/language-agnostic) → fixer → orchestrator re-verification → one commit. Gates per slice: full `installer` npm test suite, `sync-templates.sh --check`, `node --check`/`bash -n` on touched files, spot-check that repo smokes stayed green.

1. **Slice 1 — Freshness + first-run experience:** widen `sync-templates.sh` to also sync `ralph-watch.sh` and resync; scaffold + doctor + update + uninstall coverage for the new script; GETTING-STARTED rewritten truthfully for BOTH workflows (epic-file quick start + a newcomer-grade "Working from GitHub issues" section, with explicit token-cost notes); kill the `<package>` placeholder; make the outro's next-steps an honest ordered path (cd → author the PRD → run the loop → where progress appears); cost warnings + budget knobs; jargon defined at first use; version → 0.2.0.
2. **Slice 2 — Lifecycle correctness (L1–L11):** uninstall crash/atomicity; update preserves user config; one shared manifest loader with honest errors; BMAD flag-probing + qualified banner + copy-pasteable remediation; existing-project installs without `--force` scare tactics; doctor distinguishes ralph-owned drift (FAIL + remediation) from user-customized files (INFO); "Already up to date"; CLI-flag-named validation errors; preflight writable/git-identity/gh checks; bare `ralph` → help on stdout exit 0; nested/orphaned install guards.

## Outcomes

**Slice 1 — landed 2026-07-04.** Installer tests 227 (1 failing) → **244/244 green**; `sync-templates.sh --check` green again with the widened three-target set (loop, watch, prompts — now including the round-trip-era planning prompt layers). A fresh `install --yes` now yields: created app dir, executable `ralph-watch.sh` whose `ls` runs, an outro whose every step is runnable in order (cd → author the scaffolded PRD/epic by name → run the loop against the files that actually exist → where progress will appear), real `npx @seevali/ralph-loop …` commands everywhere, a calm cost note with the budget knobs, and a GETTING-STARTED that teaches both the epic-file quick start and the GitHub-issue workflow truthfully (with a doc-anti-drift test grepping the guide's variable names against the shipped template script). Verification catches, all fixed pre-commit: the `{{PACKAGE_NAME}}` substitution rendered a bare un-runnable `@seevali/ralph-loop doctor` (no `npx`) — regression caught by the contract auditor; the mandatory outro pointer to the issue-workflow section had been dropped; existing-mode outro pointed at a phantom epic file. *(Orchestration note: the contract auditor also flagged this very chapter folder as a work-surface breach and the fixer deleted it — correctly, per the letter of its spec; the orchestrator restored it. Reviewers enforcing the contract against their own paymaster's files is the system working.)*

**Slice 2 — landed 2026-07-04 (commit `661ca64`).** All eleven lifecycle items (L1–L11) shipped: uninstall no longer crashes or half-deletes (manifest removed last, so an interrupted uninstall re-runs cleanly; a new `createdDirs` manifest field means only installer-created directories are pruned — a verification catch upgraded this from "prune any empty dir in a manifest path"); update preserves every user-configured value (the manifest is now the wizard-defaults source) and says "Already up to date" on a no-op; one shared manifest loader gives corrupt/missing-manifest states a single honest error across all four subcommands; the BMAD step probes the resolved bmad-method's own `--help` before composing flags, degrades the banner honestly on failure, and prints a remediation identical to the command actually attempted; `.gitignore` no longer hard-fails real-project installs; doctor distinguishes customized user-editable files (INFO) from ralph-owned drift (FAIL, each with a remediation command); validation errors speak in CLI flag names; preflight checks writable-target/git-identity/gh before the wizard runs; bare `ralph` prints help to stdout with exit 0; nested and orphaned installs are detected and explained. Tests 246 → **288/288** plus 7 manual end-to-end CLI smokes. Verification findings this round: 3 minor (missing remediation on two doctor FAILs; the directory-pruning contract violation, found independently by both reviewers) — all fixed with regression tests, none rejected.

## Cumulative outcome

From the audit's 34 findings: **all 5 blockers and all 11 majors are fixed**, plus the high-value minors; the remaining polish items are folded into the shipped rewrites or recorded above as open. The end-to-end newcomer path now holds: `npx @seevali/ralph-loop install` → preflight that checks the ground first → a wizard/`--yes` plan that defines its jargon and names its costs → a scaffold whose outro steps all actually run → a GETTING-STARTED that teaches both the epic-file and GitHub-issue workflows truthfully → lifecycle commands (`doctor`/`update`/`uninstall`) that are runnable as printed, honest about state, and safe to interrupt.
