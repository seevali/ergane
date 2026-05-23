# Ralph Loop Demo — Agent Guidance

A self-contained demo showing how the Ralph Loop pattern orchestrates BMAD agents to build a small React app — an Exchange Rates monitoring dashboard — one story at a time.

This file gives agents working inside the loop the conventions they need. The [README](README.md) explains how a human sets the demo up and runs it; this file explains how agents should behave once it is running.

## Repo layout

- `src/` — React + Vite + TypeScript app the loop is building
- `docs/` — BMAD-managed: `prd.md`, `epics/`, `stories/`
- `scripts/ralph-loop.sh` — the orchestrator
- `_bmad/` — BMAD Method install, **core + bmm modules only**

## Stack rules

- **App stack:** React 19, Vite, TypeScript (strict). No Next.js, no SSR, no static-site frameworks.
- **Tests:** Vitest + React Testing Library. No Jest, no Cypress, no Playwright.
- **State:** React hooks; `useReducer` where it helps. No Redux, Zustand, or other state libraries unless a story explicitly requires one.
- **Styling:** CSS Modules or plain CSS. No Tailwind, no styled-components, no UI libraries — let a story add one if a design calls for it.
- **HTTP:** native `fetch`. No axios, swr, or react-query unless a story requires it.
- **Persistence:** `localStorage` only. No IndexedDB, no backend, no database.

A lean stack is a feature here. The demo is about the loop, not the app.

## Agent behavior inside the loop

**Scrum Master (`bmad-agent-sm`)**
- Produce exactly one detailed story spec per invocation. Never expand multiple stories in one run.
- Acceptance criteria must be observable from outside the code: "renders X", "responds to Y click", "calls endpoint Z" — not "uses pattern P" or "follows convention Q".
- Reference the PRD and parent epic, but inline the relevant section into the story spec so the Dev agent does not need to re-read those files.

**Developer (`bmad-agent-dev`)**
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
