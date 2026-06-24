import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { detectUpdate } from './updateDetector.js';
import { hashString } from './writer.js';

async function makeTempDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'ralph-update-detector-'));
}

async function writeManifestFixture(dir, manifest) {
  await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
  await fs.writeFile(
    path.join(dir, '.ralph', 'manifest.json'),
    JSON.stringify(manifest, null, 2),
    'utf8',
  );
}

// ─── isUpdate: false when no manifest ────────────────────────────────────────

test('detectUpdate: no manifest → isUpdate false', async () => {
  const dir = await makeTempDir();
  try {
    const result = await detectUpdate(dir);
    assert.equal(result.isUpdate, false, 'should return isUpdate: false when no manifest');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('detectUpdate: malformed manifest → isUpdate false', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
    await fs.writeFile(path.join(dir, '.ralph', 'manifest.json'), 'not valid json', 'utf8');
    const result = await detectUpdate(dir);
    assert.equal(result.isUpdate, false);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── isUpdate: true when manifest present ────────────────────────────────────

test('detectUpdate: valid manifest → isUpdate true with versions', async () => {
  const dir = await makeTempDir();
  try {
    await writeManifestFixture(dir, { version: '1.2.3', files: {} });
    const result = await detectUpdate(dir, { getInstallerVersion: async () => '1.3.0' });
    assert.equal(result.isUpdate, true);
    assert.equal(result.installedVersion, '1.2.3');
    assert.equal(result.availableVersion, '1.3.0');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('detectUpdate: version mismatch detected', async () => {
  const dir = await makeTempDir();
  try {
    await writeManifestFixture(dir, { version: '0.1.0', files: {} });
    const result = await detectUpdate(dir, { getInstallerVersion: async () => '0.2.0' });
    assert.equal(result.installedVersion, '0.1.0');
    assert.equal(result.availableVersion, '0.2.0');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Old manifest format (missing version) ───────────────────────────────────

test('detectUpdate: missing version field → warns and treats as v0.0.0', async () => {
  const dir = await makeTempDir();
  try {
    await writeManifestFixture(dir, { files: {} }); // no version
    const warnings = [];
    const result = await detectUpdate(dir, {
      getInstallerVersion: async () => '1.0.0',
      log: (msg) => warnings.push(msg),
    });
    assert.equal(result.isUpdate, true);
    assert.equal(result.installedVersion, '0.0.0');
    assert.ok(warnings.some(w => w.includes('v0.0.0')), 'should warn about old format');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Delta: isModified detection ─────────────────────────────────────────────

test('detectUpdate: unmodified installer-owned file → isModified false', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'scripts'), { recursive: true });
    const content = '#!/bin/bash\necho hello\n';
    await fs.writeFile(path.join(dir, 'scripts', 'ralph-loop.sh'), content, 'utf8');
    const checksum = hashString(content);

    await writeManifestFixture(dir, {
      version: '1.0.0',
      files: {
        'scripts/ralph-loop.sh': { ownership: 'installer-owned', checksum, path: 'scripts/ralph-loop.sh' },
      },
    });

    const result = await detectUpdate(dir, { getInstallerVersion: async () => '1.0.0' });
    assert.equal(result.delta.installerOwned.length, 1);
    assert.equal(result.delta.installerOwned[0].isModified, false);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('detectUpdate: modified installer-owned file → isModified true', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'scripts'), { recursive: true });
    const originalContent = '#!/bin/bash\necho original\n';
    const modifiedContent = '#!/bin/bash\necho modified\n';
    await fs.writeFile(path.join(dir, 'scripts', 'ralph-loop.sh'), modifiedContent, 'utf8');
    const originalChecksum = hashString(originalContent);

    await writeManifestFixture(dir, {
      version: '1.0.0',
      files: {
        'scripts/ralph-loop.sh': {
          ownership: 'installer-owned',
          checksum: originalChecksum,
          path: 'scripts/ralph-loop.sh',
        },
      },
    });

    const result = await detectUpdate(dir, { getInstallerVersion: async () => '1.0.0' });
    assert.equal(result.delta.installerOwned.length, 1);
    assert.equal(result.delta.installerOwned[0].isModified, true);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Delta: user-owned files ──────────────────────────────────────────────────

test('detectUpdate: user-owned files appear in delta.userOwned, not installerOwned', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'docs', 'epics'), { recursive: true });
    const content = '# PRD\n';
    await fs.writeFile(path.join(dir, 'docs', 'epics', 'project-prd.md'), content, 'utf8');
    const checksum = hashString(content);

    await writeManifestFixture(dir, {
      version: '1.0.0',
      files: {
        'docs/epics/project-prd.md': {
          ownership: 'user-owned',
          checksum,
          path: 'docs/epics/project-prd.md',
        },
      },
    });

    const result = await detectUpdate(dir, { getInstallerVersion: async () => '1.0.0' });
    assert.equal(result.delta.userOwned.length, 1, 'user-owned file should be in userOwned');
    assert.equal(result.delta.installerOwned.length, 0, 'should not be in installerOwned');
    assert.equal(result.delta.userOwned[0].path, 'docs/epics/project-prd.md');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Delta: missing files ─────────────────────────────────────────────────────

test('detectUpdate: file in manifest but missing from disk → in delta.missing', async () => {
  const dir = await makeTempDir();
  try {
    await writeManifestFixture(dir, {
      version: '1.0.0',
      files: {
        'scripts/ralph-loop.sh': {
          ownership: 'installer-owned',
          checksum: 'sha256:abc123',
          path: 'scripts/ralph-loop.sh',
        },
      },
    });

    const result = await detectUpdate(dir, { getInstallerVersion: async () => '1.0.0' });
    assert.equal(result.delta.missing.length, 1);
    assert.ok(result.delta.missing.includes('scripts/ralph-loop.sh'));
    assert.equal(result.delta.installerOwned.length, 0, 'missing file should not be in installerOwned');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Delta: manifest returned intact ─────────────────────────────────────────

test('detectUpdate: returns manifest object for wizard answer preservation', async () => {
  const dir = await makeTempDir();
  try {
    const wizardAnswers = { appDir: 'frontend', checkpointCommand: 'make test' };
    await writeManifestFixture(dir, {
      version: '1.0.0',
      files: {},
      wizardAnswers,
    });

    const result = await detectUpdate(dir, { getInstallerVersion: async () => '1.0.0' });
    assert.ok(result.manifest, 'manifest should be returned');
    assert.deepEqual(result.manifest.wizardAnswers, wizardAnswers);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
