# Project Conventions — Ergane (single-track)

These rules are injected into every loop agent's system prompt. They describe how
work is done in THIS repo (the Ergane loop building itself). Follow them exactly.

## Stack

- **Languages:** Bash (the loop and its wrappers) and Markdown (prompts, plans, docs).
  Do NOT switch languages. Node.js / TypeScript is permitted ONLY inside two
  directories: `installer/` (the guided-installer CLI package) and `tools/` (typed
  helper modules the Bash loop shells out to). Everything else is Bash + Markdown.
- **Bash style:** `set -euo pipefail` is mandatory in any new script. Always quote
  variable expansions. Prefer `[[ ]]` over `[ ]`. Bash 4+ is assumed; POSIX-compat is
  not a goal. Keep scripts shellcheck-clean where practical.
- **Markdown style:** prompt files under `scripts/prompts/` carry no YAML frontmatter
  unless the loader parses it; use `{{PLACEHOLDER}}` (double brace) for templated
  values, never bash `${}` interpolation inside Markdown.
- Do NOT add dependencies (npm packages, tools) unless the story explicitly requires them.

## Scope discipline

- Implement only what the current story spec asks for. No refactors of unrelated code,
  no "while I'm here" cleanups, no speculative abstractions.
- Do NOT create new top-level directories unless the story explicitly requires one.
- Self-contained repo: never reference paths outside this repo (no `../`, no absolute
  paths into a parent tree). All paths are relative to the repo root.
- Acceptance criteria are the contract. Make them demonstrable; do not gold-plate.

## Tests

- Shell scripts: validate with `bash -n <script>` and any dry-run mode the script
  provides (e.g. `--dry-run-prompts`).
- The installer package: `cd installer && npm test`.
- Chapter regression smokes under `system/chapters/*/tests/`.

## Checkpoint command

The project checkpoint command is: {{CHECKPOINT_CMD}}

Run it from the repo root to verify the build and tests pass.
