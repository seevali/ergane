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

### Story 1.4: Semantic equivalence gate

**Note on scope change (2026-05-25):** This story was originally specified as a byte-diff gate, but that approach is architecturally impossible. The chapter plan deliberately reorders the prompt assembly — Layer 1 (Execution Context) comes BEFORE Layer 2 (BMAD persona), whereas the original heredocs put the persona first with Execution Context bundled into the trailing `common` block. This reordering is a *feature* (Layer 1's "do not HALT" override needs to win against any contradictory persona instructions), so the two assemblies cannot be byte-identical by design. The actual goal — "1.5 doesn't accidentally drop content from the original prompts" — is achievable with a **semantic** equivalence check that compares the *information present* in both assemblies, regardless of ordering.

Build a re-runnable verification script that captures both the pre-refactor heredoc output (via `build_system_prompts()`) and the post-refactor layered output (via `--dry-run-prompts`), then verifies semantic equivalence by checking that every distinct content line from the original is present somewhere in the new output. Resolve any genuine content gaps (missing rules, dropped sentences) by fixing the prompt files in `scripts/prompts/`. Ordering, formatting, and separator differences are expected and allowed.

This story produces a re-runnable check artifact, not a permanent code change to `scripts/ralph-loop.sh`. The script is what story 1.5 will re-run after the heredoc deletion to confirm nothing was lost.

**Acceptance criteria:**
- A verification script exists at `system/chapters/2026-05-24-modularize-loop-prompts/artifacts/verify-semantic-equivalence.sh` that:
  - Captures the pre-refactor output: runs the current `build_system_prompts()` (still heredoc-based) and dumps the three resolved `SYSTEM_PROMPT_*` variables to a temp file.
  - Captures the post-refactor output: runs `./scripts/ralph-loop.sh --dry-run-prompts` and extracts the three role-delimited prompts.
  - For each role, verifies that every **significant content line** from the pre-refactor output appears as a substring of the post-refactor output. "Significant" = non-empty, not a section header line (`## ...`), not a separator (`---`), not a stub heading (`# Agent Persona`).
  - Exits 0 if all three roles pass; exits 1 with diagnostic output (which role failed, which lines are missing) otherwise.
- Script runs cleanly (exit 0) against the current state of the codebase, demonstrating that the layered prompts from story 1.1's files cover all the content from the original heredocs.
- The script is bash, `set -euo pipefail`, and re-runnable from the repo root.
- A brief README at `system/chapters/2026-05-24-modularize-loop-prompts/artifacts/README.md` explains the script's purpose and usage in 6-10 lines.
- `build_system_prompts()` and the heredocs are NOT modified by this story — only the verification artifact is added.

### Story 1.5: Wire the loader and delete inline heredocs

Modify `build_system_prompts()` in `scripts/ralph-loop.sh` to call `load_prompt_layers(role)` instead of using the inline heredocs. Delete the now-unused `common`/SM/Dev/Review heredocs (~110 lines). Re-run the semantic equivalence gate from story 1.4 — must still pass.

**Acceptance criteria:**
- `build_system_prompts()` calls `load_prompt_layers()` for each role, and assigns the result to `SYSTEM_PROMPT_SM`, `SYSTEM_PROMPT_DEV`, `SYSTEM_PROMPT_REVIEW`.
- The inline `common`/SM/Dev/Review heredocs are removed from `scripts/ralph-loop.sh`.
- After the rewire, running `bash system/chapters/2026-05-24-modularize-loop-prompts/artifacts/verify-semantic-equivalence.sh` still exits 0 — every significant line from the original heredocs is still present in the layered output. (The pre-refactor capture step in the script needs to be adapted since the heredocs no longer exist; either use a snapshot file produced during story 1.4 and committed, or read the original content from the prompt files directly.)
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
