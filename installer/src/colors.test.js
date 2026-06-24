import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isColorEnabled, colorize, note } from './colors.js';

// ─── isColorEnabled ───────────────────────────────────────────────────────────

test('isColorEnabled: returns true when isTTY=true and noColor=false', () => {
  assert.equal(isColorEnabled({ isTTY: true, noColor: false }), true);
});

test('isColorEnabled: returns false when isTTY=false', () => {
  assert.equal(isColorEnabled({ isTTY: false, noColor: false }), false);
});

test('isColorEnabled: returns false when noColor=true (even with TTY)', () => {
  assert.equal(isColorEnabled({ isTTY: true, noColor: true }), false);
});

test('isColorEnabled: returns false when both isTTY=false and noColor=true', () => {
  assert.equal(isColorEnabled({ isTTY: false, noColor: true }), false);
});

test('isColorEnabled: returns false when isTTY=false even if noColor=false', () => {
  assert.equal(isColorEnabled({ isTTY: false, noColor: false }), false);
});

test('isColorEnabled: NO_COLOR env var presence (not value) disables color', () => {
  const orig = process.env.NO_COLOR;
  try {
    process.env.NO_COLOR = '';
    assert.equal(isColorEnabled({ isTTY: true }), false, 'empty NO_COLOR should disable color');
    process.env.NO_COLOR = '0';
    assert.equal(isColorEnabled({ isTTY: true }), false, 'NO_COLOR=0 should still disable color');
    process.env.NO_COLOR = '1';
    assert.equal(isColorEnabled({ isTTY: true }), false, 'NO_COLOR=1 should disable color');
  } finally {
    if (orig === undefined) {
      delete process.env.NO_COLOR;
    } else {
      process.env.NO_COLOR = orig;
    }
  }
});

test('isColorEnabled: color is enabled when NO_COLOR is absent and isTTY=true', () => {
  const orig = process.env.NO_COLOR;
  try {
    delete process.env.NO_COLOR;
    assert.equal(isColorEnabled({ isTTY: true }), true);
  } finally {
    if (orig !== undefined) process.env.NO_COLOR = orig;
  }
});

// ─── colorize ─────────────────────────────────────────────────────────────────

test('colorize: applies function when colors are enabled', () => {
  const result = colorize('hello', (t) => `RED:${t}`, { isTTY: true, noColor: false });
  assert.equal(result, 'RED:hello');
});

test('colorize: returns plain text when colors are disabled (no TTY)', () => {
  const result = colorize('hello', (t) => `RED:${t}`, { isTTY: false, noColor: false });
  assert.equal(result, 'hello');
});

test('colorize: returns plain text when NO_COLOR is set', () => {
  const result = colorize('hello', (t) => `RED:${t}`, { isTTY: true, noColor: true });
  assert.equal(result, 'hello');
});

test('colorize: does not add ANSI codes in non-TTY context', () => {
  // Simulate a real picocolors function that adds ANSI escape codes
  const fakeGreen = (t) => `\x1b[32m${t}\x1b[0m`;
  const result = colorize('text', fakeGreen, { isTTY: false, noColor: false });
  assert.equal(result, 'text', 'no ANSI codes should appear in non-TTY result');
  assert.ok(!/\x1b\[/.test(result), 'result should contain no ANSI escape codes');
});

// ─── note ─────────────────────────────────────────────────────────────────────

test('note: is a non-empty string', () => {
  assert.equal(typeof note, 'string');
  assert.ok(note.length > 0);
});

test('note: contains only ASCII characters (safe in pipes)', () => {
  for (const char of note) {
    assert.ok(char.charCodeAt(0) < 128, `note character "${char}" should be ASCII`);
  }
});
