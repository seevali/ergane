/**
 * Fixture helpers for E2E tests.
 *
 * Provides temporary directory management, CLI subprocess runner, and standard
 * fixture states (empty, existing-project, installed). Each fixture returns a
 * cleanup() function that callers must invoke in a finally block.
 */
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** Absolute path to the installer package root (installer/). */
export const INSTALLER_ROOT = path.resolve(__dirname, '..');

/** Absolute path to the repo root (two levels above installer/). */
export const REPO_ROOT = path.resolve(INSTALLER_ROOT, '../..');

const RALPH_BIN = path.join(INSTALLER_ROOT, 'bin', 'ralph.js');

/**
 * Spawn the ralph CLI as a subprocess and capture its output.
 *
 * stdout and stderr are piped — the child process is not connected to a TTY,
 * so process.stdout.isTTY is undefined (falsy) in the child. Combined with
 * NO_COLOR=1, this guarantees no ANSI codes in captured output.
 *
 * @param {string[]} args - CLI arguments (e.g. ['install', '--directory', dir, '--yes'])
 * @param {object} [opts]
 * @param {string} [opts.cwd] - working directory (default: REPO_ROOT)
 * @param {number} [opts.timeout] - timeout in ms (default: 30000)
 * @param {boolean} [opts.noColor] - set NO_COLOR=1 (default: true)
 * @returns {{ exitCode: number, stdout: string, stderr: string, timedOut: boolean }}
 */
export function runCli(args, opts = {}) {
  const { cwd = REPO_ROOT, timeout = 30000, noColor = true } = opts;

  const env = { ...process.env };
  if (noColor) env.NO_COLOR = '1';

  const result = spawnSync(process.execPath, [RALPH_BIN, ...args], {
    cwd,
    timeout,
    env,
    encoding: 'utf8',
  });

  return {
    exitCode: result.status ?? 1,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    timedOut: result.status === null,
  };
}

/**
 * Spawn a bash script as a subprocess and capture its output.
 *
 * @param {string[]} args - arguments to bash (first element is the script path)
 * @param {object} [opts]
 * @param {string} [opts.cwd] - working directory (default: REPO_ROOT)
 * @param {number} [opts.timeout] - timeout in ms (default: 10000)
 * @returns {{ exitCode: number, stdout: string, stderr: string }}
 */
export function runBash(args, opts = {}) {
  const { cwd = REPO_ROOT, timeout = 10000 } = opts;

  const result = spawnSync('bash', args, {
    cwd,
    timeout,
    encoding: 'utf8',
  });

  return {
    exitCode: result.status ?? 1,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
  };
}

/**
 * Create an empty temporary directory.
 * Initial state: no .git, no package.json, no manifest.
 *
 * @returns {Promise<{ dir: string, cleanup: () => Promise<void> }>}
 */
export async function createEmptyFixture() {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'ralph-e2e-'));
  return {
    dir,
    async cleanup() {
      await fs.rm(dir, { recursive: true, force: true });
    },
  };
}

/**
 * Create a temporary directory that looks like an existing project.
 * Includes a .git/ stub and a minimal package.json to trigger
 * the 'existing-project' classification.
 *
 * @returns {Promise<{ dir: string, cleanup: () => Promise<void> }>}
 */
export async function createExistingProjectFixture() {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'ralph-e2e-'));
  await fs.mkdir(path.join(dir, '.git'), { recursive: true });
  await fs.writeFile(
    path.join(dir, 'package.json'),
    JSON.stringify({ name: 'test-project', version: '1.0.0' }, null, 2),
    'utf8',
  );
  return {
    dir,
    async cleanup() {
      await fs.rm(dir, { recursive: true, force: true });
    },
  };
}

/**
 * Create a temporary directory and run a complete ralph install into it.
 * BMAD install is skipped (--use-bmad no) to avoid network calls in tests.
 *
 * @param {string[]} [extraArgs] - additional CLI args appended after the base install args
 * @returns {Promise<{ dir: string, cleanup: () => Promise<void>, manifest: object }>}
 */
export async function createInstalledFixture(extraArgs = []) {
  const { dir, cleanup } = await createEmptyFixture();

  const result = runCli([
    'install',
    '--directory', dir,
    '--yes',
    '--use-bmad', 'no',
    ...extraArgs,
  ]);

  if (result.exitCode !== 0) {
    await cleanup();
    throw new Error(
      `Fixture install failed (exit ${result.exitCode}):\n` +
      `stdout: ${result.stdout}\nstderr: ${result.stderr}`,
    );
  }

  const manifestPath = path.join(dir, '.ralph', 'manifest.json');
  const manifest = JSON.parse(await fs.readFile(manifestPath, 'utf8'));

  return { dir, cleanup, manifest };
}

/** Read a file's UTF-8 content. Thin wrapper for convenience in tests. */
export async function readFile(filePath) {
  return fs.readFile(filePath, 'utf8');
}

/** Write UTF-8 content to a file, creating parent directories as needed. */
export async function writeFile(filePath, content) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, content, 'utf8');
}
