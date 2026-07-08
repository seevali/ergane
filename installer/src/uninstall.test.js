import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {
  loadManifest,
  categorizeFiles,
  removeFile,
  removeEmptyDir,
  pruneEmptyInstallerDirs,
  cleanGitignore,
  uninstall,
} from './uninstall.js';

// ── Helpers ───────────────────────────────────────────────────────────────────

async function makeTempDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'ralph-uninstall-'));
}

async function fileExists(p) {
  return fs.access(p).then(() => true).catch(() => false);
}

/**
 * Create a fixture directory with files and a matching manifest.
 *
 * @param {string} targetDir - Directory to populate
 * @param {Record<string, { ownership: string, content?: string }>} fileMap
 */
async function createFixtureWithManifest(targetDir, fileMap) {
  for (const [relPath, entry] of Object.entries(fileMap)) {
    const fullPath = path.join(targetDir, relPath);
    await fs.mkdir(path.dirname(fullPath), { recursive: true });
    await fs.writeFile(fullPath, entry.content ?? `# ${relPath}\n`, 'utf8');
  }

  const files = {};
  for (const [relPath, entry] of Object.entries(fileMap)) {
    files[relPath] = {
      ownership: entry.ownership ?? 'user-owned',
      checksum: 'sha256:placeholder',
      path: relPath,
    };
  }

  const manifest = {
    version: '0.1.0',
    installedAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    files,
    wizardAnswers: {},
    targetClass: 'empty',
  };

  const ralphDir = path.join(targetDir, '.ralph');
  await fs.mkdir(ralphDir, { recursive: true });
  await fs.writeFile(
    path.join(ralphDir, 'manifest.json'),
    JSON.stringify(manifest, null, 2) + '\n',
    'utf8',
  );
}

// ── loadManifest ──────────────────────────────────────────────────────────────

test('loadManifest: returns null when manifest file does not exist', async () => {
  const dir = await makeTempDir();
  try {
    const result = await loadManifest(path.join(dir, '.ralph', 'manifest.json'));
    assert.equal(result, null);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('loadManifest: returns parsed manifest when file exists and is valid', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
    const manifest = { version: '0.1.0', files: { 'test.md': { ownership: 'user-owned' } } };
    await fs.writeFile(
      path.join(dir, '.ralph', 'manifest.json'),
      JSON.stringify(manifest),
      'utf8',
    );
    const result = await loadManifest(path.join(dir, '.ralph', 'manifest.json'));
    assert.ok(result);
    assert.equal(result.version, '0.1.0');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('loadManifest: throws when file exists but is invalid JSON', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
    await fs.writeFile(path.join(dir, '.ralph', 'manifest.json'), 'not json', 'utf8');
    await assert.rejects(
      () => loadManifest(path.join(dir, '.ralph', 'manifest.json')),
      (err) => {
        assert.ok(err.message.includes('corrupted'));
        return true;
      },
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('loadManifest: throws when parsed manifest lacks files key', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
    await fs.writeFile(
      path.join(dir, '.ralph', 'manifest.json'),
      JSON.stringify({ version: '0.1.0' }),
      'utf8',
    );
    await assert.rejects(
      () => loadManifest(path.join(dir, '.ralph', 'manifest.json')),
      (err) => {
        assert.ok(err.message.includes('corrupted'));
        return true;
      },
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── categorizeFiles ───────────────────────────────────────────────────────────

test('categorizeFiles: separates entries by ownership class', () => {
  const entries = {
    'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
    'docs/prd.md': { ownership: 'user-owned' },
    'scripts/prompts/system.md': { ownership: 'installer-owned' },
  };
  const { installerOwned, userOwned } = categorizeFiles(entries);
  assert.deepEqual(installerOwned.sort(), ['scripts/prompts/system.md', 'scripts/ralph-loop.sh'].sort());
  assert.deepEqual(userOwned, ['docs/prd.md']);
});

test('categorizeFiles: treats null or unknown ownership as user-owned', () => {
  const entries = {
    'unknown.md': { ownership: 'unknown' },
    'null-entry': null,
  };
  const { installerOwned, userOwned } = categorizeFiles(entries);
  assert.equal(installerOwned.length, 0);
  assert.equal(userOwned.length, 2);
});

// ── removeFile ────────────────────────────────────────────────────────────────

test('removeFile: removes an existing file and returns success', async () => {
  const dir = await makeTempDir();
  try {
    const filePath = path.join(dir, 'test.txt');
    await fs.writeFile(filePath, 'hello', 'utf8');
    const result = await removeFile(filePath);
    assert.equal(result.success, true);
    assert.equal(await fileExists(filePath), false);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('removeFile: returns success when file is already gone (ENOENT)', async () => {
  const result = await removeFile('/tmp/ralph-does-not-exist-xyz.txt');
  assert.equal(result.success, true);
  assert.equal(result.error, null);
});

// ── removeEmptyDir ────────────────────────────────────────────────────────────

test('removeEmptyDir: removes an empty directory', async () => {
  const dir = await makeTempDir();
  const emptyDir = path.join(dir, 'empty');
  await fs.mkdir(emptyDir);
  try {
    const result = await removeEmptyDir(emptyDir);
    assert.equal(result.success, true);
    assert.equal(await fileExists(emptyDir), false);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('removeEmptyDir: returns not-empty when directory has contents', async () => {
  const dir = await makeTempDir();
  try {
    await fs.writeFile(path.join(dir, 'file.txt'), 'x', 'utf8');
    const result = await removeEmptyDir(dir);
    assert.equal(result.success, false);
    assert.equal(result.reason, 'not-empty');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── cleanGitignore ────────────────────────────────────────────────────────────

test('cleanGitignore: removes Ergane section and preserves original entries', async () => {
  const dir = await makeTempDir();
  try {
    const gitignorePath = path.join(dir, '.gitignore');
    const content = 'node_modules/\nbuild/\n\n# Ergane\n_bmad/\n.claude/skills/\n';
    await fs.writeFile(gitignorePath, content, 'utf8');

    await cleanGitignore(gitignorePath);

    const after = await fs.readFile(gitignorePath, 'utf8');
    assert.ok(!after.includes('# Ergane'), 'Ergane section should be removed');
    assert.ok(!after.includes('_bmad/'), 'Ergane entries should be removed');
    assert.ok(after.includes('node_modules/'), 'original entries should be preserved');
    assert.ok(after.includes('build/'), 'original entries should be preserved');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('cleanGitignore: deletes file when it contains only Ergane entries', async () => {
  const dir = await makeTempDir();
  try {
    const gitignorePath = path.join(dir, '.gitignore');
    await fs.writeFile(gitignorePath, '\n# Ergane\n_bmad/\n.claude/skills/\n', 'utf8');

    await cleanGitignore(gitignorePath);

    assert.equal(await fileExists(gitignorePath), false, '.gitignore should be deleted when empty');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('cleanGitignore: is a no-op when file does not exist', async () => {
  const dir = await makeTempDir();
  try {
    await assert.doesNotReject(() => cleanGitignore(path.join(dir, '.gitignore')));
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── uninstall — AC1: valid manifest removes only installer-owned files ─────────

test('uninstall: removes installer-owned files and preserves user-owned files (--yes)', async () => {
  const dir = await makeTempDir();
  try {
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      'docs/prd.md': { ownership: 'user-owned' },
    });

    const result = await uninstall(
      { targetDir: dir, yes: true, force: false },
      { isTTY: false, log: () => {}, errLog: () => {} },
    );

    assert.equal(result.success, true);
    assert.equal(await fileExists(path.join(dir, 'scripts/ralph-loop.sh')), false, 'installer-owned file removed');
    assert.equal(await fileExists(path.join(dir, 'docs/prd.md')), true, 'user-owned file preserved');
    assert.equal(await fileExists(path.join(dir, '.ralph', 'manifest.json')), false, 'manifest removed');
    assert.equal(await fileExists(path.join(dir, '.ralph')), false, '.ralph/ directory removed');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── uninstall — AC2: no manifest exits non-zero ───────────────────────────────

test('uninstall: returns failure when no manifest exists', async () => {
  const dir = await makeTempDir();
  try {
    const result = await uninstall({ targetDir: dir }, { isTTY: false });
    assert.equal(result.success, false);
    assert.ok(result.message.includes('no Ergane installation found'), result.message);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('uninstall: returns failure with corrupted manifest', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
    await fs.writeFile(path.join(dir, '.ralph', 'manifest.json'), 'bad json!', 'utf8');

    const result = await uninstall({ targetDir: dir }, { isTTY: false });
    assert.equal(result.success, false);
    assert.ok(result.message.includes('corrupted'), result.message);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── uninstall — AC3: interactive prompt preserves user files on 'n' ───────────

test('uninstall: interactive prompt preserves user-owned files when user declines', async () => {
  const dir = await makeTempDir();
  try {
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      'docs/prd.md': { ownership: 'user-owned' },
    });

    const logs = [];
    const result = await uninstall(
      { targetDir: dir, yes: false, force: false },
      {
        isTTY: false,
        log: (msg) => logs.push(msg),
        prompts: {
          confirm: async () => false, // user declines
          isCancel: () => false,
        },
      },
    );

    assert.equal(result.success, true);
    assert.equal(await fileExists(path.join(dir, 'scripts/ralph-loop.sh')), false, 'installer-owned file removed');
    assert.equal(await fileExists(path.join(dir, 'docs/prd.md')), true, 'user-owned file preserved on decline');
    assert.equal(await fileExists(path.join(dir, '.ralph', 'manifest.json')), false, 'manifest removed');
    assert.equal(await fileExists(path.join(dir, '.ralph')), false, '.ralph/ removed');
    assert.ok(logs.some((m) => m.includes('[Skipped]')), 'skipped message logged');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── uninstall — AC4: --yes preserves user files without prompting ─────────────

test('uninstall: --yes preserves user-owned files without calling prompt', async () => {
  const dir = await makeTempDir();
  try {
    const content = '# original prd content\n';
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      'docs/prd.md': { ownership: 'user-owned', content },
    });

    let promptCalled = false;
    const result = await uninstall(
      { targetDir: dir, yes: true, force: false },
      {
        isTTY: false,
        log: () => {},
        errLog: () => {},
        prompts: {
          confirm: async () => { promptCalled = true; return false; },
          isCancel: () => false,
        },
      },
    );

    assert.equal(result.success, true);
    assert.equal(await fileExists(path.join(dir, 'scripts/ralph-loop.sh')), false, 'installer-owned file removed');
    const preserved = await fs.readFile(path.join(dir, 'docs/prd.md'), 'utf8');
    assert.equal(preserved, content, 'user-owned file preserved byte-identically');
    assert.equal(promptCalled, false, 'prompt should not be called with --yes');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── uninstall — AC5: --force removes all files without prompting ──────────────

test('uninstall: --force removes both installer-owned and user-owned files', async () => {
  const dir = await makeTempDir();
  try {
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      'docs/prd.md': { ownership: 'user-owned' },
    });

    let promptCalled = false;
    const result = await uninstall(
      { targetDir: dir, yes: false, force: true },
      {
        isTTY: false,
        log: () => {},
        errLog: () => {},
        prompts: {
          confirm: async () => { promptCalled = true; return true; },
          isCancel: () => false,
        },
      },
    );

    assert.equal(result.success, true);
    assert.equal(await fileExists(path.join(dir, 'scripts/ralph-loop.sh')), false, 'installer-owned file removed');
    assert.equal(await fileExists(path.join(dir, 'docs/prd.md')), false, 'user-owned file removed with --force');
    assert.equal(await fileExists(path.join(dir, '.ralph', 'manifest.json')), false, 'manifest removed');
    assert.equal(promptCalled, false, 'prompt should not be called with --force');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── uninstall — AC5: .ralph/ removed when empty ───────────────────────────────

test('uninstall: removes .ralph/ directory when empty after manifest removal', async () => {
  const dir = await makeTempDir();
  try {
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
    });

    const result = await uninstall(
      { targetDir: dir, yes: true, force: false },
      { isTTY: false, log: () => {}, errLog: () => {} },
    );

    assert.equal(result.success, true);
    assert.equal(await fileExists(path.join(dir, '.ralph')), false, '.ralph/ removed when empty');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── uninstall — AC6: .gitignore cleanup ──────────────────────────────────────

test('uninstall: removes Ergane section from .gitignore and preserves original entries', async () => {
  const dir = await makeTempDir();
  try {
    const originalContent = 'node_modules/\nbuild/\nmy-custom-entry\n';
    const withErganeSection = originalContent + '\n# Ergane\n_bmad/\n.claude/skills/\n';

    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      '.gitignore': { ownership: 'installer-owned', content: withErganeSection },
    });

    await uninstall(
      { targetDir: dir, yes: true, force: false },
      { isTTY: false, log: () => {}, errLog: () => {} },
    );

    const after = await fs.readFile(path.join(dir, '.gitignore'), 'utf8');
    assert.ok(!after.includes('# Ergane'), 'Ergane section removed');
    assert.ok(!after.includes('_bmad/'), 'Ergane entries removed');
    assert.ok(after.includes('node_modules/'), 'original entry preserved');
    assert.ok(after.includes('my-custom-entry'), 'original entry preserved');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('uninstall: deletes .gitignore when it contained only Ergane entries', async () => {
  const dir = await makeTempDir();
  try {
    const onlyErgane = '\n# Ergane\n_bmad/\n.claude/skills/\n';

    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      '.gitignore': { ownership: 'installer-owned', content: onlyErgane },
    });

    await uninstall(
      { targetDir: dir, yes: true, force: false },
      { isTTY: false, log: () => {}, errLog: () => {} },
    );

    assert.equal(await fileExists(path.join(dir, '.gitignore')), false, '.gitignore deleted when empty');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── uninstall — AC7: partial failure with --force returns success ─────────────

test('uninstall: --force continues and returns success when a file cannot be removed', async () => {
  // Skip when running as root (chmod-based permission simulation doesn't work as root)
  if (typeof process.getuid === 'function' && process.getuid() === 0) {
    return;
  }

  const dir = await makeTempDir();
  const scriptDir = path.join(dir, 'scripts');

  try {
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      'docs/project-conventions.md': { ownership: 'installer-owned' },
      'docs/prd.md': { ownership: 'user-owned' },
    });

    // Make scripts/ non-writable so ralph-loop.sh cannot be deleted
    await fs.chmod(scriptDir, 0o555);

    const errLogs = [];
    const result = await uninstall(
      { targetDir: dir, yes: false, force: true },
      {
        isTTY: false,
        log: () => {},
        errLog: (msg) => errLogs.push(msg),
      },
    );

    // With --force, success is true even if some files couldn't be removed
    assert.equal(result.success, true, '--force overrides non-critical errors');
    assert.ok(
      errLogs.some((m) => m.includes('Could not remove')),
      'warning logged for failed removal',
    );
    // docs/project-conventions.md (in writable dir) should be removed
    assert.equal(
      await fileExists(path.join(dir, 'docs/project-conventions.md')),
      false,
      'other installer-owned file removed',
    );
  } finally {
    // Restore permissions before cleanup
    await fs.chmod(scriptDir, 0o755).catch(() => {});
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── uninstall — AC8 & AC9: no ANSI codes in non-TTY / NO_COLOR output ─────────

test('uninstall: output contains no ANSI escape codes when NO_COLOR is set', async () => {
  const dir = await makeTempDir();
  const orig = process.env.NO_COLOR;
  try {
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      'docs/prd.md': { ownership: 'user-owned' },
    });

    process.env.NO_COLOR = '1';
    const logs = [];
    await uninstall(
      { targetDir: dir, yes: true, force: false },
      {
        isTTY: true, // would be colored if NO_COLOR weren't set
        log: (msg) => logs.push(msg),
        errLog: (msg) => logs.push(msg),
      },
    );

    const allOutput = logs.join('\n');
    assert.ok(!/\x1b\[/.test(allOutput), 'output should contain no ANSI escape codes');
  } finally {
    if (orig === undefined) {
      delete process.env.NO_COLOR;
    } else {
      process.env.NO_COLOR = orig;
    }
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('uninstall: output contains no ANSI escape codes when stdout is not a TTY', async () => {
  const dir = await makeTempDir();
  try {
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      'docs/prd.md': { ownership: 'user-owned' },
    });

    const logs = [];
    await uninstall(
      { targetDir: dir, yes: true, force: false },
      {
        isTTY: false,
        noColor: false, // NO_COLOR not set, but non-TTY disables colors
        log: (msg) => logs.push(msg),
        errLog: (msg) => logs.push(msg),
      },
    );

    const allOutput = logs.join('\n');
    assert.ok(!/\x1b\[/.test(allOutput), 'output should contain no ANSI escape codes');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── uninstall — no user-owned files skips the prompt entirely ────────────────

test('uninstall: skips user-owned prompt when no user-owned files exist', async () => {
  const dir = await makeTempDir();
  try {
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
    });

    let promptCalled = false;
    const result = await uninstall(
      { targetDir: dir, yes: false, force: false },
      {
        isTTY: false,
        log: () => {},
        errLog: () => {},
        prompts: {
          confirm: async () => { promptCalled = true; return false; },
          isCancel: () => false,
        },
      },
    );

    assert.equal(result.success, true);
    assert.equal(promptCalled, false, 'prompt not called when no user-owned files');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── L1: non-interactive uninstall must not crash or half-delete ───────────────

test('uninstall: non-TTY without --yes/--force fails closed BEFORE deleting anything', async () => {
  const dir = await makeTempDir();
  try {
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      'docs/prd.md': { ownership: 'user-owned' },
    });

    // No injected prompts + stdinIsTTY false → would hit the raw @clack crash.
    const result = await uninstall(
      { targetDir: dir, yes: false, force: false },
      { isTTY: false, stdinIsTTY: false, log: () => {}, errLog: () => {} },
    );

    assert.equal(result.success, false, 'must fail closed, not crash');
    assert.ok(/--yes|--force/.test(result.message), 'message should point at --yes/--force');
    // Nothing was deleted — the tree is intact and the manifest still present.
    assert.equal(await fileExists(path.join(dir, 'scripts/ralph-loop.sh')), true, 'installer file untouched');
    assert.equal(await fileExists(path.join(dir, '.ralph', 'manifest.json')), true, 'manifest untouched');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('uninstall: --yes prunes now-empty installer directories', async () => {
  const dir = await makeTempDir();
  try {
    await createFixtureWithManifest(dir, {
      'scripts/prompts/common/system.md': { ownership: 'installer-owned' },
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
    });

    await uninstall(
      { targetDir: dir, yes: true, force: false },
      { isTTY: false, log: () => {}, errLog: () => {} },
    );

    assert.equal(await fileExists(path.join(dir, 'scripts', 'prompts', 'common')), false, 'empty prompts dir pruned');
    assert.equal(await fileExists(path.join(dir, 'scripts', 'prompts')), false, 'empty prompts dir pruned');
    assert.equal(await fileExists(path.join(dir, 'scripts')), false, 'empty scripts dir pruned');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('uninstall: prune keeps directories that still hold preserved user files', async () => {
  const dir = await makeTempDir();
  try {
    await createFixtureWithManifest(dir, {
      'docs/epics/project-prd.md': { ownership: 'user-owned' },
      'docs/project-conventions.md': { ownership: 'installer-owned' },
    });

    await uninstall(
      { targetDir: dir, yes: true, force: false },
      { isTTY: false, log: () => {}, errLog: () => {} },
    );

    // docs/ and docs/epics/ still hold the preserved user PRD → not pruned.
    assert.equal(await fileExists(path.join(dir, 'docs', 'epics', 'project-prd.md')), true, 'user file preserved');
    assert.equal(await fileExists(path.join(dir, 'docs', 'epics')), true, 'non-empty dir kept');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('uninstall: re-running on a half-deleted state (manifest present) completes cleanly', async () => {
  const dir = await makeTempDir();
  try {
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      'scripts/prompts/common/system.md': { ownership: 'installer-owned' },
      'docs/prd.md': { ownership: 'user-owned' },
    });

    // Simulate an interrupted uninstall: some installer files already gone,
    // manifest still present (manifest is removed LAST, so this is re-runnable).
    await fs.unlink(path.join(dir, 'scripts', 'ralph-loop.sh'));

    const result = await uninstall(
      { targetDir: dir, yes: true, force: false },
      { isTTY: false, log: () => {}, errLog: () => {} },
    );

    assert.equal(result.success, true, 're-run over a half-deleted tree should succeed');
    assert.equal(await fileExists(path.join(dir, '.ralph', 'manifest.json')), false, 'manifest removed on the clean re-run');
    assert.equal(await fileExists(path.join(dir, 'docs', 'prd.md')), true, 'user file still preserved');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('pruneEmptyInstallerDirs: removes empty dirs deepest-first, skips non-empty', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'scripts', 'prompts', 'common'), { recursive: true });
    await fs.mkdir(path.join(dir, 'docs', 'epics'), { recursive: true });
    await fs.writeFile(path.join(dir, 'docs', 'epics', 'keep.md'), 'x', 'utf8');

    const removed = await pruneEmptyInstallerDirs(dir, [
      'scripts/prompts/common/system.md',
      'docs/epics/project-prd.md',
    ]);

    assert.ok(removed.includes('scripts/prompts/common'), 'deep empty dir removed');
    assert.ok(removed.includes('scripts/prompts'), 'parent empty dir removed');
    assert.ok(!removed.includes('docs/epics'), 'non-empty dir kept');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── uninstall — user cancels interactive prompt (isCancel) ────────────────────

test('uninstall: preserves user-owned files when prompt is cancelled', async () => {
  const dir = await makeTempDir();
  try {
    await createFixtureWithManifest(dir, {
      'scripts/ralph-loop.sh': { ownership: 'installer-owned' },
      'docs/prd.md': { ownership: 'user-owned' },
    });

    const CANCEL = Symbol('cancel');
    const logs = [];
    const result = await uninstall(
      { targetDir: dir, yes: false, force: false },
      {
        isTTY: false,
        log: (msg) => logs.push(msg),
        prompts: {
          confirm: async () => CANCEL,
          isCancel: (v) => v === CANCEL,
        },
      },
    );

    assert.equal(result.success, true);
    assert.equal(await fileExists(path.join(dir, 'docs/prd.md')), true, 'user-owned file preserved on cancel');
    assert.ok(logs.some((m) => m.includes('[Skipped]')), 'skipped message logged');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
