# Chapter: GitHub-Issue Intake / Planning Phase (two execution paths)

**Status:** In progress — started 2026-06-24 (System Track).
**Work surface:** `scripts/ralph-loop.sh` + `scripts/prompts/**` + docs.
**Driver of this chapter's work:** authored interactively (Amelia / `bmad-agent-dev`), not via a loop run, because the loop script itself is the thing being changed and the loop is read-only during its own runs.

> **Cold-start note (for a fresh reader, any LLM, no prior context).** "The loop"
> is `scripts/ralph-loop.sh`, a ~1790-line Bash orchestrator (`set -euo pipefail`)
> that drives a Scrum-Master → Developer → Code-Review cycle, one story at a time,
> each step a fresh `claude -p` process (the "Ralph" pattern: clean context per
> step). BMAD is the agent-skill framework installed under `.claude/skills/`; the
> loop maps SM=`bmad-create-story`, Dev=`bmad-dev-story`, Review=`bmad-code-review`.
> "Checkpoint" is the shell command (`cd src && npm run build && npm test`) that is
> the independent truth-gate before each commit. "System Track" vs "Demo Track" is
> the repo's two-track split (see root `CLAUDE.md` / `system/CLAUDE.md`): Demo Track
> builds the React app under `src/`; System Track improves the loop itself.

## What this chapter adds

A new **Phase 0 (Plan)** in front of the existing loop, giving the loop **two
execution paths**:

- **Path B — "execute" (existing, unchanged).** `--epic FILE --stories LIST
  --checkpoint CMD` runs today's SM→Dev→Review loop. Selected whenever `--issue`
  is absent. Byte-compatible: same artifacts, same `feat(<id>):` commits, same
  output.
- **Path A — "intake" (new).** `--issue N [--repo OWNER/NAME] --checkpoint CMD`
  runs Phase 0 (fetch the issue → BMAD planning chain → write PRD / optional
  architecture / epic), then feeds the **existing** loop (Phase 2) unchanged.

## Phase 0 pipeline (Path A)

1. **Fetch** issue `N` via `gh issue view N --repo <repo> --json
   number,title,body,labels,milestone`. `<repo>` defaults from `--repo` then
   `gh repo view`. Clear errors (and exit) if `gh` is missing/unauthenticated,
   the repo is ambiguous, or the issue doesn't exist. A source snapshot is
   written to `docs/prd/issue-<N>-source.md` so planning agents (and humans)
   can re-read it.
2. **PRD** via the `pm` role (BMAD `bmad-create-prd`) → `docs/prd/issue-<N>.md`.
   For a `bug`-labelled issue the PM is told to produce a short problem-focused
   brief instead of a full PRD (same output path).
3. **Architecture (optional)** via the `architect` role (BMAD
   `bmad-create-architecture`) → `docs/architecture/issue-<N>.md`. Gated by
   `--architecture auto|always|never` (default `auto`): in `auto`, runs when the
   issue is not a bug AND (a label matches `arch|design|rfc` OR the body is long
   > 1200 chars). Deterministic given the issue.
4. **Epic + stories** via the `planner` role (BMAD `bmad-create-epics-and-stories`)
   → `docs/epics/issue-<N>.md`. **Load-bearing output contract:** the epic uses
   `## Epic <N>: <Title>` and `### Story <N>.<k>: <Title>` headers — the exact
   format Phase 2's `--stories all` grep and `extract_story_content` /
   `extract_story_title` already parse. Story IDs are namespaced under the issue
   number (issue 42 → `42.1`, `42.2`, …) so the existing `feat(<id>):` completion
   check and per-story artifacts work unchanged. The planner stops at the epic
   (headers + acceptance criteria); the rich per-story spec is still produced by
   Phase 2's SM step (`bmad-create-story`).
5. **Hand off:** set `EPIC_FILE=docs/epics/issue-<N>.md`, `STORIES_ARG=all`, then
   enter the existing `main()` loop unchanged.

`--plan-only` runs Phase 0 then stops (human reviews PRD/epic before any dev).

## Key implementation decisions (the *why*)

- **`finalize_story_plan()` extraction + deferred call.** The original top-level
  block that expands `--stories all` and initializes the per-story tracking
  arrays needed the epic file to *exist*. In Path A the epic doesn't exist until
  Phase 0 runs (late in the file, after every function is defined, because Phase 0
  calls `run_claude`). So that block was lifted verbatim into a function and
  called: immediately for Path B (same timing as before), and after Phase 0 for
  Path A. The tracking arrays stay **global** (declared at global scope; the
  function reassigns them with plain `=`/`+=`/`read -ra`, never `local`/`declare`,
  so they are not shadowed) — `main()` and `run_claude()` depend on that.
- **`main()` is untouched.** Phase 0 is a gate placed *before* the `main` call.
  The SM→Dev→Review loop, fix/upstream/cascade/auto-heal, smart-salvage, budget
  caps, and `run_claude()`'s signature are byte-for-byte unchanged.
- **Prompt-cache invariant preserved.** Each planning role (`pm`, `architect`,
  `planner`) is added exactly like the existing roles: a `prompts/<role>/overlay.md`,
  a `prompts/bmad-fallbacks/<role>.md`, an `AGENT_<ROLE>_FILE` → the BMAD
  `SKILL.md`, and a `build_system_prompts()` line. Planning system prompts are
  byte-stable within a run, so Anthropic's prompt cache still hits. `build_system_prompts()`
  gained an idempotency guard so the Path-A pre-build (needed before Phase 0) and
  the `main()` build don't double-work.
- **`bmad-product-brief` folded into the PM role, not a separate persona.** The
  PM persona is always `bmad-create-prd`; the bug-vs-feature depth choice lives in
  the PM *user prompt*. Swapping personas mid-run would be pointless churn (PM runs
  once per Path-A run) and muddies the role model — depth-by-prompt is simpler and
  keeps the role table uniform.
- **Phase-0 autonomy.** BMAD planning skills are elicitation-heavy by default. A
  clearly-scoped "Planning Agents" addendum was added to the shared Layer-1
  `execution-context.md` (phrased to be **inert for SM/Dev/Review** — it only
  binds planning roles), plus operational detail in each planning overlay:
  operate autonomously, infer from the issue, record assumptions explicitly,
  never block on questions.
- **Phase-0 failure parks, doesn't crash.** A failed planning invocation (or
  hitting `--max-iterations` mid-plan) logs a clear "parked for manual review"
  message and exits with code `2` (the same code `main()` uses for manual-review),
  rather than a raw `set -e` crash. Pre-flight errors that make planning
  impossible (no `gh`, unauthenticated, unknown repo, missing issue) exit `1` with
  a clear message — there is nothing to park yet.
- **Idempotency / resumability.** Phase 0 is skipped if `docs/epics/issue-<N>.md`
  already exists (mirrors the existing artifact-skip); finer per-artifact skips
  cover an interrupt between PM and planner. An interrupted Path-A run resumes
  straight into Phase 2 and skips already-completed stories.

## CLI surface added

`--issue N` (selects Path A) · `--repo OWNER/NAME` (optional) · `--plan-only` ·
`--model-pm` (default opus) · `--model-architect` (default opus) · `--model-planner`
(default sonnet) · `--architecture auto|always|never` (default auto).
`--issue` and `--epic` are mutually exclusive; `--plan-only` requires `--issue`.

## Out of scope (tracked elsewhere — the broader orchestrator)

git-branch-per-issue / draft-PR tail, issue claiming / label flips, `autonomy-ok`
gating, the scheduler/cron wrapper, auto-closing issues, any remote push beyond
what the loop does today. This chapter is the planning front-end + the two-path
split only.

## Verification

- `bash -n scripts/ralph-loop.sh` (syntax).
- `./scripts/ralph-loop.sh --dry-run-prompts` (Path B: sm/dev/review prompts
  resolve unchanged).
- `./scripts/ralph-loop.sh --issue 1 --dry-run-prompts` (Path A also resolves
  pm/architect/planner prompts; does **not** trigger Phase 0).
- Error-path smokes: `--issue 1 --epic foo.md` (mutual-exclusion error);
  `--plan-only` without `--issue` (error).
