# Project PRD

<!-- TEACHING COMMENT: This is your project PRD (Product Requirements Document). -->
<!-- The Ralph Loop's Scrum Master (SM) agent reads this file to write story specs. -->
<!-- Replace the placeholder sections below with your project's specifics. -->
<!-- Keep Acceptance Criteria observable from outside the code — "renders X", "calls endpoint Z". -->

> **App directory:** `{{APP_DIR}}/`
> **Checkpoint command:** `{{CHECKPOINT_COMMAND}}`
> **Stack:** {{STACK_DESCRIPTION}}

## 1. Vision

<!-- 1-2 paragraphs: what your app does, who uses it, and why it matters. -->
<!-- Be concrete — what workflow does it enable? What problem does it solve? -->

My project does...

## 2. Target User

### 2.1 Primary Persona

<!-- Name your user and describe their situation. -->
<!-- Example: "Sam, a contractor who invoices in USD but spends in EUR." -->

### 2.2 Jobs To Be Done

<!-- 2-4 bullet points in the format: -->
<!-- "When [situation], I want [action], so that [outcome]." -->

## 3. Glossary

<!-- Define project-specific terms here. -->
<!-- The SM and Dev agents will use these terms exactly in stories — define them clearly. -->
<!-- Example: "Watchlist — The ordered set of items the user has saved. Persisted to localStorage." -->

## 4. Features

<!-- Group related features into sections. -->
<!-- Use Functional Requirements (FR-N) so stories can cite stable IDs (e.g., "Implements FR-3"). -->

### Feature 1: <!-- Replace with a feature name -->

#### FR-1: <!-- Replace with a requirement name -->

<!-- Observable behavior the SM agent can verify: -->
**Consequences (testable):**
- <!-- "The app renders X when Y" -->
- <!-- "Clicking Z triggers W" -->

#### FR-2: <!-- Add more functional requirements as needed -->

**Consequences (testable):**
- <!-- ... -->

### Feature 2: <!-- Add more features as needed -->

#### FR-3: <!-- ... -->

**Consequences (testable):**
- <!-- ... -->

## 5. Non-Goals (Explicit)

<!-- List what v1 deliberately does NOT build. Clear non-goals prevent scope creep. -->
- <!-- Example: "No user accounts or authentication." -->

## 6. MVP Scope

### 6.1 In Scope

- <!-- FR-1, FR-2, FR-3 — replace with your actual FR list -->

### 6.2 Out of Scope for MVP

- <!-- Features deferred to v2 -->

## 7. Open Questions & Assumptions

<!-- List any decisions made without confirmation, so the SM/Dev agents know what's assumed. -->
- <!-- Example: "A1 — API endpoint: https://api.example.com — keyless, CORS-enabled." -->
