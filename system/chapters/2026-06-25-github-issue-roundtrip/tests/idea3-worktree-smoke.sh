#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Offline smoke — Idea 3 / issue #4 "Worktree-per-Issue".
#
# Subject under test: ensure_issue_worktree() / remove_issue_worktree() /
# worktree_exit_trap() in scripts/ralph-loop.sh (the RALPH ISSUE WORKTREE fenced
# block) — the functions that, in --worktree mode, run each Path A issue inside its
# own git worktree at .ralph/worktrees/issue-N (INSIDE the repo, gitignored — NOT a
# sibling ../ dir, honoring the self-contained-repo guardrail), re-point the run into
# it, and tear it down ONLY on a fully-green exit.
#
# Agent-runnable, deterministic, NO network, NO real repo. The block is extracted
# from its sentinels and sourced into THROWAWAY git fixture repos (temp dirs). The
# orchestrator's main() is never run.
#
# Proves (issue #4 ACs in parentheses):
#   1. The fenced block defines all three functions.
#   2. Parity (AC 5): USE_WORKTREE=0 → ensure_issue_worktree returns 0, creates
#      nothing, and re-points no variables.
#   3. Create (AC 1): a fresh run adds .ralph/worktrees/issue-7 on ralph/issue-7,
#      re-points REPO_ROOT/PROJECT_DIR/STORIES_DIR/EPIC_FILE into it, writes the
#      breadcrumb, and leaves the MAIN tree's `git status --porcelain` EMPTY.
#   4. Resume: a second call reuses the same worktree (no error, no second worktree).
#   5. Reaper (AC 3): a crashed run's tree resumes cleanly; after an `rm -rf` of the
#      dir, the next run's `worktree prune` reclaims the registration and a fresh add
#      succeeds — no orphaned worktree, and the branch never dangles.
#   6. Completion check (AC 2): a feat(7.1) commit on the worktree branch is found by
#      the `git log --all` grep run from INSIDE the worktree (is_story_complete
#      semantics hold).
#   7. Success teardown: worktree_exit_trap with RALPH_ALL_GREEN=1 + rc 0 removes the
#      tree (branch kept, breadcrumb gone); with all-green=0 OR rc≠0 the tree is kept.
#   8. Untracked-droppings removal: an untracked docs/prd/issue-7-pr.txt does NOT block
#      success teardown (the --force rationale).
#   9. Main-tree-on-branch conflict → hard error, non-zero, clear message.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tests/ -> chapter -> chapters -> system -> repo root
REPO_ROOT_REAL="$(cd "$SMOKE_DIR/../../../.." && pwd)"
LOOP="$REPO_ROOT_REAL/scripts/ralph-loop.sh"

PASS=0
FAIL=0
pass() { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

extract_worktree() {
  awk '
    /# >>> RALPH ISSUE WORKTREE/ { f = 1 }
    f                            { print }
    /# <<< RALPH ISSUE WORKTREE/ { f = 0 }
  ' "$LOOP"
}

# Seed a throwaway MAIN repo: base branch `main`, tracked src/ + docs/ (so the
# worktree checkout has them), and a .gitignore that ignores .ralph/ (so the
# in-repo worktree never dirties the main tree).
make_main_repo() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "smoke@example.com"
  git -C "$d" config user.name "Smoke Test"
  mkdir -p "$d/src" "$d/docs"
  : > "$d/src/.gitkeep"
  : > "$d/docs/.gitkeep"
  printf '.ralph/\n' > "$d/.gitignore"
  git -C "$d" add -A
  git -C "$d" commit -q -m "seed"
  printf '%s\n' "$d"
}

# Run ensure_issue_worktree in an isolated subshell against MAIN, with log_*
# shimmed. Emits the re-pointed run globals as KEY=VALUE lines for the parent to
# parse. RALPH_ALL_GREEN=0 so the EXIT trap (registered on success) KEEPS the tree.
# env: USE_WORKTREE (default 1), ISSUE_NUMBER, MAIN, optional STORIES_DIR override.
run_wt() {
  (
    set +e
    USE_WORKTREE="${USE_WORKTREE:-1}"
    REPO_ROOT="$MAIN"
    RALPH_MAIN_ROOT=""
    PROJECT_DIR_ARG="${PROJECT_DIR_ARG:-src}"
    PROJECT_DIR="$MAIN/$PROJECT_DIR_ARG"
    STORIES_DIR="${STORIES_DIR:-$MAIN/docs/stories}"
    MASTER_PROGRESS_FILE="$STORIES_DIR/ralph-sprint-progress.md"
    EPIC_FILE=""
    PRD_FILE=""
    RALPH_ALL_GREEN=0
    log_info()    { :; }
    log_success() { :; }
    log_warn()    { :; }
    log_error()   { printf 'ERR %s\n' "$1" >&2; }
    log_dim()     { :; }
    log_plain()   { :; }
    # shellcheck disable=SC1090
    source <(extract_worktree)
    ensure_issue_worktree
    local rc=$?
    printf 'RC=%s\n' "$rc"
    printf 'REPO_ROOT=%s\n' "$REPO_ROOT"
    printf 'PROJECT_DIR=%s\n' "$PROJECT_DIR"
    printf 'STORIES_DIR=%s\n' "$STORIES_DIR"
    printf 'MASTER_PROGRESS_FILE=%s\n' "$MASTER_PROGRESS_FILE"
    printf 'EPIC_FILE=%s\n' "$EPIC_FILE"
    printf 'PRD_FILE=%s\n' "$PRD_FILE"
    printf 'RALPH_MAIN_ROOT=%s\n' "$RALPH_MAIN_ROOT"
    exit "$rc"
  )
}

# Call worktree_exit_trap directly in a subshell with a controlled exit code and
# all-green flag (no EXIT trap of our own is registered here — we invoke the teardown
# path deterministically). $1 = RALPH_ALL_GREEN, $2 = simulated rc (0 or non-zero).
run_exit_trap() { # env: MAIN, ISSUE_NUMBER
  (
    set +e
    RALPH_MAIN_ROOT="$MAIN"
    ISSUE_NUMBER="${ISSUE_NUMBER:-7}"
    RALPH_ALL_GREEN="$1"
    log_info()    { :; }
    log_success() { :; }
    log_warn()    { :; }
    log_error()   { printf 'ERR %s\n' "$1" >&2; }
    # shellcheck disable=SC1090
    source <(extract_worktree)
    ( exit "$2" )   # set $? to the simulated exit code, then...
    worktree_exit_trap
  )
}

field() { grep "^$1=" <<< "$2" | head -1 | cut -d= -f2-; }
wt_count() { git -C "$1" worktree list --porcelain | grep -c '^worktree '; }
branch_exists() { git -C "$1" show-ref --verify --quiet "refs/heads/ralph/issue-$2"; }

echo "── Idea 3 worktree-per-issue smoke ───────────────────────────"

# ── 1. Sanity: the fenced block defines all three functions ──
wt_src="$(extract_worktree)"
if grep -q 'ensure_issue_worktree()' <<< "$wt_src" \
   && grep -q 'remove_issue_worktree()' <<< "$wt_src" \
   && grep -q 'worktree_exit_trap()' <<< "$wt_src"; then
  pass "fenced block defines ensure/remove/exit-trap"
else
  fail "fenced RALPH ISSUE WORKTREE block missing a function"
fi

# ── 2. Parity (AC 5): USE_WORKTREE=0 → no-op, nothing created, no re-point ──
MAIN="$(make_main_repo)"
out="$(USE_WORKTREE=0 ISSUE_NUMBER=7 run_wt)"; rc="$(field RC "$out")"
if [[ "$rc" -eq 0 \
      && "$(field REPO_ROOT "$out")" == "$MAIN" \
      && -z "$(field RALPH_MAIN_ROOT "$out")" \
      && ! -e "$MAIN/.ralph" \
      && -z "$(git -C "$MAIN" status --porcelain)" ]]; then
  pass "parity: USE_WORKTREE=0 returns 0, creates nothing, re-points nothing"
else
  fail "parity broke: rc=$rc REPO_ROOT=$(field REPO_ROOT "$out") main_root=[$(field RALPH_MAIN_ROOT "$out")] ralph_exists=$([[ -e $MAIN/.ralph ]] && echo yes) status=[$(git -C "$MAIN" status --porcelain)]"
fi
rm -rf "$MAIN"

# ── 3. Create (AC 1): fresh run → worktree + re-point + breadcrumb, main clean ──
MAIN="$(make_main_repo)"
WT="$MAIN/.ralph/worktrees/issue-7"
out="$(USE_WORKTREE=1 ISSUE_NUMBER=7 run_wt)"; rc="$(field RC "$out")"
ok=1
[[ "$rc" -eq 0 ]] || ok=0
[[ -d "$WT" ]] && git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || ok=0
[[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)" == "ralph/issue-7" ]] || ok=0
[[ "$(field REPO_ROOT "$out")" == "$WT" ]] || ok=0
[[ "$(field PROJECT_DIR "$out")" == "$(cd "$WT/src" && pwd)" ]] || ok=0
[[ "$(field STORIES_DIR "$out")" == "$WT/docs/stories" ]] || ok=0
[[ "$(field EPIC_FILE "$out")" == "$WT/docs/epics/issue-7.md" ]] || ok=0
[[ -f "$MAIN/.ralph/worktrees/issue-7.info" ]] || ok=0
[[ -z "$(git -C "$MAIN" status --porcelain)" ]] || ok=0
if [[ "$ok" -eq 1 ]]; then
  pass "create: worktree on ralph/issue-7, run re-pointed, breadcrumb written, MAIN tree clean"
else
  fail "create failed: rc=$rc REPO_ROOT=$(field REPO_ROOT "$out") PROJECT_DIR=$(field PROJECT_DIR "$out") STORIES_DIR=$(field STORIES_DIR "$out") EPIC=$(field EPIC_FILE "$out") wtHEAD=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null) info=$([[ -f $MAIN/.ralph/worktrees/issue-7.info ]] && echo yes) status=[$(git -C "$MAIN" status --porcelain)]"
fi

# ── 4. Resume: a second call reuses the same worktree, no second worktree ──
out="$(USE_WORKTREE=1 ISSUE_NUMBER=7 run_wt)"; rc="$(field RC "$out")"
if [[ "$rc" -eq 0 && -d "$WT" && "$(wt_count "$MAIN")" -eq 2 \
      && "$(field REPO_ROOT "$out")" == "$WT" ]]; then
  pass "resume: reused existing worktree (rc=0, exactly 2 worktrees, same dir)"
else
  fail "resume broke: rc=$rc wt_count=$(wt_count "$MAIN") REPO_ROOT=$(field REPO_ROOT "$out")"
fi

# ── 5. Reaper (AC 3): rm -rf the dir → prune reclaims + fresh add, no orphans ──
rm -rf "$WT"                       # simulate a leaked/deleted worktree dir
out="$(USE_WORKTREE=1 ISSUE_NUMBER=7 run_wt)"; rc="$(field RC "$out")"
if [[ "$rc" -eq 0 && -d "$WT" \
      && "$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)" == "ralph/issue-7" \
      && "$(wt_count "$MAIN")" -eq 2 \
      && $(branch_exists "$MAIN" 7 && echo yes) == "yes" ]]; then
  pass "reaper: prune reclaimed the stale registration, fresh add succeeded, branch intact, no orphans"
else
  fail "reaper broke: rc=$rc dir=$([[ -d $WT ]] && echo yes) wtHEAD=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null) wt_count=$(wt_count "$MAIN") branch=$(branch_exists "$MAIN" 7 && echo yes || echo no)"
fi

# ── 6. Completion check (AC 2): feat(7.1) commit found by git-log grep from INSIDE
#      the worktree — the exact query is_story_complete() uses ──
: > "$WT/src/feature.txt"
git -C "$WT" add -A
git -C "$WT" commit -q -m "feat(7.1): add feature"
if ( cd "$WT/src" && git log --oneline --all 2>/dev/null | grep -qE 'feat\(7\.1\):' ); then
  pass "completion check: feat(7.1) commit visible to git-log grep from inside the worktree"
else
  fail "completion check: feat(7.1) not found from inside the worktree"
fi

# ── 7a. Success teardown: all-green=1 + rc 0 → tree removed, branch kept, info gone ──
run_exit_trap 1 0 >/dev/null 2>&1
if [[ ! -d "$WT" && "$(wt_count "$MAIN")" -eq 1 \
      && $(branch_exists "$MAIN" 7 && echo yes) == "yes" \
      && ! -f "$MAIN/.ralph/worktrees/issue-7.info" ]]; then
  pass "success teardown: worktree removed, branch kept, breadcrumb gone"
else
  fail "success teardown broke: dir=$([[ -d $WT ]] && echo yes) wt_count=$(wt_count "$MAIN") branch=$(branch_exists "$MAIN" 7 && echo yes || echo no) info=$([[ -f $MAIN/.ralph/worktrees/issue-7.info ]] && echo yes)"
fi

# ── 7b. Kept when NOT all-green (all-green=0, rc 0) and when rc≠0 (all-green=1) ──
out="$(USE_WORKTREE=1 ISSUE_NUMBER=7 run_wt)"   # recreate the tree
run_exit_trap 0 0 >/dev/null 2>&1               # all-green=0 → keep
kept_notgreen=$([[ -d "$WT" ]] && echo yes || echo no)
run_exit_trap 1 3 >/dev/null 2>&1               # all-green=1 but rc≠0 → keep
kept_rcfail=$([[ -d "$WT" ]] && echo yes || echo no)
if [[ "$kept_notgreen" == "yes" && "$kept_rcfail" == "yes" ]]; then
  pass "teardown gate: tree kept when not all-green and when rc≠0 (uncommitted plans never destroyed)"
else
  fail "teardown gate broke: kept_notgreen=$kept_notgreen kept_rcfail=$kept_rcfail"
fi

# ── 8. Untracked-droppings: an untracked issue-7-pr.txt must NOT block --force removal ──
mkdir -p "$WT/docs/prd"
printf 'https://example/pull/1\n' > "$WT/docs/prd/issue-7-pr.txt"   # untracked runtime dropping
run_exit_trap 1 0 >/dev/null 2>&1
if [[ ! -d "$WT" && "$(wt_count "$MAIN")" -eq 1 ]]; then
  pass "untracked droppings: --force teardown removes the tree despite an untracked pr.txt"
else
  fail "untracked droppings: tree not removed (dir=$([[ -d $WT ]] && echo yes) wt_count=$(wt_count "$MAIN"))"
fi

# ── 9. Main-tree-on-branch conflict → hard error, non-zero, clear message ──
git -C "$MAIN" checkout -q ralph/issue-7          # main tree now sits ON the branch
# run_wt is EXPECTED to fail here; capture rc without tripping `set -e` (slice-a idiom).
conflict_rc=0
conflict_out="$(USE_WORKTREE=1 ISSUE_NUMBER=7 run_wt 2>&1)" || conflict_rc=$?
if [[ "$conflict_rc" -ne 0 ]] && grep -q 'main tree is on ralph/issue-7' <<< "$conflict_out"; then
  pass "conflict: main tree on the branch → hard error, non-zero, actionable message"
else
  fail "conflict not caught: rc=$conflict_rc out=[$conflict_out]"
fi
rm -rf "$MAIN"

echo "──────────────────────────────────────────────────────────────"
printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
