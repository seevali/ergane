## Project Conventions (React / Vite / TypeScript)

- Stack: React 19 + Vite + TypeScript (`strict` on) in `src/`. Do not introduce Next.js, SSR, or any other framework.
- Function components and hooks only. No class components. Reach for `useReducer` only where it genuinely simplifies state.
- TypeScript strict mode: no `any` to silence the compiler, no `@ts-ignore`/`@ts-expect-error` to hide a real type error, no non-null `!` to paper over a possibly-undefined value. Fix the type, do not suppress it. A `tsc` error is a build break.
- Lean stack — this is a deliberate constraint. Do NOT add a dependency to `src/package.json` (UI kit, charting lib, state lib, axios/swr/react-query, etc.) unless the story spec explicitly requires it. Use what's there: native `fetch` for HTTP, React hooks for state, plain CSS or CSS Modules for styling, inline SVG for charts.
- Data fetching with native `fetch`. Handle loading and error states explicitly; do not swallow rejected promises.
- Persistence is `localStorage` only. No IndexedDB, no backend, no database. Guard `JSON.parse` of stored values against malformed data.
- Tests: Vitest + React Testing Library, colocated as `Component.test.tsx` beside `Component.tsx`. Prefer behavior-level assertions (what the user sees / what endpoint is called) over implementation detail.
- Keep imports inside `src/`. Do not reach outside the app directory.

## Scope Discipline

- Implement only what the current story spec asks for. No refactors of unrelated code, no "while I'm here" cleanups, no speculative abstractions.
- If a story seems to require something the stack rules forbid (e.g. a new library), flag it as a question in your output rather than silently installing it.
- Acceptance criteria are the contract. Make them demonstrable; do not gold-plate beyond them.

## Checkpoint Command

The project checkpoint command is: {{CHECKPOINT_CMD}}

Run this from the repo root to verify the app builds and tests pass.
