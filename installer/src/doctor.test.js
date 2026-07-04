import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { runDoctor, renderChecklist } from './doctor.js';
import { hashString } from './writer.js';

async function makeTempDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'ralph-doctor-'));
}

// Always-found mock: both jq and claude found
function mockCommandFound(cmd) {
  return Promise.resolve({ found: true, path: `/usr/bin/${cmd}` });
}

// Never-found mock: no commands found
function mockCommandNotFound() {
  return Promise.resolve({ found: false });
}

// Selective mock: jq found, claude not found
function mockJqOnly(cmd) {
  if (cmd === 'jq') return Promise.resolve({ found: true, path: '/usr/bin/jq' });
  return Promise.resolve({ found: false });
}

/**
 * Write a minimal valid manifest to dir/.ralph/manifest.json.
 * @param {string} dir - temp directory
 * @param {Record<string, string>} files - { relPath: content } for files to create and manifest
 */
async function writeFixture(dir, files = {}) {
  await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });

  const manifestFiles = {};
  for (const [relPath, content] of Object.entries(files)) {
    const fullPath = path.join(dir, relPath);
    await fs.mkdir(path.dirname(fullPath), { recursive: true });
    await fs.writeFile(fullPath, content, 'utf8');
    const normalized = content.replace(/\r\n/g, '\n');
    const crypto = await import('node:crypto');
    const checksum = 'sha256:' + crypto.default.createHash('sha256').update(normalized).digest('hex');
    manifestFiles[relPath] = { ownership: 'installer-owned', checksum, path: relPath };
  }

  const manifest = {
    version: '0.1.0',
    installedAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    files: manifestFiles,
    wizardAnswers: {},
    targetClass: 'empty',
  };

  await fs.writeFile(
    path.join(dir, '.ralph', 'manifest.json'),
    JSON.stringify(manifest, null, 2),
    'utf8',
  );

  return manifest;
}

// ─── AC-3: Manifest Validation ───────────────────────────────────────────────

test('doctor: fresh install with valid manifest → all file checks pass', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {
      'scripts/ralph-loop.sh': '#!/bin/bash\necho "loop"\n',
      'docs/project-conventions.md': '# Conventions\n',
    });

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const fileFindings = findings.filter((f) => f.check.startsWith('file-'));
    assert.ok(
      fileFindings.every((f) => f.status === 'pass'),
      'all file checks should pass for a fresh fixture',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: fresh install → result.passed is true when all checks pass', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {
      'scripts/ralph-loop.sh': '#!/bin/bash\necho "loop"\n',
    });

    const result = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    assert.equal(result.passed, true, 'result.passed should be true when all checks pass');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: missing manifest → manifest-exists finding fails', async () => {
  const dir = await makeTempDir();
  try {
    // No manifest written — just an empty directory
    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const manifestFinding = findings.find((f) => f.check === 'manifest-exists');
    assert.ok(manifestFinding, 'should have a manifest-exists finding');
    assert.equal(manifestFinding.status, 'fail', 'manifest-exists check should fail');
    assert.ok(
      manifestFinding.message.includes('.ralph/manifest.json'),
      'message should mention the manifest path',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: missing manifest → other checks still run (no bail)', async () => {
  const dir = await makeTempDir();
  try {
    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    // jq and claude checks should still appear even without a manifest
    const jqFinding = findings.find((f) => f.check === 'jq-available');
    const claudeFinding = findings.find((f) => f.check === 'claude-cli-available');
    assert.ok(jqFinding, 'jq-available check should run even without manifest');
    assert.ok(claudeFinding, 'claude-cli-available check should run even without manifest');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: missing file in manifest → file-exists check fails', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {
      'scripts/ralph-loop.sh': '#!/bin/bash\necho "loop"\n',
    });

    // Delete the file after manifest was written to simulate missing file
    await fs.unlink(path.join(dir, 'scripts', 'ralph-loop.sh'));

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const missingFinding = findings.find((f) => f.check === 'file-exists:scripts/ralph-loop.sh');
    assert.ok(missingFinding, 'should find a file-exists finding for the missing file');
    assert.equal(missingFinding.status, 'fail');
    assert.ok(
      missingFinding.message.includes('scripts/ralph-loop.sh'),
      'message should name the missing file',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: missing file → result.passed is false', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {
      'docs/project-conventions.md': '# Conventions\n',
    });

    await fs.unlink(path.join(dir, 'docs', 'project-conventions.md'));

    const result = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    assert.equal(result.passed, false, 'should fail when a file is missing');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── AC-3: Checksum Validation ────────────────────────────────────────────────

test('doctor: user-editable file drift (project-conventions.md) → INFO, doctor still passes', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {
      'docs/project-conventions.md': '# Conventions\n',
    });

    // The outro invites editing this file. Divergence must NOT be a red failure.
    await fs.appendFile(
      path.join(dir, 'docs', 'project-conventions.md'),
      '\n# User modification\n',
    );

    const result = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const failFinding = result.findings.find(
      (f) => f.check === 'file-checksum:docs/project-conventions.md',
    );
    assert.ok(!failFinding, 'must not emit a red checksum FAIL for a user-editable file');

    const infoFinding = result.findings.find(
      (f) => f.check === 'file-customized:docs/project-conventions.md',
    );
    assert.ok(infoFinding, 'should emit an informational customized finding');
    assert.equal(infoFinding.informational, true);
    assert.equal(result.passed, true, 'editing an invited-to-edit file must not fail doctor');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: ralph-owned file drift (ralph-loop.sh) → FAIL with an update remediation', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {
      'scripts/ralph-loop.sh': '#!/bin/bash\necho loop\n',
    });

    await fs.appendFile(path.join(dir, 'scripts', 'ralph-loop.sh'), '\n# tampered\n');

    const result = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const finding = result.findings.find(
      (f) => f.check === 'file-checksum:scripts/ralph-loop.sh',
    );
    assert.ok(finding, 'ralph-owned drift should FAIL');
    assert.equal(finding.status, 'fail');
    assert.ok(/update/i.test(finding.message), 'FAIL line must carry a remediation command');
    assert.equal(result.passed, false);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: corrupted manifest → distinct corrupted FAIL (not "not found")', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, '.ralph'), { recursive: true });
    await fs.writeFile(path.join(dir, '.ralph', 'manifest.json'), '{bad json', 'utf8');

    const result = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const finding = result.findings.find((f) => f.check === 'manifest-valid');
    assert.ok(finding, 'should emit a manifest-valid finding for corruption');
    assert.ok(/corrupted/i.test(finding.message), 'message must say corrupted');
    assert.equal(result.passed, false);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: orphaned install (loop files but no manifest) → adopt-them message', async () => {
  const dir = await makeTempDir();
  try {
    await fs.mkdir(path.join(dir, 'scripts'), { recursive: true });
    await fs.writeFile(path.join(dir, 'scripts', 'ralph-loop.sh'), '#!/bin/bash\n', 'utf8');

    const result = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const finding = result.findings.find((f) => f.check === 'manifest-exists');
    assert.ok(finding, 'should emit a manifest-exists finding');
    assert.ok(/found loop files but no manifest/i.test(finding.message), finding.message);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: missing-file FAIL carries an install remediation', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, { 'scripts/ralph-loop.sh': '#!/bin/bash\n' });
    await fs.unlink(path.join(dir, 'scripts', 'ralph-loop.sh'));

    const result = await runDoctor(dir, { log: () => {}, checkCommand: mockCommandFound });
    const finding = result.findings.find((f) => f.check === 'file-exists:scripts/ralph-loop.sh');
    assert.ok(/install/i.test(finding.message), 'missing-file FAIL must name a remediation');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: unmodified file passes checksum check', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {
      'docs/project-conventions.md': '# Conventions\n',
    });

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const checksumFinding = findings.find(
      (f) => f.check === 'file-checksum:docs/project-conventions.md',
    );
    // No checksum finding means it passed (no finding emitted for passing checksums — only failures)
    // OR if a finding is emitted, it should be pass
    if (checksumFinding) {
      assert.equal(checksumFinding.status, 'pass');
    }
    // If no finding, that's also fine — the absence of a fail is a pass
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── AC-4: CLI Tool Validation ────────────────────────────────────────────────

test('doctor: both jq and claude found → tool checks pass', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {});

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const jqFinding = findings.find((f) => f.check === 'jq-available');
    const claudeFinding = findings.find((f) => f.check === 'claude-cli-available');

    assert.ok(jqFinding, 'jq-available finding should be present');
    assert.equal(jqFinding.status, 'pass');

    assert.ok(claudeFinding, 'claude-cli-available finding should be present');
    assert.equal(claudeFinding.status, 'pass');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: jq missing → jq-available fails with helpful message', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {});

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: (cmd) =>
        cmd === 'jq'
          ? Promise.resolve({ found: false })
          : Promise.resolve({ found: true, path: `/usr/bin/${cmd}` }),
    });

    const jqFinding = findings.find((f) => f.check === 'jq-available');
    assert.ok(jqFinding);
    assert.equal(jqFinding.status, 'fail');
    assert.ok(jqFinding.message.includes('jq'), 'message should mention jq');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: claude missing → claude-cli-available fails with helpful message', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {});

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: (cmd) =>
        cmd === 'claude'
          ? Promise.resolve({ found: false })
          : Promise.resolve({ found: true, path: `/usr/bin/${cmd}` }),
    });

    const claudeFinding = findings.find((f) => f.check === 'claude-cli-available');
    assert.ok(claudeFinding);
    assert.equal(claudeFinding.status, 'fail');
    assert.ok(claudeFinding.message.includes('claude'), 'message should mention claude');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: both jq and claude missing → both checks fail', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {});

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandNotFound,
    });

    const jqFinding = findings.find((f) => f.check === 'jq-available');
    const claudeFinding = findings.find((f) => f.check === 'claude-cli-available');

    assert.equal(jqFinding?.status, 'fail');
    assert.equal(claudeFinding?.status, 'fail');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── AC-5: Epic Header Parsing ────────────────────────────────────────────────

test('doctor: valid story headers in docs/epics/project-stories.md → pass with count', async () => {
  const dir = await makeTempDir();
  try {
    const storiesContent = `# Project Stories

### Story 1.1: App shell

Content here.

### Story 1.2: Persistence

More content.

### Story 2.1: Advanced

Yet more.
`;
    await writeFixture(dir, {
      'docs/epics/project-stories.md': storiesContent,
    });

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const epicFinding = findings.find((f) =>
      f.check === 'epic-headers:docs/epics/project-stories.md',
    );
    assert.ok(epicFinding, 'should have an epic-headers finding for project-stories.md');
    assert.equal(epicFinding.status, 'pass');
    assert.ok(
      epicFinding.message.includes('3'),
      'message should report the correct story count',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: malformed story headers → epic-headers check fails', async () => {
  const dir = await makeTempDir();
  try {
    // Headers with "### Story" but not matching the X.Y numeric format
    const storiesContent = `# Project Stories

### Story alpha: Malformed header

Content.

### Story beta.1: Also malformed

Content.
`;
    await writeFixture(dir, {
      'docs/epics/project-stories.md': storiesContent,
    });

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const epicFinding = findings.find((f) =>
      f.check === 'epic-headers:docs/epics/project-stories.md',
    );
    assert.ok(epicFinding, 'should have an epic-headers finding');
    assert.equal(epicFinding.status, 'fail');
    assert.ok(
      epicFinding.message.includes('parseable') || epicFinding.message.includes('format'),
      'message should indicate a format problem',
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: no epic files in manifest → epic check is skipped (no finding)', async () => {
  const dir = await makeTempDir();
  try {
    // Fixture with no epic files
    await writeFixture(dir, {
      'scripts/ralph-loop.sh': '#!/bin/bash\n',
    });

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    const epicFindings = findings.filter((f) => f.check.startsWith('epic-headers:'));
    assert.equal(epicFindings.length, 0, 'no epic findings when epic files are absent');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: epic file exists on disk but has no Story headers → skip (not an error)', async () => {
  const dir = await makeTempDir();
  try {
    // File has no "### Story" at all — not malformed, just no stories yet
    const storiesContent = `# Project Stories\n\nNo stories defined yet.\n`;
    await writeFixture(dir, {
      'docs/epics/project-stories.md': storiesContent,
    });

    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    // If there are no "### Story" patterns at all, no finding is emitted (we skip)
    const epicFinding = findings.find((f) =>
      f.check === 'epic-headers:docs/epics/project-stories.md',
    );
    // Should NOT fail — only fails when headers exist but are malformed
    if (epicFinding) {
      assert.notEqual(
        epicFinding.status,
        'fail',
        'should not fail when no story headers are present at all',
      );
    }
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── AC-6: Exit Code (via result.passed) ─────────────────────────────────────

test('doctor: result.passed is true when all checks pass', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {
      'scripts/ralph-loop.sh': '#!/bin/bash\n',
    });

    const result = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    assert.equal(result.passed, true);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: result.passed is false when any check fails', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {
      'scripts/ralph-loop.sh': '#!/bin/bash\n',
    });

    // Delete a file to trigger a failure
    await fs.unlink(path.join(dir, 'scripts', 'ralph-loop.sh'));

    const result = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    assert.equal(result.passed, false);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── AC-7: Checklist Rendering ────────────────────────────────────────────────

test('renderChecklist: non-TTY output has no ANSI codes', () => {
  const findings = [
    { check: 'test-pass', status: 'pass', message: 'Everything fine' },
    { check: 'test-fail', status: 'fail', message: 'Something broke' },
  ];

  const output = renderChecklist(findings, false);
  assert.ok(!output.includes('\x1b['), 'non-TTY output should have no ANSI codes');
});

test('renderChecklist: TTY output includes ANSI codes for failures', () => {
  const findings = [
    { check: 'test-fail', status: 'fail', message: 'Something broke' },
  ];

  const output = renderChecklist(findings, true);
  assert.ok(output.includes('\x1b[31m'), 'TTY output should include red ANSI code for failures');
  assert.ok(output.includes('\x1b[0m'), 'TTY output should include reset ANSI code');
});

test('renderChecklist: TTY output for pass findings has no fail color', () => {
  const findings = [
    { check: 'test-pass', status: 'pass', message: 'All good' },
  ];

  const output = renderChecklist(findings, true);
  assert.ok(!output.includes('\x1b[31m'), 'pass findings should not have red color');
});

test('renderChecklist: summary says "All checks passed" when no failures', () => {
  const findings = [
    { check: 'a', status: 'pass', message: 'OK' },
    { check: 'b', status: 'pass', message: 'Also OK' },
  ];

  const output = renderChecklist(findings, false);
  assert.ok(output.includes('All checks passed'), 'should say "All checks passed" on success');
});

test('renderChecklist: summary reports failure count when checks fail', () => {
  const findings = [
    { check: 'a', status: 'pass', message: 'OK' },
    { check: 'b', status: 'fail', message: 'Broken' },
    { check: 'c', status: 'fail', message: 'Also broken' },
  ];

  const output = renderChecklist(findings, false);
  assert.ok(output.includes('2'), 'should include the failure count');
  assert.ok(output.includes('failed'), 'should include the word "failed"');
});

test('renderChecklist: uses ✓ for pass and ✗ for fail', () => {
  const findings = [
    { check: 'a', status: 'pass', message: 'Good' },
    { check: 'b', status: 'fail', message: 'Bad' },
  ];

  const output = renderChecklist(findings, false);
  assert.ok(output.includes('✓'), 'should use ✓ for pass');
  assert.ok(output.includes('✗'), 'should use ✗ for fail');
});

test('renderChecklist: includes finding messages in output', () => {
  const findings = [
    { check: 'a', status: 'pass', message: 'jq found at /usr/bin/jq' },
    { check: 'b', status: 'fail', message: 'Required file missing: scripts/ralph-loop.sh' },
  ];

  const output = renderChecklist(findings, false);
  assert.ok(output.includes('jq found at /usr/bin/jq'), 'should include pass message');
  assert.ok(
    output.includes('Required file missing: scripts/ralph-loop.sh'),
    'should include fail message',
  );
});

// ─── Refresh: ralph-watch.sh present + executable ─────────────────────────────

async function chmodx(dir, rel) {
  await fs.chmod(path.join(dir, rel), 0o755);
}

test('doctor: ralph-watch.sh present + executable → check passes', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, { 'scripts/ralph-watch.sh': '#!/usr/bin/env bash\necho hi\n' });
    await chmodx(dir, 'scripts/ralph-watch.sh');

    const { findings } = await runDoctor(dir, { log: () => {}, checkCommand: mockCommandFound });
    const f = findings.find((x) => x.check === 'ralph-watch-executable');
    assert.ok(f, 'should emit a ralph-watch-executable finding');
    assert.equal(f.status, 'pass');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: ralph-watch.sh present but NOT executable → check fails', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, { 'scripts/ralph-watch.sh': '#!/usr/bin/env bash\necho hi\n' });
    await fs.chmod(path.join(dir, 'scripts/ralph-watch.sh'), 0o644);

    const result = await runDoctor(dir, { log: () => {}, checkCommand: mockCommandFound });
    const f = result.findings.find((x) => x.check === 'ralph-watch-executable');
    assert.ok(f, 'should emit a ralph-watch-executable finding');
    assert.equal(f.status, 'fail');
    assert.equal(result.passed, false, 'a non-executable watch script should fail the doctor');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: ralph-watch.sh in manifest but missing on disk → check fails', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, { 'scripts/ralph-watch.sh': '#!/usr/bin/env bash\n' });
    await fs.unlink(path.join(dir, 'scripts/ralph-watch.sh'));

    const { findings } = await runDoctor(dir, { log: () => {}, checkCommand: mockCommandFound });
    const f = findings.find((x) => x.check === 'ralph-watch-executable');
    assert.ok(f, 'should emit a ralph-watch-executable finding');
    assert.equal(f.status, 'fail');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: ralph-watch check is skipped when the install did not ship it', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, { 'scripts/ralph-loop.sh': '#!/bin/bash\n' });
    await chmodx(dir, 'scripts/ralph-loop.sh');

    const { findings } = await runDoctor(dir, { log: () => {}, checkCommand: mockCommandFound });
    const f = findings.find((x) => x.check === 'ralph-watch-executable');
    assert.equal(f, undefined, 'no watch finding when the manifest does not list ralph-watch.sh');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── Refresh: gh check is informational (never fails, both ways) ──────────────

test('doctor: gh present + authenticated → informational pass, does not fail doctor', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {});
    const result = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
      checkGhAuth: async () => ({ authenticated: true }),
    });
    const f = result.findings.find((x) => x.check === 'gh-available');
    assert.ok(f, 'should emit a gh-available finding');
    assert.equal(f.status, 'pass');
    assert.equal(f.informational, true);
    assert.equal(result.passed, true, 'gh informational finding must not fail an otherwise-clean install');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('doctor: gh missing → still informational, still does not fail doctor', async () => {
  const dir = await makeTempDir();
  try {
    await writeFixture(dir, {});
    const result = await runDoctor(dir, {
      log: () => {},
      checkCommand: (cmd) =>
        cmd === 'gh' ? Promise.resolve({ found: false }) : Promise.resolve({ found: true, path: `/usr/bin/${cmd}` }),
    });
    const f = result.findings.find((x) => x.check === 'gh-available');
    assert.ok(f, 'should emit a gh-available finding even when gh is absent');
    assert.equal(f.status, 'pass', 'gh finding never carries a fail status');
    assert.equal(f.informational, true);
    assert.ok(/GitHub-issue workflow/i.test(f.message), 'message should explain gh is only for the issue workflow');
    assert.equal(result.passed, true, 'a missing gh must not fail the doctor');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ─── AC-8: findings structure ─────────────────────────────────────────────────

test('doctor: returns findings array with check, status, message fields', async () => {
  const dir = await makeTempDir();
  try {
    const { findings } = await runDoctor(dir, {
      log: () => {},
      checkCommand: mockCommandFound,
    });

    assert.ok(Array.isArray(findings), 'findings should be an array');
    for (const f of findings) {
      assert.ok(typeof f.check === 'string', 'finding.check should be a string');
      assert.ok(
        f.status === 'pass' || f.status === 'fail',
        `finding.status should be "pass" or "fail", got: ${f.status}`,
      );
      assert.ok(typeof f.message === 'string', 'finding.message should be a string');
    }
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
