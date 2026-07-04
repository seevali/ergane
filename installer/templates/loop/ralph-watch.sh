#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# ralph-watch.sh — Mission Control for the Ralph swarm (issue #5, Idea 5 v1).
#
# A READ-ONLY terminal dashboard over the serial swarm driver (scripts/ralph-loop.sh
# --issues …) PLUS the pause/resume/abort brake CLI. One row per job: issue, state,
# story X/Y, elapsed, cost, and a health glyph that surfaces the ONE anomaly among
# healthy jobs (a stuck/stale running job) — triage, not monitoring (issue #5 AC 2).
#
# It reads ONLY the driver's local artifacts under .ralph/ (per-job status files and
# each job's worktree progress file). It never calls `gh`, never touches the network,
# and its ONLY writes are the brake control files (pause/abort → write, resume → delete).
# It never merges or closes anything — merging/closing stay the operator's (ADR-001 I3).
#
# Subcommands:
#   watch [--once]     clear-screen render loop, 2s interval (default). --once = one frame.
#   ls                 one-shot plain table (no screen clearing).
#   pause N            write control file `pause` for issue N (child parks at next step).
#   resume N           delete issue N's control file (child resumes at next step).
#   abort N            write control file `abort` for issue N (child exits 4 at next step).
#   help               this help.
#
# Options:
#   --jobs-dir DIR     override the jobs dir (default <repo>/.ralph/jobs).
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JOBS_DIR="$REPO_ROOT/.ralph/jobs"

# Health-glyph staleness threshold: a `running` job whose status AND progress files are
# both untouched for longer than this is flagged stuck (issue #5 AC 2's anomaly flag).
STALE_SECS=600
WATCH_INTERVAL=2

# ── Colors (degrade gracefully when not a TTY) ──
if [[ -t 1 ]]; then
  C_DIM=$'\033[2m'; C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
else
  C_DIM=''; C_RESET=''; C_BOLD=''
fi

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ── Argument parsing: pull out --jobs-dir anywhere, keep the rest positional ──
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs-dir) JOBS_DIR="$2"; shift 2 ;;
    -h|--help|help) usage 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]:-}"

SUBCMD="${1:-watch}"

# ── Read one key=value field from a status file (empty if absent) ──
status_field() { # $1=file $2=key
  [[ -f "$1" ]] || { printf ''; return; }
  local v; v="$(grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-)"
  printf '%s' "$v"
}

# ── File mtime in epoch seconds (portable-ish; 0 if missing) ──
file_mtime() { # $1=file
  [[ -e "$1" ]] || { printf '0'; return; }
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)" || m="$(stat -f %m "$1" 2>/dev/null)" || m=0
  printf '%s' "${m:-0}"
}

format_elapsed() { # $1=seconds
  local secs="$1"
  [[ "$secs" =~ ^[0-9]+$ ]] || { printf '?'; return; }
  local m=$((secs / 60)) s=$((secs % 60))
  if [[ $m -gt 0 ]]; then printf '%dm%02ds' "$m" "$s"; else printf '%ds' "$s"; fi
}

# ── Parse story X/Y (Done rows over total story rows) and run-total cost from a
#    job's worktree progress file. `?` fallbacks when the file is missing/unreadable. ──
progress_story_xy() { # $1=progress_file
  [[ -f "$1" ]] || { printf '?/?'; return; }
  awk -F'|' '
    /^\| +[0-9]+\.[0-9]+ +\|/ {
      total++
      st=$4; gsub(/^ +| +$/, "", st)
      if (st == "Done") done++
    }
    END { printf "%s/%s", (total ? done+0 : "?"), (total ? total : "?") }
  ' "$1" 2>/dev/null || printf '?/?'
}

progress_cost() { # $1=progress_file
  [[ -f "$1" ]] || { printf '?'; return; }
  local c
  c="$(grep -m1 'Total cost' "$1" 2>/dev/null | awk -F'|' '{ v=$3; gsub(/[^0-9.]/, "", v); print v }')"
  [[ -n "$c" ]] && printf '$%s' "$c" || printf '?'
}

# ── Health glyph from state + staleness (issue #5 AC 2 surfaces the one stuck job) ──
health_glyph() { # $1=state $2=stale(0|1)
  case "$1" in
    queued)          printf '⏳' ;;
    running)         [[ "$2" == "1" ]] && printf '‼' || printf '🔨' ;;
    paused)          printf '⏸' ;;
    done)            printf '✅' ;;
    parked)          printf '🅿' ;;
    failed|aborted)  printf '❌' ;;
    *)               printf '?' ;;
  esac
}

# ── Render every job as a table (shared by `ls` and `watch`) ──
render_table() {
  local now; now="$(date +%s)"
  printf '%s%-7s %-9s %-8s %-9s %-9s %s%s\n' \
    "$C_BOLD" "ISSUE" "STATE" "STORY" "ELAPSED" "COST" "HEALTH" "$C_RESET"

  local found=0 f
  # Sort numerically by issue number for a stable dashboard.
  local -a files=()
  while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(
    ls "$JOBS_DIR"/issue-*.status 2>/dev/null \
      | sed -E 's#.*/issue-([0-9]+)\.status#\1 &#' | sort -n | cut -d' ' -f2-
  )

  for f in "${files[@]:-}"; do
    [[ -f "$f" ]] || continue
    found=1
    local issue state started wt
    issue="$(status_field "$f" issue)"
    state="$(status_field "$f" state)"
    started="$(status_field "$f" started_epoch)"
    wt="$(status_field "$f" worktree)"

    local elapsed='?'
    [[ "$started" =~ ^[0-9]+$ ]] && elapsed="$(format_elapsed $((now - started)))"

    # Story X/Y + cost live in the job's worktree progress file.
    local pf="$wt/docs/stories/ralph-sprint-progress-${issue}.md"
    local xy cost
    xy="$(progress_story_xy "$pf")"
    cost="$(progress_cost "$pf")"

    # Staleness: newest of (status file, progress file) mtime. A healthy running job
    # refreshes its progress file between steps; a stuck one refreshes neither.
    local stale=0
    if [[ "$state" == "running" ]]; then
      local sm pm newest
      sm="$(file_mtime "$f")"; pm="$(file_mtime "$pf")"
      newest=$sm; [[ "$pm" -gt "$newest" ]] && newest=$pm
      [[ $((now - newest)) -gt $STALE_SECS ]] && stale=1
    fi

    local glyph; glyph="$(health_glyph "$state" "$stale")"
    printf '#%-6s %-9s %-8s %-9s %-9s %s\n' \
      "$issue" "$state" "$xy" "$elapsed" "$cost" "$glyph"
  done

  [[ "$found" -eq 1 ]] || printf '%s(no jobs — run ralph-loop.sh --issues … to start a swarm)%s\n' "$C_DIM" "$C_RESET"
}

# ── Brake control-file writers (the ONLY writes this script performs) ──
require_issue() { # $1=issue arg
  [[ -n "${1:-}" ]] || { echo "Error: this subcommand needs an issue number (e.g. $SUBCMD 12)" >&2; exit 2; }
  [[ "$1" =~ ^[0-9]+$ ]] || { echo "Error: issue must be a positive integer (got '$1')" >&2; exit 2; }
}

do_pause() { # $1=issue
  require_issue "${1:-}"
  mkdir -p "$JOBS_DIR"
  printf 'pause' > "$JOBS_DIR/issue-$1.control"
  echo "Wrote pause for issue #$1 — takes effect at the child's next between-steps check."
}

do_resume() { # $1=issue
  require_issue "${1:-}"
  rm -f "$JOBS_DIR/issue-$1.control"
  echo "Cleared the brake for issue #$1 — the child resumes at its next between-steps check."
}

do_abort() { # $1=issue
  require_issue "${1:-}"
  mkdir -p "$JOBS_DIR"
  printf 'abort' > "$JOBS_DIR/issue-$1.control"
  echo "Wrote abort for issue #$1 — the child stops (exit 4) at its next between-steps check. Other jobs are untouched."
}

# ── Dispatch ──
case "$SUBCMD" in
  ls)
    render_table
    ;;
  watch)
    once=0
    [[ "${2:-}" == "--once" ]] && once=1
    if [[ "$once" -eq 1 ]]; then
      render_table
    else
      while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        printf '%sRalph Mission Control%s — %s  (jobs: %s)\n\n' "$C_BOLD" "$C_RESET" "$(date '+%H:%M:%S')" "$JOBS_DIR"
        render_table
        printf '\n%spause N · resume N · abort N — Ctrl-C to exit%s\n' "$C_DIM" "$C_RESET"
        sleep "$WATCH_INTERVAL"
      done
    fi
    ;;
  pause)  do_pause  "${2:-}" ;;
  resume) do_resume "${2:-}" ;;
  abort)  do_abort  "${2:-}" ;;
  *)
    echo "Unknown subcommand: $SUBCMD" >&2
    usage 2
    ;;
esac
