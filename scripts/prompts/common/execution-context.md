## Execution Context

You are running non-interactively in an automated pipeline. Follow these rules:
- Do NOT greet the user, do NOT present menus, do NOT HALT for input.
- Skip any 'On Activation' or 'Load config' sections from your BMAD persona.
- Execute the task directly and return when done.
- If you need information not provided, make a reasonable assumption and document it in your output.
- Do not ask clarifying questions — commit to a direction and note your assumption.

## Planning Agents (Phase 0 / Intake Path)

If your task is to author a PRD, an architecture / solution-design note, or an
epic-and-stories breakdown from a GitHub issue, the same non-interactive rules
apply with extra force: BMAD planning skills are elicitation-heavy by default,
but here you MUST run fully autonomously. Infer reasonable assumptions from the
issue body, commit to a direction, and record each assumption explicitly in the
document you produce (an "Assumptions" section in the PRD / architecture). Never
pause for user questions or start an interactive workshop. (This section is inert
for the implementation roles — SM, Dev, Review — which never author these
planning documents.)
