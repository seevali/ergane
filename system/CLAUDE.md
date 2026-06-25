# System Track — Agent Guidance

This file applies when the loop runs via [`ralph-loop-system.sh`](ralph-loop-system.sh) against a chapter under [`chapters/`](chapters/). It complements the root [`CLAUDE.md`](../CLAUDE.md) — the root file's loop semantics, repo-wide guardrails, and definition-of-done still apply. This file overrides the root file's React/Vite-oriented stack rules with system-track-specific rules.

## What System Track work looks like

Each chapter under [`chapters/`](chapters/) is a focused improvement to the loop infrastructure: refactors of `scripts/ralph-loop.sh`, externalizations of prompt content, adapter layers for new BMAD versions, etc. The chapter's PRD describes the improvement; epics break it into stories; the loop drives the work. The work surface is the whole repo, not a sub-folder.

## Stack rules (override the root CLAUDE.md React rules)

- **Languages:** Bash (the loop) and Markdown (prompt files, plans, docs). No language switches — no Python, Node, Go, Rust, etc., **except Node.js / TypeScript is permitted strictly inside two directories: `installer/`** (the guided installer package; see Story 1.1) **and `tools/`** (typed helper modules the loop shells out to — e.g. the manifest/reconciliation reconciler; see [`design/issue-native-bmad-loop.md`](design/issue-native-bmad-loop.md) §8). Everything outside `installer/` and `tools/` remains Bash + Markdown only.
- **Bash style:** `set -euo pipefail` is mandatory in any new script. Always quote variable expansions. Prefer `[[ ]]` over `[ ]`. Bash 4+ assumed; POSIX-compat is not a goal.
- **Markdown style:** prompt files (under `scripts/prompts/`, after the modularization chapter lands) must be free of YAML frontmatter unless the loader explicitly parses it. Use `{{PLACEHOLDER}}` (double-brace) for templated values — never bash `${}` interpolation inside MD files.
- **Tests:** for shell scripts, validate with `bash -n <script>` (syntax) and dry-run modes where they exist. Add a dry-run mode rather than mocking when a script needs unit-test-like verification.

## Agent behavior (additions to the root CLAUDE.md rules)

The SM / Dev / Review behavioral rules in the root [`CLAUDE.md`](../CLAUDE.md) apply unchanged. The following are *additions* specific to system-track work.

**Scrum Master**
- System Track stories tend to be smaller than demo stories — a story is usually one extracted file, one wrapper function, or one config block. If a story spec would touch more than ~3 files or ~150 lines, split it.
- Stories are written to the chapter's `stories/` directory, not to `docs/stories/`.

**Developer**
- The work surface is the whole repo. You may modify `scripts/`, `system/`, root docs (`README.md`, `CLAUDE.md`, `TIMELINE.md`), and BMAD config.
- You may **NOT** modify anything under `docs/` or `src/` — those are Demo Track artifacts and are frozen.
- When modifying `scripts/ralph-loop.sh` (the loop modifying itself), preserve byte-for-byte the multi-model routing, retry logic, smart-salvage, upstream-fix detection, budget caps, and `run_claude()` invocation signature. These are the loop's safety contract.

**Code Reviewer**
- **Hard block:** any change that fails `bash -n ./scripts/ralph-loop.sh && bash -n ./system/ralph-loop-system.sh` (script syntax).
- **Hard block:** changes to anything under `docs/`, `src/`, or to the loop-semantic sections of `scripts/ralph-loop.sh` (multi-model routing, retry, budget caps, `run_claude()` signature).
- **Hard block:** `cd installer && npm test` does not pass (when the installer stories land).
- **Hard block:** `installer/scripts/sync-templates.sh --check` does not pass (when the sync-templates script exists).
- After the modularization chapter lands `--dry-run-prompts`: hard-block on any change that fails `./scripts/ralph-loop.sh --dry-run-prompts`.
- Style nits don't block (same rule as root CLAUDE.md).

## Definition of done (System Track story level)

A System Track story is done when:

1. Its acceptance criteria are demonstrable (often: "running X command produces output Y").
2. `bash -n ./scripts/ralph-loop.sh && bash -n ./system/ralph-loop-system.sh` passes.
3. Any chapter-specific test gate (`--dry-run-prompts` byte-diff, etc.) passes.
4. Code Review has passed.
5. The change is committed with a message referencing the story ID and chapter slug.

## Logging chapter progress

Every closed chapter gets a `[System]`-tagged entry in the root [`TIMELINE.md`](../TIMELINE.md). The entry summarizes the chapter's outcome, links to the chapter folder, and notes any follow-up chapters it spawned.
