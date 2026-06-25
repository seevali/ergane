> **Component of [The Issue-Native BMAD Loop](https://github.com/seevali/ralph-loop-demo/blob/main/system/design/issue-native-bmad-loop.md)** · design §7. The design doc is the source of truth.

## Context (cold-start)

A work item sized `small` (or a story scoped in planning) can turn out, mid-build, to be much bigger — needing a PRD, an epic, and multiple sub-issues/PRs. The BMAD analog is `bmad-correct-course`. Sizing up front is the least-reliable estimate in software, so the system must handle being wrong gracefully.

## Problem

If the loop silently shatters a `small` issue into an epic with sub-issues, the maintainer returns to find work restructured at a scale they never authorized — and stops trusting the loop. If the loop instead grinds on an under-sized story forever, it stalls. Neither is acceptable.

## Proposed mechanism (see design §7)

1. **Append-and-supersede, never edit-in-place.** Split `N.k` into new ids `N.k.1, N.k.2, …` (new story files + manifest rows); mark the parent `superseded` (a first-class terminal state reconciliation treats as done-by-replacement, not an orphan). Promotion **replays the BIG-intake code path on a subtree** — not a special subsystem.
2. **Detect autonomously, promote through a fresh human gate.** The dev agent emits a structured signal (a sentinel file, e.g. `.resize-request.json`) instead of a `feat()` commit; a heuristic guard (N iterations, no `feat(N.k)`) backstops it. On detection the loop **halts that unit**, sets the warm `needs-resize` label, and posts **one comment showing its work** (what it found, the proposed breakdown, rough PR count, option to scope down). It creates no sub-issues until the human swaps `size:small → big` and re-applies `loop:ready`.
3. The promotion transaction lives in the typed `reconcile.ts` (manifest component) and is crash-safe: the sentinel exists iff a promotion is incomplete; every sub-step idempotent; **no story with a landed `feat()` commit is ever removed**.

## Acceptance criteria

- [ ] On a detected under-size, the loop halts that unit, sets `needs-resize`, posts a show-your-work comment, and creates **no** sub-issues until human re-gates.
- [ ] Promotion creates child stories/sub-issues idempotently and marks the parent `superseded`; reconciliation never re-flags a `superseded` story as broken.
- [ ] A crash mid-promotion re-runs cleanly from the sentinel (convergent, orphan-free).
- [ ] The inverse (big → small) follows the same halt → re-gate symmetry.
- [ ] Design §7 matches shipped behavior (anti-drift DoD).

## Dependencies

- **Blocked by:** manifest/reconciler component (owns the promotion transaction + `superseded` state), native sub-issue creation, big-issue intake binding, and the label workflow (`needs-resize`, re-gate).

## Out of scope

Auto-promotion without a human gate (forbidden — change in authorized spend returns to the human, design §2/§7); auto-close of superseded sub-issues (a maintainer call).

Glossary: design §12.
