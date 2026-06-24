#!/usr/bin/env node

import { program } from 'commander';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join, resolve } from 'path';
import { preflight, renderChecklist } from '../src/preflight.js';
import { classifyTarget } from '../src/classify.js';
import { runWizard } from '../src/wizard.js';
import { writeInstall, executeUpdate } from '../src/writer.js';
import { printOutro } from '../src/outro.js';
import { runDoctor } from '../src/doctor.js';
import { parseCliArgs, validateCliArgs, listOptions } from '../src/cli-parser.js';
import { detectUpdate } from '../src/updateDetector.js';
import { resolveConflicts } from '../src/updateConflictResolver.js';
import { uninstall } from '../src/uninstall.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const packagePath = join(__dirname, '../package.json');
const { version } = JSON.parse(readFileSync(packagePath, 'utf8'));

program
  .version(version, '-v, --version', 'Show version number and exit')
  .helpOption('-h, --help', 'Show help and exit')
  .description('Ralph Loop guided installer — set up a new loop project in minutes');

program
  .command('install')
  .alias('init')
  .description('Install or update a Ralph Loop project')
  .option('-d, --directory <path>', 'Target directory (default: current directory)')
  .option('-y, --yes', 'Non-interactive mode: skip prompts and use defaults')
  .option('-f, --force', 'Force-overwrite installer-owned files even if locally modified')
  .option('--update-conflicts <keep|take|backup>', 'During update: how to handle locally modified installer-owned files')
  .option('--list-options', 'Print available flags and exit')
  .option('--app-dir <path>', 'Application source directory (e.g., src)')
  .option('--checkpoint-command <cmd>', 'Checkpoint command (build + test)')
  .option('--stack-description <text>', 'Stack description (tech choices, testing approach)')
  .option('--use-bmad <yes|no>', 'Install BMAD method modules alongside the loop')
  .option('--task-source <scaffold|existing>', 'Task source: scaffold template or existing PRD/epic')
  .option('--skip-npm-script <yes|no>', 'Skip adding npm scripts for the loop')
  .action(async (options) => {
    // --list-options: print available flags and exit 0
    if (options.listOptions) {
      console.log(listOptions());
      process.exit(0);
    }

    // Parse and validate per-question CLI flags
    const cliArgs = parseCliArgs(options);
    try {
      validateCliArgs(cliArgs);
    } catch (err) {
      console.error(`Error: ${err.message}`);
      process.exit(1);
    }

    const targetDir = resolve(options.directory ?? '.');

    // Run preflight checks
    const preflightResults = await preflight();
    renderChecklist(preflightResults);

    if (preflightResults.node.status === 'fail') {
      console.error('\nNode.js version check failed. Please upgrade Node.js to >= 20.');
      process.exit(1);
    }
    if (preflightResults.bash.status === 'fail') {
      console.error('\nBash environment check failed. Please install bash (WSL2 or Git Bash on Windows).');
      process.exit(2);
    }

    // Classify target directory
    let classifyResult;
    try {
      classifyResult = await classifyTarget(targetDir);
    } catch (err) {
      console.error(`\nError: ${err.message}`);
      process.exit(1);
    }

    // Update mode: existing install detected — skip wizard and run update flow
    if (classifyResult.type === 'existing-install') {
      const validConflictValues = ['keep', 'take', 'backup'];
      if (options.updateConflicts && !validConflictValues.includes(options.updateConflicts)) {
        console.error(`Error: Invalid --update-conflicts value: ${options.updateConflicts}. Valid values: keep, take, backup`);
        process.exit(1);
        return;
      }

      let updateInfo;
      try {
        updateInfo = await detectUpdate(targetDir);
      } catch (err) {
        console.error(`\nUpdate detection failed: ${err.message}`);
        process.exit(1);
        return;
      }

      if (!updateInfo.isUpdate) {
        console.log('Already up to date.');
        process.exit(0);
        return;
      }

      const { delta, manifest } = updateInfo;
      console.log(`installed v${updateInfo.installedVersion} → available v${updateInfo.availableVersion}`);

      const conflictFiles = delta.installerOwned.filter((e) => e.isModified);
      console.log(
        `${delta.installerOwned.length} installer-owned file(s) to update, ` +
        `${conflictFiles.length} conflict(s), ` +
        `${delta.userOwned.length} user-owned file(s) preserved`,
      );

      const resolution = await resolveConflicts(conflictFiles, {
        yes: options.yes ?? false,
        force: options.force ?? false,
        updateConflicts: options.updateConflicts ?? null,
      });

      if (!resolution.succeeded) {
        for (const err of resolution.errors) {
          console.error(`Error: ${err}`);
        }
        process.exit(1);
        return;
      }

      const wa = manifest.wizardAnswers ?? {};
      const updatePlan = {
        targetDir,
        appDir: wa.appDir ?? 'src',
        checkpointCommand: wa.checkpointCommand ?? 'npm run build && npm test',
        stackDescription: wa.stackDescription ?? 'Unknown stack',
        taskSource: wa.taskSource ?? 'scaffold',
        addGitignoreEntries: false,
        wizardAnswers: wa,
      };

      let updateResult;
      try {
        updateResult = await executeUpdate(targetDir, updatePlan, delta, resolution.decisions);
      } catch (err) {
        console.error(`\nUpdate failed: ${err.message}`);
        process.exit(1);
        return;
      }

      console.log(`\nUpdated ${updateResult.writtenFiles.length} file(s). Manifest rewritten.`);
      if (updateResult.backedUpFiles.length > 0) {
        console.log(`Backed up: ${updateResult.backedUpFiles.map((f) => `${f}.backup`).join(', ')}`);
      }
      return;
    }

    // Run wizard (interactive or non-interactive via --yes)
    let installPlan;
    try {
      installPlan = await runWizard(targetDir, classifyResult.type, preflightResults, {
        useDefaults: options.yes ?? false,
        cliAnswers: cliArgs,
      });
    } catch (err) {
      console.error(`\nInstaller error: ${err.message}`);
      process.exit(1);
    }
    if (!installPlan) {
      // User cancelled — exit cleanly (wizard already printed "Nothing was changed.")
      process.exit(0);
    }

    // Attach CLI flags so the writer can use them in conflict resolution
    installPlan.yes = options.yes ?? false;
    installPlan.force = options.force ?? false;

    // Execute the install
    let result;
    try {
      result = await writeInstall(installPlan);
    } catch (err) {
      console.error(`\nInstall failed: ${err.message}`);
      process.exit(1);
    }

    if (result.status === 'cancelled') {
      process.exit(0);
    }

    console.log(`\nInstalled ${result.filesWritten} file(s). Manifest written to .ralph/manifest.json.`);
    printOutro(result, installPlan);
  });

program
  .command('update')
  .description('Update an existing Ralph Loop installation')
  .option('-d, --directory <path>', 'Target directory (default: current directory)')
  .option('-y, --yes', 'Non-interactive mode: skip prompts and use defaults')
  .option('-f, --force', 'Force update without prompting')
  .option('--update-conflicts <keep|take|backup>', 'How to handle locally modified installer-owned files')
  .action(async (options) => {
    const targetDir = resolve(options.directory ?? '.');

    const validConflictValues = ['keep', 'take', 'backup'];
    if (options.updateConflicts && !validConflictValues.includes(options.updateConflicts)) {
      console.error(`Error: Invalid --update-conflicts value: ${options.updateConflicts}. Valid values: keep, take, backup`);
      process.exit(1);
      return;
    }

    let classifyResult;
    try {
      classifyResult = await classifyTarget(targetDir);
    } catch (err) {
      console.error(`\nError: ${err.message}`);
      process.exit(1);
      return;
    }

    if (classifyResult.type !== 'existing-install') {
      console.error('No existing Ralph Loop installation found in this directory. Run install first.');
      process.exit(1);
      return;
    }

    let updateInfo;
    try {
      updateInfo = await detectUpdate(targetDir);
    } catch (err) {
      console.error(`\nUpdate detection failed: ${err.message}`);
      process.exit(1);
      return;
    }

    if (!updateInfo.isUpdate) {
      console.log('Already up to date.');
      process.exit(0);
      return;
    }

    const { delta, manifest } = updateInfo;
    console.log(`installed v${updateInfo.installedVersion} → available v${updateInfo.availableVersion}`);

    const conflictFiles = delta.installerOwned.filter((e) => e.isModified);
    console.log(
      `${delta.installerOwned.length} installer-owned file(s) to update, ` +
      `${conflictFiles.length} conflict(s), ` +
      `${delta.userOwned.length} user-owned file(s) preserved`,
    );

    const resolution = await resolveConflicts(conflictFiles, {
      yes: options.yes ?? false,
      force: options.force ?? false,
      updateConflicts: options.updateConflicts ?? null,
    });

    if (!resolution.succeeded) {
      for (const err of resolution.errors) {
        console.error(`Error: ${err}`);
      }
      process.exit(1);
      return;
    }

    const wa = manifest.wizardAnswers ?? {};
    const updatePlan = {
      targetDir,
      appDir: wa.appDir ?? 'src',
      checkpointCommand: wa.checkpointCommand ?? 'npm run build && npm test',
      stackDescription: wa.stackDescription ?? 'Unknown stack',
      taskSource: wa.taskSource ?? 'scaffold',
      addGitignoreEntries: false,
      wizardAnswers: wa,
    };

    let updateResult;
    try {
      updateResult = await executeUpdate(targetDir, updatePlan, delta, resolution.decisions);
    } catch (err) {
      console.error(`\nUpdate failed: ${err.message}`);
      process.exit(1);
      return;
    }

    console.log(`\nUpdated ${updateResult.writtenFiles.length} file(s). Manifest rewritten.`);
    if (updateResult.backedUpFiles.length > 0) {
      console.log(`Backed up: ${updateResult.backedUpFiles.map((f) => `${f}.backup`).join(', ')}`);
    }
  });

program
  .command('uninstall')
  .description('Remove a Ralph Loop installation')
  .option('-d, --directory <path>', 'Target directory (default: current directory)')
  .option('-y, --yes', 'Preserve user-owned files without prompting')
  .option('-f, --force', 'Remove all files without prompting')
  .action(async (options) => {
    const targetDir = resolve(options.directory ?? '.');
    const result = await uninstall({
      targetDir,
      yes: options.yes ?? false,
      force: options.force ?? false,
    });

    if (!result.success) {
      console.error(result.message);
      process.exit(1);
    } else {
      console.log(result.message);
      process.exit(0);
    }
  });

program
  .command('doctor')
  .description('Validate an existing Ralph Loop installation')
  .option('-d, --directory <path>', 'Target directory (default: current directory)')
  .action(async (options) => {
    const targetDir = resolve(options.directory ?? '.');

    try {
      const result = await runDoctor(targetDir);
      process.exit(result.passed ? 0 : 1);
    } catch (err) {
      console.error(`Doctor error: ${err.message}`);
      process.exit(2);
    }
  });

program.parse(process.argv);

if (process.argv.length === 2) {
  program.outputHelp();
  process.exit(0);
}
