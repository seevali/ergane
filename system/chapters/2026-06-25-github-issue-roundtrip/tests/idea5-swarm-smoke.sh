#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Offline smoke — Idea 5 / issue #5 "The Swarm + Mission Control (v1, SERIAL)".
#
# Subjects under test (all in scripts/ralph-loop.sh + scripts/ralph-watch.sh):
#   • run_swarm_driver() / swarm_job_status() — the RALPH SWARM DRIVER fenced block:
#     the SERIAL multi-issue burn-down that resolves a queue, runs one child at a time
#     (each `--issue N --worktree`), records per-job status, and never lets a non-zero
#     child stop the queue (v1 has NO concurrency — that is a v2 bet, prd.md §3 Idea 5).
#   • check_interrupted()'s additive brake extension — pause/resume/abort honored
#     between steps, guarded on RALPH_JOBS_DIR + ISSUE_NUMBER (unset ⇒ parity/no-op).
#   • scripts/ralph-watch.sh — the read-only dashboard (ls / watch --once) + brake CLI.
#
# Agent-runnable, deterministic, NO network, NO real GitHub. The driver block and
# check_interrupted are extracted from the loop and sourced into subshells; a FAKE
# CHILD script (wired via RALPH_SWARM_CHILD_CMD) stands in for a real single-issue
# run — it records its argv, marks serial ordering, writes a fake progress file, and
# exits per-fixture (0/2/1/4). main() is never run; the network is never touched.
#
# Proves (issue #5 ACs in parentheses):
#   1. Driver sentinel extraction defines swarm_job_status + run_swarm_driver.
#   2. Queue parsing: comma list is trimmed + de-duplicated (order preserved); a bad
#      token → usage error; `ready` mode queries `--label ralph:ready --state open` and
#      sorts ascending; an empty queue exits 0 with a friendly log.
#   3. Serial order (AC 1): the fake child's START/END markers never overlap and match
#      the queue order (v1 serial — concurrency is v2).
#   4. Forwarding: the child receives `--issue N --worktree --triage … --checkpoint …`;
#      `--write` is present ONLY when the driver ran with --write.
#   5. Status lifecycle: files go queued→running→done; rc 2 → parked; rc 1 → failed;
#      rc 4 → aborted; a failing child does NOT stop later jobs; driver returns 0 when
#      all done, else 2.
#   6. Brake (AC 3): pause writes a control file, the child (real check_interrupted)
#      blocks while paused + shows state=paused, resumes on resume, exits 4 + state=
#      aborted on abort; and the extension is a NO-OP when RALPH_JOBS_DIR is unset.
#   7. Watch (AC 2): ls / watch --once render one row per job with the right state
#      glyphs, story X/Y, and cost; a stale running job shows the stuck glyph.
#   8. No auto-merge/close (ADR-001 I3): the driver's summary carries the reviewer-
#      despair line and the no-merge/close line, and its output has ZERO gh pr merge /
#      pr close / issue close.
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tests/ -> chapter -> chapters -> system -> repo root
REPO_ROOT_REAL="$(cd "$SMOKE_DIR/../../../.." && pwd)"
LOOP="$REPO_ROOT_REAL/scripts/ralph-loop.sh"
WATCH="$REPO_ROOT_REAL/scripts/ralph-watch.sh"

PASS=0
FAIL=0
pass() { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

extract_driver() {
  awk '
    /# >>> RALPH SWARM DRIVER/ { f = 1 }
    f                          { print }
    /# <<< RALPH SWARM DRIVER/ { f = 0 }
  ' "$LOOP"
}
extract_check_interrupted() {
  awk '
    /^check_interrupted\(\) \{/ { f = 1 }
    f                           { print }
    f && /^\}/                  { f = 0 }
  ' "$LOOP"
}

TMP="$(mktemp -d)"
GH_BIN="$(mktemp -d)"
trap 'rm -rf "$TMP" "$GH_BIN"' EXIT

# ── Offline `gh` stub for the `ready` queue path. `issue list` returns the numbers in
#    $GH_READY_NUMS (unsorted, to prove the driver sorts). Records its argv so the query
#    filter can be asserted. Never touches the network. ──
cat > "$GH_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$GH_CALL_LOG"
case "${1:-}:${2:-}" in
  repo:view)  printf '%s\n' "${GH_SLUG:-seevali/ralph-loop-demo}"; exit 0 ;;
  issue:list) printf '%s\n' "${GH_READY_NUMS:-}"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$GH_BIN/gh"

# ── The FAKE CHILD: records argv per issue, marks serial ordering, writes a fake
#    progress file into the worktree the driver assigned, and exits per-fixture. ──
FAKE_CHILD="$TMP/fake-child.sh"
cat > "$FAKE_CHILD" <<'CHILD'
#!/usr/bin/env bash
iss=""
argv=("$@")
for ((i=0; i<${#argv[@]}; i++)); do
  [[ "${argv[$i]}" == "--issue" ]] && iss="${argv[$((i+1))]}"
done
[[ -n "$iss" ]] || { echo "fake child: no --issue" >&2; exit 99; }
printf '%s\n' "$*" > "$ARGV_LOG_DIR/issue-$iss.argv"
printf 'START %s\n' "$iss" >> "$ORDER_LOG"
sleep 0.12
# Derive the worktree the driver recorded, write a fake progress file the watch reads.
wt="$(grep -m1 '^worktree=' "$RALPH_JOBS_DIR/issue-$iss.status" 2>/dev/null | cut -d= -f2-)"
if [[ -n "$wt" ]]; then
  mkdir -p "$wt/docs/stories"
  cat > "$wt/docs/stories/ralph-sprint-progress-$iss.md" <<PROG
| **Total cost** | \$0.1000 |
| Story | Title | Status | Duration | Retries | Cost | Notes |
|-------|-------|--------|----------|---------|------|-------|
| $iss.1 | A | Done | 1m | 0 | \$0.05 | — |
| $iss.2 | B | Pending | — | — | \$0.00 | — |
PROG
fi
printf 'END %s\n' "$iss" >> "$ORDER_LOG"
rc=0
[[ -f "$FAKE_RC_DIR/issue-$iss.rc" ]] && rc="$(cat "$FAKE_RC_DIR/issue-$iss.rc")"
exit "$rc"
CHILD
chmod +x "$FAKE_CHILD"

export ARGV_LOG_DIR="$TMP/argv"; mkdir -p "$ARGV_LOG_DIR"
export ORDER_LOG="$TMP/order.log"
export FAKE_RC_DIR="$TMP/rc"; mkdir -p "$FAKE_RC_DIR"
export GH_CALL_LOG="$TMP/gh-calls.log"

# ── Run the driver in a subshell with all knobs set, log_* shimmed to stdout, gh stub
#    on PATH, and the fake child wired via RALPH_SWARM_CHILD_CMD. Emits the driver's
#    return code as the subshell exit status; its log goes to stdout. ──
run_driver() { # env: DRV_ISSUES, DRV_ROOT, DRV_WRITE, DRV_SLUG
  (
    set +e
    PATH="$GH_BIN:$PATH"
    RED=''; NC=''; YELLOW=''; GREEN=''; CYAN=''; DIM=''
    ISSUES_ARG="$DRV_ISSUES"
    REPO_ROOT="$DRV_ROOT"
    REPO_SLUG="${DRV_SLUG:-}"
    GITHUB_WRITE="${DRV_WRITE:-0}"
    PROJECT_DIR_ARG="src"
    CHECKPOINT_CMD="cd src && npm run build && npm test"
    TRIAGE_MODE="auto"; ARCHITECTURE_MODE="auto"
    MODEL_SM=haiku; MODEL_DEV=sonnet; MODEL_REVIEW=opus
    MODEL_PM=opus; MODEL_ARCHITECT=opus; MODEL_PLANNER=sonnet
    MAX_TURNS_SM=15; MAX_TURNS_DEV=40; MAX_TURNS_REVIEW=25
    MAX_ITERATIONS=50; MAX_REVIEW_RETRIES=3; MAX_UPSTREAM_DEPTH=1
    BUDGET_PER_INVOCATION_USD=""; BUDGET_PER_STORY_USD=""
    RALPH_SWARM_CHILD_CMD=("$FAKE_CHILD")
    log_info()    { printf '%s\n' "$1"; }
    log_error()   { printf 'ERR %s\n' "$1"; }
    log_warn()    { printf '%s\n' "$1"; }
    log_plain()   { printf '%s\n' "$1"; }
    log_success() { printf '%s\n' "$1"; }
    log_dim()     { :; }
    usage()       { printf 'USAGE-CALLED\n'; exit 7; }
    # shellcheck disable=SC1090
    source <(extract_driver)
    run_swarm_driver
    exit $?
  )
}

reset_fixture() { # $1=root
  rm -rf "$1"; mkdir -p "$1"
  : > "$ORDER_LOG"; : > "$GH_CALL_LOG"
  rm -f "$ARGV_LOG_DIR"/*.argv "$FAKE_RC_DIR"/*.rc 2>/dev/null || true
}
set_rc() { printf '%s' "$2" > "$FAKE_RC_DIR/issue-$1.rc"; }   # $1=issue $2=rc
job_state() { grep -m1 '^state=' "$1/.ralph/jobs/issue-$2.status" 2>/dev/null | cut -d= -f2-; }  # $1=root $2=issue
order_events() { awk '{print $1, $2}' "$ORDER_LOG"; }

echo "── Idea 5 swarm + mission-control smoke ──────────────────────"

# ── 1. Sentinel extraction defines both driver functions ──
drv_src="$(extract_driver)"
if grep -q 'swarm_job_status()' <<< "$drv_src" && grep -q 'run_swarm_driver()' <<< "$drv_src"; then
  pass "fenced RALPH SWARM DRIVER block defines swarm_job_status + run_swarm_driver"
else
  fail "fenced RALPH SWARM DRIVER block missing a function"
fi

# ── 2. Serial order + forwarding + status lifecycle + not-all-done → rc 2 ──
ROOT="$TMP/r-main"; reset_fixture "$ROOT"
set_rc 12 0; set_rc 15 2; set_rc 19 1     # done / parked / failed
DRV_ISSUES="12,15,19" DRV_ROOT="$ROOT" DRV_WRITE=0 run_driver > "$TMP/drv.out" 2>&1
drv_rc=$?

# 2a. Serial order (AC 1): START/END never interleave, order = queue order.
expected_order=$'START 12\nEND 12\nSTART 15\nEND 15\nSTART 19\nEND 19'
if [[ "$(order_events)" == "$expected_order" ]]; then
  pass "serial order: children ran one-at-a-time in queue order (no overlap; concurrency = v2)"
else
  fail "serial order broke — got:"; sed 's/^/      /' "$ORDER_LOG"
fi

# 2b. Forwarding: --issue/--worktree/--triage/--checkpoint present; --write ABSENT.
argv12="$(cat "$ARGV_LOG_DIR/issue-12.argv" 2>/dev/null || true)"
if grep -q -- '--issue 12' <<< "$argv12" \
   && grep -q -- '--worktree' <<< "$argv12" \
   && grep -q -- '--triage auto' <<< "$argv12" \
   && grep -q -- '--architecture auto' <<< "$argv12" \
   && grep -q -- '--checkpoint' <<< "$argv12" \
   && grep -q -- '--model-sm haiku' <<< "$argv12" \
   && grep -q -- '--max-turns-dev 40' <<< "$argv12" \
   && ! grep -q -- '--write' <<< "$argv12"; then
  pass "forwarding: child got --issue/--worktree/--triage/--checkpoint/models/turns; NO --write (write off)"
else
  fail "forwarding wrong (write off): [$argv12]"
fi

# 2c. Status lifecycle: done / parked / failed from rc 0 / 2 / 1.
if [[ "$(job_state "$ROOT" 12)" == "done" \
   && "$(job_state "$ROOT" 15)" == "parked" \
   && "$(job_state "$ROOT" 19)" == "failed" ]]; then
  pass "status lifecycle: rc 0→done, rc 2→parked, rc 1→failed"
else
  fail "status lifecycle wrong: 12=$(job_state "$ROOT" 12) 15=$(job_state "$ROOT" 15) 19=$(job_state "$ROOT" 19)"
fi

# 2d. A failing child (15) did NOT stop the queue (19 still ran) + rc 2 (not all done).
if grep -q '^END 19$' "$ORDER_LOG" && [[ "$drv_rc" -eq 2 ]]; then
  pass "burn-down: a non-zero child never stops the queue; driver returns 2 (not all done)"
else
  fail "burn-down broke: END-19=$(grep -c '^END 19$' "$ORDER_LOG") drv_rc=$drv_rc"
fi

# 2e. Summary carries the reviewer-despair line + the no-merge/close line; ZERO merge/close.
if grep -qF 'Review the opened PRs before queueing more work — if PRs pile up unreviewed, do NOT scale up; concurrency stays v2 (prd.md §7).' "$TMP/drv.out" \
   && grep -qF 'The loop opened PRs; merging and closing stay yours.' "$TMP/drv.out"; then
  pass "summary: reviewer-despair guard + no-merge/close reminder present (prd.md §7, ADR-001 I3)"
else
  fail "summary lines missing"; sed 's/^/      /' "$TMP/drv.out"
fi
if ! grep -Eq 'gh pr merge|gh pr close|gh issue close' "$TMP/drv.out" "$GH_CALL_LOG"; then
  pass "no auto-merge/close (I3): driver output + gh calls contain ZERO pr merge / pr close / issue close"
else
  fail "I3 VIOLATION: a merge/close appeared"; grep -E 'gh pr merge|gh pr close|gh issue close' "$TMP/drv.out" "$GH_CALL_LOG"
fi

# ── 3. All-done → rc 0; dedupe (12,15,12 → one 12); abort rc 4 → aborted ──
ROOT="$TMP/r-alldone"; reset_fixture "$ROOT"
set_rc 12 0; set_rc 15 0
DRV_ISSUES=" 12 , 15 , 12 " DRV_ROOT="$ROOT" DRV_WRITE=0 run_driver > "$TMP/drv2.out" 2>&1
drv_rc=$?
starts_12="$(grep -c '^START 12$' "$ORDER_LOG")"
if [[ "$drv_rc" -eq 0 && "$starts_12" -eq 1 \
   && "$(job_state "$ROOT" 12)" == "done" && "$(job_state "$ROOT" 15)" == "done" ]]; then
  pass "all-done → rc 0; whitespace trimmed + duplicate 12 de-duplicated (ran once)"
else
  fail "all-done/dedupe wrong: rc=$drv_rc starts_12=$starts_12 12=$(job_state "$ROOT" 12) 15=$(job_state "$ROOT" 15)"
fi

ROOT="$TMP/r-abort"; reset_fixture "$ROOT"
set_rc 8 4
DRV_ISSUES="8" DRV_ROOT="$ROOT" DRV_WRITE=0 run_driver > /dev/null 2>&1
if [[ "$(job_state "$ROOT" 8)" == "aborted" ]]; then
  pass "child rc 4 (brake abort) → job state=aborted"
else
  fail "abort mapping wrong: 8=$(job_state "$ROOT" 8)"
fi

# ── 4. --write ON → child receives --write ──
ROOT="$TMP/r-write"; reset_fixture "$ROOT"; set_rc 5 0
DRV_ISSUES="5" DRV_ROOT="$ROOT" DRV_WRITE=1 run_driver > /dev/null 2>&1
if grep -q -- '--write' "$ARGV_LOG_DIR/issue-5.argv"; then
  pass "forwarding: --write present in the child argv when the driver ran with --write"
else
  fail "--write not forwarded: [$(cat "$ARGV_LOG_DIR/issue-5.argv" 2>/dev/null)]"
fi

# ── 5. Bad token → usage error (non-zero) ──
ROOT="$TMP/r-bad"; reset_fixture "$ROOT"
DRV_ISSUES="12,oops,15" DRV_ROOT="$ROOT" DRV_WRITE=0 run_driver > "$TMP/bad.out" 2>&1
bad_rc=$?
if [[ "$bad_rc" -ne 0 ]] && grep -q 'USAGE-CALLED' "$TMP/bad.out"; then
  pass "queue validation: a non-integer token triggers a usage error (non-zero exit)"
else
  fail "bad token not rejected: rc=$bad_rc"; sed 's/^/      /' "$TMP/bad.out"
fi

# ── 6. `ready` mode: correct gh query + ascending sort; empty queue → rc 0 ──
ROOT="$TMP/r-ready"; reset_fixture "$ROOT"
set_rc 7 0; set_rc 12 0; set_rc 19 0
GH_READY_NUMS=$'19\n7\n12' GH_SLUG="seevali/ralph-loop-demo" \
  DRV_ISSUES="ready" DRV_ROOT="$ROOT" DRV_WRITE=0 run_driver > "$TMP/ready.out" 2>&1
ready_rc=$?
ready_order="$(grep '^START ' "$ORDER_LOG" | awk '{print $2}' | paste -sd, -)"
if [[ "$ready_rc" -eq 0 && "$ready_order" == "7,12,19" ]] \
   && grep -q 'issue list' "$GH_CALL_LOG" \
   && grep -q -- '--label ralph:ready' "$GH_CALL_LOG" \
   && grep -q -- '--state open' "$GH_CALL_LOG"; then
  pass "ready mode: gh queried --label ralph:ready --state open; queue sorted ascending (7,12,19)"
else
  fail "ready mode wrong: rc=$ready_rc order=$ready_order"; sed 's/^/      /' "$GH_CALL_LOG"
fi

ROOT="$TMP/r-empty"; reset_fixture "$ROOT"
GH_READY_NUMS="" DRV_ISSUES="ready" DRV_ROOT="$ROOT" DRV_WRITE=0 run_driver > "$TMP/empty.out" 2>&1
empty_rc=$?
if [[ "$empty_rc" -eq 0 ]] && grep -q 'queue is empty' "$TMP/empty.out"; then
  pass "empty ready queue → friendly log + exit 0"
else
  fail "empty queue wrong: rc=$empty_rc"; sed 's/^/      /' "$TMP/empty.out"
fi

# ═══ Brake tests (check_interrupted extension) ═══
# A tiny runner that sources the real extracted check_interrupted and calls it once.
BRAKE_RUNNER="$TMP/brake-runner.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set +eu'
  echo 'INTERRUPTED=false; CURRENT_STORY_IDX=-1; STORY_STATUSES=()'
  echo 'log_info(){ :; }; log_warn(){ :; }; log_success(){ :; }; update_progress_file(){ :; }'
  extract_check_interrupted
  echo 'check_interrupted; echo "RETURNED rc=$?"'
} > "$BRAKE_RUNNER"

BJD="$TMP/brake-jobs"; mkdir -p "$BJD"
seed_status() { # $1=issue $2=state
  cat > "$BJD/issue-$1.status" <<EOF
issue=$1
state=$2
started_epoch=$(date +%s)
updated_epoch=$(date +%s)
exit_code=
pid=123
worktree=$BJD/wt-$1
log=$BJD/issue-$1.log
EOF
}
brake_state() { grep -m1 '^state=' "$BJD/issue-$1.status" 2>/dev/null | cut -d= -f2-; }
wait_state() { # $1=issue $2=want $3=timeout
  local deadline=$(( $(date +%s) + ${3:-10} ))
  while [[ $(date +%s) -lt $deadline ]]; do
    [[ "$(brake_state "$1")" == "$2" ]] && return 0
    sleep 0.2
  done
  return 1
}

# ── 7. Parity: RALPH_JOBS_DIR unset → check_interrupted is a no-op (returns, no hang) ──
seed_status 12 running
parity_out="$(ISSUE_NUMBER=12 bash "$BRAKE_RUNNER" 2>&1)"   # RALPH_JOBS_DIR intentionally unset
if grep -q 'RETURNED rc=0' <<< "$parity_out" && [[ "$(brake_state 12)" == "running" ]]; then
  pass "brake parity: with RALPH_JOBS_DIR unset the extension is a no-op (returns 0, status untouched)"
else
  fail "brake parity broke: [$parity_out] state=$(brake_state 12)"
fi

# ── 8. Abort: control file `abort` → status aborted + exit 4 ──
seed_status 12 running
printf 'abort' > "$BJD/issue-12.control"
RALPH_JOBS_DIR="$BJD" ISSUE_NUMBER=12 bash "$BRAKE_RUNNER" > /dev/null 2>&1
abort_rc=$?
if [[ "$abort_rc" -eq 4 && "$(brake_state 12)" == "aborted" ]]; then
  pass "brake abort: control-file abort → child exits 4 and its status shows aborted"
else
  fail "brake abort broke: rc=$abort_rc state=$(brake_state 12)"
fi
rm -f "$BJD/issue-12.control"

# ── 9. Pause → resume: child blocks (state=paused), resumes on control-file removal ──
seed_status 12 running
printf 'pause' > "$BJD/issue-12.control"
RALPH_JOBS_DIR="$BJD" ISSUE_NUMBER=12 bash "$BRAKE_RUNNER" > "$TMP/pause.out" 2>&1 &
pause_pid=$!
if wait_state 12 paused 10; then
  # still blocked? the runner must not have returned yet.
  still_running=0; kill -0 "$pause_pid" 2>/dev/null && still_running=1
  rm -f "$BJD/issue-12.control"          # resume
  wait "$pause_pid" 2>/dev/null
  if [[ "$still_running" -eq 1 && "$(brake_state 12)" == "running" ]]; then
    pass "brake pause/resume: child parked at state=paused, then resumed to state=running"
  else
    fail "brake resume broke: blocked_while_paused=$still_running final=$(brake_state 12)"
  fi
else
  fail "brake pause: child never reached state=paused"; kill "$pause_pid" 2>/dev/null; sed 's/^/      /' "$TMP/pause.out"
fi

# ── 10. Pause → abort: while paused, an abort still wins (exit 4, state=aborted) ──
seed_status 12 running
printf 'pause' > "$BJD/issue-12.control"
RALPH_JOBS_DIR="$BJD" ISSUE_NUMBER=12 bash "$BRAKE_RUNNER" > /dev/null 2>&1 &
pa_pid=$!
if wait_state 12 paused 10; then
  printf 'abort' > "$BJD/issue-12.control"   # escalate pause → abort
  wait "$pa_pid"; pa_rc=$?
  if [[ "$pa_rc" -eq 4 && "$(brake_state 12)" == "aborted" ]]; then
    pass "brake pause→abort: an abort while paused wins (exit 4, state=aborted)"
  else
    fail "brake pause→abort broke: rc=$pa_rc state=$(brake_state 12)"
  fi
else
  fail "brake pause→abort: never reached paused"; kill "$pa_pid" 2>/dev/null
fi
rm -f "$BJD/issue-12.control"

# ═══ Watch dashboard tests (scripts/ralph-watch.sh) ═══
WJD="$TMP/watch-jobs"; mkdir -p "$WJD"
NOW="$(date +%s)"
mk_status() { # $1=issue $2=state $3=started_ago $4=worktree
  cat > "$WJD/issue-$1.status" <<EOF
issue=$1
state=$2
started_epoch=$((NOW - $3))
updated_epoch=$NOW
exit_code=
pid=
worktree=$4
log=$WJD/issue-$1.log
EOF
}
mk_progress() { # $1=issue $2=done $3=total $4=cost $5=worktree
  mkdir -p "$5/docs/stories"
  { printf '| **Total cost** | $%s |\n' "$4"
    printf '| Story | Title | Status | Duration | Retries | Cost | Notes |\n'
    printf '|---|---|---|---|---|---|---|\n'
    local i
    for ((i=1; i<=$3; i++)); do
      if [[ $i -le $2 ]]; then printf '| %s.%s | S | Done | 1m | 0 | $0.05 | — |\n' "$1" "$i"
      else printf '| %s.%s | S | Pending | — | — | $0.00 | — |\n' "$1" "$i"; fi
    done
  } > "$5/docs/stories/ralph-sprint-progress-$1.md"
}

# queued, running-fresh (2/3), done, parked, failed, and a STALE running job.
mk_status 12 queued 0 "$WJD/wt-12"
mk_status 15 running 130 "$WJD/wt-15"; mk_progress 15 2 3 0.4200 "$WJD/wt-15"
mk_status 7 done 300 "$WJD/wt-7";     mk_progress 7 2 2 0.9000 "$WJD/wt-7"
mk_status 9 parked 200 "$WJD/wt-9"
mk_status 3 failed 100 "$WJD/wt-3"
mk_status 19 running 4000 "$WJD/wt-19"; mk_progress 19 1 2 1.2000 "$WJD/wt-19"
# make issue-19 stale: backdate its status + progress mtimes well past the 600s window.
touch -d '2020-01-01' "$WJD/issue-19.status" "$WJD/wt-19/docs/stories/ralph-sprint-progress-19.md" 2>/dev/null \
  || touch -t 202001010000 "$WJD/issue-19.status" "$WJD/wt-19/docs/stories/ralph-sprint-progress-19.md"

watch_out="$(bash "$WATCH" --jobs-dir "$WJD" ls 2>&1)"
# One row per job (6 jobs) + header.
row_count="$(grep -c '^#' <<< "$watch_out")"
if [[ "$row_count" -eq 6 ]]; then
  pass "watch ls: one row per job (6 rows)"
else
  fail "watch ls row count wrong: $row_count"; sed 's/^/      /' <<< "$watch_out"
fi

# Correct glyphs per state (⏳ queued, 🔨 running-fresh, ✅ done, 🅿 parked, ❌ failed, ‼ stale).
check_glyph() { # $1=issue $2=glyph $3=label
  local line; line="$(grep "^#$1 " <<< "$watch_out")"
  if grep -qF "$2" <<< "$line"; then pass "watch glyph: issue $1 → $2 ($3)"; else fail "watch glyph: issue $1 expected $2 ($3), got [$line]"; fi
}
check_glyph 12 '⏳' 'queued'
check_glyph 15 '🔨' 'running-fresh'
check_glyph 7  '✅' 'done'
check_glyph 9  '🅿' 'parked'
check_glyph 3  '❌' 'failed'
check_glyph 19 '‼' 'stale-running (AC 2 anomaly flag)'

# Story X/Y + cost parsed from the progress file.
line15="$(grep '^#15 ' <<< "$watch_out")"
if grep -q '2/3' <<< "$line15" && grep -q '0.4200' <<< "$line15"; then
  pass "watch data: issue 15 shows story 2/3 and cost \$0.4200 from its progress file"
else
  fail "watch data wrong for 15: [$line15]"
fi

# watch --once renders the same table (single frame, used by non-interactive callers).
once_out="$(bash "$WATCH" --jobs-dir "$WJD" watch --once 2>&1)"
if [[ "$(grep -c '^#' <<< "$once_out")" -eq 6 ]]; then
  pass "watch --once: single-frame render matches ls (6 rows)"
else
  fail "watch --once wrong row count: $(grep -c '^#' <<< "$once_out")"
fi

# Brake CLI writes/removes the control files (the ONLY writes the watch performs).
CJD="$TMP/ctl-jobs"; mkdir -p "$CJD"
bash "$WATCH" --jobs-dir "$CJD" pause 12 > /dev/null 2>&1
paused_ok=$([[ "$(cat "$CJD/issue-12.control" 2>/dev/null)" == "pause" ]] && echo 1 || echo 0)
bash "$WATCH" --jobs-dir "$CJD" abort 12 > /dev/null 2>&1
abort_ok=$([[ "$(cat "$CJD/issue-12.control" 2>/dev/null)" == "abort" ]] && echo 1 || echo 0)
bash "$WATCH" --jobs-dir "$CJD" resume 12 > /dev/null 2>&1
resume_ok=$([[ ! -f "$CJD/issue-12.control" ]] && echo 1 || echo 0)
if [[ "$paused_ok" -eq 1 && "$abort_ok" -eq 1 && "$resume_ok" -eq 1 ]]; then
  pass "watch brake CLI: pause/abort write the control file, resume removes it"
else
  fail "watch brake CLI broke: pause=$paused_ok abort=$abort_ok resume=$resume_ok"
fi

echo "──────────────────────────────────────────────────────────────"
printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
