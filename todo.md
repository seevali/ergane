# Preparing a Demo Repository to Showcase Ralph Loop + BMAD Agents

This demo repo will live as its own GitHub repository, so everything must be self-contained — do not depend on the parent Metis `_bmad/` install or anything outside this folder.

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
