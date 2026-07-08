> **Umbrella EPIC** for [The Issue-Native BMAD Loop](https://github.com/seevali/ergane/blob/main/system/design/issue-native-bmad-loop.md) — the architecture unifying GitHub Issues + BMAD (PRD→epic→story) + the Ralph Loop. This issue mirrors that design doc, which is the **source of truth**; this issue is the tracker view.

## What this is

A maintainer (owner or community-served) should move a product forward without friction: every work item enters as a GitHub issue, passes a maintainer review gate, and the loop builds it — **small** work as the issue itself (one PR), **big** work with the source issue becoming a BMAD **epic** whose **stories are native GitHub sub-issues** (one PR each). In-repo PRD/epic/story **files stay the book of record; GitHub is a projection.**

**The governing law:** *the machine may think at any scale but act only at the scale the human last authorized; any change in authorized spend returns to the human.*

## Component issues

**Slice A — Write-back & autonomy (the `2026-06-24`/`2026-06-25` round-trip chapter — partial implementations):**
<!-- RALPH:SLICE-A -->
_(round-trip issue list injected by create-design-issues.sh)_
<!-- /RALPH:SLICE-A -->

**Slice B — Issue-native machinery (new, this design):**
<!-- RALPH:SLICE-B -->
_(new component issue list injected by create-design-issues.sh)_
<!-- /RALPH:SLICE-B -->

## Build order (overall)

Foundations first (label workflow + manifest/reconciler), then the GitHub hierarchy (sub-issue creation), then intake binding, then re-sizing — the round-trip write primitives (Slice A #1) underpin all GitHub writes:

```
[Labels+contract] + [Manifest+reconciler]  →  [Native sub-issues]  →  [Big-issue intake]  →  [Re-sizing]
        (depends on Slice A #1 write primitives throughout)
```

## Definition of done (epic)

- [ ] All Slice A + Slice B component issues closed (or killed per their kill criteria).
- [ ] The design doc §11 traceability table reflects shipped behavior.
- [ ] A live big issue goes end-to-end: filed → gated → planned → sub-issues created → built per sub-issue → merged → source issue closed — with the merge-as-is rate measured.

See the design doc for the full spec: governing law (§2), lifecycle (§3), labels (§4), source-of-truth & manifest (§5), GitHub representation (§6), re-sizing (§7), runtime split (§8), autonomy bound (§9).
