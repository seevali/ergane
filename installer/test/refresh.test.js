/**
 * Coverage for the 2026-07-04 installer freshness + UX refresh slice:
 *   - ralph-watch.sh is scaffolded (write map + executable bit)
 *   - an empty app dir (.gitkeep) is scaffolded so the loop preflight passes
 *   - user-facing copy names the real CLI, never a literal <package> placeholder
 *   - the outro hands over an honest, cost-warned, real-path next-steps flow
 *   - GETTING-STARTED tells the truth about the loop knobs (anti-drift vs template)
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { buildWriteMap, executeWrite } from '../src/writer.js';
import { printOutro } from '../src/outro.js';
import { getPackageName } from '../src/pkg.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INSTALLER_ROOT = path.resolve(__dirname, '..');
const TEMPLATE_LOOP = path.join(INSTALLER_ROOT, 'templates', 'loop');

async function makeTempDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'ralph-refresh-'));
}

function basePlan(overrides = {}) {
  return {
    targetDir: os.tmpdir(),
    taskSource: 'scaffold',
    appDir: 'src',
    checkpointCommand: 'npm run build && npm test',
    stackDescription: 'React',
    addGitignoreEntries: false,
    ...overrides,
  };
}

// ── ralph-watch.sh scaffolding ────────────────────────────────────────────────

test('buildWriteMap includes scripts/ralph-watch.sh', async () => {
  const writeMap = await buildWriteMap(basePlan());
  assert.ok(writeMap.has('scripts/ralph-watch.sh'), 'ralph-watch.sh must be in the write map');
});

test('buildWriteMap scaffolds an empty app dir with .gitkeep', async () => {
  const writeMap = await buildWriteMap(basePlan({ appDir: 'packages/app' }));
  assert.ok(writeMap.has('packages/app/.gitkeep'), 'app dir .gitkeep must be scaffolded');
  assert.equal(writeMap.get('packages/app/.gitkeep'), '', '.gitkeep should be empty');
});

test('executeWrite sets the executable bit on .sh files', async () => {
  const dir = await makeTempDir();
  try {
    const map = new Map([
      ['scripts/ralph-watch.sh', '#!/usr/bin/env bash\necho hi\n'],
      ['docs/notes.md', '# not executable\n'],
    ]);
    await executeWrite(dir, map);

    const shStat = await fs.stat(path.join(dir, 'scripts/ralph-watch.sh'));
    assert.notEqual(shStat.mode & 0o111, 0, 'ralph-watch.sh must be executable');

    const mdStat = await fs.stat(path.join(dir, 'docs/notes.md'));
    assert.equal(mdStat.mode & 0o111, 0, 'non-.sh files should not gain the exec bit');
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── <package> placeholder is dead (B1) ────────────────────────────────────────

test('rendered GETTING-STARTED.md contains the real CLI name, never <package>', async () => {
  const writeMap = await buildWriteMap(basePlan());
  const guide = writeMap.get('GETTING-STARTED.md');
  assert.ok(guide, 'GETTING-STARTED.md must be written');
  assert.ok(!guide.includes('<package>'), 'guide must not ship the literal <package> placeholder');
  assert.ok(!guide.includes('{{'), 'guide must have no unsubstituted {{...}} placeholders');
  assert.ok(guide.includes(getPackageName()), 'guide must name the real package');
});

test('outro copy names the real CLI, never <package>', () => {
  const logs = [];
  printOutro(
    { status: 'success', filesWritten: 5, manifest: {} },
    { targetDir: '/proj', classification: 'empty', skipBmad: false, appDir: 'src', taskSource: 'scaffold', checkpointCommand: 'npm run build && npm test' },
    (m = '') => logs.push(m),
  );
  const out = logs.join('\n');
  assert.ok(!out.includes('<package>'), 'outro must not print the literal <package> placeholder');
  assert.ok(out.includes(getPackageName()), 'outro must name the real package in the doctor/update tip');
});

// ── first-success outro is honest (B2 + B3) ───────────────────────────────────

test('outro run-the-loop step points at the scaffolded epic/prd and app dir', () => {
  const logs = [];
  printOutro(
    { status: 'success', filesWritten: 5, manifest: {} },
    { targetDir: '/proj', classification: 'empty', skipBmad: false, appDir: 'app/ui', taskSource: 'scaffold', checkpointCommand: 'npm run build && npm test' },
    (m = '') => logs.push(m),
  );
  const out = logs.join('\n');
  assert.ok(out.includes('--project-dir app/ui'), 'run command must point --project-dir at the configured app dir');
  assert.ok(out.includes('docs/epics/project-stories.md'), 'run command must point --epic at the scaffolded epic');
  assert.ok(out.includes('docs/epics/project-prd.md'), 'outro must name the scaffolded PRD to author');
});

test('outro warns about cost before the run-the-loop step', () => {
  const logs = [];
  printOutro(
    { status: 'success', filesWritten: 5, manifest: {} },
    { targetDir: '/proj', classification: 'empty', skipBmad: false, appDir: 'src', taskSource: 'scaffold' },
    (m = '') => logs.push(m),
  );
  const out = logs.join('\n');
  assert.ok(/paid Anthropic API/i.test(out), 'outro must warn the loop makes paid API calls');
  assert.ok(out.includes('--budget-per-story-usd'), 'outro must surface the budget knob');
});

test('outro points at the GitHub-issue workflow (Part A #5)', () => {
  const logs = [];
  printOutro(
    { status: 'success', filesWritten: 5, manifest: {} },
    { targetDir: '/proj', classification: 'empty', skipBmad: false, appDir: 'src', taskSource: 'scaffold' },
    (m = '') => logs.push(m),
  );
  const out = logs.join('\n');
  assert.ok(/issue/i.test(out), 'outro must mention the GitHub-issue workflow');
  assert.ok(out.includes('GETTING-STARTED.md'), 'outro must point at the guide section for depth');
});

test('outro existing-mode points --prd and --epic at the same brought file', () => {
  const logs = [];
  printOutro(
    { status: 'success', filesWritten: 5, manifest: {} },
    { targetDir: '/proj', classification: 'existing-project', skipBmad: true, appDir: 'src', taskSource: 'existing', taskSourcePath: 'docs/plan.md' },
    (m = '') => logs.push(m),
  );
  const out = logs.join('\n');
  assert.ok(out.includes('--prd docs/plan.md'), 'existing mode: --prd points at the brought file');
  assert.ok(out.includes('--epic docs/plan.md'), 'existing mode: --epic points at the same brought file');
  assert.ok(!out.includes('your-epic.md'), 'existing mode must not name a phantom docs/epics/your-epic.md');
});

// ── GETTING-STARTED tells the truth about loop knobs (B4 anti-drift) ───────────

test('GETTING-STARTED names only loop knobs that exist in the synced template script', async () => {
  const guide = await fs.readFile(path.join(TEMPLATE_LOOP, 'GETTING-STARTED.md'), 'utf8');
  const loopScript = await fs.readFile(path.join(TEMPLATE_LOOP, 'ralph-loop.sh'), 'utf8');

  // Every knob the guide teaches must actually be a variable in the loop script.
  const namedKnobs = [
    'MODEL_SM',
    'MODEL_DEV',
    'MODEL_REVIEW',
    'MAX_ITERATIONS',
    'BUDGET_PER_STORY_USD',
    'BUDGET_PER_INVOCATION_USD',
  ];
  for (const knob of namedKnobs) {
    assert.ok(guide.includes(knob), `guide should name the ${knob} knob`);
    assert.ok(
      new RegExp(`\\b${knob}\\b`).test(loopScript),
      `${knob} is named in the guide but does not exist in the template loop script`,
    );
  }

  // The audit's proven falsehoods must be gone.
  assert.ok(!guide.includes('MODEL_SELECTOR'), 'guide must not reference the nonexistent MODEL_SELECTOR');
  assert.ok(!/MAX_ITERATIONS[^\n]*default[^\n]*1\b/i.test(guide), 'guide must not claim MAX_ITERATIONS defaults to 1');
  assert.ok(/MAX_ITERATIONS[\s\S]*?50/.test(guide), 'guide should state MAX_ITERATIONS default of 50');
  assert.ok(!/Present a wizard/i.test(guide), 'guide must not claim the loop presents a wizard');
  assert.ok(/non-interactive/i.test(guide), 'guide should state the loop is non-interactive');
});

test('GETTING-STARTED teaches the GitHub-issue workflow and ralph-watch', async () => {
  const guide = await fs.readFile(path.join(TEMPLATE_LOOP, 'GETTING-STARTED.md'), 'utf8');
  for (const token of ['--issue', '--plan-only', '--write', '--triage', '--worktree', '--issues', 'ralph-watch.sh']) {
    assert.ok(guide.includes(token), `guide should teach ${token}`);
  }
});
