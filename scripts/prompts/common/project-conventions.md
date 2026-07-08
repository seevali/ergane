## Project Conventions

This is the stack-agnostic fallback. If the project has a `docs/project-conventions.md`
at its repo root, the loop reads THAT instead of this file — so these rules only apply
when the project ships no conventions of its own.

- **Read the project's own conventions first.** If `docs/project-conventions.md` exists,
  it is authoritative; follow it. (You are seeing this text because it did not exist.)
- **Otherwise, infer conventions from the existing codebase.** Match the language,
  framework, formatting, test tooling, and directory layout already in use. Do not
  impose a stack the project has not chosen.
- **Introduce nothing new unless the story requires it.** Do not add a new framework,
  library, build tool, or dependency unless the story spec explicitly calls for it. If a
  story seems to need one, flag it as a question in your output rather than installing it
  silently.
- **Keep imports, reads, and writes inside the project directory** the loop is working in.

## Scope Discipline

- Implement only what the current story spec asks for. No refactors of unrelated code, no
  "while I'm here" cleanups, no speculative abstractions.
- Acceptance criteria are the contract. Make them demonstrable; do not gold-plate beyond them.

## Checkpoint Command

The project checkpoint command is: {{CHECKPOINT_CMD}}

Run this from the repo root to verify the project builds and tests pass.
