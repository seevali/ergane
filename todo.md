> **Historical document (frozen).** This is the original setup log for the demo repository, completed 2026-05-24. The Demo Track it describes (the Exchange Rates Dashboard under `src/`, the root `docs/prd.md`/epic) was **retired on 2026-07-07** when the repo was renamed Ergane and went single-track — see the [single-track chapter](system/chapters/2026-07-07-single-track/README.md). Kept as a record; nothing below is current.

# Preparing a Demo Repository to Showcase Ralph Loop + BMAD Agents

This demo repo will live as its own GitHub repository, so everything must be self-contained — do not depend on the parent Metis `_bmad/` install or anything outside this folder.

> ## ✅ Status — all 6 tasks complete (2026-05-24)
>
> **Primary Setup:** (1) BMAD core+bmm installed via `npx bmad-method install` (v6.7.1); `_bmad/` and `.claude/skills/` are gitignored install products. (2) Vite React-TS app scaffolded in `src/` with Vitest + RTL test infra and TS strict mode. (3) `scripts/ralph-loop.sh` copied from `ralph-affiant-v2.sh`.
>
> **Demo Prep:** (1) PRD at `docs/prd.md` (Exchange Rates Dashboard, Frankfurter keyless API, inline-SVG chart). (2) One epic + six small stories at `docs/epics/exchange-rates-dashboard.md`. (3) Loop script adapted to React/Vite/TS with baked-in defaults; loop semantics, model routing, retry, and budget caps left untouched.
>
> **Decisions made autonomously** (documented in commits): latest BMAD v6.7 has no `bmad-agent-sm` → roles map to `bmad-create-story` / `bmad-dev-story` / `bmad-code-review`; Rates API = Frankfurter (`api.frankfurter.dev/v1`) instead of the keyed exchangerate.host.
>
> **No TODOs left blocked.** **Next step:** run `./scripts/ralph-loop.sh` (or with explicit flags) to build the dashboard story-by-story — a separate, billed trigger, intentionally not run here.

## Tasks

### Primary Setup

1. Install BMAD Method into this repo (fresh, self-contained install — not the Metis root install). Use the official installer from https://github.com/bmad-code-org/BMAD-METHOD. Install only the minimum modules needed for the demo:
   - `core` (required base)
   - `bmm` (provides the Analyst, PM, SM, Dev, and Code Review agents)
   Skip `bmb`, `cis`, `tea`, `wds`. Configure BMAD's output/document root to this repo's `docs/` folder.
2. Set up a minimal React + Vite + TypeScript web app inside `src/` so the loop has something to build against. Keep dependencies lean — no UI library yet; let the Dev agent introduce one if a story calls for it.
3. Copy `/home/seevali/projects/affiant-dev/affiant/scripts/ralph-affiant-v2.sh` into `scripts/ralph-loop.sh` in this repo (it is tooling, not source — belongs in `scripts/`, not `src/`).

### Demo Prep

1. Create the PRD for the web app — an Exchange Rates monitoring dashboard — using the BMAD PM agent. Output to `docs/planning-artifacts/` (or whatever path the BMAD install configures).
2. Create the Epics + Stories index from the PRD using the BMAD analyst/PM workflow. This is the input the SM agent will expand into per-story specs during the loop. Confirm the epic file path so step 3 can reference it.
3. Adapt `scripts/ralph-loop.sh` to this repo:
   - Replace Affiant-specific defaults (project dir, PRD path, architecture path, .NET-specific system prompts) with values for this demo (React/Vite/TS conventions, demo `src/`, the PRD path from Demo Prep step 1, the epic file path from step 2).
   - Verify the script's `--project-dir`, `--epic`, `--prd`, and `--checkpoint` flags resolve to real paths in this repo.
   - Sanity-check that the SM → Dev → Code Review → Fix cycle still maps cleanly to the BMAD agents installed in Primary Setup step 1 (SM = `bmad-agent-sm`, Dev = `bmad-agent-dev`, Review = `bmad-code-review`).

## Goals

- Demonstrate the Ralph Loop + BMAD Agents working together end-to-end on a small but real React app build.
- Self-contained repo — anyone can clone, install BMAD, run the loop, and watch an Exchange Rates dashboard get built story-by-story.
