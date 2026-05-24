#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# ralph-loop-system.sh
#
# System Track wrapper around scripts/ralph-loop.sh. Resolves the
# chapter folder under system/chapters/, locates its PRD and epic,
# and delegates to the canonical loop with system-appropriate defaults.
#
# Cloners running the demo don't need this script — they want
# scripts/ralph-loop.sh at the repo root.
#
# Usage:
#   ./system/ralph-loop-system.sh                              # latest chapter
#   ./system/ralph-loop-system.sh <chapter-slug>               # specific chapter
#   ./system/ralph-loop-system.sh <chapter-slug> -- <args>     # pass-through to ralph-loop.sh
#   ./system/ralph-loop-system.sh -- <args>                    # latest chapter + pass-through
#   ./system/ralph-loop-system.sh --help
# ═══════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHAPTERS_DIR="$SCRIPT_DIR/chapters"
LOOP_SCRIPT="$REPO_ROOT/scripts/ralph-loop.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [CHAPTER] [-- loop args...]

Run the Ralph Loop against a chapter under system/chapters/.
If CHAPTER is omitted, the most recent dated chapter is used.

Examples:
  $(basename "$0")
  $(basename "$0") 2026-05-24-modularize-loop-prompts
  $(basename "$0") -- --stories 1.1 --max-budget-usd 2

Available chapters:
EOF
  if [[ -d "$CHAPTERS_DIR" ]]; then
    find "$CHAPTERS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' 2>/dev/null | sort
  else
    echo "  (none — $CHAPTERS_DIR does not exist)"
  fi
}

# ──── Parse args ────
CHAPTER=""
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      PASSTHROUGH=("$@")
      break
      ;;
    -*)
      # Unknown flag — pass through to ralph-loop.sh
      PASSTHROUGH=("$@")
      break
      ;;
    *)
      if [[ -z "$CHAPTER" ]]; then
        CHAPTER="$1"
        shift
      else
        PASSTHROUGH=("$@")
        break
      fi
      ;;
  esac
done

# ──── Resolve chapter ────
if [[ -z "$CHAPTER" ]]; then
  if [[ ! -d "$CHAPTERS_DIR" ]]; then
    echo "error: $CHAPTERS_DIR does not exist" >&2
    exit 1
  fi
  CHAPTER=$(find "$CHAPTERS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-' \
    | sort -r \
    | head -n 1)
  if [[ -z "$CHAPTER" ]]; then
    echo "error: no dated chapters found in $CHAPTERS_DIR" >&2
    echo "       (expected folders named YYYY-MM-DD-slug)" >&2
    exit 1
  fi
  echo "→ using latest chapter: $CHAPTER"
fi

CHAPTER_DIR="$CHAPTERS_DIR/$CHAPTER"
if [[ ! -d "$CHAPTER_DIR" ]]; then
  echo "error: chapter '$CHAPTER' not found at $CHAPTER_DIR" >&2
  exit 1
fi

# ──── Locate PRD + epic ────
PRD="$CHAPTER_DIR/prd.md"
if [[ ! -f "$PRD" ]]; then
  echo "error: $PRD not found" >&2
  echo "       every chapter must have a prd.md" >&2
  exit 1
fi

EPIC=""
if [[ -d "$CHAPTER_DIR/epics" ]]; then
  EPIC=$(find "$CHAPTER_DIR/epics" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort | head -n 1)
fi
if [[ -z "$EPIC" || ! -f "$EPIC" ]]; then
  echo "error: no epic .md file found in $CHAPTER_DIR/epics/" >&2
  exit 1
fi

# ──── Resolve paths relative to repo root for the loop ────
PRD_REL="${PRD#$REPO_ROOT/}"
EPIC_REL="${EPIC#$REPO_ROOT/}"
STORIES_REL="${CHAPTER_DIR#$REPO_ROOT/}/stories"

# Default checkpoint: syntax validation + prompt composition validation.
# bash -n verifies both scripts parse as valid bash;
# --dry-run-prompts validates all layer files exist and assemble correctly.
DEFAULT_CHECKPOINT="bash -n $LOOP_SCRIPT && bash -n $SCRIPT_DIR/ralph-loop-system.sh && $LOOP_SCRIPT --dry-run-prompts >/dev/null"

# ──── Report and exec ────
echo "→ PRD:      $PRD_REL"
echo "→ Epic:     $EPIC_REL"
echo "→ Stories:  $STORIES_REL"
echo "→ Loop:     scripts/ralph-loop.sh --project-dir ."
echo

# Override the loop's default STORIES_DIR so SM-generated story specs land
# in the chapter's stories/ folder, not in docs/stories/ (which belongs to
# the Demo Track). The loop reads STORIES_DIR via env var since the
# fix(system): unblock first chapter run commit.
export STORIES_DIR="$REPO_ROOT/$STORIES_REL"

# Tell the loop's auto-commit step which extra paths to stage for System
# Track stories. The loop's default staging list covers Demo Track work
# (src/, docs/stories/); System Track work touches the loop script, the
# wrapper, root docs, and the chapter's own folder. Without these the
# feat(X.Y): commits land empty of code — see fix(1.2,1.3) for the
# precedent that motivated this env var.
export EXTRA_STAGE_PATHS="scripts/ system/ README.md CLAUDE.md TIMELINE.md"

cd "$REPO_ROOT"
exec "$LOOP_SCRIPT" \
  --prd "$PRD_REL" \
  --epic "$EPIC_REL" \
  --project-dir . \
  --checkpoint "$DEFAULT_CHECKPOINT" \
  "${PASSTHROUGH[@]}"
