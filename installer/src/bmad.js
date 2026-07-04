import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFileCb);

export const BMAD_COMMAND = 'npx';

/**
 * The minimal, known-good argument set accepted by every supported bmad-method
 * version. Used verbatim when flag-probing is unavailable (offline / probe failed).
 */
export const BMAD_BASE_ARGS = [
  'bmad-method',
  'install',
  '--modules', 'core,bmm',
  '--tools', 'claude-code',
  '--output-folder', 'docs',
];

/**
 * Flags that older bmad-method advertised but newer versions dropped (e.g.
 * `--artifact-folder` was removed in bmad-method@6.10). Each is included ONLY when
 * the resolved binary's `install --help` still advertises it — so we never pass a
 * flag the installed version rejects (which previously printed
 * `unknown option '--artifact-folder'` and then a broken remediation).
 */
export const BMAD_OPTIONAL_FLAGS = [
  { flag: '--artifact-folder', value: 'docs' },
  { flag: '--memory-folder', value: 'docs/_bmad/_memory' },
];

/**
 * Compose the bmad-method install args from the base set plus whatever optional
 * flags the given `install --help` text advertises. Pure and fully testable.
 *
 * @param {string} [helpText] - the resolved binary's `install --help` output
 * @returns {string[]} argv for the install run (excludes the `npx` command word)
 */
export function composeBmadArgs(helpText) {
  const args = [...BMAD_BASE_ARGS];
  const help = helpText ?? '';
  for (const { flag, value } of BMAD_OPTIONAL_FLAGS) {
    if (help.includes(flag)) {
      args.push(flag, value);
    }
  }
  return args;
}

/** Render an argv into a copy-pasteable command string. */
export function formatBmadCommand(args) {
  return `${BMAD_COMMAND} ${args.join(' ')}`;
}

/**
 * Probe the resolved bmad-method for its advertised install flags. Offline-safe:
 * returns null if the probe cannot produce usable help output, so the caller falls
 * back to the minimal known-good set.
 *
 * @param {Function} execFn - promisified execFile
 * @returns {Promise<string|null>}
 */
async function probeBmadHelp(execFn) {
  try {
    const { stdout = '', stderr = '' } = await execFn(BMAD_COMMAND, [
      'bmad-method', 'install', '--help',
    ]);
    const out = `${stdout}\n${stderr}`;
    return out.trim() ? out : null;
  } catch (err) {
    const out = `${err?.stdout ?? ''}\n${err?.stderr ?? ''}`;
    // Some CLIs print help to stderr with a non-zero exit; keep it only if usable.
    return out.includes('--modules') || out.includes('--output-folder') ? out : null;
  }
}

function makeNoopSpinner() {
  return {
    start() {},
    stop() {},
  };
}

function printManualCommand(log, errorOutput, attemptedCommand) {
  if (errorOutput) {
    log(`\nBMAD install error: ${errorOutput}`);
  }
  log('\nBMAD installation could not complete. Run this exact command to finish it manually:\n');
  log(`  ${attemptedCommand}\n`);
  log('Or proceed without BMAD now and add it later with: npx bmad-method update');
}

/**
 * Run `npx bmad-method install` non-interactively with a defensively-composed flag
 * set. On failure it prints the EXACT command it attempted (post flag-probe) as the
 * manual remediation, so copy-paste has a chance of working, and returns
 * `{ success: false }` so the caller can state the degraded install honestly.
 *
 * @param {object} [options]
 * @param {object}   [options.spinner]   - external @clack/prompts spinner (start/stop); created internally if omitted
 * @param {boolean}  [options.isTTY]     - whether stdout is a TTY; defaults to process.stdout.isTTY
 * @param {Function} [options.execFile]  - injectable promisified execFile (for testing)
 * @param {Function} [options.log]       - injectable logger (for testing); defaults to console.log
 * @param {string}   [options.help]      - inject `install --help` text (skips probing; for testing/offline)
 * @param {Function} [options.probe]     - injectable probe () => Promise<string|null> (for testing)
 * @returns {Promise<{success: boolean, error?: string, command: string}>}
 */
export async function installBmad(options = {}) {
  const isTTY = options.isTTY ?? process.stdout.isTTY ?? false;
  const execFn = options.execFile ?? execFileAsync;
  const log = options.log ?? console.log;

  // Resolve the advertised flags defensively.
  let helpText;
  if (options.help !== undefined) {
    helpText = options.help;
  } else if (options.probe) {
    helpText = await options.probe();
  } else {
    helpText = await probeBmadHelp(execFn);
  }

  const args = composeBmadArgs(helpText ?? '');
  const attemptedCommand = formatBmadCommand(args);

  let s;
  if (options.spinner) {
    s = options.spinner;
  } else if (isTTY) {
    const { spinner } = await import('@clack/prompts');
    s = spinner();
  } else {
    s = makeNoopSpinner();
    log('Installing BMAD modules...');
  }

  s.start('Installing BMAD modules...');

  try {
    await execFn(BMAD_COMMAND, args);
    s.stop('BMAD modules installed.');
    return { success: true, command: attemptedCommand };
  } catch (err) {
    s.stop('BMAD installation failed.');
    const error = err?.stderr ?? err?.message ?? 'BMAD install failed';
    printManualCommand(log, error, attemptedCommand);
    return { success: false, error, command: attemptedCommand };
  }
}
