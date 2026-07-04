import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { classifyTarget, findAncestorInstall } from '../src/classify.js';

async function makeTempDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'ralph-classify-'));
}

async function writeManifestAt(dir) {
  await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
  await fs.writeFile(
    path.join(dir, '.ralph', 'manifest.json'),
    JSON.stringify({ version: '0.2.0', files: {} }),
    'utf8',
  );
}

// ─── findAncestorInstall (L11a nested-install guard) ──────────────────────────

test('findAncestorInstall: finds an install in an ancestor directory', async () => {
  const root = await makeTempDir();
  try {
    await writeManifestAt(root);
    const sub = path.join(root, 'a', 'b');
    await fs.mkdir(sub, { recursive: true });
    const found = await findAncestorInstall(sub);
    assert.equal(found, path.join(root, '.ralph', 'manifest.json'));
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test('findAncestorInstall: returns null when no ancestor has an install', async () => {
  const root = await makeTempDir();
  try {
    const sub = path.join(root, 'a', 'b');
    await fs.mkdir(sub, { recursive: true });
    assert.equal(await findAncestorInstall(sub), null);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test('findAncestorInstall: ignores the target directory itself (only ancestors)', async () => {
  const root = await makeTempDir();
  try {
    await writeManifestAt(root); // manifest is IN the target, not an ancestor
    assert.equal(await findAncestorInstall(root), null);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

// ─── Empty directory ──────────────────────────────────────────────────────────

test('empty directory classifies as empty', async () => {
  const dir = await makeTempDir();
  try {
    const result = await classifyTarget(dir);
    assert.equal(result.type, 'empty');
    assert.equal(result.signals.length, 0);
    assert.equal(result.hasManifest, false);
    assert.ok(path.isAbsolute(result.projectRoot), 'projectRoot should be absolute');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Existing projects ────────────────────────────────────────────────────────

test('Node project classifies as existing-project', async () => {
  const dir = await makeTempDir();
  try {
    await fs.writeFile(path.join(dir, 'package.json'), '{}');
    await fs.mkdir(path.join(dir, '.git'));
    const result = await classifyTarget(dir);
    assert.equal(result.type, 'existing-project');
    assert.ok(result.signals.includes('package.json'), 'signals should include package.json');
    assert.ok(result.signals.includes('.git'), 'signals should include .git');
    assert.equal(result.hasManifest, false);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('Python project classifies as existing-project', async () => {
  const dir = await makeTempDir();
  try {
    await fs.writeFile(path.join(dir, 'pyproject.toml'), '');
    await fs.mkdir(path.join(dir, '.git'));
    const result = await classifyTarget(dir);
    assert.equal(result.type, 'existing-project');
    assert.ok(result.signals.includes('pyproject.toml'), 'signals should include pyproject.toml');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Existing Ralph install ───────────────────────────────────────────────────

test('directory with .ralph/manifest.json classifies as existing-install', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'));
    await fs.writeFile(path.join(dir, '.ralph', 'manifest.json'), JSON.stringify({ version: '1.0.0' }));
    await fs.writeFile(path.join(dir, 'package.json'), '{}');
    const result = await classifyTarget(dir);
    assert.equal(result.type, 'existing-install');
    assert.equal(result.hasManifest, true);
    assert.ok(result.signals.includes('.ralph'), 'signals should include .ralph');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Ambiguous / partial install ─────────────────────────────────────────────

test('partial install (manifest present, scripts missing) still classifies as existing-install', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'));
    await fs.writeFile(path.join(dir, '.ralph', 'manifest.json'), JSON.stringify({ version: '1.0.0' }));
    // Intentionally no scripts/ralph-loop.sh — simulates partial/corrupted install
    const result = await classifyTarget(dir);
    assert.equal(result.type, 'existing-install');
    assert.equal(result.hasManifest, true);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Multiple signals ─────────────────────────────────────────────────────────

test('multiple project signals are all reported', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.git'));
    await fs.writeFile(path.join(dir, 'package.json'), '{}');
    await fs.writeFile(path.join(dir, 'Gemfile'), '');
    const result = await classifyTarget(dir);
    assert.ok(result.signals.includes('.git'), 'signals should include .git');
    assert.ok(result.signals.includes('package.json'), 'signals should include package.json');
    assert.ok(result.signals.includes('Gemfile'), 'signals should include Gemfile');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Error handling ───────────────────────────────────────────────────────────

test('non-existent path throws error with clear message', async () => {
  await assert.rejects(
    () => classifyTarget('/tmp/does-not-exist-ralph-classify-99999'),
    (err) => {
      assert.ok(
        err.message.includes('not found') || err.message.includes('does not exist'),
        `Expected "not found" in error message, got: ${err.message}`,
      );
      return true;
    },
  );
});

// ─── Symlink resolution ───────────────────────────────────────────────────────

test('symlink is resolved and projectRoot points to the real directory', async () => {
  const realDir = await makeTempDir();
  const linkPath = `${realDir}-symlink`;
  try {
    await fs.symlink(realDir, linkPath);
    const result = await classifyTarget(linkPath);
    const realResolved = await fs.realpath(realDir);
    assert.equal(result.projectRoot, realResolved, 'projectRoot should resolve to real directory');
    assert.equal(result.type, 'empty');
  } finally {
    await fs.rm(realDir, { recursive: true, force: true });
    await fs.unlink(linkPath).catch(() => {});
  }
});

// ─── Visual Studio .sln detection ────────────────────────────────────────────

test('.sln file is detected as an existing-project signal', async () => {
  const dir = await makeTempDir();
  try {
    await fs.writeFile(path.join(dir, 'MyApp.sln'), '');
    const result = await classifyTarget(dir);
    assert.equal(result.type, 'existing-project');
    assert.ok(result.signals.includes('MyApp.sln'), 'signals should include MyApp.sln');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
