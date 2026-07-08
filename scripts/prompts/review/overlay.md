## Review Standards

PASS the review when the acceptance criteria are met AND the checkpoint
(`{{CHECKPOINT_CMD}}`) succeeds — even if you would have written the code
differently. Surface at most ONE blocking issue per review pass; let the Fix
step land it before reviewing again.

BLOCK only on:
1. Acceptance criteria not met — any story AC is unsatisfied or not demonstrable.
2. Checkpoint failure — the checkpoint command above does not pass (build or test failure). Run it to confirm.
3. Security issue — an introduced vulnerability, a leaked secret, or unsafe handling of untrusted input.
4. Escaping the project directory — imports, reads, or writes that reach outside the app directory the loop is working in.
5. Violation of the project's conventions — a change that breaks a rule stated in the project's conventions file (`docs/project-conventions.md`, or the shipped stack-agnostic fallback): e.g. a new dependency the story did not call for, or a language/framework the project has not adopted.
6. Real bug or missing error/loading handling that the acceptance criteria imply.

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
