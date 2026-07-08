> **Component of [The Issue-Native BMAD Loop](https://github.com/seevali/ergane/blob/main/system/design/issue-native-bmad-loop.md)** · design §6. The design doc is the source of truth.

## Context (cold-start)

For a **big** work item, the source GitHub issue becomes a BMAD **epic** and each story becomes a **native GitHub sub-issue** (GitHub's real parent/child hierarchy, not a task-list checkbox). The source issue's body is updated to list its sub-issues.

## Problem

The Ralph Loop today never creates sub-issues, and `gh`'s REST surface has no native sub-issue link. Naively rewriting the source-issue body would also clobber the reporter's original text (especially harmful for community issues).

## Proposed mechanism (see design §6)

1. **Create sub-issues via GraphQL `addSubIssue`** (REST has no equivalent): `gh issue create` → capture number + node id → resolve parent node id → `gh api graphql … addSubIssue(input:{issueId:$parent, subIssueId:$child})`. Stamp the identity marker in the body (from the manifest component).
2. **Append (never overwrite) the source-issue body** with a fail-closed fenced managed block (`<!-- RALPH:BEGIN -->`…`<!-- RALPH:END -->`) listing the sub-issues; rendered **from the manifest**, written via `gh issue edit --body-file`. Abort the edit if fences are missing/duplicated.
3. All writes behind the `--write` gate (default off) via `gh_*_op` helpers.

## Acceptance criteria

- [ ] Big-issue stories appear as **native** sub-issues of the source issue (parent/child link visible on GitHub).
- [ ] The source-issue body gains a fenced task-list of sub-issues with the reporter's original text **preserved byte-for-byte**.
- [ ] Splice is fail-closed (malformed fences → abort, edit nothing) and re-run converges to identical bytes.
- [ ] With `--write` off, no network; the body-render is a pure function of the manifest (offline-testable).
- [ ] No auto-merge / auto-close (ADR I3); design §6 matches shipped behavior (anti-drift DoD).

## Dependencies

- **Blocked by:** the manifest/reconciler component (identity markers + state) and Slice A [#1 Round Trip](https://github.com/seevali/ergane/issues/1) (`gh_*_op` write helpers).
- **Blocks:** big-issue intake binding, re-sizing.

## Out of scope

The PRD/epic/story file generation (intake binding component); per-sub-issue PR review experience ([#3 Confessing PR](https://github.com/seevali/ergane/issues/3)); the label lifecycle (label-workflow component).

Glossary: design §12.
