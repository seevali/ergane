import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveConflicts } from './updateConflictResolver.js';

const CONFLICT_FILE = {
  path: 'scripts/prompts/common/project-conventions.md',
  checksum: 'sha256:original',
  currentChecksum: 'sha256:modified',
  isModified: true,
};

// ─── No conflicts ─────────────────────────────────────────────────────────────

test('resolveConflicts: no conflicts → empty decisions, no prompts', async () => {
  let promptCalled = false;
  const result = await resolveConflicts([], {}, {
    isTTY: true,
    prompts: { select: async () => { promptCalled = true; return 'keep'; }, isCancel: () => false },
    log: () => {},
  });
  assert.deepEqual(result.decisions, {});
  assert.equal(result.succeeded, true);
  assert.equal(result.errors.length, 0);
  assert.equal(promptCalled, false, 'no prompts for zero conflicts');
});

// ─── Invalid --update-conflicts value ────────────────────────────────────────

test('resolveConflicts: invalid --update-conflicts → returns error, no writes', async () => {
  const result = await resolveConflicts(
    [CONFLICT_FILE],
    { updateConflicts: 'invalid-value' },
    { log: () => {} },
  );
  assert.equal(result.succeeded, false);
  assert.ok(result.errors.length > 0);
  assert.ok(result.errors[0].includes('invalid-value'), 'error should name the invalid value');
  assert.deepEqual(result.decisions, {});
});

test('resolveConflicts: invalid --update-conflicts checked before any processing', async () => {
  let promptCalled = false;
  const result = await resolveConflicts(
    [CONFLICT_FILE],
    { updateConflicts: 'bad', yes: false },
    {
      isTTY: true,
      prompts: { select: async () => { promptCalled = true; return 'keep'; }, isCancel: () => false },
      log: () => {},
    },
  );
  assert.equal(result.succeeded, false);
  assert.equal(promptCalled, false, 'prompts must not fire if validation fails');
});

// ─── --yes mode ───────────────────────────────────────────────────────────────

test('resolveConflicts: --yes with conflict → uses default "keep", no prompt', async () => {
  let promptCalled = false;
  const logLines = [];
  const result = await resolveConflicts(
    [CONFLICT_FILE],
    { yes: true, updateConflicts: null },
    {
      isTTY: false,
      prompts: { select: async () => { promptCalled = true; return 'take'; }, isCancel: () => false },
      log: (m) => logLines.push(m),
    },
  );
  assert.equal(result.succeeded, true);
  assert.equal(result.decisions[CONFLICT_FILE.path], 'keep', '--yes default should be "keep"');
  assert.equal(promptCalled, false, 'no prompt in --yes mode');
  assert.ok(logLines.some(l => l.includes('default')), 'should log default-resolution message');
});

// ─── --force --update-conflicts=take ─────────────────────────────────────────

test('resolveConflicts: --force --update-conflicts=take → applies "take" without prompting', async () => {
  let promptCalled = false;
  const result = await resolveConflicts(
    [CONFLICT_FILE],
    { force: true, updateConflicts: 'take' },
    {
      isTTY: true, // even with TTY, force skips prompts
      prompts: { select: async () => { promptCalled = true; return 'keep'; }, isCancel: () => false },
      log: () => {},
    },
  );
  assert.equal(result.succeeded, true);
  assert.equal(result.decisions[CONFLICT_FILE.path], 'take');
  assert.equal(promptCalled, false, 'no prompt when --force is set');
});

// ─── --update-conflicts=backup non-interactive ────────────────────────────────

test('resolveConflicts: --yes --update-conflicts=backup → applies "backup" to all', async () => {
  const f2 = { ...CONFLICT_FILE, path: 'scripts/ralph-loop.sh' };
  const result = await resolveConflicts(
    [CONFLICT_FILE, f2],
    { yes: true, updateConflicts: 'backup' },
    { isTTY: false, log: () => {} },
  );
  assert.equal(result.succeeded, true);
  assert.equal(result.decisions[CONFLICT_FILE.path], 'backup');
  assert.equal(result.decisions[f2.path], 'backup');
});

// ─── Interactive mode ─────────────────────────────────────────────────────────

test('resolveConflicts: interactive → prompt shown, decision recorded', async () => {
  let promptCount = 0;
  const result = await resolveConflicts(
    [CONFLICT_FILE],
    { yes: false, force: false, updateConflicts: null },
    {
      isTTY: true,
      prompts: {
        select: async () => { promptCount++; return 'backup'; },
        isCancel: () => false,
      },
      log: () => {},
    },
  );
  assert.equal(result.succeeded, true);
  assert.equal(promptCount, 1, 'one prompt per conflict file');
  assert.equal(result.decisions[CONFLICT_FILE.path], 'backup');
});

test('resolveConflicts: interactive cancel → uses default "keep"', async () => {
  const result = await resolveConflicts(
    [CONFLICT_FILE],
    { yes: false, force: false },
    {
      isTTY: true,
      prompts: {
        select: async () => Symbol('cancel'),
        isCancel: (v) => typeof v === 'symbol',
      },
      log: () => {},
    },
  );
  assert.equal(result.succeeded, true);
  assert.equal(result.decisions[CONFLICT_FILE.path], 'keep', 'cancel should fall back to "keep"');
});

test('resolveConflicts: interactive multiple conflicts → one prompt per file', async () => {
  const f2 = { ...CONFLICT_FILE, path: 'scripts/ralph-loop.sh' };
  let promptCount = 0;
  const choices = ['keep', 'take'];
  const result = await resolveConflicts(
    [CONFLICT_FILE, f2],
    { yes: false },
    {
      isTTY: true,
      prompts: {
        select: async () => choices[promptCount++],
        isCancel: () => false,
      },
      log: () => {},
    },
  );
  assert.equal(promptCount, 2, 'one prompt per file');
  assert.equal(result.decisions[CONFLICT_FILE.path], 'keep');
  assert.equal(result.decisions[f2.path], 'take');
});

// ─── Non-TTY without --yes ────────────────────────────────────────────────────

test('resolveConflicts: non-TTY without --yes → uses default without prompting', async () => {
  let promptCalled = false;
  const result = await resolveConflicts(
    [CONFLICT_FILE],
    { yes: false, force: false },
    {
      isTTY: false,
      prompts: { select: async () => { promptCalled = true; return 'take'; }, isCancel: () => false },
      log: () => {},
    },
  );
  assert.equal(result.succeeded, true);
  assert.equal(result.decisions[CONFLICT_FILE.path], 'keep');
  assert.equal(promptCalled, false);
});
