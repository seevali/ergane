# Epic: Modularize Loop Prompts

**Chapter:** [2026-05-24-modularize-loop-prompts](../README.md)
**PRD:** [../prd.md](../prd.md)
**Status:** ready for loop execution

---

## Goal

Extract the loop's hardcoded prompt content into a layered file structure and live-load BMAD personas, per the design in the [chapter plan](../README.md).

## Stories

### Story 1.1: Extract repo-local prompt files

Create the `scripts/prompts/` tree per the chapter plan's file layout. Extract the literal text from `scripts/ralph-loop.sh` heredocs (common block, SM/Dev/Review overlays, fallback stubs) into separate `.md` files. Do **not** modify `scripts/ralph-loop.sh` yet — just create the new files.

**Acceptance criteria:**
- `scripts/prompts/README.md` exists and explains the 3-layer model and the `{{CHECKPOINT_CMD}}` whitelist.
- `scripts/prompts/common/execution-context.md` exists with verbatim Layer-1 text from the script's `common` heredoc (lines ~371–402).
- `scripts/prompts/common/project-conventions.md` exists with verbatim Layer-3 shared text (React/Vite/TS stack rules + scope discipline).
- `scripts/prompts/sm/overlay.md`, `scripts/prompts/dev/overlay.md`, `scripts/prompts/review/overlay.md` exist (SM and Dev may be minimal placeholders; Review has the full Review Standards + UPSTREAM_FIX_REQUIRED block).
- `scripts/prompts/bmad-fallbacks/sm.md`, `.../dev.md`, `.../review.md` exist with the current inline fallback stubs.
- No changes to `scripts/ralph-loop.sh`.

### Story 1.2: Add `load_prompt_layers()` helper

Add the loader function to `scripts/ralph-loop.sh` alongside the existing BMAD persona loader. The function reads Layer 1 + Layer 2 + Layer 3, applies the `{{CHECKPOINT_CMD}}` substitution, and returns the assembled string. Do **not** wire it up to `build_system_prompts()` yet.

**Acceptance criteria:**
- Function `load_prompt_layers()` is defined in `scripts/ralph-loop.sh`.
- Function reads from `scripts/prompts/` paths created in story 1.1.
- Function handles the empty-BMAD-persona case by falling back to `scripts/prompts/bmad-fallbacks/<role>.md`.
- `bash -n scripts/ralph-loop.sh` passes (syntax valid).
- `build_system_prompts()` is unchanged — no behavior change yet.

### Story 1.3: Add `--dry-run-prompts` flag

Add a `--dry-run-prompts` CLI flag that calls `load_prompt_layers()` for each role, prints the resolved system prompt to stdout, and exits 0 before any `claude` invocation. This is the safety harness for stories 1.4 and 1.5.

**Acceptance criteria:**
- `./scripts/ralph-loop.sh --dry-run-prompts` prints three prompts (SM, Dev, Review), each clearly delimited (e.g. `=== SM ===`, `=== DEV ===`, `=== REVIEW ===`).
- Exit code 0 on success; non-zero if any layer file is missing.
- Does not invoke `claude` at all.
- `--help` mentions the new flag.
- After this story lands, update `system/ralph-loop-system.sh`'s default checkpoint to include `./scripts/ralph-loop.sh --dry-run-prompts >/dev/null` as a syntax-plus-prompts gate.

### Story 1.4: Byte-diff gate

Capture pre-refactor output of `--dry-run-prompts` against the *current* hardcoded prompts (via a temporary patch that makes `load_prompt_layers()` return the heredoc content verbatim). Compare against post-refactor output where `load_prompt_layers()` reads from the new files (created in story 1.1). Resolve any trailing-newline / ordering differences until the diff is empty.

This story produces a check artifact, not a permanent code change. The diff process is documented for future re-runs.

**Acceptance criteria:**
- Pre- and post-refactor `--dry-run-prompts` output diff is empty (byte-identical).
- Diff procedure is documented in `system/chapters/2026-05-24-modularize-loop-prompts/artifacts/byte-diff-check.md` so it can be re-run by a future contributor.

### Story 1.5: Wire the loader and delete inline heredocs

Modify `build_system_prompts()` in `scripts/ralph-loop.sh` to call `load_prompt_layers(role)` instead of using the inline heredocs. Delete the now-unused `common`/SM/Dev/Review heredocs (~110 lines). Re-run the byte-diff gate from story 1.4 — must still be empty.

**Acceptance criteria:**
- `build_system_prompts()` calls `load_prompt_layers()` for each role.
- The inline heredocs for `common`, SM, Dev, Review wrappers are removed from `scripts/ralph-loop.sh`.
- `./scripts/ralph-loop.sh --dry-run-prompts` output is byte-identical to the snapshot from story 1.4.
- `bash -n scripts/ralph-loop.sh` passes.

### Story 1.6: Documentation update

Update root [`README.md`](../../../../README.md) (Repo layout block) and root [`CLAUDE.md`](../../../../CLAUDE.md) (Repo layout) to mention `scripts/prompts/`. Add a one-paragraph explainer of the 3-layer model so users who fork this demo for a different stack know where to make their changes.

**Acceptance criteria:**
- Both `README.md` and root `CLAUDE.md` mention `scripts/prompts/` in their layout sections.
- A new visitor reading either file understands that prompts are externalized.
- No references to the old hardcoded heredocs remain in the docs.
- Update this chapter's plan ([../README.md](../README.md)) status from `accepted` to `complete`.

---

## Dependency order

Stories must execute in order: **1.1 → 1.2 → 1.3 → 1.4 → 1.5 → 1.6.** Each builds on the previous; the byte-diff gate (1.4) is the safety net before the destructive heredoc deletion (1.5).
