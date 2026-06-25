> **Component of [The Issue-Native BMAD Loop](https://github.com/seevali/ralph-loop-demo/blob/main/system/design/issue-native-bmad-loop.md)** · design §5 (manifest) + §8 (typed runtime). The design doc is the source of truth.

## Context (cold-start)

The Issue-Native loop keeps in-repo files + git as the **authoritative** record and GitHub as a **projection**. To bind the two it needs a durable, consistent map from BMAD story IDs (`N.k`) to GitHub sub-issue numbers (which GitHub assigns), plus a way to reconcile files, git, and GitHub on every loop start without drifting or duplicating.

## Problem

GitHub assigns sub-issue numbers; story IDs are ours. Without a persisted, crash-safe binding and a reconciliation pass, a re-run duplicates sub-issues, a crash mid-creation strands them, and the file/GitHub views silently diverge.

## Proposed mechanism (see design §5, §8)

1. **Identity marker** in each sub-issue **body** (`<!-- ralph:story=N.k source=S -->`) — the durable anchor (titles can be hand-edited).
2. **Manifest** `docs/<component>/implementation/issue-manifest.json` — a derivable **cache** of `story N.k ↔ sub_issue # + node_id + state + pr_url + feat() commit`. Atomic writes (`mktemp`+`jq`+`mv -f`); write-after-confirm one story at a time; reconstructible from markers ∪ `git log`.
3. **Convergent reconciliation** each loop start: heal the cache, let git override GitHub *state* (close issues whose `feat(N.k)` landed), and **flag — never reverse** — human edits.
4. **Typed `reconcile.ts`** (in the new `tools/` dir — Node exception per design §8 / CLAUDE.md) owns the three-source join and the re-sizing promotion transaction; Bash orchestrates and observes.

## Acceptance criteria

- [ ] Re-running any phase converges to the same GitHub state (no duplicate sub-issues; idempotent).
- [ ] A crash mid-creation self-heals on next run via the marker search (no orphans, no duplicates).
- [ ] Losing/corrupting the manifest is recoverable: it rebuilds from markers ∪ `git log`.
- [ ] Reconciliation **flags, never reverses**, human-made closes/edits/out-of-band sub-issues.
- [ ] `reconcile.ts` has deterministic, agent-runnable unit tests (golden-file; nondeterministic inputs pinned); with `--write` off, zero network.
- [ ] Design doc §5/§8 match shipped behavior (anti-drift DoD).

## Dependencies

- **Blocked by:** the `tools/` Node exception (done — CLAUDE.md amended) and Slice A [#1 Round Trip](https://github.com/seevali/ralph-loop-demo/issues/1) write primitives.
- **Blocks:** native sub-issue creation, big-issue intake, re-sizing.

## Out of scope

Creating the sub-issues themselves (separate component); the label workflow (separate); re-sizing logic (separate, though the promotion transaction lives in the same `reconcile.ts` module).

Glossary: design §12.
