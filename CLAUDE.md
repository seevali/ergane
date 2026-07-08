# Ergane — Agent Guidance

This repo **is** the loop. [Ergane](README.md) is an autonomous build loop (`scripts/ralph-loop.sh`) that drives BMAD agent roles — Scrum Master → Developer → Code Reviewer → Fix — through a spec, one story at a time, each step a fresh Claude Code session. It ships as a Node.js installer that sets the loop up inside any repo. This file is the auto-loaded guidance for any agent working **inside this repo** — whether the loop is improving itself (a chapter under [`system/chapters/`](system/chapters/)) or you are editing the loop by hand.

The [README](README.md) explains how a human installs and runs Ergane. This file explains how agents should behave when working on Ergane itself.

## Repo layout

- `scripts/ralph-loop.sh` — the orchestrator. System prompts are composed from external layers.
- `scripts/prompts/` — externalized system prompts (execution-context overrides, BMAD personas, stack overlay). See [`scripts/prompts/README.md`](scripts/prompts/README.md) for the composition model.
- `scripts/ralph-watch.sh` — monitor/pause/abort for Path A `--issues` queue runs.
- `docs/` — the loop's planning-output surface: Path A writes `docs/prd/issue-N/`, `docs/epics/issue-N.md`, etc. here. Also holds **`docs/project-conventions.md`** — this repo's own conventions file, injected into every loop agent (see below).
- `system/` — where Ergane's own evolution happens: improvement work organized as dated chapters under [`system/chapters/`](system/chapters/) (see [`system/README.md`](system/README.md) for the chapter convention), the [`ralph-loop-system.sh`](system/ralph-loop-system.sh) wrapper, and design docs under [`system/design/`](system/design/).
- `installer/` — Node.js CLI package for the guided installer.
- `tools/` — typed (TypeScript/Node) helper modules the Bash loop shells out to (e.g. the manifest/reconciliation reconciler).
- `_bmad/`, `.claude/skills/` — BMAD Method install (**core + bmm modules only**); gitignored install products.
- `TIMELINE.md` — chronological log of repo evolution.

## Stack rules

- **Languages:** Bash (the loop and its wrappers) and Markdown (prompt files, plans, docs). No language switches — no Python, Go, Rust, etc. **Node.js / TypeScript is permitted strictly inside two directories: `installer/`** (the guided-installer CLI package) **and `tools/`** (typed helper modules the loop shells out to — e.g. the manifest/reconciliation reconciler; see [`system/design/issue-native-bmad-loop.md`](system/design/issue-native-bmad-loop.md) §8). Everything outside `installer/` and `tools/` is Bash + Markdown only.
- **Bash style:** `set -euo pipefail` is mandatory in any new script. Always quote variable expansions. Prefer `[[ ]]` over `[ ]`. Bash 4+ assumed; POSIX-compat is not a goal.
- **Markdown style:** prompt files under `scripts/prompts/` carry no YAML frontmatter unless the loader parses it. Use `{{PLACEHOLDER}}` (double-brace) for templated values — never bash `${}` interpolation inside Markdown.
- **Tests:** validate shell scripts with `bash -n <script>` (syntax) and any dry-run mode they provide (`--dry-run-prompts`). The installer package: `cd installer && npm test`. Add a dry-run mode rather than mocking when a script needs unit-test-like verification.

> **`docs/project-conventions.md` is the loop's live conventions file.** `scripts/ralph-loop.sh` injects it (Layer 3a) into every agent's system prompt, falling back to `scripts/prompts/common/project-conventions.md` only if it is absent. It carries the same stack rules as this section. **Keep the two consistent** — if you change the stack rules here, mirror them in `docs/project-conventions.md`.

## Agent behavior inside the loop

> **BMAD version note.** This repo installs the latest BMAD (v6.7+), which has no `bmad-agent-sm`. The loop maps its roles to v6.7 skills: SM = `bmad-create-story`, Dev = `bmad-dev-story`, Review = `bmad-code-review`. The behavioral rules below apply regardless of skill name.

Loop runs against this repo are almost always **chapter** work under [`system/chapters/`](system/chapters/), driven by [`system/ralph-loop-system.sh`](system/ralph-loop-system.sh). A chapter's PRD describes an improvement; its epic breaks it into stories; the loop drives the work. The work surface is the whole repo, not a sub-folder.

**Scrum Master (`bmad-create-story`)**
- Produce exactly one detailed story spec per invocation. Never expand multiple stories in one run.
- Acceptance criteria must be observable from outside the code ("running X produces output Y", "the script exits non-zero when Z") — not "uses pattern P" or "follows convention Q".
- Reference the PRD and parent epic, but inline the relevant section into the story spec so the Dev agent does not need to re-read those files.
- Stories are written to the **chapter's** `stories/` directory, not to `docs/stories/`. Keep them small: if a story would touch more than ~3 files or ~150 lines, split it.

**Developer (`bmad-dev-story`)**
- Implement only what the story spec asks for. No refactors of unrelated code, no "while I'm here" cleanups.
- Stick to the stack rules above. If a story seems to require something not allowed, flag it as a question in the story file rather than installing it.
- The work surface is the whole repo — you may modify `scripts/`, `system/`, `installer/`, `tools/`, root docs (`README.md`, `CLAUDE.md`, `TIMELINE.md`), and BMAD config.
- Do **not** modify `scripts/ralph-loop.sh` while the loop is running (see guardrails). When editing it outside a run, preserve byte-for-byte the multi-model routing, retry logic, smart-salvage, upstream-fix detection, budget caps, and `run_claude()` signature — these are the loop's safety contract.

**Code Reviewer (`bmad-code-review`)**
- Pass = acceptance criteria are met *and* the checkpoint command succeeds. Pass even if you would write the code differently.
- **Hard block** on: AC not met; a change that fails `bash -n ./scripts/ralph-loop.sh && bash -n ./system/ralph-loop-system.sh`; a change to the safety-contract sections of `scripts/ralph-loop.sh`; `cd installer && npm test` failing; `installer/scripts/sync-templates.sh --check` failing; a change that breaks `bash scripts/ralph-loop.sh --dry-run-prompts`; security issues; stack-rule violations.
- Style nits do not block. No requests for renames, added comments, or test re-organization.
- Surface one blocking issue per review pass. Let the Fix step land one thing before reviewing again.

## Guardrails

- **Self-contained repo.** Never reference any directory outside this repo (in particular, no `../` and no absolute paths into a parent tree). All paths in scripts, configs, and docs are relative to the repo root.
- **BMAD modules locked.** Only `core` and `bmm` are installed. Do not install `bmb`, `cis`, `tea`, `wds`, or any other module.
- **Loop script is read-only during runs.** `scripts/ralph-loop.sh` may only be edited outside an active loop run. Inside the loop, no agent touches it.
- **Checkpoint discipline.** If a test is flaky, fix it — never disable it or weaken the checkpoint command.
- **No CI/CD work.** This is a self-contained tool repo. No GitHub Actions, no deploy configs.
- **No new top-level directories** unless a story explicitly requires one. The current layout is the layout. **Exceptions already granted:** `installer/` and `tools/`.

## Definition of done (story level)

A story is done when:
1. Its acceptance criteria are demonstrable (often: "running X command produces output Y").
2. `bash -n ./scripts/ralph-loop.sh && bash -n ./system/ralph-loop-system.sh` passes.
3. Any chapter-specific test gate passes (`--dry-run-prompts` byte-diff, installer suite, `sync-templates.sh --check`, chapter smokes).
4. Code Review has passed.
5. The change is committed with a message referencing the story ID and chapter slug.

## Logging repo evolution

Every meaningful change to this repo gets logged so the public can see how it evolved:

- **[TIMELINE.md](TIMELINE.md)** — append a reverse-chronological entry for any change worth narrating (a story landing, a refactor, a structural decision, a chapter closing). One headline + a paragraph of what + why + commit link(s). New entries are **untagged** — the repo is single-track. (Historical entries carry `[Demo]`/`[System]` tags from the two-track era, 2026-05-24 to 2026-07-07; leave them as-is.) Routine commits inside a single story don't each need an entry — group them under the story's entry.
- **[system/chapters/](system/chapters/)** — significant work products (loop refactors, prompt extractions, installer chapters, BMAD adapter layers) live as dated chapter folders, each with its own plan (`README.md`), PRD, epic(s), and stories. See [system/README.md](system/README.md) for the convention. Plans must satisfy the cold-start test: a fresh reader (any LLM, no prior context) can act on them from the file alone.

When a chapter completes or is superseded, leave its folder in place and mark the status in the chapter's `README.md` header — the historical record matters more than tidiness.
