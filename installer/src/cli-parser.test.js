import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseCliArgs, validateCliArgs, listOptions } from './cli-parser.js';

// ─── parseCliArgs ─────────────────────────────────────────────────────────────

test('parseCliArgs: extracts all provided flags', () => {
  const opts = {
    appDir: 'frontend',
    checkpointCommand: 'make test',
    stackDescription: 'Vue 3',
    useBmad: 'yes',
    taskSource: 'scaffold',
    skipNpmScript: 'no',
  };
  const result = parseCliArgs(opts);
  assert.deepEqual(result, {
    appDir: 'frontend',
    checkpointCommand: 'make test',
    stackDescription: 'Vue 3',
    useBmad: 'yes',
    taskSource: 'scaffold',
    skipNpmScript: 'no',
  });
});

test('parseCliArgs: omits keys where the flag was not provided (undefined)', () => {
  const opts = { appDir: 'src' }; // only appDir provided
  const result = parseCliArgs(opts);
  assert.deepEqual(result, { appDir: 'src' });
  assert.ok(!('checkpointCommand' in result), 'checkpointCommand should be omitted');
  assert.ok(!('taskSource' in result), 'taskSource should be omitted');
});

test('parseCliArgs: returns empty object when no flags provided', () => {
  const result = parseCliArgs({});
  assert.deepEqual(result, {});
});

test('parseCliArgs: ignores extra Commander options not in flag definitions', () => {
  const opts = { appDir: 'src', directory: '/tmp/target', yes: true, force: false };
  const result = parseCliArgs(opts);
  assert.ok(!('directory' in result), 'directory should not be in cliArgs');
  assert.ok(!('yes' in result), 'yes should not be in cliArgs');
  assert.ok(!('force' in result), 'force should not be in cliArgs');
  assert.equal(result.appDir, 'src');
});

// ─── validateCliArgs ─────────────────────────────────────────────────────────

test('validateCliArgs: passes on valid values for all flags', () => {
  assert.doesNotThrow(() => validateCliArgs({
    appDir: 'src',
    checkpointCommand: 'npm test',
    stackDescription: 'React + Vite',
    useBmad: 'yes',
    taskSource: 'scaffold',
    skipNpmScript: 'no',
  }));
});

test('validateCliArgs: passes on empty object (no flags provided)', () => {
  assert.doesNotThrow(() => validateCliArgs({}));
});

test('validateCliArgs: throws on invalid --app-dir (absolute path)', () => {
  assert.throws(
    () => validateCliArgs({ appDir: '/absolute/path' }),
    (err) => {
      assert.ok(err.message.includes('--app-dir'), 'error should reference the real kebab flag');
      assert.ok(!/\bappDir\b/.test(err.message), 'error must not leak the camelCase key');
      return true;
    },
  );
});

test('validateCliArgs: throws on invalid --app-dir (path traversal)', () => {
  assert.throws(() => validateCliArgs({ appDir: '../outside' }));
});

test('validateCliArgs: throws on invalid --app-dir (empty)', () => {
  assert.throws(() => validateCliArgs({ appDir: '' }));
});

test('validateCliArgs: throws on invalid --use-bmad value', () => {
  assert.throws(
    () => validateCliArgs({ useBmad: 'maybe' }),
    (err) => {
      assert.ok(err.message.includes('--use-bmad'), 'error should reference the real kebab flag');
      assert.ok(!/\buseBmad\b/.test(err.message), 'error must not leak the camelCase key');
      return true;
    },
  );
});

test('validateCliArgs: accepts yes/no for --use-bmad', () => {
  assert.doesNotThrow(() => validateCliArgs({ useBmad: 'yes' }));
  assert.doesNotThrow(() => validateCliArgs({ useBmad: 'no' }));
});

test('validateCliArgs: throws on invalid --task-source value', () => {
  assert.throws(
    () => validateCliArgs({ taskSource: 'unknown' }),
    (err) => {
      assert.ok(err.message.includes('--task-source'), 'error should reference the real kebab flag');
      assert.ok(!/\btaskSource\b/.test(err.message), 'error must not leak the camelCase key');
      return true;
    },
  );
});

test('validateCliArgs: accepts scaffold/existing for --task-source', () => {
  assert.doesNotThrow(() => validateCliArgs({ taskSource: 'scaffold' }));
  assert.doesNotThrow(() => validateCliArgs({ taskSource: 'existing' }));
});

test('validateCliArgs: throws on invalid --skip-npm-script value', () => {
  assert.throws(() => validateCliArgs({ skipNpmScript: 'true' }));
});

test('validateCliArgs: throws on empty --checkpoint-command', () => {
  assert.throws(() => validateCliArgs({ checkpointCommand: '' }));
  assert.throws(() => validateCliArgs({ checkpointCommand: '   ' }));
});

test('validateCliArgs: throws on empty --stack-description', () => {
  assert.throws(() => validateCliArgs({ stackDescription: '' }));
});

// ─── listOptions ──────────────────────────────────────────────────────────────

test('listOptions: returns a non-empty string', () => {
  const output = listOptions();
  assert.equal(typeof output, 'string');
  assert.ok(output.length > 0);
});

test('listOptions: output contains at least 6 flags', () => {
  const output = listOptions();
  // Count the per-question flags (--app-dir, --checkpoint-command, etc.) plus global flags
  const flagMatches = output.match(/--\w[\w-]*/g) ?? [];
  assert.ok(flagMatches.length >= 6, `Expected at least 6 flags, found: ${flagMatches.join(', ')}`);
});

test('listOptions: includes all per-question flags', () => {
  const output = listOptions();
  assert.ok(output.includes('--app-dir'), 'should include --app-dir');
  assert.ok(output.includes('--checkpoint-command'), 'should include --checkpoint-command');
  assert.ok(output.includes('--stack-description'), 'should include --stack-description');
  assert.ok(output.includes('--use-bmad'), 'should include --use-bmad');
  assert.ok(output.includes('--task-source'), 'should include --task-source');
  assert.ok(output.includes('--skip-npm-script'), 'should include --skip-npm-script');
});

test('listOptions: includes global flags --yes, --force, --directory', () => {
  const output = listOptions();
  assert.ok(output.includes('--yes'), 'should include --yes');
  assert.ok(output.includes('--force'), 'should include --force');
  assert.ok(output.includes('--directory'), 'should include --directory');
});

test('listOptions: includes default values for per-question flags', () => {
  const output = listOptions();
  assert.ok(output.includes('default:'), 'should include default values');
  assert.ok(output.includes('src'), 'should include src default for --app-dir');
  assert.ok(output.includes('scaffold'), 'should include scaffold default for --task-source');
});

test('listOptions: output contains no ANSI escape codes', () => {
  const output = listOptions();
  assert.ok(!/\x1b\[/.test(output), 'listOptions should produce plain text with no ANSI codes');
});
