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

  log('\n═══════════════════════════════════════════════════════════════════');
  log('✓ Ralph Loop installed successfully!');
  log('═══════════════════════════════════════════════════════════════════\n');

  const projectPath = plan.targetDir === '.' ? 'current directory' : plan.targetDir;

  // Derive the files the writer actually emitted so the run command points at real paths.
  const appDir = plan.appDir || 'src';
  const scaffold = plan.taskSource !== 'existing';
  // In "existing" mode the wizard collects a single file (taskSourcePath) that
  // serves as BOTH the PRD and the epic (it must carry the `### Story X.Y` headers),
  // so --prd and --epic point at the same file. Never derive two different phantom
  // paths here — that made step 3 reference a docs/epics/your-epic.md that is never
  // scaffolded.
  const prdFile = scaffold ? 'docs/epics/project-prd.md' : (plan.taskSourcePath || 'docs/prd.md');
  const epicFile = scaffold ? 'docs/epics/project-stories.md' : prdFile;

  const runFlags = [`--project-dir ${appDir}`, `--prd ${prdFile}`, `--epic ${epicFile}`];
  if (plan.checkpointCommand) {
    runFlags.push(`--checkpoint '${plan.checkpointCommand}'`);
  }
  const runCommand = `bash scripts/ralph-loop.sh ${runFlags.join(' ')}`;

  log(`Your Ralph Loop lives in ${projectPath}. cd there, then follow these steps:\n`);
  log('📋 Next steps:\n');

  log(`1. Read the guide:              cat GETTING-STARTED.md`);
  log(`2. Author your plan:            edit ${prdFile}`);
  if (scaffold) {
    log(`                               and  ${epicFile}`);
  }
  log(`                               (the loop builds exactly what the epic lists —`);
  log(`                                an empty epic builds nothing, so fill the TODOs first)`);
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
