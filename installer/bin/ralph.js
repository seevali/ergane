#!/usr/bin/env node

import { program } from 'commander';
import { readFileSync } from 'fs';
import { access, constants } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join, resolve } from 'path';
import { preflight, renderChecklist, checkGitIdentity, checkGh } from '../src/preflight.js';
import { classifyTarget, findAncestorInstall } from '../src/classify.js';
import { runWizard } from '../src/wizard.js';
import { writeInstall, executeUpdate } from '../src/writer.js';
import { printOutro } from '../src/outro.js';
import { runDoctor } from '../src/doctor.js';
import { parseCliArgs, validateCliArgs, listOptions } from '../src/cli-parser.js';
import { detectUpdate } from '../src/updateDetector.js';
import { resolveConflicts } from '../src/updateConflictResolver.js';
import { uninstall } from '../src/uninstall.js';
import { ManifestError } from '../src/manifest.js';

const CONFLICT_VALUES = ['keep', 'take', 'backup'];

/**
 * Fail fast if the target directory is not writable, BEFORE the wizard runs — a
 * read-only target must not fail only at the final write step after the whole flow.
 * @returns {Promise<boolean>} true if writable
 */
async function isWritable(dir) {
  try {
    await access(dir, constants.W_OK);
    return true;
  } catch {
    return false;
  }
}

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const packagePath = join(__dirname, '../package.json');
const { version } = JSON.parse(readFileSync(packagePath, 'utf8'));

program
  .version(version, '-v, --version', 'Show version number and exit')
  .helpOption('-h, --help', 'Show help and exit')
  .description('Ergane guided installer — set up a new loop project in minutes');

program
  .command('install')
  .alias('init')
  .description('Install or update an Ergane project')
  .option('-d, --directory <path>', 'Target directory (default: current directory)')
  .option('-y, --yes', 'Non-interactive mode: skip prompts and use defaults')
  .option('-f, --force', 'Force-overwrite installer-owned files even if locally modified')
  .option('--update-conflicts <keep|take|backup>', 'During update: how to handle locally modified installer-owned files')
  .option('--list-options', 'Print available flags and exit')
  .option('--app-dir <path>', 'Application source directory (e.g., src)')
  .option('--checkpoint-command <cmd>', 'Checkpoint command (build + test)')
  .option('--stack-description <text>', 'Stack description (tech choices, testing approach)')
  .option('--use-bmad <yes|no>', 'Install BMAD method modules alongside the loop')
  .option('--task-source <scaffold|existing|example>', 'Task source: scaffold template, existing PRD/epic, or the worked example')
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

    // Validate --update-conflicts unconditionally (it was previously ignored on the
    // fresh-install path, so a typo was silently swallowed depending on target state).
    if (options.updateConflicts && !CONFLICT_VALUES.includes(options.updateConflicts)) {
      console.error(`Error: Invalid --update-conflicts value: ${options.updateConflicts}. Valid values: ${CONFLICT_VALUES.join(', ')}`);
      process.exit(1);
    }

    const targetDir = resolve(options.directory ?? '.');

    // Run preflight checks
    const preflightResults = await preflight();
    renderChecklist(preflightResults);

    // Ground checks the LOOP (not the installer) will need. Advisory only — these
    // never break --yes/non-TTY: git identity is a warn, gh is informational.
    const gitIdentity = checkGitIdentity();
    if (gitIdentity.status !== 'pass') {
      console.log(gitIdentity.message);
    }
    const gh = checkGh();
    console.log(gh.message);

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

    // Preflight the ground before the wizard: writable-target check FIRST, so a
    // read-only target fails here instead of at the final write step after the
    // whole wizard flow.
    if (!(await isWritable(targetDir))) {
      console.error(`\nError: target directory is not writable: ${targetDir}\n  Fix permissions and retry: chmod +w ${targetDir}`);
      process.exit(1);
    }

    // Update mode: existing install detected — skip wizard and run update flow
    if (classifyResult.type === 'existing-install') {
      let updateInfo;
      try {
        updateInfo = await detectUpdate(targetDir);
      } catch (err) {
        if (err instanceof ManifestError) {
          console.error(`\nError: ${err.message}`);
          process.exit(1);
          return;
        }
        console.error(`\nUpdate detection failed: ${err.message}`);
        process.exit(1);
        return;
      }

      if (updateInfo.upToDate) {
        console.log(`Already up to date (v${updateInfo.installedVersion}, no drifted files).`);
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

    // Nested-install guard: warn when an ancestor directory already has an Ergane
    // install. Proceed only with explicit confirmation (or --force in --yes mode) so a
    // second, independent nested install isn't created silently.
    const ancestorInstall = await findAncestorInstall(targetDir);
    if (ancestorInstall) {
      console.log(`\n⚠ An existing Ergane install was found above this directory:\n  ${ancestorInstall}`);
      if (options.yes) {
        if (!options.force) {
          console.error('Refusing to create a nested install non-interactively. Re-run with --force to proceed anyway.');
          process.exit(1);
        }
        console.log('Proceeding with a nested install (--force).');
      } else {
        const { confirm, isCancel } = await import('@clack/prompts');
        const answer = await confirm({ message: 'Create a nested install here anyway?', initialValue: false });
        if (isCancel(answer) || answer !== true) {
          console.log('Nothing was changed.');
          process.exit(0);
        }
      }
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
  .description('Update an existing Ergane installation')
  .option('-d, --directory <path>', 'Target directory (default: current directory)')
  .option('-y, --yes', 'Non-interactive mode: skip prompts and use defaults')
  .option('-f, --force', 'Force update without prompting')
  .option('--update-conflicts <keep|take|backup>', 'How to handle locally modified installer-owned files')
  .action(async (options) => {
    const targetDir = resolve(options.directory ?? '.');

    if (options.updateConflicts && !CONFLICT_VALUES.includes(options.updateConflicts)) {
      console.error(`Error: Invalid --update-conflicts value: ${options.updateConflicts}. Valid values: ${CONFLICT_VALUES.join(', ')}`);
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
      console.error('No existing Ergane installation found in this directory. Run install first.');
      process.exit(1);
      return;
    }

    let updateInfo;
    try {
      updateInfo = await detectUpdate(targetDir);
    } catch (err) {
      if (err instanceof ManifestError) {
        console.error(`\nError: ${err.message}`);
        process.exit(1);
        return;
      }
      console.error(`\nUpdate detection failed: ${err.message}`);
      process.exit(1);
      return;
    }

    if (updateInfo.upToDate) {
      console.log(`Already up to date (v${updateInfo.installedVersion}, no drifted files).`);
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
  .description('Remove an Ergane installation')
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
      // On failure, uninstall() returns before printing (nothing was removed), so the
      // bin surfaces the message here.
      console.error(result.message);
      process.exit(1);
    } else {
      // On success, uninstall() has already printed the full summary — do NOT re-log
      // it here (that produced the duplicated completion line).
      process.exit(0);
    }
  });

program
  .command('doctor')
  .description('Validate an existing Ergane installation')
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

// Bare invocation (no subcommand): show help on STDOUT and exit 0, BEFORE
// commander's own no-command handling writes help to stderr and exits 1.
if (process.argv.length === 2) {
  program.outputHelp();
  process.exit(0);
}

program.parse(process.argv);
