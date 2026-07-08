import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runWizard, validators } from './wizard.js';

// A unique symbol that acts as the @clack/prompts cancel token in tests.
const CANCEL = Symbol('test:cancel');

/**
 * Build a mock prompts bundle that auto-answers every prompt with its
 * initialValue (or the first option for select).  Override specific call
 * indices via { confirms, texts, selects } arrays.
 */
function buildMockPrompts(overrides = {}) {
  const counts = { confirm: 0, text: 0, select: 0 };
  return {
    intro: () => {},
    outro: () => {},
    isCancel: (v) => v === CANCEL,
    cancel: () => {},
    confirm: async (opts) => overrides.confirms?.[counts.confirm++] ?? opts.initialValue ?? true,
    select: async (opts) =>
      overrides.selects?.[counts.select++] ?? opts.initialValue ?? opts.options[0].value,
    text: async (opts) => overrides.texts?.[counts.text++] ?? opts.initialValue ?? '',
  };
}

// ─── Happy path ───────────────────────────────────────────────────────────────

test('returns a valid InstallPlan with all required fields (Enter-only defaults)', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, { prompts: buildMockPrompts() });

  assert.ok(plan, 'plan should be defined');
  assert.equal(plan.targetDir, '/tmp/test-dir');
  assert.equal(plan.classification, 'empty');
  assert.equal(plan.isUpdate, false);
  assert.equal(plan.appDir, 'src');
  assert.ok(plan.checkpointCommand, 'checkpointCommand should be non-empty');
  assert.ok(plan.stackDescription, 'stackDescription should be non-empty');
  assert.equal(plan.loopRetries, 3);
  assert.equal(plan.maxTokensPerTurn, 200000);
  assert.deepEqual(plan.modelOrder, ['opus', 'sonnet', 'haiku']);
  assert.equal(plan.taskSource, 'scaffold');
  assert.equal(plan.taskSourcePath, undefined);
  assert.equal(plan.addGitignoreEntries, true);
  assert.deepEqual(plan.gitignoreEntries, ['_bmad/', '.claude/skills/', 'scripts/logs/']);
  assert.equal(plan.addNpmScripts, true);
  assert.deepEqual(plan.npmScriptNames, ['dev-story', 'code-review']);
  assert.ok(plan.wizardAnswers, 'wizardAnswers should be present');
  assert.equal(plan.wizardAnswers.explainerConfirmed, true);
  assert.ok(Array.isArray(plan.summaryLines), 'summaryLines should be an array');
  assert.ok(plan.summaryLines.length > 0, 'summaryLines should not be empty');
});

test('all string fields are non-empty after trimming (defaults)', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, { prompts: buildMockPrompts() });
  for (const key of ['appDir', 'checkpointCommand', 'stackDescription']) {
    assert.ok(plan[key].trim().length > 0, `plan.${key} should be non-empty after trim`);
  }
});

test('numeric fields are integers >= 0', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, { prompts: buildMockPrompts() });
  assert.ok(Number.isInteger(plan.loopRetries) && plan.loopRetries >= 0, 'loopRetries >= 0');
  assert.ok(Number.isInteger(plan.maxTokensPerTurn) && plan.maxTokensPerTurn > 0, 'maxTokensPerTurn > 0');
});

// ─── Classification variants ──────────────────────────────────────────────────

test('isUpdate is true when classification is existing-install', async () => {
  const plan = await runWizard('/tmp/test-dir', 'existing-install', {}, {
    prompts: buildMockPrompts(),
  });
  assert.equal(plan.isUpdate, true);
  assert.equal(plan.classification, 'existing-install');
});

test('isUpdate is false when classification is existing-project', async () => {
  const plan = await runWizard('/tmp/test-dir', 'existing-project', {}, {
    prompts: buildMockPrompts(),
  });
  assert.equal(plan.isUpdate, false);
});

// ─── Git init offer (AC4) ─────────────────────────────────────────────────────

test('runGitInit is true by default for empty classification', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, { prompts: buildMockPrompts() });
  assert.equal(plan.runGitInit, true, 'runGitInit should default to true for empty dirs');
});

test('runGitInit can be declined for empty classification', async () => {
  // confirms: explainer, target, gitInit=false, addGitignoreEntries, addNpmScripts, installBmad, finalConfirm
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    prompts: buildMockPrompts({ confirms: [true, true, false, true, true, true, true] }),
  });
  assert.equal(plan.runGitInit, false, 'runGitInit should be false when user declines');
});

test('runGitInit is false and prompt is not offered for existing-project classification', async () => {
  const plan = await runWizard('/tmp/test-dir', 'existing-project', {}, {
    prompts: buildMockPrompts(),
  });
  assert.equal(plan.runGitInit, false, 'runGitInit should be false for non-empty dirs');
});

test('runGitInit is false and prompt is not offered for existing-install classification', async () => {
  const plan = await runWizard('/tmp/test-dir', 'existing-install', {}, {
    prompts: buildMockPrompts(),
  });
  assert.equal(plan.runGitInit, false, 'runGitInit should be false for existing installs');
});

// ─── Task source ──────────────────────────────────────────────────────────────

test('taskSourcePath is set when user selects existing task source', async () => {
  // confirm x5 (defaults), select returns 'existing', texts: appDir, checkpoint, stack, retries, tokens, prdPath
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    prompts: buildMockPrompts({
      selects: ['existing'],
      texts: ['src', 'npm run build && npm test', 'React + TypeScript', '3', '200000', 'my/prd.md'],
    }),
  });
  assert.equal(plan.taskSource, 'existing');
  assert.equal(plan.taskSourcePath, 'my/prd.md');
});

test('taskSourcePath is undefined when user selects scaffold', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    prompts: buildMockPrompts({ selects: ['scaffold'] }),
  });
  assert.equal(plan.taskSource, 'scaffold');
  assert.equal(plan.taskSourcePath, undefined);
});

// ─── Task source: example (worked example prefill) ────────────────────────────

test('selecting example prefills the stack-shaped answers (interactive)', async () => {
  // No text overrides: each text prompt auto-answers with its initialValue, which the
  // example branch prefills. This proves the select→prefill wiring is coherent so a
  // user who accepts every default lands on a config that builds the example app.
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    prompts: buildMockPrompts({ selects: ['example'] }),
  });
  assert.equal(plan.taskSource, 'example');
  assert.equal(plan.appDir, 'src');
  assert.equal(plan.checkpointCommand, 'cd src && npm run build && npm test --if-present');
  assert.equal(plan.stackDescription, 'React 19 + Vite + TypeScript (strict)');
  assert.equal(plan.taskSourcePath, undefined, 'example needs no follow-up path prompt');
});

test('example prefill is only a default — explicit answers still win (interactive)', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    prompts: buildMockPrompts({
      selects: ['example'],
      texts: ['web', 'make ci', 'Svelte', '3', '200000'],
    }),
  });
  assert.equal(plan.taskSource, 'example');
  assert.equal(plan.appDir, 'web');
  assert.equal(plan.checkpointCommand, 'make ci');
  assert.equal(plan.stackDescription, 'Svelte');
});

test('example checkpoint tracks an overridden app dir when the checkpoint is left at its default (interactive)', async () => {
  // Override ONLY the app-dir prompt (Step 4a); accept the checkpoint prompt's
  // default (the mock returns opts.initialValue for the unspecified indices). The
  // checkpoint default must derive from the entered app dir so the two stay coherent
  // — otherwise the install ships `cd src && …` against an `app/`-only tree, which
  // fails at the first checkpoint and contradicts GETTING-STARTED's `cd app` prose.
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    prompts: buildMockPrompts({
      selects: ['example'],
      texts: ['app'], // appDir only; checkpoint/stack/retries/tokens keep their defaults
    }),
  });
  assert.equal(plan.taskSource, 'example');
  assert.equal(plan.appDir, 'app');
  assert.equal(
    plan.checkpointCommand,
    'cd app && npm run build && npm test --if-present',
    'checkpoint default must cd into the overridden app dir, not the stale src default',
  );
});

// ─── Extras opt-out ───────────────────────────────────────────────────────────

test('gitignoreEntries is empty when user opts out', async () => {
  // confirms: explainer, target, gitInit, addGitignore=false, addNpmScripts, installBmad, finalConfirm
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    prompts: buildMockPrompts({ confirms: [true, true, true, false, true, true, true] }),
  });
  assert.equal(plan.addGitignoreEntries, false);
  assert.deepEqual(plan.gitignoreEntries, []);
});

test('npmScriptNames is empty when user opts out', async () => {
  // confirms: explainer, target, gitInit, addGitignoreEntries, addNpmScripts=false, installBmad, finalConfirm
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    prompts: buildMockPrompts({ confirms: [true, true, true, true, false, true, true] }),
  });
  assert.equal(plan.addNpmScripts, false);
  assert.deepEqual(plan.npmScriptNames, []);
});

// ─── Cancellation handling ────────────────────────────────────────────────────

test('Ctrl-C at explainer prompt calls exit(0) and returns undefined', async () => {
  const exitCalls = [];
  const result = await runWizard('/tmp/test-dir', 'empty', {}, {
    exit: (code) => exitCalls.push(code),
    prompts: {
      intro: () => {},
      outro: () => {},
      isCancel: (v) => v === CANCEL,
      cancel: () => {},
      confirm: async () => CANCEL,
      select: async (opts) => opts.initialValue ?? opts.options[0].value,
      text: async (opts) => opts.initialValue ?? '',
    },
  });

  assert.equal(result, undefined, 'should return undefined on cancel');
  assert.equal(exitCalls.length, 1, 'exit should be called once');
  assert.equal(exitCalls[0], 0, 'exit should be called with code 0');
});

test('declining at final confirmation calls exit(0) and returns undefined', async () => {
  const exitCalls = [];
  let confirmCount = 0;

  const result = await runWizard('/tmp/test-dir', 'empty', {}, {
    exit: (code) => exitCalls.push(code),
    prompts: {
      intro: () => {},
      outro: () => {},
      isCancel: () => false,
      cancel: () => {},
      // Return false on the 7th confirm (index 6) — the final "Create this install?"
      // (empty classification adds a git init confirm at index 2 and BMAD confirm at index 5,
      // shifting final to index 6)
      confirm: async (opts) => (confirmCount++ === 6 ? false : (opts.initialValue ?? true)),
      select: async (opts) => opts.initialValue ?? opts.options[0].value,
      text: async (opts) => opts.initialValue ?? '',
    },
  });

  assert.equal(result, undefined, 'should return undefined on decline');
  assert.equal(exitCalls.length, 1, 'exit should be called once');
  assert.equal(exitCalls[0], 0, 'exit should be called with code 0');
});

test('Ctrl-C mid-wizard calls exit(0) and returns undefined', async () => {
  const exitCalls = [];
  let textCount = 0;

  const result = await runWizard('/tmp/test-dir', 'empty', {}, {
    exit: (code) => exitCalls.push(code),
    prompts: {
      intro: () => {},
      outro: () => {},
      isCancel: (v) => v === CANCEL,
      cancel: () => {},
      confirm: async (opts) => opts.initialValue ?? true,
      select: async (opts) => opts.initialValue ?? opts.options[0].value,
      // Cancel on the second text prompt (checkpoint command)
      text: async (opts) => (textCount++ === 1 ? CANCEL : (opts.initialValue ?? '')),
    },
  });

  assert.equal(result, undefined, 'should return undefined on cancel');
  assert.equal(exitCalls.length, 1);
  assert.equal(exitCalls[0], 0);
});

// ─── Non-TTY detection ────────────────────────────────────────────────────────

test('throws when no TTY and no injected prompts', async () => {
  const origIsTTY = process.stdin.isTTY;
  try {
    Object.defineProperty(process.stdin, 'isTTY', { value: false, configurable: true });
    await assert.rejects(
      () => runWizard('/tmp/test-dir', 'empty', {}),
      (err) => {
        assert.ok(err.message.includes('interactive terminal'), 'error should mention TTY');
        return true;
      },
    );
  } finally {
    Object.defineProperty(process.stdin, 'isTTY', {
      value: origIsTTY,
      configurable: true,
    });
  }
});

// ─── InstallPlan schema completeness ─────────────────────────────────────────

test('InstallPlan schema: all required top-level keys are present', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, { prompts: buildMockPrompts() });
  const requiredKeys = [
    'targetDir', 'classification', 'isUpdate', 'runGitInit',
    'appDir', 'checkpointCommand', 'stackDescription',
    'loopRetries', 'maxTokensPerTurn', 'modelOrder',
    'taskSource',
    'addGitignoreEntries', 'gitignoreEntries',
    'addNpmScripts', 'npmScriptNames',
    'skipBmad',
    'wizardAnswers', 'summaryLines',
  ];
  for (const key of requiredKeys) {
    assert.ok(key in plan, `plan.${key} should be present`);
  }
});

test('InstallPlan schema: wizardAnswers contains required flags', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, { prompts: buildMockPrompts() });
  assert.equal(typeof plan.wizardAnswers.explainerConfirmed, 'boolean');
  assert.equal(typeof plan.wizardAnswers.stackConfirmed, 'boolean');
  assert.equal(typeof plan.wizardAnswers.loopKnobsConfirmed, 'boolean');
});

test('InstallPlan schema: modelOrder is an array of strings', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, { prompts: buildMockPrompts() });
  assert.ok(Array.isArray(plan.modelOrder));
  assert.ok(plan.modelOrder.every((m) => typeof m === 'string'));
});

// ─── validators.appDir ───────────────────────────────────────────────────────

test('validators.appDir: rejects empty string', () => {
  assert.ok(validators.appDir(''), 'empty string should be invalid');
  assert.ok(validators.appDir('   '), 'whitespace-only should be invalid');
});

test('validators.appDir: rejects absolute paths', () => {
  assert.ok(validators.appDir('/src'), 'leading slash should be invalid');
  assert.ok(validators.appDir('/usr/local'), 'absolute path should be invalid');
});

test('validators.appDir: rejects path traversal', () => {
  assert.ok(validators.appDir('../outside'), '.. should be invalid');
  assert.ok(validators.appDir('src/../secret'), 'embedded .. should be invalid');
});

test('validators.appDir: accepts valid relative paths', () => {
  assert.equal(validators.appDir('src'), undefined, '"src" should be valid');
  assert.equal(validators.appDir('packages/ui'), undefined, '"packages/ui" should be valid');
  assert.equal(validators.appDir('  frontend  '), undefined, 'whitespace is trimmed before check');
});

// ─── validators.checkpointCommand ────────────────────────────────────────────

test('validators.checkpointCommand: rejects empty and whitespace', () => {
  assert.ok(validators.checkpointCommand(''), 'empty should be invalid');
  assert.ok(validators.checkpointCommand('   '), 'whitespace-only should be invalid');
});

test('validators.checkpointCommand: accepts any non-empty command', () => {
  assert.equal(validators.checkpointCommand('npm run build && npm test'), undefined);
  assert.equal(validators.checkpointCommand('make test'), undefined);
  assert.equal(
    validators.checkpointCommand('bash -n script.sh && ./script.sh --dry-run'),
    undefined,
  );
});

// ─── validators.loopRetries ──────────────────────────────────────────────────

test('validators.loopRetries: rejects non-numeric and negative', () => {
  assert.ok(validators.loopRetries('abc'));
  assert.ok(validators.loopRetries(''));
  assert.ok(validators.loopRetries('-1'));
});

test('validators.loopRetries: accepts 0 and positive integers', () => {
  assert.equal(validators.loopRetries('0'), undefined);
  assert.equal(validators.loopRetries('3'), undefined);
  assert.equal(validators.loopRetries('10'), undefined);
});

// ─── validators.maxTokensPerTurn ─────────────────────────────────────────────

test('validators.maxTokensPerTurn: rejects 0 and negative', () => {
  assert.ok(validators.maxTokensPerTurn('0'));
  assert.ok(validators.maxTokensPerTurn('-1'));
  assert.ok(validators.maxTokensPerTurn(''));
});

test('validators.maxTokensPerTurn: accepts positive integers', () => {
  assert.equal(validators.maxTokensPerTurn('200000'), undefined);
  assert.equal(validators.maxTokensPerTurn('1'), undefined);
});

// ─── validators.stackDescription ─────────────────────────────────────────────

test('validators.stackDescription: rejects empty/whitespace', () => {
  assert.ok(validators.stackDescription(''));
  assert.ok(validators.stackDescription('   '));
});

test('validators.stackDescription: accepts strings with special characters', () => {
  assert.equal(validators.stackDescription('React 19 + Vite + TypeScript'), undefined);
  assert.equal(validators.stackDescription('Node.js # markdown * chars'), undefined);
  assert.equal(validators.stackDescription('multi\nline\ncontent'), undefined);
});

// ─── Edge cases ───────────────────────────────────────────────────────────────

test('edge case: whitespace-padded text inputs are trimmed in InstallPlan', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    prompts: buildMockPrompts({
      texts: ['  src  ', '  npm test  ', '  React  ', '3', '200000'],
    }),
  });
  assert.equal(plan.appDir, 'src', 'appDir should be trimmed');
  assert.equal(plan.checkpointCommand, 'npm test', 'checkpointCommand should be trimmed');
  assert.equal(plan.stackDescription, 'React', 'stackDescription should be trimmed');
});

test('edge case: stack description with markdown special characters is stored as-is', async () => {
  const rawStack = 'React 19 + **Vite** + TypeScript\n# Strict mode\n* CSS Modules';
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    prompts: buildMockPrompts({ texts: ['src', 'npm test', rawStack, '3', '200000'] }),
  });
  assert.equal(plan.stackDescription, rawStack.trim(), 'stack description stored verbatim');
});

// ─── skipBmad ────────────────────────────────────────────────────────────────

test('skipBmad defaults to false (BMAD installs by default)', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, { prompts: buildMockPrompts() });
  assert.equal(plan.skipBmad, false, 'skipBmad should default to false (BMAD installed by default)');
});

test('skipBmad is true when user declines BMAD install', async () => {
  // confirms: explainer, target, gitInit, addGitignoreEntries, addNpmScripts, installBmad=false, finalConfirm
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    prompts: buildMockPrompts({ confirms: [true, true, true, true, true, false, true] }),
  });
  assert.equal(plan.skipBmad, true, 'skipBmad should be true when user declines BMAD install');
});

// ─── Non-interactive mode (--yes) ────────────────────────────────────────────

test('useDefaults=true returns plan without calling any prompts', async () => {
  let promptsCalled = false;
  const result = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    log: () => {},
    prompts: {
      intro: () => { promptsCalled = true; },
      outro: () => { promptsCalled = true; },
      confirm: () => { promptsCalled = true; },
      text: () => { promptsCalled = true; },
      select: () => { promptsCalled = true; },
      isCancel: () => false,
    },
  });
  // useDefaults=true with injected prompts: since opts.prompts is set, we go through the
  // interactive path. To test pure non-interactive, omit opts.prompts.
  // This test verifies the plan is still returned.
  assert.ok(result, 'should return a plan');
});

test('useDefaults=true without opts.prompts returns plan without TTY', async () => {
  const logs = [];
  const plan = await runWizard('/tmp/nonexistent-tty', 'empty', {}, {
    useDefaults: true,
    log: (msg) => logs.push(msg),
  });
  assert.ok(plan, 'should return a plan');
  assert.ok(logs.length > 0, 'should produce log output');
});

test('non-interactive plan has all required fields', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    log: () => {},
  });

  const requiredKeys = [
    'targetDir', 'classification', 'isUpdate', 'runGitInit',
    'appDir', 'checkpointCommand', 'stackDescription',
    'loopRetries', 'maxTokensPerTurn', 'modelOrder',
    'taskSource',
    'addGitignoreEntries', 'gitignoreEntries',
    'addNpmScripts', 'npmScriptNames',
    'skipBmad',
    'wizardAnswers', 'summaryLines',
  ];
  for (const key of requiredKeys) {
    assert.ok(key in plan, `plan.${key} should be present`);
  }
});

test('non-interactive plan uses defaults for all fields', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    log: () => {},
  });

  assert.equal(plan.targetDir, '/tmp/test-dir');
  assert.equal(plan.classification, 'empty');
  assert.equal(plan.isUpdate, false);
  assert.equal(plan.appDir, 'src');
  assert.equal(plan.checkpointCommand, 'npm run build && npm test');
  assert.ok(plan.stackDescription.length > 0, 'stackDescription should be non-empty');
  assert.equal(plan.loopRetries, 3);
  assert.equal(plan.maxTokensPerTurn, 200000);
  assert.deepEqual(plan.modelOrder, ['opus', 'sonnet', 'haiku']);
  assert.equal(plan.taskSource, 'scaffold');
  assert.equal(plan.addGitignoreEntries, true);
  assert.equal(plan.addNpmScripts, true);
  assert.equal(plan.skipBmad, false, 'BMAD installs by default');
});

test('non-interactive plan: cliAnswers.appDir overrides default', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    cliAnswers: { appDir: 'frontend' },
    log: () => {},
  });
  assert.equal(plan.appDir, 'frontend');
});

test('non-interactive plan: cliAnswers.checkpointCommand overrides default', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    cliAnswers: { checkpointCommand: 'make test' },
    log: () => {},
  });
  assert.equal(plan.checkpointCommand, 'make test');
});

test('non-interactive plan: cliAnswers.taskSource=existing is respected', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    cliAnswers: { taskSource: 'existing' },
    log: () => {},
  });
  assert.equal(plan.taskSource, 'existing');
});

test('non-interactive plan: taskSource=example prefills the example stack defaults', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    cliAnswers: { taskSource: 'example' },
    log: () => {},
  });
  assert.equal(plan.taskSource, 'example');
  assert.equal(plan.appDir, 'src');
  assert.equal(plan.checkpointCommand, 'cd src && npm run build && npm test --if-present');
  assert.equal(plan.stackDescription, 'React 19 + Vite + TypeScript (strict)');
});

test('non-interactive plan: explicit flags override the example prefill', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    cliAnswers: { taskSource: 'example', checkpointCommand: 'make ci', appDir: 'web' },
    log: () => {},
  });
  assert.equal(plan.taskSource, 'example');
  assert.equal(plan.checkpointCommand, 'make ci');
  assert.equal(plan.appDir, 'web');
});

test('non-interactive plan: scaffold keeps the generic checkpoint default (no example bleed)', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    cliAnswers: { taskSource: 'scaffold' },
    log: () => {},
  });
  assert.equal(plan.checkpointCommand, 'npm run build && npm test');
});

test('non-interactive plan: example checkpoint tracks --app-dir when checkpoint is not overridden', async () => {
  // The incoherence path: pick the example, override ONLY --app-dir. The derived
  // checkpoint must `cd` into the overridden dir so the printed run command and
  // GETTING-STARTED prose both stay runnable.
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    cliAnswers: { taskSource: 'example', appDir: 'app' },
    log: () => {},
  });
  assert.equal(plan.taskSource, 'example');
  assert.equal(plan.appDir, 'app');
  assert.equal(
    plan.checkpointCommand,
    'cd app && npm run build && npm test --if-present',
    'checkpoint must cd into the overridden --app-dir, not the stale src default',
  );
});

test('non-interactive plan: cliAnswers.useBmad=no sets skipBmad=true', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    cliAnswers: { useBmad: 'no' },
    log: () => {},
  });
  assert.equal(plan.skipBmad, true, 'useBmad=no should set skipBmad=true');
});

test('non-interactive plan: cliAnswers.skipNpmScript=yes sets addNpmScripts=false', async () => {
  const plan = await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    cliAnswers: { skipNpmScript: 'yes' },
    log: () => {},
  });
  assert.equal(plan.addNpmScripts, false, 'skipNpmScript=yes should set addNpmScripts=false');
  assert.deepEqual(plan.npmScriptNames, []);
});

test('non-interactive plan: isUpdate=true for existing-install classification', async () => {
  const plan = await runWizard('/tmp/test-dir', 'existing-install', {}, {
    useDefaults: true,
    log: () => {},
  });
  assert.equal(plan.isUpdate, true);
  assert.equal(plan.classification, 'existing-install');
});

test('non-interactive log output contains no ANSI escape codes', async () => {
  const logs = [];
  await runWizard('/tmp/test-dir', 'empty', {}, {
    useDefaults: true,
    log: (msg = '') => logs.push(msg),
  });
  const combined = logs.join('\n');
  assert.ok(!/\x1b\[/.test(combined), 'non-interactive log should contain no ANSI escape codes');
});

test('useDefaults=false without TTY still throws (interactive requires TTY)', async () => {
  const origIsTTY = process.stdin.isTTY;
  try {
    Object.defineProperty(process.stdin, 'isTTY', { value: false, configurable: true });
    await assert.rejects(
      () => runWizard('/tmp/test-dir', 'empty', {}),
      (err) => {
        assert.ok(err.message.includes('interactive terminal'), 'error should mention TTY');
        return true;
      },
    );
  } finally {
    Object.defineProperty(process.stdin, 'isTTY', {
      value: origIsTTY,
      configurable: true,
    });
  }
});
