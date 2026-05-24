# Ralph Loop Demo — Agent Guidance

A self-contained demo showing how the Ralph Loop pattern orchestrates BMAD agents to build a small React app — an Exchange Rates monitoring dashboard — one story at a time.

This file gives agents working inside the loop the conventions they need. The [README](README.md) explains how a human sets the demo up and runs it; this file explains how agents should behave once it is running.

> **Two-track repo.** This file applies to Demo Track loop runs (cloners running the canonical loop at `scripts/ralph-loop.sh` against the Exchange Rates Dashboard PRD/epic at the repo root). System Track loop runs (loop-improvement work driven by `./system/ralph-loop-system.sh`) use [`system/CLAUDE.md`](system/CLAUDE.md), which overrides the stack rules below with bash/markdown rules. See the [README](README.md#two-tracks) for the architecture.

## Repo layout

- `src/` — React + Vite + TypeScript app the loop is building (Demo Track)
- `docs/` — BMAD-managed: `prd.md`, `epics/`, `stories/` (Demo Track)
- `scripts/ralph-loop.sh` — the orchestrator, with system prompts composed from external layers
- `scripts/prompts/` — externalized system prompts (execution-context, BMAD personas, stack rules)
- `_bmad/` — BMAD Method install, **core + bmm modules only**
- `system/` — System Track: loop-improvement work, organized as chapters under [`system/chapters/`](system/chapters/) (see [system/README.md](system/README.md) for the chapter convention)
- `TIMELINE.md` — chronological log of repo evolution; entries tagged `[Demo]` or `[System]`

## Stack rules

- **App stack:** React 19, Vite, TypeScript (strict). No Next.js, no SSR, no static-site frameworks.
- **Tests:** Vitest + React Testing Library. No Jest, no Cypress, no Playwright.
- **State:** React hooks; `useReducer` where it helps. No Redux, Zustand, or other state libraries unless a story explicitly requires one.
- **Styling:** CSS Modules or plain CSS. No Tailwind, no styled-components, no UI libraries — let a story add one if a design calls for it.
- **HTTP:** native `fetch`. No axios, swr, or react-query unless a story requires it.
- **Persistence:** `localStorage` only. No IndexedDB, no backend, no database.

A lean stack is a feature here. The demo is about the loop, not the app.

## Agent behavior inside the loop

> **BMAD version note.** This repo installs the latest BMAD (v6.7+), which has
> no `bmad-agent-sm`. The Ralph loop maps its roles to v6.7 skills: SM =
> `bmad-create-story`, Dev = `bmad-dev-story`, Review = `bmad-code-review`.
> The behavioral rules below still apply regardless of skill name.

**Scrum Master (`bmad-create-story`)**
- Produce exactly one detailed story spec per invocation. Never expand multiple stories in one run.
- Acceptance criteria must be observable from outside the code: "renders X", "responds to Y click", "calls endpoint Z" — not "uses pattern P" or "follows convention Q".
- Reference the PRD and parent epic, but inline the relevant section into the story spec so the Dev agent does not need to re-read those files.

**Developer (`bmad-dev-story`)**
- Implement only what the story spec asks for. No refactors of unrelated code, no "while I'm here" cleanups.
- Stick to the stack rules above. If a story seems to require something not allowed, flag it as a question in the story file rather than installing it.
- Tests live beside source files (`Component.tsx` / `Component.test.tsx`).
- Do not modify `scripts/ralph-loop.sh`, anything under `_bmad/`, the PRD, or the epic files. Those are upstream of you.

**Code Reviewer (`bmad-code-review`)**
- Pass = acceptance criteria are met *and* `cd src && npm run build && npm test` both succeed. Pass even if you would write the code differently.
- Block on: AC not met, build/test failures, security issues, stack-rule violations, or imports reaching outside `src/`.
- Style nits do not block. No requests for renames, added comments, or test re-organization.
- Surface one blocking issue per review pass. Let the Fix step land one thing before reviewing again.

## Guardrails

- **Self-contained repo.** Never reference any directory outside this repo (in particular, do not reference `../` or absolute paths into the Metis parent tree). All paths in scripts, configs, and docs are relative to this repo root.
- **BMAD modules locked.** Only `core` and `bmm` are installed. Do not install `bmb`, `cis`, `tea`, `wds`, or any other module.
- **Loop script is read-only during runs.** `scripts/ralph-loop.sh` may only be edited outside an active loop run. Inside the loop, no agent touches it.
- **Checkpoint discipline.** If a test is flaky, fix it — never disable it or weaken the checkpoint command.
- **No CI/CD work.** This is a demo. No GitHub Actions, no deploy configs.
- **No new top-level directories** unless a story explicitly requires one. The current layout is the layout.

## Definition of done (story level)

A story is done when:
1. Its acceptance criteria are demonstrable.
2. `cd src && npm run build` succeeds.
3. `cd src && npm test` succeeds (when tests exist).
4. Code Review has passed.
5. The change is committed with a message referencing the story ID.

## Logging repo evolution

Every meaningful change to this repo gets logged so the public can see how it evolved:

- **[TIMELINE.md](TIMELINE.md)** — append a reverse-chronological entry for any change worth narrating (a story landing, a refactor, a structural decision, a setup phase completing). Tag each entry `[Demo]` or `[System]`. One headline + a paragraph of what + why + commit link(s). Routine commits inside a single story don't each need an entry — group them under the story's entry.
- **[system/chapters/](system/chapters/)** — significant System Track work products (loop refactors, prompt extractions, BMAD adapter layers) live as dated chapter folders, each containing its own plan (`README.md`), PRD, epic(s), and stories. See [system/README.md](system/README.md) for the chapter convention. Plans must satisfy the cold-start test: a fresh reader can act on them with no prior context.

When a chapter completes or is superseded, leave its folder in place and mark the status in the chapter's `README.md` header — the historical record matters more than tidiness.
