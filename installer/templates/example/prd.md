---
title: Exchange Rates Dashboard
status: draft
created: 2026-05-24
updated: 2026-05-24
---

# PRD: Exchange Rates Dashboard
*Working title — confirm.*

> **Authoring note.** Produced by the BMAD Product Manager agent (`bmad-agent-pm` → `bmad-prd`) in headless "create" mode as the seed artifact for the Ralph Loop demo. Scope is deliberately tight: this is a demo whose point is to exercise the SM → Dev → Review → Fix loop, not to ship a product. Assumptions made without a human in the loop are tagged `[ASSUMPTION]` inline and indexed in §8.

## 0. Document Purpose

This PRD is for the BMAD downstream workflows in this repo — `bmad-create-epics-and-stories` (which turns it into the epic + story list) and, during the loop, `bmad-create-story` (Scrum Master) and `bmad-dev-story` (Developer). It is structured Glossary-first: features are grouped, Functional Requirements (FRs) are nested and globally numbered so stories can cite stable IDs. There is no prior UX or architecture doc; this PRD is the single upstream input. The implementation target is the React + Vite + TypeScript app under `src/`, built one story at a time.

## 1. Vision

A single-screen web dashboard that lets a user watch a handful of foreign-exchange rates without signing in, configuring anything, or paying for data. The user picks two or three currency pairs they care about, sees the current rate for each, refreshes on demand, and glances at a small chart showing where each rate has been over the last month.

It matters because most FX tools are either heavyweight trading platforms or ad-laden converter pages. This is the opposite: a calm, read-only "rates I watch" panel that loads instantly, remembers the pairs you picked, and asks nothing of you. For this repo specifically, it is the smallest real app that still touches the things a build loop should prove it can handle — async data fetching, list/selection state, derived UI, error/loading states, and a non-trivial visual (the chart).

## 2. Target User

### 2.1 Primary Persona

**Sam, a remote contractor paid in a currency that isn't their home currency.** Sam invoices in USD but spends in EUR and GBP, and occasionally moves money. They are not a trader; they just want a quick read on whether rates moved meaningfully this month before deciding to transfer. They open the dashboard a few times a week on a laptop.

### 2.2 Jobs To Be Done

- When I open the app, I want to immediately see the current rate for the pairs I care about, so I don't re-pick them every time.
- When I suspect a rate moved, I want to refresh on demand and see the new number with a timestamp, so I trust it's current.
- When I'm deciding whether to act, I want to see the last ~30 days as a simple line, so I can tell "trend" from "noise" at a glance.

### 2.3 Non-Users (v1)

- Active traders needing real-time tick data, order books, or sub-day granularity.
- Users needing currencies outside the European Central Bank reference set (see Glossary — **Supported currency**).

### 2.4 Key User Journeys

- **UJ-1. Sam sets up their watchlist once.** Sam opens the app for the first time (no auth, nothing stored). The dashboard shows an empty watchlist and a pair picker listing the available pairs. Sam adds USD/EUR and USD/GBP. The two pairs appear as cards with current rates. Sam closes the tab. **Resolution:** the chosen pairs are saved to `localStorage`.

- **UJ-2. Sam returns and refreshes.** Sam reopens the app the next day. Their two pairs load from `localStorage` and the app fetches current rates automatically on mount. Sam clicks **Refresh**; each card re-fetches and updates its rate and "last updated" time. **Edge case:** if a fetch fails, the card shows an inline error and a retry affordance without wiping the previously shown rate.

- **UJ-3. Sam reads the trend.** On each pair card, Sam sees a small line chart of the last ~30 days of daily rates. The line makes the recent direction obvious without Sam reading any numbers. Realizes the "trend vs noise" job.

## 3. Glossary

*Downstream workflows and stories must use these terms exactly.*

- **Currency** — An ISO 4217 three-letter code (e.g. `USD`, `EUR`, `GBP`, `JPY`, `AUD`). Cardinality: many.
- **Supported currency** — A Currency available from the Rates API (the European Central Bank reference set exposed by Frankfurter). The app only offers Supported currencies.
- **Currency pair** — An ordered (base, quote) tuple of two distinct Supported currencies, written `BASE/QUOTE` (e.g. `USD/EUR`). Its **rate** is the amount of quote currency per 1 unit of base currency.
- **Rate** — A positive decimal: units of quote per 1 unit of base for a Currency pair at a point in time.
- **Available pairs** — The fixed, app-defined list of Currency pairs the user may choose from (see FR-1). 3–5 pairs in v1.
- **Watchlist** — The ordered set of Currency pairs the user has added. Persisted to `localStorage`. May be empty.
- **Pair card** — The UI element rendering one watched Currency pair: its current Rate, last-updated time, refresh/remove controls, and its Rate history chart.
- **Rate history** — A series of (date, Rate) points for one Currency pair over a date range (v1: ~last 30 days, daily).
- **Rates API** — The public, keyless HTTP API providing latest and historical Rates: **Frankfurter**, canonical base `https://api.frankfurter.dev/v1`. Latest: `/v1/latest?base=BASE&symbols=QUOTE`. History: `/v1/<start>..<end>?base=BASE&symbols=QUOTE`. See §8 assumption A1.

## 4. Features

### 4.1 Available Pairs & Watchlist Selection

**Description:** The app ships with a fixed list of **Available pairs**. The user builds a **Watchlist** by adding pairs from that list and removing them. The Watchlist persists across reloads via `localStorage`. Realizes UJ-1. Uses Glossary terms exactly.

**Functional Requirements:**

#### FR-1: Fixed list of Available pairs

The app defines a constant list of 3–5 **Available pairs** drawn only from **Supported currencies**. Realizes UJ-1.

**Consequences (testable):**
- The app renders a pair picker listing exactly the Available pairs: `USD/EUR`, `USD/GBP`, `USD/JPY`, `EUR/GBP`, `AUD/USD`. `[ASSUMPTION A2]`
- Each Available pair uses two distinct Supported currencies.

#### FR-2: Add a pair to the Watchlist

A user can add an Available pair to the **Watchlist**. Realizes UJ-1.

**Consequences (testable):**
- Selecting an Available pair not already in the Watchlist adds it; a **Pair card** for it appears.
- A pair already in the Watchlist cannot be added twice (the picker disables or hides it).

#### FR-3: Remove a pair from the Watchlist

A user can remove a pair from the **Watchlist**. Realizes UJ-1.

**Consequences (testable):**
- Removing a pair removes its **Pair card** and returns it to the picker as selectable.

#### FR-4: Persist the Watchlist

The **Watchlist** persists to `localStorage` and rehydrates on load. Realizes UJ-1, UJ-2.

**Consequences (testable):**
- After adding pairs and reloading, the same pairs render in the same order.
- A missing or malformed `localStorage` value yields an empty Watchlist without throwing.

### 4.2 Current Rate Display & On-Demand Refresh

**Description:** For each pair in the Watchlist, the app fetches the current **Rate** from the **Rates API** and shows it with a last-updated timestamp. The user can refresh all cards on demand. Loading and error states are explicit. Realizes UJ-2.

**Functional Requirements:**

#### FR-5: Fetch current rate per watched pair

On mount and on refresh, the app fetches the current **Rate** for each watched pair from the **Rates API** using native `fetch`. Realizes UJ-2.

**Consequences (testable):**
- For pair `BASE/QUOTE`, the app requests the latest rate of QUOTE per BASE and displays the numeric Rate on the Pair card.
- While a fetch is in flight, the Pair card shows a loading indicator.

#### FR-6: On-demand refresh

A **Refresh** control re-fetches current Rates for all watched pairs. Realizes UJ-2.

**Consequences (testable):**
- Clicking Refresh triggers a fetch for each Pair card and updates each displayed Rate.
- Each Pair card shows a human-readable "last updated" time reflecting its most recent successful fetch.

#### FR-7: Per-card error handling

A failed fetch surfaces an inline error on the affected Pair card with a retry affordance, without discarding a previously shown Rate. Realizes UJ-2 (edge case).

**Consequences (testable):**
- When a fetch rejects or returns non-OK, the Pair card shows an error message and a retry control.
- A previously displayed Rate remains visible (not blanked) when a subsequent refresh fails.

### 4.3 Rate History Chart

**Description:** Each **Pair card** renders a small line chart of the pair's **Rate history** over the last ~30 days, drawn as an inline SVG with no charting library. Realizes UJ-3.

**Functional Requirements:**

#### FR-8: Fetch rate history per watched pair

The app fetches ~30 days of daily **Rate history** for each watched pair from the **Rates API** time-series endpoint. Realizes UJ-3.

**Consequences (testable):**
- For pair `BASE/QUOTE`, the app requests a date-range series of QUOTE per BASE covering ~30 days ending today.
- An empty or failed history response leaves the card's rate display intact and shows a chart-specific empty/error state.

#### FR-9: Render a simple line chart

The app renders **Rate history** as an inline SVG line chart on the Pair card — no third-party charting dependency. Realizes UJ-3.

**Consequences (testable):**
- Given a non-empty Rate history, the card renders an `<svg>` containing a polyline/path with one vertex per data point.
- The chart scales its y-axis to the min/max of the series so the line uses the available height.

**Feature-specific NFRs:**
- The chart is presentational only (no interaction required in v1); accessibility minimum is a text label / `aria-label` describing the pair and range.

## 5. Non-Goals (Explicit)

- No user accounts, login, or any authentication. The app is fully anonymous.
- No backend, server, or database. The only persistence is `localStorage`.
- No real-time/streaming rates, no sub-day granularity, no trading or transfer actions.
- No currency conversion calculator (amount in → amount out). v1 displays rates only. `[NON-GOAL for MVP — candidate v2]`
- No arbitrary user-defined pairs; the pair set is fixed (FR-1).
- No multi-currency base switching beyond the fixed Available pairs.

## 6. MVP Scope

### 6.1 In Scope

- Fixed Available pairs (FR-1); add/remove/persist Watchlist (FR-2–FR-4).
- Current Rate fetch, on-demand refresh, last-updated time, loading + error states (FR-5–FR-7).
- ~30-day Rate history fetched and rendered as an inline SVG chart per card (FR-8–FR-9).

### 6.2 Out of Scope for MVP

- Conversion calculator — deferred to v2; the rate display is the core demo value.
- Configurable history window / interval selectors — v1 is a fixed ~30-day daily window.
- Sorting/reordering the Watchlist beyond add order.
- Theming / dark mode — not load-bearing for the demo. `[NOTE FOR PM]`

## 7. Success Metrics

Stakes are "demo / hobby," so metrics are light.

**Primary**
- **SM-1**: The full Watchlist → refresh → chart flow works end-to-end against the live Rates API with no API key. Validates FR-1 through FR-9.

**Secondary**
- **SM-2**: `cd src && npm run build && npm test` passes after each story (the loop checkpoint). Validates FR-4, FR-7 (the states most likely to regress).

**Counter-metrics (do not optimize)**
- **SM-C1**: Number of dependencies added to `src/package.json`. Should stay near zero — adding a charting or HTTP library to hit SM-1 faster defeats the "lean stack" point of the demo. Counterbalances SM-1.

## 8. Open Questions & Assumptions

**Assumptions (inferred without confirmation):**
- **A1 — Rates API = Frankfurter, canonical base `https://api.frankfurter.dev/v1`.** Chosen over the brief's example `exchangerate.host` because Frankfurter is genuinely keyless (no `access_key`), CORS-enabled for browser use, and exposes a native time-series endpoint (`/v1/<start>..<end>?base=BASE&symbols=QUOTE`) needed for FR-8. exchangerate.host now requires an API key, which would violate the "no auth, public APIs only" constraint. Verified live on 2026-05-24: `/v1/latest?base=USD&symbols=EUR,GBP` and `/v1/<start>..<end>?base=USD&symbols=EUR` both return JSON without a key. (The older `https://api.frankfurter.app/...` host still works but 301-redirects to `api.frankfurter.dev/v1`; use the canonical base to avoid the redirect.) If Frankfurter is unavailable, any keyless equivalent with latest + time-series endpoints satisfies the FRs.
- **A2 — Available pairs.** `USD/EUR`, `USD/GBP`, `USD/JPY`, `EUR/GBP`, `AUD/USD` — five ECB-supported pairs spanning the personas's likely interest. The exact set is not load-bearing; any 3–5 Supported pairs satisfy FR-1.
- **A3 — History window.** "~30 days, daily" is the v1 default; Frankfurter returns business-day data (weekends omitted), which is acceptable for a trend glance.
- **A4 — Chart approach.** Inline SVG, no charting library, to honor the repo's lean-stack rule (no UI/charting deps). A story may still propose a library, but the default is dependency-free.

**Open Questions (future tickets, not silent gaps):**
1. Should an empty Watchlist show a suggested default pair (e.g. USD/EUR) or stay empty until the user picks? v1 assumption: stay empty (UJ-1).
2. Should refresh be throttled to respect API politeness? Not enforced in v1; revisit if rate-limited.
