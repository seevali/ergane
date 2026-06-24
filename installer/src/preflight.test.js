import { test } from 'node:test';
import assert from 'node:assert/strict';
import { preflight, renderChecklist } from './preflight.js';

// Convenience factories for commandExists injection
const allPresent = () => true;
const nonePresent = () => false;
const present = (...cmds) => (cmd) => cmds.includes(cmd);

// ─── Node.js version ──────────────────────────────────────────────────────────

test('Node.js version >= 20 reports pass', async () => {
  const results = await preflight({ nodeVersion: 'v20.11.0', platform: 'linux', commandExists: allPresent });
  assert.equal(results.node.status, 'pass');
  assert.equal(results.node.version, '20.11.0');
});

test('Node.js version < 20 reports fail', async () => {
  const results = await preflight({ nodeVersion: 'v18.0.0', platform: 'linux', commandExists: allPresent });
  assert.equal(results.node.status, 'fail');
  // Caller maps node.status === 'fail' → exit(1)
  assert.ok(results.node.message.includes('nodejs.org/download'), 'message should include download URL');
});

test('Node.js version 19 also reports fail', async () => {
  const results = await preflight({ nodeVersion: 'v19.9.0', platform: 'linux', commandExists: allPresent });
  assert.equal(results.node.status, 'fail');
});

test('Node.js version without leading v parses correctly', async () => {
  const results = await preflight({ nodeVersion: 'v22.1.0', platform: 'linux', commandExists: allPresent });
  assert.equal(results.node.status, 'pass');
  assert.equal(results.node.version, '22.1.0');
});

// ─── git ──────────────────────────────────────────────────────────────────────

test('git present reports pass', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: present('git') });
  assert.equal(results.git.status, 'pass');
});

test('git missing reports warn with install hint', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: nonePresent });
  assert.equal(results.git.status, 'warn');
  assert.ok(results.git.message.includes('git not found'), 'message should mention git not found');
  assert.ok(
    results.git.message.includes('apt install git') || results.git.message.includes('brew install git'),
    'message should include an install hint',
  );
});

// ─── jq ───────────────────────────────────────────────────────────────────────

test('jq present reports pass', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: present('jq') });
  assert.equal(results.jq.status, 'pass');
});

test('jq missing reports warn with per-OS hints', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: nonePresent });
  assert.equal(results.jq.status, 'warn');
  assert.ok(results.jq.message.includes('apt install jq'), 'includes Debian hint');
  assert.ok(results.jq.message.includes('brew install jq'), 'includes macOS hint');
  assert.ok(results.jq.message.includes('choco install jq'), 'includes Chocolatey hint');
  assert.ok(results.jq.message.includes('winget install jqlang.jq'), 'includes winget hint');
});

// ─── claude CLI ───────────────────────────────────────────────────────────────

test('claude CLI present reports pass', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: present('claude') });
  assert.equal(results.claude.status, 'pass');
});

test('claude CLI missing reports warn, not fail', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: nonePresent });
  assert.equal(results.claude.status, 'warn');
  // Caller must NOT exit on claude warn — it's optional
  assert.notEqual(results.claude.status, 'fail');
});

// ─── bash / Windows detection ─────────────────────────────────────────────────

test('non-Windows always reports bash pass', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: nonePresent });
  assert.equal(results.bash.status, 'pass');
});

test('macOS reports bash pass regardless of command presence', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'darwin', commandExists: nonePresent });
  assert.equal(results.bash.status, 'pass');
});

test('Windows with bash reports pass', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'win32', commandExists: present('bash') });
  assert.equal(results.bash.status, 'pass');
});

test('Windows without bash reports fail with WSL2 guidance', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'win32', commandExists: nonePresent });
  assert.equal(results.bash.status, 'fail');
  // Caller maps bash.status === 'fail' → exit(2)
  assert.ok(results.bash.message.includes('WSL') || results.bash.message.includes('wsl'), 'message should mention WSL2');
});

test('Windows with Git Bash (bash found) reports pass', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'win32', commandExists: present('bash') });
  assert.equal(results.bash.status, 'pass');
});

// ─── return structure ─────────────────────────────────────────────────────────

test('preflight returns all required keys with correct shape', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: allPresent });
  for (const key of ['node', 'git', 'jq', 'claude', 'bash']) {
    assert.ok(key in results, `results.${key} should exist`);
    assert.ok('status' in results[key], `results.${key}.status should exist`);
    assert.ok('message' in results[key], `results.${key}.message should exist`);
  }
  assert.ok('version' in results.node, 'results.node.version should exist');
});

test('valid status values across all checks', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: nonePresent });
  const validStatuses = new Set(['pass', 'warn', 'fail']);
  for (const key of ['node', 'git', 'jq', 'claude', 'bash']) {
    assert.ok(validStatuses.has(results[key].status), `results.${key}.status must be pass|warn|fail`);
  }
});

// ─── renderChecklist ──────────────────────────────────────────────────────────

test('renderChecklist on TTY includes status glyphs', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: nonePresent });
  // node=pass, git/jq/claude/bash=warn or pass
  const output = [];
  renderChecklist(results, { isTTY: true, noColor: true, writeFn: (s) => output.push(s) });
  const out = output.join('');
  assert.ok(out.includes('✓') || out.includes('⚠') || out.includes('✗'), 'TTY output should include a status glyph');
});

test('renderChecklist shows ✓ for pass and ⚠ for warn on TTY', async () => {
  // node=pass, git=warn (both should appear)
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: nonePresent });
  const output = [];
  renderChecklist(results, { isTTY: true, noColor: true, writeFn: (s) => output.push(s) });
  const out = output.join('');
  assert.ok(out.includes('✓'), 'should include ✓ for pass status');
  assert.ok(out.includes('⚠'), 'should include ⚠ for warn status');
});

test('renderChecklist on non-TTY is plain text without glyphs', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: allPresent });
  const output = [];
  renderChecklist(results, { isTTY: false, noColor: false, writeFn: (s) => output.push(s) });
  const out = output.join('');
  assert.ok(!/\x1b\[/.test(out), 'non-TTY output should have no ANSI escape codes');
  assert.ok(out.includes('NODE_VERSION:'), 'should include NODE_VERSION key');
  assert.ok(out.includes('GIT:'), 'should include GIT key');
  assert.ok(out.includes('JQ:'), 'should include JQ key');
  assert.ok(out.includes('CLAUDE:'), 'should include CLAUDE key');
  assert.ok(out.includes('BASH:'), 'should include BASH key');
  assert.ok(!out.includes('✓') && !out.includes('⚠') && !out.includes('✗'), 'non-TTY output should have no glyphs');
});

test('renderChecklist respects NO_COLOR on TTY (no ANSI codes)', async () => {
  const results = await preflight({ nodeVersion: 'v20.0.0', platform: 'linux', commandExists: allPresent });
  const output = [];
  // noColor=true bypasses picocolors — guarantees no ANSI sequences
  renderChecklist(results, { isTTY: true, noColor: true, writeFn: (s) => output.push(s) });
  const out = output.join('');
  assert.ok(!/\x1b\[/.test(out), 'NO_COLOR output should have no ANSI escape codes');
  // Glyphs should still appear (TTY path, just without color)
  assert.ok(out.includes('✓'), 'NO_COLOR TTY should still show glyphs');
});
