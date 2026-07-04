/**
 * E2E test suite for the Ralph Loop installer.
 *
 * Validates the complete install → doctor → update → uninstall cycle through
 * the CLI binary using non-interactive mode (--yes). Each test maps directly
 * to a PRD success criterion (1–5) plus a bonus uninstall test.
 *
 * Run: cd installer && npm test
 * Expected: all 8 tests pass, exit 0.
 */
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import {
  createEmptyFixture,
  createInstalledFixture,
  runCli,
  runBash,
  INSTALLER_ROOT,
} from './fixtures.js';
import {
  assertFR6FilesPresent,
  assertEpicStubsParseable,
  assertManifestValid,
  assertNoANSIEscapes,
  assertFilesUnchanged,
  sha256File,
} from './assertions.js';

const SYNC_SCRIPT = path.join(INSTALLER_ROOT, 'scripts', 'sync-templates.sh');
const TEMPLATE_LOOP_SCRIPT = path.join(INSTALLER_ROOT, 'templates', 'loop', 'ralph-loop.sh');
const TEMPLATE_WATCH_SCRIPT = path.join(INSTALLER_ROOT, 'templates', 'loop', 'ralph-watch.sh');

describe('E2E: Ralph Loop Installer', () => {

  // ── PRD criterion 1: empty-dir install verified end-to-end by doctor ──────────

  it('PRD criterion 1: empty-dir E2E with non-interactive install', { timeout: 90000 }, async () => {
    // Fixture: empty temp directory (no git, no manifest, no existing files)
    const { dir, cleanup } = await createEmptyFixture();
    try {
      // Step 1: Non-interactive install into empty directory
      const installResult = runCli([
        'install',
        '--directory', dir,
        '--yes',
        '--use-bmad', 'no',
      ]);

      assert.equal(
        installResult.exitCode, 0,
        `Install exited ${installResult.exitCode}:\nstdout: ${installResult.stdout}\nstderr: ${installResult.stderr}`,
      );

      // Step 2: Doctor validates the installation
      const doctorResult = runCli(['doctor', '--directory', dir], { timeout: 15000 });

      assert.equal(
        doctorResult.exitCode, 0,
        `Doctor exited ${doctorResult.exitCode}:\nstdout: ${doctorResult.stdout}\nstderr: ${doctorResult.stderr}`,
      );

      // Step 3: All FR-6 required files are present
      await assertFR6FilesPresent(dir);

      // Step 4: Epic stub files contain parseable ### Story X.Y: Title headers
      await assertEpicStubsParseable(dir);

      // Step 5: Manifest is structurally valid and checksums match on-disk files
      await assertManifestValid(dir);
    } finally {
      await cleanup();
    }
  });

  // ── PRD criterion 2: --yes simulates accepting all wizard prompts with Enter ──

  it('PRD criterion 2: Enter-only path with --yes defaults', { timeout: 90000 }, async () => {
    // --yes is the automation equivalent of pressing Enter at every wizard prompt:
    // it accepts all defaults without user interaction.
    const { dir, cleanup } = await createEmptyFixture();
    try {
      const installResult = runCli([
        'install',
        '--directory', dir,
        '--yes',
        '--use-bmad', 'no',
      ]);

      assert.equal(
        installResult.exitCode, 0,
        `Install (Enter-only) exited ${installResult.exitCode}:\nstdout: ${installResult.stdout}\nstderr: ${installResult.stderr}`,
      );

      // Doctor confirms the install produced a working setup
      const doctorResult = runCli(['doctor', '--directory', dir], { timeout: 15000 });

      assert.equal(
        doctorResult.exitCode, 0,
        `Doctor exited ${doctorResult.exitCode}:\nstdout: ${doctorResult.stdout}\nstderr: ${doctorResult.stderr}`,
      );
    } finally {
      await cleanup();
    }
  });

  // ── PRD criterion 3: update preserves user-edits byte-identically ─────────────

  it('PRD criterion 3: update safety preserves user-owned files', { timeout: 120000 }, async () => {
    const { dir, cleanup } = await createEmptyFixture();
    try {
      // Step 1: Initial install
      const installResult = runCli([
        'install',
        '--directory', dir,
        '--yes',
        '--use-bmad', 'no',
      ]);
      assert.equal(
        installResult.exitCode, 0,
        `Initial install failed (exit ${installResult.exitCode}):\n${installResult.stderr}`,
      );

      // Step 2: Capture pre-mutation checksums
      // docs/epics/project-prd.md  → user-owned: update NEVER touches it
      // scripts/prompts/common/project-conventions.md → installer-owned; default conflict
      //   resolution for --yes is 'keep', so local edits are preserved
      const prdPath = path.join(dir, 'docs/epics/project-prd.md');
      const promptConvsPath = path.join(dir, 'scripts/prompts/common/project-conventions.md');

      // Step 3: Mutate both files with known additions
      const editMarker = '\n<!-- user-edit-must-survive-update -->\n';
      await fs.appendFile(prdPath, editMarker, 'utf8');
      await fs.appendFile(promptConvsPath, editMarker, 'utf8');

      // Capture checksums of the mutated state — these are the expected post-update state
      const mutatedChecksums = {
        'docs/epics/project-prd.md': await sha256File(prdPath),
        'scripts/prompts/common/project-conventions.md': await sha256File(promptConvsPath),
      };

      // Step 4: Re-run install in the same directory (triggers update path via manifest)
      // --update-conflicts keep → preserve locally-modified installer-owned files
      const updateResult = runCli([
        'install',
        '--directory', dir,
        '--yes',
        '--use-bmad', 'no',
        '--update-conflicts', 'keep',
      ]);
      assert.equal(
        updateResult.exitCode, 0,
        `Update failed (exit ${updateResult.exitCode}):\n${updateResult.stderr}`,
      );

      // Step 5: Both files must be byte-identical to their mutated state
      await assertFilesUnchanged(dir, [
        'docs/epics/project-prd.md',
        'scripts/prompts/common/project-conventions.md',
      ], mutatedChecksums);
    } finally {
      await cleanup();
    }
  });

  // ── PRD criterion 4a: sync gate passes on a clean installer package ───────────

  it('PRD criterion 4a: sync gate passes on fresh install', { timeout: 30000 }, async () => {
    // sync-templates.sh --check verifies that installer/templates/loop/ files
    // match the canonical sources in scripts/. This confirms the installer
    // package ships templates that are in sync with the repo's active scripts.
    const syncResult = runBash([SYNC_SCRIPT, '--check']);

    assert.equal(
      syncResult.exitCode, 0,
      `Sync gate unexpectedly failed (should pass on clean repo):\n` +
      `stdout: ${syncResult.stdout}\nstderr: ${syncResult.stderr}`,
    );
  });

  // ── PRD criterion 4b: sync gate detects drift in a template file ──────────────

  it('PRD criterion 4b: sync gate detects drift', { timeout: 30000 }, async () => {
    // To simulate drift we temporarily corrupt installer/templates/loop/ralph-loop.sh
    // (the synced copy). The sync check compares this template against the canonical
    // scripts/ralph-loop.sh; a difference triggers a non-zero exit.
    // We restore the original content in finally regardless of test outcome.
    const original = await fs.readFile(TEMPLATE_LOOP_SCRIPT, 'utf8');

    try {
      await fs.appendFile(TEMPLATE_LOOP_SCRIPT, '\n# DRIFT-MARKER-INJECTED-BY-TEST\n', 'utf8');

      const syncResult = runBash([SYNC_SCRIPT, '--check']);

      assert.notEqual(
        syncResult.exitCode, 0,
        'Sync gate should have detected drift (expected non-zero exit) but exited 0',
      );
    } finally {
      // Always restore — do NOT leave the template file modified.
      await fs.writeFile(TEMPLATE_LOOP_SCRIPT, original, 'utf8');
    }
  });

  // ── Refresh 4c: sync gate detects drift in the watch script ───────────────────

  it('Refresh: sync gate detects drift in ralph-watch.sh', { timeout: 30000 }, async () => {
    const original = await fs.readFile(TEMPLATE_WATCH_SCRIPT, 'utf8');
    try {
      await fs.appendFile(TEMPLATE_WATCH_SCRIPT, '\n# DRIFT-MARKER-INJECTED-BY-TEST\n', 'utf8');

      const syncResult = runBash([SYNC_SCRIPT, '--check']);

      assert.notEqual(
        syncResult.exitCode, 0,
        'Sync gate should detect drift in ralph-watch.sh (expected non-zero exit) but exited 0',
      );
      assert.ok(
        syncResult.stderr.includes('ralph-watch.sh'),
        `--check should name the drifted watch script; stderr: ${syncResult.stderr}`,
      );
    } finally {
      await fs.writeFile(TEMPLATE_WATCH_SCRIPT, original, 'utf8');
    }
  });

  // ── Refresh: fresh install ships a working, executable ralph-watch.sh ─────────

  it('Refresh: fresh install yields an executable ralph-watch.sh whose `ls` runs', { timeout: 90000 }, async () => {
    const { dir, cleanup } = await createEmptyFixture();
    try {
      const installResult = runCli(['install', '--directory', dir, '--yes', '--use-bmad', 'no']);
      assert.equal(installResult.exitCode, 0, `Install failed: ${installResult.stderr}`);

      const watchPath = path.join(dir, 'scripts', 'ralph-watch.sh');
      const st = await fs.stat(watchPath);
      assert.notEqual(st.mode & 0o111, 0, 'installed ralph-watch.sh must be executable');

      // `./scripts/ralph-watch.sh ls` must run and print the empty-jobs line.
      const lsResult = runBash([watchPath, 'ls'], { cwd: dir, timeout: 10000 });
      assert.equal(lsResult.exitCode, 0, `ralph-watch.sh ls should exit 0; stderr: ${lsResult.stderr}`);
      assert.ok(
        lsResult.stdout.includes('no jobs'),
        `ralph-watch.sh ls should print the empty-jobs line; stdout: ${lsResult.stdout}`,
      );
    } finally {
      await cleanup();
    }
  });

  // ── PRD criterion 5a: non-TTY install output has no ANSI escape codes ─────────

  it('PRD criterion 5a: non-TTY output contains no ANSI codes', { timeout: 90000 }, async () => {
    // runCli() pipes stdout/stderr — the child process has process.stdout.isTTY === undefined.
    // Combined with NO_COLOR=1, picocolors and the installer's isColorEnabled() disable colors.
    const { dir, cleanup } = await createEmptyFixture();
    try {
      const installResult = runCli([
        'install',
        '--directory', dir,
        '--yes',
        '--use-bmad', 'no',
      ]);

      assert.equal(
        installResult.exitCode, 0,
        `Install failed: ${installResult.stderr}`,
      );

      // Both stdout and stderr must be free of ANSI escape sequences
      assertNoANSIEscapes(installResult.stdout);
      assertNoANSIEscapes(installResult.stderr);
    } finally {
      await cleanup();
    }
  });

  // ── PRD criterion 5b: conflict without --force exits non-zero, does not hang ──

  it('PRD criterion 5b: conflict without --force exits non-zero', { timeout: 10000 }, async () => {
    // Pre-existing scripts/ralph-loop.sh triggers a 'file-exists-no-manifest' conflict.
    // With --yes (non-interactive) but no --force, confirmConflicts calls process.exit(1)
    // immediately without writing anything.
    const { dir, cleanup } = await createEmptyFixture();
    try {
      await fs.mkdir(path.join(dir, 'scripts'), { recursive: true });
      await fs.writeFile(
        path.join(dir, 'scripts', 'ralph-loop.sh'),
        '#!/bin/bash\n# pre-existing file that conflicts with the installer\n',
        'utf8',
      );

      const installResult = runCli(
        ['install', '--directory', dir, '--yes', '--use-bmad', 'no'],
        { timeout: 10000 },
      );

      assert.ok(!installResult.timedOut, 'Install must not hang when conflict is detected without --force');

      assert.notEqual(
        installResult.exitCode, 0,
        `Expected non-zero exit due to conflict, but got exit 0\nstdout: ${installResult.stdout}`,
      );
    } finally {
      await cleanup();
    }
  });

  // ── Bonus: uninstall removes installer-owned files ────────────────────────────

  it('bonus: uninstall removes installer-owned files', { timeout: 90000 }, async () => {
    const { dir, cleanup } = await createEmptyFixture();
    try {
      // Step 1: Install
      const installResult = runCli([
        'install',
        '--directory', dir,
        '--yes',
        '--use-bmad', 'no',
      ]);
      assert.equal(
        installResult.exitCode, 0,
        `Install failed: ${installResult.stderr}`,
      );

      // Verify key files exist before uninstall
      await fs.access(path.join(dir, 'scripts', 'ralph-loop.sh'));
      await fs.access(path.join(dir, 'scripts', 'ralph-watch.sh'));
      await fs.access(path.join(dir, '.ralph', 'manifest.json'));

      // Step 2: Uninstall with --yes (preserves user-owned files without prompting)
      const uninstallResult = runCli([
        'uninstall',
        '--directory', dir,
        '--yes',
      ]);
      assert.equal(
        uninstallResult.exitCode, 0,
        `Uninstall failed: ${uninstallResult.stderr}`,
      );

      // Step 3: Installer-owned files must be gone
      const loopShGone = await fs.access(path.join(dir, 'scripts', 'ralph-loop.sh'))
        .then(() => false)
        .catch(() => true);
      assert.ok(loopShGone, 'scripts/ralph-loop.sh must be removed by uninstall');

      const watchShGone = await fs.access(path.join(dir, 'scripts', 'ralph-watch.sh'))
        .then(() => false)
        .catch(() => true);
      assert.ok(watchShGone, 'scripts/ralph-watch.sh must be removed by uninstall');

      const manifestGone = await fs.access(path.join(dir, '.ralph', 'manifest.json'))
        .then(() => false)
        .catch(() => true);
      assert.ok(manifestGone, '.ralph/manifest.json must be removed by uninstall');
    } finally {
      await cleanup();
    }
  });

});
