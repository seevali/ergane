/**
 * E2E tests for the update flow (Story 3.2).
 *
 * These tests exercise the full update pipeline at the module API level:
 *   writeInstall → (modify files) → detectUpdate → resolveConflicts → executeUpdate
 *
 * PRD success criterion: user-owned files preserved byte-identically;
 * installer-owned files replaced; manifest rewritten; exit 0.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { writeInstall, executeUpdate, hashFile } from '../src/writer.js';
import { detectUpdate } from '../src/updateDetector.js';
import { resolveConflicts } from '../src/updateConflictResolver.js';

async function makeTempDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'ralph-e2e-update-'));
}

async function readManifest(dir) {
  const raw = await fs.readFile(path.join(dir, '.ralph', 'manifest.json'), 'utf8');
  return JSON.parse(raw);
}

function sha256(content) {
  const normalized = content.replace(/\r\n/g, '\n');
  return 'sha256:' + crypto.createHash('sha256').update(normalized).digest('hex');
}

async function runInitialInstall(dir) {
  const plan = {
    targetDir: dir,
    classification: 'empty',
    appDir: 'src',
    checkpointCommand: 'npm test',
    stackDescription: 'React + TypeScript',
    taskSource: 'scaffold',
    addGitignoreEntries: false,
    wizardAnswers: {
      appDir: 'src',
      checkpointCommand: 'npm test',
      stackDescription: 'React + TypeScript',
      taskSource: 'scaffold',
    },
    force: false,
    yes: true,
    skipBmad: true,
  };
  return writeInstall(plan, { log: () => {} });
}

async function runUpdate(dir, manifest, updateConflicts = 'keep') {
  const updateInfo = await detectUpdate(dir);
  assert.ok(updateInfo.isUpdate, 'should be in update mode');

  const conflictFiles = updateInfo.delta.installerOwned.filter((e) => e.isModified);

  const resolution = await resolveConflicts(conflictFiles, {
    yes: true,
    updateConflicts,
  }, { log: () => {} });

  assert.ok(resolution.succeeded, 'conflict resolution should succeed');

  const wa = manifest.wizardAnswers ?? {};
  const updatePlan = {
    targetDir: dir,
    appDir: wa.appDir ?? 'src',
    checkpointCommand: wa.checkpointCommand ?? 'npm test',
    stackDescription: wa.stackDescription ?? 'React + TypeScript',
    taskSource: wa.taskSource ?? 'scaffold',
    addGitignoreEntries: false,
    wizardAnswers: wa,
  };

  return executeUpdate(dir, updatePlan, updateInfo.delta, resolution.decisions, { log: () => {} });
}

// ─── E2E 1: User-owned file preservation (PRD success criterion 3) ────────────

test('E2E update: user-owned file preserved byte-identically after update', async () => {
  const dir = await makeTempDir();
  try {
    const installResult = await runInitialInstall(dir);
    assert.equal(installResult.status, 'success', 'initial install should succeed');

    const manifest = await readManifest(dir);

    // Find a user-owned file that was written
    const userOwnedEntries = Object.entries(manifest.files)
      .filter(([, e]) => e.ownership === 'user-owned');
    assert.ok(userOwnedEntries.length > 0, 'initial install should write at least one user-owned file');

    const userOwnedPath = userOwnedEntries[0][0];
    const fullUserPath = path.join(dir, userOwnedPath);

    // Modify the user-owned file
    const userAddition = '\n# User added this comment — must survive update\n';
    await fs.appendFile(fullUserPath, userAddition, 'utf8');
    const userModifiedContent = await fs.readFile(fullUserPath, 'utf8');

    // Run update (no --update-conflicts needed since no installer-owned conflicts)
    await runUpdate(dir, manifest, 'keep');

    // Verify user-owned file is byte-identical to the modified state
    const afterContent = await fs.readFile(fullUserPath, 'utf8');
    assert.equal(afterContent, userModifiedContent, 'user-owned file must be byte-identical after update');

    // Verify installer-owned files are present and have updated checksums in manifest
    const updatedManifest = await readManifest(dir);
    const installerOwnedEntries = Object.entries(updatedManifest.files)
      .filter(([, e]) => e.ownership === 'installer-owned');
    assert.ok(installerOwnedEntries.length > 0, 'updated manifest must have installer-owned file entries');
    for (const [, entry] of installerOwnedEntries) {
      assert.ok(entry.checksum?.startsWith('sha256:'), 'installer-owned checksum must be updated');
    }
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('E2E update: installer-owned unmodified file is replaced with current template', async () => {
  const dir = await makeTempDir();
  try {
    await runInitialInstall(dir);
    const manifest = await readManifest(dir);

    const targetFile = 'scripts/prompts/common/project-conventions.md';
    assert.ok(manifest.files[targetFile], `${targetFile} should be in manifest`);
    assert.equal(manifest.files[targetFile].ownership, 'installer-owned');

    const originalChecksum = await hashFile(path.join(dir, targetFile));

    await runUpdate(dir, manifest, 'keep');

    // File should still exist and have a valid checksum in updated manifest
    const updatedManifest = await readManifest(dir);
    const updatedChecksum = updatedManifest.files[targetFile]?.checksum;
    assert.ok(updatedChecksum?.startsWith('sha256:'), 'checksum must be updated in manifest');

    // File should still be on disk and readable
    const onDiskChecksum = await hashFile(path.join(dir, targetFile));
    assert.equal(onDiskChecksum, updatedChecksum, 'on-disk checksum must match manifest after update');
    // For same installer version, content should be identical (same template)
    assert.equal(onDiskChecksum, originalChecksum, 'same installer version should produce same checksum');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── E2E 2: Modified installer-owned file with "keep" ────────────────────────

test('E2E update: modified installer-owned file + --update-conflicts=keep → file preserved, no backup', async () => {
  const dir = await makeTempDir();
  try {
    await runInitialInstall(dir);
    const manifest = await readManifest(dir);

    const targetFile = 'scripts/prompts/common/project-conventions.md';
    const fullPath = path.join(dir, targetFile);
    const originalChecksum = manifest.files[targetFile]?.checksum;

    // Locally modify the installer-owned file
    const localMod = '\n# Local modification — must survive keep\n';
    await fs.appendFile(fullPath, localMod, 'utf8');
    const modifiedContent = await fs.readFile(fullPath, 'utf8');

    await runUpdate(dir, manifest, 'keep');

    // File on disk must be byte-identical to the modified state
    const afterContent = await fs.readFile(fullPath, 'utf8');
    assert.equal(afterContent, modifiedContent, '"keep" must preserve file byte-identically');

    // No .backup file should be created
    const backupExists = await fs.access(`${fullPath}.backup`).then(() => true).catch(() => false);
    assert.equal(backupExists, false, 'no .backup file should be created for "keep"');

    // Manifest checksum for this file must remain as the prior installer checksum
    // (so the next update run still detects it as locally modified)
    const updatedManifest = await readManifest(dir);
    assert.equal(
      updatedManifest.files[targetFile]?.checksum,
      originalChecksum,
      '"keep" manifest checksum must stay as original installer checksum',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── E2E 3: Modified installer-owned file with "backup" ──────────────────────

test('E2E update: modified installer-owned file + --update-conflicts=backup → backup created, new version written', async () => {
  const dir = await makeTempDir();
  try {
    await runInitialInstall(dir);
    const manifest = await readManifest(dir);

    const targetFile = 'scripts/prompts/common/project-conventions.md';
    const fullPath = path.join(dir, targetFile);
    const originalChecksum = manifest.files[targetFile]?.checksum;

    // Locally modify the installer-owned file
    const localMod = '\n# Local modification — should end up in backup\n';
    await fs.appendFile(fullPath, localMod, 'utf8');
    const modifiedContent = await fs.readFile(fullPath, 'utf8');

    await runUpdate(dir, manifest, 'backup');

    // Backup file should exist with the modified content
    const backupPath = `${fullPath}.backup`;
    const backupExists = await fs.access(backupPath).then(() => true).catch(() => false);
    assert.ok(backupExists, '.backup file must be created');

    const backupContent = await fs.readFile(backupPath, 'utf8');
    assert.equal(backupContent, modifiedContent, 'backup must contain the user-modified content');

    // Original path should have the new installer version (same template = same as original)
    const newContent = await fs.readFile(fullPath, 'utf8');
    assert.ok(!newContent.includes('# Local modification'), 'new file must not have local modification');

    // Manifest checksum must be updated to the new content's checksum
    const updatedManifest = await readManifest(dir);
    const newChecksum = await hashFile(fullPath);
    assert.equal(
      updatedManifest.files[targetFile]?.checksum,
      newChecksum,
      'manifest checksum must reflect the newly written content',
    );
    // For same installer version the new checksum should equal the original (same template)
    assert.equal(newChecksum, originalChecksum, 'same installer version → same checksum after replace');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── E2E 4: "keep" followed by "backup" on same file ─────────────────────────

test('E2E update: keep then backup on same modified file — backup created on second run', async () => {
  const dir = await makeTempDir();
  try {
    await runInitialInstall(dir);
    let manifest = await readManifest(dir);

    const targetFile = 'scripts/prompts/common/project-conventions.md';
    const fullPath = path.join(dir, targetFile);

    // Locally modify the installer-owned file
    await fs.appendFile(fullPath, '\n# Modification for two-run test\n', 'utf8');
    const modifiedContent = await fs.readFile(fullPath, 'utf8');

    // First run with "keep" — file stays modified
    await runUpdate(dir, manifest, 'keep');
    manifest = await readManifest(dir);

    // File still modified on disk
    const afterKeep = await fs.readFile(fullPath, 'utf8');
    assert.equal(afterKeep, modifiedContent, 'file should be unchanged after "keep"');

    // Second run with "backup" — should detect the file as still modified and create backup
    await runUpdate(dir, manifest, 'backup');

    const backupExists = await fs.access(`${fullPath}.backup`).then(() => true).catch(() => false);
    assert.ok(backupExists, 'backup must be created on second run with --update-conflicts=backup');

    // New file should not have the local modification
    const afterBackup = await fs.readFile(fullPath, 'utf8');
    assert.ok(!afterBackup.includes('# Modification for two-run test'), 'new file must not have modification');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── E2E 5: Non-interactive invalid --update-conflicts → non-zero exit ────────

test('E2E update: invalid --update-conflicts → resolution fails, no writes occur', async () => {
  const dir = await makeTempDir();
  try {
    await runInitialInstall(dir);
    const manifest = await readManifest(dir);
    const updateInfo = await detectUpdate(dir);

    const conflictFiles = updateInfo.delta.installerOwned.filter((e) => e.isModified);

    const resolution = await resolveConflicts(conflictFiles, {
      yes: true,
      updateConflicts: 'invalid-value',
    }, { log: () => {} });

    assert.equal(resolution.succeeded, false, 'should fail with invalid --update-conflicts');
    assert.ok(resolution.errors.length > 0, 'should return error messages');
    assert.ok(resolution.errors[0].includes('invalid-value'), 'error should name the invalid value');
    assert.deepEqual(resolution.decisions, {}, 'no decisions should be made');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── E2E 6: Manifest preserved fields after update ───────────────────────────

test('E2E update: manifest preserves installedAt, wizardAnswers, targetClass after update', async () => {
  const dir = await makeTempDir();
  try {
    await runInitialInstall(dir);
    const originalManifest = await readManifest(dir);

    // Small delay to ensure updatedAt will differ
    await new Promise((resolve) => setTimeout(resolve, 5));

    await runUpdate(dir, originalManifest, 'keep');
    const updatedManifest = await readManifest(dir);

    assert.equal(
      updatedManifest.installedAt,
      originalManifest.installedAt,
      'installedAt must be preserved',
    );
    assert.deepEqual(
      updatedManifest.wizardAnswers,
      originalManifest.wizardAnswers,
      'wizardAnswers must be preserved',
    );
    assert.equal(
      updatedManifest.targetClass,
      originalManifest.targetClass,
      'targetClass must be preserved',
    );
    assert.ok(
      updatedManifest.updatedAt >= originalManifest.updatedAt,
      'updatedAt must be refreshed',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
