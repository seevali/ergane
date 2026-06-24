import { test } from 'node:test';
import assert from 'node:assert/strict';
import { installBmad, BMAD_COMMAND, BMAD_ARGS } from './bmad.js';

// ─── Test 1: Exact argv verification ──────────────────────────────────────────

test('exact argv verification: execFile called with correct command and args in order', async () => {
  let capturedCmd;
  let capturedArgs;

  const mockExec = async (cmd, args) => {
    capturedCmd = cmd;
    capturedArgs = [...args];
    return { stdout: '', stderr: '' };
  };

  const mockSpinner = { start() {}, stop() {} };

  await installBmad({ execFile: mockExec, spinner: mockSpinner });

  assert.equal(capturedCmd, 'npx', 'command should be npx');
  assert.deepEqual(capturedArgs, [
    'bmad-method',
    'install',
    '--modules', 'core,bmm',
    '--tools', 'claude-code',
    '--output-folder', 'docs',
    '--artifact-folder', 'docs',
    '--memory-folder', 'docs/_bmad/_memory',
  ], 'argv should match exact order and values');

  // Cross-check against the exported constant
  assert.deepEqual(capturedArgs, BMAD_ARGS, 'captured args should match BMAD_ARGS export');
  assert.equal(capturedCmd, BMAD_COMMAND, 'captured command should match BMAD_COMMAND export');
});

// ─── Test 2: Success path ─────────────────────────────────────────────────────

test('success path: returns { success: true } and stops spinner', async () => {
  const spinnerCalls = { start: [], stop: [] };
  const mockSpinner = {
    start(msg) { spinnerCalls.start.push(msg); },
    stop(msg) { spinnerCalls.stop.push(msg); },
  };

  const mockExec = async () => ({ stdout: '', stderr: '' });

  const result = await installBmad({ execFile: mockExec, spinner: mockSpinner });

  assert.deepEqual(result, { success: true }, 'should return { success: true } on success');
  assert.equal(spinnerCalls.start.length, 1, 'spinner.start should be called once');
  assert.equal(spinnerCalls.stop.length, 1, 'spinner.stop should be called once');
});

// ─── Test 3: Failure path — manual command printed ────────────────────────────

test('failure path: prints manual command, returns { success: true }, does not throw', async () => {
  const logs = [];
  const mockLog = (...args) => logs.push(args.join(' '));
  const mockSpinner = {
    start() {},
    stop() {},
  };

  const mockExec = async () => {
    const err = Object.assign(new Error('Command failed'), {
      stderr: 'npm error: some error output',
      code: 1,
    });
    throw err;
  };

  let threw = false;
  let result;
  try {
    result = await installBmad({ execFile: mockExec, spinner: mockSpinner, log: mockLog });
  } catch {
    threw = true;
  }

  assert.equal(threw, false, 'should not throw on command failure');
  assert.deepEqual(result, { success: true }, 'failure should still return { success: true }');

  const output = logs.join('\n');
  assert.ok(
    output.includes('npx bmad-method install'),
    'manual command should appear in output',
  );
  assert.ok(
    output.includes('--modules core,bmm'),
    'full command arguments should appear in output',
  );
  assert.ok(
    output.toLowerCase().includes('manual') || output.toLowerCase().includes('manually'),
    'guidance text should direct user to run manually',
  );
});

// ─── Test 4: Non-TTY handling ─────────────────────────────────────────────────

test('non-TTY mode: no ANSI escape codes in output, plain text progress line appears', async () => {
  const logs = [];
  const mockLog = (...args) => logs.push(args.join(' '));
  const mockExec = async () => ({ stdout: '', stderr: '' });

  await installBmad({ isTTY: false, log: mockLog, execFile: mockExec });

  const output = logs.join('\n');

  // ESC character introduces ANSI sequences
  assert.ok(
    !output.includes('\x1b[') && !output.includes('['),
    'output must contain no ANSI escape codes when isTTY is false',
  );

  assert.ok(
    output.toLowerCase().includes('installing') || output.toLowerCase().includes('bmad'),
    'plain text progress line should appear in non-TTY mode',
  );
});

// ─── Test 5: External spinner passthrough ─────────────────────────────────────

test('external spinner passthrough: provided spinner object is used, start and stop called', async () => {
  const startMessages = [];
  const stopMessages = [];
  const externalSpinner = {
    start(msg) { startMessages.push(msg); },
    stop(msg) { stopMessages.push(msg); },
  };

  const mockExec = async () => ({ stdout: '', stderr: '' });

  await installBmad({ spinner: externalSpinner, execFile: mockExec });

  assert.equal(startMessages.length, 1, 'spinner.start should be called exactly once');
  assert.equal(stopMessages.length, 1, 'spinner.stop should be called exactly once');
});
