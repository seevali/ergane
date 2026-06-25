#!/usr/bin/env bash
# Idempotent: files the design-level umbrella epic + the 5 NEW Issue-Native
# component issues (Slice B) from the body files beside this script, and wires
# the umbrella to the round-trip slice (#1-#6, Slice A). Safe to re-run: labels
# create-or-edit; issues are matched by exact title and their bodies re-synced
# from files (files are source of truth); the umbrella's child lists regenerate.
#
# Requires: `gh` authenticated with WRITE scope on the repo.
# Usage:   ./create-design-issues.sh [OWNER/NAME]   (default: seevali/ralph-loop-demo)
set -euo pipefail

REPO="${1:-seevali/ralph-loop-demo}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Target repo: $REPO"
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. Run: gh auth login -h github.com"; exit 1; }

# --- 1. Labels (idempotent) -------------------------------------------------
ensure_label() { # name color description
  gh label create "$1" --repo "$REPO" --color "$2" --description "$3" 2>/dev/null \
    || gh label edit "$1" --repo "$REPO" --color "$2" --description "$3" >/dev/null 2>&1 || true
}
echo "==> Ensuring labels"
ensure_label "ralph:issue-native" "0052cc" "The Issue-Native BMAD Loop (unified design)"
ensure_label "ralph:manifest"     "0e8a16" "Manifest, identity markers & typed reconciler"
ensure_label "ralph:sub-issues"   "0e8a16" "Native GitHub sub-issue creation + source-issue body"
ensure_label "ralph:workflow"     "0e8a16" "Label state machine & loop:ready contract"
ensure_label "ralph:resize"       "0e8a16" "Re-sizing / correct-course"
ensure_label "ralph:intake"       "0e8a16" "Big-issue intake binding (issue -> PRD/epic/stories + sub-issues)"
ensure_label "ralph:epic"         "5319e7" "Umbrella epic issue" 2>/dev/null || true
ensure_label "type:feature"       "fbca04" "User-facing capability" 2>/dev/null || true
ensure_label "type:plumbing"      "c5def5" "Infrastructure other features stand on" 2>/dev/null || true
ensure_label "ralph:blocked"      "b60205" "Has unmet dependencies (see body)" 2>/dev/null || true
ensure_label "roadmap"            "d93f0b" "Scan-excluded: loop must NOT pick this up until Triage promotes it" 2>/dev/null || true

# --- 2. Helpers (quote-safe, body-syncing) ----------------------------------
find_issue_number() { # exact title -> number (empty if none); jq --arg = quote-safe
  gh issue list --repo "$REPO" --state all --limit 300 --json number,title \
    | jq -r --arg t "$1" '.[] | select(.title == $t) | .number' | head -n1
}
create_issue() { # title body_file label[,label...] -> echoes number; syncs body on re-run
  local title="$1" body="$2" labels="$3" num
  num="$(find_issue_number "$title")"
  if [[ -n "$num" ]]; then
    gh issue edit "$num" --repo "$REPO" --body-file "$body" >/dev/null
    echo "    synced: #$num  $title" >&2; printf '%s' "$num"; return 0
  fi
  local args=(--repo "$REPO" --title "$title" --body-file "$body")
  IFS=',' read -ra L <<< "$labels"
  for l in "${L[@]}"; do args+=(--label "$l"); done
  local url; url="$(gh issue create "${args[@]}")"; num="${url##*/}"
  echo "    created: #$num  $title" >&2; printf '%s' "$num"
}

# --- 3. Slice B: the 5 new component issues ---------------------------------
echo "==> Creating/syncing Slice B component issues"
TN3="[ralph] Label state machine & the loop:ready contract"
TN1="[ralph] Manifest, identity markers & the typed reconciler"
TN2="[ralph] Native sub-issue creation + source-issue-as-epic body"
TN5="[ralph] Big-issue intake binding (issue -> PRD/epic/stories + sub-issues)"
TN4="[ralph] Re-sizing / correct-course"

N3="$(create_issue "$TN3" "$DIR/n3-label-workflow.md"          "ralph:issue-native,ralph:workflow,type:feature,ralph:blocked,roadmap")"
N1="$(create_issue "$TN1" "$DIR/n1-manifest-and-reconciler.md" "ralph:issue-native,ralph:manifest,type:plumbing,ralph:blocked,roadmap")"
N2="$(create_issue "$TN2" "$DIR/n2-native-sub-issues.md"       "ralph:issue-native,ralph:sub-issues,type:feature,ralph:blocked,roadmap")"
N5="$(create_issue "$TN5" "$DIR/n5-big-issue-intake-binding.md" "ralph:issue-native,ralph:intake,type:feature,ralph:blocked,roadmap")"
N4="$(create_issue "$TN4" "$DIR/n4-resizing-correct-course.md" "ralph:issue-native,ralph:resize,type:feature,ralph:blocked,roadmap")"

# --- 4. Umbrella epic with both slices injected -----------------------------
echo "==> Creating/refreshing umbrella epic"
SLICE_A="- [ ] #6 — EPIC: GitHub Issue Round-Trip & Autonomy *(tracks #1 Round Trip · #2 Triage · #3 Confessing PR · #4 Worktree · #5 Swarm — the write-back slice)*"
SLICE_B="$(cat <<EOF
**Build order:** (#$N3 Labels + #$N1 Manifest/reconciler) → #$N2 Native sub-issues → #$N5 Big-issue intake → #$N4 Re-sizing

- [ ] #$N3 — Label state machine & the loop:ready contract *(foundation)*
- [ ] #$N1 — Manifest, identity markers & the typed reconciler *(foundation; plumbing)*
- [ ] #$N2 — Native sub-issue creation + source-issue-as-epic body
- [ ] #$N5 — Big-issue intake binding (issue → PRD/epic/stories + sub-issues)
- [ ] #$N4 — Re-sizing / correct-course
EOF
)"
EPIC_BODY="$(mktemp)"
awk -v a="$SLICE_A" -v b="$SLICE_B" '
  /<!-- RALPH:SLICE-A -->/   {print; print a; skipa=1; next}
  /<!-- \/RALPH:SLICE-A -->/ {skipa=0; print; next}
  /<!-- RALPH:SLICE-B -->/   {print; print b; skipb=1; next}
  /<!-- \/RALPH:SLICE-B -->/ {skipb=0; print; next}
  skipa||skipb {next} {print}
' "$DIR/epic-issue-native-bmad-loop.md" > "$EPIC_BODY"

TE="[ralph] EPIC: The Issue-Native BMAD Loop"
NE="$(find_issue_number "$TE")"
if [[ -n "$NE" ]]; then
  gh issue edit "$NE" --repo "$REPO" --body-file "$EPIC_BODY" >/dev/null; echo "    updated epic: #$NE"
else
  URL="$(gh issue create --repo "$REPO" --title "$TE" --body-file "$EPIC_BODY" \
    --label "ralph:issue-native" --label "ralph:epic" --label "roadmap")"; NE="${URL##*/}"
  echo "    created epic: #$NE"
fi
rm -f "$EPIC_BODY"

echo
echo "==> Done. Umbrella #$NE; Slice B: labels #$N3, manifest #$N1, sub-issues #$N2, intake #$N5, resize #$N4"
echo "    Update design §11 traceability with these numbers."
gh issue list --repo "$REPO" --label "ralph:issue-native" --state open
