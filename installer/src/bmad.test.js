import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  installBmad,
  composeBmadArgs,
  formatBmadCommand,
  BMAD_COMMAND,
  BMAD_BASE_ARGS,
} from './bmad.js';

// Sample help texts for the two bmad-method variants we defend against.
const HELP_NEW = `Usage: bmad-method install [options]
  --modules <list>        modules to install
  --tools <list>          tools
  --output-folder <dir>   output folder
`;
const HELP_OLD = `Usage: bmad-method install [options]
  --modules <list>          modules
  --tools <list>            tools
  --output-folder <dir>     output folder
  --artifact-folder <dir>   artifacts
  --memory-folder <dir>     memory
`;

// ─── composeBmadArgs: flag probing ────────────────────────────────────────────

test('composeBmadArgs: newer bmad (no --artifact-folder in help) → minimal known-good set', () => {
  const args = composeBmadArgs(HELP_NEW);
  assert.deepEqual(args, BMAD_BASE_ARGS, 'must not add flags the resolved version does not advertise');
  assert.ok(!args.includes('--artifact-folder'), 'dropped flag must not be passed');
  assert.ok(!args.includes('--memory-folder'), 'dropped flag must not be passed');
});

test('composeBmadArgs: older bmad (advertises the flags) → includes them', () => {
  const args = composeBmadArgs(HELP_OLD);
  assert.ok(args.includes('--artifact-folder'), 'advertised flag included');
  assert.ok(args.includes('--memory-folder'), 'advertised flag included');
});

test('composeBmadArgs: empty/undefined help → minimal known-good set (offline-safe fallback)', () => {
  assert.deepEqual(composeBmadArgs(''), BMAD_BASE_ARGS);
  assert.deepEqual(composeBmadArgs(undefined), BMAD_BASE_ARGS);
});

// ─── Exact argv the run uses is probe-driven ──────────────────────────────────

test('installBmad: runs the composed argv (probed help, no dropped flags)', async () => {
  let capturedCmd, capturedArgs;
  const mockExec = async (cmd, args) => {
    capturedCmd = cmd;
    capturedArgs = [...args];
    return { stdout: '', stderr: '' };
  };

  await installBmad({
    execFile: mockExec,
    spinner: { start() {}, stop() {} },
    help: HELP_NEW,
  });

  assert.equal(capturedCmd, BMAD_COMMAND);
  assert.deepEqual(capturedArgs, BMAD_BASE_ARGS, 'install run must use only advertised flags');
});

// ─── Success path ─────────────────────────────────────────────────────────────

test('installBmad: success → { success: true } with the attempted command', async () => {
  const mockExec = async () => ({ stdout: '', stderr: '' });
  const result = await installBmad({
    execFile: mockExec,
    spinner: { start() {}, stop() {} },
    help: HELP_NEW,
  });
  assert.equal(result.success, true);
  assert.equal(result.command, formatBmadCommand(BMAD_BASE_ARGS));
});

// ─── Failure path — returns success:false AND a working remediation ───────────

test('installBmad: failure → { success: false } and the remediation equals the exact attempted command', async () => {
  const logs = [];
  const mockLog = (...a) => logs.push(a.join(' '));
  // Reject with the classic dropped-flag error to prove the remediation is NOT broken.
  const mockExec = async () => {
    throw Object.assign(new Error('Command failed'), {
      stderr: "error: unknown option '--artifact-folder'",
      code: 1,
    });
  };

  const result = await installBmad({
    execFile: mockExec,
    spinner: { start() {}, stop() {} },
    log: mockLog,
    help: HELP_NEW, // newer bmad → composed args exclude --artifact-folder
  });

  assert.equal(result.success, false, 'a failed BMAD step must report failure');

  const output = logs.join('\n');
  const attempted = formatBmadCommand(BMAD_BASE_ARGS);
  assert.ok(output.includes(attempted), 'remediation must print the exact attempted command');
  assert.ok(
    !/npx bmad-method install[^\n]*--artifact-folder/.test(output),
    'remediation must NOT reproduce the dropped --artifact-folder flag',
  );
  assert.ok(/manual/i.test(output), 'remediation should direct the user to run it manually');
});

// ─── Probe drives flag composition end to end ─────────────────────────────────

test('installBmad: probes install --help, then includes advertised legacy flags', async () => {
  const calls = [];
  const mockExec = async (cmd, args) => {
    calls.push(args);
    if (args.includes('--help')) {
      return { stdout: HELP_OLD, stderr: '' };
    }
    return { stdout: '', stderr: '' };
  };

  const result = await installBmad({
    execFile: mockExec,
    spinner: { start() {}, stop() {} },
  });

  assert.equal(result.success, true);
  const installCall = calls.find((a) => !a.includes('--help'));
  assert.ok(installCall.includes('--artifact-folder'), 'advertised legacy flag flows into the install run');
});

// ─── Non-TTY handling ─────────────────────────────────────────────────────────

test('installBmad: non-TTY mode emits no ANSI codes and a plain progress line', async () => {
  const logs = [];
  const mockLog = (...a) => logs.push(a.join(' '));
  const mockExec = async () => ({ stdout: '', stderr: '' });

  await installBmad({ isTTY: false, log: mockLog, execFile: mockExec, help: HELP_NEW });

  const output = logs.join('\n');
  assert.ok(!output.includes('\x1b['), 'no ANSI escape codes in non-TTY mode');
  assert.ok(output.toLowerCase().includes('installing') || output.toLowerCase().includes('bmad'));
});
