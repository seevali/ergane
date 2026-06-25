#!/usr/bin/env bash
# Idempotent bootstrap: files the GitHub issue taxonomy, epic, and 5 children for
# the "GitHub Issue Round-Trip & Autonomy" chapter from the body files beside this
# script. Safe to re-run: labels use `create || true`; issues are skipped if one
# with the same title already exists; the epic's child checklist is regenerated.
#
# Requires: `gh` authenticated with WRITE scope (issues + labels) on the repo.
# Usage:   ./create-github-issues.sh [OWNER/NAME]   (default: seevali/ralph-loop-demo)
set -euo pipefail

REPO="${1:-seevali/ralph-loop-demo}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Target repo: $REPO"
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. Run: gh auth login -h github.com"; exit 1; }

# --- 1. Labels (idempotent) -------------------------------------------------
ensure_label() { # name  color  description
  gh label create "$1" --repo "$REPO" --color "$2" --description "$3" 2>/dev/null \
    || gh label edit "$1" --repo "$REPO" --color "$2" --description "$3" >/dev/null 2>&1 || true
}
echo "==> Ensuring labels"
ensure_label "ralph:issue-support" "1d76db" "Epic: GitHub issue round-trip & autonomy"
ensure_label "ralph:round-trip"    "0e8a16" "Idea 1: branch/PR/comment/label write-back (the spine)"
ensure_label "ralph:confessing-pr" "0e8a16" "Idea 2: PR body synthesized from per-story artifacts"
ensure_label "ralph:worktree"      "0e8a16" "Idea 3: git worktree isolation"
ensure_label "ralph:triage"        "0e8a16" "Idea 4: readiness pre-phase / gate"
ensure_label "ralph:swarm"         "0e8a16" "Idea 5: serial multi-issue + ralph watch + brake"
ensure_label "ralph:epic"          "5319e7" "Umbrella epic issue"
ensure_label "type:feature"        "fbca04" "User-facing capability"
ensure_label "type:plumbing"       "c5def5" "Infrastructure other features stand on"
ensure_label "ralph:blocked"       "b60205" "Has unmet dependencies (see body)"
ensure_label "ralph:ready"         "0e8a16" "Triage verdict: buildable"
ensure_label "ralph:needs-triage"  "fbca04" "Triage verdict: underspecified"
ensure_label "roadmap"             "d93f0b" "Scan-excluded: loop must NOT pick this up as work until Triage promotes it"

# --- 2. Helpers -------------------------------------------------------------
find_issue_number() { # exact title -> number (empty if none)
  # Pipe to standalone jq with --arg so titles containing quotes/parens are safe
  # (gh's inline --jq would break on a title like '… ("I had to guess")').
  gh issue list --repo "$REPO" --state all --limit 300 --json number,title \
    | jq -r --arg t "$1" '.[] | select(.title == $t) | .number' | head -n1
}

create_issue() { # title  body_file  label[,label...] -> echoes number
  # Declarative: the body FILES are the source of truth. On re-run, an existing
  # issue's body is re-synced from its file (overwrites manual edits to the body).
  local title="$1" body="$2" labels="$3" num
  num="$(find_issue_number "$title")"
  if [[ -n "$num" ]]; then
    gh issue edit "$num" --repo "$REPO" --body-file "$body" >/dev/null
    echo "    synced: #$num  $title" >&2
    printf '%s' "$num"; return 0
  fi
  local args=(--repo "$REPO" --title "$title" --body-file "$body")
  IFS=',' read -ra L <<< "$labels"
  for l in "${L[@]}"; do args+=(--label "$l"); done
  local url; url="$(gh issue create "${args[@]}")"
  num="${url##*/}"
  echo "    created: #$num  $title" >&2
  printf '%s' "$num"
}

# --- 3. Children first (so the epic can link them) --------------------------
echo "==> Creating child issues"
T1="[ralph] The Round Trip — branch-per-issue → draft PR → self-updating comment → labels"
T2="[ralph] The Confessing PR — synthesize PR body from per-story artifacts (\"I had to guess\")"
T3="[ralph] Worktree-per-Issue — git worktree isolation for clean, concurrent-capable runs"
T4="[ralph] Triage Before Toil — readiness pre-phase that gates issues before building"
T5="[ralph] Swarm + Mission Control — serial multi-issue (v1) + ralph watch + brake"

N1="$(create_issue "$T1" "$DIR/01-round-trip.md"        "ralph:issue-support,ralph:round-trip,type:feature,ralph:ready,roadmap")"
N4="$(create_issue "$T4" "$DIR/04-triage-before-toil.md" "ralph:issue-support,ralph:triage,type:feature,ralph:blocked,roadmap")"
N2="$(create_issue "$T2" "$DIR/02-confessing-pr.md"     "ralph:issue-support,ralph:confessing-pr,type:feature,ralph:blocked,roadmap")"
N3="$(create_issue "$T3" "$DIR/03-worktree-per-issue.md" "ralph:issue-support,ralph:worktree,type:plumbing,ralph:blocked,roadmap")"
N5="$(create_issue "$T5" "$DIR/05-swarm-mission-control.md" "ralph:issue-support,ralph:swarm,type:feature,ralph:blocked,roadmap")"

# --- 4. Epic with child checklist + dependency graph ------------------------
echo "==> Creating/refreshing epic"
CHECKLIST="$(cat <<EOF
**Build order (trust before scale):** #$N1 → #$N4 → (#$N2, #$N3) → #$N5

- [ ] #$N1 — The Round Trip *(spine; build by hand; blocks all others)*
- [ ] #$N4 — Triage Before Toil *(blocked by #$N1; promoted ahead of #$N2/#$N3)*
- [ ] #$N2 — The Confessing PR *(blocked by #$N1)*
- [ ] #$N3 — Worktree-per-Issue *(blocked by #$N1; blocks #$N5)*
- [ ] #$N5 — Swarm + Mission Control *(blocked by #$N3; serial v1, concurrency = v2)*
EOF
)"
EPIC_BODY="$(mktemp)"
awk -v repl="$CHECKLIST" '
  /<!-- RALPH:CHILDREN -->/ {print; print repl; skip=1; next}
  /<!-- \/RALPH:CHILDREN -->/ {skip=0; print; next}
  skip {next} {print}
' "$DIR/epic-github-issue-roundtrip.md" > "$EPIC_BODY"

TE="[ralph] EPIC: GitHub Issue Round-Trip & Autonomy"
NE="$(find_issue_number "$TE")"
if [[ -n "$NE" ]]; then
  gh issue edit "$NE" --repo "$REPO" --body-file "$EPIC_BODY" >/dev/null
  echo "    updated epic: #$NE"
else
  URL="$(gh issue create --repo "$REPO" --title "$TE" --body-file "$EPIC_BODY" \
    --label "ralph:issue-support" --label "ralph:epic" --label "roadmap")"
  NE="${URL##*/}"
  echo "    created epic: #$NE"
fi
rm -f "$EPIC_BODY"

echo
echo "==> Done. Epic #$NE; children #$N1 #$N2 #$N3 #$N4 #$N5"
echo "    Update prd.md §9 traceability table with these numbers."
gh issue list --repo "$REPO" --label "ralph:issue-support" --state open
