import { intro, outro, text, confirm, select, isCancel } from '@clack/prompts';
import pc from 'picocolors';
import { isColorEnabled } from './colors.js';

// Sentinel thrown internally when the user cancels or declines.
// The outer try-catch converts it to a clean undefined return.
const CANCELLED = Symbol('wizard:cancelled');

// Validators exported so tests can verify them independently.
export const validators = {
  appDir(value) {
    const trimmed = value.trim();
    if (!trimmed) return 'Directory name is required.';
    if (trimmed.startsWith('/') || trimmed.includes('..')) {
      return 'Use a relative path (e.g., src, packages/ui).';
    }
    return undefined;
  },

  checkpointCommand(value) {
    const trimmed = value.trim();
    if (!trimmed) return 'Checkpoint command is required.';
    return undefined;
  },

  stackDescription(value) {
    if (!value.trim()) return 'Stack description is required.';
    return undefined;
  },

  loopRetries(value) {
    const num = parseInt(value.trim(), 10);
    if (isNaN(num) || num < 0) return 'Enter a non-negative number.';
    return undefined;
  },

  maxTokensPerTurn(value) {
    const num = parseInt(value.trim(), 10);
    if (isNaN(num) || num <= 0) return 'Enter a positive number.';
    return undefined;
  },

  taskSourcePath(value) {
    if (!value.trim()) return 'Path is required.';
    return undefined;
  },
};

// ── Non-interactive plan builder ──────────────────────────────────────────────

/**
 * Build an InstallPlan from defaults and CLI-provided answers, without any prompts.
 * Called when --yes is set. Prints plain text progress (no ANSI codes).
 *
 * @param {string} targetDir
 * @param {'empty'|'existing-project'|'existing-install'} classification
 * @param {object} cliAnswers - from parseCliArgs()
 * @param {Function} [log] - injectable console.log
 * @returns {object} InstallPlan
 */
function buildNonInteractivePlan(targetDir, classification, cliAnswers, log = console.log) {
  const appDir = (cliAnswers.appDir ?? 'src').trim();
  const checkpointCommand = (
    cliAnswers.checkpointCommand ?? 'npm run build && npm test'
  ).trim();
  const stackDescription = (
    cliAnswers.stackDescription ??
    'React 19 + Vite + TypeScript (strict mode)\nCSS Modules for styling\nVitest + React Testing Library for tests\nFetch API for HTTP'
  ).trim();
  const taskSource = cliAnswers.taskSource ?? 'scaffold';
  const addNpmScripts = cliAnswers.skipNpmScript !== 'yes';
  const skipBmad = cliAnswers.useBmad === 'no';

  const gitignoreEntries = ['_bmad/', '.claude/skills/', 'scripts/logs/'];
  const npmScriptNames = addNpmScripts ? ['dev-story', 'code-review'] : [];

  const summaryLines = [
    `Target directory: ${targetDir}`,
    `App directory: ${appDir}`,
    `Checkpoint command: ${checkpointCommand}`,
    `Stack: ${stackDescription.split('\n')[0]}...`,
    `Task source: ${taskSource}`,
    'Loop retries: 3',
    'Max tokens: 200000',
    'Will add .gitignore entries',
    addNpmScripts ? 'Will add npm scripts' : 'No npm script changes',
    skipBmad ? 'Skipping BMAD install' : 'Will install BMAD modules (core, bmm)',
    'Cost: the loop calls the Anthropic API — a small story typically costs cents to a few dollars; cap it with BUDGET_PER_STORY_USD',
  ];

  log('[non-interactive] Installing with defaults...');
  summaryLines.forEach((line) => log(`  ${line}`));

  return {
    targetDir,
    classification,
    isUpdate: classification === 'existing-install',
    runGitInit: false,

    appDir,
    checkpointCommand,
    stackDescription,

    loopRetries: 3,
    maxTokensPerTurn: 200000,
    modelOrder: ['opus', 'sonnet', 'haiku'],

    taskSource,
    taskSourcePath: undefined,

    addGitignoreEntries: true,
    gitignoreEntries,
    addNpmScripts,
    npmScriptNames,
    skipBmad,

    // Persist the ACTUAL configured values (not just confirmation booleans) so a
    // later `update` re-reads them as defaults and never regenerates config from
    // wizard defaults, silently discarding the user's stack/checkpoint/app dir.
    wizardAnswers: {
      explainerConfirmed: true,
      stackConfirmed: true,
      loopKnobsConfirmed: true,
      appDir,
      checkpointCommand,
      stackDescription,
      taskSource,
      taskSourcePath: undefined,
      skipBmad,
      addNpmScripts,
      loopRetries: 3,
      maxTokensPerTurn: 200000,
    },

    summaryLines,
  };
}

function makeCancelChecker(p, exit) {
  return function checkCancel(value) {
    if (p.isCancel(value)) {
      p.outro(pc.yellow('Nothing was changed.'));
      exit(0);
      throw CANCELLED;
    }
    return value;
  };
}

function decline(p, exit) {
  p.outro(pc.yellow('Nothing was changed.'));
  exit(0);
  throw CANCELLED;
}

/**
 * Run the wizard to collect install configuration.
 *
 * Supports two modes:
 * - Interactive (default): prompts the user via @clack/prompts; requires a TTY stdin.
 * - Non-interactive (opts.useDefaults=true): skips all prompts, uses defaults + cliAnswers;
 *   safe to use in CI/CD pipelines and piped contexts.
 *
 * @param {string} targetDir - absolute path to the target directory
 * @param {'empty'|'existing-project'|'existing-install'} classification - from Story 2.1
 * @param {object} preflightResults - from Story 1.4's preflight()
 * @param {object} [opts]
 * @param {boolean}  [opts.useDefaults]  - skip all prompts and use defaults (--yes)
 * @param {object}   [opts.cliAnswers]   - per-question flag values from parseCliArgs()
 * @param {object}   [opts.prompts]      - injectable prompt functions (for testing)
 * @param {Function} [opts.exit]         - injectable process.exit (for testing)
 * @param {Function} [opts.log]          - injectable console.log (for testing)
 * @returns {Promise<object|undefined>} InstallPlan, or undefined if user cancelled
 */
export async function runWizard(targetDir, classification, preflightResults, opts = {}) {
  const useDefaults = opts.useDefaults ?? false;
  const cliAnswers = opts.cliAnswers ?? {};
  const log = opts.log ?? console.log;

  // Non-interactive path: bypass all prompts, use defaults + cliAnswers
  if (useDefaults && !opts.prompts) {
    return buildNonInteractivePlan(targetDir, classification, cliAnswers, log);
  }

  // Interactive path requires a real TTY for user input
  if (!opts.prompts && !process.stdin.isTTY) {
    throw new Error(
      'Wizard requires an interactive terminal. Use --yes for non-interactive mode.',
    );
  }

  const colorOpts = { isTTY: process.stdout.isTTY === true };
  const p = opts.prompts ?? { intro, outro, text, confirm, select, isCancel };
  const exit = opts.exit ?? process.exit;
  const checkCancel = makeCancelChecker(p, exit);

  try {
    // ── Step 2: Intro ──────────────────────────────────────────────────────────
    p.intro(pc.bold('Ralph Loop Guided Installer'));

    const explainerConfirmed = checkCancel(
      await p.confirm({
        message:
          'Welcome! This wizard will set up the Ralph Loop — an agent-driven development loop\n' +
          'running Claude Code to build your app story by story.\n\n' +
          "We'll collect information about your project and the loop configuration.\n" +
          'Press Enter to accept any default, or Ctrl-C to cancel (zero changes made).\n\n' +
          'Continue?',
        initialValue: true,
      }),
    );
    if (!explainerConfirmed) decline(p, exit);

    // ── Step 3: Target directory confirmation ─────────────────────────────────
    const targetMessage =
      classification === 'empty'
        ? "This directory is empty. I'll set up the Ralph Loop here."
        : classification === 'existing-project'
          ? "This is an existing project. I'll add Ralph Loop files without touching your code."
          : "This directory already has a Ralph Loop install. I'll update it.";

    const targetConfirmed = checkCancel(
      await p.confirm({
        message: `${targetMessage}\n\nTarget: ${targetDir}\n\nContinue?`,
        initialValue: true,
      }),
    );
    if (!targetConfirmed) decline(p, exit);

    // ── Step 3b: Git init offer (empty directories only) ──────────────────────
    let runGitInit = false;
    if (classification === 'empty') {
      runGitInit = checkCancel(
        await p.confirm({
          message: 'This directory is empty. Initialize a git repository as part of the install?',
          initialValue: true,
        }),
      );
    }

    // ── Step 4a: App directory ────────────────────────────────────────────────
    const appDirRaw = checkCancel(
      await p.text({
        message: 'Application source directory (relative to project root)',
        initialValue: 'src',
        validate: validators.appDir,
      }),
    );

    // ── Step 4b: Checkpoint command ───────────────────────────────────────────
    const checkpointCommandRaw = checkCancel(
      await p.text({
        message: 'Checkpoint command (build + test; shown in loop prompts)',
        initialValue: 'npm run build && npm test',
        validate: validators.checkpointCommand,
      }),
    );

    // ── Step 4c: Stack description ────────────────────────────────────────────
    // @clack/prompts text is single-line by default. Multi-line content can be
    // edited in the generated project-conventions.md after install.
    const stackDescriptionRaw = checkCancel(
      await p.text({
        message: 'Stack description (tech choices, testing approach, etc.)',
        initialValue:
          'React 19 + Vite + TypeScript (strict mode)\nCSS Modules for styling\nVitest + React Testing Library for tests\nFetch API for HTTP',
        validate: validators.stackDescription,
      }),
    );

    // ── Step 5: Loop knobs ────────────────────────────────────────────────────
    const loopRetriesRaw = checkCancel(
      await p.text({
        message: 'Max retries per agent invocation (recommended: 3–5)',
        initialValue: '3',
        validate: validators.loopRetries,
      }),
    );

    const maxTokensPerTurnRaw = checkCancel(
      await p.text({
        message: 'Max output tokens per loop turn (recommended: 150k–300k)',
        initialValue: '200000',
        validate: validators.maxTokensPerTurn,
      }),
    );

    // ── Step 6: Task source ───────────────────────────────────────────────────
    const taskSource = checkCancel(
      await p.select({
        message: 'How would you like to define the first task?',
        options: [
          {
            value: 'scaffold',
            label: 'Start with a template PRD and epic (recommended)',
            hint: 'PRD = a short product-requirements doc; epic = a list of build stories. Includes comments explaining the format.',
          },
          {
            value: 'existing',
            label: 'Point to an existing PRD and epic',
            hint: 'PRD = product-requirements doc; epic = story list. Must follow the ### Story X.Y: Title format.',
          },
        ],
        initialValue: 'scaffold',
      }),
    );

    let taskSourcePath;
    if (taskSource === 'existing') {
      taskSourcePath = checkCancel(
        await p.text({
          message: 'Path to your PRD file (relative to project root)',
          initialValue: 'docs/prd.md',
          validate: validators.taskSourcePath,
        }),
      );
    }

    // ── Step 7: Extras ────────────────────────────────────────────────────────
    const addGitignoreEntries = checkCancel(
      await p.confirm({
        message: 'Add default .gitignore entries (_bmad/, .claude/skills/, scripts/logs/)?',
        initialValue: true,
      }),
    );

    const addNpmScripts = checkCancel(
      await p.confirm({
        message: 'Add npm scripts for the loop (dev-story, code-review)?',
        initialValue: true,
      }),
    );

    const installBmadStep = checkCancel(
      await p.confirm({
        message:
          'Install BMAD method modules (core, bmm) into docs/ as part of setup?\n' +
          '  Runs: npx bmad-method install --modules core,bmm --tools claude-code --output-folder docs',
        initialValue: true,
      }),
    );

    const gitignoreEntries = addGitignoreEntries
      ? ['_bmad/', '.claude/skills/', 'scripts/logs/']
      : [];

    const npmScriptNames = addNpmScripts ? ['dev-story', 'code-review'] : [];

    // ── Step 8: Summary and final confirmation ────────────────────────────────
    const summaryLines = [
      `Target directory: ${targetDir}`,
      `App directory: ${appDirRaw.trim()}`,
      `Checkpoint command: ${checkpointCommandRaw.trim()}`,
      `Stack: ${stackDescriptionRaw.trim().split('\n')[0]}...`,
      `Task source: ${taskSource}`,
      `Loop retries: ${loopRetriesRaw.trim()}`,
      `Max tokens: ${maxTokensPerTurnRaw.trim()}`,
      addGitignoreEntries ? 'Will add .gitignore entries' : 'No .gitignore changes',
      addNpmScripts ? 'Will add npm scripts' : 'No npm script changes',
      installBmadStep ? 'Will install BMAD modules (core, bmm)' : 'Skipping BMAD install',
      'Cost: the loop calls the Anthropic API — a small story typically costs cents to a few dollars; cap it with BUDGET_PER_STORY_USD',
    ];

    console.log('\n' + (isColorEnabled(colorOpts) ? pc.gray('Plan summary:') : 'Plan summary:'));
    summaryLines.forEach((line) => console.log('  ' + line));

    const finalConfirm = checkCancel(
      await p.confirm({
        message: 'Create this install?',
        initialValue: true,
      }),
    );
    if (!finalConfirm) decline(p, exit);

    // ── Step 9: Build and return the InstallPlan ──────────────────────────────
    const installPlan = {
      targetDir,
      classification,
      isUpdate: classification === 'existing-install',
      runGitInit,

      appDir: appDirRaw.trim(),
      checkpointCommand: checkpointCommandRaw.trim(),
      stackDescription: stackDescriptionRaw.trim(),

      loopRetries: parseInt(loopRetriesRaw.trim(), 10),
      maxTokensPerTurn: parseInt(maxTokensPerTurnRaw.trim(), 10),
      modelOrder: ['opus', 'sonnet', 'haiku'],

      taskSource,
      taskSourcePath: taskSourcePath?.trim(),

      addGitignoreEntries,
      gitignoreEntries,
      addNpmScripts,
      npmScriptNames,
      skipBmad: !installBmadStep,

      // Persist the ACTUAL configured values (see buildNonInteractivePlan) so a later
      // `update` preserves the user's stack/checkpoint/app dir byte-for-byte.
      wizardAnswers: {
        explainerConfirmed: true,
        stackConfirmed: true,
        loopKnobsConfirmed: true,
        appDir: appDirRaw.trim(),
        checkpointCommand: checkpointCommandRaw.trim(),
        stackDescription: stackDescriptionRaw.trim(),
        taskSource,
        taskSourcePath: taskSourcePath?.trim(),
        skipBmad: !installBmadStep,
        addNpmScripts,
        loopRetries: parseInt(loopRetriesRaw.trim(), 10),
        maxTokensPerTurn: parseInt(maxTokensPerTurnRaw.trim(), 10),
      },

      summaryLines,
    };

    p.outro(pc.green('Plan ready. Proceeding to install...'));

    return installPlan;
  } catch (err) {
    if (err === CANCELLED) return undefined;
    throw err;
  }
}
