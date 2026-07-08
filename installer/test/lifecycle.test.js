/**
 * Installer lifecycle-correctness slice (2026-07-04): end-to-end CLI behavior for
 * the L1–L11 fixes that span bin/ralph.js and multiple modules.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { runCli, createEmptyFixture, createExistingProjectFixture } from './fixtures.js';
import { writeInstall, computeCreatedDirs } from '../src/writer.js';
import { pruneEmptyInstallerDirs } from '../src/uninstall.js';
import { runDoctor } from '../src/doctor.js';
import { printOutro } from '../src/outro.js';

async function makeTempDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'ralph-lifecycle-'));
}

// ─── L10: bare `ralph` → help on STDOUT, exit 0 ───────────────────────────────

test('L10: bare `ralph` prints help to stdout and exits 0', () => {
  const result = runCli([]);
  assert.equal(result.exitCode, 0, 'bare invocation must exit 0, not 1');
  assert.ok(result.stdout.length > 0, 'help must go to stdout');
  assert.ok(result.stdout.includes('Usage'), 'stdout should carry the usage block');
  assert.equal(result.stderr.trim(), '', 'nothing should go to stderr');
});

// ─── L8: --update-conflicts is validated on the fresh-install path too ────────

test('L8: invalid --update-conflicts on a fresh install errors (was silently ignored)', async () => {
  const { dir, cleanup } = await createEmptyFixture();
  try {
    const result = runCli(['install', '-d', dir, '--yes', '--use-bmad', 'no', '--update-conflicts', 'bogus']);
    assert.notEqual(result.exitCode, 0, 'a bogus value must fail regardless of target state');
    assert.ok(/update-conflicts/.test(result.stdout + result.stderr));
  } finally {
    await cleanup();
  }
});

// ─── L5: existing project with a .gitignore installs WITHOUT --force ──────────

test('L5: install into a project with a .gitignore succeeds without --force and appends', async () => {
  const { dir, cleanup } = await createExistingProjectFixture();
  try {
    await fs.writeFile(path.join(dir, '.gitignore'), 'node_modules/\ndist/\n', 'utf8');

    const result = runCli(['install', '-d', dir, '--yes', '--use-bmad', 'no']);
    assert.equal(result.exitCode, 0, 'a pre-existing .gitignore must not hard-fail install');

    const gitignore = await fs.readFile(path.join(dir, '.gitignore'), 'utf8');
    assert.ok(gitignore.includes('node_modules/'), 'user entries preserved');
    assert.ok(gitignore.includes('# Ergane'), 'ergane section appended');
  } finally {
    await cleanup();
  }
});

// ─── L11a: nested install is refused non-interactively without --force ────────

test('L11a: nested install under an existing install is refused with --yes (no --force)', async () => {
  const parent = await makeTempDir();
  try {
    const install = runCli(['install', '-d', parent, '--yes', '--use-bmad', 'no']);
    assert.equal(install.exitCode, 0, 'parent install should succeed');

    const sub = path.join(parent, 'sub');
    await fs.mkdir(sub, { recursive: true });

    const nested = runCli(['install', '-d', sub, '--yes', '--use-bmad', 'no']);
    assert.notEqual(nested.exitCode, 0, 'nested install must refuse non-interactively');
    assert.ok(/nested|existing Ergane install/i.test(nested.stdout + nested.stderr));

    // --force lets it through.
    const forced = runCli(['install', '-d', sub, '--yes', '--force', '--use-bmad', 'no']);
    assert.equal(forced.exitCode, 0, '--force allows the nested install');
  } finally {
    await fs.rm(parent, { recursive: true, force: true });
  }
});

// ─── L2 + L7: update --yes preserves the user's config and reports no-op ───────

test('L2/L7: update --yes preserves custom config byte-for-byte and says up to date', async () => {
  const { dir, cleanup } = await createEmptyFixture();
  try {
    const install = runCli([
      'install', '-d', dir, '--yes', '--use-bmad', 'no',
      '--app-dir', 'myapp',
      '--stack-description', 'Vue 3 + Vite (custom)',
      '--checkpoint-command', 'pnpm build && pnpm test',
    ]);
    assert.equal(install.exitCode, 0);

    const before = await fs.readFile(path.join(dir, 'docs', 'project-conventions.md'), 'utf8');
    assert.ok(before.includes('Vue 3 + Vite (custom)'));
    assert.ok(before.includes('pnpm build && pnpm test'));

    const update = runCli(['update', '-d', dir, '--yes']);
    assert.equal(update.exitCode, 0);
    assert.ok(/Already up to date/i.test(update.stdout), 'same version + no drift → up to date');

    const after = await fs.readFile(path.join(dir, 'docs', 'project-conventions.md'), 'utf8');
    assert.equal(after, before, 'update --yes must change nothing the user configured');
  } finally {
    await cleanup();
  }
});

// ─── L3: a corrupted manifest is reported honestly by update ──────────────────

test('L3: `update` on a corrupted manifest reports corruption (exit 1), not "up to date"', async () => {
  const { dir, cleanup } = await createEmptyFixture();
  try {
    runCli(['install', '-d', dir, '--yes', '--use-bmad', 'no']);
    await fs.writeFile(path.join(dir, '.ralph', 'manifest.json'), '{corrupt', 'utf8');

    const result = runCli(['update', '-d', dir, '--yes']);
    assert.notEqual(result.exitCode, 0, 'corruption must not be hidden as success');
    assert.ok(/corrupted/i.test(result.stdout + result.stderr), 'must say the manifest is corrupted');
  } finally {
    await cleanup();
  }
});

// ─── L4: a failed BMAD step degrades the banner (never unqualified success) ────

test('L4: BMAD failure degrades the install banner and never claims plain success', () => {
  const logs = [];
  const bmadFailedResult = { status: 'success', filesWritten: 5, manifest: {}, bmadFailed: true };
  printOutro(
    bmadFailedResult,
    { targetDir: '/proj', classification: 'empty', skipBmad: false, appDir: 'src', taskSource: 'scaffold' },
    (m = '') => logs.push(m),
  );
  const out = logs.join('\n');
  assert.ok(/needing attention/i.test(out), 'banner must state the degraded state');
  assert.ok(!/installed successfully/.test(out), 'must NOT print an unqualified success banner');
});

test('L4: writeInstall threads a BMAD failure into result.bmadFailed', async () => {
  const dir = await makeTempDir();
  try {
    const plan = {
      targetDir: dir,
      classification: 'empty',
      appDir: 'src',
      checkpointCommand: 'npm test',
      stackDescription: 'React',
      taskSource: 'scaffold',
      addGitignoreEntries: false,
      wizardAnswers: {},
      skipBmad: false,
      yes: true,
      force: false,
    };
    const result = await writeInstall(plan, {
      log: () => {},
      installBmad: async () => ({ success: false, error: "unknown option '--artifact-folder'" }),
    });
    assert.equal(result.status, 'success', 'install itself still completes');
    assert.equal(result.bmadFailed, true, 'a failed BMAD step is surfaced on the result');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── L1: uninstall prunes ONLY installer-created dirs, not pre-existing ones ────

test('L1: pruneEmptyInstallerDirs preserves a user-created dir absent from createdDirs', async () => {
  const dir = await makeTempDir();
  try {
    // docs/ pre-existed (user made it); scripts/prompts/ was installer-created.
    // Both are empty at prune time (files already removed).
    await fs.mkdir(path.join(dir, 'docs', 'epics'), { recursive: true });
    await fs.mkdir(path.join(dir, 'scripts', 'prompts'), { recursive: true });

    const relPaths = ['docs/epics/x.md', 'scripts/prompts/a.txt'];
    // Installer created docs/epics + scripts + scripts/prompts, but NOT docs/ (user's).
    const createdDirs = ['docs/epics', 'scripts', 'scripts/prompts'];

    const removed = await pruneEmptyInstallerDirs(dir, relPaths, createdDirs);

    const docsExists = await fs.access(path.join(dir, 'docs')).then(() => true).catch(() => false);
    assert.ok(docsExists, 'a user-created dir absent from createdDirs must survive uninstall');

    const epicsGone = await fs.access(path.join(dir, 'docs', 'epics')).then(() => false).catch(() => true);
    assert.ok(epicsGone, 'an installer-created empty dir must be pruned');
    const scriptsGone = await fs.access(path.join(dir, 'scripts')).then(() => false).catch(() => true);
    assert.ok(scriptsGone, 'installer-created scripts tree must be pruned');
    assert.ok(removed.includes('docs/epics') && !removed.includes('docs'), 'only created dirs reported removed');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('L1: pruneEmptyInstallerDirs with empty createdDirs removes nothing', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'docs', 'epics'), { recursive: true });
    const removed = await pruneEmptyInstallerDirs(dir, ['docs/epics/x.md'], []);
    assert.deepEqual(removed, [], 'an empty createdDirs list means the install created no dirs to prune');
    const stillThere = await fs.access(path.join(dir, 'docs', 'epics')).then(() => true).catch(() => false);
    assert.ok(stillThere, 'no pre-existing dir may be removed when createdDirs is empty');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('L1: computeCreatedDirs excludes ancestor dirs that already exist', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'docs'), { recursive: true }); // pre-existing
    const created = await computeCreatedDirs(dir, ['docs/epics/x.md', 'scripts/prompts/a.txt']);
    assert.ok(!created.includes('docs'), 'a pre-existing dir is not recorded as installer-created');
    assert.ok(created.includes('docs/epics'), 'a newly-needed subdir is recorded');
    assert.ok(created.includes('scripts') && created.includes('scripts/prompts'), 'new dirs recorded');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('L1: an install records createdDirs in its manifest', async () => {
  const { dir, cleanup } = await createEmptyFixture();
  try {
    const result = runCli(['install', '-d', dir, '--yes', '--use-bmad', 'no']);
    assert.equal(result.exitCode, 0, `install failed: ${result.stderr}`);
    const manifest = JSON.parse(await fs.readFile(path.join(dir, '.ralph', 'manifest.json'), 'utf8'));
    assert.ok(Array.isArray(manifest.createdDirs), 'manifest records createdDirs');
    assert.ok(manifest.createdDirs.includes('scripts'), 'installer-created scripts dir recorded');
  } finally {
    await cleanup();
  }
});

// ─── L6: every doctor FAIL carries a one-line remediation command ──────────────

test('L6: jq/claude FAIL findings each carry a remediation command', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
    await fs.writeFile(
      path.join(dir, '.ralph', 'manifest.json'),
      JSON.stringify({ version: '0.0.0', installedAt: 'x', files: {}, wizardAnswers: {} }),
      'utf8',
    );

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: async () => ({ found: false }),
      checkGhAuth: async () => ({ authenticated: false }),
    });

    const jq = findings.find((f) => f.check === 'jq-available');
    const claude = findings.find((f) => f.check === 'claude-cli-available');
    assert.equal(jq.status, 'fail');
    assert.equal(claude.status, 'fail');
    assert.ok(/remediation/i.test(jq.message) && /install/i.test(jq.message), 'jq FAIL must carry a remediation command');
    assert.ok(/remediation/i.test(claude.message) && /npm install/i.test(claude.message), 'claude FAIL must carry a remediation command');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
