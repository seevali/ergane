# Ralph Loop + BMAD Agents — Demo

> As discussed in [Hardening the Ralph Loop](https://seevali.dev/builds/hardening-the-ralph-loop/) on the blog — this is the live, runnable companion to the post.

A self-contained demo showing the **Ralph Loop** pattern orchestrating **BMAD Method agents** to build a small React app — an **Exchange Rates monitoring dashboard** — story-by-story, autonomously, with one command.

The loop runs overnight (or for an hour, or until you stop it) and produces a working app driven by a PRD and an epics/stories plan.

## Quick Start

### Prerequisites

- **Node.js 20+** (the installer runs via `npx`)
- **`claude` CLI** ([install](https://github.com/anthropics/claude-code)) — the installer warns if missing, but your loop won't run without it.
- **Git** (optional but recommended — the installer can initialize a repo)
- **`jq`** (optional — the installer provides OS-specific install commands if it's missing)

### Install in 5 minutes

```bash
npx <package> install
```

That's it. The installer asks about your project, scaffolds the loop, and walks you through customization. For non-interactive use (CI/scripts):

```bash
npx <package> install --yes
```

**Next:** The installer generates `GETTING-STARTED.md` with your project-specific next steps. Start reading there.

### Why this approach?

The Ralph Loop is powerful but requires careful setup: choosing a stack, writing the initial PRD and epic stubs, customizing system prompts, installing BMAD. The installer automates this, enforces best practices, and is designed to run on every update without losing your work. See the [repo layout](#repo-layout) and [how the loop works](#how-the-loop-works) sections below for what gets installed.

## What is this?

Two ideas, combined:

- **The Ralph Loop** — a build pattern where each step of work (plan a story → implement it → review it → fix it) runs in a *fresh* Claude Code session. Clean context per step is the whole point: the model never gets confused by a 200-message history, and prompt caching makes the repeated context cheap.
- **BMAD Method agents** — a set of role-based AI agents (Analyst, PM, Scrum Master, Dev, Code Reviewer) from [bmad-code-org/BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD). Each agent has a persona, a workflow, and a defined output shape.

The demo wires them together. The Ralph script picks the next story, hands it to the SM agent to expand into a detailed spec, hands that to the Dev agent to implement, hands the diff to the Code Review agent, loops fixes back to Dev until review passes, commits, and moves on.

## What gets built

An Exchange Rates dashboard — a small React + Vite + TypeScript web app — defined by a PRD at `docs/` and broken into epics and stories the loop works through one at a time.

The point isn't the app. The point is watching agents collaborate to build it.

## Repo layout

```
.
├── docs/         # PRD, epics, stories — the BMAD agents' working artifacts
├── scripts/      # ralph-loop.sh — the orchestrator
│   └── prompts/  # externalized system prompts (3-layer composition)
├── src/          # the React app being built
├── installer/    # guided installer CLI (Node.js package; System Track)
├── _bmad/        # BMAD Method install (created during setup; self-contained)
├── system/       # how the loop itself is improved — see "Two Tracks" below
└── TIMELINE.md   # chronological log of how this repo has evolved
```

**System prompts & customization:** The loop composes system prompts from three layers: (1) execution-context overrides that ensure the loop runs non-interactively, (2) live-loaded BMAD persona files from `.claude/skills/`, and (3) stack-specific demo rules (React/TypeScript conventions, review standards). Files for layers 1 and 3 live in `scripts/prompts/` — if you fork this demo for a different stack, customize the prompts there rather than editing the loop script. See [`scripts/prompts/README.md`](scripts/prompts/README.md) for the full composition model and how to extend it.

## Running the loop

These flags are the script's built-in defaults, so a bare `./scripts/ralph-loop.sh` does the same thing. Spelled out:

```bash
./scripts/ralph-loop.sh \
  --project-dir src \
  --prd docs/prd.md \
  --epic docs/epics/exchange-rates-dashboard.md \
  --stories all \
  --checkpoint "cd src && npm run build && npm test --if-present"
```

The script runs one story at a time: SM → Dev → Review → (Fix loop) → commit. Stop it anytime with `Ctrl-C`; resume by re-running with the same arguments.

### Two execution paths

The loop has two paths, selected by whether you pass `--issue`:

- **Path B — execute (default).** Build from an epic that already exists — the
  command above. This is what the demo runs.
- **Path A — intake (`--issue N`).** Start from a single GitHub issue. A planning
  phase (**Phase 0**) turns the issue into a PRD (`docs/prd/issue-N.md`), an
  optional architecture note (`docs/architecture/issue-N.md`), and an epic
  (`docs/epics/issue-N.md`, with stories namespaced `N.1`, `N.2`, …), then runs
  the Path B loop on it. Requires the [`gh`](https://cli.github.com/) CLI,
  authenticated.

```bash
# Path A — plan AND build from issue 42:
./scripts/ralph-loop.sh --issue 42 --repo owner/name \
  --checkpoint "cd src && npm run build && npm test --if-present"

# Path A — plan only, stop before any code (review the PRD/epic first):
./scripts/ralph-loop.sh --issue 42 --plan-only
```

`--issue` and `--epic` are mutually exclusive (Path A derives the epic from the
issue). Phase 0 is skipped on re-run if its epic already exists, so an
interrupted intake resumes straight into the build. Planning models default to
opus (PRD/architecture) and sonnet (story breakdown); override with `--model-pm`,
`--model-architect`, `--model-planner`. The architecture step is gated by
`--architecture auto|always|never` (default `auto`).

### Useful flags

| Flag | Purpose |
|------|---------|
| `--stories 1,2,3` | Run a subset of stories instead of all |
| `--max-budget-usd 5` | Hard cap per Claude invocation |
| `--tag <name>` | Tag log files for this run |
| `--issue N` | Path A: plan from GitHub issue N, then build |
| `--repo OWNER/NAME` | Repo to read the issue from (default: `gh repo view`) |
| `--plan-only` | Path A: run planning then stop (no code changes) |

See `./scripts/ralph-loop.sh --help` for the full list.

## How the loop works

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

Each box is a **fresh Claude Code session** — no shared chat history. Context the next session needs is loaded from the file system (PRD, epic, story spec, code diff). That's the Ralph insight: scope the context tightly, run the model clean, repeat.

Multi-model routing keeps costs sane: cheap model plans, mid-tier model writes, premium model reviews.

## Watching the run

The script streams a live progress block to the terminal and writes a JSONL log per invocation to `scripts/logs/`. Open another terminal and `tail -f scripts/logs/<latest>.log` to watch the model's reasoning.

## Cost expectations

A small story (~50 lines of changed code) typically runs:

- SM expansion: ~$0.02
- Dev implementation: ~$0.15
- Review: ~$0.20
- 0–2 fix passes: ~$0.10 each

Plan for **$0.50–1.50 per story** as a rough order. The whole demo (a few epics worth of stories) lands in the low-to-mid double digits in dollars. Set `--max-budget-usd` on each invocation if you want a hard ceiling.

## Limitations

- The loop assumes the checkpoint command (`npm test`, `npm run build`) reliably tells truth about whether code works. Flaky tests will confuse the review agent.
- BMAD agents work best on greenfield React/TS code. Wiring them to a complex existing codebase needs custom system prompts.
- Long-running loops can drift. Watch the early stories closely; if quality looks off, fix the PRD or epic before letting it churn for hours.

## Adapting this to your project

The easiest path is to run `npx <package> install` in your target directory. The installer asks about your project, renders customized templates, and updates your system prompts. Re-run to update without touching your work.

If you're adapting the loop for a framework or environment not covered by the installer, or you need fine-grained control:

1. [Follow the Quick Start](#quick-start) to get a baseline install.
2. Edit the installer-generated files (described below) for your stack.
3. Test with `./scripts/ralph-loop.sh --dry-run-prompts >/dev/null`.

### Files you'll customize

#### 1. Replace the demo content

The installer scaffolds these from your project answers. If you need to edit further:

| What | Where | Notes |
|---|---|---|
| Your PRD | `docs/prd.md` | The installer generates a stub; refine with the BMAD PM agent (`@bmad-agent-pm`) or edit manually. |
| Your epic + story **stubs** | `docs/epics/*.md` | The installer generates stubs from your project description. Just title + brief acceptance criteria per story — not full implementation specs. The loop's SM agent expands each stub into a detailed spec at run time (writes to `docs/stories/<id>.md`). Story headers MUST be `### Story X.Y: Title` — the loop's parser is strict on that line. |
| Your app source | `src/` | Or override the path with `--project-dir <your-app-dir>`. |

#### 2. Customize the prompts

The loop's agent behavior is controlled by [`scripts/prompts/`](scripts/prompts/) — you don't need to edit `scripts/ralph-loop.sh` itself. The installer scaffolds these based on your answers; customize further if your framework wasn't fully covered. See [`scripts/prompts/README.md`](scripts/prompts/README.md) for the 3-layer composition model. The two files you'll usually edit:

- **`scripts/prompts/common/project-conventions.md`** — The installer scaffolds this based on your stack answers. Customize it further if needed for frameworks the installer didn't cover.
- **`scripts/prompts/review/overlay.md`** — review pass/block criteria. Currently tuned for `tsc`/Vite/Vitest; replace with what "code review passes" means in your codebase.

#### 3. Set your checkpoint command

The loop validates each story by running a **checkpoint command** after the Dev agent finishes. The demo uses `cd src && npm run build && npm test --if-present`. Set yours via `--checkpoint`:

```bash
./scripts/ralph-loop.sh --checkpoint "make test && make lint"
```

Whatever you choose must be **reliable** — flaky tests confuse the Review agent. Fix the flake; never weaken the command.

#### 4. Update CLAUDE.md

The [root `CLAUDE.md`](CLAUDE.md) is auto-loaded by every Claude Code session the loop spawns. The installer scaffolds it with stack rules based on your answers. Customize it further to replace the React/TS rules and guardrails with rules appropriate to your codebase.

#### 5. Run

```bash
./scripts/ralph-loop.sh --stories all --budget-per-story-usd 10
```

Start with a small story budget cap. Watch the first story carefully. If the agent's output isn't what you wanted, the fix is usually **in the PRD or epic** — those are the input quality control. Sharpen them, then re-run.

### How long does adoption take?

Run `npx <package> install` and you'll have a working loop in under 5 minutes. For custom environments or stacks the installer doesn't cover, a focused adapter usually swaps stack + prompts + epic in about an hour. **PRD/epic quality is the #1 predictor of loop output quality.**

## Two Tracks

This repo has two parallel tracks. Both use the same Ralph Loop engine, but for different purposes:

- **Demo Track** — everything at the repo root (`docs/`, `src/`, `scripts/ralph-loop.sh`). The **frozen showcase**: the Exchange Rates Dashboard you built by following Setup. Nothing here changes after first publication. **If you cloned this repo, this is the track you ran.**
- **System Track** — under [`system/`](system/). **The maintainer's R&D lab for the Ralph Loop itself** — refactors of the orchestrator, new agent personas, prompt evolution, bug fixes. It's literally the loop used on itself. Each improvement is a **chapter** under [`system/chapters/`](system/chapters/) with its own plan, PRD, epic, and stories. Browse [chapter 1](system/chapters/2026-05-24-modularize-loop-prompts/) for a complete worked example, including the three infrastructure bugs that chapter exposed and fixed along the way (see the `fix(system)` commits in `git log`).

**If you're forking this for your own project, you don't need the System Track.** It exists in the same repo as the Demo Track on purpose: it makes the recursion legible — anyone visiting the repo can watch the tool forge itself, story by story, in public.

## Credits

- **Ralph Loop pattern** — the original idea, from [Geoff Huntley's "loop" post](https://ghuntley.com/loop/). Drive coding agents through fresh-context iteration cycles instead of one long conversation — every "Ralph" loop in the wild, including this one, traces back to that post.
- **This repo's loop implementation** — adapted from [Seevali Rathnayake](https://seevali.dev)'s production scripts (`ralph-affiant-v2.sh`, `ralph-gantry-v2.sh`).
- **BMAD Method** — by [bmad-code-org](https://github.com/bmad-code-org/BMAD-METHOD).
- **Claude Code** — by [Anthropic](https://claude.com/claude-code).

## Manual Install (Fallback)

The recommended approach is the [Quick Start](#quick-start) above. This section documents the manual installation process for those who need per-step control or are adapting the loop to a non-standard environment.

### Prerequisites

- **Platform:** macOS, Linux, or **WSL2 on Windows** — the loop is a bash pipeline, so PowerShell/cmd won't work. If you're on Windows, install WSL2 and an Ubuntu (or similar) distro, then run everything below from inside WSL.
- Node.js 20+
- [Claude Code CLI](https://claude.com/claude-code) authenticated with an Anthropic account that has API credits
- `git`
- `jq` — JSON processor used to parse the `claude` CLI's output for cost tracking and session handling. Install with:
  - macOS: `brew install jq`
  - Debian/Ubuntu/WSL: `sudo apt-get install -y jq`
  - Other: see [jqlang.org/download](https://jqlang.org/download/)
- A few hours of patience (and budget — the loop costs real money per iteration)

### Setup

```bash
# 1. Install dependencies for the app
cd src && npm install && cd ..

# 2. Install BMAD Method (core + bmm modules only).
#    Interactive: `npx bmad-method install` then choose core + bmm,
#    tool "claude-code", output folder ./docs. Or non-interactively:
npx bmad-method install \
  --directory . --modules core,bmm --tools claude-code \
  --output-folder docs \
  --set bmm.planning_artifacts=docs --set bmm.implementation_artifacts=docs/stories \
  --yes
# This creates _bmad/ and .claude/skills/ (both gitignored — they are
# install products, regenerated by this command). The PRD and epic are
# already committed at docs/prd.md and docs/epics/exchange-rates-dashboard.md,
# so you do NOT need to regenerate them — just run the loop.

# 3. Verify the loop script is executable
chmod +x scripts/ralph-loop.sh
```

> Installs the latest BMAD (v6.7+). Its agent skills are `bmad-create-story`
> (Scrum Master), `bmad-dev-story` (Developer), and `bmad-code-review`
> (Reviewer) — there is no `bmad-agent-sm` in v6.7+.

## License

MIT — see [LICENSE](LICENSE).
