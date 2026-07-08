import { cliInvocation } from './pkg.js';

/**
 * Print a numbered post-install summary showing an honest, ordered next-steps path.
 * Called after writeInstall() completes successfully.
 *
 * The steps are ordered so a newcomer never runs a command that errors on a fresh
 * install: read the guide, author the plan, THEN run the loop (which now has a
 * scaffolded app dir + epic to build), then watch the progress file that the first
 * run creates.
 *
 * @param {object} result - from writeInstall(); has { status, filesWritten, manifest }
 * @param {object} plan - InstallPlan; has { targetDir, classification, skipBmad, appDir, taskSource, taskSourcePath, checkpointCommand }
 * @param {Function} [log] - injectable console.log (for testing)
 */
export function printOutro(result, plan, log = console.log) {
  if (result.status !== 'success') {
    return;
  }

  const cli = cliInvocation();

  // When an opt-in step (BMAD) failed, the banner must NOT claim unqualified success.
  // The install itself completed (exit code stays 0), but the degraded state is stated.
  const bmadFailed = result.bmadFailed === true;

  log('\n═══════════════════════════════════════════════════════════════════');
  if (bmadFailed) {
    log('✓ Ergane installed, with 1 step needing attention (BMAD).');
  } else {
    log('✓ Ergane installed successfully!');
  }
  log('═══════════════════════════════════════════════════════════════════\n');

  if (bmadFailed) {
    log('The loop files are in place and ready. The optional BMAD module install did');
    log('not complete — see the BMAD error above for the exact command to re-run.\n');
  }

  const projectPath = plan.targetDir === '.' ? 'current directory' : plan.targetDir;

  // Derive the files the writer actually emitted so the run command points at real
  // paths. Three task sources, three (prd, epic) pairs — an explicit switch, not a
  // boolean, so a not-yet-considered value never silently falls into the wrong copy.
  const appDir = plan.appDir || 'src';
  const taskSource = plan.taskSource ?? 'scaffold';
  const scaffold = taskSource === 'scaffold';
  const ready = taskSource === 'example';

  let prdFile;
  let epicFile;
  if (taskSource === 'existing') {
    // "existing" mode: the wizard collects a single file (taskSourcePath) that serves
    // as BOTH the PRD and the epic (it must carry the `### Story X.Y` headers), so
    // --prd and --epic point at the same file. Never derive two different phantom
    // paths — that made step 3 reference a docs/epics/your-epic.md never scaffolded.
    prdFile = plan.taskSourcePath || 'docs/prd.md';
    epicFile = prdFile;
  } else if (taskSource === 'example') {
    // The worked example lands at the repo's own real paths (writer.js example branch).
    prdFile = 'docs/prd.md';
    epicFile = 'docs/epics/exchange-rates-dashboard.md';
  } else {
    // scaffold: the two rendered stub docs.
    prdFile = 'docs/epics/project-prd.md';
    epicFile = 'docs/epics/project-stories.md';
  }

  // --checkpoint is REQUIRED by the loop (it bakes in no default), so the printed
  // "next command" must always carry it or it would fail at the first flag check.
  // The wizard requires a checkpoint answer; fall back to the same default the
  // writer uses for the rendered project-conventions/template only as a safety net.
  const checkpointCommand = plan.checkpointCommand || 'npm run build && npm test';
  const runFlags = [
    `--project-dir ${appDir}`,
    `--prd ${prdFile}`,
    `--epic ${epicFile}`,
    `--checkpoint '${checkpointCommand}'`,
  ];
  const runCommand = `bash scripts/ralph-loop.sh ${runFlags.join(' ')}`;

  log(`Your Ergane loop lives in ${projectPath}. cd there, then follow these steps:\n`);
  log('📋 Next steps:\n');

  log(`1. Read the guide:              cat GETTING-STARTED.md`);
  if (ready) {
    // The example ships a complete, authored plan — nothing to fill in.
    log(`2. Review the worked example:   ${prdFile}`);
    log(`                               and  ${epicFile}`);
    log(`                               (a complete, ready-to-run PRD + epic — no TODOs to fill)`);
  } else {
    log(`2. Author your plan:            edit ${prdFile}`);
    if (scaffold) {
      log(`                               and  ${epicFile}`);
    }
    log(`                               (the loop builds exactly what the epic lists —`);
    log(`                                an empty epic builds nothing, so fill the TODOs first)`);
  }
  log(`3. Start your first loop:       ${runCommand}`);
  log(`   💰 Heads up: the loop makes paid Anthropic API calls. A small story is usually`);
  log(`      cents to a few dollars; cap spend with --budget-per-story-usd (see the guide).`);
  log(`4. Watch progress:              after your first run you'll find a progress file at`);
  log(`                               docs/stories/ralph-sprint-progress-*.md`);
  if (plan.skipBmad !== true) {
    log(`5. View agent memory:           ls -la docs/_bmad/_memory/`);
  }

  log(`\n🐙 Prefer GitHub issues? See "Working from GitHub issues" in GETTING-STARTED.md`);
  log(`   to drive the loop straight from an issue (--issue / --write / --issues).`);

  log(`\n💡 Tip: Use '${cli} doctor' to validate your installation at any time.`);
  log(`   Use '${cli} update' to update the loop infrastructure later.\n`);

  if (plan.classification === 'existing-project') {
    log('⚠️  Installing into an existing project. Review your customizations:');
    log(`   • docs/project-conventions.md  (tech stack, checkpoint command)`);
    log(`   • scripts/prompts/               (customize agent behavior)`);
    log();
  }
}
