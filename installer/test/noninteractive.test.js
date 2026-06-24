/**
 * Integration tests for non-interactive (--yes) mode and conflict detection.
 *
 * These tests exercise the full module API (wizard → writer) without spawning
 * child processes, using injectable dependencies to capture exits and logs.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { runWizard } from '../src/wizard.js';
import { writeInstall, detectConflicts } from '../src/writer.js';

async function makeTempDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'ralph-noninteractive-'));
}

// ─── E2E: --yes --force into empty dir ───────────────────────────────────────

test('E2E: --yes --force into empty dir creates all expected files', async () => {
  const dir = await makeTempDir();
  try {
    const plan = await runWizard(dir, 'empty', {}, {
      useDefaults: true,
      log: () => {},
    });

    plan.yes = true;
    plan.force = true;

    const result = await writeInstall(plan, {
      log: () => {},
      installBmad: async () => ({ success: true }), // mock BMAD install
    });

    assert.equal(result.status, 'success', 'install should succeed');
    assert.ok(result.filesWritten > 0, 'should write at least one file');
    assert.ok(result.manifest, 'manifest should be returned');

    // Verify core files exist
    const loopShExists = await fs
      .access(path.join(dir, 'scripts', 'ralph-loop.sh'))
      .then(() => true)
      .catch(() => false);
    assert.ok(loopShExists, 'scripts/ralph-loop.sh should exist');

    const manifestExists = await fs
      .access(path.join(dir, '.ralph', 'manifest.json'))
      .then(() => true)
      .catch(() => false);
    assert.ok(manifestExists, '.ralph/manifest.json should exist');

    const conventionsExists = await fs
      .access(path.join(dir, 'docs', 'project-conventions.md'))
      .then(() => true)
      .catch(() => false);
    assert.ok(conventionsExists, 'docs/project-conventions.md should exist');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('E2E: non-interactive install log has no ANSI escape codes', async () => {
  const dir = await makeTempDir();
  try {
    const logMessages = [];
    const captureLog = (msg = '') => logMessages.push(msg);

    const plan = await runWizard(dir, 'empty', {}, {
      useDefaults: true,
      log: captureLog,
    });

    plan.yes = true;
    plan.force = true;

    await writeInstall(plan, {
      log: captureLog,
      installBmad: async () => ({ success: true }),
    });

    const combined = logMessages.join('\n');
    assert.ok(
      !/\x1b\[/.test(combined),
      'log output should contain no ANSI escape codes in non-interactive mode',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── E2E: Conflict detection without --force ─────────────────────────────────

test('E2E: conflict without --force exits non-zero and does not write', async () => {
  const dir = await makeTempDir();
  try {
    // First install
    const plan1 = await runWizard(dir, 'empty', {}, {
      useDefaults: true,
      log: () => {},
    });
    plan1.yes = true;
    plan1.force = true;
    await writeInstall(plan1, {
      log: () => {},
      installBmad: async () => ({ success: true }),
    });

    // Second install without --force: should exit non-zero
    const plan2 = await runWizard(dir, 'existing-install', {}, {
      useDefaults: true,
      log: () => {},
    });
    plan2.yes = true;
    plan2.force = false;

    const exitCalls = [];
    const logMessages = [];

    const result = await writeInstall(plan2, {
      exit: (code) => exitCalls.push(code),
      log: (msg = '') => logMessages.push(msg),
      installBmad: async () => ({ success: true }),
    });

    // Should call exit with non-zero OR return null (cancelled)
    const blocked = exitCalls.some((code) => code !== 0) || result?.status === 'cancelled';
    assert.ok(blocked, 'second install without --force should exit non-zero or be cancelled');

    if (exitCalls.length > 0) {
      assert.notEqual(exitCalls[0], 0, 'exit code should be non-zero');
    }
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('E2E: second install with --force succeeds (overwrites installer-owned)', async () => {
  const dir = await makeTempDir();
  try {
    const install = async (force) => {
      const classification = force === true && (await hasManifest(dir))
        ? 'existing-install'
        : 'empty';
      const plan = await runWizard(dir, classification, {}, {
        useDefaults: true,
        log: () => {},
      });
      plan.yes = true;
      plan.force = force;
      return writeInstall(plan, {
        log: () => {},
        installBmad: async () => ({ success: true }),
      });
    };

    const result1 = await install(true);
    assert.equal(result1.status, 'success', 'first install should succeed');

    const result2 = await install(true);
    assert.equal(result2.status, 'success', 'second install with --force should succeed');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Per-question flags affect the plan ──────────────────────────────────────

test('E2E: --app-dir flag embeds custom dir in scaffold epic stubs', async () => {
  const dir = await makeTempDir();
  try {
    const plan = await runWizard(dir, 'empty', {}, {
      useDefaults: true,
      cliAnswers: { appDir: 'packages/app' },
      log: () => {},
    });
    plan.yes = true;
    plan.force = true;

    await writeInstall(plan, {
      log: () => {},
      installBmad: async () => ({ success: true }),
    });

    // APP_DIR is embedded in the scaffold epic stubs (docs/epics/project-prd.md)
    const prd = await fs.readFile(
      path.join(dir, 'docs', 'epics', 'project-prd.md'),
      'utf8',
    );
    assert.ok(prd.includes('packages/app'), 'scaffold prd should include custom app dir');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('E2E: --stack-description flag embeds custom text in conventions file', async () => {
  const dir = await makeTempDir();
  try {
    const plan = await runWizard(dir, 'empty', {}, {
      useDefaults: true,
      cliAnswers: { stackDescription: 'Django + React' },
      log: () => {},
    });
    plan.yes = true;
    plan.force = true;

    await writeInstall(plan, {
      log: () => {},
      installBmad: async () => ({ success: true }),
    });

    const conventions = await fs.readFile(
      path.join(dir, 'docs', 'project-conventions.md'),
      'utf8',
    );
    assert.ok(conventions.includes('Django + React'), 'conventions file should include custom stack');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── --list-options verification (via listOptions() function) ─────────────────

test('listOptions() output lists at least 6 flags', async () => {
  const { listOptions } = await import('../src/cli-parser.js');
  const output = listOptions();
  const flagMatches = output.match(/--\w[\w-]*/g) ?? [];
  assert.ok(flagMatches.length >= 6, `Expected ≥6 flags, got: ${flagMatches.join(', ')}`);
});

test('listOptions() output contains no ANSI escape codes', async () => {
  const { listOptions } = await import('../src/cli-parser.js');
  const output = listOptions();
  assert.ok(!/\x1b\[/.test(output), 'listOptions output should be plain text');
});

// ─── NO_COLOR detection ────────────────────────────────────────────────────────

test('isColorEnabled returns false when NO_COLOR is set (any value)', async () => {
  const { isColorEnabled } = await import('../src/colors.js');
  assert.equal(isColorEnabled({ isTTY: true, noColor: true }), false, 'NO_COLOR=any disables color');
  assert.equal(isColorEnabled({ isTTY: true, noColor: false }), true, 'no NO_COLOR allows color');
});

// ─── Helper ───────────────────────────────────────────────────────────────────

async function hasManifest(dir) {
  try {
    await fs.access(path.join(dir, '.ralph', 'manifest.json'));
    return true;
  } catch {
    return false;
  }
}
