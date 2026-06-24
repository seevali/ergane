# scripts/prompts — Ralph Loop Prompt Files

This directory holds the repo-local prompt text that the Ralph Loop assembles into cached system prompts for each agent role (SM, Dev, Review). It was introduced by the `2026-05-24-modularize-loop-prompts` chapter to replace ~110 lines of hardcoded heredocs in `scripts/ralph-loop.sh`.

---

## Three-Layer Composition Model

Each agent's cached system prompt is built from three layers concatenated with `---` separators:

```
[Layer 1: Execution Context]    scripts/prompts/common/execution-context.md
[Layer 2: BMAD Persona]         loaded live from .claude/skills/<role>/SKILL.md
                                  (falls back to scripts/prompts/bmad-fallbacks/<role>.md)
[Layer 3: Demo-Specific Rules]  scripts/prompts/common/project-conventions.md
                                  + scripts/prompts/<role>/overlay.md
```

**Why this order matters.** Layer 1 must come first: it contains "do not HALT, skip On Activation" override rules that win against BMAD persona's interactive instructions. Layer 3 comes last so demo-specific stack rules (React/Vite/TS conventions, review pass/block criteria) are the freshest instruction the model receives.

**When BMAD updates.** Only Layer 2 changes when a new BMAD version ships. Layers 1 and 3 stay byte-identical, so prompt cache hits survive across the unchanged bytes within a run.

---

## File Layout

```
scripts/prompts/
├── README.md                        ← this file
├── common/
│   ├── execution-context.md         Layer 1 (shared by all roles): non-interactive override
│   └── project-conventions.md       Layer 3 shared: React/Vite/TS stack rules + scope discipline
├── sm/
│   └── overlay.md                   Layer 3 SM-specific additions (placeholder initially)
├── dev/
│   └── overlay.md                   Layer 3 Dev-specific additions (placeholder initially)
├── review/
│   └── overlay.md                   Layer 3 Review: pass/block standards + UPSTREAM_FIX_REQUIRED format
└── bmad-fallbacks/                  Used only when .claude/skills/ is absent or incomplete
    ├── sm.md
    ├── dev.md
    └── review.md
```

---

## The `{{CHECKPOINT_CMD}}` Placeholder

`project-conventions.md` contains the literal string `{{CHECKPOINT_CMD}}` (double braces). This is the **only** templated value allowed in Layer 3. The loader (`load_prompt_layers()` in `scripts/ralph-loop.sh`, added in story 1.2) substitutes it with the actual `$CHECKPOINT_CMD` value at load time.

**Why double braces?** To distinguish placeholder syntax from bash variable syntax (`${...}`). The substitution is a single deterministic pass over a whitelisted set (`CHECKPOINT_CMD` only).

**Why is `CHECKPOINT_CMD` whitelisted and nothing else?** Prompt cache hits require byte-identical system prompts across every invocation of the same role within a run. `CHECKPOINT_CMD` is stable for the lifetime of a run (set once at startup). Per-invocation values — story IDs, file paths, user prompts — MUST remain in user prompts, never in the system prompt. If you add a new placeholder here, it will break cache hits unless you can guarantee the value is constant for the entire run.

---

## How the Loader Assembles a Prompt

The `load_prompt_layers(role)` function (story 1.2) does roughly:

```
layer1 = read scripts/prompts/common/execution-context.md
layer2 = $AGENT_<ROLE>_PERSONA   # already loaded from .claude/skills/
layer3 = read scripts/prompts/common/project-conventions.md
       + read scripts/prompts/<role>/overlay.md
if layer2 is empty:
    layer2 = read scripts/prompts/bmad-fallbacks/<role>.md
result = layer1 + "\n\n---\n\n" + layer2 + "\n\n---\n\n" + layer3
result = substitute("{{CHECKPOINT_CMD}}", $CHECKPOINT_CMD)
return result
```

The assembled string is assigned to `SYSTEM_PROMPT_SM`, `SYSTEM_PROMPT_DEV`, or `SYSTEM_PROMPT_REVIEW`, which the loop injects via `--append-system-prompt` on every `claude` invocation for that role.

---

## Where to Make Changes for a Different Stack

If you fork this demo for a different tech stack:

- **React/Vite/TS rules** — edit `scripts/prompts/common/project-conventions.md`. The "## Project Conventions" section is the only place these rules live. Keep the `{{CHECKPOINT_CMD}}` placeholder and update your checkpoint command in the shell that runs the loop.
- **Review pass/block criteria** — edit `scripts/prompts/review/overlay.md`. The current criteria are specific to the TypeScript/Vite build toolchain. Replace them with criteria appropriate to your stack.
- **Non-interactive override rules** — edit `scripts/prompts/common/execution-context.md` only if your BMAD version uses different activation patterns or introduces new interactive commands. Changing this risks the loop hanging.
- **Fallback personas** — edit `scripts/prompts/bmad-fallbacks/<role>.md` if you want different generic persona stubs when BMAD isn't installed.

Do NOT add new `{{PLACEHOLDER}}` values to Layer 3 files unless you also add the substitution case to `load_prompt_layers()` and verify the value is constant for the lifetime of a run.

---

## Layer 2 Lifecycle Note

Layer 2 (the BMAD persona) is loaded fresh from `.claude/skills/<skill>/SKILL.md` on every loop run via the existing BMAD loader in `scripts/ralph-loop.sh`. The `scripts/prompts/` directory is never the source for Layer 2 — `.claude/skills/` is. The `bmad-fallbacks/` subdirectory here is strictly a safety net used only when the skills directory is absent or a role file is missing.

`.claude/skills/` is gitignored — it is regenerated by `npx bmad-method install`. `scripts/prompts/` is tracked in git and is the stable, version-controlled source for Layers 1 and 3.
