# Plan: Modularize Loop Prompts & Live-Load BMAD Personas

**Chapter:** `2026-05-24-modularize-loop-prompts`
**Date:** 2026-05-24
**Status:** complete
**Author:** Seevali Rathnayake (with Claude Opus 4.7 as plan agent)
**Target file:** [scripts/ralph-loop.sh](../../../scripts/ralph-loop.sh)
**PRD:** [prd.md](prd.md)
**Epic:** [epics/modularize-loop-prompts.md](epics/modularize-loop-prompts.md)

---

## Cold-start context (read first if you're new here)

This plan refactors the bash orchestrator script that drives the Ralph Loop demo. A few terms you need to know before the rest of the plan makes sense:

- **Ralph Loop** — a build pattern where each step of work (plan a story, implement it, review it, fix it) runs in a *fresh* Claude Code session. Clean context per step is the point. See the repo [README](../../../README.md) for the full overview.
- **BMAD Method** — a set of role-based AI agents (Analyst, PM, Scrum Master, Dev, Code Reviewer) from [bmad-code-org/BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD). Installed in this repo via `npx bmad-method install` (creates `_bmad/` and `.claude/skills/`, both gitignored). This repo runs **BMAD v6.7+**.
- **BMAD skills used by the loop:**
  - `bmad-create-story` → SM (Scrum Master) role
  - `bmad-dev-story` → Dev role
  - `bmad-code-review` → Reviewer role
- **Prompt cache** — Anthropic's prompt cache reduces cost on repeated context across `claude` invocations within a few minutes. Cache hits require the system prompt to be **byte-identical** across invocations.
- **`--append-system-prompt`** — the Claude Code CLI flag that injects a string into the system prompt of an invocation. The Ralph script uses this to inject per-role agent personas. It is what makes the prompt cache pick up the repeated context.
- **Chapter** — a self-contained improvement effort under [`system/chapters/`](../). Each chapter has its own plan (this file), PRD, epic(s), and stories. The System Track wrapper [`system/ralph-loop-system.sh`](../../ralph-loop-system.sh) runs the canonical loop against a chapter.

---

## Problem

[scripts/ralph-loop.sh](../../../scripts/ralph-loop.sh) has ~110 lines of agent personas and execution-context instructions baked in as heredocs:

- The `common` execution-context block (lines ~371–402) — encodes "do not greet, skip On Activation, do not HALT, do not ask" rules that override BMAD personas' interactive instructions.
- SM/Dev/Review wrapper blocks (lines ~404–448) — combine the common block with per-role persona stubs.
- Review Standards + Upstream Fix rules (lines ~454–487) — review pass/block criteria and the `UPSTREAM_FIX_REQUIRED` escalation contract.

This causes two problems:

1. **Maintenance burden.** Changes to persona behavior require editing a 1200-line bash script.
2. **Stale personas.** When BMAD ships updated personas (new versions, behavior tweaks), the loop ignores them. The author must manually port persona changes into the script — defeating the purpose of installing BMAD at all.

The explicit goal: *"make sure we load the BMAD Agent personas freshly from the file system rather than hard-coding them in the script making sure the loop supports future BMAD method updates without needing to touch the loop file."*

---

## Critical findings from inspecting the BMAD installs

Both BMAD installs in this monorepo were inspected (the demo's v6.7+ install at `.claude/skills/` and the parent Metis root's v6.2.2 install at `/home/seevali/projects/Metis/_bmad/`). Two facts shape the design:

1. **BMAD persona files are not clean drop-ins for `--append-system-prompt`.** They contain YAML frontmatter, `{communication_language}` template variables, `python3 _bmad/scripts/resolve_customization.py` invocations, and explicit "Greet the User" / "HALT and wait" instructions. These directly conflict with the loop's non-interactive contract. The current `common` block exists *specifically* to neutralize these — that override is load-bearing and cannot be removed.
2. **BMAD file layout drifts between versions.** Metis root v6.2.2 has `SKILL.md → workflow.md` (3-line shim + separate workflow file). Demo v6.7+ has the full content inside `SKILL.md` (429/485/90 lines for SM/Dev/Review respectively) plus a `steps/` subdir for code-review only. Same skill names, different file shapes. A loader that only reads `SKILL.md` would silently lose content on one of the two versions.

---

## Recommended path: hybrid 3-layer composition

Two simpler paths were rejected:

- **Load BMAD persona files directly as the system prompt.** Infeasible — finding (1) above. BMAD personas would inject "HALT and wait" rules that break the non-interactive loop.
- **Maintain repo-local prompt MD files, ignore BMAD personas.** Throws away the explicit "future BMAD updates flow in" requirement.

The viable path is **hybrid composition**. Each cached system prompt is built from three concatenated layers:

```
[Layer 1: Execution Context Override]   ← repo-local, stable
[Layer 2: BMAD Persona]                 ← live from .claude/skills/, may be empty
[Layer 3: Demo-Specific Rules]          ← repo-local stack / review rules
```

**Layer ordering matters.** Layer 1 must come first so the "do not HALT, skip On Activation" rules win against the BMAD persona's contradictory instructions. Layer 3 last so stack-specific rules (React/Vite/TS conventions, one-blocker-per-review-pass policy) are the most-recent instruction the model sees.

When BMAD updates a persona, only Layer 2 changes. Layers 1 and 3 stay byte-identical, so prompt cache hits survive on the un-changed layers' bytes during a run. When BMAD changes its file layout, only the Layer 2 loader needs updating.

---

## Proposed file layout

```
scripts/
├── ralph-loop.sh                    # shrinks by ~140 lines
└── prompts/                          # NEW — all repo-local prompt text
    ├── README.md                     # explains the 3-layer model + loader contract
    ├── common/
    │   ├── execution-context.md      # Layer 1: non-interactive override (~30 lines)
    │   └── project-conventions.md    # Layer 3 shared: React/Vite/TS stack + scope discipline
    ├── sm/overlay.md                 # Layer 3 SM-specific (placeholder initially)
    ├── dev/overlay.md                # Layer 3 Dev-specific (placeholder initially)
    ├── review/overlay.md             # Layer 3 Review: standards + UPSTREAM_FIX_REQUIRED format
    └── bmad-fallbacks/               # used only when .claude/skills/ is absent
        ├── sm.md
        ├── dev.md
        └── review.md
```

MD files use literal `{{CHECKPOINT_CMD}}` and `{{REVIEW_CHECKPOINT}}` placeholders — not bash `${}` interpolation. A single deterministic substitution pass replaces them at load time, with a whitelisted variable set.

---

## Loading mechanism (pseudocode)

A new bash helper `load_prompt_layers(role)` is added next to the existing BMAD loader:

```
load_prompt_layers(role):
  layer1 = read scripts/prompts/common/execution-context.md
  layer2 = $AGENT_<ROLE>_PERSONA           # already loaded from .claude/skills/
  layer3 = read scripts/prompts/common/project-conventions.md
         + read scripts/prompts/<role>/overlay.md
  if layer2 empty: layer2 = read scripts/prompts/bmad-fallbacks/<role>.md
  result = layer1 + "\n\n---\n\n" + layer2 + "\n\n---\n\n" + layer3
  result = replace("{{CHECKPOINT_CMD}}", $CHECKPOINT_CMD)   # whitelisted only
  return result
```

Called once per role from the existing `build_system_prompts()` function near the top of `main()`. Result is assigned to the existing `SYSTEM_PROMPT_SM/_DEV/_REVIEW` globals → every downstream call site stays unchanged, including the `--append-system-prompt "$system_prompt"` invocation in `run_claude()` (line ~790). Files are read once per run → the assembled string is byte-identical across every invocation of the same role within that run → **prompt cache continues to hit**.

---

## Migration steps (each independently reviewable)

1. **Extract literal text.** Create the `scripts/prompts/` tree per the layout above. Copy persona/rule text verbatim from `scripts/ralph-loop.sh` — no rewrites, no edits.
2. **Add the loader.** Define `load_prompt_layers()` in `scripts/ralph-loop.sh` alongside the existing BMAD loader. Don't wire it up yet.
3. **Add `--dry-run-prompts` flag.** Prints each resolved system prompt to stdout and exits before any `claude` invocation. This is the test harness for steps 4–6.
4. **Semantic equivalence gate.** Build a verification script that captures both the pre-refactor heredoc output (via `build_system_prompts()`) and the post-refactor layered output (via `--dry-run-prompts`), then checks that every significant content line from the original is present in the new output. Ordering, formatting, and separator differences are expected — the layer ordering is deliberately different. See story 1.4 in the epic for the full acceptance criteria and the rationale.
5. **Wire it in.** Make `build_system_prompts()` call `load_prompt_layers()`. Delete the inline `common`/SM/Dev/Review heredocs from the script (~140 line removal). Re-run the semantic equivalence script, confirm it still passes.
6. **Update docs.** Mention `scripts/prompts/` in [README.md](../../../README.md) "Repo layout" and [CLAUDE.md](../../../CLAUDE.md) "Repo layout". Add a one-paragraph explainer of the 3-layer model for users who fork this demo for a different stack.

Step 4's semantic check is the safety gate. Steps 5 and 6 are reversible if step 4 surfaces a regression. The epic at [epics/modularize-loop-prompts.md](epics/modularize-loop-prompts.md) breaks these into the stories the loop will run.

> **Why semantic and not byte-diff?** The original heredocs put `# Agent Persona`/persona content FIRST and bundle Execution Context inside the trailing `common` block. The new 3-layer assembly deliberately reorders this — Layer 1 (Execution Context) is FIRST so its "do not HALT, skip On Activation" rules override the BMAD persona's contradictory interactive instructions. This reordering is a *feature*, not a bug, so the two assemblies cannot be byte-identical by design. A byte-diff gate would always fail on this chapter; a semantic equivalence check ("all the same rules are still there") is the right primitive.

---

## Test plan (no overnight run required)

- **Semantic equivalence check** (primary gate): script produced in story 1.4 confirms that every significant content line from the pre-refactor heredoc output is present in the post-refactor `--dry-run-prompts` output. Ordering differences are expected and allowed — the 3-layer reordering is intentional.
- **Persona-absence test:** `mv .claude/skills .claude/skills.bak && ./scripts/ralph-loop.sh --dry-run-prompts`. Confirm fallback MDs load and the script logs `using inline fallback` for each role. Restore.
- **Single-story smoke run:** `./scripts/ralph-loop.sh --stories 1.1 --max-budget-usd 1`. Confirm SM produces a story spec; confirm prompt cache hits appear in per-invocation log (`cache_read > 0` on the Dev call after the SM call, since Layer 1+3 overlap across roles).
- **BMAD-update simulation:** edit `.claude/skills/bmad-dev-story/SKILL.md` (add a line). Re-run `--dry-run-prompts`. Confirm the Dev prompt reflects the edit *without* touching `scripts/ralph-loop.sh`. This directly verifies the stated goal.

---

## Risks and open questions

- **BMAD file layout drift across versions.** Confirmed real (root v6.2.2 vs demo v6.7+ differ). Mitigation: the existing BMAD loader pattern (check `SKILL.md`, then concatenate `steps/*.md`) handles both shapes seen today. If a future BMAD release drops `SKILL.md` entirely (e.g. moves to YAML manifests), the loader's "persona empty → fall back to `bmad-fallbacks/`" branch is the safety net. Add a startup warning when any expected role file is missing.
- **Silent override weakening.** If a future BMAD release adds a new "must HALT" rule with new keywords, Layer 1's override may not cover it — the loop could silently weaken. Layer 1 already neutralizes most such instructions, but flag a follow-up: add a CI check that grep-blocks new HALT-class keywords in resolved prompts.
- **Templating scope creep.** Whitelist `{{CHECKPOINT_CMD}}` (and only that) in v1. Document that per-invocation variables (story IDs, etc.) MUST stay in user prompts — never system — to preserve cache hits. Put this in `scripts/prompts/README.md`.
- **`.gitignore` impact.** `.claude/skills/` stays gitignored (correct — it's a regenerable BMAD install product). `scripts/prompts/` must be tracked. No `.gitignore` change needed; verify with `git check-ignore scripts/prompts/common/execution-context.md` post-extraction.

---

## Out of scope (explicitly)

- The 6 *user* prompts (heredocs at script lines ~914, 951, 984, 1027, 1063, 1123). Same externalization pattern applies but this chapter is scoped to system prompts / personas. Flagged as a follow-up chapter.
- Loop semantics, multi-model routing (haiku/sonnet/opus), retry logic, smart-salvage, upstream-fix detection, budget caps, auto-heal — all untouched.
- The `run_claude()` invocation signature and flag set — untouched.
- BMAD config / `customize.toml` / `_bmad/` — untouched. The loader reads `.claude/skills/` only.
- Switching languages (Python/Node/etc) — explicitly rejected. Stays bash.
- The Demo Track. Nothing under `docs/` or `src/` is modified by this chapter.

---

## Glossary

- **Layer 1 / 2 / 3** — the three concatenated sections of the cached system prompt, in order: execution-context override, BMAD persona, demo-specific rules. Defined in §"Recommended path" above.
- **SKILL.md** — the entry-point markdown file BMAD generates for each skill under `.claude/skills/<skill-name>/`. Contains the agent persona and workflow instructions.
- **UPSTREAM_FIX_REQUIRED** — the escalation contract used by the Review agent to signal that a defect in the current story actually requires fixing an earlier story. Implementation lives in `scripts/ralph-loop.sh`.
- **`--append-system-prompt`** — Claude Code CLI flag for injecting text into the system prompt. The vehicle for prompt-cache reuse.
- **Demo Track / System Track** — the two-track architecture of this repo. Demo Track is the frozen showcase at the repo root (`docs/`, `src/`, `scripts/ralph-loop.sh`). System Track is loop-improvement work under `system/`. See the [root README](../../../README.md) for the full description.
