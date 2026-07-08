> **Component of [The Issue-Native BMAD Loop](https://github.com/seevali/ergane/blob/main/system/design/issue-native-bmad-loop.md)** · design §10 (extends Path A). The design doc is the source of truth.

## Context (cold-start)

The loop's existing **Path A intake** (`--issue N`) already turns one GitHub issue into PRD/epic/story **files**, but it (a) writes only to Demo-Track `docs/` paths, (b) creates no GitHub sub-issues, and (c) is read-only against GitHub. The Issue-Native design needs intake to produce the full BMAD hierarchy *and* the GitHub sub-issue hierarchy, routed correctly for System Track (or any component).

## Problem

Today there is no path from "a `loop:ready` big issue" to "PRD + epic + story files (book of record) **and** native sub-issues bound to them." Path A is the closest primitive but is demo-track-flavored and GitHub-read-only.

## Proposed mechanism (see design §10)

1. **On a `size:big`, `loop:ready` source issue:** run the BMAD planning chain (PM → optional Architect → Planner) to produce the PRD + epic + story files (the book of record), component/track-routed (not hardcoded to `docs/`).
2. **Bind to GitHub:** for each story, create a native sub-issue (native-sub-issue component) and record `N.k ↔ #X` in the manifest (manifest component); append the source-issue body with the sub-issue task-list.
3. **Then build per sub-issue** via the existing SM → Dev → Review cycle, one PR per sub-issue.
4. **Small path:** `size:small` skips the split — brief + one story, one PR, no sub-issues.
5. Honors source-of-truth (files authoritative), `--write` gate, and the `loop:ready` contract.

## Acceptance criteria

- [ ] A `size:big` `loop:ready` issue produces PRD + epic + story files **and** native sub-issues bound 1:1 to the stories via the manifest.
- [ ] Output paths are component/track-routed (not hardcoded to Demo-Track `docs/`); System Track work lands correctly.
- [ ] A `size:small` issue builds directly (one PR, no sub-issues, brief not full PRD).
- [ ] Re-running intake is idempotent (no duplicate files, sub-issues, or PRDs).
- [ ] Files remain fully sufficient for a fresh clone (GitHub not required to understand the work).
- [ ] Design §10 matches shipped behavior (anti-drift DoD).

## Dependencies

- **Blocked by:** manifest/reconciler, native sub-issue creation, and the label workflow (the `size:`/`loop:ready` contract). Extends the existing Path A intake.
- **Blocks:** re-sizing (which replays this pipeline on a subtree).

## Out of scope

Re-sizing (separate component); the maintainer review/scoring that sets `loop:ready` ([#2 Triage](https://github.com/seevali/ergane/issues/2)); the build cycle itself (existing SM→Dev→Review).

Glossary: design §12.
