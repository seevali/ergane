#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# Ralph Loop — autonomous BMAD build loop (Cost-Optimized)
#
# Orchestrates SM -> Dev -> Review -> Fix cycles per story.
# Each agent invocation is a fresh Claude Code session (the core
# Ralph insight: clean context per step).
#
# The loop is workload-neutral — it bakes in no project-specific defaults:
#   - Path B (execute): --project-dir and --epic are REQUIRED; they name the
#     app directory the agents work inside and the epic to build from.
#   - Path A (intake, --issue/--issues): the epic is DERIVED from the issue.
#   - Per-project conventions are read at runtime from the target repo's
#     docs/project-conventions.md (falling back to the shipped stack-agnostic
#     scripts/prompts/common/project-conventions.md), and the review checkpoint
#     is whatever --checkpoint specifies. No stack rules are hardcoded here.
# The loop semantics, multi-model routing, retry logic, and budget caps are
# unchanged from the ralph-affiant-v2.sh lineage this was adapted from.
#   - BMAD agent personas load from .claude/skills (BMAD v6.7+): the SM
#     step is bmad-create-story, Dev is bmad-dev-story, Review is
#     bmad-code-review (there is no bmad-agent-sm in v6.7+).
#
# Cost optimizations preserved from the Affiant version:
#   1. Multi-model routing: SM=haiku, Dev=sonnet, Review=opus
#   2. Per-agent --max-turns caps to prevent runaway loops
#   3. Optional --max-budget-usd hard cap per invocation
#   4. Agent persona + stable project conventions moved to
#      --append-system-prompt so Anthropic's prompt cache picks
#      them up across invocations (byte-identical within a run).
#   5. Review/Fix prompts no longer force re-reads of PRD/arch.
#   6. Per-invocation cost + token tracking via --output-format json.
#   7. Retry semantics: one retry with 30s backoff; no retry on
#      exit code 2 (usage errors don't change on retry).
#   8. Per-story and run-total cost in the progress file.
#
# Requires: claude CLI, jq, git
# ═══════════════════════════════════════════════════════════════════

# ──── Colors ────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# ──── Defaults ────
MAX_ITERATIONS=50
MAX_REVIEW_RETRIES=3
MAX_UPSTREAM_DEPTH=1
TAG=""
# Workload-neutral: no project-specific defaults. --project-dir is always
# required; --epic is required for Path B (an --issue/--issues run derives its
# own epic); --checkpoint is always required (it names the project's health
# command — the loop bakes in no stack, so there is no sane default to guess).
# --prd is optional.
EPIC_FILE=""
STORIES_ARG="all"
CHECKPOINT_CMD=""
PROJECT_DIR_ARG=""
PRD_FILE=""
ARCH_FILE=""
DRY_RUN_PROMPTS=false

# Cost-optimization defaults
MODEL_SM="haiku"
MODEL_DEV="sonnet"
MODEL_REVIEW="opus"
MAX_TURNS_SM=15
MAX_TURNS_DEV=40
MAX_TURNS_REVIEW=25
MAX_TURNS_FIX=30
MAX_TURNS_UPSTREAM_FIX=30
BUDGET_PER_INVOCATION_USD=""   # Empty = no hard cap per invocation.
ESCALATION_MODEL="opus"        # Model to escalate to on failed dev/fix retry.
ESCALATION_TURNS_MULTIPLIER=2  # Turn cap multiplier applied on escalated attempt.
BUDGET_PER_STORY_USD=""        # Hard dollar cap per story; abort if cumulative spend exceeds.

# ──── Path A (intake) defaults ────
# Presence of --issue selects Path A: Phase 0 (Plan) turns a GitHub issue into a
# PRD / optional architecture / epic, then Phase 2 (the existing loop) builds it.
ISSUE_NUMBER=""                # Empty = Path B (execute). Non-empty = Path A (intake).
REPO_SLUG=""                   # OWNER/NAME; default resolved via `gh repo view`.
PLAN_ONLY=false                # --plan-only: run Phase 0 then stop (human review).
EPIC_EXPLICIT=false            # True once --epic is passed (for --issue/--epic mutual exclusion).
STORIES_EXPLICIT=false         # True once --stories is passed (Path A derives it).
ARCHITECTURE_MODE="auto"       # auto|always|never — whether Phase 0 runs the architecture step.
TRIAGE_MODE="auto"             # auto|always|never — readiness pre-phase (issue #2 Idea 4) run before Phase 0. `never` restores pre-triage behavior.
USE_WORKTREE=0                 # 0 = run in the main tree (default). 1 = --worktree: isolate the issue run in .ralph/worktrees/issue-N (issue #4). Valid only with --issue.

# ──── Swarm driver (issue #5, Idea 5 v1 — SERIAL) defaults ────
# --issues LIST|ready selects the swarm driver: a SERIAL multi-issue burn-down that
# works a queue one issue at a time, each in its own worktree, each opening its own PR
# (built on Ideas 1/3/4). No concurrency in v1 — that is a separately-justified v2 bet
# (prd.md §3 Idea 5); the pause/resume/abort brake ships in this same increment. The
# driver never merges or closes anything (ADR-001 I3). Empty = single-issue behavior.
ISSUES_ARG=""

# ──── Round-trip (GitHub write-back) defaults ────
# Write-back (branch, draft PR, self-updating comment, verdict-gated labels) is
# the "Round Trip" feature (issue #1). Every GitHub mutation is gated by a single
# master flag, default OFF, so the entire write surface is dark under tests/CI and
# the network is a flag flip (ADR-001 invariant I1). See gh_comment_op /
# gh_label_op / gh_pr_op below.
GITHUB_WRITE=0                 # 0 = read-only (dry); 1 = perform GitHub mutations. Set by --write.

# Planning-model routing (Phase 0). Opus for PRD/architecture, sonnet for the
# epic/story breakdown — the breakdown is mechanical relative to the PRD.
MODEL_PM="opus"
MODEL_ARCHITECT="opus"
MODEL_PLANNER="sonnet"
MAX_TURNS_PM=30
MAX_TURNS_ARCHITECT=30
MAX_TURNS_PLANNER=30

# ──── Argument parsing ────
usage() {
  cat <<'EOF'
Usage:
  Path B (execute):  ralph-loop.sh --project-dir DIR --epic FILE --checkpoint CMD [--stories LIST] [options]
  Path A (intake):   ralph-loop.sh --issue N --project-dir DIR --checkpoint CMD [--repo OWNER/NAME] [--plan-only] [options]

The loop has two execution paths:
  • Path B "execute" (default): build from an existing epic. --project-dir,
    --epic, and --checkpoint are REQUIRED — the loop is workload-neutral and
    bakes in no defaults.
  • Path A "intake" (selected by --issue): turn a single GitHub issue into a PRD /
    optional architecture / epic (Phase 0), then run the Path B loop on it. In
    Path A, --epic/--stories are DERIVED from the issue and must not be passed
    (--issue and --epic are mutually exclusive); --project-dir is still required.

Core flags:
  --project-dir DIR        Relative (or absolute) path to the app the agents work
                           inside. REQUIRED.
  --epic FILE              Path to the epics markdown file. REQUIRED for Path B;
                           derived from the issue in Path A.
  --stories LIST           "all" (every story in the epic, in file order) or a
                           comma-separated subset in execution order, e.g. 1.1,1.2,1.3
                           (default: all)
  --checkpoint CMD         Shell command to verify project health, run from repo root
                           (e.g. 'npm test' or 'cd app && npm run build && npm test').
                           REQUIRED — the loop is workload-neutral and bakes in no
                           default; this command is what every review step gates on.

Optional document references (passed to SM agent for context):
  --prd FILE               Path to the PRD markdown (optional; unset by default)
  --arch FILE              Path to an architecture doc (optional; unset by default)

Path A (intake) flags:
  --issue N                GitHub issue number to plan from. Selects Path A. Phase 0
                           writes docs/prd/issue-N.md, optional docs/architecture/issue-N.md,
                           and docs/epics/issue-N.md (stories namespaced as N.1, N.2, …),
                           then runs the Path B loop on it.
  --repo OWNER/NAME        Repo to read the issue from (default: resolved via `gh repo view`)
  --plan-only              Run Phase 0 (plan) then stop — no code changes. (Requires --issue.)
  --architecture MODE      Whether Phase 0 runs the architecture step: auto|always|never
                           (default: auto — runs for non-bugs with a design/arch/rfc label
                           or a long body)
  --triage MODE            Readiness pre-phase (issue #2 Idea 4) run BEFORE Phase 0:
                           auto|always|never (default: auto). It deterministically scores
                           the issue, labels its stage (ralph:ready / ralph:needs-triage /
                           ralph:blocked), posts clarifying questions when underspecified,
                           and promotes only `ready` issues into Phase 0. `never` restores
                           pre-triage behavior. The gate applies even with --write OFF —
                           the classification is logged, but labels/comments stay dry.
  --worktree               Run this issue inside its own git worktree so the main
                           working tree stays clean and back-to-back issue runs never
                           trample each other (issue #4). The worktree lives INSIDE the
                           repo at .ralph/worktrees/issue-N (gitignored) — never a sibling
                           `../` dir, honoring the self-contained-repo guardrail. Planning
                           artifacts stay readable from the main tree at
                           .ralph/worktrees/issue-N/docs/…. On a fully-green run the tree is
                           removed (the branch ralph/issue-N is kept for review); a crash,
                           park, or --plan-only KEEPS the tree, and re-running the same
                           --issue N --worktree command RESUMES it. Requires --issue.
  --model-pm MODEL         Model for the PRD agent (default: opus)
  --model-architect MODEL  Model for the architecture agent (default: opus)
  --model-planner MODEL    Model for the epic/story breakdown agent (default: sonnet)

Swarm (issue #5, Idea 5 — v1 SERIAL):
  --issues LIST|ready      Work a QUEUE of issues one after another (serial burn-down),
                           each isolated in its own git worktree (Idea 3) and opening its
                           own PR (Idea 1). LIST is a comma-separated set of issue numbers
                           (e.g. 12,15,19; trimmed, de-duplicated, order preserved); the
                           literal `ready` resolves the open issues labelled `ralph:ready`
                           (Triage's promotion gate, issue #2) in ascending order. Mutually
                           exclusive with --issue and --epic. A read-only `ralph watch`
                           dashboard (scripts/ralph-watch.sh) shows per-job state and a
                           per-job pause/resume/abort BRAKE ships in the same increment.
                           No concurrency in v1 — true parallel execution is a separately
                           justified v2 bet (prd.md §3 Idea 5). The loop never merges or
                           closes its own PRs/issues (ADR-001 I3).

Loop options:
  --max-iterations N       Max total agent invocations (default: 50)
  --max-review-retries N   Max fix+re-review cycles per story (default: 3)
  --max-upstream-depth N   Max upstream fix chain depth (default: 1)
  --tag NAME               Git tag to create after all stories complete

Cost options:
  --model-sm MODEL         Model for SM agent (default: haiku)
  --model-dev MODEL        Model for Dev/Fix/Upstream-Fix agents (default: sonnet)
  --model-review MODEL     Model for Review agent (default: opus)
  --max-turns-sm N         Max tool-use turns for SM (default: 15)
  --max-turns-dev N        Max tool-use turns for Dev/Fix (default: 40)
  --max-turns-review N     Max tool-use turns for Review (default: 25)
  --budget-per-invocation-usd X   Hard dollar cap per agent invocation (default: unset)
  --budget-per-story-usd X     Hard dollar cap per story; abort + mark Manual Review if exceeded (default: unset)
  --escalation-model MODEL     Model to use on dev/fix retry (default: opus)
  --escalation-turns-multiplier N  Turn cap multiplier on escalated attempt (default: 2)

Utility flags:
  --dry-run-prompts     Print resolved system prompts for SM, Dev, and Review roles, then exit
  --write               Enable GitHub write-back (branch/PR/comment/labels). Default OFF:
                        without it every GitHub mutation is a no-op logged as "[dry] gh …",
                        so behavior stays byte-identical to read-only Path A (ADR-001 I1).

Example (build every story in an epic):
  ./scripts/ralph-loop.sh \
     --epic docs/epics/my-feature.md \
     --project-dir app \
     --checkpoint 'npm test'

Example (just the first two stories, with a PRD for context):
  ./scripts/ralph-loop.sh --epic docs/epics/my-feature.md --project-dir app \
     --prd docs/prd.md --stories 1.1,1.2 --checkpoint 'npm test'

Example (Path A — plan and build from GitHub issue 42):
  ./scripts/ralph-loop.sh --issue 42 --repo owner/name --project-dir app \
     --checkpoint 'npm test'

Example (Path A — plan only, for human review before any dev):
  ./scripts/ralph-loop.sh --issue 42 --project-dir app --checkpoint 'npm test' --plan-only
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --project-dir)                 PROJECT_DIR_ARG="$2"; shift 2 ;;
    --epic)                        EPIC_FILE="$2"; EPIC_EXPLICIT=true; shift 2 ;;
    --stories)                     STORIES_ARG="$2"; STORIES_EXPLICIT=true; shift 2 ;;
    --checkpoint)                  CHECKPOINT_CMD="$2"; shift 2 ;;
    --issue)                       ISSUE_NUMBER="$2"; shift 2 ;;
    --issues)                      ISSUES_ARG="$2"; shift 2 ;;
    --repo)                        REPO_SLUG="$2"; shift 2 ;;
    --plan-only)                   PLAN_ONLY=true; shift ;;
    --architecture)                ARCHITECTURE_MODE="$2"; shift 2 ;;
    --triage)                      TRIAGE_MODE="$2"; shift 2 ;;
    --worktree)                    USE_WORKTREE=1; shift ;;
    --model-pm)                    MODEL_PM="$2"; shift 2 ;;
    --model-architect)             MODEL_ARCHITECT="$2"; shift 2 ;;
    --model-planner)               MODEL_PLANNER="$2"; shift 2 ;;
    --prd)                         PRD_FILE="$2"; shift 2 ;;
    --arch)                        ARCH_FILE="$2"; shift 2 ;;
    --max-iterations)              MAX_ITERATIONS="$2"; shift 2 ;;
    --max-review-retries)          MAX_REVIEW_RETRIES="$2"; shift 2 ;;
    --max-upstream-depth)          MAX_UPSTREAM_DEPTH="$2"; shift 2 ;;
    --tag)                         TAG="$2"; shift 2 ;;
    --model-sm)                    MODEL_SM="$2"; shift 2 ;;
    --model-dev)                   MODEL_DEV="$2"; shift 2 ;;
    --model-review)                MODEL_REVIEW="$2"; shift 2 ;;
    --max-turns-sm)                MAX_TURNS_SM="$2"; shift 2 ;;
    --max-turns-dev)               MAX_TURNS_DEV="$2"; shift 2 ;;
    --max-turns-review)            MAX_TURNS_REVIEW="$2"; shift 2 ;;
    --budget-per-invocation-usd)   BUDGET_PER_INVOCATION_USD="$2"; shift 2 ;;
    --budget-per-story-usd)        BUDGET_PER_STORY_USD="$2"; shift 2 ;;
    --escalation-model)            ESCALATION_MODEL="$2"; shift 2 ;;
    --escalation-turns-multiplier) ESCALATION_TURNS_MULTIPLIER="$2"; shift 2 ;;
    --dry-run-prompts)             DRY_RUN_PROMPTS=true; shift ;;
    --write)                       GITHUB_WRITE=1; shift ;;
    --help|-h)                     usage ;;
    *)                             echo -e "${RED}Unknown argument: $1${NC}"; usage ;;
  esac
done

# ──── Swarm driver (issue #5) mode guard ────
# --issues (serial multi-issue burn-down) is a distinct mode: it drives N single-issue
# children, so it is mutually exclusive with --issue (one child's own job) and --epic
# (Path B). The queue itself (list vs `ready`) is resolved inside run_swarm_driver, after
# dependency checks. With --issues set and --issue empty, the run falls through the Path B
# validation below (which skips the --epic requirement when --issues is set) and is
# intercepted by the driver gate before main().
if [[ -n "$ISSUES_ARG" ]]; then
  [[ -n "$ISSUE_NUMBER" ]] && { echo -e "${RED}Error: --issues and --issue are mutually exclusive (--issues drives many single-issue children; --issue is one child)${NC}"; usage; }
  $EPIC_EXPLICIT && { echo -e "${RED}Error: --issues and --epic are mutually exclusive (--issues implies Path A children)${NC}"; usage; }
fi

# ──── Path selection + path-aware validation ────
# Path A (intake) is selected by --issue; Path B (execute) is the default.
if [[ -n "$ISSUE_NUMBER" ]]; then
  # Path A: --epic/--stories are DERIVED from the issue, not required.
  [[ ! "$ISSUE_NUMBER" =~ ^[0-9]+$ ]] && { echo -e "${RED}Error: --issue must be a positive integer (got '$ISSUE_NUMBER')${NC}"; usage; }
  $EPIC_EXPLICIT && { echo -e "${RED}Error: --issue and --epic are mutually exclusive (Path A derives the epic from the issue)${NC}"; usage; }
  $STORIES_EXPLICIT && echo -e "${YELLOW}Warning: --stories is ignored in Path A (intake); all generated stories are run${NC}"
  case "$ARCHITECTURE_MODE" in auto|always|never) ;; *) echo -e "${RED}Error: --architecture must be auto|always|never (got '$ARCHITECTURE_MODE')${NC}"; usage ;; esac
  case "$TRIAGE_MODE" in auto|always|never) ;; *) echo -e "${RED}Error: --triage must be auto|always|never (got '$TRIAGE_MODE')${NC}"; usage ;; esac
else
  # Path B (execute) or the swarm driver (--issues). --plan-only/--worktree are
  # Path A-only.
  $PLAN_ONLY && { echo -e "${RED}Error: --plan-only requires --issue (it stops after the Phase 0 plan, which only Path A runs)${NC}"; usage; }
  [[ "$USE_WORKTREE" == "1" ]] && { echo -e "${RED}Error: --worktree requires --issue (it isolates a Path A issue run in its own git worktree)${NC}"; usage; }
  # --epic is required only for a plain Path B run: the swarm driver (--issues) and
  # Path A children (--issue) each derive their own epic, so don't demand it there.
  if [[ -z "$ISSUES_ARG" ]]; then
    [[ -z "$EPIC_FILE" ]] && { echo -e "${RED}Error: --epic is required for Path B (or use --issue/--issues to derive one). See --help.${NC}"; usage; }
  fi
  [[ -z "$STORIES_ARG" ]] && { echo -e "${RED}Error: --stories is required${NC}"; usage; }
fi
[[ -z "$PROJECT_DIR_ARG" ]] && { echo -e "${RED}Error: --project-dir is required (name the app directory the agents work inside). See --help.${NC}"; usage; }
[[ -z "$CHECKPOINT_CMD" ]]  && { echo -e "${RED}Error: --checkpoint is required (the shell command every review step gates on, e.g. 'npm test'). The loop bakes in no default. See --help.${NC}"; usage; }

# ──── Dependency checks ────
command -v claude >/dev/null 2>&1 || {
  echo -e "${RED}Error: claude CLI not found on PATH${NC}"; exit 1; }
command -v jq >/dev/null 2>&1 || {
  echo -e "${RED}Error: jq is required for cost tracking. Install with: brew install jq (macOS) or apt-get install jq (Linux)${NC}"; exit 1; }
command -v git >/dev/null 2>&1 || {
  echo -e "${RED}Error: git not found on PATH${NC}"; exit 1; }

# ──── Path Resolution ────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$PROJECT_DIR_ARG" == /* ]]; then
  PROJECT_DIR="$PROJECT_DIR_ARG"
else
  PROJECT_DIR="$REPO_ROOT/$PROJECT_DIR_ARG"
fi
[[ ! -d "$PROJECT_DIR" ]] && { echo -e "${RED}Error: Project directory not found: $PROJECT_DIR${NC}"; exit 1; }
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Friendly label for banners/progress headers. Defaults to the bare app-dir name;
# refined to the epic's own '## Epic N: Title' below once $EPIC_FILE is resolved.
COMPONENT_DISPLAY_NAME="$(basename "$PROJECT_DIR_ARG")"

# ──── Path A (intake): derive the artifact paths from the issue number ────
# Phase 0 (run_intake_phase, below) generates these before Phase 2 consumes them,
# so the epic does not exist yet at startup — its existence check is deferred.
if [[ -n "$ISSUE_NUMBER" ]]; then
  EPIC_FILE="$REPO_ROOT/docs/epics/issue-${ISSUE_NUMBER}.md"
  PRD_FILE="$REPO_ROOT/docs/prd/issue-${ISSUE_NUMBER}.md"
  ARCH_FILE=""   # set by run_intake_phase only if the architecture step runs
fi

if [[ ! -f "$EPIC_FILE" ]]; then
  if [[ -f "$REPO_ROOT/$EPIC_FILE" ]]; then
    EPIC_FILE="$REPO_ROOT/$EPIC_FILE"
  elif [[ -n "$ISSUE_NUMBER" || -n "$ISSUES_ARG" ]]; then
    :   # Path A: epic generated by Phase 0. Driver (--issues): epic never used (each child
        # derives its own). Both defer/skip the epic-file existence check.
  else
    echo -e "${RED}Error: Epic file not found: $EPIC_FILE${NC}"; exit 1
  fi
fi
# Canonicalize only when the file already exists (Path A's epic is created later;
# its path is already absolute from the derivation above).
if [[ -f "$EPIC_FILE" ]]; then
  EPIC_FILE="$(cd "$(dirname "$EPIC_FILE")" && pwd)/$(basename "$EPIC_FILE")"
  # Prefer the epic's own '## Epic N: Title' header as the friendly display name.
  _epic_display="$(grep -m1 -oE '^## Epic [0-9]+: .+' "$EPIC_FILE" 2>/dev/null | sed -E 's/^## Epic [0-9]+: //')"
  [[ -n "$_epic_display" ]] && COMPONENT_DISPLAY_NAME="$_epic_display"
fi

resolve_optional_doc() {
  local path="$1"
  [[ -z "$path" ]] && { echo ""; return; }
  if [[ "$path" == /* ]]; then
    echo "$path"
  elif [[ -f "$path" ]]; then
    echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
  elif [[ -f "$REPO_ROOT/$path" ]]; then
    echo "$REPO_ROOT/$path"
  else
    echo "$path"
  fi
}

PRD_FILE="$(resolve_optional_doc "$PRD_FILE")"
ARCH_FILE="$(resolve_optional_doc "$ARCH_FILE")"

# In Path A these are generated by Phase 0 and won't exist yet — skip the warning.
if [[ -z "$ISSUE_NUMBER" ]]; then
  [[ -n "$PRD_FILE"  && ! -f "$PRD_FILE"  ]] && echo -e "${YELLOW}Warning: PRD file not found at $PRD_FILE${NC}"
  [[ -n "$ARCH_FILE" && ! -f "$ARCH_FILE" ]] && echo -e "${YELLOW}Warning: Architecture doc not found at $ARCH_FILE${NC}"
fi

# Story specs, per-story progress, and review notes default to docs/stories/
# (BMAD's implementation_artifacts location for this repo). System Track runs
# override this via the STORIES_DIR env var so each chapter keeps its own
# stories under system/chapters/<chapter>/stories/.
STORIES_DIR="${STORIES_DIR:-$REPO_ROOT/docs/stories}"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/ralph-loop-$(date +%Y-%m-%d-%H-%M).log"
MASTER_PROGRESS_FILE="$STORIES_DIR/ralph-sprint-progress.md"
START_TIME="$(date +"%Y-%m-%d %H:%M")"
LOOP_START_EPOCH="$(date +%s)"

mkdir -p "$STORIES_DIR"
mkdir -p "$LOG_DIR"

# BMAD v6.7+ registers agent skills under .claude/skills/ (created by
# `npx bmad-method install`). The loop reads each agent's SKILL.md from here
# to seed the cached system prompts; if absent it falls back to inline personas.
BMAD_ROOT="$REPO_ROOT/.claude/skills"

cd "$PROJECT_DIR"

if [[ ! -f "CLAUDE.md" && ! -f "$REPO_ROOT/CLAUDE.md" ]]; then
  echo -e "${YELLOW}Warning: no CLAUDE.md found — agents will rely on the PRD and epic for conventions${NC}"
fi

# ──── Story plan + tracking arrays (global scope) ────
# These are declared global so finalize_story_plan() — and the rest of the run —
# populate the SAME variables. Path B fills them immediately below; Path A fills
# them after Phase 0 generates the epic (the epic does not exist at startup there).
declare -a STORY_LIST=()
declare -a STORY_STATUSES=()
declare -a STORY_DURATIONS=()
declare -a STORY_RETRIES=()
declare -a STORY_NOTES=()
declare -a STORY_COSTS=()
TOTAL_STORIES=0
EPIC_ID=""
PROGRESS_FILE=""

# finalize_story_plan: expand `--stories all` from the epic (story headers look
# like `### Story 1.1: ...`) and (re)initialize the per-story tracking arrays.
# Runs at global scope — it assigns the globals above with plain `=`/`+=`/`read`,
# never `local`/`declare`, so they are not shadowed and stay visible to main().
finalize_story_plan() {
  if [[ "$STORIES_ARG" == "all" ]]; then
    STORIES_ARG="$(grep -oE '^### Story [0-9]+\.[0-9]+' "$EPIC_FILE" \
      | grep -oE '[0-9]+\.[0-9]+' | paste -sd, -)"
    [[ -z "$STORIES_ARG" ]] && {
      echo -e "${RED}Error: --stories all found no '### Story X.Y' headers in $EPIC_FILE${NC}"; exit 1; }
    echo -e "${CYAN}--stories all -> $STORIES_ARG${NC}"
  fi

  IFS=',' read -ra STORY_LIST <<< "$STORIES_ARG"
  TOTAL_STORIES=${#STORY_LIST[@]}
  EPIC_ID="${STORY_LIST[0]%%.*}"
  PROGRESS_FILE="$STORIES_DIR/ralph-sprint-progress-${EPIC_ID}.md"

  STORY_STATUSES=(); STORY_DURATIONS=(); STORY_RETRIES=(); STORY_NOTES=(); STORY_COSTS=()
  for ((i=0; i<TOTAL_STORIES; i++)); do
    STORY_STATUSES+=("Pending")
    STORY_DURATIONS+=("—")
    STORY_RETRIES+=("—")
    STORY_NOTES+=("—")
    STORY_COSTS+=("0")
  done
}

# Path B (no --issue): the epic exists now, so finalize immediately — same timing
# as before the two-path split. Path A finalizes after Phase 0 builds the epic. Driver
# mode (--issues) skips this entirely: it dispatches per-issue Path A children and never
# touches an epic or the story-plan globals (finalize would only print a spurious
# `--stories all -> …` line and, with no --epic passed, abort).
if [[ -z "$ISSUE_NUMBER" && -z "$ISSUES_ARG" ]]; then
  finalize_story_plan
fi

ITERATION_COUNT=0
STORIES_COMPLETED=0
CURRENT_STORY_IDX=-1
INTERRUPTED=false
# Worktree teardown gate (issue #4). RALPH_ALL_GREEN is flipped to 1 only inside
# main()'s all-green completion block; the EXIT trap (registered by
# ensure_issue_worktree in --worktree mode) removes the worktree ONLY when it is 1
# AND the run exits 0 — so a crash, park, or --plan-only keeps the tree for resume.
# RALPH_MAIN_ROOT holds the pre-re-point repo root; ensure_issue_worktree sets it,
# and the triage ledger + worktree teardown paths read it (empty until then).
RALPH_ALL_GREEN=0
RALPH_MAIN_ROOT=""
TOTAL_COST="0"
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0
TOTAL_CACHE_READ_TOKENS=0

declare -A UPSTREAM_FIX_LOG=()

# ════════════════════════════════════════════════════════════════
# Helpers
# ════════════════════════════════════════════════════════════════

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

format_duration() {
  local secs="$1"
  local m=$((secs / 60))
  local s=$((secs % 60))
  if [[ $m -gt 0 ]]; then printf "%dm %02ds" "$m" "$s"
  else printf "%ds" "$s"; fi
}

# Float addition helper (bash can't do floats natively).
fadd() {
  awk -v a="$1" -v b="$2" 'BEGIN{printf "%.4f", a+b}'
}

log_info()    { local t="[$(timestamp)]"; echo "$t $1" >> "$LOG_FILE"; echo -e "${CYAN}${t} $1${NC}"; }
log_success() { local t="[$(timestamp)]"; echo "$t $1" >> "$LOG_FILE"; echo -e "${GREEN}${t} $1${NC}"; }
log_warn()    { local t="[$(timestamp)]"; echo "$t $1" >> "$LOG_FILE"; echo -e "${YELLOW}${t} $1${NC}"; }
log_error()   { local t="[$(timestamp)]"; echo "$t $1" >> "$LOG_FILE"; echo -e "${RED}${t} $1${NC}"; }
log_plain()   { local t="[$(timestamp)]"; echo "$t $1" >> "$LOG_FILE"; echo "$t $1"; }
log_dim()     { local t="[$(timestamp)]"; echo "$t $1" >> "$LOG_FILE"; echo -e "${DIM}${t} $1${NC}"; }

# ──── GitHub write guards (ADR-001 invariant I1) ────
# THE central gate for every GitHub mutation. Each public helper wraps a `gh`
# invocation: with GITHUB_WRITE=0 (the default, --write off) it logs "[dry] gh …"
# and returns 0 WITHOUT touching the network; with GITHUB_WRITE=1 (--write on) it
# runs the real `gh`. All write-back call sites (branch/PR/comment/labels — issue
# #1, design §6) MUST funnel through these three named helpers so the entire write
# surface is dark by default and a misfire is impossible until the flag is flipped.
# The three names stay distinct so later slices can add op-specific idempotency
# (PR-URL persistence, comment fence handling, single add/remove label calls)
# without touching the shared gate. gh-only — no octokit/REST (design §6).
#
# The block between the >>> / <<< sentinels is sourced standalone by the offline
# smoke (system/chapters/2026-06-25-github-issue-roundtrip/tests/), so keep it
# self-contained: reference only GITHUB_WRITE, log_dim, and gh.
# >>> RALPH WRITE GUARDS (ADR-001 I1) — do not remove the sentinels >>>
_gh_write_guarded() {
  # $@ is the full `gh` argument vector (e.g. issue comment 1 --body-file f).
  if [[ "${GITHUB_WRITE:-0}" != "1" ]]; then
    log_dim "[dry] gh $*"
    return 0
  fi
  gh "$@"
}
gh_comment_op() { _gh_write_guarded "$@"; }   # issue comments (self-updating, fenced — later slice)
gh_label_op()   { _gh_write_guarded "$@"; }    # label transitions (single add/remove — later slice)
gh_pr_op()      { _gh_write_guarded "$@"; }    # branch/draft-PR ops (idempotent via URL file — later slice)
# <<< RALPH WRITE GUARDS <<<

# ──── Load BMAD agent definitions ────
# BMAD v6.7+ skill mapping for the SM -> Dev -> Review cycle:
#   SM     = bmad-create-story (turns the epic into a context-rich story spec)
#   Dev    = bmad-dev-story    (implements the story spec)
#   Review = bmad-code-review  (adversarial review + triage)
# There is no bmad-agent-sm in v6.7+; bmad-create-story is its successor.
AGENT_SM_FILE="$BMAD_ROOT/bmad-create-story/SKILL.md"
AGENT_DEV_FILE="$BMAD_ROOT/bmad-dev-story/SKILL.md"
AGENT_REVIEW_DIR="$BMAD_ROOT/bmad-code-review"

# Path A (intake / Phase 0) planning roles. Same loader pattern as SM/Dev:
#   PM        = bmad-create-prd               (issue -> PRD)
#   Architect = bmad-create-architecture      (optional solution design)
#   Planner   = bmad-create-epics-and-stories (PRD -> epic with story headers)
AGENT_PM_FILE="$BMAD_ROOT/bmad-create-prd/SKILL.md"
AGENT_ARCHITECT_FILE="$BMAD_ROOT/bmad-create-architecture/SKILL.md"
AGENT_PLANNER_FILE="$BMAD_ROOT/bmad-create-epics-and-stories/SKILL.md"

AGENT_SM_PERSONA=""
AGENT_DEV_PERSONA=""
AGENT_REVIEW_PERSONA=""
AGENT_PM_PERSONA=""
AGENT_ARCHITECT_PERSONA=""
AGENT_PLANNER_PERSONA=""

if [[ -f "$AGENT_SM_FILE" ]]; then
  AGENT_SM_PERSONA=$(cat "$AGENT_SM_FILE")
  log_info "Loaded SM agent persona from $AGENT_SM_FILE"
else
  log_warn "SM agent SKILL.md not found at $AGENT_SM_FILE — using inline fallback"
fi

if [[ -f "$AGENT_DEV_FILE" ]]; then
  AGENT_DEV_PERSONA=$(cat "$AGENT_DEV_FILE")
  log_info "Loaded Dev agent persona from $AGENT_DEV_FILE"
else
  log_warn "Dev agent SKILL.md not found at $AGENT_DEV_FILE — using inline fallback"
fi

if [[ -f "$AGENT_REVIEW_DIR/SKILL.md" ]]; then
  AGENT_REVIEW_PERSONA=$(cat "$AGENT_REVIEW_DIR/SKILL.md")
  for step_file in "$AGENT_REVIEW_DIR/steps/"*.md; do
    [[ -f "$step_file" ]] && AGENT_REVIEW_PERSONA+=$'\n\n'"$(cat "$step_file")"
  done
  log_info "Loaded Review agent workflow from $AGENT_REVIEW_DIR"
else
  log_warn "Review agent SKILL.md not found at $AGENT_REVIEW_DIR — using inline fallback"
fi

# Planning personas (Path A). Loaded the same way as SM/Dev — a missing SKILL.md
# falls back to scripts/prompts/bmad-fallbacks/<role>.md inside load_prompt_layers.
if [[ -f "$AGENT_PM_FILE" ]]; then
  AGENT_PM_PERSONA=$(cat "$AGENT_PM_FILE")
  log_info "Loaded PM agent persona from $AGENT_PM_FILE"
else
  log_warn "PM agent SKILL.md not found at $AGENT_PM_FILE — using inline fallback"
fi

if [[ -f "$AGENT_ARCHITECT_FILE" ]]; then
  AGENT_ARCHITECT_PERSONA=$(cat "$AGENT_ARCHITECT_FILE")
  log_info "Loaded Architect agent persona from $AGENT_ARCHITECT_FILE"
else
  log_warn "Architect agent SKILL.md not found at $AGENT_ARCHITECT_FILE — using inline fallback"
fi

if [[ -f "$AGENT_PLANNER_FILE" ]]; then
  AGENT_PLANNER_PERSONA=$(cat "$AGENT_PLANNER_FILE")
  log_info "Loaded Planner agent persona from $AGENT_PLANNER_FILE"
else
  log_warn "Planner agent SKILL.md not found at $AGENT_PLANNER_FILE — using inline fallback"
fi

# ──── Layer 3a conventions source ────
# Prefer the project's own docs/project-conventions.md (this repo commits one; the
# installer renders a per-project one from the wizard's stack answers). Fall back to
# the shipped stack-agnostic scripts/prompts/common/project-conventions.md when the
# target project has none. Derived from $REPO_ROOT, so it MUST be re-derived whenever
# REPO_ROOT changes: ensure_issue_worktree() re-points REPO_ROOT into the worktree for
# --worktree runs and re-runs this exact resolution (inline there, because that fenced
# block must stay self-sourceable for its smoke — see the note at that site). Without
# the re-derive a --worktree run would read the MAIN tree's conventions after the trees
# diverge. Resolved here at startup so the choice is logged beside the persona loads.
if [[ -f "$REPO_ROOT/docs/project-conventions.md" ]]; then
  PROJECT_CONVENTIONS_FILE="$REPO_ROOT/docs/project-conventions.md"
else
  PROJECT_CONVENTIONS_FILE="$REPO_ROOT/scripts/prompts/common/project-conventions.md"
fi
log_info "Loaded project conventions from $PROJECT_CONVENTIONS_FILE"

# Assembles a three-layer system prompt for the given role (sm, dev, review).
# Layer 1: execution-context override (stable, repo-local)
# Layer 2: live BMAD persona or bmad-fallbacks/<role>.md if the persona is empty
# Layer 3: project-conventions.md + <role>/overlay.md (stable, repo-local)
# Layers are joined with "\n\n---\n\n". {{CHECKPOINT_CMD}} is substituted.
# Output goes to stdout; capture with: result=$(load_prompt_layers "dev")
load_prompt_layers() {
  local role="$1"
  [[ -z "$role" ]] && { echo "ERROR: load_prompt_layers requires a role argument (sm, dev, review)" >&2; return 1; }

  local layer1 layer2 layer3_common layer3_overlay layer3 result

  # Layer 1: Execution Context Override (stable, repo-local)
  layer1="$(cat "$REPO_ROOT/scripts/prompts/common/execution-context.md" 2>/dev/null)"
  [[ -z "$layer1" ]] && { echo "ERROR: Layer 1 file not found: $REPO_ROOT/scripts/prompts/common/execution-context.md" >&2; return 1; }

  # Layer 2: BMAD Persona (live from .claude/skills/, or fallback to repo-local)
  case "$role" in
    sm)        layer2="$AGENT_SM_PERSONA" ;;
    dev)       layer2="$AGENT_DEV_PERSONA" ;;
    review)    layer2="$AGENT_REVIEW_PERSONA" ;;
    pm)        layer2="$AGENT_PM_PERSONA" ;;
    architect) layer2="$AGENT_ARCHITECT_PERSONA" ;;
    planner)   layer2="$AGENT_PLANNER_PERSONA" ;;
    *)         echo "ERROR: Unknown role '$role'. Expected one of: sm, dev, review, pm, architect, planner" >&2; return 1 ;;
  esac

  if [[ -z "$layer2" ]]; then
    layer2="$(cat "$REPO_ROOT/scripts/prompts/bmad-fallbacks/${role}.md" 2>/dev/null)"
    [[ -z "$layer2" ]] && { echo "ERROR: No BMAD persona and fallback file not found: $REPO_ROOT/scripts/prompts/bmad-fallbacks/${role}.md" >&2; return 1; }
    log_info "load_prompt_layers($role): using inline fallback (BMAD persona not found)"
  fi

  # Layer 3: project conventions (PROJECT_CONVENTIONS_FILE — the project's own
  # docs/project-conventions.md, else the shipped stack-agnostic fallback; resolved at
  # startup and re-resolved by ensure_issue_worktree() when a --worktree run re-points
  # REPO_ROOT, so this always reflects the current tree)
  layer3_common="$(cat "$PROJECT_CONVENTIONS_FILE" 2>/dev/null)"
  [[ -z "$layer3_common" ]] && { echo "ERROR: Layer 3 conventions file not found: $PROJECT_CONVENTIONS_FILE" >&2; return 1; }

  layer3_overlay="$(cat "$REPO_ROOT/scripts/prompts/${role}/overlay.md" 2>/dev/null)"
  [[ -z "$layer3_overlay" ]] && { echo "ERROR: Layer 3 overlay file not found: $REPO_ROOT/scripts/prompts/${role}/overlay.md" >&2; return 1; }

  layer3="${layer3_common}

${layer3_overlay}"

  # Concatenate layers with markdown separator
  result="${layer1}

---

${layer2}

---

${layer3}"

  # Substitute {{CHECKPOINT_CMD}} placeholder (only whitelisted value; stable for run lifetime).
  # Escape & first: bash's ${//} treats & in the replacement as a backreference (like sed).
  local escaped_cmd="${CHECKPOINT_CMD//&/\\&}"
  result="${result//\{\{CHECKPOINT_CMD\}\}/$escaped_cmd}"

  echo "$result"
}

# ════════════════════════════════════════════════════════════════
# Build cached system prompts
#
# These are byte-identical across every invocation of the same
# agent type within a run. Because we pass them via
# --append-system-prompt, Anthropic's prompt cache will hit on
# subsequent invocations within the cache TTL (~5 min default).
# This is the single biggest cost lever in the script.
# ════════════════════════════════════════════════════════════════

SYSTEM_PROMPT_SM=""
SYSTEM_PROMPT_DEV=""
SYSTEM_PROMPT_REVIEW=""
SYSTEM_PROMPT_PM=""
SYSTEM_PROMPT_ARCHITECT=""
SYSTEM_PROMPT_PLANNER=""
SYSTEM_PROMPTS_BUILT=false

build_system_prompts() {
  # Idempotent: Path A pre-builds these before Phase 0; main() then calls again.
  $SYSTEM_PROMPTS_BUILT && return 0

  SYSTEM_PROMPT_SM=$(load_prompt_layers "sm")
  SYSTEM_PROMPT_DEV=$(load_prompt_layers "dev")
  SYSTEM_PROMPT_REVIEW=$(load_prompt_layers "review")
  # Planning roles (Path A). Built unconditionally so a single run is cheap and
  # the prompts are byte-stable; only invoked when --issue selects Path A.
  SYSTEM_PROMPT_PM=$(load_prompt_layers "pm")
  SYSTEM_PROMPT_ARCHITECT=$(load_prompt_layers "architect")
  SYSTEM_PROMPT_PLANNER=$(load_prompt_layers "planner")

  log_info "System prompts built (SM/Dev/Review + PM/Architect/Planner cached via --append-system-prompt)"
  log_dim "  SM prompt size:        $(echo -n "$SYSTEM_PROMPT_SM"        | wc -c) bytes"
  log_dim "  Dev prompt size:       $(echo -n "$SYSTEM_PROMPT_DEV"       | wc -c) bytes"
  log_dim "  Review prompt size:    $(echo -n "$SYSTEM_PROMPT_REVIEW"    | wc -c) bytes"
  log_dim "  PM prompt size:        $(echo -n "$SYSTEM_PROMPT_PM"        | wc -c) bytes"
  log_dim "  Architect prompt size: $(echo -n "$SYSTEM_PROMPT_ARCHITECT" | wc -c) bytes"
  log_dim "  Planner prompt size:   $(echo -n "$SYSTEM_PROMPT_PLANNER"   | wc -c) bytes"

  SYSTEM_PROMPTS_BUILT=true
}

# ──── Signal handling ────
cleanup() { INTERRUPTED=true; }
trap cleanup SIGINT SIGTERM

# check_interrupted runs between every step of every story. Beyond the Ctrl-C flag
# (the original 3-line body), it is also the swarm BRAKE's honor point (issue #5,
# Idea 5): the driver exports RALPH_JOBS_DIR into each child, and a `ralph watch`
# pause/resume/abort writes a control file the child obeys HERE. The brake block is
# guarded on RALPH_JOBS_DIR + ISSUE_NUMBER, so a standalone --issue run (no driver,
# RALPH_JOBS_DIR unset) is byte-identical to before — no new call sites needed.
check_interrupted() {
  if $INTERRUPTED; then
    if [[ $CURRENT_STORY_IDX -ge 0 ]]; then
      STORY_STATUSES[$CURRENT_STORY_IDX]="Interrupted"
    fi
    update_progress_file
    log_warn "Ralph Loop interrupted. Progress saved to $PROGRESS_FILE"
    exit 130
  fi

  # ── The swarm brake (issue #5) — pause/resume/abort honored between steps ──
  # Only active under the driver (RALPH_JOBS_DIR exported) with a known issue. The
  # control file is written by scripts/ralph-watch.sh; the child updates its OWN job
  # status file (state=paused|running|aborted) so the dashboard reflects the brake.
  if [[ -n "${RALPH_JOBS_DIR:-}" && -n "${ISSUE_NUMBER:-}" ]]; then
    # Rewrite just the state=/updated_epoch= keys of this job's status file, preserving
    # every other key the driver wrote (started_epoch/pid/worktree/log). Nested so the
    # whole brake stays inside check_interrupted (no sibling helper in this region).
    _brake_set_state() { # $1 = new state
      local _sf="$RALPH_JOBS_DIR/issue-${ISSUE_NUMBER}.status"
      [[ -f "$_sf" ]] || return 0
      local _tmp; _tmp="$(mktemp)" || return 0
      awk -v st="$1" -v now="$(date +%s)" '
        /^state=/         { print "state=" st; next }
        /^updated_epoch=/ { print "updated_epoch=" now; next }
                          { print }
      ' "$_sf" > "$_tmp" 2>/dev/null && mv "$_tmp" "$_sf" 2>/dev/null || rm -f "$_tmp"
    }
    local _ctl="$RALPH_JOBS_DIR/issue-${ISSUE_NUMBER}.control"
    local _paused=0
    while [[ -f "$_ctl" ]]; do
      # Ctrl-C beats pause: honor a real interrupt even while parked on the brake.
      if $INTERRUPTED; then
        if [[ $CURRENT_STORY_IDX -ge 0 ]]; then
          STORY_STATUSES[$CURRENT_STORY_IDX]="Interrupted"
        fi
        update_progress_file
        log_warn "Ralph Loop interrupted. Progress saved to $PROGRESS_FILE"
        exit 130
      fi
      local _cmd; _cmd="$(cat "$_ctl" 2>/dev/null || true)"
      if [[ "$_cmd" == "abort" ]]; then
        log_warn "[brake] abort requested for issue #${ISSUE_NUMBER} — stopping this job (exit 4)."
        _brake_set_state aborted
        exit 4
      elif [[ "$_cmd" == "pause" ]]; then
        if [[ $_paused -eq 0 ]]; then
          _paused=1
          log_warn "[brake] pause requested for issue #${ISSUE_NUMBER} — waiting (resume: ralph-watch.sh resume ${ISSUE_NUMBER})."
          _brake_set_state paused
        fi
        sleep 5
      else
        # Unknown/empty control content — treat as no brake and stop polling.
        break
      fi
    done
    if [[ $_paused -eq 1 ]]; then
      _brake_set_state running
      log_info "[brake] resumed issue #${ISSUE_NUMBER}."
    fi
  fi
}

# ════════════════════════════════════════════════════════════════
# Checkpoint Execution
# ════════════════════════════════════════════════════════════════

run_checkpoint() {
  (cd "$REPO_ROOT" && eval "$CHECKPOINT_CMD") 2>&1
}

# ════════════════════════════════════════════════════════════════
# Epic File Operations
# ════════════════════════════════════════════════════════════════

extract_story_content() {
  local story_id="$1"
  awk -v sid="$story_id" '
    BEGIN { found = 0 }
    /^### Story / {
      if (index($0, "### Story " sid ":") == 1) found = 1
      else if (found) exit
    }
    /^## / && found { exit }
    /^---$/ && found { exit }
    found { print }
  ' "$EPIC_FILE"
}

extract_story_title() {
  local story_id="$1"
  sed -n "s/^### Story ${story_id}: //p" "$EPIC_FILE" | head -1
}

is_story_complete() {
  local story_id="$1"
  if git log --oneline --all 2>/dev/null | grep -qE "feat\(${story_id}\):"; then
    return 0
  fi
  return 1
}

mark_story_complete() {
  :   # No-op: completion tracked via git commits + artifacts.
}

# Read a review file's verdict. The agent is instructed to write REVIEW_PASSED
# or REVIEW_FAILED on the first line, but LLMs sometimes wrap the verdict in a
# markdown title (e.g. "# Story 1.1 Code Review" before the marker). Be lenient
# and search for the first line that starts with either marker.
# Returns 0 if PASSED, non-zero otherwise (file missing, FAILED, or no verdict).
is_review_passed() {
  local review_file="$1"
  [[ -f "$review_file" ]] || return 1
  local verdict
  verdict=$(grep -m1 -E '^(REVIEW_PASSED|REVIEW_FAILED)' "$review_file" 2>/dev/null || true)
  [[ "$verdict" == "REVIEW_PASSED" ]]
}

# ════════════════════════════════════════════════════════════════
# Progress File
# ════════════════════════════════════════════════════════════════

get_all_story_ids() {
  grep -oE '^### Story [0-9]+\.[0-9]+:' "$EPIC_FILE" | sed 's/^### Story //; s/://'
}

update_progress_file() {
  local now
  now=$(date +"%Y-%m-%d %H:%M:%S")
  local elapsed="—"
  if [[ -n "${LOOP_START_EPOCH:-}" ]]; then
    elapsed=$(format_duration $(( $(date +%s) - LOOP_START_EPOCH )))
  fi

  local done_count=0 failed_count=0 manual_count=0 pending_count=0 inprog_count=0
  local total_run=${#STORY_LIST[@]}
  for ((k=0; k<total_run; k++)); do
    case "${STORY_STATUSES[$k]}" in
      Done)                     ((done_count++))   || true ;;
      Failed)                   ((failed_count++)) || true ;;
      "Manual Review Required") ((manual_count++)) || true ;;
      "In Progress")            ((inprog_count++)) || true ;;
      *)                        ((pending_count++)) || true ;;
    esac
  done

  local epic_num="${EPIC_ID}"
  local epic_title
  epic_title=$(grep -m1 "^## Epic ${epic_num}:" "$EPIC_FILE" 2>/dev/null | sed "s/^## Epic ${epic_num}: //" || echo "Epic ${EPIC_ID}")

  {
    echo "## Sprint: Epic ${EPIC_ID} — ${epic_title}"
    echo ""
    echo "| Field | Value |"
    echo "|-------|-------|"
    echo "| **Epic** | ${EPIC_ID} |"
    echo "| **Run started** | $START_TIME |"
    echo "| **Last updated** | $now |"
    echo "| **Elapsed** | $elapsed |"
    echo "| **Agent invocations** | $ITERATION_COUNT |"
    echo "| **Total cost** | \$${TOTAL_COST} |"
    echo "| **Input tokens** | $TOTAL_INPUT_TOKENS |"
    echo "| **Output tokens** | $TOTAL_OUTPUT_TOKENS |"
    echo "| **Cache-read tokens** | $TOTAL_CACHE_READ_TOKENS |"
    echo "| **Max iterations** | $MAX_ITERATIONS |"
    echo "| **Max review retries** | $MAX_REVIEW_RETRIES |"
    echo "| **Max upstream depth** | $MAX_UPSTREAM_DEPTH |"
    echo "| **Model (SM/Dev/Review)** | ${MODEL_SM} / ${MODEL_DEV} / ${MODEL_REVIEW} |"
    echo "| **Max turns (SM/Dev/Review)** | ${MAX_TURNS_SM} / ${MAX_TURNS_DEV} / ${MAX_TURNS_REVIEW} |"
    echo "| **Project dir** | \`$PROJECT_DIR_ARG\` |"
    echo "| **Epic file** | \`$EPIC_FILE\` |"
    echo "| **Checkpoint** | \`$CHECKPOINT_CMD\` |"
    echo "| **Log file** | \`$LOG_FILE\` |"
    if [[ -n "$TAG" ]]; then
      echo "| **Git tag** | \`$TAG\` |"
    fi
    echo ""
    echo "### Status Breakdown"
    echo ""
    echo "| Done | In Progress | Pending | Manual Review | Failed | Total |"
    echo "|------|-------------|---------|---------------|--------|-------|"
    echo "| $done_count | $inprog_count | $pending_count | $manual_count | $failed_count | $total_run |"
    echo ""
    if [[ -n "$PHASE0_NOTE" ]]; then
      echo "### Phase 0 — Planning (Path A intake)"
      echo ""
      echo "$PHASE0_NOTE"
      if [[ -n "$ISSUE_NUMBER" ]]; then
        echo ""
        echo "| Artifact | Path |"
        echo "|----------|------|"
        echo "| Issue source | \`docs/prd/issue-${ISSUE_NUMBER}-source.md\` |"
        echo "| PRD | \`$PRD_FILE\` |"
        [[ -n "$ARCH_FILE" && -f "$ARCH_FILE" ]] && echo "| Architecture | \`$ARCH_FILE\` |"
        echo "| Epic | \`$EPIC_FILE\` |"
      fi
      echo ""
    fi
    echo "### Story Details"
    echo ""
    echo "| Story | Title | Status | Duration | Retries | Cost | Notes |"
    echo "|-------|-------|--------|----------|---------|------|-------|"
    for ((k=0; k<total_run; k++)); do
      local s_id="${STORY_LIST[$k]}"
      local s_title
      s_title=$(extract_story_title "$s_id")
      echo "| $s_id | ${s_title:-—} | ${STORY_STATUSES[$k]} | ${STORY_DURATIONS[$k]} | ${STORY_RETRIES[$k]} | \$${STORY_COSTS[$k]} | ${STORY_NOTES[$k]} |"
    done

    echo ""
    echo "### Upstream Fixes Applied"
    echo ""
    if [[ ${#UPSTREAM_FIX_LOG[@]} -gt 0 ]]; then
      echo "| Triggered By | Fixed Story | Result |"
      echo "|--------------|------------|--------|"
      for key in "${!UPSTREAM_FIX_LOG[@]}"; do
        echo "| $key | ${UPSTREAM_FIX_LOG[$key]} | Applied |"
      done
    else
      echo "_None_"
    fi
    echo ""
  } > "$PROGRESS_FILE"

  update_master_progress_file
}

update_master_progress_file() {
  local epic_num="${EPIC_ID}"
  local epic_title
  epic_title=$(grep -m1 "^## Epic ${epic_num}:" "$EPIC_FILE" 2>/dev/null | sed "s/^## Epic ${epic_num}: //" || echo "Epic ${EPIC_ID}")

  {
    echo "# Ralph Sprint Progress — ${COMPONENT_DISPLAY_NAME}"
    echo ""
    echo "> Auto-generated by \`ralph-loop.sh\`. Do not edit manually."
    echo ">"
    echo "> Each epic run appends a new sprint section. Story statuses reflect the last run that touched each story."
    echo ""

    if [[ -f "$MASTER_PROGRESS_FILE" ]]; then
      awk -v epic="${EPIC_ID}" '
        BEGIN { found_sprint=0; in_skip=0 }
        /^## All Stories/ { exit }
        /^## Sprint:/ {
          found_sprint=1
          in_skip = (index($0, "## Sprint: Epic " epic " ") == 1 || $0 == "## Sprint: Epic " epic)
        }
        found_sprint && !in_skip { print }
      ' "$MASTER_PROGRESS_FILE"
    fi

    cat "$PROGRESS_FILE"

    echo "## All Stories — Master Table"
    echo ""
    echo "| Story | Title | Epic | Final Status |"
    echo "|-------|-------|------|-------------|"

    if [[ -f "$MASTER_PROGRESS_FILE" ]]; then
      awk -v epic="${EPIC_ID}" '
        /^## All Stories/,0 {
          if (/^\| [0-9]+\.[0-9]+[[:space:]]*\|/) {
            if ($0 ~ /^\| Story /) next
            match($0, /\| ([0-9]+\.[0-9]+) \|/, arr)
            if (arr[1] != "" && arr[1] !~ ("^" epic "\\.")) print
          }
        }
      ' "$MASTER_PROGRESS_FILE"
    fi

    for ((k=0; k<${#STORY_LIST[@]}; k++)); do
      local s_id="${STORY_LIST[$k]}"
      local s_title
      s_title=$(extract_story_title "$s_id")
      echo "| $s_id | ${s_title:-—} | ${EPIC_ID} | ${STORY_STATUSES[$k]} |"
    done

  } > "$MASTER_PROGRESS_FILE"
}

# ════════════════════════════════════════════════════════════════
# Story Complexity Scaling
#
# Measures story spec line count and scales the dev turn cap upward
# for large stories, before the first attempt. This is a cheap
# proxy for implementation scope — avoids paying for a failed
# Sonnet run on a spec that was always going to need more turns.
#
# Thresholds (tuned against observed 10.2/10.3 failures):
#   >500 lines → ×1.75  (e.g., 40 → 70)
#   >300 lines → ×1.25  (e.g., 40 → 50)
#   ≤300 lines → unchanged
# ════════════════════════════════════════════════════════════════

scale_dev_turns() {
  local story_file="$1"
  local base_turns="$2"
  if [[ ! -f "$story_file" ]]; then
    echo "$base_turns"
    return
  fi
  local lines
  lines=$(wc -l < "$story_file")
  if   [[ $lines -gt 500 ]]; then echo $(( base_turns * 7 / 4 ))
  elif [[ $lines -gt 300 ]]; then echo $(( base_turns * 5 / 4 ))
  else echo "$base_turns"
  fi
}

# ════════════════════════════════════════════════════════════════
# Claude Invocation (cost-tracking variant)
#
# Arguments:
#   $1 user_prompt_file   Path to tempfile with the story-specific user prompt.
#   $2 label              Human-readable label for logs (e.g. "[1.2] Dev Agent").
#   $3 model              Model alias: haiku | sonnet | opus (or full ID).
#   $4 max_turns          Hard turn cap for this invocation.
#   $5 system_prompt      Full system prompt text (passed via --append-system-prompt).
#   $6 story_id           (Optional) Story ID for cost attribution.
# ════════════════════════════════════════════════════════════════

run_claude() {
  local user_prompt_file="$1"
  local label="$2"
  local model="$3"
  local max_turns="$4"
  local system_prompt="$5"
  local story_id="${6:-}"
  local resume_session_id="${7:-}"  # If non-empty, invokes claude --resume <id>

  local attempt=0
  local max_attempts=2
  local rc=0
  local tmp_out
  tmp_out=$(mktemp)

  {
    echo ""
    echo "====== $label — Invocation ======"
    echo "Model: $model | Max turns: $max_turns | Budget cap: ${BUDGET_PER_INVOCATION_USD:-none}"
    echo ""
    echo "------ System Prompt (cached via --append-system-prompt) ------"
    echo "$system_prompt"
    echo ""
    echo "------ User Prompt ------"
    cat "$user_prompt_file"
    echo ""
    echo "------ Response ------"
  } >> "$LOG_FILE"

  while [[ $attempt -lt $max_attempts ]]; do
    rc=0

    # On retry, escalate model and turns if the configured escalation model
    # differs from the original. Applies to dev/fix agents (sonnet → opus);
    # no-ops when the caller already passed opus or when escalation is disabled.
    local current_model="$model"
    local current_turns="$max_turns"
    if [[ $attempt -gt 0 && -n "$ESCALATION_MODEL" && "$model" != "$ESCALATION_MODEL" ]]; then
      current_model="$ESCALATION_MODEL"
      current_turns=$(( max_turns * ESCALATION_TURNS_MULTIPLIER ))
      log_warn "$label: escalating to ${current_model} / ${current_turns} turns (attempt $((attempt+1))/$max_attempts)"
    fi

    local -a args=(
      -p
      --dangerously-skip-permissions
      --model "$current_model"
      --max-turns "$current_turns"
      --append-system-prompt "$system_prompt"
      --output-format json
    )

    if [[ -n "$BUDGET_PER_INVOCATION_USD" ]]; then
      args+=(--max-budget-usd "$BUDGET_PER_INVOCATION_USD")
    fi

    if [[ -n "$resume_session_id" ]]; then
      args+=(--resume "$resume_session_id")
      log_dim "    ${label}: resuming session ${resume_session_id}"
    fi

    claude "${args[@]}" "$(cat "$user_prompt_file")" > "$tmp_out" 2>>"$LOG_FILE" || rc=$?

    # Append raw response to log.
    cat "$tmp_out" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"

    ((ITERATION_COUNT++)) || true

    # Parse usage from JSON result. Default to 0 if any field is missing.
    local cost in_tok out_tok cache_read cache_create num_turns
    cost=$(jq -r       '.total_cost_usd // 0'                 < "$tmp_out" 2>/dev/null || echo "0")
    in_tok=$(jq -r     '.usage.input_tokens // 0'             < "$tmp_out" 2>/dev/null || echo "0")
    out_tok=$(jq -r    '.usage.output_tokens // 0'            < "$tmp_out" 2>/dev/null || echo "0")
    cache_read=$(jq -r '.usage.cache_read_input_tokens // 0'  < "$tmp_out" 2>/dev/null || echo "0")
    cache_create=$(jq -r '.usage.cache_creation_input_tokens // 0' < "$tmp_out" 2>/dev/null || echo "0")
    num_turns=$(jq -r  '.num_turns // 0'                      < "$tmp_out" 2>/dev/null || echo "0")

    # Defensive: coerce any non-numeric to 0.
    [[ "$cost"         =~ ^[0-9]+\.?[0-9]*$ ]] || cost="0"
    [[ "$in_tok"       =~ ^[0-9]+$ ]] || in_tok="0"
    [[ "$out_tok"      =~ ^[0-9]+$ ]] || out_tok="0"
    [[ "$cache_read"   =~ ^[0-9]+$ ]] || cache_read="0"
    [[ "$cache_create" =~ ^[0-9]+$ ]] || cache_create="0"
    [[ "$num_turns"    =~ ^[0-9]+$ ]] || num_turns="0"

    # Smart-retry signal: parse terminal_reason + session_id so callers can decide
    # whether to salvage on-disk work, resume the session, or escalate.
    local terminal_reason session_id
    terminal_reason=$(jq -r '.terminal_reason // ""' < "$tmp_out" 2>/dev/null || echo "")
    session_id=$(jq -r '.session_id // ""' < "$tmp_out" 2>/dev/null || echo "")
    [[ "$terminal_reason" =~ ^[a-z_]+$ ]] || terminal_reason=""
    [[ "$session_id"      =~ ^[A-Za-z0-9_-]+$ ]] || session_id=""
    RALPH_LAST_TERMINAL_REASON="$terminal_reason"
    RALPH_LAST_SESSION_ID="$session_id"

    # Accumulate run totals.
    TOTAL_COST=$(fadd "$TOTAL_COST" "$cost")
    TOTAL_INPUT_TOKENS=$(( TOTAL_INPUT_TOKENS + in_tok ))
    TOTAL_OUTPUT_TOKENS=$(( TOTAL_OUTPUT_TOKENS + out_tok ))
    TOTAL_CACHE_READ_TOKENS=$(( TOTAL_CACHE_READ_TOKENS + cache_read ))

    # Per-story attribution.
    if [[ -n "$story_id" ]]; then
      local sidx=-1
      for ((k=0; k<TOTAL_STORIES; k++)); do
        if [[ "${STORY_LIST[$k]}" == "$story_id" ]]; then sidx=$k; break; fi
      done
      if [[ $sidx -ge 0 ]]; then
        STORY_COSTS[$sidx]=$(fadd "${STORY_COSTS[$sidx]}" "$cost")
      fi
    fi

    log_dim "    ${label} → model=${current_model} turns=${num_turns} in=${in_tok} out=${out_tok} cache_read=${cache_read} cost=\$${cost} (run total: \$${TOTAL_COST})"

    if [[ $rc -eq 0 ]]; then
      rm -f "$tmp_out" "$user_prompt_file"
      return 0
    fi

    # Exit code 2 is a usage error (bad flag, bad prompt format).
    # Retrying won't help — surface immediately.
    if [[ $rc -eq 2 ]]; then
      log_error "$label: usage error (exit 2) — not retrying"
      break
    fi

    # Smart-retry: max_turns means the agent ran out of budget mid-task. The agent
    # may have shipped progress to disk (especially the dev agent) — let the caller
    # decide whether to salvage, resume the session, or escalate. Skip the auto-retry
    # because re-running with a fresh session re-does work the agent already
    # completed and re-burns cache for context that's still warm.
    if [[ "$terminal_reason" == "max_turns" ]]; then
      rm -f "$tmp_out" "$user_prompt_file"
      log_warn "$label: max_turns hit ($num_turns turns, session=$session_id)"
      log_warn "$label: NOT auto-retrying — caller should inspect on-disk state or use --resume"
      return 3
    fi

    ((attempt++)) || true
    if [[ $attempt -lt $max_attempts ]]; then
      log_warn "$label: exit code $rc — retrying in 30s ($((attempt+1))/$max_attempts)..."
      sleep 30
    fi
  done

  rm -f "$tmp_out" "$user_prompt_file"
  log_error "$label: failed after $max_attempts attempts (exit code: $rc)"
  return 1
}

# ════════════════════════════════════════════════════════════════
# Agent Steps
#
# User prompts are now minimal — just the story-specific task and
# file references. Personas, project conventions, and agent-type
# checklists live in the cached system prompts above.
# ════════════════════════════════════════════════════════════════

run_sm_agent() {
  local story_id="$1" story_title="$2" story_content="$3"
  local pf
  pf=$(mktemp)

  local context_reads="- ${EPIC_FILE} (the full epic file, for cross-story context)"
  if [[ -n "$PRD_FILE" && -f "$PRD_FILE" ]]; then
    context_reads="- ${PRD_FILE} (the product requirements)"$'\n'"$context_reads"
  fi
  if [[ -n "$ARCH_FILE" && -f "$ARCH_FILE" ]]; then
    context_reads="- ${ARCH_FILE} (the architecture)"$'\n'"$context_reads"
  fi

  cat > "$pf" << RALPH_PROMPT
Write a detailed development story specification for story ${story_id}: ${story_title}

Read for context:
${context_reads}

The story definition from the epic is:
---
${story_content}
---

Expand this into a complete development story that includes:
- Detailed implementation steps (specific files to create/modify, in order)
- Technical details referencing the relevant PRD sections and architecture decisions
- Dependencies on files created by previous stories
- Exact verification steps (commands to run, expected output)
- Edge cases or gotchas to watch for

Write the story specification to: ${STORIES_DIR}/${story_id}.md
RALPH_PROMPT

  run_claude "$pf" "[${story_id}] SM Agent" "$MODEL_SM" "$MAX_TURNS_SM" "$SYSTEM_PROMPT_SM" "$story_id"
}

run_dev_agent() {
  local story_id="$1"
  local pf
  pf=$(mktemp)

  # Scale turn cap upfront based on story spec size. Large specs (>300 lines)
  # need more turns even on the first attempt — cheaper than a wasted Sonnet run.
  local scaled_turns
  scaled_turns=$(scale_dev_turns "${STORIES_DIR}/${story_id}.md" "$MAX_TURNS_DEV")
  if [[ "$scaled_turns" != "$MAX_TURNS_DEV" ]]; then
    log_dim "    [${story_id}] story spec $(wc -l < "${STORIES_DIR}/${story_id}.md") lines → scaling dev turns ${MAX_TURNS_DEV} → ${scaled_turns}"
  fi

  cat > "$pf" << RALPH_PROMPT
Implement story ${story_id}.

Read the story specification at ${STORIES_DIR}/${story_id}.md and implement everything described.
The project conventions are already in your system prompt — follow them strictly.

After implementation:
- Run the verification steps from the story spec
- If any verification fails, fix the issue before finishing
- Write an implementation summary to ${STORIES_DIR}/${story_id}-done.md listing:
  - Files created or modified
  - Key implementation decisions
  - Verification results
RALPH_PROMPT

  run_claude "$pf" "[${story_id}] Dev Agent" "$MODEL_DEV" "$scaled_turns" "$SYSTEM_PROMPT_DEV" "$story_id"
}

run_review_agent() {
  local story_id="$1"
  local resume_session_id="${2:-}"  # If non-empty, resume the prior session via --resume.
  local pf
  pf=$(mktemp)

  if [[ -n "$resume_session_id" ]]; then
    cat > "$pf" << RALPH_PROMPT
Continue your review of story ${story_id}.

You hit max_turns previously before writing your verdict. The conversation history above already has the full context (story spec, implementation summary, file reads). Conclude the review now: write your verdict to ${STORIES_DIR}/${story_id}-review.md starting with either REVIEW_PASSED or REVIEW_FAILED on the first line, followed by your findings. Do not re-read files you've already inspected — finish the review with what you already know.

Reminder: the verdict file is the contract. Without it written, this story is blocked.
RALPH_PROMPT
  else
    cat > "$pf" << RALPH_PROMPT
Review the implementation of story ${story_id}.

Read:
- ${STORIES_DIR}/${story_id}.md (the story specification with acceptance criteria)
- ${STORIES_DIR}/${story_id}-done.md (the implementation summary)
- All files listed as modified in the implementation summary

Apply the review standards and cross-story root-cause rules from your system prompt.

Write your review to ${STORIES_DIR}/${story_id}-review.md.

If ALL checks pass:
  The LITERAL FIRST LINE of the file MUST be exactly: REVIEW_PASSED
  Do NOT precede it with a markdown title (e.g. "# Story X Code Review"),
  a heading, or any preamble. The very first character of the file is "R".
  Then write a brief summary of what was reviewed on the lines that follow.

If ANY check fails:
  The LITERAL FIRST LINE of the file MUST be exactly: REVIEW_FAILED
  Do NOT precede it with a markdown title or any preamble.
  Then list each specific issue with file paths and line references.
  Be specific enough for the Dev agent to fix without ambiguity.
  If the root cause is in a previous story, include the UPSTREAM_FIX_REQUIRED block
  per the format in your system prompt.
RALPH_PROMPT
  fi

  run_claude "$pf" "[${story_id}] Review Agent" "$MODEL_REVIEW" "$MAX_TURNS_REVIEW" "$SYSTEM_PROMPT_REVIEW" "$story_id" "$resume_session_id"
}

# Auto-heal injection: invoked when the final independent checkpoint fails after
# a REVIEW_PASSED verdict. Forces the review agent to re-render its verdict in
# light of the captured checkpoint output. The agent is instructed to output
# REVIEW_FAILED so the existing fix loop takes over and the dev agent gets a
# concrete failure to repair.
run_review_agent_with_failure_injection() {
  local story_id="$1"
  local chk_output="$2"
  local pf chk_tail
  pf=$(mktemp)

  # Cap captured output to keep the prompt bounded — build/test failures can
  # be tens of thousands of lines, and the tail typically has the actionable signal.
  chk_tail=$(printf '%s\n' "$chk_output" | tail -n 200)

  cat > "$pf" << RALPH_PROMPT
You previously marked this story as REVIEW_PASSED, but the final independent validation gate failed with the following error. Analyze if this is a flaky test or a structural defect. You MUST output REVIEW_FAILED and provide specific instructions for the Dev agent to fix the root cause.

Story: ${story_id}
Checkpoint command: ${CHECKPOINT_CMD}

Re-read the relevant artifacts before deciding:
- ${STORIES_DIR}/${story_id}.md (the story specification)
- ${STORIES_DIR}/${story_id}-done.md (the implementation summary)
- Any test or source files implicated in the failure output below

Then overwrite ${STORIES_DIR}/${story_id}-review.md. The LITERAL FIRST LINE of the file MUST be exactly REVIEW_FAILED (no markdown title, no preamble — the very first character is "R"), followed on subsequent lines by precise file paths, line references, and corrective instructions the Dev agent can act on without further interpretation. If the failure is a flaky test, identify the test and prescribe a deterministic fix (do not instruct the Dev agent to disable or skip it).

Here is the captured error (last 200 lines of the checkpoint output):

${chk_tail}
RALPH_PROMPT

  run_claude "$pf" "[${story_id}] Review Agent (Auto-Heal)" "$MODEL_REVIEW" "$MAX_TURNS_REVIEW" "$SYSTEM_PROMPT_REVIEW" "$story_id" ""
}

run_fix_agent() {
  local story_id="$1"
  local resume_session_id="${2:-}"  # If non-empty, resume the prior session via --resume.
  local pf
  pf=$(mktemp)

  if [[ -n "$resume_session_id" ]]; then
    cat > "$pf" << RALPH_PROMPT
Continue fixing story ${story_id}.

You hit max_turns previously before finishing. The conversation history above already has the review findings and the implementation context. Conclude the fix now: address any remaining REVIEW_FAILED issues from ${STORIES_DIR}/${story_id}-review.md that you haven't already fixed, then run the checkpoint command (see your system prompt) to confirm the build is green. Do not re-read files you've already inspected — finish with what you already know.

Reminder: re-review is the gate that decides whether the fix is complete. Your job is to ship code changes that address the review's findings; the verbose done.md update is optional.
RALPH_PROMPT
  else
    cat > "$pf" << RALPH_PROMPT
Fix the issues identified in code review for story ${story_id}.

Read:
- ${STORIES_DIR}/${story_id}.md (the story specification)
- ${STORIES_DIR}/${story_id}-review.md (the code review feedback — REVIEW_FAILED)

Fix every issue listed in the review.

After fixing:
- Run the verification steps from the story spec
- Run the checkpoint command to confirm the project still builds and tests pass
- Update ${STORIES_DIR}/${story_id}-done.md with a brief note on what you fixed

Do not introduce new issues while fixing the reviewed ones.
RALPH_PROMPT
  fi

  run_claude "$pf" "[${story_id}] Fix Agent" "$MODEL_DEV" "$MAX_TURNS_FIX" "$SYSTEM_PROMPT_DEV" "$story_id" "$resume_session_id"
}

# ════════════════════════════════════════════════════════════════
# Upstream Fix Detection & Resolution
# ════════════════════════════════════════════════════════════════

detect_upstream_fix() {
  local review_file="$1"

  if [[ ! -f "$review_file" ]]; then
    return 1
  fi

  local upstream_story
  upstream_story=$(grep -m1 '^UPSTREAM_FIX_REQUIRED:' "$review_file" | sed 's/^UPSTREAM_FIX_REQUIRED:[[:space:]]*//' | tr -d '[:space:]')

  if [[ -n "$upstream_story" ]]; then
    if [[ "$upstream_story" =~ ^[0-9]+\.[0-9]+$ ]]; then
      echo "$upstream_story"
      return 0
    else
      log_warn "Invalid upstream story ID format: '$upstream_story'"
      return 1
    fi
  fi

  return 1
}

run_upstream_fix_agent() {
  local upstream_story_id="$1"
  local current_story_id="$2"
  local current_review_file="${STORIES_DIR}/${current_story_id}-review.md"
  local pf
  pf=$(mktemp)

  local root_cause affected_files current_impact
  root_cause=$(sed -n 's/^ROOT_CAUSE:[[:space:]]*//p' "$current_review_file" | head -1)
  affected_files=$(sed -n 's/^AFFECTED_FILES:[[:space:]]*//p' "$current_review_file" | head -1)
  current_impact=$(sed -n 's/^CURRENT_IMPACT:[[:space:]]*//p' "$current_review_file" | head -1)

  cat > "$pf" << RALPH_PROMPT
Perform an upstream fix on story ${upstream_story_id}, triggered by the review of ${current_story_id}.

## Context

During review of story ${current_story_id}, a bug was found whose root cause is in code written by story ${upstream_story_id}.

**Root cause:** ${root_cause}
**Affected files:** ${affected_files}
**Impact on ${current_story_id}:** ${current_impact}

Read:
- ${current_review_file} (full review of ${current_story_id}, for complete context)
- ${STORIES_DIR}/${upstream_story_id}.md (the upstream story spec, for original intent)
- ${STORIES_DIR}/${upstream_story_id}-done.md (the upstream implementation summary)

## Task

1. Understand the affected files
2. Fix the root cause — make the MINIMUM change needed
3. Do NOT refactor or improve unrelated code in the upstream story
4. Ensure your fix does not break the upstream story's own acceptance criteria
5. Run the checkpoint command to confirm the project still builds and tests pass
6. Update ${STORIES_DIR}/${upstream_story_id}-done.md with an "Upstream Fix" section:
   - What was changed and why
   - Which downstream story triggered this fix (${current_story_id})
   - Files modified

CRITICAL: Only modify files in story ${upstream_story_id}'s scope. If shared definitions must change (e.g., interfaces or types used by both stories), make those changes too — but keep them minimal.
RALPH_PROMPT

  run_claude "$pf" "[${current_story_id}] Upstream Fix Agent (fixing ${upstream_story_id})" "$MODEL_DEV" "$MAX_TURNS_UPSTREAM_FIX" "$SYSTEM_PROMPT_DEV" "$current_story_id"
}

verify_cascade() {
  local upstream_story_id="$1"
  local current_story_id="$2"

  local upstream_idx=-1 current_idx=-1
  for ((i=0; i<TOTAL_STORIES; i++)); do
    [[ "${STORY_LIST[$i]}" == "$upstream_story_id" ]] && upstream_idx=$i
    [[ "${STORY_LIST[$i]}" == "$current_story_id" ]] && current_idx=$i
  done

  log_info "Verifying cascade: checkpoint after upstream fix to $upstream_story_id"
  local chk_rc=0
  local chk_output=""
  chk_output=$(run_checkpoint) || chk_rc=$?

  if [[ $chk_rc -ne 0 ]]; then
    log_error "Cascade verification FAILED — checkpoint broken after upstream fix"
    log_error "$chk_output"
    return 1
  fi

  log_success "Cascade verification passed — checkpoint OK after upstream fix to $upstream_story_id"

  if [[ $upstream_idx -ge 0 && $current_idx -ge 0 ]]; then
    local intermediate_count=0
    for ((i=upstream_idx+1; i<current_idx; i++)); do
      local mid_story="${STORY_LIST[$i]}"
      if is_review_passed "${STORIES_DIR}/${mid_story}-review.md"; then
        log_info "  Intermediate story $mid_story: previously passed review, checkpoint still green"
        ((intermediate_count++)) || true
      fi
    done
    if [[ $intermediate_count -gt 0 ]]; then
      log_info "  $intermediate_count intermediate stories verified via checkpoint"
    fi
  fi

  return 0
}

# ════════════════════════════════════════════════════════════════
# Phase 0 — Intake / Planning (Path A only)
#
# Fetches a single GitHub issue and runs a BMAD planning chain
# (PRD -> optional architecture -> epic + stories) as fresh run_claude
# invocations, using the same non-interactive discipline and cached,
# byte-stable system prompts as Phase 2. The epic it writes uses the
# exact `## Epic <N>:` / `### Story <N>.<k>:` headers that Phase 2's
# `--stories all` grep and extract_story_* already parse, so the loop
# continues into main() unchanged.
#
# State stays in git + on-disk artifacts: Phase 0 is skipped if its epic
# already exists (resumability), and each step is skipped if its own
# artifact exists. A planning failure PARKS (clear message + exit 2) — it
# does not crash the run with a raw set -e abort.
# ════════════════════════════════════════════════════════════════

PHASE0_NOTE=""        # One-line Phase 0 summary rendered into the progress file.
ISSUE_TITLE=""
ISSUE_SOURCE_FILE=""
IS_BUG=false

# Park a Phase-0 failure: log clearly and exit 2 (same code main() uses for
# Manual Review Required). Budgets/iteration caps and planning-agent failures
# all funnel here so a Phase-0 problem surfaces for a human instead of crashing.
phase0_park() {
  local msg="$1"
  log_error "[Phase 0] $msg"
  log_error "[Phase 0] Parked for manual review — run with --plan-only to inspect, or fix and re-run (Phase 0 resumes if the epic exists)."
  # The per-story progress file only exists once finalize_story_plan has run
  # (after Phase 0). During Phase 0 there is no story table to write — the log is
  # the record — so only refresh the progress file if it has been set up.
  [[ -n "$PROGRESS_FILE" ]] && { update_progress_file 2>/dev/null || true; }
  exit 2
}

# Guard the shared iteration cap before each planning invocation (budgets span
# both phases). Per-invocation dollar caps are already enforced inside run_claude.
phase0_iteration_guard() {
  if [[ $ITERATION_COUNT -ge $MAX_ITERATIONS ]]; then
    phase0_park "Max iterations ($MAX_ITERATIONS) reached during planning."
  fi
}

run_pm_agent() {
  local pf
  pf=$(mktemp)

  local depth_guidance
  if $IS_BUG; then
    depth_guidance="This issue is labelled a bug. Produce a CONCISE, problem-focused brief — problem statement, expected vs actual behaviour, a root-cause hypothesis if the issue suggests one, and acceptance criteria for the fix. Do not pad it into a full feature PRD."
  else
    depth_guidance="Produce a full PRD — goals, numbered functional requirements (FR-1, FR-2, …) that are observable from outside the code, and the non-functional constraints that matter."
  fi

  cat > "$pf" << RALPH_PROMPT
Author a Product Requirements Document for GitHub issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}

Read the issue (title, labels, milestone, full body) at:
- ${ISSUE_SOURCE_FILE}

${depth_guidance}

Write the PRD to: ${PRD_FILE}

The PRD MUST:
- State the problem/goal and the scope drawn from the issue.
- Express requirements observable from outside the code (renders X, responds to Y, calls endpoint Z).
- Include a "## Assumptions" section recording every detail you inferred rather than read directly from the issue.
- Stay within the project's stack rules (already in your system prompt).

Operate autonomously: do not ask questions, do not start an elicitation workshop — infer and commit.
RALPH_PROMPT

  run_claude "$pf" "[issue ${ISSUE_NUMBER}] PM Agent" "$MODEL_PM" "$MAX_TURNS_PM" "$SYSTEM_PROMPT_PM" ""
}

run_architecture_agent() {
  local pf
  pf=$(mktemp)

  cat > "$pf" << RALPH_PROMPT
Author a focused solution-design / architecture note for GitHub issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}

Read:
- ${PRD_FILE} (the PRD produced for this issue)
- ${ISSUE_SOURCE_FILE} (the original issue)

Write the architecture note to: ${ARCH_FILE}

Cover only what the build needs: the components touched, the data/control flow, the key technical choices and their rationale, and the cross-cutting concerns (error handling, persistence, accessibility) the build must honour. Include a "## Assumptions" section. Stay within the stack rules in your system prompt.

Do NOT break the work into stories — that is the planner's job. Operate autonomously: infer and commit, do not ask questions.
RALPH_PROMPT

  run_claude "$pf" "[issue ${ISSUE_NUMBER}] Architect Agent" "$MODEL_ARCHITECT" "$MAX_TURNS_ARCHITECT" "$SYSTEM_PROMPT_ARCHITECT" ""
}

run_planner_agent() {
  local pf arch_read_line=""
  pf=$(mktemp)
  if [[ -n "$ARCH_FILE" && -f "$ARCH_FILE" ]]; then
    arch_read_line="- ${ARCH_FILE} (the architecture / solution-design note)"
  fi

  cat > "$pf" << RALPH_PROMPT
Break the PRD for GitHub issue #${ISSUE_NUMBER} into ONE epic with small, incremental stories.

Read:
- ${PRD_FILE} (the PRD)
${arch_read_line}

Write the epic to: ${EPIC_FILE}

CRITICAL output format — parsed by shell tooling, so follow it EXACTLY:
- Exactly one epic header line: "## Epic ${ISSUE_NUMBER}: <Epic Title>"
- Each story header EXACTLY: "### Story ${ISSUE_NUMBER}.<k>: <Story Title>", with <k> = 1, 2, 3, …
  Examples: "### Story ${ISSUE_NUMBER}.1: ...", then "### Story ${ISSUE_NUMBER}.2: ...".
- A colon and a single space after the ID; a title on the same line.
- Inside a story's body do NOT use a "## " heading and do NOT put a lone "---" line — either one truncates the story when it is sliced out later. Use bold labels or "####" sub-headings. End the story list with a "## Notes" section or a final "---" line.

For each story: the header, a short description, and an "Acceptance Criteria" list observable from outside the code. Keep stories small and incremental — each independently demonstrable, each leaving the checkpoint green — and ordered so later stories build on earlier ones.

STOP at the epic. Do NOT write any per-story spec files under docs/stories/ — the build loop's Scrum Master step produces those later. Operate autonomously: infer and commit, do not ask questions.
RALPH_PROMPT

  run_claude "$pf" "[issue ${ISSUE_NUMBER}] Planner Agent" "$MODEL_PLANNER" "$MAX_TURNS_PLANNER" "$SYSTEM_PROMPT_PLANNER" ""
}

# Decide whether the optional architecture step runs. Deterministic given the
# issue (no hidden state): see --architecture auto|always|never.
intake_needs_architecture() {
  case "$ARCHITECTURE_MODE" in
    always) return 0 ;;
    never)  return 1 ;;
    auto)
      $IS_BUG && return 1
      # A design/arch/rfc label, or a long body, implies real design decisions.
      if printf '%s' "$1" | jq -e '[.labels[].name | ascii_downcase] | any(test("arch|design|rfc"))' >/dev/null 2>&1; then
        return 0
      fi
      local body_len
      body_len=$(printf '%s' "$1" | jq -r '.body // "" | length' 2>/dev/null || echo 0)
      [[ "$body_len" =~ ^[0-9]+$ ]] || body_len=0
      [[ $body_len -gt 1200 ]] && return 0
      return 1 ;;
    *) return 1 ;;
  esac
}

run_intake_phase() {
  # ── Pre-flight: gh available, authenticated, repo resolvable ──
  command -v gh >/dev/null 2>&1 || {
    log_error "Path A (--issue) requires the GitHub CLI 'gh' on PATH. Install: https://cli.github.com/"; exit 1; }
  if ! gh auth status >/dev/null 2>&1; then
    log_error "Path A: 'gh' is not authenticated. Run: gh auth login"; exit 1
  fi

  local slug="$REPO_SLUG"
  if [[ -z "$slug" ]]; then
    slug=$(cd "$REPO_ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || true
  fi
  [[ -z "$slug" ]] && {
    log_error "Path A: could not determine the GitHub repo. Pass --repo OWNER/NAME (or set a default with: gh repo set-default)."; exit 1; }
  log_info "[Phase 0] Intake for issue #${ISSUE_NUMBER} in ${slug}"

  ISSUE_SOURCE_FILE="$REPO_ROOT/docs/prd/issue-${ISSUE_NUMBER}-source.md"
  local arch_path="$REPO_ROOT/docs/architecture/issue-${ISSUE_NUMBER}.md"

  # ── Resumability fast-path: epic already exists → Phase 0 is done ──
  if [[ -f "$EPIC_FILE" ]]; then
    [[ -f "$arch_path" ]] && ARCH_FILE="$arch_path"
    local n_existing
    # `grep -c` prints the count AND exits 1 on zero matches, so put the fallback
    # on the assignment (not inside $()) to avoid a "0\n0" value.
    n_existing=$(grep -cE '^### Story [0-9]+\.[0-9]+:' "$EPIC_FILE" 2>/dev/null) || n_existing=0
    PHASE0_NOTE="Resumed: epic issue-${ISSUE_NUMBER}.md already present (${n_existing} stories) — skipped planning."
    log_info "[Phase 0] Epic already exists at $EPIC_FILE — skipping planning, resuming into Phase 2."
    return 0
  fi

  # ── Fetch the issue ──
  local issue_json
  issue_json=$(cd "$REPO_ROOT" && gh issue view "$ISSUE_NUMBER" --repo "$slug" \
    --json number,title,body,labels,milestone 2>/dev/null) || {
      log_error "Path A: could not fetch issue #${ISSUE_NUMBER} from ${slug}. Does it exist and is it accessible to your gh account?"; exit 1; }

  ISSUE_TITLE=$(printf '%s' "$issue_json" | jq -r '.title // ""')
  local body labels milestone
  body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
  labels=$(printf '%s' "$issue_json" | jq -r '[.labels[].name] | join(", ")')
  milestone=$(printf '%s' "$issue_json" | jq -r '.milestone.title // ""')

  IS_BUG=false
  if printf '%s' "$issue_json" | jq -e '[.labels[].name | ascii_downcase] | any(. == "bug" or test("(^|[: ])bug$"))' >/dev/null 2>&1; then
    IS_BUG=true
  fi

  # ── Persist a source snapshot the planning agents (and humans) can re-read ──
  mkdir -p "$REPO_ROOT/docs/prd" "$REPO_ROOT/docs/epics"
  {
    printf '# Issue #%s: %s\n\n' "$ISSUE_NUMBER" "$ISSUE_TITLE"
    printf -- '- Repo: %s\n' "$slug"
    printf -- '- Labels: %s\n' "${labels:-none}"
    printf -- '- Milestone: %s\n' "${milestone:-none}"
    printf '\n## Body\n\n%s\n' "$body"
  } > "$ISSUE_SOURCE_FILE"
  log_info "[Phase 0] Wrote issue snapshot to $ISSUE_SOURCE_FILE (bug=${IS_BUG})"

  # ── Step 1: PRD ──
  if [[ -f "$PRD_FILE" ]]; then
    log_info "[Phase 0] PRD already exists — skipping PM agent"
  else
    phase0_iteration_guard
    log_info "[Phase 0] PM agent writing PRD (model=${MODEL_PM})..."
    run_pm_agent || phase0_park "PM agent failed (terminal_reason=${RALPH_LAST_TERMINAL_REASON:-unknown})."
    [[ -f "$PRD_FILE" ]] || phase0_park "PM agent finished but no PRD was written at $PRD_FILE."
    log_success "[Phase 0] PRD written: $PRD_FILE"
  fi

  # ── Step 2: Architecture (optional) ──
  ARCH_FILE=""
  if [[ -f "$arch_path" ]]; then
    ARCH_FILE="$arch_path"
    log_info "[Phase 0] Architecture note already exists — skipping Architect agent"
  elif intake_needs_architecture "$issue_json"; then
    mkdir -p "$REPO_ROOT/docs/architecture"
    ARCH_FILE="$arch_path"
    phase0_iteration_guard
    log_info "[Phase 0] Architect agent writing solution design (model=${MODEL_ARCHITECT})..."
    run_architecture_agent || phase0_park "Architect agent failed (terminal_reason=${RALPH_LAST_TERMINAL_REASON:-unknown})."
    if [[ ! -f "$ARCH_FILE" ]]; then
      log_warn "[Phase 0] Architect agent produced no file — continuing without an architecture note."
      ARCH_FILE=""
    else
      log_success "[Phase 0] Architecture note written: $ARCH_FILE"
    fi
  else
    log_info "[Phase 0] Architecture step skipped (mode=${ARCHITECTURE_MODE}; issue does not imply design decisions)."
  fi

  # ── Step 3: Epic + stories ──
  phase0_iteration_guard
  log_info "[Phase 0] Planner agent writing epic + stories (model=${MODEL_PLANNER})..."
  run_planner_agent || phase0_park "Planner agent failed (terminal_reason=${RALPH_LAST_TERMINAL_REASON:-unknown})."
  [[ -f "$EPIC_FILE" ]] || phase0_park "Planner agent finished but no epic was written at $EPIC_FILE."

  # ── Validate the load-bearing output contract before handing off to Phase 2 ──
  local n_stories
  n_stories=$(grep -cE "^### Story ${ISSUE_NUMBER}\.[0-9]+:" "$EPIC_FILE" 2>/dev/null) || n_stories=0
  [[ "$n_stories" =~ ^[0-9]+$ ]] || n_stories=0
  if [[ $n_stories -lt 1 ]]; then
    phase0_park "Epic at $EPIC_FILE has no valid '### Story ${ISSUE_NUMBER}.<k>:' headers — Phase 2 cannot consume it."
  fi
  if ! grep -qE "^## Epic ${ISSUE_NUMBER}:" "$EPIC_FILE" 2>/dev/null; then
    log_warn "[Phase 0] Epic is missing a '## Epic ${ISSUE_NUMBER}:' header — progress will show a generic title."
  fi

  local arch_note="no architecture"
  [[ -n "$ARCH_FILE" && -f "$ARCH_FILE" ]] && arch_note="architecture"
  PHASE0_NOTE="Issue #${ISSUE_NUMBER} → PRD + ${arch_note} + epic (${n_stories} stories)."
  log_success "[Phase 0] Planning complete: ${n_stories} stories in $EPIC_FILE"
}

# ──── Branch-per-issue (issue #1, slice a) ────
# Path A builds onto a dedicated branch `ralph/issue-N` so the dev loop's
# feat() commits never land on the base branch. The branch is LOCAL state (no
# network), so it is created in EVERY mode — including --write off — keeping the
# branch-before-commit invariant true even in dry runs. Pushing the branch is a
# GitHub mutation and is deferred to the draft-PR slice (b), gated by --write.
# Idempotent: a re-run resumes the existing branch (checkout, never -B/reset), so
# prior story commits are preserved.
#
# Sourced standalone by the offline smoke (tests/slice-a-issue-branch-smoke.sh),
# so keep self-contained: reference only ISSUE_NUMBER, REPO_ROOT, git, and log_*.
# >>> RALPH ISSUE BRANCH (issue #1 slice a) — do not remove the sentinels >>>
ensure_issue_branch() {
  local branch="ralph/issue-${ISSUE_NUMBER}"
  local current
  current="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)" || {
    log_error "[branch] not a git repository at $REPO_ROOT — cannot create $branch"; exit 1; }

  if [[ "$current" == "$branch" ]]; then
    log_info "[branch] already on $branch (resuming)"
  elif git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    if ! git -C "$REPO_ROOT" checkout "$branch" 2>/dev/null; then
      log_error "[branch] '$branch' exists but checkout failed (uncommitted changes in the way?) — refusing to build"; exit 1
    fi
    log_info "[branch] resumed existing $branch"
  else
    if ! git -C "$REPO_ROOT" checkout -b "$branch" 2>/dev/null; then
      log_error "[branch] could not create $branch off $current — refusing to build"; exit 1
    fi
    log_success "[branch] created $branch (off $current)"
  fi

  # Hard invariant (issue #1 AC: branch-before-commit). The dev loop runs next
  # (main() is the very next statement), so verifying HEAD here IS asserting it
  # before the dev loop — story commits must never land on the base branch.
  local head
  head="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [[ "$head" != "$branch" ]]; then
    log_error "[branch] expected HEAD=$branch before the dev loop, but HEAD=$head — refusing to build so story commits never land on the base branch"
    exit 1
  fi
}
# <<< RALPH ISSUE BRANCH <<<

# ──── Draft PR at intake (issue #1, slice b) ────
# After Phase 0 writes the plan (docs/prd/issue-N.md, docs/epics/issue-N.md) and
# ensure_issue_branch() has put HEAD on ralph/issue-N, this opens the human's
# reviewable surface: commit the plan as the PR's first commit, push the branch,
# and open exactly ONE draft PR whose body is the PRD. The push and PR are network
# mutations, so both are gated by --write (ADR-001 I1) — with --write off they log
# a dry line and touch nothing, so externally observable behavior stays
# byte-identical to read-only Path A.
#
# Why the plan commit: ensure_issue_branch() creates ralph/issue-N off the base
# with the plan files still UNCOMMITTED, so the branch has no commits ahead of base
# and a real `gh pr create` would fail ("No commits between main and ralph/issue-N").
# commit_issue_plan() gives the draft PR its first commit. It is gated to --write so
# --write-off local history is unchanged (there the plan is swept into the first
# story commit, exactly as read-only Path A does today).
#
# Idempotency (ADR-001 I2): the PR URL is persisted to docs/prd/issue-N-pr.txt at
# creation. On a re-run, if that file exists and `gh pr view` still resolves it,
# the PR is reused (no second PR). It is re-created only on a genuine 404. Never
# auto-merge, never auto-close (I3) — the PR stays a draft here; readying it is the
# finish step.
#
# Branch-based recovery (issue #4 hardening): docs/prd/issue-N-pr.txt is UNTRACKED,
# so a successful --worktree run removes the tree (git worktree remove --force) and
# discards it. Without recovery, a later --write-on re-run would see no recorded URL
# and call `gh pr create` on a branch that ALREADY has a PR → a hard `gh` failure.
# So, on the --write-ON path only (after the --write-off dry return, keeping --write
# off byte-identical), before creating we ask GitHub whether this branch already has
# a PR via an UNGATED read (`gh pr view <branch> --json url`); if so we re-persist
# the URL and reuse it instead of creating a duplicate.
#
# `gh pr create` funnels through gh_pr_op (the slice-1 guarded helper); the branch
# push goes through _git_push_guarded (the same gate, but git is not a gh command).
# gh-only, no octokit/REST (design §6).
#
# Sourced standalone (alongside the RALPH WRITE GUARDS block, for gh_pr_op) by the
# offline smoke (tests/slice-b-draft-pr-smoke.sh), so keep self-contained:
# reference only GITHUB_WRITE, ISSUE_NUMBER, ISSUE_TITLE, REPO_ROOT, the gh_pr_op
# helper, git/gh, and log_*.
# >>> RALPH ISSUE PR (issue #1 slice b) — do not remove the sentinels >>>
_git_push_guarded() {
  # A branch push is a network mutation → gated exactly like the gh_*_op helpers
  # (ADR-001 I1). $1 = branch to push to origin. With --write off: log a dry line,
  # return 0, touch nothing. With --write on: push and set upstream.
  local branch="$1"
  if [[ "${GITHUB_WRITE:-0}" != "1" ]]; then
    log_dim "[dry] git push -u origin $branch"
    return 0
  fi
  git -C "$REPO_ROOT" push -u origin "$branch"
}

commit_issue_plan() {
  # Commit the intake plan artifacts onto ralph/issue-N as the PR's first commit,
  # so the draft PR is non-empty. A LOCAL git op (no network); the CALLER gates it
  # on GITHUB_WRITE so --write-off history is untouched. Narrow `git add` (never
  # -A) of only the plan files, mirroring the loop's per-story staging discipline.
  # Idempotent: if nothing is staged (already committed), skip without erroring.
  local branch="ralph/issue-${ISSUE_NUMBER}"
  local -a paths=()
  local p
  for p in "docs/prd/issue-${ISSUE_NUMBER}.md" \
           "docs/prd/issue-${ISSUE_NUMBER}-source.md" \
           "docs/epics/issue-${ISSUE_NUMBER}.md" \
           "docs/architecture/issue-${ISSUE_NUMBER}.md"; do
    [[ -f "$REPO_ROOT/$p" ]] && paths+=("$p")
  done
  if [[ ${#paths[@]} -eq 0 ]]; then
    log_warn "[pr] no intake plan files found to commit onto $branch"
    return 0
  fi
  git -C "$REPO_ROOT" add -- "${paths[@]}" 2>/dev/null || true
  if git -C "$REPO_ROOT" diff --cached --quiet; then
    log_info "[pr] intake plan already committed — nothing to commit"
    return 0
  fi
  if git -C "$REPO_ROOT" commit -q -m "docs(issue-${ISSUE_NUMBER}): intake plan (PRD + epic)"; then
    log_success "[pr] committed intake plan onto $branch (PR first commit)"
  else
    log_error "[pr] failed to commit intake plan onto $branch"; return 1
  fi
}

ensure_issue_pr() {
  local branch="ralph/issue-${ISSUE_NUMBER}"
  local pr_file="$REPO_ROOT/docs/prd/issue-${ISSUE_NUMBER}-pr.txt"
  local body_file="$REPO_ROOT/docs/prd/issue-${ISSUE_NUMBER}.md"
  local title="Ralph: #${ISSUE_NUMBER} ${ISSUE_TITLE:-}"

  # ── Idempotency (I2): an already-recorded PR is reused, never duplicated ──
  if [[ -s "$pr_file" ]]; then
    local existing
    existing="$(head -n1 "$pr_file")"
    # `gh pr view` is a READ (no mutation) → ungated, like the existing read sites.
    if gh pr view "$existing" >/dev/null 2>&1; then
      log_info "[pr] draft PR already open ($existing) — reusing (idempotent)"
      return 0
    fi
    log_warn "[pr] recorded PR not found ($existing) — re-creating"
  fi

  # ── Commit the plan as the PR's first commit (LOCAL op, gated to --write so
  #    --write-off history is unchanged; without it the branch is empty vs base) ──
  if [[ "${GITHUB_WRITE:-0}" == "1" ]]; then
    commit_issue_plan
  fi

  # ── Push the issue branch (network mutation → gated by --write) ──
  _git_push_guarded "$branch"

  # ── Open exactly one draft PR (network mutation → gated via gh_pr_op) ──
  if [[ "${GITHUB_WRITE:-0}" != "1" ]]; then
    # --write off: dry no-op. Emit the [dry] line through the guarded helper and
    # persist nothing — externally identical to read-only Path A.
    gh_pr_op pr create --draft --base main --head "$branch" \
      --title "$title" --body-file "$body_file"
    log_info "[pr] dry-run: branch not pushed, draft PR not opened (enable with --write)"
    return 0
  fi

  # ── Branch-based PR recovery (issue #4 idempotency hardening) ──
  # No usable recorded URL reached this point (the reuse block above would have
  # returned otherwise). Before creating, ask GitHub whether this branch already has
  # an OPEN PR — an UNGATED read (`gh pr view` accepts a branch selector). We filter
  # on state==OPEN deliberately: `gh pr create` only fails when an OPEN PR already
  # exists for the head, so that is the only case recovery must cover. A MERGED/CLOSED
  # PR must NOT be resurrected here — `gh pr view <branch>` resolves a branch's PR
  # regardless of state, and reusing a merged/closed one would skip create and leave a
  # re-run's new commits with NO open reviewable PR. This sits AFTER the --write-off
  # dry return above, so with --write off it never runs and parity stays byte-
  # identical. Found (OPEN) → re-persist the URL and reuse (idempotent); otherwise →
  # fall through to create exactly as before.
  local recovered
  recovered="$(gh pr view "$branch" --json url,state -q 'select(.state == "OPEN") | .url' 2>/dev/null)" || true
  if [[ -n "$recovered" ]]; then
    printf '%s\n' "$recovered" > "$pr_file"
    log_info "[pr] recovered existing OPEN PR (idempotent): $recovered (recorded → $pr_file)"
    return 0
  fi

  local url
  url="$(gh_pr_op pr create --draft --base main --head "$branch" \
    --title "$title" --body-file "$body_file")" || {
    log_error "[pr] gh pr create failed for $branch — leaving no URL file"; return 1; }
  printf '%s\n' "$url" > "$pr_file"
  log_success "[pr] draft PR opened: $url (recorded → $pr_file)"
}
# <<< RALPH ISSUE PR <<<

# ──── Self-updating issue comment (issue #1, slice c) ────
# Once the draft PR exists (slice b), the loop keeps the human informed where they
# live — on the issue itself — via ONE comment it edits in place across the run. The
# body is rendered from LOCAL state only (the PR URL in docs/prd/issue-N-pr.txt, the
# STORIES_COMPLETED / TOTAL_STORIES counters, the current story) and wrapped in a
# single HTML-comment fence (`<!-- RALPH:BEGIN -->` … `<!-- RALPH:END -->`). Status
# vocabulary (issue #1 step 3): 🔵 planning → 🟡 building story X/Y → 🟢 done (+ PR link).
#
# Idempotency (ADR-001 I2): ONE comment, found by the BEGIN marker and edited in
# place; the fenced block is regenerated from local git state on EVERY call, so any
# number of call sites (intake, per story, completion) CONVERGE on the same single
# comment instead of posting duplicates. FAIL CLOSED: if the loop-managed region in
# an existing comment has zero / duplicated / unbalanced fences, the edit is aborted
# (nothing written) and the build continues — the loop never writes a body it cannot
# round-trip and never clobbers human content OUTSIDE the fences.
#
# Reads are UNGATED (like slice b's `gh pr view`): listing the issue's comments to
# find the marker mutates nothing. WRITES (create + edit) funnel through gh_comment_op
# (the slice-1 guarded helper); with --write OFF the whole upsert is a dry no-op —
# it logs `[dry] gh …` and touches neither the comment list nor the network, so
# externally observable behavior stays byte-identical to read-only Path A (mirroring
# ensure_issue_pr's --write-off branch). The body is always passed via a FILE
# (`--body-file` on create; `-F body=@file` on edit) for byte/newline safety, never
# inline. gh-only — no octokit/REST (design §6); `gh api` is the gh CLI's own API
# passthrough, not a separate client. Never auto-merge / auto-close (I3): a comment
# does neither.
#
# Sourced standalone (alongside the RALPH WRITE GUARDS block, for gh_comment_op) by
# the offline smoke (tests/slice-c-issue-comment-smoke.sh), so keep self-contained:
# reference only GITHUB_WRITE, ISSUE_NUMBER, REPO_SLUG, REPO_ROOT, STORIES_COMPLETED,
# TOTAL_STORIES, CURRENT_STORY_IDX, STORY_LIST, the gh_comment_op helper, git/gh/jq,
# and log_*.
# >>> RALPH ISSUE COMMENT (issue #1 slice c) — do not remove the sentinels >>>
RALPH_COMMENT_BEGIN='<!-- RALPH:BEGIN -->'
RALPH_COMMENT_END='<!-- RALPH:END -->'

render_issue_comment_block() {
  # PURE render: the whole input is the argument vector (no global reads, no file
  # reads), so the block is deterministic by construction — same inputs yield
  # byte-identical output, which is what makes re-runs converge (I2). The CALLER
  # resolves local state (PR url, counters) and passes it in.
  #   $1 phase: planning | building | done
  #   $2 issue number   $3 stories completed   $4 total stories
  #   $5 current story id (may be empty)   $6 PR url (may be empty)
  local phase="$1" issue="$2" completed="$3" total="$4" current="$5" pr_url="$6"
  local status
  case "$phase" in
    building) status="🟡 building — story ${current:-?} (${completed}/${total} done)" ;;
    done)     status="🟢 done — ${completed}/${total} stories" ;;
    *)        status="🔵 planning — ${completed}/${total} stories" ;;
  esac
  printf '%s\n' "$RALPH_COMMENT_BEGIN"
  printf '**🤖 Ralph Loop** · issue #%s\n\n' "$issue"
  printf '%s\n' "$status"
  if [[ -n "$pr_url" ]]; then
    printf '\nPR: %s\n' "$pr_url"
  fi
  printf '%s\n' "$RALPH_COMMENT_END"
}

splice_managed_block() {
  # PURE fail-closed splice. Replace the single fenced region in an existing comment
  # body with a freshly rendered block, preserving every byte OUTSIDE the fences.
  #   $1 existing-body file   $2 new-block file
  # Emits the spliced body on stdout, returns 0 on success. FAIL CLOSED: unless the
  # existing body holds EXACTLY one BEGIN and one END marker (each on its own line)
  # with BEGIN strictly before END, write NOTHING and return 1 — the caller then
  # aborts the edit and lets the build continue (I2). Whole-line anchored matching
  # means a marker mentioned inside prose can never be mistaken for a fence.
  local existing="$1" block="$2"
  local begin_n end_n begin_line end_line
  begin_n="$(grep -c "^${RALPH_COMMENT_BEGIN}$" "$existing" 2>/dev/null || true)"
  end_n="$(grep -c "^${RALPH_COMMENT_END}$" "$existing" 2>/dev/null || true)"
  if [[ "$begin_n" != "1" || "$end_n" != "1" ]]; then
    return 1
  fi
  begin_line="$(grep -n "^${RALPH_COMMENT_BEGIN}$" "$existing" | cut -d: -f1)"
  end_line="$(grep -n "^${RALPH_COMMENT_END}$" "$existing" | cut -d: -f1)"
  if [[ "$begin_line" -ge "$end_line" ]]; then
    return 1
  fi
  head -n "$((begin_line - 1))" "$existing"
  cat "$block"
  tail -n "+$((end_line + 1))" "$existing"
}

upsert_issue_comment() {
  # Create-or-edit the loop's ONE issue comment so the human sees current status.
  #   $1 phase: planning | building | done
  # Path A only — the caller guards on ISSUE_NUMBER. Best-effort: every path returns
  # 0 so a comment hiccup never fails the build. Idempotent + fail-closed (I2).
  local phase="$1"
  local pr_file="$REPO_ROOT/docs/prd/issue-${ISSUE_NUMBER}-pr.txt"
  local pr_url=""
  [[ -s "$pr_file" ]] && pr_url="$(head -n1 "$pr_file")"
  local current=""
  [[ "${CURRENT_STORY_IDX:--1}" -ge 0 ]] && current="${STORY_LIST[$CURRENT_STORY_IDX]:-}"

  local block_file; block_file="$(mktemp)"
  render_issue_comment_block "$phase" "$ISSUE_NUMBER" "${STORIES_COMPLETED:-0}" \
    "${TOTAL_STORIES:-0}" "$current" "$pr_url" > "$block_file"

  # ── --write OFF: dry no-op. Emit the intended write through the guarded helper
  #    (logs [dry] …) and stop — no comments read, no post/edit (mirrors slice b) ──
  if [[ "${GITHUB_WRITE:-0}" != "1" ]]; then
    gh_comment_op issue comment "$ISSUE_NUMBER" --body-file "$block_file"
    log_info "[comment] dry-run: status comment not posted/edited (enable with --write)"
    rm -f "$block_file"
    return 0
  fi

  # ── Resolve OWNER/NAME (the --repo global, else `gh repo view` — a READ) ──
  local slug="${REPO_SLUG:-}"
  if [[ -z "$slug" ]]; then
    slug="$(cd "$REPO_ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  if [[ -z "$slug" ]]; then
    log_warn "[comment] could not resolve repo slug — skipping issue comment"
    rm -f "$block_file"; return 0
  fi

  # ── Find the loop's existing comment by the BEGIN marker (READ — ungated) ──
  local comments_json existing_url
  comments_json="$(gh issue view "$ISSUE_NUMBER" --repo "$slug" --json comments 2>/dev/null || true)"
  existing_url=""
  if [[ -n "$comments_json" ]]; then
    existing_url="$(printf '%s' "$comments_json" \
      | jq -r --arg m "$RALPH_COMMENT_BEGIN" 'first(.comments[]? | select(.body | contains($m))) | .url // ""' 2>/dev/null || true)"
  fi

  local body_file; body_file="$(mktemp)"

  if [[ -z "$existing_url" ]]; then
    # ── No existing comment → CREATE one (body IS the rendered block) ──
    cp "$block_file" "$body_file"
    if gh_comment_op issue comment "$ISSUE_NUMBER" --repo "$slug" --body-file "$body_file"; then
      log_success "[comment] posted status comment (${phase})"
    else
      log_error "[comment] failed to post status comment — continuing build"
    fi
    rm -f "$block_file" "$body_file"
    return 0
  fi

  # ── Existing comment found → EDIT in place, splicing only the fenced region ──
  local existing_file; existing_file="$(mktemp)"
  printf '%s' "$comments_json" \
    | jq -r --arg m "$RALPH_COMMENT_BEGIN" 'first(.comments[]? | select(.body | contains($m))) | .body // ""' \
      2>/dev/null > "$existing_file" || true
  if ! splice_managed_block "$existing_file" "$block_file" > "$body_file"; then
    log_warn "[comment] managed fences missing/duplicated/unbalanced — aborting edit (fail-closed), build continues"
    rm -f "$block_file" "$body_file" "$existing_file"
    return 0
  fi
  local cid="${existing_url##*issuecomment-}"
  if [[ -z "$cid" || "$cid" == "$existing_url" ]]; then
    log_warn "[comment] could not derive comment id from '$existing_url' — aborting edit (fail-closed)"
    rm -f "$block_file" "$body_file" "$existing_file"
    return 0
  fi
  if gh_comment_op api --method PATCH "repos/${slug}/issues/comments/${cid}" -F body=@"$body_file"; then
    log_success "[comment] updated status comment in place (${phase})"
  else
    log_error "[comment] failed to update status comment — continuing build"
  fi
  rm -f "$block_file" "$body_file" "$existing_file"
  return 0
}
# <<< RALPH ISSUE COMMENT <<<

# ──── Verdict-gated issue labels (issue #1, slice d) ────
# The loop projects its build state onto the issue as a single `ralph:` status label,
# so a human scanning the issue list sees where each issue stands without opening it.
# Exactly ONE ralph: status label is present at a time (issue #1 step 4 vocabulary):
#   ralph:building   — build started (set at the Phase 0 gate, beside the 🔵 planning comment)
#   ralph:needs-fix  — latest review verdict was REVIEW_FAILED (the loop is fixing it)
#   ralph:in-review  — latest review verdict was REVIEW_PASSED (ready for a human)
#   ralph:done       — every story green (set at main()'s completion section)
# Three STAGE labels arrived with issue #2 (Triage / Idea 4) and share this same single
# `ralph:` status namespace, so the array below is now SEVEN (four build + three stage):
#   ralph:ready         — Triage promoted the issue into Phase 0
#   ralph:needs-triage  — Triage found it underspecified (clarifying questions posted)
#   ralph:blocked       — Triage flagged it out-of-scope/duplicate (a human decides; I3)
# Keeping them in ONE array preserves the "exactly ONE ralph: label at a time" invariant
# GLOBALLY — set_issue_label removes every OTHER array label in its single-edit transition.
# The per-story labels are driven off the SAME first-line REVIEW_PASSED/REVIEW_FAILED
# contract that is_review_passed() reads — wired at the existing verdict decision points
# in main(). This is issue #1's NARROW machine only; the richer triage / loop:* state
# machine in design §4 is issue #7's territory and SUPERSEDES this (design §11), so this
# slice introduces none of that vocabulary.
#
# Idempotency (ADR-001 I2): every transition is a SINGLE `gh issue edit` that adds NEW
# and removes every OTHER ralph status label currently present — one atomic call, never
# split add/remove across invocations, so a crash mid-transition still lands the terminal
# state. Before firing, an UNGATED read of the issue's current labels lets the helper SKIP
# when NEW is already the sole ralph status label, so a re-run of a finished issue issues
# ZERO label writes (converge, never churn). Only the `ralph:` namespace is ever touched —
# human / non-ralph labels are never added or removed.
#
# Writes funnel through gh_label_op (the slice-1 guarded helper); with --write OFF the
# whole transition is a dry no-op — it logs `[dry] gh issue edit …`, reads nothing, changes
# nothing — so externally observable behavior stays byte-identical to read-only Path A
# (mirrors ensure_issue_pr / upsert_issue_comment). gh-only — no octokit/REST (`gh issue
# edit` / `gh label` are the gh CLI itself). Never auto-merge / auto-close (I3): a label
# does neither.
#
# Sourced standalone (alongside the RALPH WRITE GUARDS block, for gh_label_op) by the
# offline smoke (tests/slice-d-verdict-labels-smoke.sh), so keep self-contained: reference
# only GITHUB_WRITE, ISSUE_NUMBER, REPO_SLUG, REPO_ROOT, the gh_label_op helper, gh, and log_*.
# >>> RALPH ISSUE LABEL (issue #1 slice d) — do not remove the sentinels >>>
RALPH_STATUS_LABELS=(ralph:building ralph:needs-fix ralph:in-review ralph:done ralph:ready ralph:needs-triage ralph:blocked)

_resolve_repo_slug() {
  # OWNER/NAME via the --repo global, else `gh repo view` (a READ) — exactly as
  # upsert_issue_comment resolves it. Emits the slug (possibly empty) on stdout.
  local slug="${REPO_SLUG:-}"
  if [[ -z "$slug" ]]; then
    slug="$(cd "$REPO_ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  printf '%s' "$slug"
}

ensure_ralph_labels() {
  # Idempotently ensure the seven ralph: status labels EXIST in the repo (four build +
  # three stage labels added by issue #2 Triage), so a live
  # --write-on `gh issue edit --add-label` can never fail on a missing label (the offline
  # smoke can't catch that — same live-path caveat as slice b's `gh pr create` and slice
  # c's `gh api PATCH`). Reads (label list) are ungated; creates funnel through gh_label_op
  # (gated). NO-CHURN: only labels that are actually missing are created, so a re-run on a
  # fully-labelled repo writes nothing.
  if [[ "${GITHUB_WRITE:-0}" != "1" ]]; then
    # --write off: emit the intended creates through the guarded helper (dry) and stop.
    local l
    for l in "${RALPH_STATUS_LABELS[@]}"; do gh_label_op label create "$l"; done
    return 0
  fi
  local slug; slug="$(_resolve_repo_slug)"
  if [[ -z "$slug" ]]; then
    log_warn "[label] could not resolve repo slug — skipping label ensure"
    return 0
  fi
  local existing
  existing="$(gh label list --repo "$slug" --limit 200 --json name -q '.[].name' 2>/dev/null || true)"
  local l
  for l in "${RALPH_STATUS_LABELS[@]}"; do
    if ! grep -qxF "$l" <<< "$existing"; then
      if gh_label_op label create "$l" --repo "$slug" --description "Ralph Loop status (issue #1)"; then
        log_info "[label] created repo label $l"
      else
        log_warn "[label] could not create repo label $l — a later add-label may fail"
      fi
    fi
  done
}

set_issue_label() {
  # Transition the issue to exactly ONE ralph: status label in a SINGLE `gh issue edit`
  # (add NEW + remove every OTHER ralph status label currently present) — ADR-001 I2's
  # "single call per transition, never split add/remove." Idempotent: SKIP when NEW is
  # already the sole ralph status label (zero churn on re-run). Best-effort: always returns
  # 0 so a label hiccup never fails the build. Never auto-merge / auto-close (I3).
  #   $1 NEW status label (one of RALPH_STATUS_LABELS)
  local new="$1"

  # --write OFF: dry no-op. Emit the intended single edit through the guarded helper
  # (logs `[dry] gh issue edit …`) and stop — no labels read, nothing changed — so
  # behavior is byte-identical to read-only Path A (mirrors slice c's --write-off branch).
  if [[ "${GITHUB_WRITE:-0}" != "1" ]]; then
    gh_label_op issue edit "$ISSUE_NUMBER" --add-label "$new"
    log_info "[label] dry-run: status label not changed (enable with --write)"
    return 0
  fi

  local slug; slug="$(_resolve_repo_slug)"
  if [[ -z "$slug" ]]; then
    log_warn "[label] could not resolve repo slug — skipping label transition"
    return 0
  fi

  # READ the issue's current labels (UNGATED, like slice c's comment read) ──
  local current
  current="$(gh issue view "$ISSUE_NUMBER" --repo "$slug" --json labels -q '.labels[].name' 2>/dev/null || true)"

  # Partition the ralph status namespace: is NEW already present, and which OTHER ralph
  # status labels must be removed to keep exactly one present? (Human / non-ralph labels
  # are outside this loop, so they are never touched.) ──
  local -a to_remove=()
  local new_present=false
  local l
  for l in "${RALPH_STATUS_LABELS[@]}"; do
    if grep -qxF "$l" <<< "$current"; then
      if [[ "$l" == "$new" ]]; then new_present=true; else to_remove+=("$l"); fi
    fi
  done

  # Converged → SKIP (no churn): NEW is already the sole ralph status label ──
  if $new_present && [[ ${#to_remove[@]} -eq 0 ]]; then
    log_info "[label] already $new — no transition (idempotent)"
    return 0
  fi

  # The SINGLE transition: add NEW + remove every other ralph status label, one call ──
  local -a args=(issue edit "$ISSUE_NUMBER" --repo "$slug" --add-label "$new")
  if [[ ${#to_remove[@]} -gt 0 ]]; then
    for l in "${to_remove[@]}"; do
      args+=(--remove-label "$l")
    done
  fi
  if gh_label_op "${args[@]}"; then
    log_success "[label] → $new (removed: ${to_remove[*]:-none})"
  else
    log_error "[label] failed to set $new — continuing build"
  fi
  return 0
}
# <<< RALPH ISSUE LABEL <<<

# ──── Finish: graduate the draft PR to ready-for-review (issue #1 finish slice) ────
# On all stories green, step 5 of prd.md §3 Idea 1: `gh pr ready` on the draft PR slice
# b opened. This is the ONE PR-state graduation ADR-001 allows — `gh pr ready` converts
# a DRAFT PR to ready-for-review; it is NEITHER a merge NOR a close, so it does NOT
# violate invariant I3 (the human's thumb stays on the merge button). The "final issue
# comment linking the PR" half of step 5 is ALREADY delivered by slice c's
# `upsert_issue_comment done` (its 🟢 body links the PR), wired at the same completion
# call site — so the finish slice adds NO second comment (I2's one-self-updating-comment
# rule). This slice's only NEW behavior is readying the PR.
#
# Idempotency (ADR-001 I2): the PR URL is read from docs/prd/issue-N-pr.txt (the file
# slice b persisted). An UNGATED `gh pr view … --json isDraft` read decides whether any
# write is needed: if the PR is already NOT a draft (already readied, or a re-run of a
# finished issue), SKIP — zero writes, no churn. The single mutation `gh pr ready`
# funnels through gh_pr_op (the slice-1 guarded helper). A missing URL file or a 404 PR
# → best-effort log+skip (return 0): readying never fails the build.
#
# Never auto-merge / auto-close (I3): `gh pr ready` ONLY — never `gh pr merge`,
# `gh pr close`, or `gh issue close`.
#
# Sourced standalone (alongside the RALPH WRITE GUARDS block, for gh_pr_op) by the
# offline smoke (tests/slice-e-pr-ready-smoke.sh), so keep self-contained: reference
# only GITHUB_WRITE, ISSUE_NUMBER, REPO_ROOT, the gh_pr_op helper, gh, and log_*.
# >>> RALPH ISSUE READY (issue #1 finish) — do not remove the sentinels >>>
mark_issue_pr_ready() {
  local pr_file="$REPO_ROOT/docs/prd/issue-${ISSUE_NUMBER}-pr.txt"

  # --write OFF: dry no-op. Mirror ensure_issue_pr's --write-off branch — emit the
  # intended `gh pr ready` through the guarded helper (logs `[dry] gh pr ready …`), skip
  # the isDraft read entirely, change nothing — byte-identical to read-only Path A. The
  # URL file may not exist with --write off (slice b never opened the PR), so select the
  # PR by its branch (a valid `gh pr ready` selector, always known, no file read).
  if [[ "${GITHUB_WRITE:-0}" != "1" ]]; then
    gh_pr_op pr ready "ralph/issue-${ISSUE_NUMBER}"
    log_info "[pr] dry-run: draft PR not readied (enable with --write)"
    return 0
  fi

  # --write ON. Read the recorded PR URL (a LOCAL read, like slice b's idempotency
  # check). Missing/empty → best-effort skip; readying never fails the build.
  if [[ ! -s "$pr_file" ]]; then
    log_warn "[pr] no recorded PR URL ($pr_file) — skipping ready (best-effort)"
    return 0
  fi
  local url
  url="$(head -n1 "$pr_file")"

  # Idempotency (I2): an UNGATED read of the PR's draft state (`gh pr view` is a READ,
  # like slice b's reuse check). A 404 (PR gone) → best-effort skip. Already NOT a draft
  # (already readied / re-run of a finished issue) → skip, ZERO churn.
  local is_draft
  if ! is_draft="$(gh pr view "$url" --json isDraft -q .isDraft 2>/dev/null)"; then
    log_warn "[pr] recorded PR not found ($url) — skipping ready (best-effort)"
    return 0
  fi
  if [[ "$is_draft" != "true" ]]; then
    log_info "[pr] PR already ready-for-review ($url) — no transition (idempotent)"
    return 0
  fi

  # The single mutation: graduate the draft to ready-for-review (network → gated via
  # gh_pr_op). NEVER merge/close (I3). Best-effort: a hiccup never fails the build.
  if gh_pr_op pr ready "$url"; then
    log_success "[pr] draft PR graduated to ready-for-review: $url"
  else
    log_error "[pr] gh pr ready failed for $url — continuing build"
  fi
  return 0
}
# <<< RALPH ISSUE READY <<<

# ──── Triage before toil (issue #2, Idea 4 — the judgment gate) ────
# A readiness PRE-PHASE that runs BEFORE Phase 0 in Path A. It deterministically
# classifies the issue (ready | needs-info | wontfix-candidate | excluded), records
# the classification to a LOCAL ledger, labels the issue's stage, posts clarifying
# questions when it is underspecified, and promotes ONLY `ready` issues into Phase 0.
# Everything here is ADDITIVE — the existing loop semantics are untouched — and it is
# the cheapest guard against the loop confidently BUILDING THE WRONG THING once
# write-back (issue #1) exists. See prd.md §3 Idea 4, §5, §6; issue 04-triage-before-toil.
#
# Invariant mapping (ADR-001):
#   I1 — --write default-off: every GitHub WRITE funnels through gh_comment_op /
#        gh_label_op (via set_issue_label / ensure_ralph_labels); with --write off the
#        stage is DARK — classification is still logged and the local ledger still
#        appended, but labels/comments are dry no-ops. The gate (promote/park) applies
#        regardless of --write, so read-only runs still refuse to build unready issues.
#   I2 — idempotency: the triage comment is ONE comment, found by its BEGIN marker and
#        edited in place (distinct TRIAGE fences, independent of slice-c's build-status
#        comment); the stage label is a single-edit transition; a re-run of a promoted
#        (ralph:ready) issue makes ZERO writes.
#   I3 — the loop NEVER closes: a wontfix-candidate is flagged for a human, never closed.
#
# Sourced standalone (alongside the RALPH WRITE GUARDS block for gh_comment_op/gh_label_op,
# and the RALPH ISSUE LABEL block for set_issue_label/ensure_ralph_labels/_resolve_repo_slug)
# by the offline smoke (tests/idea4-triage-smoke.sh), so keep self-contained: reference only
# GITHUB_WRITE, ISSUE_NUMBER, REPO_SLUG, REPO_ROOT, TRIAGE_MODE, EPIC_FILE, the
# gh_comment_op/gh_label_op helpers, set_issue_label, ensure_ralph_labels, _resolve_repo_slug,
# gh/jq, and log_*.
# >>> RALPH TRIAGE (issue #2) — do not remove the sentinels >>>
RALPH_TRIAGE_BEGIN='<!-- RALPH:TRIAGE:BEGIN -->'
RALPH_TRIAGE_END='<!-- RALPH:TRIAGE:END -->'

triage_classify() {
  # PURE deterministic classifier — the "deterministic given the issue content" AC.
  # No global reads, no file reads, no gh, no randomness: same inputs ⇒ byte-identical
  # output. Inputs are the whole argument vector:
  #   $1 title   $2 body   $3 labels (newline-separated)
  # stdout:
  #   line 1     : ready | needs-info | wontfix-candidate | excluded
  #   then 0+    : "reason: …" lines (why it classified that way)
  #   then 0+    : "question: …" lines (needs-info only, derived from MISSING signals)
  local title="$1" body="$2" labels="$3"

  local labels_lc title_lc
  labels_lc="$(printf '%s' "$labels" | tr '[:upper:]' '[:lower:]')"
  title_lc="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"

  # Case-insensitive whole-label test against the newline-separated label list.
  _triage_has_label() { grep -qxF "$1" <<< "$labels_lc"; }

  # ── Rule 1: roadmap → excluded (scan-exclusion guard, prd.md §6) ──
  if _triage_has_label roadmap; then
    printf 'excluded\n'
    printf 'reason: carries the roadmap label — a planning issue the loop must not act on; a human promotes it by adding ralph:ready.\n'
    return 0
  fi

  # ── Rule 2: wontfix / duplicate / invalid → wontfix-candidate ──
  if _triage_has_label wontfix || _triage_has_label duplicate || _triage_has_label invalid; then
    printf 'wontfix-candidate\n'
    printf 'reason: labelled wontfix/duplicate/invalid — looks out-of-scope or already-handled; a human decides (the loop never closes, I3).\n'
    return 0
  fi

  # ── Rule 3: score readiness (integers only — no floats) ──
  # Trim leading/trailing whitespace, then measure length (internal spaces kept).
  local body_trimmed
  body_trimmed="$body"
  body_trimmed="${body_trimmed#"${body_trimmed%%[![:space:]]*}"}"
  body_trimmed="${body_trimmed%"${body_trimmed##*[![:space:]]}"}"
  local body_len=${#body_trimmed}
  local body_lc
  body_lc="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')"

  # Signals (recorded so the questions can be derived from the ones that are MISSING).
  local has_len140=false has_len400=false has_md=false has_accept=false
  local has_title20=false is_question=false has_bug=false has_repro=false
  [[ $body_len -ge 140 ]] && has_len140=true
  [[ $body_len -ge 400 ]] && has_len400=true
  grep -qE '^#|^[-*] |^[[:space:]]*[-*] \[[ xX]\]' <<< "$body" && has_md=true
  # Word-boundary (\b) anchored so short keywords match only as whole words — otherwise
  # 'repro' hits reprogram/reprocess and 'goal' hits goalkeeper, scoring unrelated prose as
  # an acceptance-criteria signal and false-promoting an underspecified issue into Phase 0.
  grep -qE '\b(acceptance|expected|criteria|steps to reproduce|repro|goal|so that|in order to)\b' <<< "$body_lc" && has_accept=true
  [[ ${#title} -ge 20 ]] && has_title20=true
  { [[ "$title" == *'?' ]] || grep -qE '^(how|why|what|help|question)([^a-z]|$)' <<< "$title_lc"; } && is_question=true
  _triage_has_label bug && has_bug=true
  grep -qE '\b(steps to reproduce|repro)\b' <<< "$body_lc" && has_repro=true

  local score=0
  $has_len140 && score=$((score + 2))
  $has_len400 && score=$((score + 1))
  $has_md     && score=$((score + 2))
  $has_accept && score=$((score + 2))
  $has_title20 && score=$((score + 1))
  $is_question && score=$((score - 3))

  if [[ $score -ge 5 ]]; then
    printf 'ready\n'
    printf 'reason: readiness score %s (>= 5 promotes) — the issue carries enough structure and detail to plan.\n' "$score"
    return 0
  fi

  # ── needs-info: emit the questions derived from MISSING signals, fixed order ──
  printf 'needs-info\n'
  printf 'reason: readiness score %s (< 5) — underspecified; clarifying questions below.\n' "$score"
  $has_len140 || printf 'question: The issue body is very brief — can you describe the problem or goal in more detail?\n'
  $has_accept || printf 'question: What does success look like? Please add expected behavior or acceptance criteria.\n'
  { $has_bug && ! $has_repro; } && printf 'question: Can you add steps to reproduce?\n'
  $has_md || printf "question: A short bullet list of what's in and out of scope would help the loop plan this.\n"
  return 0
}

splice_triage_block() {
  # PURE fail-closed splice against the TRIAGE fences (a local copy of slice-c's
  # whole-line-anchored splicer, so this block stays standalone-sourceable). Replace
  # the single fenced region in an existing comment body with a freshly rendered block,
  # preserving every byte OUTSIDE the fences.
  #   $1 existing-body file   $2 new-block file
  # Emits the spliced body on stdout, returns 0. FAIL CLOSED: unless the body holds
  # EXACTLY one BEGIN and one END marker (each on its own line) with BEGIN strictly
  # before END, write NOTHING and return 1.
  local existing="$1" block="$2"
  local begin_n end_n begin_line end_line
  begin_n="$(grep -c "^${RALPH_TRIAGE_BEGIN}$" "$existing" 2>/dev/null || true)"
  end_n="$(grep -c "^${RALPH_TRIAGE_END}$" "$existing" 2>/dev/null || true)"
  if [[ "$begin_n" != "1" || "$end_n" != "1" ]]; then
    return 1
  fi
  begin_line="$(grep -n "^${RALPH_TRIAGE_BEGIN}$" "$existing" | cut -d: -f1)"
  end_line="$(grep -n "^${RALPH_TRIAGE_END}$" "$existing" | cut -d: -f1)"
  if [[ "$begin_line" -ge "$end_line" ]]; then
    return 1
  fi
  head -n "$((begin_line - 1))" "$existing"
  cat "$block"
  tail -n "+$((end_line + 1))" "$existing"
}

upsert_triage_comment() {
  # Create-or-edit the loop's ONE triage comment carrying the classification + clarifying
  # questions, wrapped in the TRIAGE fences (distinct from slice-c's build-status fences,
  # so the two comments converge independently). Best-effort: every path returns 0 so a
  # comment hiccup never fails the gate. Idempotent + fail-closed (I2). Body-by-file always.
  #   $1 classification   $2 full triage_classify output (line 1 + reason:/question: lines)
  local classification="$1" classify_out="$2"

  # ── Render the fenced body from LOCAL args only (pure) ──
  local block_file; block_file="$(mktemp)"
  {
    printf '%s\n' "$RALPH_TRIAGE_BEGIN"
    printf '**🤖 Ralph Loop — triage** · issue #%s\n\n' "$ISSUE_NUMBER"
    printf '**Classification:** `%s`\n' "$classification"
    # reason: lines → bullets
    local had_reason=false
    while IFS= read -r line; do
      case "$line" in
        reason:\ *)
          $had_reason || { printf '\nWhy:\n'; had_reason=true; }
          printf -- '- %s\n' "${line#reason: }" ;;
      esac
    done <<< "$classify_out"
    # question: lines → numbered list
    local qn=0 line
    while IFS= read -r line; do
      case "$line" in
        question:\ *)
          [[ $qn -eq 0 ]] && printf '\nPlease edit the issue to answer these so the loop can build it:\n'
          qn=$((qn + 1))
          printf '%s. %s\n' "$qn" "${line#question: }" ;;
      esac
    done <<< "$classify_out"
    printf '%s\n' "$RALPH_TRIAGE_END"
  } > "$block_file"

  # ── --write OFF: dry no-op — emit the intended write through the guarded helper ──
  if [[ "${GITHUB_WRITE:-0}" != "1" ]]; then
    gh_comment_op issue comment "$ISSUE_NUMBER" --body-file "$block_file"
    log_info "[triage] dry-run: triage comment not posted/edited (enable with --write)"
    rm -f "$block_file"
    return 0
  fi

  # ── Resolve OWNER/NAME (the --repo global, else `gh repo view` — a READ) ──
  local slug; slug="$(_resolve_repo_slug)"
  if [[ -z "$slug" ]]; then
    log_warn "[triage] could not resolve repo slug — skipping triage comment"
    rm -f "$block_file"; return 0
  fi

  # ── Find the loop's existing triage comment by the BEGIN marker (READ — ungated) ──
  local comments_json existing_url
  comments_json="$(gh issue view "$ISSUE_NUMBER" --repo "$slug" --json comments 2>/dev/null || true)"
  existing_url=""
  if [[ -n "$comments_json" ]]; then
    existing_url="$(printf '%s' "$comments_json" \
      | jq -r --arg m "$RALPH_TRIAGE_BEGIN" 'first(.comments[]? | select(.body | contains($m))) | .url // ""' 2>/dev/null || true)"
  fi

  local body_file; body_file="$(mktemp)"

  if [[ -z "$existing_url" ]]; then
    # ── No existing comment → CREATE one (body IS the rendered block) ──
    cp "$block_file" "$body_file"
    if gh_comment_op issue comment "$ISSUE_NUMBER" --repo "$slug" --body-file "$body_file"; then
      log_success "[triage] posted triage comment (${classification})"
    else
      log_error "[triage] failed to post triage comment — continuing"
    fi
    rm -f "$block_file" "$body_file"
    return 0
  fi

  # ── Existing comment found → EDIT in place, splicing only the fenced region ──
  local existing_file; existing_file="$(mktemp)"
  printf '%s' "$comments_json" \
    | jq -r --arg m "$RALPH_TRIAGE_BEGIN" 'first(.comments[]? | select(.body | contains($m))) | .body // ""' \
      2>/dev/null > "$existing_file" || true
  if ! splice_triage_block "$existing_file" "$block_file" > "$body_file"; then
    log_warn "[triage] managed fences missing/duplicated/unbalanced — aborting edit (fail-closed), continuing"
    rm -f "$block_file" "$body_file" "$existing_file"
    return 0
  fi
  local cid="${existing_url##*issuecomment-}"
  if [[ -z "$cid" || "$cid" == "$existing_url" ]]; then
    log_warn "[triage] could not derive comment id from '$existing_url' — aborting edit (fail-closed)"
    rm -f "$block_file" "$body_file" "$existing_file"
    return 0
  fi
  if gh_comment_op api --method PATCH "repos/${slug}/issues/comments/${cid}" -F body=@"$body_file"; then
    log_success "[triage] updated triage comment in place (${classification})"
  else
    log_error "[triage] failed to update triage comment — continuing"
  fi
  rm -f "$block_file" "$body_file" "$existing_file"
  return 0
}

triage_ledger_append() {
  # Measurability AC: append `<epoch>\t<issue>\t<classification>` to
  # $REPO_ROOT/.ralph/triage-ledger.tsv — the raw data for offline triage-precision
  # measurement (% of `ready` issues whose PR later merges; computed by a human).
  # LOCAL state, written REGARDLESS of --write; `.ralph/` is gitignored. Best-effort.
  local classification="$1"
  # Prefer the MAIN root so the ledger stays central even after --worktree re-points
  # REPO_ROOT into the worktree (issue #4). RALPH_MAIN_ROOT is empty in non-worktree
  # runs, so this falls back to REPO_ROOT — unchanged behavior. Either way .ralph/ is
  # gitignored.
  local dir="${RALPH_MAIN_ROOT:-$REPO_ROOT}/.ralph"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s\t%s\t%s\n' "$(date +%s)" "$ISSUE_NUMBER" "$classification" >> "$dir/triage-ledger.tsv" 2>/dev/null || true
  return 0
}

triage_park() {
  # Mirror phase0_park's shape, triage-flavored: log the reason + what the human should
  # do next, then exit 2. No progress file exists at triage time, so nothing to refresh.
  local msg="$1"
  log_error "[Triage] $msg"
  log_error "[Triage] Answer the clarifying questions on the issue, then re-run with --triage always after editing — or bypass triage entirely with --triage never."
  exit 2
}

run_triage_phase() {
  # The orchestrator: classify → ledger → label the stage → promote or park.
  # 1. --triage never → skip entirely.
  if [[ "${TRIAGE_MODE:-auto}" == "never" ]]; then
    log_info "[Triage] skipped (--triage never)"
    return 0
  fi
  # 2. Epic already present → the issue was promoted once; Phase 0 will resume.
  if [[ -f "$EPIC_FILE" ]]; then
    log_info "[Triage] epic already exists — issue already promoted; resuming into Phase 0."
    return 0
  fi
  # 3. Pre-flight gh (exactly like run_intake_phase), resolve the repo slug.
  command -v gh >/dev/null 2>&1 || {
    log_error "Path A (--issue) requires the GitHub CLI 'gh' on PATH. Install: https://cli.github.com/"; exit 1; }
  if ! gh auth status >/dev/null 2>&1; then
    log_error "Path A: 'gh' is not authenticated. Run: gh auth login"; exit 1
  fi
  local slug; slug="$(_resolve_repo_slug)"
  [[ -z "$slug" ]] && triage_park "could not determine the GitHub repo — pass --repo OWNER/NAME (or set a default with: gh repo set-default)."

  # 4. Fetch the issue (a READ — ungated).
  local issue_json
  issue_json="$(gh issue view "$ISSUE_NUMBER" --repo "$slug" --json title,body,labels 2>/dev/null)" \
    || triage_park "could not fetch issue #${ISSUE_NUMBER} from ${slug}. Does it exist and is it accessible to your gh account?"
  [[ -z "$issue_json" ]] && triage_park "empty response fetching issue #${ISSUE_NUMBER} from ${slug}."

  local title body labels
  title="$(printf '%s' "$issue_json" | jq -r '.title // ""')"
  body="$(printf '%s' "$issue_json" | jq -r '.body // ""')"
  labels="$(printf '%s' "$issue_json" | jq -r '.labels[]?.name // empty')"

  # 5. Fast-path (I2 converge): already promoted (ralph:ready) and mode != always → proceed
  #    into Phase 0 with ZERO writes.
  if [[ "${TRIAGE_MODE:-auto}" != "always" ]] && grep -qxF 'ralph:ready' <<< "$labels"; then
    log_info "[Triage] issue #${ISSUE_NUMBER} already promoted (ralph:ready) — into Phase 0 (no writes)."
    return 0
  fi

  # 6. Classify (pure), log the verdict + each reason, append the local ledger row.
  local classify_out classification
  classify_out="$(triage_classify "$title" "$body" "$labels")"
  classification="${classify_out%%$'\n'*}"
  log_info "[Triage] issue #${ISSUE_NUMBER} classified: ${classification}"
  local rline
  while IFS= read -r rline; do
    [[ -z "$rline" ]] && continue
    log_dim "[Triage] ${rline}"
  done < <(printf '%s\n' "$classify_out" | tail -n +2)
  triage_ledger_append "$classification"

  # 7. Act on the classification.
  case "$classification" in
    ready)
      ensure_ralph_labels
      set_issue_label "ralph:ready"
      log_success "[Triage] issue #${ISSUE_NUMBER} is ready — promoting into Phase 0."
      return 0 ;;
    needs-info)
      upsert_triage_comment "$classification" "$classify_out"
      ensure_ralph_labels
      set_issue_label "ralph:needs-triage"
      triage_park "issue #${ISSUE_NUMBER} is underspecified — clarifying questions posted; not building." ;;
    wontfix-candidate)
      upsert_triage_comment "$classification" "$classify_out"
      ensure_ralph_labels
      set_issue_label "ralph:blocked"
      triage_park "issue #${ISSUE_NUMBER} looks out-of-scope/duplicate — flagged ralph:blocked; a human decides (the loop never closes, I3)." ;;
    excluded)
      # roadmap: the loop must NOT touch its own planning issues — ZERO labels, ZERO
      # comments (only the local ledger row above, which is fine). Human promotes it.
      triage_park "issue #${ISSUE_NUMBER} carries the roadmap label — excluded from the loop; a human promotes it deliberately by adding ralph:ready." ;;
    *)
      triage_park "issue #${ISSUE_NUMBER} could not be classified ('${classification}') — not building." ;;
  esac
}
# <<< RALPH TRIAGE <<<

# ──── The Confessing PR (issue #3, Idea 2 — the trust interface) ────
# Synthesise the draft PR's BODY from artifacts the loop already produces, so the PR
# reads like a careful colleague wrote it. The body opens with an "I had to guess"
# section (recorded assumptions/open questions, surfaced FIRST — that is where the
# human's judgment is actually needed), then a story → acceptance-criteria → commit
# map, then per-story narratives. Wired as ONE body update at completion, right before
# the draft PR graduates to ready (mark_issue_pr_ready), so the human reviews a
# confessing body — not the intake PRD ensure_issue_pr created the PR with. See
# prd.md §3 Idea 2; issue 02-confessing-pr.
#
# Invariant mapping (ADR-001):
#   I1 — --write default-off: the single GitHub WRITE (`gh pr edit --body-file`)
#        funnels through gh_pr_op; with --write off it is a dry no-op (the body is
#        still rendered to prove renderability, but nothing is sent).
#   I2 — idempotency: render_pr_body is a PURE function of on-disk artifacts + `git
#        log` (no gh, no globals, no timestamps, no $RANDOM), so the same disk state
#        yields a byte-identical body; `gh pr edit` is naturally idempotent, so a
#        re-run converges on the same PR body instead of duplicating anything.
#   I3 — the loop NEVER merges/closes: `gh pr edit` only edits the body.
#
# Sourced standalone (alongside the RALPH WRITE GUARDS block, for gh_pr_op) by the
# offline smoke (tests/idea2-confessing-pr-smoke.sh), so keep self-contained: reference
# only GITHUB_WRITE, ISSUE_NUMBER, REPO_ROOT, STORIES_DIR, EPIC_FILE, the gh_pr_op
# helper, git/gh, and log_*.
# >>> RALPH PR BODY (issue #3) — do not remove the sentinels >>>
_pr_guesses_from() {
  # Extract recorded assumptions / open questions from ONE artifact file.
  #   $1 file   $2 repo-relative path (for source attribution)
  # Emits `- <text> — _<src>_` lines. awk-only, pure; a missing file is the caller's
  # concern (it only calls this on files that exist).
  awk -v src="$2" '
    function emit(t) {
      sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
      if (t != "") print "- " t " — _" src "_"
    }
    {
      line = $0; low = tolower($0)
      if (line ~ /^#{2,4} /) {
        # A guess/assumption SECTION heading is ABOUT recorded assumptions / open
        # questions / risks / uncertainties — the keyword must END the heading text.
        # Anchoring to the end keeps "Risks" / "Open Questions" / "Recorded
        # Assumptions" while excluding resolved-work headings whose keyword is a mere
        # modifier ("Risk Mitigations", "Risk Assessment", "Assumptions Validated"),
        # so completed actions do not leak into the trust-critical section.
        htxt = low; sub(/^#{2,4}[[:space:]]*/, "", htxt); sub(/[[:space:]]+$/, "", htxt)
        if (htxt ~ /(assumptions?|open questions?|uncertaint(y|ies)|risks?|guess(es|ed)?)$/) inblk = 1; else inblk = 0
        next
      }
      # A standalone recorded-assumption LABEL: the keyword must be followed by a COLON
      # (`ASSUMPTION: …`, `Guess: …`, `Open question: …`) — a label, not a leading verb.
      # Requiring the colon rejects ordinary imperative prose like "guess the locale …".
      if (low ~ /^[[:space:]]*[-*>]?[[:space:]]*(assumption|guess|open question):/) {
        t = line; sub(/^[[:space:]]*[-*>]?[[:space:]]*/, "", t); emit(t); next
      }
      if (inblk == 1 && line ~ /^[[:space:]]*[-*] /) {
        t = line; sub(/^[[:space:]]*[-*] +/, "", t); sub(/^\[[ xX]\][[:space:]]+/, "", t); emit(t)
      }
    }
  ' "$1"
}

_pr_collect_guesses() {
  # Gather guesses across all sources in DETERMINISTIC order: PRD, then per story in
  # epic order (spec, then done). De-duplicates exact-duplicate rendered lines.
  #   $1 issue   $2 epic   $3 stories-dir   $4 repo-root   $5.. ordered story ids
  local issue="$1" epic="$2" sdir="$3" root="$4"; shift 4
  local -a sids=(${@+"$@"})
  local out="" sid f
  f="$root/docs/prd/issue-${issue}.md"
  [[ -f "$f" ]] && out+="$(_pr_guesses_from "$f" "${f#"$root"/}")"$'\n'
  if [[ ${#sids[@]} -gt 0 ]]; then
    for sid in "${sids[@]}"; do
      f="$sdir/${sid}.md";      [[ -f "$f" ]] && out+="$(_pr_guesses_from "$f" "${f#"$root"/}")"$'\n'
      f="$sdir/${sid}-done.md"; [[ -f "$f" ]] && out+="$(_pr_guesses_from "$f" "${f#"$root"/}")"$'\n'
    done
  fi
  printf '%s\n' "$out" | awk 'NF { if (!seen[$0]++) print }'
}

_pr_extract_acs() {
  # Bullet/checkbox lines under the first heading matching (ci) `acceptance criteria`,
  # read from stdin. Emits `- <text>` lines; nothing if no such heading/bullets.
  awk '
    BEGIN { inac = 0 }
    {
      line = $0; low = tolower($0)
      if (inac == 0) {
        if ((line ~ /^#{1,6} / || line ~ /^\*\*/) && low ~ /acceptance criteria/) inac = 1
        next
      }
      if (line ~ /^#{1,6} / || line ~ /^### Story /) { inac = 0; next }
      if (line ~ /^[[:space:]]*[-*] /) {
        t = line; sub(/^[[:space:]]*[-*] +/, "", t); sub(/^\[[ xX]\][[:space:]]+/, "", t)
        print "- " t
      }
    }
  '
}

_pr_epic_section() {
  # The lines of a story's own section inside the epic (### Story sid: … until the
  # next ### Story or ## heading). $1 epic   $2 story id.
  awk -v sid="$2" '
    { if ($0 ~ ("^### Story " sid ":")) { inb = 1; next }
      if (inb == 1 && ($0 ~ /^### Story / || $0 ~ /^## /)) inb = 0
      if (inb == 1) print
    }
  ' "$1"
}

_pr_narrative() {
  # First non-empty paragraph of a `-done.md`: preferring a `## Summary`-matching
  # heading, else after the FIRST heading of any level. Truncated to 400 chars with an
  # ellipsis. $1 file. (done.md is Dev-authored free-form — its title may be an H1, H2,
  # or any level — so the fallback anchors on the first heading, not just `# ` H1.)
  local f="$1" para=""
  [[ -f "$f" ]] || return 0
  # NB: awk's `exit` still runs END, so every flush resets p to avoid double-printing.
  para="$(awk '
    BEGIN { c = 0 }
    { if ($0 ~ /^#{1,6} /) {
        if (c == 1 && p != "") { print p; p = ""; exit }
        if (tolower($0) ~ /summary/) { c = 1; p = ""; next }
        if (c == 1) c = 0
        next
      }
      if (c == 1) {
        if ($0 ~ /^[[:space:]]*$/) { if (p != "") { print p; p = ""; exit }; next }
        if (p == "") p = $0; else p = p " " $0
      }
    }
    END { if (p != "") print p }
  ' "$f" 2>/dev/null || true)"
  if [[ -z "$para" ]]; then
    para="$(awk '
      BEGIN { c = 0; seen = 0 }
      { if ($0 ~ /^#{1,6} / && seen == 0) { c = 1; seen = 1; next }
        if (c == 1) {
          if ($0 ~ /^#{1,6} /)        { if (p != "") { print p; p = ""; exit }; next }
          if ($0 ~ /^[[:space:]]*$/)  { if (p != "") { print p; p = ""; exit }; next }
          if (p == "") p = $0; else p = p " " $0
        }
      }
      END { if (p != "") print p }
    ' "$f" 2>/dev/null || true)"
  fi
  [[ -z "$para" ]] && return 0
  if (( ${#para} > 400 )); then para="${para:0:400}…"; fi
  printf '%s\n' "$para"
}

render_pr_body() {
  # PURE function of on-disk artifacts + `git log` (AC 3/4). Args:
  #   $1 issue number   $2 epic file   $3 stories dir   $4 repo root
  # Reads ONLY those files + `git -C "$4" log`. NO gh, no globals, no timestamps, no
  # $RANDOM — same disk state ⇒ byte-identical output. Emits the PR body on stdout.
  local issue="$1" epic="$2" sdir="$3" root="$4"
  local -a sids=() stitles=()
  local hline sid title
  while IFS= read -r hline; do
    [[ -z "$hline" ]] && continue
    sid="$(sed -E 's/^### Story ([0-9]+\.[0-9]+):.*/\1/' <<<"$hline")"
    title="$(sed -E 's/^### Story [0-9]+\.[0-9]+:[[:space:]]*//' <<<"$hline")"
    sids+=("$sid"); stitles+=("$title")
  done < <(grep -E "^### Story ${issue}\.[0-9]+:" "$epic" 2>/dev/null || true)
  local k="${#sids[@]}"

  # ── Header ──
  printf 'Closes #%s.\n\n' "$issue"
  printf 'The Ralph Loop built this from issue #%s in %s stories.\n\n' "$issue" "$k"

  # ── "I had to guess" — the trust interface, always FIRST (AC 1: never silently empty) ──
  printf '## ⚠️ I had to guess\n\n'
  local guesses
  guesses="$(_pr_collect_guesses "$issue" "$epic" "$sdir" "$root" ${sids[@]+"${sids[@]}"})"
  if [[ -n "$guesses" ]]; then
    printf '%s\n\n' "$guesses"
  else
    printf '_No assumptions or open questions were recorded in the planning or story artifacts. Treat confident-looking sections with normal skepticism._\n\n'
  fi

  # ── Stories → acceptance criteria → commits (AC 2) ──
  printf '## Stories → acceptance criteria → commits\n\n'
  local i hashes cline h acs
  for ((i = 0; i < k; i++)); do
    sid="${sids[$i]}"; title="${stitles[$i]}"
    printf '### %s — %s\n\n' "$sid" "$title"
    hashes="$(git -C "$root" log --all --pretty='%h %s' 2>/dev/null \
      | awk -v pfx="feat(${sid}):" '{ h = $1; rest = substr($0, length($1) + 2); if (substr(rest, 1, length(pfx)) == pfx) print h }' || true)"
    if [[ -n "$hashes" ]]; then
      cline=""
      while IFS= read -r h; do [[ -z "$h" ]] && continue; cline+="\`$h\` "; done <<<"$hashes"
      printf 'Commit: %s\n\n' "${cline% }"
    else
      printf 'Commit: _(not yet committed)_\n\n'
    fi
    acs="$(cat "$sdir/${sid}.md" 2>/dev/null | _pr_extract_acs || true)"
    [[ -z "$acs" ]] && acs="$(_pr_epic_section "$epic" "$sid" | _pr_extract_acs || true)"
    if [[ -n "$acs" ]]; then
      printf '%s\n\n' "$acs"
    else
      printf '_(no acceptance criteria recorded)_\n\n'
    fi
  done

  # ── Story narratives ──
  printf '## Story narratives\n\n'
  local narr
  for ((i = 0; i < k; i++)); do
    sid="${sids[$i]}"; title="${stitles[$i]}"
    printf '### %s — %s\n\n' "$sid" "$title"
    narr="$(_pr_narrative "$sdir/${sid}-done.md")"
    [[ -z "$narr" ]] && narr='_(no implementation summary)_'
    printf '%s\n\n' "$narr"
  done

  # ── Footer ──
  printf -- '---\n\n'
  printf '_This body is generated by the Ralph Loop ("Confessing PR", prd.md §3 Idea 2) — regenerated deterministically from per-story artifacts at completion. The PR body is loop-owned until the PR is marked ready; edits above this line may be overwritten before then._\n'
}

update_issue_pr_body() {
  # Gated writer: replace the draft PR's body with the freshly rendered confessing body.
  # Best-effort — always returns 0 so a body hiccup never fails the build. Idempotent
  # (I2): same artifacts ⇒ same body ⇒ `gh pr edit` converges, never duplicates.
  # Human-edit safety (parity with mark_issue_pr_ready): the body is loop-owned ONLY
  # while the PR is a draft (render_pr_body's footer promises exactly this). Once the PR
  # is no longer a draft — already graduated to ready-for-review — a re-run SKIPS the
  # edit so human review edits to the ready body are never clobbered.
  local pr_file="$REPO_ROOT/docs/prd/issue-${ISSUE_NUMBER}-pr.txt"
  local body_file; body_file="$(mktemp)"
  render_pr_body "$ISSUE_NUMBER" "$EPIC_FILE" "$STORIES_DIR" "$REPO_ROOT" > "$body_file"

  # ── --write OFF: dry no-op. Render anyway (proves renderability), emit the intended
  #    write through the guarded helper (logs [dry] …), touch nothing (mirrors slice b) ──
  if [[ "${GITHUB_WRITE:-0}" != "1" ]]; then
    gh_pr_op pr edit "ralph/issue-${ISSUE_NUMBER}" --body-file "$body_file"
    log_info "[pr] dry-run: PR body not updated (enable with --write)"
    rm -f "$body_file"
    return 0
  fi

  # ── --write ON: read the recorded PR URL (a LOCAL read, like mark_issue_pr_ready).
  #    Missing/empty → best-effort skip; updating never fails the build. ──
  if [[ ! -s "$pr_file" ]]; then
    log_warn "[pr] no recorded PR URL ($pr_file) — skipping body update (best-effort)"
    rm -f "$body_file"
    return 0
  fi
  local url; url="$(head -n1 "$pr_file")"

  # Human-edit safety + idempotency (parity with mark_issue_pr_ready): an UNGATED read
  # of the PR's draft state (`gh pr view` is a READ). The body is loop-owned only while
  # the PR is a draft; once it is ready-for-review (already graduated — e.g. a --write
  # re-run of a finished issue) human review edits must NOT be clobbered, so skip the
  # edit. A 404 (PR gone) → best-effort skip. Zero writes on the ready PR ⇒ still
  # I2-idempotent (a re-run converges to no-op instead of overwriting).
  local is_draft
  if ! is_draft="$(gh pr view "$url" --json isDraft -q .isDraft 2>/dev/null)"; then
    log_warn "[pr] recorded PR not found ($url) — skipping body update (best-effort)"
    rm -f "$body_file"
    return 0
  fi
  if [[ "$is_draft" != "true" ]]; then
    log_info "[pr] PR already ready-for-review ($url) — body no longer loop-owned, skipping (idempotent)"
    rm -f "$body_file"
    return 0
  fi

  if gh_pr_op pr edit "$url" --body-file "$body_file"; then
    log_success "[pr] PR body updated to the confessing body: $url"
  else
    log_error "[pr] gh pr edit failed for $url — continuing"
  fi
  rm -f "$body_file"
  return 0
}
# <<< RALPH PR BODY <<<

# ──── Worktree-per-issue (issue #4, Idea 3) ────
# Each Path A --issue run can execute inside its OWN git worktree so the main
# working tree is never trampled and its `git status` stays clean throughout (AC 1),
# so back-to-back issue runs don't collide, and so a crashed run's half-built tree is
# resumable state rather than contamination of the main tree.
#
# DELIBERATE DEVIATION from issue #4's literal body: the issue proposed a SIBLING dir
# `../ralph-issue-N`. A path outside the repo violates the self-contained-repo
# guardrail (root CLAUDE.md: never reference `../` or the parent Metis tree) and would
# pollute the parent tree. Instead the worktree lives INSIDE the repo at
# .ralph/worktrees/issue-N (`.ralph/` is gitignored since the issue-#2 triage slice).
# This also makes the artifact seam (AC 4) trivial: planning artifacts are readable
# from the MAIN tree at .ralph/worktrees/issue-N/docs/… while the main tree's TRACKED
# status stays clean (the whole subtree is ignored).
#
# Parity (AC 5): with --worktree absent (USE_WORKTREE=0) ensure_issue_worktree is a
# no-op that returns 0 without creating anything, re-pointing anything, or registering
# any trap — so externally observable behavior is byte-identical to today.
#
# Sourced standalone by the offline smoke (tests/idea3-worktree-smoke.sh), so keep
# self-contained. Dependencies: the re-point READS USE_WORKTREE, ISSUE_NUMBER,
# REPO_ROOT, PROJECT_DIR_ARG, STORIES_DIR and WRITES RALPH_MAIN_ROOT, REPO_ROOT,
# PROJECT_DIR, EPIC_FILE, PRD_FILE, STORIES_DIR, MASTER_PROGRESS_FILE; the teardown +
# EXIT trap READ RALPH_MAIN_ROOT, ISSUE_NUMBER, RALPH_ALL_GREEN; plus git and log_*.
# >>> RALPH ISSUE WORKTREE (issue #4) — do not remove the sentinels >>>
ensure_issue_worktree() {
  # 1. Parity: a no-op unless --worktree was passed (AC 5).
  [[ "${USE_WORKTREE:-0}" != "1" ]] && return 0

  # 2. Pin the MAIN root (the pre-re-point REPO_ROOT). The worktree teardown, the
  #    breadcrumb, and the triage ledger all resolve paths against this.
  RALPH_MAIN_ROOT="$REPO_ROOT"
  local branch="ralph/issue-${ISSUE_NUMBER}"
  local wt_dir="$RALPH_MAIN_ROOT/.ralph/worktrees/issue-${ISSUE_NUMBER}"

  git -C "$RALPH_MAIN_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    log_error "[worktree] not a git repository at $RALPH_MAIN_ROOT — cannot create worktree for $branch"; exit 1; }

  # 3. Reaper half of AC 3: reclaim registrations whose worktree dirs were manually
  #    deleted (e.g. an operator `rm -rf`'d a leaked tree) BEFORE we try to add.
  git -C "$RALPH_MAIN_ROOT" worktree prune 2>/dev/null || true

  # Conflict guard: the branch is checked out in the MAIN tree (a previous
  #    non-worktree run left HEAD there). git refuses to add a worktree for an
  #    already-checked-out branch; surface a clear, actionable hard error.
  local main_head
  main_head="$(git -C "$RALPH_MAIN_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$main_head" == "$branch" ]]; then
    log_error "[worktree] main tree is on $branch; switch it back to your base branch, then re-run"
    exit 1
  fi

  # 4. Resume-or-create.
  if [[ -d "$wt_dir" ]] && git -C "$wt_dir" rev-parse --git-dir >/dev/null 2>&1; then
    # Existing, valid worktree → this is the crash-recovery path. A crashed run's
    # tree holds resumable planning state, NOT garbage — reuse it, never clobber it.
    local wt_head
    wt_head="$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "$wt_head" == "$branch" ]]; then
      log_info "[worktree] resuming existing worktree $wt_dir (HEAD on $branch — crash-recovery state)"
    else
      log_error "[worktree] worktree $wt_dir exists but HEAD is '$wt_head', expected $branch — refusing to build"; exit 1
    fi
  elif git -C "$RALPH_MAIN_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    # Branch already exists (a prior run created it) but no worktree → attach one.
    if ! git -C "$RALPH_MAIN_ROOT" worktree add "$wt_dir" "$branch" 2>/dev/null; then
      log_error "[worktree] could not add worktree $wt_dir for existing branch $branch — refusing to build"; exit 1
    fi
    log_success "[worktree] added worktree $wt_dir on existing branch $branch"
  else
    # Fresh: create the branch off the current main-tree HEAD (same "off \$current"
    # semantics as ensure_issue_branch) and attach the worktree in one step.
    if ! git -C "$RALPH_MAIN_ROOT" worktree add -b "$branch" "$wt_dir" 2>/dev/null; then
      log_error "[worktree] could not create worktree $wt_dir with new branch $branch — refusing to build"; exit 1
    fi
    log_success "[worktree] created worktree $wt_dir with new branch $branch (off ${main_head:-HEAD})"
  fi

  # 5. Re-point the run INTO the worktree so every claude -p step, every feat(N.k)
  #    commit, and every `git log` completion grep scopes to this tree automatically.
  #    Mirror the startup Path A derivation exactly (deferred existence for the epic/
  #    PRD — Phase 0 writes them; ARCH_FILE is left for run_intake_phase to set).
  REPO_ROOT="$wt_dir"
  PROJECT_DIR="$wt_dir/$PROJECT_DIR_ARG"
  [[ -d "$PROJECT_DIR" ]] || {
    log_error "[worktree] project dir not found in worktree: $PROJECT_DIR (it must be tracked)"; exit 1; }
  PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
  EPIC_FILE="$REPO_ROOT/docs/epics/issue-${ISSUE_NUMBER}.md"
  PRD_FILE="$REPO_ROOT/docs/prd/issue-${ISSUE_NUMBER}.md"
  # Re-derive the Layer 3a conventions source from the worktree's REPO_ROOT (it was
  # resolved from the main tree at startup, before this re-point). Without this a
  # --worktree run reads the main tree's docs/project-conventions.md even after the
  # trees diverge. Inlined (not a shared helper call) on purpose: this fenced block is
  # extracted and sourced in isolation by idea3-worktree-smoke.sh, so it must not
  # depend on functions defined elsewhere in the script. Mirror the startup resolution.
  if [[ -f "$REPO_ROOT/docs/project-conventions.md" ]]; then
    PROJECT_CONVENTIONS_FILE="$REPO_ROOT/docs/project-conventions.md"
  else
    PROJECT_CONVENTIONS_FILE="$REPO_ROOT/scripts/prompts/common/project-conventions.md"
  fi
  log_info "[worktree] project conventions -> $PROJECT_CONVENTIONS_FILE"
  # Re-point stories + master progress ONLY if they still hold the startup default
  # (a System Track run may have overridden STORIES_DIR via env — respect that).
  if [[ "$STORIES_DIR" == "$RALPH_MAIN_ROOT/docs/stories" ]]; then
    STORIES_DIR="$REPO_ROOT/docs/stories"
    MASTER_PROGRESS_FILE="$STORIES_DIR/ralph-sprint-progress.md"
  fi
  mkdir -p "$STORIES_DIR"
  cd "$PROJECT_DIR"
  # LOG_DIR/LOG_FILE deliberately stay in the MAIN tree so observability outlives the
  # worktree's removal on teardown.

  # 6. Breadcrumb seam: record the mapping in the MAIN tree, and log the exact
  #    artifact paths a viewer can read from the main tree while code work happens
  #    in the worktree (AC 4).
  local info_file="$RALPH_MAIN_ROOT/.ralph/worktrees/issue-${ISSUE_NUMBER}.info"
  mkdir -p "$RALPH_MAIN_ROOT/.ralph/worktrees" 2>/dev/null || true
  {
    printf 'branch\t%s\n'   "$branch"
    printf 'worktree\t%s\n' "$wt_dir"
    printf 'started\t%s\n'  "$(date +%s)"
  } > "$info_file" 2>/dev/null || true
  log_info "[worktree] run re-pointed into $wt_dir (branch $branch kept for review)"
  log_info "[worktree] planning artifacts readable from the main tree at .ralph/worktrees/issue-${ISSUE_NUMBER}/docs/ (epic: .ralph/worktrees/issue-${ISSUE_NUMBER}/docs/epics/issue-${ISSUE_NUMBER}.md)"

  # 7. Register teardown. No prior EXIT trap exists today (only INT/TERM → cleanup),
  #    and this is registered ONLY in worktree mode, so parity holds when off.
  trap 'worktree_exit_trap' EXIT
}

remove_issue_worktree() {
  # Success-path teardown. Recompute the paths from the globals the run pinned so
  # this is safe to call from the EXIT trap (a function's locals aren't visible there).
  local branch="ralph/issue-${ISSUE_NUMBER}"
  local wt_dir="$RALPH_MAIN_ROOT/.ralph/worktrees/issue-${ISSUE_NUMBER}"
  local info_file="$RALPH_MAIN_ROOT/.ralph/worktrees/issue-${ISSUE_NUMBER}.info"
  # --force is DELIBERATE: runtime droppings (e.g. the untracked
  # docs/prd/issue-N-pr.txt the loop writes) would otherwise block `worktree remove`.
  # They are recoverable — the PR URL is re-derivable from the branch via
  # ensure_issue_pr's branch-based recovery — so forcing here is safe.
  if git -C "$RALPH_MAIN_ROOT" worktree remove --force "$wt_dir" 2>/dev/null; then
    log_success "[worktree] removed worktree $wt_dir; branch $branch kept for review"
  else
    log_warn "[worktree] could not remove $wt_dir (already gone?) — leaving for manual cleanup; branch $branch kept"
  fi
  rm -f "$info_file" 2>/dev/null || true
}

worktree_exit_trap() {
  # MUST capture the exit code first. Remove the tree ONLY on a fully-green run
  # (RALPH_ALL_GREEN=1, set by main()'s completion block) that exits 0. Every other
  # exit — a crash, a park (exit 2), an interrupt (exit 130), or --plan-only (exit 0
  # but not all-green) — KEEPS the tree so uncommitted plans are never destroyed and
  # the next `--issue N --worktree` run resumes it.
  local rc=$?
  if [[ "${RALPH_ALL_GREEN:-0}" == "1" && "$rc" -eq 0 ]]; then
    remove_issue_worktree
  else
    log_info "[worktree] worktree kept at $RALPH_MAIN_ROOT/.ralph/worktrees/issue-${ISSUE_NUMBER} (rc=$rc, all-green=${RALPH_ALL_GREEN:-0}) — resume with: --issue ${ISSUE_NUMBER} --worktree"
  fi
}
# <<< RALPH ISSUE WORKTREE <<<

# ──── Swarm driver (issue #5, Idea 5 v1 — SERIAL multi-issue burn-down) ────
# When --issues is set, this drives a QUEUE of issues one at a time (never concurrent —
# v1 is serial; concurrency is a separately-justified v2 bet, prd.md §3 Idea 5). Each
# issue is worked by its OWN fresh single-issue child (`$0 --issue N --worktree …`), so it
# lands in its own worktree (Idea 3) and opens its own PR (Idea 1). A non-zero child NEVER
# stops the queue — that IS burn-down: log the outcome and move to the next. The driver
# exports RALPH_JOBS_DIR to each child so the pause/resume/abort BRAKE (check_interrupted)
# and the `ralph watch` dashboard (scripts/ralph-watch.sh) can see and steer each job. The
# driver never merges or closes anything (ADR-001 I3) — only `gh issue list` (a read) for
# the `ready` queue.
#
# The child command is `RALPH_SWARM_CHILD_CMD` (defaults to `("$0")`, overridable via an
# array env var — the offline-test seam the smoke uses to substitute a fake child).
#
# Sourced standalone by tests/idea5-swarm-smoke.sh, so keep self-contained: reference only
# documented globals (ISSUES_ARG, REPO_ROOT, REPO_SLUG, PROJECT_DIR_ARG, CHECKPOINT_CMD,
# GITHUB_WRITE, TRIAGE_MODE, ARCHITECTURE_MODE, the MODEL_*/MAX_TURNS_*/MAX_*/BUDGET_*
# knobs, RALPH_SWARM_CHILD_CMD), plus gh, usage, and log_*.
# >>> RALPH SWARM DRIVER (issue #5) — do not remove the sentinels >>>
# Whole-file rewrite of one job's status file (local swarm state under .ralph/jobs/, never
# gated — it never touches the network). Keys: issue/state/started_epoch/updated_epoch/
# exit_code/pid/worktree/log. The child's brake updates only state=/updated_epoch= in place.
swarm_job_status() { # $1=jobs_dir $2=issue $3=state $4=started $5=exit_code $6=pid $7=worktree $8=log
  local _dir="$1" _iss="$2" _st="$3" _started="$4" _ec="$5" _pid="$6" _wt="$7" _log="$8"
  {
    echo "issue=$_iss"
    echo "state=$_st"
    echo "started_epoch=$_started"
    echo "updated_epoch=$(date +%s)"
    echo "exit_code=$_ec"
    echo "pid=$_pid"
    echo "worktree=$_wt"
    echo "log=$_log"
  } > "$_dir/issue-${_iss}.status"
}

run_swarm_driver() {
  local jobs_dir="$REPO_ROOT/.ralph/jobs"
  mkdir -p "$jobs_dir"

  # ── 1. Resolve the queue ──
  local -a queue=()
  if [[ "$ISSUES_ARG" == "ready" ]]; then
    local slug="$REPO_SLUG"
    [[ -z "$slug" ]] && slug="$(cd "$REPO_ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    [[ -z "$slug" ]] && { log_error "[swarm] could not resolve the repo slug — pass --repo OWNER/NAME"; return 1; }
    # `ralph:ready` is Triage's promotion gate (issue #2): only issues a human (or Triage)
    # deliberately promoted enter the queue, so `roadmap`-labelled planning issues can't
    # be dogfooded in by accident (prd.md §6 recursion guard). Ascending order = stable.
    # Fail CLOSED, like slug resolution above: a gh failure (unauthenticated, no network,
    # rate-limited) must not masquerade as an empty ready-queue and exit 0. Capture gh's
    # own exit status BEFORE sorting so `|| true` doesn't swallow it.
    local _nums _n _gh_rc=0
    _nums="$(gh issue list --repo "$slug" --label ralph:ready --state open --json number -q '.[].number' 2>/dev/null)" || _gh_rc=$?
    [[ $_gh_rc -ne 0 ]] && { log_error "[swarm] \`gh issue list\` failed (rc=$_gh_rc) resolving the ready queue — check auth/network (gh auth status)"; return 1; }
    _nums="$(printf '%s\n' "$_nums" | sort -n)"
    while read -r _n; do [[ -n "$_n" ]] && queue+=("$_n"); done <<< "$_nums"
  else
    # Explicit list: split on commas, trim, validate positive integers, de-dup (keep order).
    local _saved_ifs="$IFS"; IFS=','; local -a _raw=($ISSUES_ARG); IFS="$_saved_ifs"
    local _tok _q _seen
    for _tok in "${_raw[@]}"; do
      # Trim ONLY leading/trailing whitespace — never interior. Stripping interior space
      # would coalesce a space-separated typo like `--issues "12 15"` into `1215` (a valid-
      # looking but wrong issue); leaving the space makes it fail the integer gate below.
      _tok="${_tok#"${_tok%%[![:space:]]*}"}"   # ltrim
      _tok="${_tok%"${_tok##*[![:space:]]}"}"   # rtrim
      [[ -z "$_tok" ]] && continue
      [[ "$_tok" =~ ^[0-9]+$ ]] || { echo -e "${RED}Error: --issues token '$_tok' is not a positive integer${NC}"; usage; }
      _seen=0
      for _q in "${queue[@]}"; do [[ "$_q" == "$_tok" ]] && { _seen=1; break; }; done
      [[ $_seen -eq 0 ]] && queue+=("$_tok")
    done
  fi

  if [[ ${#queue[@]} -eq 0 ]]; then
    log_info "[swarm] queue is empty — nothing to burn down. (For \`ready\`: no open issues carry the ralph:ready label.)"
    return 0
  fi

  log_info "[swarm] serial burn-down of ${#queue[@]} issue(s): ${queue[*]}  — v1 serial, worktree-isolated, brake included; concurrency = v2 (prd.md §3 Idea 5)."

  # The child command: default to this script's ABSOLUTE path, overridable via the
  # RALPH_SWARM_CHILD_CMD array env var (the offline-test seam). The absolute path is
  # mandatory: the top-level `cd "$PROJECT_DIR"` (into src/) runs before this driver, so a
  # relative `$0` (e.g. the documented `./scripts/ralph-loop.sh`) would resolve against src/
  # and fail to exec (rc 127 → every child `failed`). SCRIPT_DIR is already absolute. Only
  # compute the default when no override is set, so the offline seam (which sets the array
  # but not SCRIPT_DIR) never trips `set -u` on SCRIPT_DIR.
  local -a child_base
  if [[ -n "${RALPH_SWARM_CHILD_CMD+x}" ]]; then
    child_base=("${RALPH_SWARM_CHILD_CMD[@]}")
  else
    child_base=("$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")")
  fi

  # ── 2. Work the queue, IN ORDER, one child at a time (strictly serial) ──
  local all_done=1
  local _iss _rc _state _started _wt _logf
  for _iss in "${queue[@]}"; do
    _wt="$REPO_ROOT/.ralph/worktrees/issue-${_iss}"
    _logf="$jobs_dir/issue-${_iss}.log"
    _started="$(date +%s)"
    swarm_job_status "$jobs_dir" "$_iss" queued "$_started" "" "" "$_wt" "$_logf"
    log_info "[swarm] ── issue #${_iss}: starting (worktree-isolated) ──"
    swarm_job_status "$jobs_dir" "$_iss" running "$_started" "" "$$" "$_wt" "$_logf"

    # Forward the parsed knobs to the child. Always --issue N --worktree (Path A + Idea 3).
    local -a child=("${child_base[@]}" --issue "$_iss" --worktree
      --project-dir "$PROJECT_DIR_ARG"
      --checkpoint "$CHECKPOINT_CMD"
      --triage "$TRIAGE_MODE"
      --architecture "$ARCHITECTURE_MODE"
      --model-sm "$MODEL_SM" --model-dev "$MODEL_DEV" --model-review "$MODEL_REVIEW"
      --model-pm "$MODEL_PM" --model-architect "$MODEL_ARCHITECT" --model-planner "$MODEL_PLANNER"
      --max-turns-sm "$MAX_TURNS_SM" --max-turns-dev "$MAX_TURNS_DEV" --max-turns-review "$MAX_TURNS_REVIEW"
      --max-iterations "$MAX_ITERATIONS"
      --max-review-retries "$MAX_REVIEW_RETRIES"
      --max-upstream-depth "$MAX_UPSTREAM_DEPTH")
    [[ -n "$REPO_SLUG" ]] && child+=(--repo "$REPO_SLUG")
    [[ "$GITHUB_WRITE" == "1" ]] && child+=(--write)
    [[ -n "$BUDGET_PER_INVOCATION_USD" ]] && child+=(--budget-per-invocation-usd "$BUDGET_PER_INVOCATION_USD")
    [[ -n "$BUDGET_PER_STORY_USD" ]] && child+=(--budget-per-story-usd "$BUDGET_PER_STORY_USD")

    # Serial: run the child in the FOREGROUND (never backgrounded — v1 has no concurrency),
    # brake-wired via RALPH_JOBS_DIR. Its output is teed to the per-job log the watch reads.
    _rc=0
    RALPH_JOBS_DIR="$jobs_dir" "${child[@]}" >> "$_logf" 2>&1 || _rc=$?

    # Map the child's exit code to a job state. rc 0 → done; rc 2 → parked (triage gate /
    # manual review — a normal burn-down outcome); rc 4 → aborted (brake); else → failed.
    case "$_rc" in
      0) _state=done ;;
      2) _state=parked ;;
      4) _state=aborted ;;
      *) _state=failed ;;
    esac
    swarm_job_status "$jobs_dir" "$_iss" "$_state" "$_started" "$_rc" "" "$_wt" "$_logf"
    [[ "$_state" == "done" ]] || all_done=0
    log_info "[swarm] ── issue #${_iss}: ${_state} (rc=${_rc}) — continuing the queue ──"
    # A non-zero child NEVER stops the queue — that is burn-down (no `break`, no `exit`).
  done

  # ── 3. End summary: per-issue state table + PR count, then the two fixed guard lines ──
  local _pr_count=0
  _pr_count="$( { ls "$REPO_ROOT"/.ralph/worktrees/issue-*/docs/prd/issue-*-pr.txt \
                     "$REPO_ROOT"/docs/prd/issue-*-pr.txt 2>/dev/null || true; } | sort -u | wc -l | tr -d ' ')"
  log_plain "[swarm] ─────────── burn-down complete ───────────"
  log_plain "[swarm]  issue    state"
  for _iss in "${queue[@]}"; do
    local _sf="$jobs_dir/issue-${_iss}.status" _s="?"
    [[ -f "$_sf" ]] && _s="$(grep -m1 '^state=' "$_sf" 2>/dev/null | cut -d= -f2-)"
    log_plain "$(printf '[swarm]  #%-6s %s' "$_iss" "$_s")"
  done
  log_plain "[swarm]  PRs opened: ${_pr_count}"
  # The reviewer-despair kill criterion (prd.md §7) and the I3 no-merge/close reminder.
  # Exact strings — the dashboard/operator (and the smoke) look for them verbatim.
  log_warn "Review the opened PRs before queueing more work — if PRs pile up unreviewed, do NOT scale up; concurrency stays v2 (prd.md §7)."
  log_warn "The loop opened PRs; merging and closing stay yours."

  # Exit 0 iff every job is done, else 2 (park semantics — a human triages the rest).
  if [[ $all_done -eq 1 ]]; then return 0; else return 2; fi
}
# <<< RALPH SWARM DRIVER <<<

# ════════════════════════════════════════════════════════════════
# Main Loop
# ════════════════════════════════════════════════════════════════

main() {
  build_system_prompts

  log_plain "══════════════════════════════════════════"
  log_plain "Ralph Loop — ${COMPONENT_DISPLAY_NAME} (cost-optimized)"
  log_plain "Project:    $PROJECT_DIR_ARG"
  log_plain "Stories:    $STORIES_ARG"
  log_plain "Checkpoint: $CHECKPOINT_CMD"
  log_plain "Models:     SM=${MODEL_SM} | Dev=${MODEL_DEV} | Review=${MODEL_REVIEW}"
  log_plain "Max turns:  SM=${MAX_TURNS_SM} | Dev=${MAX_TURNS_DEV} | Review=${MAX_TURNS_REVIEW} | Fix=${MAX_TURNS_FIX}"
  log_plain "Budget cap: ${BUDGET_PER_INVOCATION_USD:-none} per invocation"
  log_plain "Max iterations: $MAX_ITERATIONS | Max review retries: $MAX_REVIEW_RETRIES | Max upstream depth: $MAX_UPSTREAM_DEPTH"
  log_plain "══════════════════════════════════════════"

  for ((idx=0; idx<TOTAL_STORIES; idx++)); do
    local story_id="${STORY_LIST[$idx]}"
    local story_title story_content
    story_title=$(extract_story_title "$story_id")
    story_content=$(extract_story_content "$story_id")
    CURRENT_STORY_IDX=$idx

    # Slice c (issue #1): refresh the self-updating issue comment to 🟡 building the
    # current story (X/Y). Path A only; a dry no-op with --write off. Regenerated
    # from local state, so it edits the one comment in place (never duplicates).
    [[ -n "$ISSUE_NUMBER" ]] && upsert_issue_comment building

    # Snapshot artifact existence at iteration entry — used by the phantom-
    # commit defense further down. Must be captured BEFORE Steps 1/2/3 run,
    # because those steps create the same artifacts on disk. Checking
    # file-state at guard-time (after steps run) is wrong: a Dev agent that
    # just wrote done.md doesn't mean done.md "pre-existed".
    local _pre_spec_existed=false _pre_done_existed=false _pre_review_passed=false
    [[ -f "${STORIES_DIR}/${story_id}.md" ]] && _pre_spec_existed=true
    [[ -f "${STORIES_DIR}/${story_id}-done.md" ]] && _pre_done_existed=true
    is_review_passed "${STORIES_DIR}/${story_id}-review.md" && _pre_review_passed=true

    if [[ -z "$story_content" ]]; then
      log_error "Story $story_id not found in $EPIC_FILE. Stopping."
      update_progress_file
      exit 1
    fi

    if is_story_complete "$story_id"; then
      log_info "[$story_id] Already complete — skipping."
      STORY_STATUSES[$idx]="Done"
      STORY_NOTES[$idx]="Pre-completed"
      (( STORIES_COMPLETED++ )) || true
      continue
    fi

    if [[ $ITERATION_COUNT -ge $MAX_ITERATIONS ]]; then
      log_error "Max iterations ($MAX_ITERATIONS) reached. Stopping."
      update_progress_file
      exit 1
    fi

    log_info "[$story_id] Starting: $story_title"
    STORY_STATUSES[$idx]="In Progress"
    update_progress_file

    local story_start step_start step_dur
    story_start=$(date +%s)
    local retry_count=0

    # ── Step 1: SM Agent writes story spec ──
    if [[ -f "${STORIES_DIR}/${story_id}.md" ]]; then
      log_info "[$story_id] Step 1/3: Story spec exists — skipping SM agent"
    else
      log_info "[$story_id] Step 1/3: SM agent writing story spec (model=${MODEL_SM})..."
      step_start=$(date +%s)

      if ! run_sm_agent "$story_id" "$story_title" "$story_content"; then
        STORY_STATUSES[$idx]="Failed"
        STORY_NOTES[$idx]="SM agent failed"
        update_progress_file
        exit 1
      fi

      step_dur=$(( $(date +%s) - step_start ))
      log_success "[$story_id] Step 1/3: Complete (${step_dur}s). Output: ${STORIES_DIR}/${story_id}.md"
    fi
    check_interrupted

    # ── Step 2: Dev Agent implements ──
    if [[ -f "${STORIES_DIR}/${story_id}-done.md" ]]; then
      log_info "[$story_id] Step 2/3: Implementation summary exists — skipping Dev agent"
    else
      log_info "[$story_id] Step 2/3: Dev agent implementing (model=${MODEL_DEV})..."
      step_start=$(date +%s)

      local dev_rc=0
      run_dev_agent "$story_id" || dev_rc=$?

      # Smart salvage: if dev agent hit max_turns (rc=3) but the working tree shows
      # changes AND the checkpoint command passes, the dev shipped working code
      # before exhausting its turn budget. Synthesize a minimal done.md from the
      # git diff stat and proceed to review — saves a full retry that would
      # repeat work already on disk.
      if [[ $dev_rc -eq 3 && ! -f "${STORIES_DIR}/${story_id}-done.md" ]]; then
        log_warn "[$story_id] Dev hit max_turns — checking on-disk state before retrying"
        local diff_stat
        diff_stat=$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | head -50)
        if [[ -n "$diff_stat" ]]; then
          log_info "[$story_id] Working tree has changes — running checkpoint to verify..."
          local checkpoint_rc=0
          ( cd "$REPO_ROOT" && eval "$CHECKPOINT_CMD" ) > /dev/null 2>>"$LOG_FILE" || checkpoint_rc=$?
          if [[ $checkpoint_rc -eq 0 ]]; then
            log_success "[$story_id] Checkpoint passed despite max_turns — salvaging dev's on-disk output"
            local files_changed
            files_changed=$(cd "$REPO_ROOT" && git diff --stat HEAD 2>/dev/null; cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | grep '^??' | awk '{print "  untracked: "$2}')
            cat > "${STORIES_DIR}/${story_id}-done.md" << SALVAGE_DONE
# Story ${story_id} — Implementation Summary (Salvaged from max_turns)

The dev agent hit max_turns at turn ${RALPH_LAST_SESSION_ID:+(session ${RALPH_LAST_SESSION_ID})} before writing this summary. The on-disk output passes the checkpoint command, so the work is preserved. This summary was synthesized by Ralph from \`git diff --stat HEAD\` rather than by the dev agent.

## Files changed (from \`git status --porcelain\`)

\`\`\`
${files_changed}
\`\`\`

## Verification

- Checkpoint command (\`${CHECKPOINT_CMD}\`) → PASSED on the dev's on-disk output before review
- A regular review cycle followed this salvage, validating the work meets the story's ACs

## Notes

The salvaged output skipped the explicit verification + summary stages of the dev's normal flow. The Code Review stage (Step 3) is the authoritative correctness gate for this story.
SALVAGE_DONE
            log_success "[$story_id] Step 2/3: Salvaged (\$RALPH_LAST_SESSION_ID can be resumed via Claude SDK if a real summary is needed later)"
            dev_rc=0
          else
            log_warn "[$story_id] Checkpoint failed (rc=$checkpoint_rc) — dev's on-disk output is incomplete; falling through to failure path"
          fi
        else
          log_warn "[$story_id] No working-tree changes — dev produced nothing to salvage"
        fi
      fi

      if [[ $dev_rc -ne 0 ]]; then
        STORY_STATUSES[$idx]="Failed"
        STORY_NOTES[$idx]="Dev agent failed (rc=$dev_rc, terminal_reason=${RALPH_LAST_TERMINAL_REASON:-unknown})"
        update_progress_file
        exit 1
      fi

      step_dur=$(( $(date +%s) - step_start ))
      log_success "[$story_id] Step 2/3: Complete (${step_dur}s). Output: ${STORIES_DIR}/${story_id}-done.md"
    fi
    check_interrupted

    # ── Step 3: Code Review (with retry loop) ──
    local review_passed=false

    if is_review_passed "${STORIES_DIR}/${story_id}-review.md"; then
      log_info "[$story_id] Step 3/3: Review already passed — skipping"
      review_passed=true
      # Slice d (issue #1): a resumed run with a passing review → ralph:in-review.
      [[ -n "$ISSUE_NUMBER" ]] && set_issue_label "ralph:in-review"
    else
      log_info "[$story_id] Step 3/3: Code Review agent reviewing (model=${MODEL_REVIEW})..."
      step_start=$(date +%s)

      local rev_rc=0
      run_review_agent "$story_id" || rev_rc=$?

      # Smart-retry on max_turns: resume the same session via --resume <id> instead
      # of restarting from scratch. The agent has the full review context in its
      # conversation history; one nudge is usually enough to get a verdict written.
      if [[ $rev_rc -eq 3 && -n "$RALPH_LAST_SESSION_ID" ]]; then
        local resume_id="$RALPH_LAST_SESSION_ID"
        log_warn "[$story_id] Review hit max_turns — resuming session $resume_id (one nudge to get a verdict)"
        rev_rc=0
        run_review_agent "$story_id" "$resume_id" || rev_rc=$?
      fi

      if [[ $rev_rc -ne 0 ]]; then
        STORY_STATUSES[$idx]="Failed"
        STORY_NOTES[$idx]="Review agent failed (rc=$rev_rc, terminal_reason=${RALPH_LAST_TERMINAL_REASON:-unknown})"
        update_progress_file
        exit 1
      fi

      step_dur=$(( $(date +%s) - step_start ))

      if is_review_passed "${STORIES_DIR}/${story_id}-review.md"; then
        log_success "[$story_id] Step 3/3: REVIEW_PASSED (${step_dur}s)"
        review_passed=true
        # Slice d (issue #1): verdict-gated label off is_review_passed → ralph:in-review.
        [[ -n "$ISSUE_NUMBER" ]] && set_issue_label "ralph:in-review"
      else
        log_warn "[$story_id] Step 3/3: REVIEW_FAILED (${step_dur}s)"
        # Slice d (issue #1): REVIEW_FAILED → ralph:needs-fix (the loop is fixing it).
        [[ -n "$ISSUE_NUMBER" ]] && set_issue_label "ralph:needs-fix"
      fi
    fi
    check_interrupted

    # ── Auto-heal wrapper around fix loop + checkpoint + commit ──
    # If the final independent checkpoint fails after REVIEW_PASSED, attempt a
    # single auto-heal: invoke the review agent again with the captured
    # checkpoint failure as context, force a synthetic REVIEW_FAILED, and
    # re-enter the fix loop so the dev agent gets a chance to repair the root
    # cause. Capped at one auto-heal attempt per story to prevent infinite
    # loops on unfixable environment errors.
    local final_gate_heal_attempted=false

    while true; do

    # Fix + re-review loop (with upstream fix support)
    local upstream_fix_attempted=false

    while ! $review_passed; do
      ((retry_count++)) || true

      if [[ $retry_count -gt $MAX_REVIEW_RETRIES ]]; then
        log_error "Story $story_id failed code review $MAX_REVIEW_RETRIES times. Marking as Manual Review Required."
        log_error "Last review: ${STORIES_DIR}/${story_id}-review.md"
        STORY_STATUSES[$idx]="Manual Review Required"
        STORY_RETRIES[$idx]="$MAX_REVIEW_RETRIES"
        STORY_NOTES[$idx]="Review failed ${MAX_REVIEW_RETRIES}x — manual intervention needed"
        update_progress_file
        break
      fi

      if [[ $ITERATION_COUNT -ge $MAX_ITERATIONS ]]; then
        log_error "Max iterations ($MAX_ITERATIONS) reached during review retry. Stopping."
        STORY_STATUSES[$idx]="Failed"
        STORY_NOTES[$idx]="Max iterations hit"
        update_progress_file
        exit 1
      fi

      # Per-story budget cap: abort the retry loop and surface to human if a single
      # story has consumed more than --budget-per-story-usd. Prevents runaway spend
      # on stories that hit max_turns or REVIEW_FAILED loops.
      if [[ -n "$BUDGET_PER_STORY_USD" ]]; then
        local cur_story_cost="${STORY_COSTS[$idx]:-0}"
        if awk -v a="$cur_story_cost" -v b="$BUDGET_PER_STORY_USD" 'BEGIN{exit !(a>b)}'; then
          log_error "Story $story_id exceeded per-story budget cap (\$${cur_story_cost} > \$${BUDGET_PER_STORY_USD}). Marking as Manual Review Required."
          STORY_STATUSES[$idx]="Manual Review Required"
          STORY_RETRIES[$idx]="$retry_count"
          STORY_NOTES[$idx]="Budget cap exceeded (\$${cur_story_cost}) — manual intervention needed"
          update_progress_file
          break
        fi
      fi

      local upstream_story=""
      upstream_story=$(detect_upstream_fix "${STORIES_DIR}/${story_id}-review.md") || true

      if [[ -n "$upstream_story" ]] && ! $upstream_fix_attempted; then
        log_warn "[$story_id] Review identified upstream root cause in $upstream_story"

        local depth=0
        local chain="$story_id"
        local check_story="$story_id"
        while [[ -n "${UPSTREAM_FIX_LOG[$check_story]+x}" ]]; do
          ((depth++)) || true
          check_story="${UPSTREAM_FIX_LOG[$check_story]}"
          chain="$check_story -> $chain"
        done

        if [[ $depth -ge $MAX_UPSTREAM_DEPTH ]]; then
          log_warn "[$story_id] Upstream fix depth limit ($MAX_UPSTREAM_DEPTH) reached. Chain: $chain"
          log_warn "[$story_id] Falling back to Manual Review Required"
          STORY_STATUSES[$idx]="Manual Review Required"
          STORY_RETRIES[$idx]="$retry_count"
          STORY_NOTES[$idx]="Upstream chain too deep: $chain"
          update_progress_file
          break
        fi

        UPSTREAM_FIX_LOG[$story_id]="$upstream_story"
        upstream_fix_attempted=true

        log_info "[$story_id] Running upstream fix agent on $upstream_story (model=${MODEL_DEV})..."
        step_start=$(date +%s)

        if ! run_upstream_fix_agent "$upstream_story" "$story_id"; then
          step_dur=$(( $(date +%s) - step_start ))
          log_error "[$story_id] Upstream fix agent failed on $upstream_story (${step_dur}s)"
          log_warn "[$story_id] Falling back to Manual Review Required"
          STORY_STATUSES[$idx]="Manual Review Required"
          STORY_RETRIES[$idx]="$retry_count"
          STORY_NOTES[$idx]="Upstream fix failed for $upstream_story"
          update_progress_file
          break
        fi

        step_dur=$(( $(date +%s) - step_start ))
        log_success "[$story_id] Upstream fix agent completed (${step_dur}s)"
        check_interrupted

        log_info "[$story_id] Verifying cascade after upstream fix to $upstream_story..."
        if ! verify_cascade "$upstream_story" "$story_id"; then
          log_error "[$story_id] Cascade verification failed after upstream fix"
          log_warn "[$story_id] Falling back to Manual Review Required"
          STORY_STATUSES[$idx]="Manual Review Required"
          STORY_RETRIES[$idx]="$retry_count"
          STORY_NOTES[$idx]="Cascade broken after fixing $upstream_story"
          update_progress_file
          break
        fi
        check_interrupted

        log_info "[$story_id] Committing upstream fix to $upstream_story..."
        local git_rc=0
        git add -A && git commit -m "fix(${upstream_story}): upstream fix triggered by ${story_id} review" || git_rc=$?
        if [[ $git_rc -ne 0 ]]; then
          log_warn "[$story_id] Upstream fix commit returned exit code $git_rc (may be no changes)"
        else
          log_success "[$story_id] Upstream fix committed"
        fi

        log_info "[$story_id] Re-reviewing after upstream fix to $upstream_story (model=${MODEL_REVIEW})..."
        step_start=$(date +%s)

        if ! run_review_agent "$story_id"; then
          STORY_STATUSES[$idx]="Failed"
          STORY_NOTES[$idx]="Review agent failed after upstream fix"
          update_progress_file
          exit 1
        fi

        step_dur=$(( $(date +%s) - step_start ))

        if is_review_passed "${STORIES_DIR}/${story_id}-review.md"; then
          log_success "[$story_id] REVIEW_PASSED after upstream fix to $upstream_story (${step_dur}s)"
          review_passed=true
          # Slice d (issue #1): passing verdict after upstream fix → ralph:in-review.
          [[ -n "$ISSUE_NUMBER" ]] && set_issue_label "ralph:in-review"
          STORY_NOTES[$idx]="Upstream fix applied to $upstream_story"
        else
          log_warn "[$story_id] REVIEW_FAILED after upstream fix (${step_dur}s) — continuing with local fix attempts"
        fi

      else
        # ── Standard local fix path ──
        log_warn "[$story_id] Fix attempt $retry_count/$MAX_REVIEW_RETRIES (model=${MODEL_DEV})..."

        local fix_rc=0
        run_fix_agent "$story_id" || fix_rc=$?

        # Smart-retry on max_turns: try one resume of the same session before
        # giving up. The fix agent has the review findings + code context loaded;
        # a focused continuation usually finishes the remaining edits cheaply.
        if [[ $fix_rc -eq 3 && -n "$RALPH_LAST_SESSION_ID" ]]; then
          local resume_id="$RALPH_LAST_SESSION_ID"
          log_warn "[$story_id] Fix agent hit max_turns — resuming session $resume_id"
          fix_rc=0
          run_fix_agent "$story_id" "$resume_id" || fix_rc=$?
        fi

        # If resume also hit max_turns, do not mark Failed — fall through to
        # re-review. The review is the actual gate that decides whether the
        # fix is complete; if it's not, the next fix attempt (retry_count++)
        # gets another shot. If it IS complete, no further fix work is needed.
        if [[ $fix_rc -eq 3 ]]; then
          log_warn "[$story_id] Fix resume also hit max_turns — proceeding to re-review and letting it decide"
          fix_rc=0
        fi

        if [[ $fix_rc -ne 0 ]]; then
          STORY_STATUSES[$idx]="Failed"
          STORY_NOTES[$idx]="Fix agent failed (attempt $retry_count, rc=$fix_rc, terminal_reason=${RALPH_LAST_TERMINAL_REASON:-unknown})"
          update_progress_file
          exit 1
        fi
        check_interrupted

        log_info "[$story_id] Re-reviewing after fix $retry_count (model=${MODEL_REVIEW})..."
        step_start=$(date +%s)

        local rerev_rc=0
        run_review_agent "$story_id" || rerev_rc=$?

        # Smart-retry on max_turns: resume the same session rather than restart.
        if [[ $rerev_rc -eq 3 && -n "$RALPH_LAST_SESSION_ID" ]]; then
          local resume_id="$RALPH_LAST_SESSION_ID"
          log_warn "[$story_id] Re-review (fix $retry_count) hit max_turns — resuming session $resume_id"
          rerev_rc=0
          run_review_agent "$story_id" "$resume_id" || rerev_rc=$?
        fi

        if [[ $rerev_rc -ne 0 ]]; then
          STORY_STATUSES[$idx]="Failed"
          STORY_NOTES[$idx]="Review agent failed on retry $retry_count (rc=$rerev_rc, terminal_reason=${RALPH_LAST_TERMINAL_REASON:-unknown})"
          update_progress_file
          exit 1
        fi

        step_dur=$(( $(date +%s) - step_start ))

        if is_review_passed "${STORIES_DIR}/${story_id}-review.md"; then
          log_success "[$story_id] Step 3/3: REVIEW_PASSED on retry $retry_count (${step_dur}s)"
          review_passed=true
          # Slice d (issue #1): passing verdict on a fix retry → ralph:in-review.
          [[ -n "$ISSUE_NUMBER" ]] && set_issue_label "ralph:in-review"
        else
          log_warn "[$story_id] Step 3/3: REVIEW_FAILED on retry $retry_count (${step_dur}s)"
          # Slice d (issue #1): still failing on retry → ralph:needs-fix (idempotent no-op if already set).
          [[ -n "$ISSUE_NUMBER" ]] && set_issue_label "ralph:needs-fix"
        fi
        check_interrupted
      fi
    done

    # Manual Review Required: break out of the auto-heal wrapper so the
    # skip-to-next-story handler below can fire.
    if [[ "${STORY_STATUSES[$idx]}" == "Manual Review Required" ]]; then
      break
    fi

    # ── Checkpoint + commit ──

    # Defense-in-depth against phantom commits (2026-05-15 hardening, v2).
    # Uses the iteration-entry SNAPSHOT (captured at top of for-loop, before
    # Steps 1/2/3 run) — not current file state. This is the corrected
    # version of the original guard: checking current file state was wrong
    # because Dev/Review agents create the same artifacts during the
    # iteration, so the post-step check fired falsely for stories that did
    # real work (e.g. 15.5 on 2026-05-15 — Dev wrote validator code, Review
    # wrote REVIEW_PASSED, then this guard incorrectly skipped the commit
    # and 15.5's source got swept into the next story's upstream-fix commit).
    if $_pre_spec_existed && $_pre_done_existed && $_pre_review_passed; then
      log_info "[$story_id] All artifacts pre-existed at iteration start (story.md + done.md + REVIEW_PASSED review.md); no agents ran new work — skipping checkpoint + commit (phantom-commit defense)"
      STORY_STATUSES[$idx]="Done"
      STORY_NOTES[$idx]="Pre-completed (artifacts present at iteration entry)"
      (( STORIES_COMPLETED++ )) || true
      update_progress_file
      continue 2   # exit auto-heal wrapper AND skip outer-for post-wrapper handler (which would double-count)
    fi

    if git log --oneline --all | grep -q "feat(${story_id}):"; then
      log_info "[$story_id] Already committed — skipping checkpoint"
      break
    fi

    log_info "[$story_id] Checkpoint: $CHECKPOINT_CMD"
    local chk_output=""
    local chk_rc=0
    chk_output=$(run_checkpoint) || chk_rc=$?

    if [[ $chk_rc -ne 0 ]]; then
      if $final_gate_heal_attempted; then
        log_error "Checkpoint failed after auto-heal attempt for story $story_id. Command output:"
        log_error "$chk_output"
        STORY_STATUSES[$idx]="Failed"
        STORY_NOTES[$idx]="Checkpoint failed (auto-heal exhausted)"
        update_progress_file
        exit 1
      fi

      log_warn "[$story_id] Final-gate checkpoint failed — invoking auto-heal review injection (one-shot)"
      log_warn "$chk_output"
      final_gate_heal_attempted=true

      local heal_rc=0
      run_review_agent_with_failure_injection "$story_id" "$chk_output" || heal_rc=$?

      if [[ $heal_rc -ne 0 ]]; then
        log_error "[$story_id] Auto-heal review-injection agent failed (rc=$heal_rc, terminal_reason=${RALPH_LAST_TERMINAL_REASON:-unknown})"
        log_error "$chk_output"
        STORY_STATUSES[$idx]="Failed"
        STORY_NOTES[$idx]="Auto-heal review injection failed"
        update_progress_file
        exit 1
      fi

      if is_review_passed "${STORIES_DIR}/${story_id}-review.md"; then
        log_error "[$story_id] Auto-heal: review agent ignored the injection and re-emitted REVIEW_PASSED. Aborting."
        log_error "$chk_output"
        STORY_STATUSES[$idx]="Failed"
        STORY_NOTES[$idx]="Auto-heal: review agent did not produce REVIEW_FAILED"
        update_progress_file
        exit 1
      fi

      log_warn "[$story_id] Auto-heal: synthetic REVIEW_FAILED written — re-entering fix loop"
      review_passed=false
      continue   # restart auto-heal wrapper → fix loop runs again
    fi

    log_success "[$story_id] Checkpoint: $CHECKPOINT_CMD -> SUCCESS"

    mark_story_complete "$story_id"

    local git_rc=0
    # Narrow git add: stage only this story's artifacts plus configured
    # work-surface paths. The paths are derived from the run's own
    # --project-dir ($PROJECT_DIR) and story-specs dir ($STORIES_DIR) — never
    # a hardcoded app dir — so a fork with an unrelated `src/` is never
    # silently over-staged. System Track runs (whose --project-dir is the repo
    # root) additionally enumerate scripts/, system/, root docs via the
    # EXTRA_STAGE_PATHS env var, which the System Track wrapper exports.
    #
    # Never `git add -A` — that would sweep unrelated tracked changes (logs,
    # other stories' progress, anything you happened to be editing) into the
    # feat(X.Y): commit. CRITICAL SUBTLETY: `git add "$PROJECT_DIR"` when
    # $PROJECT_DIR *is* the repo root is exactly `git add -A` from the repo root
    # (git 2.0+). System Track passes `--project-dir .`, which resolves
    # $PROJECT_DIR to $REPO_ROOT — so the array below adds $PROJECT_DIR/$STORIES_DIR
    # ONLY when --project-dir is a real subdirectory. In the repo-root case staging
    # is scoped entirely by the curated EXTRA_STAGE_PATHS list (the System Track
    # wrapper exports "scripts/ system/ README.md CLAUDE.md TIMELINE.md"; its
    # `system/` entry covers $STORIES_DIR), plus the three explicit per-story files.
    #
    # `cd "$REPO_ROOT"` is critical: the script's cwd is "$PROJECT_DIR"
    # from the `cd "$PROJECT_DIR"` near the top of the run. $PROJECT_DIR and
    # $STORIES_DIR are absolute (inside the repo), so they resolve correctly
    # from the repo root. node_modules/ and dist/ are gitignored, so staging
    # a subdirectory project dir won't add build output.
    #
    # `|| true` on git add is also critical: the script runs under
    # `set -euo pipefail`. A non-zero git-add return (e.g. a pathspec
    # that doesn't exist yet for a story that doesn't touch it) would
    # otherwise terminate the script before `git commit`. The
    # `git diff --cached --quiet` check below is the real signal we
    # care about — not git-add's exit code.
    local -a stage_paths=(
      "${STORIES_DIR}/${story_id}.md"
      "${STORIES_DIR}/${story_id}-done.md"
      "${STORIES_DIR}/${story_id}-review.md"
    )
    # Add the run's work-surface dirs ONLY when --project-dir is a real subdir.
    # If $PROJECT_DIR == $REPO_ROOT (System Track's `--project-dir .`), staging it
    # equals `git add -A` and would sweep unrelated dirty files into this commit;
    # in that mode EXTRA_STAGE_PATHS (below) does the narrow staging instead.
    if [[ "$PROJECT_DIR" != "$REPO_ROOT" ]]; then
      stage_paths+=( "$PROJECT_DIR" "$STORIES_DIR" )
    fi
    if [[ -n "${EXTRA_STAGE_PATHS:-}" ]]; then
      # Intentional word splitting on EXTRA_STAGE_PATHS so callers can pass
      # space-separated paths via env var: EXTRA_STAGE_PATHS="scripts/ system/ README.md"
      # shellcheck disable=SC2206
      local -a extra=(${EXTRA_STAGE_PATHS})
      stage_paths+=("${extra[@]}")
    fi
    ( cd "$REPO_ROOT" && git add "${stage_paths[@]}" 2>/dev/null ) || true
    # Nothing-to-commit guard — final defense against a no-op commit.
    if git diff --cached --quiet; then
      log_warn "[$story_id] Nothing to commit (no story-scoped changes); skipping commit"
      break
    fi
    git commit -m "feat(${story_id}): ${story_title}" || git_rc=$?
    if [[ $git_rc -ne 0 ]]; then
      log_warn "[$story_id] Git commit returned exit code $git_rc"
    fi
    log_success "[$story_id] Git commit: feat(${story_id}): ${story_title}"

    break   # success path → exit auto-heal wrapper
    done    # close auto-heal wrapper

    # ── Handle Manual Review Required: skip to next story ──
    if [[ "${STORY_STATUSES[$idx]}" == "Manual Review Required" ]]; then
      log_warn "[$story_id] Skipping to next story (Manual Review Required)"
      local story_end total_dur fmt_dur
      story_end=$(date +%s)
      total_dur=$(( story_end - story_start ))
      fmt_dur=$(format_duration "$total_dur")
      STORY_DURATIONS[$idx]="$fmt_dur"
      update_progress_file
      continue
    fi

    # ── Update tracking ──
    local story_end total_dur fmt_dur
    story_end=$(date +%s)
    total_dur=$(( story_end - story_start ))
    fmt_dur=$(format_duration "$total_dur")

    STORY_STATUSES[$idx]="Done"
    STORY_DURATIONS[$idx]="$fmt_dur"
    STORY_RETRIES[$idx]="$retry_count"
    (( STORIES_COMPLETED++ )) || true
    update_progress_file

    log_success "[$story_id] COMPLETE ($fmt_dur, $retry_count retries, \$${STORY_COSTS[$idx]})"
  done

  # ── Completion ──
  local manual_count=0
  for ((j=0; j<TOTAL_STORIES; j++)); do
    if [[ "${STORY_STATUSES[$j]}" == "Manual Review Required" ]]; then ((manual_count++)) || true; fi
  done

  # Slice c (issue #1): when the whole sprint is green (Path A, no manual reviews,
  # every story done), flip the self-updating issue comment to 🟢 done + PR link.
  # A dry no-op with --write off; edits the one comment in place (idempotent).
  if [[ -n "$ISSUE_NUMBER" && $manual_count -eq 0 && $STORIES_COMPLETED -eq $TOTAL_STORIES ]]; then
    CURRENT_STORY_IDX=-1
    # Finish slice (issue #1 step 5): graduate the slice-b draft PR to ready-for-review
    # BEFORE the 🟢 done comment, so the comment announces a PR that is actually ready.
    # `gh pr ready` only — never merge/close (I3); idempotent (skips an already-ready PR);
    # a dry no-op with --write off. Step 5's "final linking comment" is the existing
    # `upsert_issue_comment done` below (its 🟢 body links the PR) — NO second comment.
    # Confessing PR (issue #3, Idea 2): upgrade the PR body to the synthesised body
    # while the PR is still loop-owned (draft) — BEFORE ready. Dry no-op with --write off.
    update_issue_pr_body
    RALPH_ALL_GREEN=1   # worktree teardown gate (issue #4): the EXIT trap removes the tree only on a fully-green run
    mark_issue_pr_ready
    upsert_issue_comment done
    # Slice d (issue #1): all stories green → terminal ralph:done (single edit, removes
    # whatever ralph status label was last set). Idempotent; a dry no-op with --write off.
    set_issue_label "ralph:done"
  fi

  if [[ -n "$TAG" ]] && [[ $manual_count -eq 0 ]]; then
    git tag "$TAG"
    log_success "Git tag created: $TAG"
  elif [[ -n "$TAG" ]]; then
    log_warn "Skipping git tag '$TAG' — $manual_count stories need manual review"
  fi

  log_plain "══════════════════════════════════════════"
  if [[ $manual_count -gt 0 ]]; then
    log_warn "Ralph Loop complete with warnings."
    log_warn "$manual_count stories marked 'Manual Review Required':"
    for ((j=0; j<TOTAL_STORIES; j++)); do
      if [[ "${STORY_STATUSES[$j]}" == "Manual Review Required" ]]; then
        log_warn "  ${STORY_LIST[$j]}: ${STORY_NOTES[$j]}"
      fi
    done
  else
    log_success "Ralph Loop complete! $STORIES_COMPLETED/$TOTAL_STORIES stories done."
  fi

  if [[ ${#UPSTREAM_FIX_LOG[@]} -gt 0 ]]; then
    log_info "Upstream fixes applied:"
    for key in "${!UPSTREAM_FIX_LOG[@]}"; do
      log_info "  $key triggered fix in ${UPSTREAM_FIX_LOG[$key]}"
    done
  fi

  log_plain "Total agent invocations: $ITERATION_COUNT"
  log_plain "Total cost:              \$${TOTAL_COST}"
  log_plain "Total input tokens:      $TOTAL_INPUT_TOKENS"
  log_plain "Total output tokens:     $TOTAL_OUTPUT_TOKENS"
  log_plain "Total cache-read tokens: $TOTAL_CACHE_READ_TOKENS"
  log_plain "Log:                     $LOG_FILE"
  log_plain "Sprint progress:         $PROGRESS_FILE"
  log_plain "Master progress:         $MASTER_PROGRESS_FILE"
  log_plain "══════════════════════════════════════════"

  if [[ $manual_count -gt 0 ]]; then
    exit 2
  fi
}

# ──── Swarm driver gate (issue #5) — serial multi-issue burn-down ────
# When --issues is set this run is a DRIVER, not a single-issue build: it works the queue
# one child at a time and never falls through into the single-issue machinery below. Placed
# before the --dry-run-prompts block and the Phase-0 gate so driver mode wins cleanly. With
# --issues empty (every existing invocation, including --dry-run-prompts and the golden),
# this is inert — externally unchanged.
if [[ -n "$ISSUES_ARG" ]]; then
  run_swarm_driver
  exit $?
fi

# ──── Dry-run prompts mode ────
# Prints the three resolved system prompts and exits (no claude invocation).
# Placed here (after all function definitions and persona loading) so
# load_prompt_layers() and AGENT_*_PERSONA variables are fully available.
if $DRY_RUN_PROMPTS; then
  if ! declare -f load_prompt_layers &>/dev/null; then
    echo "Error: load_prompt_layers() not found" >&2
    exit 1
  fi
  _dryrun_failed=0
  # Path B prints sm/dev/review (unchanged). Path A (--issue) also prints the
  # planning roles so their resolved prompts can be smoke-checked without running
  # Phase 0 (this block exits before the Phase 0 gate below).
  _dryrun_roles=(sm dev review)
  [[ -n "$ISSUE_NUMBER" ]] && _dryrun_roles+=(pm architect planner)
  for _dryrun_role in "${_dryrun_roles[@]}"; do
    echo "=== $(echo "$_dryrun_role" | tr '[:lower:]' '[:upper:]') ==="
    _dryrun_prompt=""
    _dryrun_rc=0
    _dryrun_prompt=$(load_prompt_layers "$_dryrun_role") || _dryrun_rc=$?
    if [[ $_dryrun_rc -ne 0 ]]; then
      echo "Error: load_prompt_layers failed for role '$_dryrun_role' (exit code $_dryrun_rc)" >&2
      _dryrun_failed=1
    else
      printf '%s\n' "$_dryrun_prompt"
    fi
    echo ""
  done
  [[ $_dryrun_failed -eq 0 ]] || exit 1
  exit 0
fi

# ──── Phase 0 (Plan) gate — Path A only ────
# Runs before main() so the existing loop is reached unchanged. Building the
# system prompts here (idempotent) makes SYSTEM_PROMPT_PM/ARCHITECT/PLANNER
# available to the planning agents; main() will no-op its own build call.
if [[ -n "$ISSUE_NUMBER" ]]; then
  build_system_prompts
  # Issue #4 (Idea 3): if --worktree, re-point this run into .ralph/worktrees/issue-N
  # BEFORE triage and Phase 0, so ALL planning artifacts (PRD/architecture/epic/stories)
  # land in the worktree and the main tree stays clean. A no-op without --worktree
  # (parity, AC 5). Triage writes no repo files — its ledger goes to the MAIN root's
  # .ralph/ (RALPH_MAIN_ROOT), set here.
  ensure_issue_worktree
  # Idea 4, issue #2: the judgment gate — only ralph:ready work is promoted into Phase 0
  # (needs-info/wontfix-candidate/excluded issues are labelled + parked, never built);
  # see prd.md §3 Idea 4. Runs before run_intake_phase so no build tokens are spent on
  # unready issues. `--triage never` bypasses it (pre-triage behavior).
  run_triage_phase
  run_intake_phase          # fetch issue → PRD → (architecture) → epic; sets EPIC_FILE/PRD_FILE/ARCH_FILE
  finalize_story_plan       # now the epic exists → expand stories + init tracking arrays

  if $PLAN_ONLY; then
    log_success "[Phase 0] --plan-only: planning complete, stopping before any code changes."
    log_plain "  Issue:   #${ISSUE_NUMBER}"
    log_plain "  PRD:     $PRD_FILE"
    [[ -n "$ARCH_FILE" && -f "$ARCH_FILE" ]] && log_plain "  Arch:    $ARCH_FILE"
    log_plain "  Epic:    $EPIC_FILE"
    log_plain "  Stories: $STORIES_ARG"
    exit 0
  fi

  # Slice a (issue #1): create/resume `ralph/issue-N` BEFORE the dev loop so
  # story feat() commits land on the issue branch, never the base branch. Local
  # only — no push (that lands with the draft PR in slice b, gated by --write).
  ensure_issue_branch

  # Slice b (issue #1): push the issue branch and open exactly one draft PR
  # (idempotent via docs/prd/issue-N-pr.txt), both gated by --write. With --write
  # off these are dry no-ops — no push, no PR — so read-only Path A is unchanged.
  ensure_issue_pr

  # Slice c (issue #1): post the self-updating status comment (🔵 planning) so the
  # human sees the build start where they live. Idempotent + fail-closed; a dry
  # no-op with --write off. Per-story 🟡 and final 🟢 updates edit this same comment.
  upsert_issue_comment planning

  # Slice d (issue #1): ensure the ralph: status labels exist (so a live
  # --write-on add-label can't fail on a missing label), then mark the build started
  # (ralph:building). Build start lives HERE, beside the 🔵 planning comment, so the
  # label and the comment cross the Rubicon together. Verdict-gated per-story labels
  # (ralph:needs-fix ↔ ralph:in-review) and the terminal ralph:done land in main().
  # Already inside the --issue gate; both are dry no-ops with --write off.
  ensure_ralph_labels
  set_issue_label "ralph:building"
fi

main