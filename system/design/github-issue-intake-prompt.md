# Implementation prompt — add a GitHub-issue intake/planning phase to `ralph-loop.sh` (two execution paths)

## Your task
You are working **inside the `ralph-loop` repository** (`scripts/ralph-loop.sh`, ~1790-line bash, `set -euo pipefail`). Add a new **intake/planning phase** so the loop can take a single GitHub issue, generate the planning artifacts (PRD / optional architecture / epic + stories) via BMAD, and then run the existing implementation loop on them. The current behavior must remain available **unchanged**. After this change the loop has **two execution paths**.

**Before writing any code, read `scripts/ralph-loop.sh` end-to-end, plus `scripts/prompts/**` and the repo's `CLAUDE.md`.** The line numbers below are guides from a prior read — verify them against the live file; do not trust them blindly.

## How the loop works today (ground truth to preserve)
- **Required flags** `--epic FILE`, `--stories LIST`, `--checkpoint CMD` (validated ~169–171); model routing `--model-sm`/`--model-dev`/`--model-review` (defaults haiku/sonnet/opus, ~68–70).
- **BMAD wiring** (~324–330): SM = `bmad-create-story`, Dev = `bmad-dev-story`, Review = `bmad-code-review`. Each `AGENT_*_FILE` points at `$BMAD_ROOT/<skill>/SKILL.md`.
- **Prompt model:** `load_prompt_layers(role)` (~366) composes 3 layers — L1 `prompts/common/execution-context.md` (the non-interactive override), L2 the live BMAD persona `SKILL.md` (fallbacks in `prompts/bmad-fallbacks/<role>.md`), L3 `prompts/<role>/overlay.md`. `build_system_prompts()` (~434) builds `SYSTEM_PROMPT_{SM,DEV,REVIEW}`. **System prompts are byte-identical within a run so Anthropic's prompt cache hits — this is the main cost lever; preserve it.**
- **One invoker:** `run_claude()` (~705) spawns a fresh `claude -p --dangerously-skip-permissions --model … --max-turns … --append-system-prompt <cached> --output-format json`. Every step is a fresh process; context is reloaded from disk (the "Ralph" model).
- **Scope:** `--stories all` expands by grepping the epic for `### Story X.Y` headers (~256–263); `extract_story_content`/`extract_story_title` (~472/486) slice a story's section out of the epic.
- **State = git history + on-disk artifacts.** `is_story_complete` greps `git log` for `feat(<id>):` (~491). Per-story artifacts in `docs/stories/`: `<id>.md` (spec), `<id>-done.md`, `<id>-review.md`. Review verdict contract: first line `REVIEW_PASSED`/`REVIEW_FAILED` (~508). Steps are **skipped if their artifact already exists** (resumability).
- **`main()`** (~1167) iterates the story list: Step 1/3 SM (~1230) → Step 2/3 Dev (~1249) → Step 3/3 Review (~1321) → fix/upstream-fix/cascade/auto-heal; `run_checkpoint` (the `--checkpoint` command) is the independent truth-gate before commit; exhausted retries/budget park as **"Manual Review Required"**. Progress regenerated into `ralph-sprint-progress-<epic>.md`.
- **Stops:** `--max-iterations` (50), `--max-review-retries` (3), budget caps.

## The two paths (target state)
- **Path B — "execute" (EXISTING; must stay byte-compatible).** `--epic FILE --stories LIST --checkpoint CMD` → today's SM→Dev→Review loop. This is the default whenever `--issue` is absent. **Do not change its behavior, artifacts, commit messages, or output.**
- **Path A — "intake" (NEW).** `--issue N [--repo OWNER/NAME] --checkpoint CMD` → run **Phase 0 (Plan)**, then feed **Phase 2 (the existing loop)**.

## Path A — Phase 0 (Plan) specification
1. **Fetch the issue:** `gh issue view N --repo <repo> --json number,title,body,labels,milestone` (default `<repo>` from `gh repo view`/origin). Fail with a clear message if `gh` is unauthenticated, the repo is ambiguous, or the issue doesn't exist.
2. **Run a BMAD planning chain** — each step a fresh `run_claude` invocation using the same non-interactive discipline as today. Gate the depth by issue size/labels:
   - **PRD** via `bmad-create-prd` (or `bmad-product-brief` for a small `type:bug`) — produce a PRD from the issue body.
   - **(optional) Architecture** via `bmad-create-architecture` only when the issue implies design decisions.
   - **Epic + story breakdown** via `bmad-create-epics-and-stories` — produce the epic markdown file.
3. **Output contract — the bridge to Path B (the load-bearing detail):** Phase 0 MUST emit an epic markdown file at the path Path B consumes (e.g. `docs/epics/issue-<N>.md`) whose stories use the **exact** `### Story <N>.<k>: <Title>` header format that Path B's `--stories all` grep and `extract_story_content`/`extract_story_title` already parse. Namespace story IDs under the issue number (issue 42 → `42.1`, `42.2`, …) so the existing `feat(<id>):` completion check and per-story artifacts work **unchanged**. Persist the PRD/architecture beside it (e.g. `docs/prd/issue-<N>.md`).
   - **Boundary (do not duplicate the SM step):** Phase 0 produces the epic with story *headers + acceptance criteria*. The per-story *rich context spec* is still produced by Phase 2's existing SM step (`bmad-create-story`). Phase 0 stops at the epic; it does not write `docs/stories/<id>.md`.
4. **Hand off:** set `EPIC_FILE=docs/epics/issue-<N>.md` and `STORIES_ARG=all`, then enter the existing `main()` loop **unchanged**.

## CLI surface (consistent with existing flags)
- New: `--issue N` (selects Path A), `--repo OWNER/NAME` (optional), `--plan-only` (run Phase 0 then stop — lets a human review the PRD/epic before any dev), and planning-model flags `--model-pm` / `--model-architect` / `--model-planner` (suggested defaults: opus for PRD/architecture, sonnet for the breakdown).
- **Path selection:** presence of `--issue` ⇒ Path A; otherwise Path B. `--issue` and `--epic` are mutually exclusive (error if both given).
- **Make required-args path-aware:** in Path A, `--epic`/`--stories` are *derived* and must NOT be required; `--checkpoint` stays required (or give it a sane default).

## Invariants you MUST preserve
- **Phase 2 (`main()` SM→Dev→Review + fix/upstream/cascade/auto-heal) is untouched.** Add Phase 0 *in front*; don't refactor the existing loop.
- **Fresh process per step via `run_claude`; cached 3-layer prompts.** Add planning roles the same way every existing role is added: new `prompts/<role>/overlay.md` + `prompts/bmad-fallbacks/<role>.md`, a new `AGENT_<ROLE>_FILE` → the BMAD `SKILL.md`, and extend `build_system_prompts()`. Keep planning system prompts byte-stable within a run.
- **Non-interactive autonomy.** BMAD planning skills are elicitation-heavy by default; under `claude -p --dangerously-skip-permissions` they must run autonomously from the issue body. Extend the `execution-context.md` override and write the planning overlay to say: *operate autonomously, infer reasonable assumptions from the issue, record assumptions explicitly in the PRD, never block on user questions.*
- **Idempotency / resumability.** Skip Phase 0 if its output epic file already exists (mirror the existing artifact-skip), so an interrupted Path-A run resumes straight into Phase 2.
- **Budgets & stops span BOTH phases:** `--max-iterations`, budget caps, and the "Manual Review Required" parking apply to Phase-0 invocations too — a Phase-0 failure parks, it does not crash the run.
- State stays in git + on-disk artifacts; logging to `scripts/logs/`; extend the progress file so a Path-A run shows the Phase-0 planning step above the per-story table.

## Acceptance criteria
- [ ] `--epic … --stories … --checkpoint …` behaves EXACTLY as before — a known epic produces identical artifacts and `feat(<id>):` commits (regression check).
- [ ] `--issue N --checkpoint …` fetches the issue, writes `docs/prd/issue-N.md` + `docs/epics/issue-N.md` (valid `### Story N.k` headers) + optional architecture, then runs SM→Dev→Review per story to a green checkpoint.
- [ ] `--issue N --plan-only` stops after Phase 0 with artifacts written and zero code changes.
- [ ] Re-running `--issue N` after an interrupt resumes (skips Phase 0 if the epic exists; skips completed stories).
- [ ] Error paths are clear: nonexistent issue, unauthenticated `gh`, both `--issue` and `--epic` supplied.
- [ ] `usage()` and the README document both paths with an example each.

## Out of scope (do NOT build here — these are the broader orchestrator, tracked separately)
- The git-branch-per-issue / draft-PR commit tail, issue *claiming* / label flips, `autonomy-ok` gating, the scheduler/cron wrapper.
- Auto-closing issues or any push to a remote beyond what the loop does today.
Keep this change to the **planning front-end + the two-path split**. Nothing else.

## Suggested implementation order
1. Read the script + `prompts/**` + `CLAUDE.md`; write a short design note (what you'll touch, where).
2. Add the CLI flags + path-aware required-args validation.
3. Add planning roles to the prompt system (overlays, fallbacks, `AGENT_*_FILE`, `build_system_prompts`).
4. Implement `run_intake_phase()` — fetch issue → BMAD chain → write PRD/epic → set `EPIC_FILE`/`STORIES_ARG`; with idempotency, logging, and Manual-Review parking.
5. Gate it just before `main()`: if `--issue`, run Phase 0 first; `--plan-only` exits after.
6. Update `usage()` + README; add a dry-run/smoke for both paths.
