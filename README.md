# Ergane

**An autonomous build loop: a GitHub issue or a PRD goes in, reviewed commits come out — one story at a time.**

Ergane drives [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) agent roles — Scrum Master, Developer, Code Reviewer — through a spec, building software story by story without a human in the chat. Each step runs in a *fresh* Claude Code session, so the model never drowns in a 200-message history. The pattern is Geoff Huntley's ["Ralph"](https://ghuntley.com/loop/); Ergane is a hardened implementation with BMAD planning, multi-model cost routing, GitHub-issue intake, and a guided installer.

> **Name.** *Ergane* (er-GAH-nee) is the epithet of *Athena Ergane*, "Athena the Worker," patroness of craftspeople. It was born inside the [Metis](https://github.com/seevali) ecosystem — and in myth Metis is Athena's mother.

This repository is two things at once: **the tool** (the loop, its prompts, its installer) and **the place the tool builds itself** — every improvement to Ergane is made by running Ergane on Ergane (see [How this repo evolves itself](#how-this-repo-evolves-itself)).

---

## What it is

Ergane is a Bash orchestrator (`scripts/ralph-loop.sh`) that turns a spec into working, reviewed code. For each story it:

1. **Scrum Master** (`bmad-create-story`) expands the story into a detailed, self-contained spec.
2. **Developer** (`bmad-dev-story`) implements exactly that spec inside your app directory.
3. **Checkpoint** — your build/test command runs to prove the code still works.
4. **Code Reviewer** (`bmad-code-review`) checks acceptance criteria and the checkpoint; a **Fix** loop sends failures back to the Developer until review passes.
5. The change is committed with a message referencing the story ID, and the loop moves to the next story.

Two ideas do the heavy lifting:

- **The Ralph pattern** — every step above is a **fresh Claude Code session** with no shared chat history. Context is reloaded from the file system (PRD, epic, story spec, code diff). Clean context per step is the whole point: the model stays sharp and prompt caching keeps the repeated context cheap. Named after [Geoff Huntley's "loop"](https://ghuntley.com/loop/).
- **BMAD Method** — role-based agents (PM, Architect, Scrum Master, Developer, Code Reviewer) from [bmad-code-org/BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD). Each has a persona, a workflow, and a defined output shape. Ergane maps the loop's roles onto BMAD skills: SM = `bmad-create-story`, Dev = `bmad-dev-story`, Review = `bmad-code-review`.

**Checkpoint discipline** is the safety contract: the loop only trusts code that passes the checkpoint command you give it, and every review step gates on that command. Flaky checkpoints confuse the reviewer — fix the flake, never weaken the command.

### Two intake paths

Ergane reads work from one of two sources:

- **Path B — an epic file (`--epic`).** You already have a PRD and an epic broken into stories. The loop executes them. This is the direct path.
- **Path A — a GitHub issue (`--issue N`).** A planning phase (**Phase 0**) turns the issue into a PRD (`docs/prd/issue-N.md`), an optional architecture note, and an epic (`docs/epics/issue-N.md`, stories namespaced `N.1`, `N.2`, …), then runs the Path B loop on it. Requires the [`gh`](https://cli.github.com/) CLI, authenticated. Add `--write` to project progress back onto the issue/PR; `--issues LIST|ready` to work a queue, one worktree + PR each.

## Install

The installer (a Node.js CLI in [`installer/`](installer/)) sets Ergane up inside any repo: it copies the loop scripts and prompts, renders a project-specific `GETTING-STARTED.md`, optionally installs BMAD, and writes a `docs/project-conventions.md` the loop injects into every agent.

### Once published (aspirational)

Ergane is **not yet on npm** (publishing is a pending manual step — see [`PUBLISHING.md`](PUBLISHING.md)). After the first publish, install will be:

```bash
# NOTE: not available until @seevali/ergane is published to npm.
npx @seevali/ergane install
```

### Today: install from a clone

Until then, clone this repo and run the installer directly:

```bash
git clone https://github.com/seevali/ergane.git
cd ergane
node installer/bin/ralph.js install --directory /path/to/your/project
```

**Want to watch it build something first?** Install the worked example — a complete, ready-to-run *Exchange Rates Dashboard* PRD + epic (six small React/Vite/TypeScript stories):

```bash
node installer/bin/ralph.js install --directory /path/to/scratch-dir --task-source example
```

That writes `docs/prd.md` + `docs/epics/exchange-rates-dashboard.md` (no TODOs to fill in) and prints the exact command to run the loop against them. This is the "install it and watch it build an app" experience — and because it travels through the real install path, it exercises exactly what a real user gets.

### Prerequisites

- **Platform:** macOS, Linux, or **WSL2 on Windows** — the loop is a Bash pipeline, so PowerShell/cmd won't work.
- **Node.js 20+** (runs the installer).
- **`claude` CLI** ([Claude Code](https://claude.com/claude-code)), authenticated with an Anthropic account that has API credit — the loop won't run without it.
- **`git`**.
- **`jq`** — JSON processor the loop uses to parse the `claude` CLI's cost output. The installer prints an OS-specific install command if it's missing.
- **`gh`** ([GitHub CLI](https://cli.github.com/)), authenticated — only for Path A (`--issue`) intake.

## Running the loop

Every run needs three flags — the loop bakes in **no defaults**, so a missing one stops immediately with a clear error (e.g. `Error: --epic is required`):

- `--project-dir DIR` — the app directory the Developer writes code inside.
- `--epic FILE` — the epic to execute (Path B). Path A derives this from `--issue` instead.
- `--checkpoint CMD` — the build/test command every review step gates on.

**Path B — execute an epic:**

```bash
bash scripts/ralph-loop.sh \
  --project-dir src \
  --prd docs/prd.md \
  --epic docs/epics/exchange-rates-dashboard.md \
  --checkpoint "cd src && npm run build && npm test --if-present"
```

(That is the exact command the example install prints. Substitute your own `--project-dir`, `--epic`, and `--checkpoint`.) Stop anytime with `Ctrl-C`; resume by re-running with the same arguments.

**Path A — plan and build from a GitHub issue:**

```bash
# Plan only — write the PRD/epic, stop before any code:
bash scripts/ralph-loop.sh --issue 42 --plan-only --project-dir src --checkpoint "cd src && npm run build && npm test --if-present"

# Plan AND build:
bash scripts/ralph-loop.sh --issue 42 --project-dir src --checkpoint "cd src && npm run build && npm test --if-present"
```

`--issue` and `--epic` are mutually exclusive (Path A derives the epic from the issue). Phase 0 is skipped on re-run if its epic already exists, so an interrupted intake resumes straight into the build.

### Useful flags

| Flag | Purpose |
|------|---------|
| `--stories 1,2,3` | Run a subset of stories instead of all |
| `--budget-per-story-usd 10` | Cap spend per story |
| `--max-budget-usd 5` | Hard cap per Claude invocation |
| `--issue N` | Path A: plan from GitHub issue N, then build |
| `--repo OWNER/NAME` | Repo to read the issue from (default: `gh repo view`) |
| `--plan-only` | Path A: run planning then stop (no code changes) |
| `--write` | Path A: project loop progress back to the issue/PR |
| `--issues LIST\|ready` | Work a queue of issues serially, one worktree + PR each; pair with [`scripts/ralph-watch.sh`](scripts/ralph-watch.sh) to watch/pause/abort jobs |

See `bash scripts/ralph-loop.sh --help` for the full list.

### How the loop routes models

```
┌──────────┐    ┌──────────┐    ┌────────────┐    ┌──────────┐
│   PRD    │ →  │   SM     │ →  │   Dev      │ →  │  Review  │
│  + Epic  │    │ (haiku)  │    │ (sonnet)   │    │  (opus)  │
└──────────┘    └──────────┘    └────────────┘    └──────────┘
                                       ↑                  │
                                       │                  ▼
                                  ┌────────┐         pass / fail
                                  │  Fix   │ ← ──────────┘
                                  └────────┘
```

Cheap model plans, mid-tier model writes, premium model reviews. Each box is a fresh session — no shared chat history.

### Watching a run

The script streams a live progress block to the terminal and writes a JSONL log per invocation to `scripts/logs/`. Open another terminal and `tail -f scripts/logs/<latest>.log` to watch the model's reasoning. Path A queue runs (`--issues`) can be monitored with [`scripts/ralph-watch.sh`](scripts/ralph-watch.sh).

## Cost expectations

A small story (~50 lines of changed code) typically runs:

- SM expansion: ~$0.02
- Dev implementation: ~$0.15
- Review: ~$0.20
- 0–2 fix passes: ~$0.10 each

Plan for **$0.50–1.50 per story** as a rough order. The six-story example lands in the low-to-mid single digits of dollars. Set `--budget-per-story-usd` or `--max-budget-usd` for a hard ceiling.

## Limitations

- The loop assumes the checkpoint command reliably tells the truth about whether code works. Flaky tests confuse the review agent.
- BMAD agents work best on greenfield or well-factored code. Wiring them into a large, tangled codebase needs a sharper `docs/project-conventions.md` and prompt customization.
- Long-running loops can drift. Watch the early stories closely; if quality looks off, fix the PRD or epic — those are the input quality control — before letting it churn for hours.

## How this repo evolves itself

Ergane is developed **by running Ergane on Ergane.** Every improvement to the loop is a **chapter** under [`system/chapters/`](system/chapters/) — a dated folder with its own plan (`README.md`), PRD, epic, and stories. [`system/ralph-loop-system.sh`](system/ralph-loop-system.sh) points the canonical loop at a chapter; the loop then drives the work like any other project. Browse the chapters to see the tool forging itself in public — including the bugs each chapter exposed and fixed.

- **[`system/`](system/)** — the lab notebook: chapters, the system-track wrapper, and design docs under [`system/design/`](system/design/).
- **[`TIMELINE.md`](TIMELINE.md)** — a reverse-chronological narration of every meaningful change.

### A note on history

From **2026-05-24 to 2026-07-07** this repo was named `ralph-loop-demo` and ran on two tracks: a clonable "Demo Track" showcase (a React app skeleton under `src/` plus the Exchange Rates Dashboard PRD/epic at the root) and a "System Track" for loop-improvement work. On **2026-07-07** the demo was retired: it had never actually been run, and the same "watch it build an app" experience is now delivered better through the installer's `--task-source example` (above), because it travels the real install path. The repo was renamed **Ergane** and is now single-track — the tool and its self-development in one place. The full rationale lives in the [single-track chapter](system/chapters/2026-07-07-single-track/README.md); the two-track era itself is narrated in the blog post [*Watching the Loop Forge Itself*](https://seevali.dev/builds/watching-the-loop-forge-itself/) (2026-05-25), which stands as a record of that period. Historical `TIMELINE.md` entries keep their `[Demo]`/`[System]` tags for the same reason.

## Credits

- **Ralph pattern** — [Geoff Huntley's "loop" post](https://ghuntley.com/loop/). Drive coding agents through fresh-context iteration cycles instead of one long conversation.
- **This loop's implementation** — adapted from [Seevali Rathnayake](https://seevali.dev)'s production Ralph scripts.
- **BMAD Method** — by [bmad-code-org](https://github.com/bmad-code-org/BMAD-METHOD).
- **Claude Code** — by [Anthropic](https://claude.com/claude-code).

## License

MIT — see [LICENSE](LICENSE).
