# Ralph Loop + BMAD Agents — Demo

A self-contained demo showing the **Ralph Loop** pattern orchestrating **BMAD Method agents** to build a small React app — an **Exchange Rates monitoring dashboard** — story-by-story, autonomously, with one command.

The loop runs overnight (or for an hour, or until you stop it) and produces a working app driven by a PRD and an epics/stories plan.

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
├── src/          # the React app being built
└── _bmad/        # BMAD Method install (created during setup; self-contained)
```

## Prerequisites

- Node.js 20+
- [Claude Code CLI](https://claude.com/claude-code) authenticated with an Anthropic account that has API credits
- `jq` and `git`
- A few hours of patience (and budget — the loop costs real money per iteration)

## Setup

```bash
# 1. Install dependencies for the app
cd src && npm install && cd ..

# 2. Install BMAD Method (core + bmm modules only)
npx bmad-method install
# When prompted, choose: core, bmm. Set output dir to ./docs.

# 3. Verify the loop script is executable
chmod +x scripts/ralph-loop.sh
```

## Running the loop

```bash
./scripts/ralph-loop.sh \
  --project-dir src \
  --prd docs/prd.md \
  --epic docs/epics/exchange-rates-dashboard.md \
  --stories all \
  --checkpoint "npm --prefix src run build && npm --prefix src test"
```

The script runs one story at a time: SM → Dev → Review → (Fix loop) → commit. Stop it anytime with `Ctrl-C`; resume by re-running with the same arguments.

### Useful flags

| Flag | Purpose |
|------|---------|
| `--stories 1,2,3` | Run a subset of stories instead of all |
| `--max-budget-usd 5` | Hard cap per Claude invocation |
| `--tag <name>` | Tag log files for this run |

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

## Credits

- **Ralph Loop pattern** — adapted from [Seevali Rathnayake](https://github.com/seevali)'s production scripts (`ralph-affiant-v2.sh`, `ralph-gantry-v2.sh`).
- **BMAD Method** — by [bmad-code-org](https://github.com/bmad-code-org/BMAD-METHOD).
- **Claude Code** — by [Anthropic](https://claude.com/claude-code).

## License

MIT — see [LICENSE](LICENSE).
