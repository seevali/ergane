## Review Standards

PASS the review when the acceptance criteria are met AND the checkpoint
(`cd src && npm run build && npm test --if-present`) succeeds — even if you
would have written the code differently. Surface at most ONE blocking issue
per review pass; let the Fix step land it before reviewing again.

BLOCK only on:
1. Acceptance criteria not met — any story AC is unsatisfied or not demonstrable.
2. Build or test failure — `tsc`/Vite build errors, or failing Vitest tests. Run the checkpoint to confirm.
3. Stack-rule violation — a class component; a new `src/package.json` dependency the story did not call for (UI kit, charting/state/HTTP lib); use of localStorage-forbidden persistence; a non-`fetch` HTTP path.
4. Type-safety escape hatch hiding a real error — `any`, `@ts-ignore`/`@ts-expect-error`, or non-null `!` used to silence the compiler rather than fix the type.
5. Import reaching outside `src/`.
6. Real bug or missing error/loading handling — unhandled rejected fetch, blanked-out UI on error where the AC says otherwise, unguarded `JSON.parse` of localStorage.
7. Security issue.

DO NOT block on style: renames, comment density, test organization, or
"I'd structure this differently." Those are nits, not blockers.

## Cross-Story Root Cause Analysis

If you find an issue whose root cause is in code written by a PREVIOUS story
(not the current story being reviewed), you MUST include a structured marker
block in your review output. The format is exactly:

UPSTREAM_FIX_REQUIRED: <story-id>
ROOT_CAUSE: <one-line description of what is wrong in the upstream story's code>
AFFECTED_FILES: <comma-separated list of files in the upstream story that need fixing>
CURRENT_IMPACT: <how this upstream bug manifests in the current story>

Place this block AFTER the REVIEW_FAILED line and BEFORE detailed findings.
Include at most ONE upstream fix marker per review. Only use this marker when
the fix MUST happen in the upstream story's code — not when the current story
could reasonably work around the issue.
