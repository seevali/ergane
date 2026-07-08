# Ergane Installer

The guided wizard to install and manage Ergane—an agentic workflow orchestrator for Claude Code, built on the Ralph loop pattern.

## Quick Start

```bash
npx @seevali/ergane install
```

## What it does

- Scaffolds Ergane into an empty directory or existing project
- Installs [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) agent modules (`core`, `bmm`)
- Configures project conventions and environment
- Ships both loop entry points — the epic-file workflow and the GitHub-issue workflow (`--issue`/`--write`/`--issues`) with the `ralph-watch` swarm dashboard
- Non-interactive mode for CI/CD scripts (`--yes`)

## Prerequisites

- Node.js 20 or later
- Git (strongly recommended; will warn if missing)
- Bash environment (Windows users: WSL2 required)
- jq (optional; some commands work better with it)

## Documentation

Full documentation is in the [main README](https://github.com/seevali/ergane#readme).

## License

MIT
