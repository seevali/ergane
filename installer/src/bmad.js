import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFileCb);

export const BMAD_COMMAND = 'npx';
export const BMAD_ARGS = [
  'bmad-method',
  'install',
  '--modules', 'core,bmm',
  '--tools', 'claude-code',
  '--output-folder', 'docs',
  '--artifact-folder', 'docs',
  '--memory-folder', 'docs/_bmad/_memory',
];

const MANUAL_COMMAND =
  'npx bmad-method install --modules core,bmm --tools claude-code' +
  ' --output-folder docs --artifact-folder docs --memory-folder docs/_bmad/_memory';

function makeNoopSpinner() {
  return {
    start() {},
    stop() {},
  };
}

function printManualCommand(log, errorOutput) {
  if (errorOutput) {
    log(`\nBMAD install error: ${errorOutput}`);
  }
  log('\nBMAD installation failed. Run this command to install manually:\n');
  log(`  ${MANUAL_COMMAND}\n`);
  log('Or proceed without BMAD now and update later with: npx bmad-method update');
}

/**
 * Run `npx bmad-method install` non-interactively with the flags required by Ralph Loop.
 *
 * @param {object} [options]
 * @param {object}   [options.spinner]   - external @clack/prompts spinner (start/stop); created internally if omitted
 * @param {boolean}  [options.isTTY]     - whether stdout is a TTY; defaults to process.stdout.isTTY
 * @param {Function} [options.execFile]  - injectable promisified execFile (for testing)
 * @param {Function} [options.log]       - injectable logger (for testing); defaults to console.log
 * @returns {Promise<{success: boolean, error?: string}>}
 */
export async function installBmad(options = {}) {
  const isTTY = options.isTTY ?? process.stdout.isTTY ?? false;
  const execFn = options.execFile ?? execFileAsync;
  const log = options.log ?? console.log;

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
    await execFn(BMAD_COMMAND, BMAD_ARGS);
    s.stop('BMAD modules installed.');
    return { success: true };
  } catch (err) {
    s.stop('BMAD installation failed.');
    printManualCommand(log, err?.stderr ?? err?.message ?? '');
    return { success: true };
  }
}
