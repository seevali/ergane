# Project Conventions

<!-- This file is managed by the Ergane installer. -->
<!-- It is referenced by loop agents as the authoritative description of your stack rules. -->
<!-- Edit the sections below to reflect your actual project conventions. -->
<!-- The installer may update this file when loop knobs change (checkpoint, model, etc.). -->

## Stack

{{STACK_DESCRIPTION}}

## Scope Discipline

- Implement only what the current story spec asks for. No "while I'm here" cleanups or speculative abstractions.
- If a story seems to require something the stack rules forbid (e.g. a new library), flag it as a question in your output rather than silently installing it.
- Acceptance criteria are the contract. Make them demonstrable; do not gold-plate beyond them.

## Checkpoint Command

The project checkpoint command is:

```
{{CHECKPOINT_COMMAND}}
```

Run this from the project root to verify the app builds and tests pass. The loop's Dev agent runs this after each story.

## Definition of Done (Story Level)

A story is done when:

1. Its acceptance criteria are demonstrable.
2. The checkpoint command above passes.
3. Code Review has passed.
4. The change is committed with a message referencing the story ID.
