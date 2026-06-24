# Getting Started with Your Ralph Loop

This guide covers the basics of running your new Ralph Loop — starting the loop, stopping it, watching logs, and keeping it updated.

## Starting the Loop

To run a single iteration of the loop (wizard prompt + execution):

```bash
bash scripts/ralph-loop.sh
```

The loop will:
1. Present a wizard asking for your task/story details
2. Orchestrate your agents (Scrum Master, Developer, Reviewer)
3. Write implementation files and update your sprint status
4. Show a summary of what was completed

For completely non-interactive mode (no prompts), see **Advanced usage** below.

## Stopping the Loop

To gracefully stop a running loop iteration:
- **Mid-wizard:** Press `Ctrl-C` to cancel any prompt. No files are written until you confirm the final step.
- **Mid-agent:** The loop will attempt to salvage output from the running agent; press `Ctrl-C` again to force-kill and discard.
- **Complete safely:** Let the loop finish its current iteration. The checkpoint step (tests/build) will run before completion.

Partial work is never committed. The loop's definition of "done" includes a passing checkpoint.

## Watching Loop Activity

### Real-time logs

Logs are written to `scripts/logs/` as the loop runs:

```bash
# Watch the most recent log in real-time
tail -f scripts/logs/latest.log

# Or list all logs
ls -lh scripts/logs/
```

Each log includes:
- Agent model selection and invocation
- Full prompt sent to the agent
- Agent output (response)
- Checkpoint command output (tests, build)
- Errors or salvage actions taken

### Sprint status

Your work is tracked in your sprint status file (location and format depend on your setup; typically `docs/sprint-status.yaml` or similar). After each loop iteration:

```bash
# Check sprint status
cat docs/sprint-status.yaml  # or equivalent

# Or view just the progress section
grep -A 50 "development_status:" docs/sprint-status.yaml
```

### Agent memory and decisions

Agent memory and learned preferences live in `docs/_bmad/_memory/` (if BMAD is installed). Each component has its own memory folder:

```bash
# List all agent memory
ls -la docs/_bmad/_memory/

# Check a specific agent's decisions (if the component is tracked)
cat docs/_bmad/_memory/<component>/memory.md
```

This memory persists across loop runs and helps agents make better decisions on future iterations.

## Customizing Loop Behavior

### Loop configuration

Your loop is configured via `scripts/ralph-loop.sh`. Key customizations:

- **Model selection:** Edit the `MODEL_SELECTOR` variable (default: uses Claude Opus)
- **Max iterations:** Edit `MAX_ITERATIONS` (default: 1; set to 0 for infinite until manual stop)
- **Prompt folder location:** The loop reads prompts from `scripts/prompts/` (system-level instructions for your agents)

### Project conventions

Your project's specific conventions (checkpoint command, app directory, tech stack, agent behavior) are in `docs/project-conventions.md`. This file is consulted by the loop's agents to keep work aligned with your project structure.

## Updating Your Ralph Loop

To update the loop infrastructure (new BMAD modules, prompt improvements, bug fixes):

```bash
npx <package> update
```

The update step will:
1. Check for a newer installer version
2. Show you what's changing (installed version → available version)
3. Replace loop infrastructure files (scripts, prompts) if they haven't been locally modified
4. Preserve all your user-owned files (docs, src, tests, configs)
5. Ask before overwriting any locally-modified infrastructure files

If a file conflict occurs:
- **Keep mine:** Keep your local version (useful if you've customized a loop file)
- **Take new:** Use the installer's version (recommended for infrastructure updates)
- **Backup and take:** Rename your local version to `.bak` and use the new one (safe experimentation)

## Troubleshooting

### Loop won't start

1. **Bash not found:** The Ralph Loop requires bash (native or WSL2 on Windows). Install Git Bash or WSL2.
2. **Node.js version:** The installer requires Node ≥ 20. Check: `node --version`
3. **Claude CLI missing:** Ensure `claude` is in your PATH: `which claude`
4. **jq missing:** Install jq for JSON processing (used by the loop for manifest validation). Install via your OS package manager.

### Agent produces low-quality output

1. Check `scripts/logs/latest.log` to see what prompt was sent.
2. Review `docs/project-conventions.md` — your stack description and project facts should be accurate.
3. Run `/ralph-loop-update-conventions` (if available) to re-gather project facts interactively.
4. For deeper customization, edit `scripts/prompts/common/project-conventions.md` and re-run the loop.

### Manifest validation fails

Run the doctor to see what's wrong:

```bash
npx <package> doctor
```

The doctor will validate:
- All required files are present
- File checksums match the manifest
- Required CLI tools (`jq`, `claude`) are available
- Your epic headers parse correctly

Fix any issues and re-run the doctor.

## Next Steps

1. **Start your first loop iteration:** `bash scripts/ralph-loop.sh`
2. **Check the logs:** `tail -f scripts/logs/latest.log`
3. **Review your sprint status:** Check your sprint tracker (e.g., `docs/sprint-status.yaml`)
4. **Customize as needed:** Edit `docs/project-conventions.md` or loop knobs in `scripts/ralph-loop.sh`
5. **Keep updated:** Periodically run `npx <package> update` to pull improvements

For deeper documentation, see:
- **Loop architecture:** README.md (root of this repo)
- **BMAD method:** [BMAD docs](https://bmad.dev) (if BMAD is installed)
- **Prompt customization:** Edit files in `scripts/prompts/` to tailor agent behavior

---

**Happy looping! 🚀**
