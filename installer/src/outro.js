/**
 * Print a numbered post-install summary showing next steps.
 * Called after writeInstall() completes successfully.
 *
 * @param {object} result - from writeInstall(); has { status, filesWritten, manifest }
 * @param {object} plan - InstallPlan; has { targetDir, classification, skipBmad }
 * @param {Function} [log] - injectable console.log (for testing)
 */
export function printOutro(result, plan, log = console.log) {
  if (result.status !== 'success') {
    return;
  }

  log('\n═══════════════════════════════════════════════════════════════════');
  log('✓ Ralph Loop installed successfully!');
  log('═══════════════════════════════════════════════════════════════════\n');

  const projectPath = plan.targetDir === '.' ? 'current directory' : plan.targetDir;

  log('📋 Next steps:\n');
  log(`1. Read the guide:              cat ${projectPath}/GETTING-STARTED.md`);
  log(`2. Start your first loop:       bash ${projectPath}/scripts/ralph-loop.sh`);
  log(`3. Watch the logs live:         tail -f ${projectPath}/scripts/logs/latest.log`);
  log(`4. Check sprint status:         cat ${projectPath}/docs/sprint-status.yaml`);
  if (plan.skipBmad !== true) {
    log(`5. View agent memory:           ls -la ${projectPath}/docs/_bmad/_memory/`);
  }
  log(`\n💡 Tip: Use 'npx <package> doctor' to validate your installation at any time.`);
  log(`   Use 'npx <package> update' to update the loop infrastructure later.\n`);

  if (plan.classification === 'existing-project') {
    log('⚠️  Installing into an existing project. Review your customizations:');
    log(`   • docs/project-conventions.md  (tech stack, checkpoint command)`);
    log(`   • scripts/prompts/               (customize agent behavior)`);
    log();
  }
}
