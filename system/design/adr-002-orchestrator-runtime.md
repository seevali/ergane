# ADR-002 — Orchestrator runtime: stay Bash + a typed reconciler; Sandcastle is plumbing, not substrate

**Status:** Accepted (2026-06-25).
**Scope:** the language/runtime of the Ralph Loop orchestrator (`scripts/ralph-loop.sh`) as a whole — distinct from ADR-001 (the round-trip chapter's "GitHub as shared mutable state").
**Companions:** `issue-native-bmad-loop.md` §8 (the Bash-orchestrates / typed-reconciler split this ADR ratifies at whole-orchestrator scope) and `../chapters/2026-06-25-github-issue-roundtrip/adr-001-github-as-shared-mutable-state.md` (whose "graduation tripwire" this ADR interprets).

> **Cold-start note.** "The orchestrator" is `scripts/ralph-loop.sh` — a ~2256-line Bash script (`set -euo pipefail`) that autonomously builds software one *story* at a time, each step a fresh `claude -p` CLI process (the "Ralph pattern": clean context per step, state reloaded from the file system; completion proven by `git log` grep for `feat(<id>):`). It carries mature, hard-won machinery: multi-model routing, retry+escalation, smart-salvage, upstream-fix cascade, auto-heal review injection, budget caps, and parking. "Prompt-cache discipline" = keeping system prompts byte-identical across `claude -p` calls so Anthropic's prompt cache hits — the single biggest cost lever. "Sandcastle" is `github.com/mattpocock/sandcastle`, a TypeScript library for orchestrating sandboxed AI coding agents (git worktrees, branch strategies, session capture + `.fork()`, completion signals, multi-provider, Docker/Podman/Firecracker sandboxes). The repo is BOTH a public showcase of "the Ralph Loop pattern" AND the maintainer's real product (the System Track).

---

## Decision

The Ralph Loop orchestrator **stays in Bash**. The hard, stateful logic graduates to **typed (TypeScript/Node) modules under `tools/`, strangler-fig style, one bounded subsystem at a time** — starting with the manifest/reconciler (`tools/reconcile.ts`, per design §8). We will **not** do a big-bang rewrite, and we will **not** adopt Sandcastle as the orchestration substrate. Sandcastle may later be adopted for **concurrency/sandbox plumbing only** (never the loop's "heart"), and its *design* may be mined now.

## Options considered

- **(a) Stay: Bash orchestrator + typed reconciler (CHOSEN).** The current plan. Battle-tested machinery and cache discipline are preserved; the typed core grows only where pain or capability forces it.
- **(b) Hand-rolled TS rewrite.** Reimplement the orchestrator in TypeScript. Rejected now: maximum risk, zero new user capability, re-derives ~1900 lines of scar tissue, and freezes the Issue-Native roadmap (#1–#12). Reserved as the *form* a future graduation would take (leaf-first, never big-bang).
- **(c) Adopt Sandcastle as the engine.** Rejected: a philosophical mismatch (its session-capture + `.fork()` model fights Ralph's clean-context-per-step), it endangers prompt-cache byte-stability through its templating layer, it adds multi-provider/sandbox surface area we don't use, and it dilutes the showcase thesis ("you don't need a framework"). Useful narrowly — see "plumbing, not substrate."

## Why (the reasoning)

1. **Language does not move the user outcome.** The job is "autonomously turn a backlog into shipped software, cheaply and reliably, while I sleep." That value lives in prompt discipline, the retry/salvage/cascade machinery, and cost control — none of which are language features. Bash-vs-TS is a *maintainer-ergonomics* question, not a user-value one; it must not be smuggled in as a user win.
2. **The graduation tripwire (ADR-001) has not fired on the orchestrator.** Its conditions — idempotency logic > ~300 lines of bash, `gh` error branches outnumbering feature branches, true cross-worktree concurrency — all target **the reconciler slice already being carved into `tools/`**, not the loop kernel. Rewriting the whole orchestrator now reaches *past* the tripwire.
3. **A rewrite re-derives judgment, not just code.** ~1900 of the 2256 lines are scar tissue — each branch a lesson learned in production (smart-salvage's exact decision boundary, cascade fan-out correctness, `claude -p` exit-code/JSON state discrimination, `--resume` session identity). A port silently reintroduces fixed bugs into the one tool trusted to run unattended overnight.
4. **The decisive evidence: the current roadmap is serial.** Design §5 explicitly defers the Swarm's true concurrency to **v2** ("v1 ships serial multi-issue … true parallel execution is a separately-justified v2 bet"). Concurrency is the one place Bash genuinely runs out of road — and it is not required by #1–#12. So no trigger is present today.
5. **The showcase favors Bash.** "The Ralph Loop pattern" teaches best as a shell loop + fresh context — "no framework needed." Wrapping it in Sandcastle undercuts that thesis and moves the lesson into a dependency.

## The trigger that flips this decision

Graduate the loop kernel to TypeScript (leaf-first, reconciler-pattern as the template) when **either** holds, *with evidence in a log*:

- **Concurrency becomes P0** — true parallel multi-story execution across isolated worktrees that Bash cannot coordinate without race-prone temp files/lockfiles (the v2 Swarm). At that point, **adopt Sandcastle for the concurrency/sandbox plumbing** (a capability acquisition), keeping the loop's decision logic in owned source.
- **The self-modification hazard becomes concrete** — the loop, building loop-features, is observed corrupting its own live run because Bash is editing the file it is executing.

Softer signals (idempotency-bash-bloat, `gh`-error-branch count) inform the reconciler's growth but do **not**, alone, justify converting the orchestrator.

## Non-negotiables (carried regardless of path)

1. **Prompt-cache byte-stability is sacred.** The single biggest regression risk in any migration is *silent* cache-key drift (a template literal, a key-reordering serializer, a prettier pass, `\r\n` from a Windows checkout, or a library preamble) — build green, tests green, the bill goes up. **Make the `--dry-run-prompts` byte-diff a CI gate on every prompt-adjacent change**, and the first gate any future TS prompt-emitter must pass.
2. **The loop's "heart" stays readable and owned.** The ~80 lines that *are* the loop — read context → call agent → judge progress → continue-or-stop — must live in source a 2am operator can open and a learner can read in one sitting. Never inside a dependency's internals or a transpiled artifact.
3. **Clone-and-run in one move.** Part of the pattern's value is `./ralph-loop.sh` and it goes. Any future TS form must ship a real CLI (`npx`/a binary) so "clone and watch it loop" survives — no install moat around the lesson.
4. **Migration, if ever, is strangler-fig.** Lift one bounded subsystem at a time behind the same shell interface, each with a parity gate (byte-diff for prompts; replay real Ralph logs for decision predicates — identical decisions on every historical step).

## Consequences

- **Positive:** the Issue-Native roadmap ships on a substrate that works; battle-tested machinery and cache discipline are preserved; the showcase keeps its thesis; the door to TS stays open without a flag day.
- **Accepted cost:** the Bash artifact has already outgrown "readable in one sitting" (2256 lines), and the manifest/concurrency pain is real and will grow. Mitigation (separable, worth banking regardless): extract the loop's ~80-line heart into one read-it-in-one-sitting core — a *legibility* refactor, not a language port.
- **Watch:** when v2 concurrency lands on the agenda, re-open this ADR — that is the moment to evaluate Sandcastle-as-plumbing with a concrete value case rather than a refactoring urge.

## Provenance

Distilled from a BMAD party-mode roundtable on 2026-06-25 (Winston/architect, Amelia/dev, John/PM, Sally/UX). Architect, dev, and PM converged on "stay + strangler-fig, concurrency as the trigger"; UX added the separable legibility win (split the one-page idea from the thousand-line operation) and the "heart stays owned, plumbing may be borrowed" line.
