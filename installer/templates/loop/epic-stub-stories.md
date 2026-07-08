# Project Epic: <!-- Replace with your epic title -->

<!-- TEACHING COMMENT: This file defines your project's stories. -->
<!-- Ergane's SM agent reads it to produce individual story spec files. -->
<!-- Stories MUST follow the "### Story X.Y: Title" format — the loop parses this exactly. -->
<!-- Each story should: -->
<!--   - Be small and independently demonstrable. -->
<!--   - Leave `{{CHECKPOINT_COMMAND}}` green after implementation. -->
<!--   - Have observable Acceptance Criteria: "renders X", "calls endpoint Z". -->

> **App directory:** `{{APP_DIR}}/`
> **Checkpoint command:** `{{CHECKPOINT_COMMAND}}`
> **Stack:** {{STACK_DESCRIPTION}}

## Overview

<!-- 1-2 paragraphs describing the epic's goal and how stories build on each other. -->
<!-- Reference the PRD (prd.md) and cite FR-N IDs to keep traceability. -->

## Stories

### Story 1.1: Initial setup and application shell

As a user,
I want [goal],
So that [benefit].

Implements [FR-1, FR-2]. <!-- Update FR references to match your PRD. -->

**Acceptance Criteria:**
- [ ] [Observable behavior: "Given the app loads, the user sees X."]
- [ ] [Observable behavior: "When the user does Y, Z appears."]
- [ ] `{{CHECKPOINT_COMMAND}}` passes.

<!-- TEACHING COMMENT: Each story below builds on the previous one. -->
<!-- Keep stories small — one capability per story is the right size. -->

### Story 1.2: Core feature implementation

As a user,
I want [next goal],
So that [next benefit].

Implements [FR-3].

**Acceptance Criteria:**
- [ ] [Observable behavior]
- [ ] [Observable behavior]
- [ ] `{{CHECKPOINT_COMMAND}}` passes.

### Story 1.3: <!-- Add more stories as needed -->

As a user,
I want [goal],
So that [benefit].

Implements [FR-N].

**Acceptance Criteria:**
- [ ] [Observable behavior]
- [ ] `{{CHECKPOINT_COMMAND}}` passes.
