---
stepsCompleted: ["step-01", "step-02", "step-03", "step-04"]
inputDocuments: ["docs/prd.md"]
---

# Exchange Rates Dashboard - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for the **Exchange Rates Dashboard**, decomposing the requirements from [the PRD](../prd.md) into implementable stories for the Ralph Loop.

It is the input the Scrum Master step (`bmad-create-story`) expands into per-story spec files in `docs/stories/` during a loop run, and that the Developer step (`bmad-dev-story`) then implements. Stories are deliberately small and incremental: each one builds on the previous, is independently demonstrable, and leaves `cd src && npm run build && npm test` green. Acceptance criteria are written to be observable from outside the code (renders X, responds to click Y, calls endpoint Z) per the repo's `CLAUDE.md` Scrum Master rules.

> **Cold-start note.** Terms in **bold** (Available pairs, Watchlist, Pair card, Rate, Rate history, Rates API) are defined in the PRD §3 Glossary. The **Rates API** is Frankfurter, canonical base `https://api.frankfurter.dev/v1`, keyless. Latest: `/v1/latest?base=BASE&symbols=QUOTE`. History: `/v1/<start>..<end>?base=BASE&symbols=QUOTE`. Stack rules (React 19 + Vite + TS strict, Vitest + RTL, native `fetch`, `localStorage` only, no UI/charting/state/HTTP libraries) live in the repo `CLAUDE.md`.

## Requirements Inventory

### Functional Requirements

From PRD §4 (IDs are stable; stories cite them):

- **FR-1** — Fixed list of 3–5 **Available pairs** drawn from Supported currencies (`USD/EUR`, `USD/GBP`, `USD/JPY`, `EUR/GBP`, `AUD/USD`).
- **FR-2** — Add an Available pair to the **Watchlist** (no duplicates).
- **FR-3** — Remove a pair from the **Watchlist**.
- **FR-4** — Persist the Watchlist to `localStorage`; rehydrate on load; tolerate missing/malformed values.
- **FR-5** — Fetch the current **Rate** per watched pair on mount via native `fetch`; show a loading state while in flight.
- **FR-6** — On-demand **Refresh** re-fetches all cards; each card shows a "last updated" time.
- **FR-7** — Per-card error handling with retry; a previously shown Rate is not blanked on a failed refresh.
- **FR-8** — Fetch ~30-day daily **Rate history** per watched pair from the time-series endpoint.
- **FR-9** — Render Rate history as an inline SVG line chart (no charting dependency).

### NonFunctional Requirements

Cross-cutting, enforced every story (from PRD §7 SM-C1 + repo `CLAUDE.md`):

- **NFR-1 (lean stack)** — No new runtime dependency in `src/package.json` beyond `react`/`react-dom` unless a story explicitly justifies it. No UI, charting, state, or HTTP library.
- **NFR-2 (idioms)** — Function components + hooks only (no class components); TypeScript `strict`; `useReducer` only where it genuinely helps.
- **NFR-3 (checkpoint)** — Tests colocated as `Component.test.tsx`; `cd src && npm run build && npm test` passes at the end of every story.
- **NFR-4 (a11y)** — The chart carries an `aria-label` describing the pair and date range.

### Additional Requirements

- All network calls target the keyless **Rates API**; no API key, no auth, no backend, no persistence beyond `localStorage`.

### UX Design Requirements

None — no separate UX doc exists. UI shape is described inline in each story; plain CSS / CSS Modules only.

### FR Coverage Map

| FR | Covered by story |
|----|------------------|
| FR-1 | 1.1 |
| FR-2 | 1.1 |
| FR-3 | 1.1 |
| FR-4 | 1.2 |
| FR-5 | 1.3 |
| FR-6 | 1.4 |
| FR-7 | 1.5 |
| FR-8 | 1.6 |
| FR-9 | 1.6 |

## Epic List

- **Epic 1: Exchange Rates Dashboard MVP** — Deliver the full read-only dashboard: pick currency pairs from a fixed list, persist the watchlist, see current rates with on-demand refresh and explicit loading/error states, and view a 30-day inline chart per pair. Standalone end-to-end user value; no future epic required for it to function.

## Epic 1: Exchange Rates Dashboard MVP

Build the Exchange Rates Dashboard end to end, one capability per story. Story 1.1 stands up the shell and pair selection; each subsequent story layers one capability (persistence → live rates → refresh → error resilience → chart) without refactoring prior work.

### Story 1.1: App shell, Available pairs, and Watchlist selection

As Sam, a remote contractor watching a few FX rates,
I want to pick currency pairs from a fixed list and see them as cards,
So that I can assemble the set of rates I care about.

Implements **FR-1, FR-2, FR-3**. Watchlist is in-memory only in this story (persistence is 1.2). No network calls yet — cards show the pair label only.

**Acceptance Criteria:**

**Given** the app has loaded,
**When** the dashboard renders,
**Then** a pair picker offers exactly these **Available pairs**: `USD/EUR`, `USD/GBP`, `USD/JPY`, `EUR/GBP`, `AUD/USD`,
**And** an empty **Watchlist** renders no **Pair cards**.

**Given** an Available pair that is not yet in the Watchlist,
**When** the user adds it from the picker,
**Then** a Pair card labelled `BASE/QUOTE` appears,
**And** that pair can no longer be added again (the picker hides or disables it).

**Given** a pair already in the Watchlist,
**When** the user removes it from its Pair card,
**Then** the card disappears,
**And** the pair becomes selectable in the picker again.

### Story 1.2: Persist the Watchlist to localStorage

As Sam,
I want my chosen pairs remembered between visits,
So that I don't re-pick them every time I open the app.

Implements **FR-4**. Builds directly on the 1.1 Watchlist state.

**Acceptance Criteria:**

**Given** a Watchlist with one or more pairs,
**When** the page is reloaded,
**Then** the same pairs render as Pair cards in the same order.

**Given** no prior saved Watchlist (key absent),
**When** the app loads,
**Then** the Watchlist is empty and no error is thrown.

**Given** a malformed value stored under the Watchlist `localStorage` key,
**When** the app loads,
**Then** it falls back to an empty Watchlist without throwing,
**And** subsequent add/remove still persists correctly.

### Story 1.3: Fetch and display the current rate per pair

As Sam,
I want each card to show the current rate for its pair,
So that I can read today's number at a glance.

Implements **FR-5**. Introduce a small rates client module (`src/api/rates.ts` or similar) using native `fetch` against the **Rates API** latest endpoint. No new dependency (NFR-1).

**Acceptance Criteria:**

**Given** a Watchlist containing `USD/EUR`,
**When** the app mounts,
**Then** it issues a `fetch` to `https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR`,
**And** the Pair card displays the returned numeric **Rate** (quote per 1 base).

**Given** a rate fetch is in flight for a card,
**When** the card renders before the response resolves,
**Then** the card shows a loading indicator instead of a rate.

**Given** the rates client (tested in isolation with a mocked `fetch`),
**When** it parses a successful Frankfurter `latest` response,
**Then** it returns the rate for the requested quote currency as a number.

### Story 1.4: On-demand refresh with last-updated time

As Sam,
I want a refresh button and a timestamp on each card,
So that I can pull fresh rates and trust how current they are.

Implements **FR-6**. Builds on 1.3's rates client.

**Acceptance Criteria:**

**Given** a Watchlist with at least one pair showing a rate,
**When** the user clicks the **Refresh** control,
**Then** each Pair card re-issues its current-rate `fetch`,
**And** each card updates its displayed **Rate** from the new response.

**Given** a card has completed a successful fetch,
**When** it renders,
**Then** it shows a human-readable "last updated" time reflecting that fetch.

### Story 1.5: Per-card error handling and retry

As Sam,
I want a clear error and a retry when a rate fails to load,
So that a network blip doesn't wipe out or freeze my dashboard.

Implements **FR-7**. Builds on 1.3/1.4.

**Acceptance Criteria:**

**Given** the current-rate fetch rejects or returns a non-OK response for a card,
**When** the card renders,
**Then** it shows an inline error message and a retry control,
**And** clicking retry re-issues the fetch for that card only.

**Given** a card is already showing a rate from an earlier successful fetch,
**When** a subsequent refresh fails for that card,
**Then** the previously shown Rate remains visible (it is not blanked),
**And** the error is surfaced alongside it.

### Story 1.6: Rate history fetch and inline SVG chart

As Sam,
I want a small 30-day line chart on each card,
So that I can tell trend from noise without reading numbers.

Implements **FR-8, FR-9**. Extend the rates client with a time-series call; render an inline SVG line chart — no charting library (NFR-1).

**Acceptance Criteria:**

**Given** a Watchlist containing `USD/EUR`,
**When** the app loads the card,
**Then** it issues a `fetch` to `https://api.frankfurter.dev/v1/<start>..<end>?base=USD&symbols=EUR` for a ~30-day window ending today,
**And** the rates client returns an ordered array of `{ date, rate }` points.

**Given** a non-empty **Rate history** for a card,
**When** the chart renders,
**Then** the card contains an `<svg>` with a `polyline` or `path` having one vertex per history point,
**And** the chart's y-extent is scaled to the series min/max so the line uses the available height,
**And** the `<svg>` has an `aria-label` naming the pair and date range (NFR-4).

**Given** an empty or failed history response,
**When** the card renders,
**Then** the current-rate display remains intact,
**And** the chart area shows a chart-specific empty/error state (not a crash).
