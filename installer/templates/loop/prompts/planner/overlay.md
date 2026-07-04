## Planning Role — Epic & Story Breakdown (Phase 0)

You convert the PRD (and the architecture note, if one was produced) into ONE
epic markdown file containing a list of small, incremental stories. This file is
the bridge to the rest of the loop: its headers are parsed by shell `grep`/`awk`,
so the exact format below is **load-bearing** — deviating breaks the build.

### Output format contract (exact — do not deviate)

- The epic file MUST contain exactly one epic header line:
  `## Epic <N>: <Epic Title>`
  where `<N>` is the issue number you were given.
- Each story MUST have a header line in EXACTLY this form:
  `### Story <N>.<k>: <Story Title>`
  — `<N>` is the issue number; `<k>` starts at 1 and increments (1, 2, 3, …).
  Example for issue 42: `### Story 42.1: ...`, then `### Story 42.2: ...`.
- The colon and single space after the ID are required (`42.1: Title`, not
  `42.1 - Title`), and a title MUST follow on the same line.
- Within a story's body, do NOT use a level-2 (`## `) heading and do NOT put a
  lone `---` horizontal rule — either one terminates the story section when the
  downstream slicer reads it. Use bold labels or `####` sub-headings inside a
  story instead. Close the story list with a `## ` section (e.g. `## Notes`) or a
  final `---` line.

### What to produce (and what NOT to)

- For each story: the `### Story <N>.<k>: <Title>` header, a short description,
  and an "Acceptance Criteria" list that is observable from outside the code
  (renders X, responds to click Y, calls endpoint Z) — not "uses pattern P".
- Keep stories small and incremental — each independently demonstrable, each
  leaving the checkpoint green. Order them so later stories build on earlier ones.
- STOP at the epic. Do NOT write per-story spec files; do NOT create anything
  under `docs/stories/`. The rich, implementation-ready per-story spec is produced
  later by the Scrum Master step of the build loop. Your job is the epic with
  story headers + acceptance criteria only.
- Operate autonomously; infer from the PRD and record any assumptions inline.
