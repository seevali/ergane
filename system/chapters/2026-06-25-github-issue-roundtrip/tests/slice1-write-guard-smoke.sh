#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Offline smoke — Slice 1 of issue #1 "The Round Trip" (GitHub write-back).
#
# Subject under test: the central --write gate (GITHUB_WRITE, default 0) and
# the three guarded helpers gh_comment_op / gh_label_op / gh_pr_op in
# scripts/ralph-loop.sh (ADR-001 invariant I1).
#
# This smoke is agent-runnable, deterministic, and touches NO network. It proves:
#
#   1. Byte-stability gate (ADR-002 non-negotiable #1): the `--dry-run-prompts`
#      output — with the wall-clock timestamp and the absolute repo path
#      normalized away — is byte-identical to the committed golden captured
#      BEFORE the write-gate change. No system-prompt byte moved, so the
#      Anthropic prompt cache still hits.
#
#   2. No-op with --write off (GITHUB_WRITE=0): each helper logs "[dry] gh …",
#      returns 0, and NEVER invokes `gh` (proven by an offline stub that records
#      any call) — the write surface is dark by default.
#
#   3. Write path with --write on (GITHUB_WRITE=1): each helper DOES invoke `gh`
#      (again via the offline stub — still no network) — the gate flips correctly.
#
# The helper functions are exercised by extracting ONLY their fenced block from
# the loop script and sourcing it, so the smoke never runs the orchestrator's
# main() and depends on nothing but the bytes of the helpers themselves.
#
# Usage:
#   slice1-write-guard-smoke.sh                 # run all checks (default)
#   slice1-write-guard-smoke.sh --update-golden # regenerate the golden, then run
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tests/ -> chapter -> chapters -> system -> repo root
REPO_ROOT="$(cd "$SMOKE_DIR/../../../.." && pwd)"
LOOP="$REPO_ROOT/scripts/ralph-loop.sh"
GOLDEN="$SMOKE_DIR/dry-run-prompts.golden"

ESC=$'\033'
PASS=0
FAIL=0

# ── Deterministic fixture for --dry-run-prompts ──
# The loop is workload-neutral: --project-dir and --epic are required (no baked-in
# defaults), so the dry-run invocation must supply its own tiny, stack-agnostic epic
# and a scratch project dir. The fixture content is byte-identical between runs so the
# golden stays deterministic; its temp path is normalized to <FIXTURE> below.
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
FIXTURE_PROJECT="$FIXTURE_DIR/app"
FIXTURE_EPIC="$FIXTURE_DIR/epic.md"
mkdir -p "$FIXTURE_PROJECT"
cat > "$FIXTURE_EPIC" <<'FIXTURE_EOF'
# Fixture Epic

## Epic 1: Fixture

### Story 1.1: Fixture story

As a fixture, I want one deterministic story so the dry-run golden is stable.
FIXTURE_EOF

pass() { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Strip ANSI colors, pin the wall-clock timestamp, and make the repo path
# portable so the golden is clone- and machine-independent. The exact same
# transform is applied when capturing the golden and when comparing against it.
normalize() {
  # $REPO_ROOT normalization keeps the golden clone-/machine-independent. The
  # fixture temp dir lives OUTSIDE the repo (mktemp), so it would otherwise leak a
  # per-run path into any epic/project echoes — collapse it to a stable token too.
  sed -E \
    -e "s/${ESC}\[[0-9;]*m//g" \
    -e 's/\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]/[TIMESTAMP]/g' \
    -e "s|${REPO_ROOT}|<REPO_ROOT>|g" \
    -e "s|${FIXTURE_DIR}|<FIXTURE>|g"
}

capture_dryrun() {
  # --dry-run-prompts never invokes claude (it prints resolved prompts and
  # exits), so this is offline. Explicit --project-dir/--epic/--checkpoint satisfy
  # the loop's required flags (workload-neutral, no defaults). --checkpoint is a
  # FIXED literal 'true' (not a temp path) so the golden stays deterministic; the
  # dry-run never eval's it — it just substitutes into the composed prompts, where
  # 'true' now appears wherever the old demo checkpoint string used to. stderr is
  # dropped; only the prompt projection on stdout is the contract.
  "$LOOP" --dry-run-prompts --project-dir "$FIXTURE_PROJECT" --epic "$FIXTURE_EPIC" --checkpoint true 2>/dev/null | normalize
}

# Pull just the write-guard block out of the loop script (between the sentinels)
# so we can source the helpers in isolation, with no orchestrator side effects.
extract_helpers() {
  awk '
    /# >>> RALPH WRITE GUARDS/ { f = 1 }
    f                          { print }
    /# <<< RALPH WRITE GUARDS/ { f = 0 }
  ' "$LOOP"
}

# ── --update-golden: regenerate the baseline from the current script ──
if [[ "${1:-}" == "--update-golden" ]]; then
  capture_dryrun > "$GOLDEN"
  printf 'Golden regenerated: %s (%s lines)\n' "$GOLDEN" "$(wc -l < "$GOLDEN")"
  shift || true
fi

echo "── Slice 1 write-guard smoke ─────────────────────────────────"

# ── Check 1: byte-stability of --dry-run-prompts vs the golden ──
if [[ ! -f "$GOLDEN" ]]; then
  fail "golden missing ($GOLDEN) — run with --update-golden first"
else
  # Compare raw streams (no $() round-trip, which would strip trailing newlines)
  # so the byte comparison is exact against the golden written the same way.
  if diff -u "$GOLDEN" <(capture_dryrun) > /tmp/.slice1-dryrun.diff 2>&1; then
    pass "--dry-run-prompts byte-identical to golden (prompt-cache stable)"
  else
    fail "--dry-run-prompts DIFFERS from golden:"
    sed 's/^/      /' /tmp/.slice1-dryrun.diff
  fi
fi

# ── Sanity: the fenced helper block exists and defines the three helpers ──
helpers_src="$(extract_helpers)"
if [[ -n "$helpers_src" ]] \
   && grep -q 'gh_comment_op()' <<< "$helpers_src" \
   && grep -q 'gh_label_op()'   <<< "$helpers_src" \
   && grep -q 'gh_pr_op()'      <<< "$helpers_src"; then
  pass "fenced write-guard block defines gh_comment_op / gh_label_op / gh_pr_op"
else
  fail "fenced write-guard block not found or missing a helper"
fi

# ── Check 2: --write OFF (GITHUB_WRITE=0) → no-op, no network ──
net_log="$(mktemp)"; : > "$net_log"
dry_out="$(
  set +e
  GITHUB_WRITE=0
  # log_dim shim: strip the loop's LOG_FILE/timestamp wiring, keep the message.
  log_dim() { printf '%s\n' "$1"; }
  # offline stub: standing in for `gh`; if a helper ever reaches it with --write
  # off, that is a leak — it records the call so the assertion below fails.
  gh() { echo "LEAK $*" >> "$net_log"; }
  # shellcheck disable=SC1090
  source <(extract_helpers)
  gh_comment_op issue comment 1 --body "hello"; echo "rc_comment=$?"
  gh_label_op  issue edit 1 --add-label loop:active --remove-label triage; echo "rc_label=$?"
  gh_pr_op     pr create --draft --title t; echo "rc_pr=$?"
)"

dry_marker_count="$(grep -c '\[dry\] gh ' <<< "$dry_out" || true)"
if [[ "$dry_marker_count" -eq 3 ]]; then
  pass "all three helpers logged '[dry] gh …' with --write off"
else
  fail "expected 3 '[dry] gh …' lines, got $dry_marker_count"
  sed 's/^/      /' <<< "$dry_out"
fi

if grep -q 'rc_comment=0' <<< "$dry_out" \
   && grep -q 'rc_label=0' <<< "$dry_out" \
   && grep -q 'rc_pr=0' <<< "$dry_out"; then
  pass "all three helpers returned 0 with --write off"
else
  fail "a helper returned non-zero with --write off"
  sed 's/^/      /' <<< "$dry_out"
fi

if [[ -s "$net_log" ]]; then
  fail "network leak with --write off — gh was invoked:"
  sed 's/^/      /' "$net_log"
else
  pass "no network: gh never invoked with --write off"
fi

# ── Check 3: --write ON (GITHUB_WRITE=1) → gate flips, gh is invoked ──
call_log="$(mktemp)"; : > "$call_log"
(
  set +e
  GITHUB_WRITE=1
  log_dim() { printf '%s\n' "$1"; }
  # offline stub stands in for the real gh — proves the helper DELEGATES to gh
  # when the gate is on, without ever touching the network.
  gh() { echo "CALLED $*" >> "$call_log"; }
  # shellcheck disable=SC1090
  source <(extract_helpers)
  gh_comment_op issue comment 1 --body "hello"
  gh_label_op  issue edit 1 --add-label loop:active --remove-label triage
  gh_pr_op     pr create --draft --title t
) || true

called_count="$(grep -c '^CALLED ' "$call_log" || true)"
if [[ "$called_count" -eq 3 ]]; then
  pass "all three helpers delegated to gh with --write on"
else
  fail "expected 3 gh delegations with --write on, got $called_count"
  sed 's/^/      /' "$call_log"
fi

rm -f "$net_log" "$call_log" /tmp/.slice1-dryrun.diff

echo "──────────────────────────────────────────────────────────────"
printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
