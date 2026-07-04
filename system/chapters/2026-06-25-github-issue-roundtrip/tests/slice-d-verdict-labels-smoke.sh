#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Offline smoke — Slice d of issue #1 "The Round Trip": verdict-gated issue labels.
#
# Subject under test: ensure_ralph_labels() and set_issue_label() in
# scripts/ralph-loop.sh — the helpers that project the loop's build state onto the
# issue as a single `ralph:` status label, driven off the same first-line
# REVIEW_PASSED/REVIEW_FAILED contract that is_review_passed() reads (ADR-001 I1/I2/I3).
#
# Agent-runnable, deterministic, NO network. The label helpers are extracted from
# their fenced block (together with the RALPH WRITE GUARDS block they call into for
# gh_label_op, and the real is_review_passed() so the verdict→label mapping is the
# loop's own, not a copy) and sourced into a subshell with log_* shimmed and `gh`
# replaced by an offline, STATEFUL stub (two newline files standing in for the issue's
# labels and the repo's label set). main() is never run; the real repo/GitHub are never
# touched.
#
# Proves:
#   1. The fenced block defines ensure_ralph_labels + set_issue_label (+ RALPH_STATUS_LABELS).
#   2. ensure_ralph_labels --write on: creates ONLY the missing ralph: labels; a re-run
#      on a fully-labelled repo writes nothing (no-churn).
#   3. --write OFF: a dry no-op — gh is never invoked, a "[dry] gh issue edit …" line is
#      logged, the issue's labels are unchanged.
#   4. Verdict drives the label (loop's own is_review_passed): a REVIEW_FAILED review
#      file → set_issue_label ralph:needs-fix; REVIEW_PASSED → ralph:in-review. Each is a
#      SINGLE `gh issue edit` adding NEW and removing the other ralph status label.
#   5. all stories green → ralph:done in one edit (removes the prior ralph status label).
#   6. Idempotent no-churn: re-setting the already-sole label issues ZERO label writes.
#   7. Single-status-label invariant: after every transition exactly ONE of the four
#      ralph: labels is present.
#   8. Namespace isolation: a pre-existing human label is never removed by a transition.
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

# set_issue_label/ensure_ralph_labels call gh_label_op (the slice-1 guarded helper),
# so both fenced blocks are sourced — exactly as the loop has them. is_review_passed()
# is extracted by name (it has no sentinels) so the verdict→label mapping under test is
# the loop's real contract, not a re-implementation.
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
extract_is_review_passed() {
  awk '
    /^is_review_passed\(\) \{/ { f = 1 }
    f                          { print }
    f && /^\}/                 { f = 0 }
  ' "$LOOP"
}

# ── Offline, STATEFUL `gh` stub. State lives in two newline files:
#   $GH_ISSUE_LABELS — the labels currently on the issue (one per line)
#   $GH_REPO_LABELS  — the labels that exist in the repo (one per line)
# Only WRITES (`issue edit`, `label create`) are recorded to $GH_WRITE_LOG so the test
# can count transitions; READs (`issue view`, `label list`, `repo view`) just return
# state. No network is ever touched.
GH_BIN="$(mktemp -d)"
cat > "$GH_BIN/gh" <<'STUB'
#!/usr/bin/env bash
sub="${1:-}"; op="${2:-}"
case "$sub" in
  repo)  # gh repo view --json nameWithOwner -q .nameWithOwner
    printf '%s\n' "${GH_SLUG:-seevali/ralph-loop-demo}"; exit 0 ;;
  issue)
    case "$op" in
      view)  # gh issue view N --repo slug --json labels -q '.labels[].name'
        grep -vE '^$' "$GH_ISSUE_LABELS" 2>/dev/null || true; exit 0 ;;
      edit)  # gh issue edit N --repo slug --add-label X [--remove-label Y ...]
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
    esac ;;
  label)
    case "$op" in
      list)  # gh label list --repo slug --limit N --json name -q '.[].name'
        grep -vE '^$' "$GH_REPO_LABELS" 2>/dev/null || true; exit 0 ;;
      create)  # gh label create X --repo slug --description ...
        printf '%s\n' "$*" >> "$GH_WRITE_LOG"
        name="${3:-}"
        grep -qxF "$name" "$GH_REPO_LABELS" 2>/dev/null || printf '%s\n' "$name" >> "$GH_REPO_LABELS"
        exit 0 ;;
    esac ;;
esac
printf 'UNHANDLED gh %s\n' "$*" >> "$GH_WRITE_LOG"
exit 0
STUB
chmod +x "$GH_BIN/gh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT" "$GH_BIN"' EXIT

# Run a label helper against a temp REPO_ROOT with the gh stub on PATH and log_*
# shimmed to stdout (so [dry]/transition lines are observable). The verdict→label
# mapping uses the loop's REAL is_review_passed() (extracted above), exactly as main().
run_label() { # env: GITHUB_WRITE, ISSUE_NUMBER, REPO_SLUG, REPO, GH_* state; args: a function call
  (
    set +e
    PATH="$GH_BIN:$PATH"
    REPO_ROOT="${REPO:-$TMPROOT}"
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
    source <(extract_is_review_passed)
    # The loop's own verdict→label mapping (mirrors main()'s is_review_passed branches).
    label_from_verdict() { # $1 review-file
      if is_review_passed "$1"; then printf 'ralph:in-review'; else printf 'ralph:needs-fix'; fi
    }
    "$@"
  )
}

# Helpers callable inside run_label's subshell via "$@".
do_set()        { set_issue_label "$1"; }
do_ensure()     { ensure_ralph_labels; }
do_verdict()    { set_issue_label "$(label_from_verdict "$1")"; }  # $1 review-file

fresh_issue()  { : > "$GH_ISSUE_LABELS"; }                 # no labels on the issue
fresh_repo()   { : > "$GH_REPO_LABELS"; }                  # no labels in the repo
seed_issue()   { printf '%s\n' "$@" > "$GH_ISSUE_LABELS"; }
seed_repo()    { printf '%s\n' "$@" > "$GH_REPO_LABELS"; }
issue_labels() { grep -vE '^$' "$GH_ISSUE_LABELS" 2>/dev/null || true; }
edit_count()   { grep -c '^issue edit ' "$GH_WRITE_LOG" 2>/dev/null || true; }
create_count() { grep -c '^label create ' "$GH_WRITE_LOG" 2>/dev/null || true; }
# Count how many of the four ralph status labels are currently on the issue.
ralph_status_count() {
  local n=0 l
  for l in ralph:building ralph:needs-fix ralph:in-review ralph:done; do
    grep -qxF "$l" "$GH_ISSUE_LABELS" 2>/dev/null && n=$((n + 1))
  done
  printf '%s' "$n"
}

export GH_ISSUE_LABELS="$TMPROOT/issue-labels.txt"
export GH_REPO_LABELS="$TMPROOT/repo-labels.txt"
export GH_WRITE_LOG="$TMPROOT/gh-writes.log"
reset_log() { : > "$GH_WRITE_LOG"; }

echo "── Slice d verdict-labels smoke ──────────────────────────────"

# ── 0. Sanity: the fenced block defines the helpers + the label vocabulary ──
# The status namespace GREW from four to SEVEN with issue #2 (Triage / Idea 4) — the
# three stage labels (ralph:ready / ralph:needs-triage / ralph:blocked) share this same
# single-label array so the "exactly ONE ralph: label" invariant holds globally.
il_src="$(extract_issue_label)"
if grep -q 'set_issue_label()' <<< "$il_src" \
   && grep -q 'ensure_ralph_labels()' <<< "$il_src" \
   && grep -q 'RALPH_STATUS_LABELS=(ralph:building ralph:needs-fix ralph:in-review ralph:done ralph:ready ralph:needs-triage ralph:blocked)' <<< "$il_src"; then
  pass "fenced block defines ensure_ralph_labels + set_issue_label + the seven ralph: status labels"
else
  fail "fenced RALPH ISSUE LABEL block not found or missing a helper / the label vocabulary"
fi

# ── 1. ensure_ralph_labels (--write on): create only missing labels, no-churn re-run ──
# The array grew to SEVEN with issue #2 (four build + three stage labels), so a fresh
# repo now takes seven creates — the assertion tracks the grown contract, not a weakened one.
fresh_repo; reset_log
GITHUB_WRITE=1 REPO_SLUG="seevali/ralph-loop-demo" run_label do_ensure >/dev/null
created="$(create_count)"
have_all=true
for l in ralph:building ralph:needs-fix ralph:in-review ralph:done ralph:ready ralph:needs-triage ralph:blocked; do
  grep -qxF "$l" "$GH_REPO_LABELS" || have_all=false
done
if [[ "$created" -eq 7 ]] && $have_all; then
  pass "ensure_ralph_labels (--write on): created the 7 missing ralph: labels"
else
  fail "ensure create wrong: creates=$created have_all=$have_all"
fi
reset_log
GITHUB_WRITE=1 REPO_SLUG="seevali/ralph-loop-demo" run_label do_ensure >/dev/null
if [[ "$(create_count)" -eq 0 ]]; then
  pass "ensure_ralph_labels re-run on a fully-labelled repo: ZERO creates (no-churn)"
else
  fail "ensure not idempotent: re-run created $(create_count) labels"
fi

# ── 2. --write OFF: dry no-op — gh never called, [dry] line logged, labels untouched ──
fresh_issue; reset_log
off_out="$(GITHUB_WRITE=0 ISSUE_NUMBER=7 REPO_SLUG="seevali/ralph-loop-demo" run_label do_set "ralph:building")"
if [[ ! -s "$GH_WRITE_LOG" && -z "$(issue_labels)" ]] \
   && grep -q '\[dry\] gh issue edit 7 --add-label ralph:building' <<< "$off_out"; then
  pass "--write off: no transition (gh never called), '[dry] gh issue edit …' logged, labels unchanged"
else
  fail "--write off leaked: writes=$(wc -l < "$GH_WRITE_LOG") labels='$(issue_labels)'"
  sed 's/^/      /' <<< "$off_out"
fi

# ── 3. Build start (--write on): ralph:building added in a single edit (no removes) ──
fresh_issue; reset_log
GITHUB_WRITE=1 ISSUE_NUMBER=7 REPO_SLUG="seevali/ralph-loop-demo" run_label do_set "ralph:building" >/dev/null
if [[ "$(edit_count)" -eq 1 && "$(issue_labels)" == "ralph:building" && "$(ralph_status_count)" -eq 1 ]] \
   && grep -q '^issue edit 7 --repo seevali/ralph-loop-demo --add-label ralph:building$' "$GH_WRITE_LOG"; then
  pass "build start: single 'gh issue edit --add-label ralph:building' (no --remove-label), sole status label"
else
  fail "build-start transition wrong: edits=$(edit_count) labels='$(issue_labels)'"
  sed 's/^/      /' "$GH_WRITE_LOG"
fi

# ── 4. Verdict REVIEW_FAILED → ralph:needs-fix (single edit add NEW + remove building) ──
reset_log
rf="$TMPROOT/r-fail.md"; printf 'REVIEW_FAILED\nfix the thing\n' > "$rf"
GITHUB_WRITE=1 ISSUE_NUMBER=7 REPO_SLUG="seevali/ralph-loop-demo" run_label do_verdict "$rf" >/dev/null
if [[ "$(edit_count)" -eq 1 && "$(issue_labels)" == "ralph:needs-fix" && "$(ralph_status_count)" -eq 1 ]] \
   && grep -q '^issue edit 7 --repo seevali/ralph-loop-demo --add-label ralph:needs-fix --remove-label ralph:building$' "$GH_WRITE_LOG"; then
  pass "REVIEW_FAILED → ralph:needs-fix: single edit add needs-fix + remove building, sole status label"
else
  fail "needs-fix transition wrong: edits=$(edit_count) labels='$(issue_labels)'"
  sed 's/^/      /' "$GH_WRITE_LOG"
fi

# ── 5. Verdict REVIEW_PASSED → ralph:in-review (single edit add NEW + remove needs-fix) ──
reset_log
rp="$TMPROOT/r-pass.md"; printf 'REVIEW_PASSED\n' > "$rp"
GITHUB_WRITE=1 ISSUE_NUMBER=7 REPO_SLUG="seevali/ralph-loop-demo" run_label do_verdict "$rp" >/dev/null
if [[ "$(edit_count)" -eq 1 && "$(issue_labels)" == "ralph:in-review" && "$(ralph_status_count)" -eq 1 ]] \
   && grep -q '^issue edit 7 --repo seevali/ralph-loop-demo --add-label ralph:in-review --remove-label ralph:needs-fix$' "$GH_WRITE_LOG"; then
  pass "REVIEW_PASSED → ralph:in-review: single edit add in-review + remove needs-fix, sole status label"
else
  fail "in-review transition wrong: edits=$(edit_count) labels='$(issue_labels)'"
  sed 's/^/      /' "$GH_WRITE_LOG"
fi

# ── 6. Idempotent no-churn: re-setting the already-sole label issues ZERO writes ──
reset_log
idem_out="$(GITHUB_WRITE=1 ISSUE_NUMBER=7 REPO_SLUG="seevali/ralph-loop-demo" run_label do_set "ralph:in-review")"
if [[ "$(edit_count)" -eq 0 && "$(issue_labels)" == "ralph:in-review" ]] \
   && grep -q 'already ralph:in-review — no transition (idempotent)' <<< "$idem_out"; then
  pass "re-set already-sole ralph:in-review: ZERO label writes (converged, no churn)"
else
  fail "no-churn broke: edits=$(edit_count) labels='$(issue_labels)'"
  sed 's/^/      /' <<< "$idem_out"
fi

# ── 7. all-green → ralph:done in one edit (removes the prior status label) ──
reset_log
GITHUB_WRITE=1 ISSUE_NUMBER=7 REPO_SLUG="seevali/ralph-loop-demo" run_label do_set "ralph:done" >/dev/null
if [[ "$(edit_count)" -eq 1 && "$(issue_labels)" == "ralph:done" && "$(ralph_status_count)" -eq 1 ]] \
   && grep -q '^issue edit 7 --repo seevali/ralph-loop-demo --add-label ralph:done --remove-label ralph:in-review$' "$GH_WRITE_LOG"; then
  pass "all-green → ralph:done: single edit add done + remove in-review, sole status label"
else
  fail "done transition wrong: edits=$(edit_count) labels='$(issue_labels)'"
  sed 's/^/      /' "$GH_WRITE_LOG"
fi
# … and re-running on the finished issue is a no-op.
reset_log
GITHUB_WRITE=1 ISSUE_NUMBER=7 REPO_SLUG="seevali/ralph-loop-demo" run_label do_set "ralph:done" >/dev/null
if [[ "$(edit_count)" -eq 0 && "$(issue_labels)" == "ralph:done" ]]; then
  pass "re-run on a finished issue (ralph:done already set): ZERO label writes"
else
  fail "terminal idempotency broke: edits=$(edit_count) labels='$(issue_labels)'"
fi

# ── 8. Namespace isolation: a pre-existing human label survives every transition ──
seed_issue "bug" "ralph:needs-fix"; reset_log
GITHUB_WRITE=1 ISSUE_NUMBER=7 REPO_SLUG="seevali/ralph-loop-demo" run_label do_set "ralph:in-review" >/dev/null
if grep -qxF "bug" "$GH_ISSUE_LABELS" \
   && [[ "$(ralph_status_count)" -eq 1 ]] && grep -qxF "ralph:in-review" "$GH_ISSUE_LABELS" \
   && ! grep -q 'remove-label bug' "$GH_WRITE_LOG"; then
  pass "namespace isolation: human label 'bug' preserved; only the ralph: label transitioned"
else
  fail "namespace isolation broke: labels='$(issue_labels)'"
  sed 's/^/      /' "$GH_WRITE_LOG"
fi

echo "──────────────────────────────────────────────────────────────"
printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
