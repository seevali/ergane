import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {
  renderTemplate,
  validateNoUnsubstituted,
  extractStoryIds,
  hashFile,
  hashString,
  detectConflicts,
  confirmConflicts,
  executeWrite,
  writeManifest,
  buildWriteMap,
  writeInstall,
  executeUpdate,
} from './writer.js';

async function makeTempDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'ralph-writer-'));
}

// ─── AC-1: Template Rendering ─────────────────────────────────────────────────

test('renderTemplate substitutes all three named placeholders', () => {
  const tpl = 'dir={{APP_DIR}}, cmd={{CHECKPOINT_COMMAND}}, stack={{STACK_DESCRIPTION}}';
  const result = renderTemplate(tpl, {
    APP_DIR: 'src',
    CHECKPOINT_COMMAND: 'npm test',
    STACK_DESCRIPTION: 'React + TypeScript',
  });
  assert.equal(result, 'dir=src, cmd=npm test, stack=React + TypeScript');
});

test('renderTemplate replaces all occurrences of the same placeholder', () => {
  const tpl = '{{APP_DIR}} is used again in {{APP_DIR}}';
  const result = renderTemplate(tpl, { APP_DIR: 'src' });
  assert.equal(result, 'src is used again in src');
});

test('renderTemplate leaves unrelated placeholders untouched', () => {
  const tpl = 'known={{KNOWN}}, unknown={{UNKNOWN_EXTRA}}';
  const result = renderTemplate(tpl, { KNOWN: 'yes' });
  assert.equal(result, 'known=yes, unknown={{UNKNOWN_EXTRA}}');
});

test('validateNoUnsubstituted throws when a placeholder remains', () => {
  assert.throws(
    () => validateNoUnsubstituted('Hello {{REMAINING}} world'),
    (err) => {
      assert.ok(err.message.includes('{{REMAINING}}'), 'error should name the placeholder');
      return true;
    },
  );
});

test('validateNoUnsubstituted throws and names all remaining placeholders', () => {
  assert.throws(
    () => validateNoUnsubstituted('{{FOO}} and {{BAR}}'),
    (err) => {
      assert.ok(err.message.includes('{{FOO}}') && err.message.includes('{{BAR}}'));
      return true;
    },
  );
});

test('validateNoUnsubstituted passes when no placeholders remain', () => {
  assert.doesNotThrow(() => validateNoUnsubstituted('No placeholders here.'));
});

test('validateNoUnsubstituted passes on empty string', () => {
  assert.doesNotThrow(() => validateNoUnsubstituted(''));
});

// ─── AC-1 (continued): Rendered epic stub produces valid story headers ─────────

test('rendered epic-stub-stories.md has parseable ### Story X.Y: headers', async () => {
  const plan = {
    targetDir: os.tmpdir(),
    taskSource: 'scaffold',
    appDir: 'src',
    checkpointCommand: 'npm test',
    stackDescription: 'React + TypeScript',
    addGitignoreEntries: false,
  };

  const writeMap = await buildWriteMap(plan);
  const storiesContent = writeMap.get('docs/epics/project-stories.md');
  assert.ok(storiesContent, 'stories file should be in write map');

  const ids = extractStoryIds(storiesContent);
  assert.ok(ids.length > 0, 'rendered stub should have at least one ### Story X.Y: header');

  // All extracted IDs must match the X.Y numeric format
  for (const id of ids) {
    assert.match(id, /^\d+\.\d+$/, `story ID "${id}" should be in X.Y format`);
  }
});

test('rendered project-conventions.md contains no unsubstituted placeholders', async () => {
  const plan = {
    targetDir: os.tmpdir(),
    taskSource: 'existing',
    appDir: 'frontend',
    checkpointCommand: 'make test',
    stackDescription: 'Vue 3 + Vite',
    addGitignoreEntries: false,
  };

  const writeMap = await buildWriteMap(plan);
  const conventions = writeMap.get('docs/project-conventions.md');
  assert.ok(conventions, 'project-conventions.md should be in write map');
  assert.doesNotThrow(() => validateNoUnsubstituted(conventions));
});

// ─── AC-6: Story Header Parsing ───────────────────────────────────────────────

test('extractStoryIds finds all ### Story X.Y: headers', () => {
  const content = `
# Epic

### Story 1.1: App shell

Content.

### Story 1.2: Persistence

Content.

### Story 2.3: Advanced feature

Content.
`;
  const ids = extractStoryIds(content);
  assert.deepEqual(ids, ['1.1', '1.2', '2.3']);
});

test('extractStoryIds returns empty array when no headers present', () => {
  const ids = extractStoryIds('No story headers here.');
  assert.deepEqual(ids, []);
});

test('extractStoryIds ignores malformed headers', () => {
  const content = `
### Story 1.1: Valid
### Story notanumber: Invalid
## Story 2.1: Wrong level (##)
### story 3.1: lowercase not matched
`;
  const ids = extractStoryIds(content);
  assert.deepEqual(ids, ['1.1'], 'only strictly matching headers should be extracted');
});

test('extractStoryIds handles multi-digit story numbers', () => {
  const content = `
### Story 10.1: Large epic
### Story 1.10: Many stories
`;
  const ids = extractStoryIds(content);
  assert.deepEqual(ids, ['10.1', '1.10']);
});

// ─── AC-2: Conflict Detection — Default-Deny ──────────────────────────────────

test('AC-2.1: fresh install (no manifest) — existing file → conflict detected', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'docs'), { recursive: true });
    await fs.writeFile(path.join(dir, 'docs', 'project-conventions.md'), 'existing content\n');

    const plan = { targetDir: dir };
    const writeMap = new Map([['docs/project-conventions.md', 'new content\n']]);

    const conflicts = await detectConflicts(plan, writeMap);

    assert.equal(conflicts.length, 1, 'should detect one conflict');
    assert.equal(conflicts[0].path, 'docs/project-conventions.md');
    assert.equal(conflicts[0].reason, 'file-exists-no-manifest');
    assert.ok(conflicts[0].existingChecksum?.startsWith('sha256:'), 'should include existing checksum');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('AC-2.2: manifest with user-owned file → conflict detected', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
    await fs.mkdir(path.join(dir, 'docs', 'epics'), { recursive: true });

    const existingContent = 'user edited content\n';
    await fs.writeFile(path.join(dir, 'docs', 'epics', 'project-prd.md'), existingContent);

    const manifest = {
      version: '0.1.0',
      files: {
        'docs/epics/project-prd.md': {
          ownership: 'user-owned',
          checksum: hashString(existingContent),
          path: 'docs/epics/project-prd.md',
        },
      },
    };
    await fs.writeFile(
      path.join(dir, '.ralph', 'manifest.json'),
      JSON.stringify(manifest),
    );

    const plan = { targetDir: dir };
    const writeMap = new Map([['docs/epics/project-prd.md', 'new prd content\n']]);

    const conflicts = await detectConflicts(plan, writeMap);

    assert.equal(conflicts.length, 1, 'should detect one conflict');
    assert.equal(conflicts[0].path, 'docs/epics/project-prd.md');
    assert.equal(conflicts[0].reason, 'user-owned');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('AC-2.3: manifest with installer-owned file, checksum unchanged → no conflict', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
    await fs.mkdir(path.join(dir, 'docs'), { recursive: true });

    const fileContent = '# Conventions\n';
    const filePath = path.join(dir, 'docs', 'project-conventions.md');
    await fs.writeFile(filePath, fileContent);
    const checksum = await hashFile(filePath);

    const manifest = {
      version: '0.1.0',
      files: {
        'docs/project-conventions.md': {
          ownership: 'installer-owned',
          checksum,
          path: 'docs/project-conventions.md',
        },
      },
    };
    await fs.writeFile(
      path.join(dir, '.ralph', 'manifest.json'),
      JSON.stringify(manifest),
    );

    const plan = { targetDir: dir };
    const writeMap = new Map([['docs/project-conventions.md', '# New Conventions\n']]);

    const conflicts = await detectConflicts(plan, writeMap);

    assert.equal(conflicts.length, 0, 'unchanged installer-owned file should not be a conflict');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('AC-2.4: manifest with installer-owned file, locally modified → conflict "locally-modified"', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
    await fs.mkdir(path.join(dir, 'docs'), { recursive: true });

    // File on disk has different content than what the manifest recorded
    await fs.writeFile(
      path.join(dir, 'docs', 'project-conventions.md'),
      'user modified this\n',
    );

    const manifest = {
      version: '0.1.0',
      files: {
        'docs/project-conventions.md': {
          ownership: 'installer-owned',
          checksum: 'sha256:original-checksum-that-no-longer-matches',
          path: 'docs/project-conventions.md',
        },
      },
    };
    await fs.writeFile(
      path.join(dir, '.ralph', 'manifest.json'),
      JSON.stringify(manifest),
    );

    const plan = { targetDir: dir };
    const writeMap = new Map([['docs/project-conventions.md', 'installer version\n']]);

    const conflicts = await detectConflicts(plan, writeMap);

    assert.equal(conflicts.length, 1, 'should detect one conflict');
    assert.equal(conflicts[0].reason, 'locally-modified');
    assert.ok(conflicts[0].existingChecksum?.startsWith('sha256:'), 'should include existing checksum');
    assert.equal(
      conflicts[0].manifestChecksum,
      'sha256:original-checksum-that-no-longer-matches',
      'should include manifest checksum',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('no conflicts when target files do not yet exist', async () => {
  const dir = await makeTempDir();
  try {
    const plan = { targetDir: dir };
    const writeMap = new Map([
      ['docs/project-conventions.md', '# New\n'],
      ['scripts/ralph-loop.sh', '#!/bin/bash\n'],
    ]);

    const conflicts = await detectConflicts(plan, writeMap);
    assert.equal(conflicts.length, 0, 'no conflicts when target files are absent');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── AC-3: Conflict Confirmation ─────────────────────────────────────────────

test('AC-3: no conflicts → returns full writeMap as approved', async () => {
  const plan = { targetDir: '/tmp/fake', force: false, yes: true };
  const writeMap = new Map([['scripts/ralph-loop.sh', '# script\n']]);
  const approved = await confirmConflicts(plan, [], writeMap, { log: () => {} });

  assert.ok(approved instanceof Map);
  assert.equal(approved.size, 1);
  assert.ok(approved.has('scripts/ralph-loop.sh'));
});

test('AC-3.1: force+yes → installer-owned conflicts overwrite, user-owned skipped', async () => {
  const logMessages = [];
  const plan = { targetDir: '/tmp/fake', force: true, yes: true };

  const writeMap = new Map([
    ['scripts/ralph-loop.sh', '# script\n'],       // installer-owned conflict
    ['docs/epics/project-prd.md', '# prd\n'],      // user-owned conflict
    ['docs/project-conventions.md', '# conv\n'],   // no conflict (always included)
  ]);

  const conflicts = [
    { path: 'scripts/ralph-loop.sh', reason: 'locally-modified' },
    { path: 'docs/epics/project-prd.md', reason: 'user-owned' },
  ];

  const approved = await confirmConflicts(plan, conflicts, writeMap, {
    log: (msg) => logMessages.push(msg),
  });

  assert.ok(approved instanceof Map);
  assert.ok(approved.has('scripts/ralph-loop.sh'), 'installer-owned conflict should be approved');
  assert.ok(!approved.has('docs/epics/project-prd.md'), 'user-owned should be skipped');
  assert.ok(approved.has('docs/project-conventions.md'), 'non-conflicting file should be included');
  assert.ok(
    logMessages.some((m) => m.includes('Skipping') && m.includes('project-prd.md')),
    'should log a warning about skipped user-owned file',
  );
});

test('AC-3.2: yes without force → exits non-zero, returns null, does not write', async () => {
  const exitCalls = [];
  const logMessages = [];
  const plan = { targetDir: '/tmp/fake', force: false, yes: true };

  const writeMap = new Map([['scripts/ralph-loop.sh', '# script\n']]);
  const conflicts = [{ path: 'scripts/ralph-loop.sh', reason: 'locally-modified' }];

  const result = await confirmConflicts(plan, conflicts, writeMap, {
    exit: (code) => exitCalls.push(code),
    log: (msg) => logMessages.push(msg),
  });

  assert.equal(result, null, 'should return null when exit is called');
  assert.equal(exitCalls.length, 1, 'exit should be called exactly once');
  assert.notEqual(exitCalls[0], 0, 'exit code should be non-zero');
  assert.ok(
    logMessages.some((m) => m.toLowerCase().includes('conflict')),
    'should log conflict information',
  );
});

test('AC-3.3: interactive — per-file confirmation with mocked prompts', async () => {
  const plan = { targetDir: '/tmp/fake', force: false, yes: false };

  const writeMap = new Map([
    ['scripts/ralph-loop.sh', '# script\n'],
    ['docs/epics/project-prd.md', '# prd\n'],
    ['docs/project-conventions.md', '# conv\n'], // no conflict, auto-approved
  ]);

  const conflicts = [
    { path: 'scripts/ralph-loop.sh', reason: 'locally-modified' },
    { path: 'docs/epics/project-prd.md', reason: 'user-owned' },
  ];

  // First conflicting file: 'take', second: 'keep'
  let selectCount = 0;
  const choices = ['take', 'keep'];

  const mockPrompts = {
    select: async () => choices[selectCount++],
    isCancel: () => false,
  };

  const approved = await confirmConflicts(plan, conflicts, writeMap, {
    prompts: mockPrompts,
    log: () => {},
  });

  assert.ok(approved instanceof Map);
  assert.ok(approved.has('scripts/ralph-loop.sh'), '"take" should include the file');
  assert.ok(!approved.has('docs/epics/project-prd.md'), '"keep" should exclude the file');
  assert.ok(approved.has('docs/project-conventions.md'), 'non-conflicting file should be auto-approved');
  assert.equal(selectCount, 2, 'select should be called once per conflicting file');
});

test('interactive backup choice: renames existing file and writes new', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'scripts'), { recursive: true });
    const existingContent = '# original\n';
    await fs.writeFile(path.join(dir, 'scripts', 'ralph-loop.sh'), existingContent);

    const plan = { targetDir: dir, force: false, yes: false };
    const writeMap = new Map([['scripts/ralph-loop.sh', '# new version\n']]);
    const conflicts = [{ path: 'scripts/ralph-loop.sh', reason: 'locally-modified' }];

    const mockPrompts = {
      select: async () => 'backup',
      isCancel: () => false,
    };

    const approved = await confirmConflicts(plan, conflicts, writeMap, {
      prompts: mockPrompts,
      log: () => {},
    });

    assert.ok(approved.has('scripts/ralph-loop.sh'), 'backup+take should include the file');

    // Verify the backup file was created
    const backupContent = await fs.readFile(
      path.join(dir, 'scripts', 'ralph-loop.sh.bak'),
      'utf8',
    );
    assert.equal(backupContent, existingContent, 'backup should contain original content');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── executeWrite ─────────────────────────────────────────────────────────────

test('executeWrite creates directories and writes all files', async () => {
  const dir = await makeTempDir();
  try {
    const approvedMap = new Map([
      ['scripts/ralph-loop.sh', '#!/bin/bash\necho "hello"\n'],
      ['docs/project-conventions.md', '# Conventions\n'],
    ]);

    const written = await executeWrite(dir, approvedMap);

    assert.deepEqual(written.sort(), ['docs/project-conventions.md', 'scripts/ralph-loop.sh'].sort());

    const loopContent = await fs.readFile(path.join(dir, 'scripts', 'ralph-loop.sh'), 'utf8');
    assert.ok(loopContent.includes('echo "hello"'));

    const convsContent = await fs.readFile(path.join(dir, 'docs', 'project-conventions.md'), 'utf8');
    assert.ok(convsContent.includes('# Conventions'));
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('executeWrite normalizes CRLF to LF', async () => {
  const dir = await makeTempDir();
  try {
    const approvedMap = new Map([['file.txt', 'line1\r\nline2\r\nline3\r\n']]);
    await executeWrite(dir, approvedMap);

    const content = await fs.readFile(path.join(dir, 'file.txt'), 'utf8');
    assert.ok(!content.includes('\r\n'), 'CRLF should be normalized to LF');
    assert.ok(content.includes('\n'), 'LF should be present');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── AC-4: Manifest Contents ──────────────────────────────────────────────────

test('AC-4.1: writeManifest produces valid JSON with required top-level fields', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'scripts'), { recursive: true });
    await fs.writeFile(path.join(dir, 'scripts', 'ralph-loop.sh'), '#!/bin/bash\n');

    const plan = {
      targetDir: dir,
      classification: 'empty',
      wizardAnswers: { appDir: 'src' },
    };

    const manifest = await writeManifest(plan, ['scripts/ralph-loop.sh']);

    assert.ok(typeof manifest.version === 'string', 'version should be a string');
    assert.ok(typeof manifest.installedAt === 'string', 'installedAt should be ISO string');
    assert.ok(typeof manifest.updatedAt === 'string', 'updatedAt should be ISO string');
    assert.ok(typeof manifest.files === 'object' && manifest.files !== null, 'files should be an object');
    assert.ok(typeof manifest.wizardAnswers === 'object', 'wizardAnswers should be an object');
    assert.ok(typeof manifest.targetClass === 'string', 'targetClass should be a string');

    // Verify file on disk is valid JSON
    const manifestPath = path.join(dir, '.ralph', 'manifest.json');
    const raw = await fs.readFile(manifestPath, 'utf8');
    const parsed = JSON.parse(raw);
    assert.equal(parsed.version, manifest.version);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('AC-4.2: all written files appear in manifest.files', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'scripts'), { recursive: true });
    await fs.mkdir(path.join(dir, 'docs'), { recursive: true });
    await fs.writeFile(path.join(dir, 'scripts', 'ralph-loop.sh'), '#!/bin/bash\n');
    await fs.writeFile(path.join(dir, 'docs', 'project-conventions.md'), '# Conventions\n');

    const plan = {
      targetDir: dir,
      classification: 'empty',
      wizardAnswers: {},
    };

    const manifest = await writeManifest(plan, [
      'scripts/ralph-loop.sh',
      'docs/project-conventions.md',
    ]);

    assert.ok('scripts/ralph-loop.sh' in manifest.files, 'ralph-loop.sh should be in manifest');
    assert.ok(
      'docs/project-conventions.md' in manifest.files,
      'project-conventions.md should be in manifest',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('AC-4.3: each file entry has ownership, checksum, and path', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'scripts'), { recursive: true });
    await fs.mkdir(path.join(dir, 'docs', 'epics'), { recursive: true });
    await fs.writeFile(path.join(dir, 'scripts', 'ralph-loop.sh'), '#!/bin/bash\n');
    await fs.writeFile(path.join(dir, 'docs', 'epics', 'project-prd.md'), '# PRD\n');

    const plan = { targetDir: dir, classification: 'empty', wizardAnswers: {} };
    const manifest = await writeManifest(plan, [
      'scripts/ralph-loop.sh',
      'docs/epics/project-prd.md',
    ]);

    for (const [filePath, entry] of Object.entries(manifest.files)) {
      assert.ok(
        entry.ownership === 'installer-owned' || entry.ownership === 'user-owned',
        `${filePath}: ownership should be installer-owned or user-owned, got ${entry.ownership}`,
      );
      assert.ok(
        entry.checksum?.startsWith('sha256:'),
        `${filePath}: checksum should start with "sha256:", got ${entry.checksum}`,
      );
      assert.equal(entry.path, filePath, `${filePath}: path field should match key`);
    }

    // Ownership classification verification
    assert.equal(
      manifest.files['scripts/ralph-loop.sh'].ownership,
      'installer-owned',
    );
    assert.equal(
      manifest.files['docs/epics/project-prd.md'].ownership,
      'user-owned',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('AC-4.4: wizardAnswers recorded verbatim from plan', async () => {
  const dir = await makeTempDir();
  try {
    const wizardAnswers = {
      appDir: 'frontend',
      checkpointCommand: 'make test',
      stackDescription: 'Vue 3 + Vite',
      loopRetries: 3,
    };

    const plan = { targetDir: dir, classification: 'empty', wizardAnswers };
    const manifest = await writeManifest(plan, []);

    assert.deepEqual(manifest.wizardAnswers, wizardAnswers, 'wizardAnswers must match exactly');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('AC-4.5: checksums are stable — same file content produces same checksum on re-read', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'scripts'), { recursive: true });
    await fs.writeFile(path.join(dir, 'scripts', 'ralph-loop.sh'), '#!/bin/bash\necho "stable"\n');

    const plan = { targetDir: dir, classification: 'empty', wizardAnswers: {} };

    const manifest1 = await writeManifest(plan, ['scripts/ralph-loop.sh']);
    const manifest2 = await writeManifest(plan, ['scripts/ralph-loop.sh']);

    assert.equal(
      manifest1.files['scripts/ralph-loop.sh'].checksum,
      manifest2.files['scripts/ralph-loop.sh'].checksum,
      'checksum should be stable across multiple reads',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── AC-5: End-to-End integration (write + manifest round-trip) ────────────────

test('AC-5: full write + manifest records files that can be re-detected as unchanged', async () => {
  const dir = await makeTempDir();
  try {
    const plan = {
      targetDir: dir,
      classification: 'empty',
      appDir: 'src',
      checkpointCommand: 'npm test',
      stackDescription: 'React + TypeScript',
      taskSource: 'scaffold',
      addGitignoreEntries: false,
      wizardAnswers: { appDir: 'src' },
      force: false,
      yes: true, // non-interactive, no conflicts expected in empty dir
    };

    const result = await writeInstall(plan, { log: () => {} });

    assert.equal(result.status, 'success');
    assert.ok(result.filesWritten > 0, 'should write at least one file');
    assert.ok(result.manifest, 'manifest should be returned');

    // .ralph/manifest.json should exist
    const manifestPath = path.join(dir, '.ralph', 'manifest.json');
    const raw = await fs.readFile(manifestPath, 'utf8');
    const manifest = JSON.parse(raw);
    assert.ok(Object.keys(manifest.files).length > 0, 'manifest should record written files');

    // Re-running detectConflicts with the same write map should find no conflicts
    // (all installer-owned files should match their manifest checksums)
    const writeMap = await buildWriteMap(plan);
    const conflicts = await detectConflicts(plan, writeMap);
    const installerOwnedConflicts = conflicts.filter((c) => c.reason !== 'user-owned');
    assert.equal(
      installerOwnedConflicts.length,
      0,
      'installer-owned files should have no conflicts immediately after install',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('AC-5 user-owned: re-run install preserves user-owned file despite conflict', async () => {
  const dir = await makeTempDir();
  try {
    // Write a user-owned file before install (simulating existing project content)
    await fs.mkdir(path.join(dir, 'docs', 'epics'), { recursive: true });
    const userContent = 'user edited PRD\n';
    await fs.writeFile(path.join(dir, 'docs', 'epics', 'project-prd.md'), userContent);

    // Set up a manifest that marks this file as user-owned
    await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
    const existingManifest = {
      version: '0.1.0',
      files: {
        'docs/epics/project-prd.md': {
          ownership: 'user-owned',
          checksum: hashString(userContent),
          path: 'docs/epics/project-prd.md',
        },
      },
    };
    await fs.writeFile(
      path.join(dir, '.ralph', 'manifest.json'),
      JSON.stringify(existingManifest),
    );

    const plan = {
      targetDir: dir,
      classification: 'existing-install',
      appDir: 'src',
      checkpointCommand: 'npm test',
      stackDescription: 'React',
      taskSource: 'scaffold',
      addGitignoreEntries: false,
      wizardAnswers: {},
      force: true,
      yes: true, // force+yes: skip user-owned, overwrite installer-owned
    };

    await writeInstall(plan, { log: () => {} });

    // User-owned file should be unchanged
    const afterContent = await fs.readFile(
      path.join(dir, 'docs', 'epics', 'project-prd.md'),
      'utf8',
    );
    assert.equal(afterContent, userContent, 'user-owned file should not be overwritten');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── hashFile / hashString consistency ───────────────────────────────────────

test('hashFile and hashString produce identical results for same content', async () => {
  const dir = await makeTempDir();
  try {
    const content = 'line 1\nline 2\n';
    const filePath = path.join(dir, 'test.txt');
    await fs.writeFile(filePath, content, 'utf8');

    const fromFile = await hashFile(filePath);
    const fromString = hashString(content);

    assert.equal(fromFile, fromString, 'hashFile and hashString should agree');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('hashString normalizes CRLF so checksums are platform-stable', () => {
  const lf = 'line1\nline2\n';
  const crlf = 'line1\r\nline2\r\n';
  assert.equal(hashString(lf), hashString(crlf), 'LF and CRLF should produce the same hash');
});

// ─── buildWriteMap ─────────────────────────────────────────────────────────────

test('buildWriteMap always includes project-conventions.md', async () => {
  const plan = {
    targetDir: os.tmpdir(),
    taskSource: 'existing',
    appDir: 'src',
    checkpointCommand: 'npm test',
    stackDescription: 'React',
    addGitignoreEntries: false,
  };

  const writeMap = await buildWriteMap(plan);
  assert.ok(writeMap.has('docs/project-conventions.md'), 'project-conventions.md should always be present');
});

test('buildWriteMap includes scaffold docs only when taskSource is scaffold', async () => {
  const basePlan = {
    targetDir: os.tmpdir(),
    appDir: 'src',
    checkpointCommand: 'npm test',
    stackDescription: 'React',
    addGitignoreEntries: false,
  };

  const scaffoldMap = await buildWriteMap({ ...basePlan, taskSource: 'scaffold' });
  const existingMap = await buildWriteMap({ ...basePlan, taskSource: 'existing' });

  assert.ok(scaffoldMap.has('docs/epics/project-prd.md'), 'scaffold should include prd');
  assert.ok(scaffoldMap.has('docs/epics/project-stories.md'), 'scaffold should include stories');
  assert.ok(!existingMap.has('docs/epics/project-prd.md'), 'existing should not include prd');
  assert.ok(!existingMap.has('docs/epics/project-stories.md'), 'existing should not include stories');
});

test('buildWriteMap writes the example PRD/epic verbatim when taskSource is example', async () => {
  const plan = {
    targetDir: os.tmpdir(),
    appDir: 'src',
    checkpointCommand: 'cd src && npm run build && npm test --if-present',
    stackDescription: 'React 19 + Vite + TypeScript (strict)',
    addGitignoreEntries: false,
    taskSource: 'example',
  };

  const map = await buildWriteMap(plan);

  // Lands at the repo's own real paths, not the scaffold stub paths.
  assert.ok(map.has('docs/prd.md'), 'example writes docs/prd.md');
  assert.ok(map.has('docs/epics/exchange-rates-dashboard.md'), 'example writes the exchange-rates epic');
  assert.ok(!map.has('docs/epics/project-prd.md'), 'example must not write the scaffold prd stub');
  assert.ok(!map.has('docs/epics/project-stories.md'), 'example must not write the scaffold stories stub');

  const prd = map.get('docs/prd.md');
  assert.ok(prd.includes('Exchange Rates'), 'example prd carries the real authored content');
  assert.ok(!/\{\{[A-Z_]+\}\}/.test(prd), 'example prd is written verbatim — no {{…}} placeholders');

  const epic = map.get('docs/epics/exchange-rates-dashboard.md');
  assert.ok(/^###\s+Story\s+1\.1:/m.test(epic), 'example epic keeps its story headers');
  assert.ok(/^##\s+Epic\s+1:/m.test(epic), 'example epic keeps its `## Epic 1:` header (progress UI needs it)');
});

test('buildWriteMap uses default values when optional plan fields are missing', async () => {
  const plan = {
    targetDir: os.tmpdir(),
    taskSource: 'existing',
    addGitignoreEntries: false,
  };

  // Should not throw even with missing appDir/checkpointCommand/stackDescription
  const writeMap = await buildWriteMap(plan);
  assert.ok(writeMap.size > 0, 'should produce a non-empty write map with defaults');
});

test('example install records the PRD/epic as user-owned and ships the example guide', async () => {
  const dir = await makeTempDir();
  try {
    const plan = {
      targetDir: dir,
      classification: 'empty',
      appDir: 'src',
      checkpointCommand: 'cd src && npm run build && npm test --if-present',
      stackDescription: 'React 19 + Vite + TypeScript (strict)',
      taskSource: 'example',
      addGitignoreEntries: false,
      wizardAnswers: {},
      force: false,
      yes: true,
      skipBmad: true,
    };

    const result = await writeInstall(plan, {
      log: () => {},
      installBmad: async () => ({ success: true }),
    });

    assert.equal(result.status, 'success');
    // Ownership falls out of getOwnership()'s default → user-owned, so update/uninstall
    // never clobber a user's mid-demo edits.
    assert.equal(result.manifest.files['docs/prd.md'].ownership, 'user-owned');
    assert.equal(
      result.manifest.files['docs/epics/exchange-rates-dashboard.md'].ownership,
      'user-owned',
    );

    // The GETTING-STARTED guide is the example variant: honest "ready to run" copy.
    const guide = await fs.readFile(path.join(dir, 'GETTING-STARTED.md'), 'utf8');
    assert.ok(/ready to run|ready-to-run/i.test(guide), 'example guide advertises ready-to-run');
    assert.ok(/no TODOs?/i.test(guide), 'example guide states there are no TODOs to fill');
    assert.ok(
      guide.includes('docs/epics/exchange-rates-dashboard.md'),
      'example guide points the run command at the real epic path',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── BMAD integration ─────────────────────────────────────────────────────────

test('writeInstall calls installBmad when plan.skipBmad is false', async () => {
  const dir = await makeTempDir();
  try {
    let bmadCalled = false;
    const plan = {
      targetDir: dir,
      classification: 'empty',
      appDir: 'src',
      checkpointCommand: 'npm test',
      stackDescription: 'React',
      taskSource: 'scaffold',
      addGitignoreEntries: false,
      wizardAnswers: {},
      force: false,
      yes: true,
      skipBmad: false,
    };

    const result = await writeInstall(plan, {
      log: () => {},
      installBmad: async () => { bmadCalled = true; return { success: true }; },
    });

    assert.equal(result.status, 'success');
    assert.ok(bmadCalled, 'installBmad should be called when skipBmad is false');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('writeInstall skips installBmad when plan.skipBmad is true', async () => {
  const dir = await makeTempDir();
  try {
    let bmadCalled = false;
    const plan = {
      targetDir: dir,
      classification: 'empty',
      appDir: 'src',
      checkpointCommand: 'npm test',
      stackDescription: 'React',
      taskSource: 'scaffold',
      addGitignoreEntries: false,
      wizardAnswers: {},
      force: false,
      yes: true,
      skipBmad: true,
    };

    await writeInstall(plan, {
      log: () => {},
      installBmad: async () => { bmadCalled = true; return { success: true }; },
    });

    assert.ok(!bmadCalled, 'installBmad should not be called when skipBmad is true');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('writeInstall skips installBmad when plan.skipBmad is undefined (backward compat)', async () => {
  const dir = await makeTempDir();
  try {
    let bmadCalled = false;
    const plan = {
      targetDir: dir,
      classification: 'empty',
      appDir: 'src',
      checkpointCommand: 'npm test',
      stackDescription: 'React',
      taskSource: 'scaffold',
      addGitignoreEntries: false,
      wizardAnswers: {},
      force: false,
      yes: true,
      // skipBmad deliberately omitted (undefined)
    };

    await writeInstall(plan, {
      log: () => {},
      installBmad: async () => { bmadCalled = true; return { success: true }; },
    });

    assert.ok(!bmadCalled, 'installBmad should not be called when skipBmad is undefined');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── executeUpdate ────────────────────────────────────────────────────────────

async function setupInitialInstall(dir) {
  const plan = {
    targetDir: dir,
    classification: 'empty',
    appDir: 'src',
    checkpointCommand: 'npm test',
    stackDescription: 'React + TypeScript',
    taskSource: 'scaffold',
    addGitignoreEntries: false,
    wizardAnswers: { appDir: 'src', checkpointCommand: 'npm test', stackDescription: 'React + TypeScript' },
    force: false,
    yes: true,
    skipBmad: true,
  };
  await writeInstall(plan, { log: () => {} });
  return plan;
}

async function readManifest(dir) {
  const raw = await fs.readFile(path.join(dir, '.ralph', 'manifest.json'), 'utf8');
  return JSON.parse(raw);
}

test('executeUpdate: no conflicts → installer-owned files replaced, user-owned untouched', async () => {
  const dir = await makeTempDir();
  try {
    const plan = await setupInitialInstall(dir);

    // Read the original manifest
    const originalManifest = await readManifest(dir);
    const installerFiles = Object.entries(originalManifest.files)
      .filter(([, e]) => e.ownership === 'installer-owned')
      .map(([p]) => p);
    assert.ok(installerFiles.length > 0, 'there should be installer-owned files');

    // delta: no modifications
    const delta = {
      installerOwned: installerFiles.map((p) => ({
        path: p,
        checksum: originalManifest.files[p].checksum,
        currentChecksum: originalManifest.files[p].checksum,
        isModified: false,
      })),
      userOwned: [],
      missing: [],
    };

    const result = await executeUpdate(dir, plan, delta, {}, { log: () => {} });

    assert.ok(result.writtenFiles.length > 0, 'installer-owned files should be re-written');
    assert.equal(result.backedUpFiles.length, 0, 'no backups expected');

    // Manifest should be updated
    const updatedManifest = await readManifest(dir);
    assert.ok(updatedManifest.updatedAt, 'updatedAt should be set');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('executeUpdate: conflict "keep" → modified file skipped, not in writtenFiles', async () => {
  const dir = await makeTempDir();
  try {
    const plan = await setupInitialInstall(dir);
    const originalManifest = await readManifest(dir);

    const targetFile = 'scripts/prompts/common/project-conventions.md';
    const originalChecksum = originalManifest.files[targetFile]?.checksum;
    assert.ok(originalChecksum, `${targetFile} should be in manifest`);

    // Simulate local modification
    const fullPath = path.join(dir, targetFile);
    await fs.appendFile(fullPath, '\n# Local modification\n', 'utf8');
    const modifiedChecksum = await hashFile(fullPath);

    const delta = {
      installerOwned: [{ path: targetFile, checksum: originalChecksum, currentChecksum: modifiedChecksum, isModified: true }],
      userOwned: [],
      missing: [],
    };

    const result = await executeUpdate(dir, plan, delta, { [targetFile]: 'keep' }, { log: () => {} });

    assert.ok(!result.writtenFiles.includes(targetFile), '"keep" file should not be in writtenFiles');
    assert.equal(result.backedUpFiles.length, 0, 'no backup for "keep"');

    // File on disk should still have the local modification
    const afterContent = await fs.readFile(fullPath, 'utf8');
    assert.ok(afterContent.includes('# Local modification'), 'user modification should be preserved');

    // Manifest checksum for this file should be the PRIOR installer checksum (not updated)
    const updatedManifest = await readManifest(dir);
    assert.equal(
      updatedManifest.files[targetFile]?.checksum,
      originalChecksum,
      '"keep" file manifest checksum must stay as prior checksum so next update detects it as modified',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('executeUpdate: conflict "backup" → existing file renamed, new version written', async () => {
  const dir = await makeTempDir();
  try {
    const plan = await setupInitialInstall(dir);
    const originalManifest = await readManifest(dir);

    const targetFile = 'scripts/prompts/common/project-conventions.md';
    const originalChecksum = originalManifest.files[targetFile]?.checksum;

    const fullPath = path.join(dir, targetFile);
    const localModification = '\n# Backup test modification\n';
    await fs.appendFile(fullPath, localModification, 'utf8');
    const modifiedChecksum = await hashFile(fullPath);

    const delta = {
      installerOwned: [{ path: targetFile, checksum: originalChecksum, currentChecksum: modifiedChecksum, isModified: true }],
      userOwned: [],
      missing: [],
    };

    const result = await executeUpdate(dir, plan, delta, { [targetFile]: 'backup' }, { log: () => {} });

    assert.ok(result.writtenFiles.includes(targetFile), 'file should be in writtenFiles for "backup"');
    assert.ok(result.backedUpFiles.includes(targetFile), 'file should be in backedUpFiles');

    // Backup file should exist with the modified content
    const backupContent = await fs.readFile(`${fullPath}.backup`, 'utf8');
    assert.ok(backupContent.includes('# Backup test modification'), 'backup should contain local modification');

    // Original path should now have new version (no modification)
    const newContent = await fs.readFile(fullPath, 'utf8');
    assert.ok(!newContent.includes('# Backup test modification'), 'new file should not have user modification');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('executeUpdate: user-owned files are never written', async () => {
  const dir = await makeTempDir();
  try {
    const plan = await setupInitialInstall(dir);
    const originalManifest = await readManifest(dir);

    // Collect user-owned files
    const userOwnedFiles = Object.entries(originalManifest.files)
      .filter(([, e]) => e.ownership === 'user-owned')
      .map(([p]) => p);

    // Modify a user-owned file to detect if executeUpdate touches it
    const userFile = userOwnedFiles[0];
    assert.ok(userFile, 'there should be at least one user-owned file');
    const userContent = 'USER OWNED CONTENT MUST NOT BE OVERWRITTEN\n';
    await fs.writeFile(path.join(dir, userFile), userContent, 'utf8');

    const delta = { installerOwned: [], userOwned: [], missing: [] };

    await executeUpdate(dir, plan, delta, {}, { log: () => {} });

    const afterContent = await fs.readFile(path.join(dir, userFile), 'utf8');
    assert.equal(afterContent, userContent, 'user-owned file must be byte-identical after update');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('executeUpdate: manifest updated with new version and checksums for replaced files', async () => {
  const dir = await makeTempDir();
  try {
    const plan = await setupInitialInstall(dir);
    const originalManifest = await readManifest(dir);

    const installerFile = 'scripts/prompts/common/project-conventions.md';
    const delta = {
      installerOwned: [{
        path: installerFile,
        checksum: originalManifest.files[installerFile]?.checksum,
        currentChecksum: originalManifest.files[installerFile]?.checksum,
        isModified: false,
      }],
      userOwned: [],
      missing: [],
    };

    await executeUpdate(dir, plan, delta, {}, { log: () => {} });

    const updatedManifest = await readManifest(dir);
    assert.ok(updatedManifest.version, 'manifest must have a version after update');
    assert.ok(updatedManifest.files[installerFile]?.checksum?.startsWith('sha256:'), 'checksum must be updated');
    assert.deepEqual(updatedManifest.wizardAnswers, originalManifest.wizardAnswers, 'wizardAnswers must be preserved');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
