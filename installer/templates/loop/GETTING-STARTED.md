# Getting Started with Your Ergane Loop

This guide gets you from a fresh install to your first autonomous build, then shows the two ways to feed the loop work: **from an epic file** (the quick-start path) and **from GitHub issues** (the issue-driven path).

A few facts to anchor on before you start:

- **The loop is non-interactive.** `scripts/ralph-loop.sh` is an orchestrator, not a wizard. It reads your epic file, expands it into stories, and drives Scrum-Master → Developer → Reviewer agents story by story. It does not stop to ask you questions.
- **It costs real money.** Every story runs paid Anthropic API calls. See [Cost & budget](#cost--budget) below and set a cap before your first run.
- **The loop never merges or closes anything.** Even in the GitHub-issue workflow it only pushes branches and opens draft PRs — a human reviews and merges.

---

## Quick start — build from an epic file (Path B)

This is the fastest path to a first success. You already have a scaffolded PRD and epic; you just need to fill them in.

### 1. Author your plan

The installer scaffolded two files under `docs/epics/`:

- **`docs/epics/project-prd.md`** — your PRD (product-requirements doc). The Scrum-Master agent reads it to write story specs.
- **`docs/epics/project-stories.md`** — your epic: the list of stories the loop builds, one per `### Story X.Y: Title` header.

Both ship full of `<!-- TODO -->` placeholders. **The loop builds exactly what the epic lists — an empty epic builds nothing.** Open both files and replace the placeholders with your project's real requirements and stories before you run anything.

### 2. Run the loop

```bash
bash scripts/ralph-loop.sh \
  --project-dir {{APP_DIR}} \
  --prd docs/epics/project-prd.md \
  --epic docs/epics/project-stories.md
```

Your app source lives in `{{APP_DIR}}/` (the installer created it empty with a `.gitkeep`). The loop, for each story, will:

1. Ask the **Scrum-Master** agent to expand the story into a detailed spec.
2. Ask the **Developer** agent to implement it inside `{{APP_DIR}}/`.
3. Run your checkpoint command (build + tests).
4. Ask the **Reviewer** agent to pass or block.
5. Commit on a green checkpoint, then move to the next story.

To build just a subset of stories, pass `--stories 1.1,1.2`.

### 3. Watch progress

After your first run finishes a story, the loop writes a progress file:

```bash
# The per-epic progress table (X is your epic's first number, e.g. 1)
cat docs/stories/ralph-sprint-progress-*.md
```

There is no progress file before the first run — don't look for one until the loop has completed at least one story.

---

## Cost & budget

The loop makes **paid Anthropic API calls** on every story. A small story typically costs **cents to a few dollars**; a large epic run adds up. The installed defaults are deliberately generous, so set a cap before your first long run.

Three knobs control spend (env vars in `scripts/ralph-loop.sh`, each also settable as a CLI flag):

| Knob | CLI flag | Default | What it does |
|------|----------|---------|--------------|
| `MAX_ITERATIONS` | `--max-iterations N` | `50` | Hard ceiling on total agent invocations for the run. |
| `BUDGET_PER_STORY_USD` | `--budget-per-story-usd X` | *(empty = no cap)* | Aborts a story and marks it for manual review if its cumulative spend exceeds X dollars. |
| `BUDGET_PER_INVOCATION_USD` | `--budget-per-invocation-usd X` | *(empty = no cap)* | Hard dollar cap on any single agent invocation. |

A safe first run:

```bash
bash scripts/ralph-loop.sh \
  --project-dir {{APP_DIR}} \
  --prd docs/epics/project-prd.md \
  --epic docs/epics/project-stories.md \
  --stories 1.1 \
  --budget-per-story-usd 2
```

---

## Working from GitHub issues (Path A)

Instead of hand-authoring an epic, you can point the loop at a GitHub issue and let it plan and build. This path needs the **GitHub CLI (`gh`)** installed and authenticated (`gh auth login`). Run `{{CLI_INVOCATION}} doctor` to check — it reports `gh` status as informational.

Every command below is **read-only against GitHub by default** (it never pushes, comments, or labels) until you add `--write`.

### Preview a plan (free-ish, safe)

```bash
bash scripts/ralph-loop.sh --issue 42 --plan-only
```

`--issue N` selects an issue to plan from. `--plan-only` runs only the planning phase (writes a local PRD/epic under `docs/`) and then stops — **no code is written**. This still spends a small amount of tokens on the planning agents, but touches nothing on GitHub.

### Build from an issue (still read-only against GitHub)

```bash
bash scripts/ralph-loop.sh --issue 42
```

Plans the issue, then runs the full Path B loop on the derived epic. It writes code locally and spends tokens per story, but makes **no** changes to the GitHub issue or repo — no branch push, no PR, no comment.

### Write back to GitHub (`--write` — default OFF)

```bash
bash scripts/ralph-loop.sh --issue 42 --write
```

Adds `--write` turns on GitHub mutations. It will: push a branch, open a **draft** PR, keep **one** status comment updated on the issue, and set progress labels. It is OFF by default so a first run can never surprise you by writing to your repo. **It still never merges or closes the PR — that stays your decision.**

### Triage gate (`--triage`)

```bash
bash scripts/ralph-loop.sh --issue 42 --triage auto
```

`--triage` is a readiness pre-check that runs before planning. It scores the issue and labels it `ralph:ready`, `ralph:needs-triage`, or `ralph:blocked`, posting clarifying questions when the issue is underspecified and promoting only `ready` issues into the build. Modes: `auto` (default — triage when it helps), `always`, `never`.

### Isolate a run (`--worktree`)

```bash
bash scripts/ralph-loop.sh --issue 42 --worktree
```

`--worktree` runs the issue inside its own git worktree so your main working tree stays clean and back-to-back runs never trample each other. The trees live **inside** the repo at `.ralph/worktrees/issue-N/` (gitignored). A green run removes the tree (keeping the branch for review); a crash or `--plan-only` keeps it, and re-running the same command resumes it.

### Swarm through many issues (`--issues`)

```bash
# Work an explicit queue, one issue after another:
bash scripts/ralph-loop.sh --issues 12,15,19

# Or drain every issue Triage has marked ready:
bash scripts/ralph-loop.sh --issues ready
```

`--issues` burns down a queue of issues serially, each isolated in its own worktree and opening its own draft PR. Watch and control the swarm with the dashboard:

```bash
./scripts/ralph-watch.sh          # live dashboard (Ctrl-C to exit)
./scripts/ralph-watch.sh ls       # one-shot table
./scripts/ralph-watch.sh pause 15 # park issue 15 at its next safe step
./scripts/ralph-watch.sh resume 15
./scripts/ralph-watch.sh abort 15 # stop issue 15; other jobs keep running
```

`ralph-watch.sh` is read-only over the swarm's local state — its only writes are the pause/abort brake files. It never calls GitHub and never merges or closes anything.

---

## Customizing loop behavior

### Model selection

The loop routes each agent role to its own model (env vars in `scripts/ralph-loop.sh`, or CLI flags):

- `MODEL_SM` (`--model-sm`) — Scrum-Master agent. Default: `haiku`.
- `MODEL_DEV` (`--model-dev`) — Developer/Fix agent. Default: `sonnet`.
- `MODEL_REVIEW` (`--model-review`) — Reviewer agent. Default: `opus`.

### Project conventions

Your stack, checkpoint command, and app directory live in `docs/project-conventions.md`. The agents read this file to keep their work aligned with your project. Edit it freely — the installer treats it as yours and won't clobber your changes on update.

Deeper agent behavior lives in `scripts/prompts/`. Edit those overlays to tailor how each role thinks.

---

## Updating your Ergane Loop

```bash
{{CLI_INVOCATION}} update
```

This pulls infrastructure improvements (loop script, watch script, prompts) while preserving your user-owned files (PRD, epic, source, conventions). If a loop file you edited locally conflicts, you're asked to **keep mine**, **take new**, or **back up and take new**.

---

## Troubleshooting

Run the doctor to validate an install:

```bash
{{CLI_INVOCATION}} doctor
```

It checks that all required files are present and unmodified, that `jq` and `claude` are on your PATH, that `scripts/ralph-watch.sh` is present and executable, and (informational) whether `gh` is installed and authenticated for the issue workflow.

Common issues:

1. **Bash not found** — the loop requires bash (native, WSL2, or Git Bash on Windows).
2. **Node.js too old** — the installer requires Node ≥ 20 (`node --version`).
3. **`claude` CLI missing** — ensure it's on your PATH (`which claude`).
4. **`jq` missing** — install it via your OS package manager.
5. **`gh` missing/unauthenticated** — only matters for the GitHub-issue workflow; run `gh auth login`.

---

## Deeper documentation

- **Loop architecture:** the repo's own `README.md`.
- **The GitHub-issue workflow in depth:** [issue-roundtrip chapter](https://github.com/seevali/ergane/tree/main/system/chapters/2026-06-25-github-issue-roundtrip).
- **Prompt customization:** edit the overlays in `scripts/prompts/`.

---

**Happy looping! 🚀**
