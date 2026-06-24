import { test } from 'node:test';
import assert from 'node:assert/strict';
import { printOutro } from './outro.js';

function makeResult(overrides = {}) {
  return {
    status: 'success',
    filesWritten: 5,
    manifest: {},
    ...overrides,
  };
}

function makePlan(overrides = {}) {
  return {
    targetDir: '/some/project',
    classification: 'empty',
    skipBmad: false,
    ...overrides,
  };
}

// ─── Test: Prints numbered steps correctly ────────────────────────────────────

test('printOutro: prints numbered steps 1–5 on success', () => {
  const logs = [];
  const result = makeResult();
  const plan = makePlan({ skipBmad: false });

  printOutro(result, plan, (msg = '') => logs.push(msg));

  const output = logs.join('\n');
  assert.ok(output.includes('1.'), 'should include step 1');
  assert.ok(output.includes('2.'), 'should include step 2');
  assert.ok(output.includes('3.'), 'should include step 3');
  assert.ok(output.includes('4.'), 'should include step 4');
  assert.ok(output.includes('5.'), 'should include step 5');
});

test('printOutro: output mentions GETTING-STARTED.md', () => {
  const logs = [];
  printOutro(makeResult(), makePlan(), (msg = '') => logs.push(msg));

  const output = logs.join('\n');
  assert.ok(output.includes('GETTING-STARTED.md'), 'should mention GETTING-STARTED.md');
});

test('printOutro: output mentions scripts/ralph-loop.sh', () => {
  const logs = [];
  printOutro(makeResult(), makePlan(), (msg = '') => logs.push(msg));

  const output = logs.join('\n');
  assert.ok(output.includes('scripts/ralph-loop.sh'), 'should mention scripts/ralph-loop.sh');
});

test('printOutro: output mentions doctor command tip', () => {
  const logs = [];
  printOutro(makeResult(), makePlan(), (msg = '') => logs.push(msg));

  const output = logs.join('\n');
  assert.ok(output.includes('doctor'), 'should mention the doctor command');
});

// ─── Test: Shows BMAD memory only if not skipped ─────────────────────────────

test('printOutro: includes agent memory step when skipBmad is false', () => {
  const logs = [];
  printOutro(makeResult(), makePlan({ skipBmad: false }), (msg = '') => logs.push(msg));

  const output = logs.join('\n');
  assert.ok(output.includes('agent memory') || output.includes('_memory'), 'should include agent memory step');
});

test('printOutro: excludes agent memory step when skipBmad is true', () => {
  const logs = [];
  printOutro(makeResult(), makePlan({ skipBmad: true }), (msg = '') => logs.push(msg));

  const output = logs.join('\n');
  assert.ok(
    !output.includes('View agent memory'),
    'should NOT include agent memory step when skipBmad is true',
  );
});

test('printOutro: includes agent memory step when skipBmad is absent from plan', () => {
  const logs = [];
  const plan = makePlan();
  delete plan.skipBmad;
  printOutro(makeResult(), plan, (msg = '') => logs.push(msg));

  const output = logs.join('\n');
  // plan.skipBmad is undefined, !== true, so step 5 shows
  assert.ok(output.includes('5.'), 'should include step 5 when skipBmad is absent');
});

// ─── Test: No output for non-success status ───────────────────────────────────

test('printOutro: produces no output when status is cancelled', () => {
  const logs = [];
  const result = { status: 'cancelled', filesWritten: 0, manifest: null };
  printOutro(result, makePlan(), (msg = '') => logs.push(msg));

  assert.equal(logs.length, 0, 'should log nothing when status is not success');
});

test('printOutro: produces no output when status is error', () => {
  const logs = [];
  const result = { status: 'error', filesWritten: 0, manifest: null };
  printOutro(result, makePlan(), (msg = '') => logs.push(msg));

  assert.equal(logs.length, 0, 'should log nothing for non-success status');
});

// ─── Test: Path formatting ────────────────────────────────────────────────────

test('printOutro: uses targetDir in step commands', () => {
  const logs = [];
  const plan = makePlan({ targetDir: '/my/project/path' });
  printOutro(makeResult(), plan, (msg = '') => logs.push(msg));

  const output = logs.join('\n');
  assert.ok(output.includes('/my/project/path'), 'should include the target directory path');
});

test('printOutro: shows "current directory" label when targetDir is "."', () => {
  const logs = [];
  const plan = makePlan({ targetDir: '.' });
  printOutro(makeResult(), plan, (msg = '') => logs.push(msg));

  const output = logs.join('\n');
  assert.ok(output.includes('current directory'), 'should use "current directory" for "." targetDir');
});

// ─── Test: Existing-project warning ──────────────────────────────────────────

test('printOutro: shows existing-project warning when classification is existing-project', () => {
  const logs = [];
  const plan = makePlan({ classification: 'existing-project' });
  printOutro(makeResult(), plan, (msg = '') => logs.push(msg));

  const output = logs.join('\n');
  assert.ok(
    output.includes('existing project') || output.includes('existing-project'),
    'should warn about existing-project installs',
  );
});

test('printOutro: no existing-project warning for empty-class installs', () => {
  const logs = [];
  const plan = makePlan({ classification: 'empty' });
  printOutro(makeResult(), plan, (msg = '') => logs.push(msg));

  const output = logs.join('\n');
  assert.ok(
    !output.includes('Installing into an existing project'),
    'should not show existing-project warning for empty installs',
  );
});
