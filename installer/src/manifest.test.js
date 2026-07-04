import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {
  loadManifest,
  tryLoadManifest,
  ManifestError,
  MANIFEST_NOT_FOUND_MESSAGE,
  MANIFEST_CORRUPTED_MESSAGE,
  hasOrphanedLoopFiles,
} from './manifest.js';

async function makeTempDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'ralph-manifest-'));
}

async function writeManifest(dir, content) {
  await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
  await fs.writeFile(path.join(dir, '.ralph', 'manifest.json'), content, 'utf8');
}

test('loadManifest: throws not-found ManifestError with the canonical message when absent', async () => {
  const dir = await makeTempDir();
  try {
    await assert.rejects(
      () => loadManifest(dir),
      (err) => {
        assert.ok(err instanceof ManifestError);
        assert.equal(err.code, 'not-found');
        assert.equal(err.message, MANIFEST_NOT_FOUND_MESSAGE);
        return true;
      },
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('loadManifest: throws corrupted ManifestError on invalid JSON', async () => {
  const dir = await makeTempDir();
  try {
    await writeManifest(dir, '{not json');
    await assert.rejects(
      () => loadManifest(dir),
      (err) => {
        assert.equal(err.code, 'corrupted');
        assert.equal(err.message, MANIFEST_CORRUPTED_MESSAGE);
        return true;
      },
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('loadManifest: throws corrupted when the files key is missing', async () => {
  const dir = await makeTempDir();
  try {
    await writeManifest(dir, JSON.stringify({ version: '0.2.0' }));
    await assert.rejects(() => loadManifest(dir), (err) => err.code === 'corrupted');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('loadManifest: returns the parsed manifest when valid', async () => {
  const dir = await makeTempDir();
  try {
    await writeManifest(dir, JSON.stringify({ version: '0.2.0', files: { 'a.md': {} } }));
    const manifest = await loadManifest(dir);
    assert.equal(manifest.version, '0.2.0');
    assert.ok(manifest.files['a.md']);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('tryLoadManifest: returns { error } with the ManifestError instead of throwing', async () => {
  const dir = await makeTempDir();
  try {
    const { error, manifest } = await tryLoadManifest(dir);
    assert.equal(manifest, undefined);
    assert.equal(error.code, 'not-found');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('hasOrphanedLoopFiles: true when loop files exist without a manifest', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'scripts'), { recursive: true });
    await fs.writeFile(path.join(dir, 'scripts', 'ralph-loop.sh'), '#!/bin/bash\n', 'utf8');
    assert.equal(await hasOrphanedLoopFiles(dir), true);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('hasOrphanedLoopFiles: false for a truly empty directory', async () => {
  const dir = await makeTempDir();
  try {
    assert.equal(await hasOrphanedLoopFiles(dir), false);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
