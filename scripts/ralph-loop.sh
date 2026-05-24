#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# Ralph Loop — Exchange Rates Dashboard demo (Cost-Optimized)
#
# Orchestrates SM -> Dev -> Review -> Fix cycles per story.
# Each agent invocation is a fresh Claude Code session (the core
# Ralph insight: clean context per step).
#
# Adapted from ralph-affiant-v2.sh for this self-contained React + Vite
# + TypeScript demo repo. The loop semantics, multi-model routing, retry
# logic, and budget caps are unchanged from the Affiant version; only the
# stack-specific bits were swapped:
#   - Defaults target this repo: --project-dir src, --prd docs/prd.md,
#     --epic docs/epics/exchange-rates-dashboard.md, and an npm checkpoint.
#     A PRD is passed via --prd; there is no separate architecture doc
#     (--arch stays optional and unset).
#   - Cached system prompts encode React 19 / Vite / TypeScript-strict
#     conventions (function components + hooks, native fetch, localStorage,
#     no class components, lean dependency stack) instead of .NET/C#.
#   - Review standards are React/TS-specific (hooks rules, strict types,
#     Vitest + RTL, stack-rule adherence) instead of .NET layering.
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
# Defaults target this demo repo so the documented command — and a bare
# `./scripts/ralph-loop.sh` — work out of the box. Flags still override.
EPIC_FILE="docs/epics/exchange-rates-dashboard.md"
STORIES_ARG="all"
CHECKPOINT_CMD="cd src && npm run build && npm test --if-present"
PROJECT_DIR_ARG="src"
PRD_FILE="docs/prd.md"
ARCH_FILE=""

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

# ──── Argument parsing ────
usage() {
  cat <<'EOF'
Usage: ralph-loop.sh [--project-dir DIR] [--epic FILE] [--stories LIST] [--checkpoint CMD] [options]

All four "required" flags below have demo defaults baked in, so a bare
`./scripts/ralph-loop.sh` runs the full Exchange Rates Dashboard build.
Pass a flag only to override its default.

Core flags (defaults shown):
  --project-dir DIR        Relative path to the app the agents work inside
                           (default: src)
  --epic FILE              Path to the epics markdown file
                           (default: docs/epics/exchange-rates-dashboard.md)
  --stories LIST           "all" (every story in the epic, in file order) or a
                           comma-separated subset in execution order, e.g. 1.1,1.2,1.3
                           (default: all)
  --checkpoint CMD         Shell command to verify project health, run from repo root
                           (default: 'cd src && npm run build && npm test --if-present')

Optional document references (passed to SM agent for context):
  --prd FILE               Path to the PRD markdown (default: docs/prd.md)
  --arch FILE              Path to an architecture doc (default: unset — this demo has none)

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

Example (run the whole Exchange Rates Dashboard build — these are the defaults):
  ./scripts/ralph-loop.sh \
     --project-dir src \
     --prd docs/prd.md \
     --epic docs/epics/exchange-rates-dashboard.md \
     --stories all \
     --checkpoint 'cd src && npm run build && npm test --if-present'

Example (just the first two stories):
  ./scripts/ralph-loop.sh --stories 1.1,1.2
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --project-dir)                 PROJECT_DIR_ARG="$2"; shift 2 ;;
    --epic)                        EPIC_FILE="$2"; shift 2 ;;
    --stories)                     STORIES_ARG="$2"; shift 2 ;;
    --checkpoint)                  CHECKPOINT_CMD="$2"; shift 2 ;;
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
    --help|-h)                     usage ;;
    *)                             echo -e "${RED}Unknown argument: $1${NC}"; usage ;;
  esac
done

[[ -z "$PROJECT_DIR_ARG" ]] && { echo -e "${RED}Error: --project-dir is required${NC}"; usage; }
[[ -z "$EPIC_FILE" ]]       && { echo -e "${RED}Error: --epic is required${NC}"; usage; }
[[ -z "$STORIES_ARG" ]]     && { echo -e "${RED}Error: --stories is required${NC}"; usage; }
[[ -z "$CHECKPOINT_CMD" ]]  && { echo -e "${RED}Error: --checkpoint is required${NC}"; usage; }

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

COMPONENT_NAME="$(basename "$PROJECT_DIR_ARG" | tr '[:upper:]' '[:lower:]')"
# Friendly label for banners/progress headers. `src` is this demo's app dir,
# so show the product name rather than the bare folder name.
if [[ "$COMPONENT_NAME" == "src" ]]; then
  COMPONENT_DISPLAY_NAME="Exchange Rates Dashboard"
else
  COMPONENT_DISPLAY_NAME="$(basename "$PROJECT_DIR_ARG")"
fi

if [[ ! -f "$EPIC_FILE" ]]; then
  if [[ -f "$REPO_ROOT/$EPIC_FILE" ]]; then
    EPIC_FILE="$REPO_ROOT/$EPIC_FILE"
  else
    echo -e "${RED}Error: Epic file not found: $EPIC_FILE${NC}"; exit 1
  fi
fi
EPIC_FILE="$(cd "$(dirname "$EPIC_FILE")" && pwd)/$(basename "$EPIC_FILE")"

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

[[ -n "$PRD_FILE"  && ! -f "$PRD_FILE"  ]] && echo -e "${YELLOW}Warning: PRD file not found at $PRD_FILE${NC}"
[[ -n "$ARCH_FILE" && ! -f "$ARCH_FILE" ]] && echo -e "${YELLOW}Warning: Architecture doc not found at $ARCH_FILE${NC}"

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

# Expand `--stories all` into every story ID in the epic file, in file order.
# Story headers look like `### Story 1.1: ...`.
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

# ──── Tracking arrays ────
declare -a STORY_STATUSES=()
declare -a STORY_DURATIONS=()
declare -a STORY_RETRIES=()
declare -a STORY_NOTES=()
declare -a STORY_COSTS=()
for ((i=0; i<TOTAL_STORIES; i++)); do
  STORY_STATUSES+=("Pending")
  STORY_DURATIONS+=("—")
  STORY_RETRIES+=("—")
  STORY_NOTES+=("—")
  STORY_COSTS+=("0")
done

ITERATION_COUNT=0
STORIES_COMPLETED=0
CURRENT_STORY_IDX=-1
INTERRUPTED=false
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

# ──── Load BMAD agent definitions ────
# BMAD v6.7+ skill mapping for the SM -> Dev -> Review cycle:
#   SM     = bmad-create-story (turns the epic into a context-rich story spec)
#   Dev    = bmad-dev-story    (implements the story spec)
#   Review = bmad-code-review  (adversarial review + triage)
# There is no bmad-agent-sm in v6.7+; bmad-create-story is its successor.
AGENT_SM_FILE="$BMAD_ROOT/bmad-create-story/SKILL.md"
AGENT_DEV_FILE="$BMAD_ROOT/bmad-dev-story/SKILL.md"
AGENT_REVIEW_DIR="$BMAD_ROOT/bmad-code-review"

AGENT_SM_PERSONA=""
AGENT_DEV_PERSONA=""
AGENT_REVIEW_PERSONA=""

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

build_system_prompts() {
  # Common execution context — shared by all agent types.
  # Do NOT include story-specific or invocation-varying content here,
  # or prompt cache hits will be lost.
  local common
  common="## Execution Context

You are running non-interactively in an automated pipeline. Follow these rules:
- Do NOT greet the user, do NOT present menus, do NOT HALT for input.
- Skip any 'On Activation' or 'Load config' sections from your BMAD persona.
- Execute the task directly and return when done.
- If you need information not provided, make a reasonable assumption and document it in your output.
- Do not ask clarifying questions — commit to a direction and note your assumption.

## Project Conventions (React / Vite / TypeScript)

- Stack: React 19 + Vite + TypeScript (\`strict\` on) in \`src/\`. Do not introduce Next.js, SSR, or any other framework.
- Function components and hooks only. No class components. Reach for \`useReducer\` only where it genuinely simplifies state.
- TypeScript strict mode: no \`any\` to silence the compiler, no \`@ts-ignore\`/\`@ts-expect-error\` to hide a real type error, no non-null \`!\` to paper over a possibly-undefined value. Fix the type, do not suppress it. A \`tsc\` error is a build break.
- Lean stack — this is a deliberate constraint. Do NOT add a dependency to \`src/package.json\` (UI kit, charting lib, state lib, axios/swr/react-query, etc.) unless the story spec explicitly requires it. Use what's there: native \`fetch\` for HTTP, React hooks for state, plain CSS or CSS Modules for styling, inline SVG for charts.
- Data fetching with native \`fetch\`. Handle loading and error states explicitly; do not swallow rejected promises.
- Persistence is \`localStorage\` only. No IndexedDB, no backend, no database. Guard \`JSON.parse\` of stored values against malformed data.
- Tests: Vitest + React Testing Library, colocated as \`Component.test.tsx\` beside \`Component.tsx\`. Prefer behavior-level assertions (what the user sees / what endpoint is called) over implementation detail.
- Keep imports inside \`src/\`. Do not reach outside the app directory.

## Scope Discipline

- Implement only what the current story spec asks for. No refactors of unrelated code, no \"while I'm here\" cleanups, no speculative abstractions.
- If a story seems to require something the stack rules forbid (e.g. a new library), flag it as a question in your output rather than silently installing it.
- Acceptance criteria are the contract. Make them demonstrable; do not gold-plate beyond them.

## Checkpoint Command

The project checkpoint command is: ${CHECKPOINT_CMD}

Run this from the repo root to verify the app builds and tests pass."

  # ── SM system prompt ──
  if [[ -n "$AGENT_SM_PERSONA" ]]; then
    SYSTEM_PROMPT_SM="# Agent Persona

${AGENT_SM_PERSONA}

---

${common}"
  else
    SYSTEM_PROMPT_SM="You are the BMAD Scrum Master (bmad-create-story). Produce exactly one detailed, implementation-ready story spec from the epic and PRD. Acceptance criteria must be observable from outside the code.

${common}"
  fi

  # ── Dev system prompt (also used for Fix and Upstream Fix) ──
  if [[ -n "$AGENT_DEV_PERSONA" ]]; then
    SYSTEM_PROMPT_DEV="# Agent Persona

${AGENT_DEV_PERSONA}

---

${common}"
  else
    SYSTEM_PROMPT_DEV="You are the BMAD Developer (bmad-dev-story). Implement the story spec to satisfy its acceptance criteria, then make the checkpoint pass.

${common}"
  fi

  # ── Review system prompt ──
  local review_header
  if [[ -n "$AGENT_REVIEW_PERSONA" ]]; then
    review_header="# Agent Persona

You are the BMAD Code Review agent. Apply the adversarial review approach (Blind Hunter + Edge Case Hunter + Acceptance Auditor) and triage methodology. The full BMAD review workflow is provided below.

${AGENT_REVIEW_PERSONA}

---"
  else
    review_header="# Agent Persona

You are the BMAD Code Review agent."
  fi

  SYSTEM_PROMPT_REVIEW="${review_header}

${common}

## Review Standards

PASS the review when the acceptance criteria are met AND the checkpoint
(\`cd src && npm run build && npm test --if-present\`) succeeds — even if you
would have written the code differently. Surface at most ONE blocking issue
per review pass; let the Fix step land it before reviewing again.

BLOCK only on:
1. Acceptance criteria not met — any story AC is unsatisfied or not demonstrable.
2. Build or test failure — \`tsc\`/Vite build errors, or failing Vitest tests. Run the checkpoint to confirm.
3. Stack-rule violation — a class component; a new \`src/package.json\` dependency the story did not call for (UI kit, charting/state/HTTP lib); use of localStorage-forbidden persistence; a non-\`fetch\` HTTP path.
4. Type-safety escape hatch hiding a real error — \`any\`, \`@ts-ignore\`/\`@ts-expect-error\`, or non-null \`!\` used to silence the compiler rather than fix the type.
5. Import reaching outside \`src/\`.
6. Real bug or missing error/loading handling — unhandled rejected fetch, blanked-out UI on error where the AC says otherwise, unguarded \`JSON.parse\` of localStorage.
7. Security issue.

DO NOT block on style: renames, comment density, test organization, or
\"I'd structure this differently.\" Those are nits, not blockers.

## Cross-Story Root Cause Analysis

If you find an issue whose root cause is in code written by a PREVIOUS story
(not the current story being reviewed), you MUST include a structured marker
block in your review output. The format is exactly:

UPSTREAM_FIX_REQUIRED: <story-id>
ROOT_CAUSE: <one-line description of what is wrong in the upstream story's code>
AFFECTED_FILES: <comma-separated list of files in the upstream story that need fixing>
CURRENT_IMPACT: <how this upstream bug manifests in the current story>

Place this block AFTER the REVIEW_FAILED line and BEFORE detailed findings.
Include at most ONE upstream fix marker per review. Only use this marker when
the fix MUST happen in the upstream story's code — not when the current story
could reasonably work around the issue."

  log_info "System prompts built (SM/Dev/Review cached via --append-system-prompt)"
  log_dim "  SM prompt size:     $(echo -n "$SYSTEM_PROMPT_SM"     | wc -c) bytes"
  log_dim "  Dev prompt size:    $(echo -n "$SYSTEM_PROMPT_DEV"    | wc -c) bytes"
  log_dim "  Review prompt size: $(echo -n "$SYSTEM_PROMPT_REVIEW" | wc -c) bytes"
}

# ──── Signal handling ────
cleanup() { INTERRUPTED=true; }
trap cleanup SIGINT SIGTERM

check_interrupted() {
  if $INTERRUPTED; then
    if [[ $CURRENT_STORY_IDX -ge 0 ]]; then
      STORY_STATUSES[$CURRENT_STORY_IDX]="Interrupted"
    fi
    update_progress_file
    log_warn "Ralph Loop interrupted. Progress saved to $PROGRESS_FILE"
    exit 130
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
The project conventions (TypeScript strict, ESM, dependency direction, atomic writes, etc.) are already in your system prompt — follow them strictly.

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

CRITICAL: Only modify files in story ${upstream_story_id}'s scope. If shared type files must change (e.g., TypeScript interfaces used by both stories), make those changes too — but keep them minimal.
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
      else
        log_warn "[$story_id] Step 3/3: REVIEW_FAILED (${step_dur}s)"
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
        else
          log_warn "[$story_id] Step 3/3: REVIEW_FAILED on retry $retry_count (${step_dur}s)"
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
    # Narrow git add: stage only this story's artifacts plus the app source,
    # never `git add -A` (which would sweep unrelated tracked changes — logs,
    # other stories' progress — into the feat(X.Y): commit).
    #
    # `cd "$REPO_ROOT"` is critical: the script's cwd is "$PROJECT_DIR" (= src/)
    # from the `cd "$PROJECT_DIR"` near the top of the run. The pathspecs below
    # are repo-root-relative (`src/`, `docs/stories/`), so they must resolve
    # from the repo root, not from inside src/. node_modules/ and dist/ under
    # src/ are gitignored, so `git add src/` won't stage build output.
    #
    # `|| true` is also critical: the script runs under `set -euo pipefail`.
    # A non-zero git-add return (e.g. a pathspec that doesn't exist yet for a
    # story that doesn't touch it) would otherwise terminate the script before
    # `git commit`. The `git diff --cached --quiet` check below is the real
    # signal we care about — not git-add's exit code.
    ( cd "$REPO_ROOT" && git add \
      "${STORIES_DIR}/${story_id}.md" \
      "${STORIES_DIR}/${story_id}-done.md" \
      "${STORIES_DIR}/${story_id}-review.md" \
      src/ \
      docs/stories/ \
      2>/dev/null ) || true
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

main