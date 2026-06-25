> **Component of [The Issue-Native BMAD Loop](https://github.com/seevali/ralph-loop-demo/blob/main/system/design/issue-native-bmad-loop.md)** · design §4. The design doc is the source of truth.

## Context (cold-start)

Every work item — owner- or community-filed — enters as a GitHub issue and is driven through its lifecycle by a **label state machine**. A single human gate authorizes the loop to spend tokens and write publicly; the loop's trigger (`--issue N` or a scheduler) reads the same label.

## Problem

There is no defined workflow today. Without an authoritative label machine, there's no consistent gate, no machine-readable "loop may claim this," and no shared vocabulary across owner/community/loop/scheduler.

## Proposed mechanism (see design §4)

1. **Status labels** (exactly one at a time; loop reads): `triage` → `loop:ready` → `loop:active` → `loop:review` → `done`. Setting a new status removes the old.
2. **Disposition/attention** (warm, loud): `needs-info`, `needs-resize`, `blocked`, `wontfix`/`duplicate`.
3. **Orthogonal tags:** `size:small|big` (set by the planning agent at intake; required for `loop:ready`), `type:bug|feature|chore|docs` (selects the BMAD path), optional `priority` (scheduler ordering only).
4. **The single gate** = the human transition `triage → loop:ready` (authorizes spend + public writes). Second human touch = `loop:review → done` (merge). The loop never auto-promotes `triage → loop:ready`, even for the owner.
5. **The `loop:ready` contract:** the loop refuses (→ `needs-info`) unless the issue is sized, has ≥1 observable acceptance criterion, is bounded (small ⇒ one PR), unblocked, and typed.
6. **Visual law:** cool = machine owns it; warm = needs the human.
7. **Outward comments:** `needs-info`/`loop:ready` post a warm, human-readable comment so the community author feels heard / informed.

## Acceptance criteria

- [ ] The label set exists with exactly one status per issue at any time (enforced by single add/remove transitions).
- [ ] `--issue N` and the scheduler both claim work via the identical query `label:loop:ready AND no open PR`.
- [ ] The loop refuses a `loop:ready` issue that fails the contract and sets `needs-info` with a comment naming the missing piece.
- [ ] Owner and community use the same pipe and the same gate (no auto-promotion to `loop:ready`).
- [ ] Label transitions are idempotent/order-independent (single `gh issue edit --add-label … --remove-label …`).
- [ ] Design §4 matches shipped behavior (anti-drift DoD).

## Dependencies

- **Relates to / supersedes the narrower** verdict-gated labels in Slice A [#1 Round Trip](https://github.com/seevali/ralph-loop-demo/issues/1) and the gate in [#2 Triage Before Toil](https://github.com/seevali/ralph-loop-demo/issues/2) — this is the authoritative, complete workflow those partially touch.
- **Blocked by:** Slice A [#1](https://github.com/seevali/ralph-loop-demo/issues/1) write helpers (label ops).

## Out of scope

Scheduler implementation ([#5 Swarm](https://github.com/seevali/ralph-loop-demo/issues/5)); the readiness *scoring* itself ([#2 Triage](https://github.com/seevali/ralph-loop-demo/issues/2)) — this component defines the labels/contract it sets.

Glossary: design §12.
