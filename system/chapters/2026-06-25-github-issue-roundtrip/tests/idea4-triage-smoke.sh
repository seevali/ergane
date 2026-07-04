#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Offline smoke — Idea 4 "Triage Before Toil" (GitHub issue #2): the readiness
# pre-phase that runs BEFORE Phase 0 in Path A.
#
# Subject under test: triage_classify(), splice_triage_block(), upsert_triage_comment(),
# triage_ledger_append(), triage_park(), and run_triage_phase() in scripts/ralph-loop.sh —
# the deterministic classifier + the orchestrator that labels the issue's stage, posts
# clarifying questions when underspecified, and promotes ONLY `ready` issues into Phase 0
# (ADR-001 invariants I1/I2/I3; prd.md §3 Idea 4, §5, §6).
#
# Agent-runnable, deterministic, NO network. The triage functions are extracted from
# their fenced block (together with the RALPH WRITE GUARDS block they call into for
# gh_comment_op/gh_label_op, and the RALPH ISSUE LABEL block for set_issue_label /
# ensure_ralph_labels / _resolve_repo_slug) and sourced into a subshell with log_*
# shimmed and `gh` replaced by an offline, STATEFUL stub. main() is never run; the real
# repo/GitHub are never touched.
#
# Proves:
#   1. Sentinels extract; all six triage functions are defined.
#   2. DETERMINISM: a ≥6-issue fixture table classifies byte-identically across two
#      invocations, each matching its expected classification (incl. the repro question
#      for a bug issue with no reproduction steps).
#   3. --write OFF, needs-info: run_triage_phase exits 2, no WRITE hits gh, "[dry] gh …"
#      lines are logged for the comment + labels, and a ledger row is appended.
#   4. --write OFF, ready: returns 0 (would proceed into Phase 0), only dry label writes.
#   5. --write ON, needs-info: exactly ONE triage comment created; a re-run edits it in
#      place (no 2nd create, I2); the label transition is a single `gh issue edit`; exit 2.
#   6. --write ON, ready fast-path: an issue already labelled ralph:ready (mode auto) →
#      ZERO gh writes, returns 0.
#   7. --triage never → returns 0, ZERO gh invocations of any kind.
#   8. Roadmap exclusion → exit 2 and ZERO gh writes (no comment, no label).
#   9. I3: `gh issue close` / `gh pr merge` / `gh pr close` NEVER appear across all cases.
#  10. Resume: a pre-existing EPIC_FILE → returns 0, ZERO gh calls.
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

# run_triage_phase leans on gh_comment_op/gh_label_op (write guards) and on
# set_issue_label/ensure_ralph_labels/_resolve_repo_slug (the label block), so all three
# fenced blocks are sourced — exactly as the loop has them side by side.
extract_write_guards() {
  awk '
    /# >>> RALPH WRITE GUARDS/ { f = 1 }
    f                          { print }
    /# <<< RALPH WRITE GUARDS/ { f = 0 }
  ' "$LOOP"
}
extract_issue_label() {
  awk '
    /# >>> RALPH ISSUE LABEL/ { f = 1 }
    f                         { print }
    /# <<< RALPH ISSUE LABEL/ { f = 0 }
  ' "$LOOP"
}
extract_triage() {
  awk '
    /# >>> RALPH TRIAGE/ { f = 1 }
    f                    { print }
    /# <<< RALPH TRIAGE/ { f = 0 }
  ' "$LOOP"
}

# ── Offline, STATEFUL `gh` stub. State lives in:
#   $GH_ISSUE_LABELS — the labels currently on the issue (one per line)
#   $GH_REPO_LABELS  — the labels that exist in the repo (one per line)
#   $GH_COMMENTS     — a JSON {"comments":[…]} standing in for the issue's comment list
#   $GH_TITLE/$GH_BODY — the issue's title/body (env), reflected into the fetch JSON
# WRITES (`issue edit`, `issue comment`, `label create`, `api PATCH`) are recorded to
# $GH_WRITE_LOG so writes can be counted; every call is recorded to $GH_CALL_LOG so
# "zero gh invocations" is checkable; a forbidden verb (I3) lands in $GH_FORBIDDEN. READs
# (`issue view`, `label list`, `repo view`, `auth`) just return state. No network.
GH_BIN="$(mktemp -d)"
cat > "$GH_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALL_LOG:-/dev/null}"
sub="${1:-}"; op="${2:-}"
case "$sub $op" in
  "issue close"|"pr merge"|"pr close") printf '%s\n' "$*" >> "${GH_FORBIDDEN:-/dev/null}" ;;
esac
case "$sub" in
  auth) exit 0 ;;
  repo) printf '%s\n' "${GH_SLUG:-seevali/ralph-loop-demo}"; exit 0 ;;
  issue)
    case "$op" in
      view)
        jsonflds=""
        shift 2
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --json)  jsonflds="$2"; shift 2 ;;
            -q|--jq) shift 2 ;;
            --repo)  shift 2 ;;
            *)       shift ;;
          esac
        done
        if [[ "$jsonflds" == *comments* ]]; then
          cat "${GH_COMMENTS:-/dev/null}" 2>/dev/null || printf '{"comments":[]}\n'
        elif [[ "$jsonflds" == *title* ]]; then
          labels_json="$(grep -vE '^$' "$GH_ISSUE_LABELS" 2>/dev/null | jq -R . | jq -s 'map({name:.})')"
          [[ -z "$labels_json" ]] && labels_json='[]'
          jq -n --arg t "${GH_TITLE:-}" --arg b "${GH_BODY:-}" --argjson l "$labels_json" '{title:$t,body:$b,labels:$l}'
        elif [[ "$jsonflds" == *labels* ]]; then
          grep -vE '^$' "$GH_ISSUE_LABELS" 2>/dev/null || true
        fi
        exit 0 ;;
      edit)
        printf '%s\n' "$*" >> "$GH_WRITE_LOG"
        shift 2
        addv=(); remv=()
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --add-label)    addv+=("$2"); shift 2 ;;
            --remove-label) remv+=("$2"); shift 2 ;;
            *) shift ;;
          esac
        done
        tmp="$(mktemp)"
        { grep -vE '^$' "$GH_ISSUE_LABELS" 2>/dev/null || true
          for x in "${addv[@]}"; do printf '%s\n' "$x"; done
        } | sort -u > "$tmp"
        for x in "${remv[@]}"; do grep -vxF "$x" "$tmp" > "$tmp.2" || true; mv "$tmp.2" "$tmp"; done
        mv "$tmp" "$GH_ISSUE_LABELS"
        exit 0 ;;
      comment)
        printf '%s\n' "$*" >> "$GH_WRITE_LOG"
        bf=""
        while [[ $# -gt 0 ]]; do
          [[ "$1" == "--body-file" ]] && bf="${2:-}"
          shift
        done
        body="$(cat "$bf")"
        n="$(jq '.comments | length' "$GH_COMMENTS")"
        cid=$((2000 + n + 1))
        url="https://github.com/${GH_SLUG:-o/r}/issues/${GH_ISSUE:-2}#issuecomment-${cid}"
        tmp="$(mktemp)"
        jq --arg b "$body" --arg u "$url" '.comments += [{"body":$b,"url":$u}]' "$GH_COMMENTS" > "$tmp" && mv "$tmp" "$GH_COMMENTS"
        printf '%s\n' "$url"; exit 0 ;;
    esac ;;
  label)
    case "$op" in
      list) grep -vE '^$' "$GH_REPO_LABELS" 2>/dev/null || true; exit 0 ;;
      create)
        printf '%s\n' "$*" >> "$GH_WRITE_LOG"
        name="${3:-}"
        grep -qxF "$name" "$GH_REPO_LABELS" 2>/dev/null || printf '%s\n' "$name" >> "$GH_REPO_LABELS"
        exit 0 ;;
    esac ;;
  api)
    printf '%s\n' "$*" >> "$GH_WRITE_LOG"
    path=""; bf=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        */issues/comments/*) path="$1" ;;
        -F|--field) [[ "${2:-}" == body=@* ]] && bf="${2#body=@}" ;;
      esac
      shift
    done
    cid="${path##*/}"
    body="$(cat "$bf")"
    tmp="$(mktemp)"
    jq --arg c "$cid" --arg b "$body" '(.comments[] | select(.url | test("issuecomment-" + $c + "$")) | .body) |= $b' "$GH_COMMENTS" > "$tmp" && mv "$tmp" "$GH_COMMENTS"
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$GH_BIN/gh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT" "$GH_BIN"' EXIT

# Classify in a subshell with only the triage block sourced (pure — no gh needed).
classify_once() { # $1 title  $2 body  $3 labels(newline-sep)
  (
    # Run under the SAME shell mode the real loop uses (set -euo pipefail), NOT set +e —
    # so a future edit that turns a bare grep/`[[ ]]` signal line into a standalone,
    # errexit-exposed command (which the live loop would die on mid-classification) fails
    # this smoke instead of printing a false green.
    set -euo pipefail
    log_dim() { :; }; log_info() { :; }; log_warn() { :; }
    log_success() { :; }; log_error() { :; }
    # shellcheck disable=SC1090
    source <(extract_triage)
    triage_classify "$1" "$2" "$3"
  )
}

# Run run_triage_phase against a temp REPO_ROOT with the gh stub on PATH and log_*
# shimmed to stdout (so [dry]/status lines are observable). Returns the subshell rc
# (triage_park exits 2). Env in: GITHUB_WRITE, ISSUE_NUMBER, REPO_SLUG, TRIAGE_MODE,
# EPIC_FILE, REPO, GH_* state.
run_triage() {
  (
    # Same rationale as classify_once: exercise run_triage_phase under the loop's real
    # errexit mode so an errexit regression in the triage path fails here, not in prod.
    set -euo pipefail
    PATH="$GH_BIN:$PATH"
    REPO_ROOT="$REPO"
    log_dim()     { printf '%s\n' "$1"; }
    log_info()    { printf '%s\n' "$1"; }
    log_warn()    { printf '%s\n' "$1"; }
    log_success() { printf '%s\n' "$1"; }
    log_error()   { printf 'ERR %s\n' "$1" >&2; }
    # shellcheck disable=SC1090
    source <(extract_write_guards)
    # shellcheck disable=SC1090
    source <(extract_issue_label)
    # shellcheck disable=SC1090
    source <(extract_triage)
    run_triage_phase
  )
}

new_repo()     { mktemp -d -p "$TMPROOT"; }
fresh_state() {  # reset all gh state files for a case
  : > "$GH_ISSUE_LABELS"; : > "$GH_REPO_LABELS"; : > "$GH_WRITE_LOG"; : > "$GH_CALL_LOG"
  printf '{"comments":[]}\n' > "$GH_COMMENTS"
}
seed_issue()   { printf '%s\n' "$@" > "$GH_ISSUE_LABELS"; }
ledger_rows()  { grep -c . "$1/.ralph/triage-ledger.tsv" 2>/dev/null || true; }
w_create()     { grep -c '^issue comment ' "$GH_WRITE_LOG" 2>/dev/null || true; }
w_patch()      { grep -c '^api --method PATCH' "$GH_WRITE_LOG" 2>/dev/null || true; }
w_edit()       { grep -c '^issue edit ' "$GH_WRITE_LOG" 2>/dev/null || true; }

export GH_ISSUE_LABELS="$TMPROOT/issue-labels.txt"
export GH_REPO_LABELS="$TMPROOT/repo-labels.txt"
export GH_COMMENTS="$TMPROOT/comments.json"
export GH_WRITE_LOG="$TMPROOT/gh-writes.log"
export GH_CALL_LOG="$TMPROOT/gh-calls.log"
export GH_FORBIDDEN="$TMPROOT/gh-forbidden.log"
: > "$GH_FORBIDDEN"

echo "── Idea 4 triage smoke ───────────────────────────────────────"

# ── 0. Sanity: the fenced block defines all six triage functions ──
tr_src="$(extract_triage)"
missing=""
for fn in triage_classify splice_triage_block upsert_triage_comment triage_ledger_append triage_park run_triage_phase; do
  grep -q "${fn}()" <<< "$tr_src" || missing="$missing $fn"
done
if [[ -z "$missing" ]]; then
  pass "fenced block defines all six triage functions"
else
  fail "RALPH TRIAGE block missing function(s):$missing"
fi

# ── 1. Determinism: a 6-issue fixture table classifies byte-identically + as expected ──
RICH_BODY=$'## Goal\nAdd a user-configurable auto-refresh interval to the exchange rates dashboard.\n\n## Acceptance criteria\n- A settings control lets the user pick 15s / 30s / 60s.\n- The dashboard re-fetches rates at the chosen interval.\n- The choice persists across reloads via localStorage.'

det_ok=true
check_det() { # $1 name  $2 expected  $3 title  $4 body  $5 labels  [$6 must-contain]
  local name="$1" expect="$2" title="$3" body="$4" labels="$5" needle="${6:-}"
  local a b cls
  a="$(classify_once "$title" "$body" "$labels")"
  b="$(classify_once "$title" "$body" "$labels")"
  cls="${a%%$'\n'*}"
  if [[ "$a" != "$b" ]]; then
    det_ok=false; fail "determinism: '$name' not byte-identical across invocations"; return
  fi
  if [[ "$cls" != "$expect" ]]; then
    det_ok=false; fail "classify '$name': got '$cls', expected '$expect'"; sed 's/^/      /' <<< "$a"; return
  fi
  if [[ -n "$needle" ]] && ! grep -qF "$needle" <<< "$a"; then
    det_ok=false; fail "classify '$name': missing expected line '$needle'"; sed 's/^/      /' <<< "$a"; return
  fi
}

check_det "rich body"      ready              "Add a configurable auto-refresh interval to the rates dashboard" "$RICH_BODY" ""
check_det "empty body"     needs-info         "Fix it"                                                          ""           ""
check_det "question title" needs-info         "How do I change the refresh rate?"                               ""           ""
check_det "roadmap label"  excluded           "The Swarm + Mission Control"                                     "$RICH_BODY" "roadmap"
check_det "wontfix label"  wontfix-candidate  "Please add blockchain support"                                   ""           "wontfix"
check_det "bug w/o repro"  needs-info         "Chart flickers on load"                                          "The chart flickers when the page loads." "bug" "question: Can you add steps to reproduce?"

if $det_ok; then
  pass "determinism: all 6 fixtures byte-identical + classified as expected (incl. bug→repro question)"
fi

# ── 2. --write OFF, needs-info → exit 2, no WRITE hits gh, [dry] lines, ledger row ──
REPO="$(new_repo)"; fresh_state
export GH_TITLE="Fix it" GH_BODY=""
off_rc=0
off_out="$(GITHUB_WRITE=0 ISSUE_NUMBER=2 REPO_SLUG="seevali/ralph-loop-demo" TRIAGE_MODE=auto EPIC_FILE="$REPO/docs/epics/issue-2.md" REPO="$REPO" run_triage)" || off_rc=$?
if [[ "$off_rc" -eq 2 && ! -s "$GH_WRITE_LOG" ]] \
   && grep -q '\[dry\] gh issue comment 2 --body-file' <<< "$off_out" \
   && grep -q '\[dry\] gh issue edit 2 --add-label ralph:needs-triage' <<< "$off_out" \
   && [[ "$(ledger_rows "$REPO")" -ge 1 ]]; then
  pass "--write off needs-info: exit 2, no gh WRITE, [dry] comment+label logged, ledger row appended"
else
  fail "--write off needs-info leaked: rc=$off_rc writes=$(wc -l < "$GH_WRITE_LOG") ledger=$(ledger_rows "$REPO")"
  sed 's/^/      /' <<< "$off_out"
fi

# ── 3. --write OFF, ready → returns 0 (would proceed), only dry label writes ──
REPO="$(new_repo)"; fresh_state
export GH_TITLE="Add a configurable auto-refresh interval to the rates dashboard" GH_BODY="$RICH_BODY"
rdy_rc=0
rdy_out="$(GITHUB_WRITE=0 ISSUE_NUMBER=2 REPO_SLUG="seevali/ralph-loop-demo" TRIAGE_MODE=auto EPIC_FILE="$REPO/docs/epics/issue-2.md" REPO="$REPO" run_triage)" || rdy_rc=$?
if [[ "$rdy_rc" -eq 0 && ! -s "$GH_WRITE_LOG" ]] \
   && grep -q '\[dry\] gh issue edit 2 --add-label ralph:ready' <<< "$rdy_out"; then
  pass "--write off ready: returns 0 (proceeds), only a dry ralph:ready label write, no gh WRITE"
else
  fail "--write off ready wrong: rc=$rdy_rc writes=$(wc -l < "$GH_WRITE_LOG")"
  sed 's/^/      /' <<< "$rdy_out"
fi

# ── 4. --write ON, needs-info → one comment, re-run edits in place, single edit, exit 2 ──
REPO="$(new_repo)"; fresh_state
export GH_TITLE="Fix it" GH_BODY=""
on1_rc=0
on1_out="$(GITHUB_WRITE=1 ISSUE_NUMBER=2 REPO_SLUG="seevali/ralph-loop-demo" TRIAGE_MODE=auto EPIC_FILE="$REPO/docs/epics/issue-2.md" REPO="$REPO" run_triage)" || on1_rc=$?
on2_rc=0
on2_out="$(GITHUB_WRITE=1 ISSUE_NUMBER=2 REPO_SLUG="seevali/ralph-loop-demo" TRIAGE_MODE=auto EPIC_FILE="$REPO/docs/epics/issue-2.md" REPO="$REPO" run_triage)" || on2_rc=$?
comment_count="$(jq '.comments | length' "$GH_COMMENTS")"
if [[ "$on1_rc" -eq 2 && "$on2_rc" -eq 2 ]] \
   && [[ "$(w_create)" -eq 1 && "$(w_patch)" -ge 1 && "$comment_count" -eq 1 ]] \
   && [[ "$(w_edit)" -eq 1 ]] \
   && grep -q '^issue edit 2 --repo seevali/ralph-loop-demo --add-label ralph:needs-triage$' "$GH_WRITE_LOG"; then
  pass "--write on needs-info: 1 comment created + edited in place on re-run (I2), single label edit, exit 2 twice"
else
  fail "--write on needs-info broke: rc1=$on1_rc rc2=$on2_rc creates=$(w_create) patches=$(w_patch) edits=$(w_edit) comments=$comment_count"
  sed 's/^/      /' <<< "$on2_out"
fi

# ── 5. --write ON, ready fast-path → already ralph:ready (mode auto) → 0 writes, rc 0 ──
REPO="$(new_repo)"; fresh_state
seed_issue "ralph:ready"
export GH_TITLE="Fix it" GH_BODY=""
fp_rc=0
fp_out="$(GITHUB_WRITE=1 ISSUE_NUMBER=2 REPO_SLUG="seevali/ralph-loop-demo" TRIAGE_MODE=auto EPIC_FILE="$REPO/docs/epics/issue-2.md" REPO="$REPO" run_triage)" || fp_rc=$?
if [[ "$fp_rc" -eq 0 && ! -s "$GH_WRITE_LOG" ]] \
   && grep -q 'already promoted (ralph:ready)' <<< "$fp_out"; then
  pass "--write on ready fast-path: already ralph:ready (auto) → ZERO gh writes, returns 0"
else
  fail "ready fast-path broke: rc=$fp_rc writes=$(wc -l < "$GH_WRITE_LOG")"
  sed 's/^/      /' <<< "$fp_out"
fi

# ── 6. --triage never → returns 0, ZERO gh invocations of any kind ──
REPO="$(new_repo)"; fresh_state
export GH_TITLE="Fix it" GH_BODY=""
nv_rc=0
nv_out="$(GITHUB_WRITE=1 ISSUE_NUMBER=2 REPO_SLUG="seevali/ralph-loop-demo" TRIAGE_MODE=never EPIC_FILE="$REPO/docs/epics/issue-2.md" REPO="$REPO" run_triage)" || nv_rc=$?
if [[ "$nv_rc" -eq 0 && ! -s "$GH_CALL_LOG" ]] \
   && grep -q 'skipped (--triage never)' <<< "$nv_out"; then
  pass "--triage never: returns 0, ZERO gh invocations of any kind"
else
  fail "--triage never broke: rc=$nv_rc ghcalls=$(wc -l < "$GH_CALL_LOG")"
  sed 's/^/      /' <<< "$nv_out"
fi

# ── 7. Roadmap exclusion → exit 2, ZERO gh writes (no comment, no label) ──
REPO="$(new_repo)"; fresh_state
seed_issue "roadmap"
export GH_TITLE="The Swarm + Mission Control" GH_BODY="$RICH_BODY"
ex_rc=0
ex_out="$(GITHUB_WRITE=1 ISSUE_NUMBER=2 REPO_SLUG="seevali/ralph-loop-demo" TRIAGE_MODE=auto EPIC_FILE="$REPO/docs/epics/issue-2.md" REPO="$REPO" run_triage)" || ex_rc=$?
if [[ "$ex_rc" -eq 2 && ! -s "$GH_WRITE_LOG" ]] \
   && [[ "$(jq '.comments | length' "$GH_COMMENTS")" -eq 0 ]]; then
  pass "roadmap excluded: exit 2, ZERO gh writes (no comment, no label)"
else
  fail "roadmap exclusion broke: rc=$ex_rc writes=$(wc -l < "$GH_WRITE_LOG") comments=$(jq '.comments|length' "$GH_COMMENTS")"
  sed 's/^/      /' <<< "$ex_out"
fi

# ── 8. Resume: pre-existing EPIC_FILE → returns 0, ZERO gh calls ──
REPO="$(new_repo)"; fresh_state
mkdir -p "$REPO/docs/epics"; printf '## Epic 2: Resumed\n### Story 2.1: X\n' > "$REPO/docs/epics/issue-2.md"
export GH_TITLE="Fix it" GH_BODY=""
rs_rc=0
rs_out="$(GITHUB_WRITE=1 ISSUE_NUMBER=2 REPO_SLUG="seevali/ralph-loop-demo" TRIAGE_MODE=auto EPIC_FILE="$REPO/docs/epics/issue-2.md" REPO="$REPO" run_triage)" || rs_rc=$?
if [[ "$rs_rc" -eq 0 && ! -s "$GH_CALL_LOG" ]] \
   && grep -q 'epic already exists' <<< "$rs_out"; then
  pass "resume: pre-existing EPIC_FILE → returns 0, ZERO gh calls"
else
  fail "resume broke: rc=$rs_rc ghcalls=$(wc -l < "$GH_CALL_LOG")"
  sed 's/^/      /' <<< "$rs_out"
fi

# ── 9. I3: the loop NEVER closed / merged across every case above ──
if [[ ! -s "$GH_FORBIDDEN" ]]; then
  pass "I3: no 'gh issue close' / 'gh pr merge' / 'gh pr close' across all cases"
else
  fail "I3 violated — forbidden gh verb invoked:"
  sed 's/^/      /' "$GH_FORBIDDEN"
fi

echo "──────────────────────────────────────────────────────────────"
printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
