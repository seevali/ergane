import { promises as fs } from 'node:fs';
import path from 'node:path';
import { isColorEnabled } from './colors.js';
import {
  loadManifest as loadManifestShared,
  ManifestError,
  MANIFEST_NOT_FOUND_MESSAGE,
} from './manifest.js';

/**
 * Compatibility wrapper around the shared manifest loader (src/manifest.js).
 * Takes a manifest *file* path (legacy signature), returns the parsed manifest,
 * `null` when the file is absent, and throws (message includes "corrupted") when
 * present-but-malformed. The single source of truth is src/manifest.js.
 */
export async function loadManifest(manifestPath) {
  const targetDir = path.dirname(path.dirname(manifestPath));
  try {
    return await loadManifestShared(targetDir);
  } catch (err) {
    if (err instanceof ManifestError && err.code === 'not-found') {
      return null;
    }
    throw err;
  }
}

/**
 * Separate manifest file entries into installer-owned and user-owned arrays.
 * @param {Record<string,{ownership:string}>} manifestEntries
 * @returns {{ installerOwned: string[], userOwned: string[] }}
 */
export function categorizeFiles(manifestEntries) {
  const installerOwned = [];
  const userOwned = [];

  for (const [filePath, entry] of Object.entries(manifestEntries)) {
    if (entry && entry.ownership === 'installer-owned') {
      installerOwned.push(filePath);
    } else {
      userOwned.push(filePath);
    }
  }

  return { installerOwned, userOwned };
}

/**
 * Remove a single file. Returns { success: boolean, error: string|null }.
 * ENOENT (already gone) is treated as success.
 */
export async function removeFile(filePath) {
  try {
    await fs.unlink(filePath);
    return { success: true, error: null };
  } catch (err) {
    if (err.code === 'ENOENT') {
      return { success: true, error: null };
    }
    return { success: false, error: err.message };
  }
}

/**
 * Prune directories that the installer created and that are now empty after file
 * removal. Only removes empty directories, so any directory still holding a
 * preserved user-owned file is left in place. Never touches `targetDir` itself.
 *
 * Contract (spec L1): remove "now-empty directories the installer created (and
 * only those)". When the manifest records `createdDirs` (the dirs the install
 * actually brought into existence — see writeManifest), that list is the
 * AUTHORITATIVE candidate set: a directory the user created before install is
 * never in it, so a pre-existing empty `docs/` or `scripts/` survives uninstall.
 * Legacy manifests (written before createdDirs was recorded) pass `undefined`
 * here; for those we fall back to deriving candidates from the manifest file
 * paths (best-effort — the pre-createdDirs behavior).
 *
 * @param {string} targetDir
 * @param {string[]} relPaths - every relative file path the manifest listed
 * @param {string[]} [createdDirs] - dirs the installer created (authoritative when present)
 * @returns {Promise<string[]>} relative directory paths that were removed
 */
export async function pruneEmptyInstallerDirs(targetDir, relPaths, createdDirs) {
  const dirs = new Set();
  if (Array.isArray(createdDirs)) {
    // Authoritative: only consider dirs the installer itself created. An empty
    // array means the install created no dirs (every needed dir pre-existed) →
    // prune nothing, honoring "and only those the installer created".
    for (const dir of createdDirs) {
      const n = dir.replace(/\\/g, '/');
      if (n && n !== '.' && n !== '/') dirs.add(n);
    }
  } else {
    // Legacy fallback: derive candidates from manifest file paths.
    for (const relPath of relPaths) {
      let dir = path.posix.dirname(relPath.replace(/\\/g, '/'));
      while (dir && dir !== '.' && dir !== '/') {
        dirs.add(dir);
        dir = path.posix.dirname(dir);
      }
    }
  }

  // Deepest first, so child dirs empty out before their parents are checked.
  const ordered = [...dirs].sort((a, b) => b.split('/').length - a.split('/').length);

  const removed = [];
  for (const relDir of ordered) {
    const result = await removeEmptyDir(path.join(targetDir, relDir));
    if (result.success) {
      removed.push(relDir);
    }
  }
  return removed;
}

/**
 * Remove a directory only if it is empty.
 * Returns { success: boolean, reason?: string }.
 */
export async function removeEmptyDir(dirPath) {
  try {
    const entries = await fs.readdir(dirPath);
    if (entries.length > 0) {
      return { success: false, reason: 'not-empty' };
    }
    await fs.rmdir(dirPath);
    return { success: true };
  } catch (err) {
    return { success: false, reason: err.message };
  }
}

/**
 * Remove the Ralph Loop section from a .gitignore file.
 * The section starts at the `# Ralph Loop` line and continues until a blank
 * line or another comment header (or EOF). If the file becomes empty after
 * removal it is deleted; if the file doesn't exist this is a no-op.
 */
export async function cleanGitignore(gitignorePath) {
  let content;
  try {
    content = await fs.readFile(gitignorePath, 'utf8');
  } catch {
    return;
  }

  const lines = content.split('\n');
  const result = [];
  let inRalphSection = false;

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === '# Ralph Loop') {
      inRalphSection = true;
      continue;
    }
    if (inRalphSection) {
      // End of Ralph section: blank line or another comment header
      if (trimmed === '' || trimmed.startsWith('#')) {
        inRalphSection = false;
        if (trimmed !== '') {
          result.push(line);
        }
      }
      // else: skip this Ralph Loop entry
    } else {
      result.push(line);
    }
  }

  // Strip trailing empty lines
  while (result.length > 0 && result[result.length - 1].trim() === '') {
    result.pop();
  }

  if (result.length === 0) {
    await fs.unlink(gitignorePath);
  } else {
    await fs.writeFile(gitignorePath, result.join('\n') + '\n', 'utf8');
  }
}

/**
 * Uninstall a Ralph Loop installation from the target directory.
 *
 * Five-phase flow:
 *   1. Load and validate .ralph/manifest.json
 *   2. Categorize files by ownership class
 *   3. Remove installer-owned files (except .gitignore)
 *   4. Handle user-owned files per --yes / --force / interactive prompt
 *   3b. Clean .gitignore (remove Ralph Loop section only)
 *   5. Remove .ralph/manifest.json and .ralph/ directory (if empty)
 *
 * @param {object} options
 * @param {string}  options.targetDir        - Directory containing the installation
 * @param {boolean} [options.yes=false]      - Preserve user-owned files without prompting
 * @param {boolean} [options.force=false]    - Remove all files without prompting
 * @param {object}  [opts]                   - Injectable dependencies for testing
 * @param {Function} [opts.log]              - Override console.log
 * @param {Function} [opts.errLog]           - Override console.error
 * @param {object}   [opts.prompts]          - Injectable { confirm, isCancel }
 * @param {boolean}  [opts.isTTY]            - Override TTY detection
 * @param {boolean}  [opts.noColor]          - Override NO_COLOR detection
 * @returns {Promise<{ success: boolean, message: string }>}
 */
export async function uninstall(options, opts = {}) {
  const { targetDir, yes = false, force = false } = options;
  const log = opts.log ?? console.log;
  const errLog = opts.errLog ?? console.error;

  const colorOpts = {
    isTTY: 'isTTY' in opts ? opts.isTTY : process.stdout.isTTY === true,
    noColor: 'noColor' in opts ? opts.noColor : process.env.NO_COLOR !== undefined,
  };
  const colored = isColorEnabled(colorOpts);
  const ok = colored ? '\x1b[32m✓\x1b[0m' : '✓';
  const fail = colored ? '\x1b[31m✗\x1b[0m' : '✗';

  // Phase 1: Load and validate manifest
  const manifestPath = path.join(targetDir, '.ralph', 'manifest.json');
  let manifest;
  try {
    manifest = await loadManifest(manifestPath);
  } catch (err) {
    return { success: false, message: err.message };
  }

  if (manifest === null) {
    return {
      success: false,
      message: MANIFEST_NOT_FOUND_MESSAGE,
    };
  }

  // Phase 2: Categorize files
  const { installerOwned, userOwned } = categorizeFiles(manifest.files ?? {});

  // Fail closed BEFORE deleting anything if we'd need to prompt but cannot.
  // A non-interactive terminal with neither --yes nor --force would otherwise hit
  // the @clack confirm and crash with a raw TTY-init stack trace mid-delete, leaving
  // a half-removed, corrupt install. Bail here so the tree is left untouched.
  const needsPrompt = !force && !yes && userOwned.length > 0;
  if (needsPrompt && !opts.prompts) {
    const stdinIsTTY = 'stdinIsTTY' in opts ? opts.stdinIsTTY : process.stdin.isTTY === true;
    if (!stdinIsTTY) {
      return {
        success: false,
        message:
          'Uninstall needs an interactive terminal to confirm removing your files.\n' +
          'Re-run with --yes to keep user-owned files, or --force to remove everything.',
      };
    }
  }

  // Phase 3: Remove installer-owned files (excluding .gitignore — handled in phase 3b)
  const errors = [];
  let removedCount = 0;

  for (const relPath of installerOwned) {
    if (relPath === '.gitignore') continue;
    const fullPath = path.join(targetDir, relPath);
    const result = await removeFile(fullPath);
    if (result.success) {
      log(`${ok} Removed ${relPath}`);
      removedCount++;
    } else {
      errLog(`${fail} Could not remove ${relPath}: ${result.error}`);
      errors.push(`Could not remove ${relPath}: ${result.error}`);
    }
  }

  // Phase 4: Handle user-owned files
  let userFilesPreserved = 0;

  if (userOwned.length > 0) {
    if (force) {
      for (const relPath of userOwned) {
        const fullPath = path.join(targetDir, relPath);
        const result = await removeFile(fullPath);
        if (result.success) {
          log(`${ok} Removed ${relPath}`);
          removedCount++;
        } else {
          errLog(`${fail} Could not remove ${relPath}: ${result.error}`);
          errors.push(`Could not remove ${relPath}: ${result.error}`);
        }
      }
    } else if (yes) {
      userFilesPreserved = userOwned.length;
      log(`[Skipped] ${userFilesPreserved} user-owned file${userFilesPreserved !== 1 ? 's' : ''} preserved.`);
    } else {
      log('\nUser-owned files found:');
      for (const relPath of userOwned) {
        log(`  ${relPath}`);
      }

      let promptConfirm, promptIsCancel;
      if (opts.prompts) {
        promptConfirm = opts.prompts.confirm;
        promptIsCancel = opts.prompts.isCancel;
      } else {
        const clack = await import('@clack/prompts');
        promptConfirm = clack.confirm;
        promptIsCancel = clack.isCancel;
      }

      const answer = await promptConfirm({ message: 'Remove these files too? (y/n)' });
      const shouldRemove = !promptIsCancel(answer) && answer === true;

      if (shouldRemove) {
        for (const relPath of userOwned) {
          const fullPath = path.join(targetDir, relPath);
          const result = await removeFile(fullPath);
          if (result.success) {
            log(`${ok} Removed ${relPath}`);
            removedCount++;
          } else {
            errLog(`${fail} Could not remove ${relPath}: ${result.error}`);
            errors.push(`Could not remove ${relPath}: ${result.error}`);
          }
        }
      } else {
        userFilesPreserved = userOwned.length;
        log(`[Skipped] ${userFilesPreserved} user-owned file${userFilesPreserved !== 1 ? 's' : ''} preserved.`);
      }
    }
  }

  // Phase 3b: Clean .gitignore (after user-owned files, before manifest removal)
  if (installerOwned.includes('.gitignore')) {
    const gitignorePath = path.join(targetDir, '.gitignore');
    try {
      await cleanGitignore(gitignorePath);
      log(`${ok} Cleaned .gitignore (removed Ralph Loop section)`);
      removedCount++;
    } catch (err) {
      errLog(`${fail} Could not clean .gitignore: ${err.message}`);
      errors.push(`Could not clean .gitignore: ${err.message}`);
    }
  }

  // Phase 5: Remove manifest and .ralph/ directory
  const manifestRemoveResult = await removeFile(manifestPath);
  if (!manifestRemoveResult.success) {
    return {
      success: false,
      message: `Cannot remove manifest: ${manifestRemoveResult.error}`,
    };
  }

  const ralphDir = path.join(targetDir, '.ralph');
  const dirResult = await removeEmptyDir(ralphDir);
  if (dirResult.success) {
    log(`${ok} Removed .ralph/ directory`);
  } else if (dirResult.reason === 'not-empty') {
    log('.ralph/ directory is not empty. Leaving it in place.');
  } else {
    log(`.ralph/ directory could not be removed: ${dirResult.reason}`);
  }

  // Phase 6: Prune now-empty directories the installer created (docs/epics,
  // scripts/prompts/*, etc.). Only empty dirs go — a dir still holding a preserved
  // user file survives. This leaves the tree as it was pre-install (modulo user files).
  const prunedDirs = await pruneEmptyInstallerDirs(
    targetDir,
    Object.keys(manifest.files ?? {}),
    manifest.createdDirs,
  );
  for (const relDir of prunedDirs) {
    log(`${ok} Removed empty directory ${relDir}/`);
  }

  // Summary
  const summary = `Uninstall complete. ${removedCount} file${removedCount !== 1 ? 's' : ''} removed, ${userFilesPreserved} file${userFilesPreserved !== 1 ? 's' : ''} preserved.`;
  log(summary);

  // Non-critical errors with --force are suppressed (success: true)
  const success = errors.length === 0 || force;
  return {
    success,
    message: success ? summary : `Uninstall encountered errors. ${errors.join('; ')}`,
  };
}
