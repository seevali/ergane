#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Offline smoke — Idea 2 "The Confessing PR" (GitHub issue #3): synthesise the
# draft PR's BODY from the artifacts the loop already produces.
#
# Subject under test: render_pr_body() + update_issue_pr_body() (and their private
# _pr_* helpers) in scripts/ralph-loop.sh — the pure body builder and its gated
# writer. render_pr_body is a PURE function of on-disk artifacts + `git log`
# (ADR-001 I2/I3; AC 3/4); update_issue_pr_body funnels the ONE GitHub write through
# gh_pr_op (I1) and never merges/closes (I3).
#
# Agent-runnable, deterministic, NO network. The RALPH PR BODY block is extracted
# from its fence (together with the RALPH WRITE GUARDS block it calls into for
# gh_pr_op) and sourced into THROWAWAY git repos with a real LOCAL `git` and an
# offline `gh` stub. The orchestrator's main() is never run.
#
# Proves (spec §5):
#   1. Sentinels extract; render_pr_body + update_issue_pr_body defined.
#   2. Full fixture: guess section (both items + source attributions), AC bullets
#      per story, correct short commit hashes (read from the fixture git log),
#      narrative excerpts.
#   3. Determinism (AC 4): two renders are byte-identical.
#   4. Purity (AC 3): the gh stub records ZERO calls during render_pr_body.
#   5. No-assumptions fixture → the explicit "No assumptions…" line (AC 1).
#   6. Uncommitted story → _(not yet committed)_; missing done.md → _(no
#      implementation summary)_; missing ACs → the AC fallback line.
#   7. update_issue_pr_body --write OFF → [dry] gh pr edit … logged, stub untouched, rc 0.
#   8. --write ON with pr.txt (PR still a draft) → exactly ONE `pr edit` with --body-file
#      whose file equals render_pr_body byte-for-byte; rc 0; re-run converges (still one
#      call). Once the PR is ready-for-review (isDraft=false) → ZERO edits (human-edit safe).
#   9. --write ON without pr.txt → warn + rc 0, zero stub writes.
#  10. I3: no `pr merge` / `pr close` / `issue close` ever recorded.
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

extract_write_guards() {
  awk '
    /# >>> RALPH WRITE GUARDS/ { f = 1 }
    f                          { print }
    /# <<< RALPH WRITE GUARDS/ { f = 0 }
  ' "$LOOP"
}
extract_pr_body() {
  awk '
    /# >>> RALPH PR BODY/ { f = 1 }
    f                     { print }
    /# <<< RALPH PR BODY/ { f = 0 }
  ' "$LOOP"
}

# ── Offline `gh` stub: records every call; `pr edit` succeeds silently ──
GH_BIN="$(mktemp -d)"
cat > "$GH_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
exit 0
STUB
chmod +x "$GH_BIN/gh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT" "$GH_BIN"' EXIT

# ── Fixture builders ──────────────────────────────────────────────
# Each fixture is a real local git repo whose docs/{epics,prd,stories} mirror the
# artifacts a Path A run leaves on disk. Commits carry `feat(N.k):` subjects so the
# commit map can resolve real short hashes. Echoes the repo root.

new_repo() {
  local root; root="$(mktemp -d -p "$TMPROOT")"
  git -C "$root" init -q
  git -C "$root" symbolic-ref HEAD refs/heads/main
  git -C "$root" config user.email "smoke@example.com"
  git -C "$root" config user.name "Smoke Test"
  mkdir -p "$root/docs/epics" "$root/docs/prd" "$root/docs/stories"
  printf '%s\n' "$root"
}

# Full two-story fixture (issue 9). 9.1 records a guess in its spec (## Assumptions)
# AND another in its done.md (a standalone ASSUMPTION: line).
make_full_fixture() {
  local root; root="$(new_repo)"
  cat > "$root/docs/epics/issue-9.md" <<'EPIC'
## Epic 9: Confessing PR demo

### Story 9.1: App shell and watchlist

Some prose.

### Story 9.2: Persist the watchlist

More prose.
EPIC
  printf '# PRD issue 9\n\nNo recorded assumptions here.\n' > "$root/docs/prd/issue-9.md"

  cat > "$root/docs/stories/9.1.md" <<'S91'
# Story 9.1

## Acceptance Criteria

- Renders the pair picker
- Responds to an add click

## Assumptions

- The Frankfurter API is keyless
S91
  cat > "$root/docs/stories/9.1-done.md" <<'D91'
# Story 9.1 — done

## Summary

Implemented the app shell and watchlist selection with an in-memory list.

ASSUMPTION: localStorage is available in the target browsers.
D91
  cat > "$root/docs/stories/9.2.md" <<'S92'
# Story 9.2

## Acceptance Criteria

- Persists the watchlist to localStorage
S92
  cat > "$root/docs/stories/9.2-done.md" <<'D92'
# Story 9.2 — done

Persisted the watchlist and rehydrated it on load, tolerating malformed JSON.
D92

  git -C "$root" add -A
  git -C "$root" commit -q -m "docs(issue-9): intake plan"
  # One feat() commit per story (the loop's real story-commit subject format).
  printf 'a\n' > "$root/docs/stories/9.1-mark.txt"
  git -C "$root" add -A && git -C "$root" commit -q -m "feat(9.1): App shell and watchlist"
  printf 'b\n' > "$root/docs/stories/9.2-mark.txt"
  git -C "$root" add -A && git -C "$root" commit -q -m "feat(9.2): Persist the watchlist"
  printf '%s\n' "$root"
}

# No-assumptions fixture (issue 5): one story, zero recorded guesses anywhere.
make_clean_fixture() {
  local root; root="$(new_repo)"
  cat > "$root/docs/epics/issue-5.md" <<'EPIC'
## Epic 5: Clean

### Story 5.1: Only story
EPIC
  cat > "$root/docs/stories/5.1.md" <<'S51'
# Story 5.1

## Acceptance Criteria

- Renders something
S51
  printf '# Story 5.1 — done\n\nBuilt it cleanly.\n' > "$root/docs/stories/5.1-done.md"
  git -C "$root" add -A && git -C "$root" commit -q -m "feat(5.1): Only story"
  printf '%s\n' "$root"
}

# Fallbacks fixture (issue 3): one story with NO commit, NO done.md, and a spec
# WITHOUT any acceptance-criteria heading (epic section also has no AC bullets).
make_fallback_fixture() {
  local root; root="$(new_repo)"
  cat > "$root/docs/epics/issue-3.md" <<'EPIC'
## Epic 3: Fallbacks

### Story 3.1: Uncommitted, undocumented

Just a description, no acceptance criteria list here either.
EPIC
  cat > "$root/docs/stories/3.1.md" <<'S31'
# Story 3.1

A spec that forgot to record acceptance criteria.
S31
  # a seed commit so `git log` works, but NO feat(3.1): commit and NO 3.1-done.md
  printf 'seed\n' > "$root/seed.txt"
  git -C "$root" add -A && git -C "$root" commit -q -m "seed"
  printf '%s\n' "$root"
}

# Source the PR BODY block (+ write guards, for gh_pr_op) with log_* shimmed to
# stdout, then run the given function. Runs in a subshell so globals never leak.
render_in() { # $1 repo  $2 issue ; echoes rendered body
  (
    set -euo pipefail
    log_dim() { :; }; log_info() { :; }; log_warn() { :; }
    log_success() { :; }; log_error() { :; }
    # shellcheck disable=SC1090
    source <(extract_write_guards)
    # shellcheck disable=SC1090
    source <(extract_pr_body)
    render_pr_body "$2" "$1/docs/epics/issue-$2.md" "$1/docs/stories" "$1"
  )
}

run_update() { # env: GITHUB_WRITE, REPO, ISSUE_NUMBER, GH_CALL_LOG ; echoes logs
  (
    set +e
    PATH="$GH_BIN:$PATH"
    REPO_ROOT="$REPO"
    ISSUE_NUMBER="$ISSUE"
    EPIC_FILE="$REPO/docs/epics/issue-${ISSUE}.md"
    STORIES_DIR="$REPO/docs/stories"
    log_dim()     { printf '%s\n' "$1"; }
    log_info()    { printf '%s\n' "$1"; }
    log_warn()    { printf '%s\n' "$1"; }
    log_success() { printf '%s\n' "$1"; }
    log_error()   { printf 'ERR %s\n' "$1" >&2; }
    # shellcheck disable=SC1090
    source <(extract_write_guards)
    # shellcheck disable=SC1090
    source <(extract_pr_body)
    update_issue_pr_body
  )
}

echo "── Idea 2 confessing-PR smoke ────────────────────────────────"

# ── 1. Sanity: the fenced block defines both public functions ──
pr_src="$(extract_pr_body)"
if grep -q 'render_pr_body()' <<<"$pr_src" && grep -q 'update_issue_pr_body()' <<<"$pr_src"; then
  pass "fenced block defines render_pr_body + update_issue_pr_body"
else
  fail "fenced RALPH PR BODY block missing a function"
fi

# ── 2. Full fixture: guesses, ACs, commit hashes, narratives ──
FULL="$(make_full_fixture)"
h91="$(git -C "$FULL" log --all --pretty='%h %s' | awk '$0 ~ /feat\(9\.1\):/ {print $1}')"
h92="$(git -C "$FULL" log --all --pretty='%h %s' | awk '$0 ~ /feat\(9\.2\):/ {print $1}')"
body="$(render_in "$FULL" 9)"

ok=1
grep -qF '## ⚠️ I had to guess' <<<"$body" || { ok=0; }
grep -qF -- '- The Frankfurter API is keyless — _docs/stories/9.1.md_' <<<"$body" || ok=0
grep -qF -- '- ASSUMPTION: localStorage is available in the target browsers. — _docs/stories/9.1-done.md_' <<<"$body" || ok=0
if [[ "$ok" -eq 1 ]]; then
  pass "guess section lists both recorded items with source attributions"
else
  fail "guess section missing an item"; sed 's/^/      /' <<<"$body"
fi

if grep -qF -- '- Renders the pair picker' <<<"$body" \
   && grep -qF -- '- Responds to an add click' <<<"$body" \
   && grep -qF -- '- Persists the watchlist to localStorage' <<<"$body"; then
  pass "acceptance-criteria bullets appear under their stories"
else
  fail "an AC bullet is missing"; sed 's/^/      /' <<<"$body"
fi

if grep -qF "Commit: \`$h91\`" <<<"$body" && grep -qF "Commit: \`$h92\`" <<<"$body"; then
  pass "commit map resolves the correct short hashes ($h91, $h92)"
else
  fail "commit hash map wrong (want $h91 / $h92)"; sed 's/^/      /' <<<"$body"
fi

if grep -qF 'Implemented the app shell and watchlist selection with an in-memory list.' <<<"$body" \
   && grep -qF 'Persisted the watchlist and rehydrated it on load' <<<"$body"; then
  pass "story narratives extracted (Summary heading + after-H1 fallback)"
else
  fail "a story narrative is missing"; sed 's/^/      /' <<<"$body"
fi

# ── 3. Determinism (AC 4): two renders byte-identical ──
b1="$(render_in "$FULL" 9)"; b2="$(render_in "$FULL" 9)"
if [[ "$b1" == "$b2" ]]; then
  pass "two renders are byte-identical (deterministic)"
else
  fail "render output is non-deterministic"; diff <(printf '%s' "$b1") <(printf '%s' "$b2") | sed 's/^/      /'
fi

# ── 4. Purity (AC 3): zero gh calls during render_pr_body ──
export GH_CALL_LOG="$TMPROOT/purity.log"; : > "$GH_CALL_LOG"
(
  set -euo pipefail
  PATH="$GH_BIN:$PATH"
  log_dim() { :; }; log_info() { :; }; log_warn() { :; }; log_success() { :; }; log_error() { :; }
  # shellcheck disable=SC1090
  source <(extract_write_guards)
  # shellcheck disable=SC1090
  source <(extract_pr_body)
  render_pr_body 9 "$FULL/docs/epics/issue-9.md" "$FULL/docs/stories" "$FULL" >/dev/null
)
if [[ ! -s "$GH_CALL_LOG" ]]; then
  pass "render_pr_body made ZERO gh calls (pure)"
else
  fail "render_pr_body invoked gh"; sed 's/^/      /' "$GH_CALL_LOG"
fi

# ── 5. No-assumptions fixture → explicit line (AC 1: never silently empty) ──
CLEAN="$(make_clean_fixture)"
cbody="$(render_in "$CLEAN" 5)"
if grep -qF '_No assumptions or open questions were recorded in the planning or story artifacts.' <<<"$cbody"; then
  pass "no recorded guesses → explicit 'No assumptions…' line (never silently empty)"
else
  fail "missing the explicit no-assumptions line"; sed 's/^/      /' <<<"$cbody"
fi

# ── 6. Fallbacks: uncommitted / missing done.md / missing ACs ──
FB="$(make_fallback_fixture)"
fbody="$(render_in "$FB" 3)"
if grep -qF 'Commit: _(not yet committed)_' <<<"$fbody" \
   && grep -qF '_(no implementation summary)_' <<<"$fbody" \
   && grep -qF '_(no acceptance criteria recorded)_' <<<"$fbody"; then
  pass "fallbacks render: not-yet-committed, no-summary, no-AC"
else
  fail "a fallback line is missing"; sed 's/^/      /' <<<"$fbody"
fi

# ── 7. update_issue_pr_body --write OFF → dry, stub untouched, rc 0 ──
REPO="$FULL"; ISSUE=9
export GH_CALL_LOG="$TMPROOT/calls-off.log"; : > "$GH_CALL_LOG"
off_rc=0; off_out="$(GITHUB_WRITE=0 run_update)" || off_rc=$?
if [[ "$off_rc" -eq 0 ]] \
   && [[ ! -s "$GH_CALL_LOG" ]] \
   && grep -q '\[dry\] gh pr edit ralph/issue-9 --body-file' <<<"$off_out"; then
  pass "--write off: [dry] gh pr edit logged, gh never called, rc 0"
else
  fail "--write off leaked: rc=$off_rc ghcalls=$(wc -l < "$GH_CALL_LOG")"; sed 's/^/      /' <<<"$off_out"
fi

# ── 8. --write ON with pr.txt → exactly one `pr edit`, body byte-equal, converges ──
# A capturing `gh` stub records its args AND copies the --body-file so the on-disk
# body can be compared to render_pr_body byte-for-byte.
printf 'https://github.com/seevali/ralph-loop-demo/pull/99\n' > "$FULL/docs/prd/issue-9-pr.txt"
expected_body="$(render_in "$FULL" 9)"
CAP_BIN="$(mktemp -d)"
cat > "$CAP_BIN/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$GH_CALL_LOG"
# Model the PR's draft state for the isDraft human-edit guard (default: still a draft).
if [[ "\${1:-} \${2:-}" == "pr view" ]]; then
  printf '%s\n' "\${PR_IS_DRAFT:-true}"
  exit 0
fi
if [[ "\${1:-} \${2:-}" == "pr edit" ]]; then
  for ((k = 1; k <= \$#; k++)); do
    if [[ "\${!k}" == "--body-file" ]]; then n=\$((k + 1)); cp "\${!n}" "$TMPROOT/captured-body.md"; fi
  done
fi
exit 0
STUB
chmod +x "$CAP_BIN/gh"
export GH_CALL_LOG="$TMPROOT/calls-on.log"; : > "$GH_CALL_LOG"
on_rc=0
(
  set +e
  PATH="$CAP_BIN:$PATH"
  REPO_ROOT="$FULL"; ISSUE_NUMBER=9
  EPIC_FILE="$FULL/docs/epics/issue-9.md"; STORIES_DIR="$FULL/docs/stories"
  export GH_CALL_LOG
  log_dim() { :; }; log_info() { :; }; log_warn() { :; }; log_success() { :; }; log_error() { :; }
  # shellcheck disable=SC1090
  source <(extract_write_guards)
  # shellcheck disable=SC1090
  source <(extract_pr_body)
  GITHUB_WRITE=1 update_issue_pr_body
) || on_rc=$?
edit_count="$(grep -c '^pr edit ' "$GH_CALL_LOG" || true)"
if [[ "$on_rc" -eq 0 ]] && [[ "$edit_count" -eq 1 ]] \
   && [[ -f "$TMPROOT/captured-body.md" ]] \
   && [[ "$(cat "$TMPROOT/captured-body.md")" == "$expected_body" ]]; then
  pass "--write on: exactly one 'pr edit --body-file'; body == render_pr_body byte-for-byte"
else
  fail "--write on wrong: rc=$on_rc edits=$edit_count bodymatch=$([[ "$(cat "$TMPROOT/captured-body.md" 2>/dev/null)" == "$expected_body" ]] && echo yes || echo no)"
fi

# Re-run converges: still exactly one edit call (no duplicate PR bodies)
: > "$GH_CALL_LOG"
(
  set +e
  PATH="$CAP_BIN:$PATH"
  REPO_ROOT="$FULL"; ISSUE_NUMBER=9
  EPIC_FILE="$FULL/docs/epics/issue-9.md"; STORIES_DIR="$FULL/docs/stories"
  export GH_CALL_LOG
  log_dim() { :; }; log_info() { :; }; log_warn() { :; }; log_success() { :; }; log_error() { :; }
  # shellcheck disable=SC1090
  source <(extract_write_guards)
  # shellcheck disable=SC1090
  source <(extract_pr_body)
  GITHUB_WRITE=1 update_issue_pr_body
) >/dev/null 2>&1 || true
rerun_count="$(grep -c '^pr edit ' "$GH_CALL_LOG" || true)"
if [[ "$rerun_count" -eq 1 ]]; then
  pass "idempotent: re-run makes exactly one 'pr edit' (converges, no duplicates)"
else
  fail "re-run made $rerun_count edit calls (expected 1)"
fi

# ── 8c. Ready PR: once the PR is no longer a draft (already graduated to ready-for-
# review), the body is no longer loop-owned — a --write re-run must SKIP the edit so
# human review edits to the ready body are never clobbered (parity with mark_issue_pr_ready).
: > "$GH_CALL_LOG"
(
  set +e
  PATH="$CAP_BIN:$PATH"
  REPO_ROOT="$FULL"; ISSUE_NUMBER=9
  EPIC_FILE="$FULL/docs/epics/issue-9.md"; STORIES_DIR="$FULL/docs/stories"
  export GH_CALL_LOG PR_IS_DRAFT=false
  log_dim() { :; }; log_info() { :; }; log_warn() { :; }; log_success() { :; }; log_error() { :; }
  # shellcheck disable=SC1090
  source <(extract_write_guards)
  # shellcheck disable=SC1090
  source <(extract_pr_body)
  GITHUB_WRITE=1 update_issue_pr_body
) >/dev/null 2>&1 || true
ready_edits="$(grep -c '^pr edit ' "$GH_CALL_LOG" || true)"
rm -rf "$CAP_BIN"
if [[ "$ready_edits" -eq 0 ]]; then
  pass "ready PR: --write re-run makes ZERO 'pr edit' (human edits to a ready body never clobbered)"
else
  fail "ready-PR guard failed: $ready_edits edit calls (expected 0)"
fi

# ── 9. --write ON without pr.txt → warn + rc 0, zero writes ──
rm -f "$FULL/docs/prd/issue-9-pr.txt"
export GH_CALL_LOG="$TMPROOT/calls-nourl.log"; : > "$GH_CALL_LOG"
nourl_rc=0; nourl_out="$(GITHUB_WRITE=1 run_update)" || nourl_rc=$?
if [[ "$nourl_rc" -eq 0 ]] && [[ ! -s "$GH_CALL_LOG" ]] \
   && grep -q 'no recorded PR URL' <<<"$nourl_out"; then
  pass "--write on, no pr.txt: warn + rc 0, zero stub writes (best-effort)"
else
  fail "no-url path wrong: rc=$nourl_rc ghcalls=$(wc -l < "$GH_CALL_LOG")"; sed 's/^/      /' <<<"$nourl_out"
fi

# ── 10. I3: never merge/close across every recorded call in this run ──
ALL_CALLS="$TMPROOT/all-calls.log"; cat "$TMPROOT"/calls-*.log > "$ALL_CALLS" 2>/dev/null || true
if ! grep -Eq 'pr merge|pr close|issue close' "$ALL_CALLS"; then
  pass "I3 upheld: no 'pr merge' / 'pr close' / 'issue close' ever recorded"
else
  fail "I3 VIOLATED: a merge/close call was recorded"; grep -E 'pr merge|pr close|issue close' "$ALL_CALLS" | sed 's/^/      /'
fi

echo "──────────────────────────────────────────────────────────────"
printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
