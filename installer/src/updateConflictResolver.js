const VALID_VALUES = ['keep', 'take', 'backup'];
const DEFAULT_RESOLUTION = 'keep';

/**
 * Resolve how to handle each locally-modified installer-owned file during an update.
 *
 * Modes:
 *   Interactive (TTY, no --yes, no --force): prompt per conflicting file via @clack/prompts
 *   Non-interactive (non-TTY or --yes or --force): apply --update-conflicts or default ("keep")
 *
 * @param {Array<{path: string, checksum: string|null, currentChecksum: string, isModified: boolean}>} conflictFiles
 * @param {{yes?: boolean, force?: boolean, updateConflicts?: string|null}} options
 * @param {object} [opts]
 * @param {object}   [opts.prompts]  - injectable { select, isCancel } (for testing)
 * @param {Function} [opts.log]      - injectable console.log (for testing)
 * @param {boolean}  [opts.isTTY]    - override TTY detection (for testing)
 * @returns {Promise<{decisions: {[path: string]: 'keep'|'take'|'backup'}, succeeded: boolean, errors: string[]}>}
 */
export async function resolveConflicts(conflictFiles, options, opts = {}) {
  const { yes = false, force = false, updateConflicts = null } = options;
  const log = opts.log ?? console.log;
  const isTTY = 'isTTY' in opts ? opts.isTTY : (process.stdout.isTTY ?? false);

  // Validate --update-conflicts before any writes
  if (updateConflicts !== null && !VALID_VALUES.includes(updateConflicts)) {
    return {
      decisions: {},
      succeeded: false,
      errors: [`Invalid --update-conflicts value: ${updateConflicts}. Valid values: keep, take, backup`],
    };
  }

  if (conflictFiles.length === 0) {
    return { decisions: {}, succeeded: true, errors: [] };
  }

  const decisions = {};

  if (!isTTY || yes || force) {
    const resolution = updateConflicts ?? DEFAULT_RESOLUTION;

    if (updateConflicts == null && (yes || !isTTY)) {
      log(`Using default conflict resolution: ${DEFAULT_RESOLUTION} (use --update-conflicts to override)`);
    }

    for (const file of conflictFiles) {
      decisions[file.path] = resolution;
      log(`${file.path}: ${resolution}`);
    }

    return { decisions, succeeded: true, errors: [] };
  }

  // Interactive mode
  let promptSelect, promptIsCancel;
  if (opts.prompts) {
    promptSelect = opts.prompts.select;
    promptIsCancel = opts.prompts.isCancel;
  } else {
    const clack = await import('@clack/prompts');
    promptSelect = clack.select;
    promptIsCancel = clack.isCancel;
  }

  for (const file of conflictFiles) {
    const choice = await promptSelect({
      message: `${file.path} — modified by you, new version available. What should we do?`,
      options: [
        { value: 'keep', label: 'Keep my changes', hint: 'Skip this file' },
        { value: 'take', label: 'Take the new version', hint: 'Overwrite with installer version' },
        { value: 'backup', label: 'Backup and take new', hint: 'Rename to .backup, then write new' },
      ],
    });

    decisions[file.path] = promptIsCancel(choice) ? DEFAULT_RESOLUTION : choice;
  }

  return { decisions, succeeded: true, errors: [] };
}
