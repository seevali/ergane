# System — where Ergane evolves itself

This folder is where the **Ergane loop is improved using itself**. Every change to the loop infrastructure is made by running `scripts/ralph-loop.sh` on a plan that lives here — the tool forging itself in public, story by story.

> This is a self-referential lab, not a place you need to run anything to use Ergane. To *use* the loop, see the root [README](../README.md). Come here to see how the loop itself was built.

## What lives here

```
system/
├── README.md                  # this file
├── ralph-loop-system.sh       # wrapper that points the canonical loop at a chapter
├── design/                    # living design docs for in-flight loop work
└── chapters/                  # one folder per improvement effort
    └── YYYY-MM-DD-slug/
        ├── README.md          # the plan (renders on GitHub when folder is opened)
        ├── prd.md             # PRD that drives the loop for this chapter
        ├── epics/             # epic(s) derived from the plan
        ├── stories/           # populated by the loop's SM agent during runs
        └── artifacts/         # optional — diagrams, research, test outputs
```

Agent behavior rules for loop runs live in the root [`CLAUDE.md`](../CLAUDE.md) (auto-loaded).

## How a chapter works

Each chapter is a self-contained improvement to the loop infrastructure: refactors of `scripts/ralph-loop.sh`, prompt externalizations, installer work, BMAD adapter layers, etc. The folder shape (`prd.md`, `epics/`, `stories/`) mirrors any BMAD project, so the convention is learnable once.

A chapter goes through this lifecycle:

1. **Plan** — drafted (often by a planning agent), reviewed, accepted. The plan is the chapter's `README.md` so it renders on GitHub. Plans must satisfy the cold-start test: a fresh reader (any LLM, no prior context) can act on the plan from the file alone.
2. **PRD + Epic** — the plan is operationalized into a PRD the loop can consume and one or more epics with story-level acceptance criteria.
3. **Loop execution** — `./system/ralph-loop-system.sh <chapter>` (or just `./system/ralph-loop-system.sh` for the most recent chapter) drives BMAD agents through the stories.
4. **Stories land** — the Dev agent commits each story; the Code Reviewer agent gates each pass. Story files in `stories/` are written by the SM agent at run time.
5. **Chapter closes** — when all stories are merged, the chapter's plan status is updated to `complete` in its `README.md`. Closed chapters stay in place — the historical record matters more than tidiness.

## Running a chapter

```bash
# Run the most recent chapter
./system/ralph-loop-system.sh

# Run a specific chapter
./system/ralph-loop-system.sh 2026-05-24-modularize-loop-prompts

# Pass loop flags through (after the chapter name, or after --)
./system/ralph-loop-system.sh 2026-05-24-modularize-loop-prompts -- --stories 1.1 --max-budget-usd 2

# List available chapters
./system/ralph-loop-system.sh --help
```

The wrapper is a thin shim that resolves the chapter's PRD and epic paths and delegates to [`scripts/ralph-loop.sh`](../scripts/ralph-loop.sh) (the canonical loop). The work surface is the whole repo, except the safety-contract sections of `scripts/ralph-loop.sh` (multi-model routing, retry, budget caps, the `run_claude()` signature). The root [`TIMELINE.md`](../TIMELINE.md) narrates every chapter's outcome.
