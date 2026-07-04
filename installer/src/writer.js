import { promises as fs } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { installBmad } from './bmad.js';
import { getPackageName, cliInvocation } from './pkg.js';
import { tryLoadManifest } from './manifest.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TEMPLATES_DIR = path.join(__dirname, '..', 'templates', 'loop');

// ── Pure functions (fully testable without filesystem) ────────────────────────

/**
 * Substitute {{KEY}} placeholders in templateContent.
 * @param {string} templateContent
 * @param {Record<string,string>} substitutions - { KEY: 'value', ... }
 * @returns {string}
 */
export function renderTemplate(templateContent, substitutions) {
  let rendered = templateContent;
  for (const [key, value] of Object.entries(substitutions)) {
    const placeholder = `{{${key}}}`;
    rendered = rendered.replaceAll(placeholder, value ?? '');
  }
  return rendered;
}

/**
 * Throw if any {{PLACEHOLDER}} patterns remain in content.
 * @param {string} content
 */
export function validateNoUnsubstituted(content) {
  const unreplaced = content.match(/\{\{[A-Z_]+\}\}/g);
  if (unreplaced) {
    throw new Error(`Unsubstituted placeholders: ${unreplaced.join(', ')}`);
  }
}

/**
 * Extract story IDs from content containing "### Story X.Y: Title" headers.
 * @param {string} content
 * @returns {string[]} e.g. ["1.1", "1.2"]
 */
export function extractStoryIds(content) {
  const matches = [...content.matchAll(/^###\s+Story\s+(\d+\.\d+):/gm)];
  return matches.map((m) => m[1]);
}

// ── Filesystem helpers ────────────────────────────────────────────────────────

/**
 * Compute sha256 checksum of a file, normalizing CRLF → LF before hashing.
 * @param {string} filePath
 * @returns {Promise<string>} "sha256:<hex>"
 */
export async function hashFile(filePath) {
  const content = await fs.readFile(filePath, 'utf8');
  return hashString(content);
}

/**
 * Compute sha256 checksum of a string, normalizing CRLF → LF.
 * @param {string} content
 * @returns {string} "sha256:<hex>"
 */
export function hashString(content) {
  const normalized = content.replace(/\r\n/g, '\n');
  return 'sha256:' + crypto.createHash('sha256').update(normalized).digest('hex');
}

/**
 * Load and parse .ralph/manifest.json for internal conflict/update bookkeeping.
 * Returns null when absent or unreadable — the "is this dir corrupted?" decision
 * is made upstream (bin → detectUpdate) so the writer treats any load failure as
 * "no prior manifest to reconcile against". Uses the shared parser (src/manifest.js).
 * @param {string} targetPath
 * @returns {Promise<object|null>}
 */
async function loadManifest(targetPath) {
  const { manifest } = await tryLoadManifest(targetPath);
  return manifest ?? null;
}

/**
 * Determine ownership class for a relative file path.
 * installer-owned: files the installer manages and may overwrite on update.
 * user-owned: files the user edits; the installer never overwrites them.
 * @param {string} filePath - forward-slash relative path
 * @returns {'installer-owned'|'user-owned'}
 */
function getOwnership(filePath) {
  const normalized = filePath.replace(/\\/g, '/');

  if (
    normalized === 'scripts/ralph-loop.sh' ||
    normalized === 'scripts/ralph-watch.sh' ||
    normalized.startsWith('scripts/prompts/') ||
    normalized === 'docs/project-conventions.md' ||
    normalized === '.gitignore'
  ) {
    return 'installer-owned';
  }

  // Scaffold docs (docs/epics/, docs/prd.md) are user-owned: the user will edit them.
  return 'user-owned';
}

// ── Phase 1: Build write map ──────────────────────────────────────────────────

async function loadTemplateFile(templateName) {
  const templatePath = path.join(TEMPLATES_DIR, templateName);
  return fs.readFile(templatePath, 'utf8');
}

async function gatherPromptFiles() {
  const promptsDir = path.join(TEMPLATES_DIR, 'prompts');
  const files = new Map();

  async function walk(dir, base) {
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      const relPath = base ? `${base}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        await walk(fullPath, relPath);
      } else {
        const content = await fs.readFile(fullPath, 'utf8');
        files.set(`scripts/prompts/${relPath}`, content);
      }
    }
  }

  await walk(promptsDir, '');
  return files;
}

async function buildGitignoreContent(targetPath, entries) {
  if (!entries || entries.length === 0) return null;

  let existing = '';
  try {
    existing = await fs.readFile(path.join(targetPath, '.gitignore'), 'utf8');
  } catch {
    // No existing .gitignore; start fresh
  }

  const existingLines = new Set(existing.split('\n').map((l) => l.trim()));
  const toAdd = entries.filter((e) => !existingLines.has(e));

  if (toAdd.length === 0) return null;

  const separator = existing && !existing.endsWith('\n') ? '\n' : '';
  const header = '\n# Ralph Loop\n';
  return existing + separator + header + toAdd.join('\n') + '\n';
}

/**
 * Build the map of all files to write, keyed by relative path (forward slashes).
 * @param {object} plan - InstallPlan from runWizard()
 * @returns {Promise<Map<string,string>>}
 */
export async function buildWriteMap(plan) {
  const appDir = plan.appDir || 'src';
  const substitutions = {
    APP_DIR: appDir,
    CHECKPOINT_COMMAND: plan.checkpointCommand || 'npm run build && npm test',
    STACK_DESCRIPTION: plan.stackDescription || 'Unknown stack',
    PACKAGE_NAME: getPackageName(),
    // The runnable CLI invocation (`npx <name>`), defined once in pkg.js so the
    // guide and the outro tip name the CLI identically. Bare {{PACKAGE_NAME}} is
    // NOT runnable (the bin is `ralph`, not the package name), so user-facing
    // commands must use {{CLI_INVOCATION}}.
    CLI_INVOCATION: cliInvocation(),
  };

  const writeMap = new Map();

  // Always: docs/project-conventions.md (installer-owned)
  const conventionsTpl = await loadTemplateFile('project-conventions.md');
  const conventions = renderTemplate(conventionsTpl, substitutions);
  validateNoUnsubstituted(conventions);
  writeMap.set('docs/project-conventions.md', conventions);

  // Always: scripts/ralph-loop.sh (installer-owned, executable)
  const loopScript = await loadTemplateFile('ralph-loop.sh');
  writeMap.set('scripts/ralph-loop.sh', loopScript);

  // Always: scripts/ralph-watch.sh (installer-owned, executable) — the swarm
  // dashboard + pause/resume/abort brake that the loop's --issues features drive.
  const watchScript = await loadTemplateFile('ralph-watch.sh');
  writeMap.set('scripts/ralph-watch.sh', watchScript);

  // Always: scripts/prompts/** (installer-owned)
  const promptFiles = await gatherPromptFiles();
  for (const [filePath, content] of promptFiles) {
    writeMap.set(filePath, content);
  }

  // Always: GETTING-STARTED.md (user-owned). Rendered so the guide names the real
  // CLI (PACKAGE_NAME) and the configured app dir instead of literal placeholders.
  const gettingStartedTpl = await loadTemplateFile('GETTING-STARTED.md');
  const gettingStarted = renderTemplate(gettingStartedTpl, substitutions);
  validateNoUnsubstituted(gettingStarted);
  writeMap.set('GETTING-STARTED.md', gettingStarted);

  // Always: an empty app source directory so the loop's project-dir preflight
  // passes on a fresh install. A .gitkeep keeps the (otherwise empty) dir in git.
  // User-owned: it's the user's source tree — never overwritten or reverted.
  writeMap.set(`${appDir}/.gitkeep`, '');

  // Conditional: scaffold docs (user-owned — users will edit these)
  if (plan.taskSource === 'scaffold') {
    const prdTpl = await loadTemplateFile('epic-stub-prd.md');
    const prd = renderTemplate(prdTpl, substitutions);
    validateNoUnsubstituted(prd);
    writeMap.set('docs/epics/project-prd.md', prd);

    const storiesTpl = await loadTemplateFile('epic-stub-stories.md');
    const stories = renderTemplate(storiesTpl, substitutions);
    validateNoUnsubstituted(stories);
    writeMap.set('docs/epics/project-stories.md', stories);
  }

  // Conditional: .gitignore entries (installer-owned, append-only)
  if (plan.addGitignoreEntries && plan.gitignoreEntries?.length > 0) {
    const gitignoreContent = await buildGitignoreContent(
      plan.targetDir,
      plan.gitignoreEntries,
    );
    if (gitignoreContent !== null) {
      writeMap.set('.gitignore', gitignoreContent);
    }
  }

  return writeMap;
}

// ── Phase 2: Conflict detection ───────────────────────────────────────────────

/**
 * Detect files in writeMap that conflict with the existing filesystem state.
 *
 * Default-deny policy:
 *   - No manifest: any existing file is a conflict.
 *   - Manifest + user-owned: always a conflict (never overwrite).
 *   - Manifest + installer-owned, checksum changed: locally-modified conflict.
 *   - Manifest + installer-owned, checksum matches: safe to overwrite (no conflict).
 *
 * @param {object} plan - has .targetDir
 * @param {Map<string,string>} writeMap
 * @returns {Promise<Array<{path,reason,existingChecksum?,manifestChecksum?}>>}
 */
export async function detectConflicts(plan, writeMap) {
  const conflicts = [];
  const targetPath = plan.targetDir;
  const manifest = await loadManifest(targetPath);

  for (const [filePath] of writeMap) {
    const fullPath = path.join(targetPath, filePath);

    // .gitignore is never a blocking conflict: buildGitignoreContent() already
    // produced an append-merge of the user's existing file + a deduped "# Ralph Loop"
    // section, so writing it preserves everything. A pre-existing .gitignore (which
    // every real project has) must NOT hard-fail install or demand --force.
    if (filePath === '.gitignore') continue;

    let exists = false;
    try {
      await fs.access(fullPath);
      exists = true;
    } catch {
      // File doesn't exist — no conflict
    }

    if (!exists) continue;

    if (!manifest) {
      // No manifest: any existing file is a conflict
      conflicts.push({
        path: filePath,
        reason: 'file-exists-no-manifest',
        existingChecksum: await hashFile(fullPath),
      });
      continue;
    }

    const fileEntry = manifest.files?.[filePath];
    const ownership = fileEntry?.ownership;

    if (ownership === 'user-owned') {
      // Never overwrite user-owned files
      conflicts.push({ path: filePath, reason: 'user-owned' });
    } else if (ownership === 'installer-owned') {
      const existingChecksum = await hashFile(fullPath);
      const manifestChecksum = fileEntry?.checksum;

      if (existingChecksum !== manifestChecksum) {
        // File was locally modified since last install
        conflicts.push({
          path: filePath,
          reason: 'locally-modified',
          existingChecksum,
          manifestChecksum,
        });
      }
      // Checksums match: safe to overwrite, no conflict
    } else {
      // File exists but has no manifest entry — treat as conflict
      conflicts.push({
        path: filePath,
        reason: 'file-exists-no-manifest',
        existingChecksum: await hashFile(fullPath),
      });
    }
  }

  return conflicts;
}

// ── Phase 3: Conflict confirmation ────────────────────────────────────────────

/**
 * Resolve conflicts and return the approved write map.
 * Returns null if the caller should abort (exit was called or user cancelled).
 *
 * Modes (driven by plan.yes and plan.force):
 *   yes=false            → interactive: prompt per conflicting file
 *   yes=true, force=true → non-interactive force: overwrite installer-owned, skip user-owned
 *   yes=true, force=false → non-interactive: print conflicts and exit non-zero
 *
 * @param {object} plan - has .targetDir, .force, .yes
 * @param {Array} conflicts - from detectConflicts()
 * @param {Map<string,string>} writeMap
 * @param {object} [opts]
 * @param {object}   [opts.prompts] - injectable { select, isCancel } (for testing)
 * @param {Function} [opts.exit]    - injectable process.exit (for testing)
 * @param {Function} [opts.log]     - injectable console.log (for testing)
 * @returns {Promise<Map<string,string>|null>}
 */
export async function confirmConflicts(plan, conflicts, writeMap, opts = {}) {
  const log = opts.log ?? console.log;
  const exit = opts.exit ?? process.exit;

  // No conflicts: all files are approved
  if (conflicts.length === 0) {
    return new Map(writeMap);
  }

  const force = plan.force ?? false;
  const yes = plan.yes ?? false;

  if (!yes) {
    // Interactive mode: prompt per conflicting file
    let promptSelect, promptIsCancel;
    if (opts.prompts) {
      promptSelect = opts.prompts.select;
      promptIsCancel = opts.prompts.isCancel;
    } else {
      const clack = await import('@clack/prompts');
      promptSelect = clack.select;
      promptIsCancel = clack.isCancel;
    }

    const conflictPaths = new Set(conflicts.map((c) => c.path));
    const approved = new Map();

    for (const [filePath, content] of writeMap) {
      if (!conflictPaths.has(filePath)) {
        approved.set(filePath, content);
        continue;
      }

      const conflict = conflicts.find((c) => c.path === filePath);
      const reasonLabel =
        conflict.reason === 'user-owned'
          ? 'user-owned file'
          : conflict.reason === 'locally-modified'
            ? 'locally modified'
            : 'existing file (no manifest)';

      const choice = await promptSelect({
        message: `${filePath} — ${reasonLabel}. What should we do?`,
        options: [
          { value: 'keep', label: 'Keep mine', hint: 'Skip this file' },
          { value: 'take', label: 'Take new', hint: 'Overwrite with installer version' },
          { value: 'backup', label: 'Back up and take new', hint: 'Rename existing, then write new' },
        ],
      });

      if (promptIsCancel(choice)) {
        log('Installation cancelled.');
        exit(0);
        return null;
      }

      if (choice === 'take') {
        approved.set(filePath, content);
      } else if (choice === 'backup') {
        const fullPath = path.join(plan.targetDir, filePath);
        const backupPath = `${fullPath}.bak`;
        try {
          await fs.rename(fullPath, backupPath);
          log(`  Backed up: ${filePath} → ${path.basename(backupPath)}`);
        } catch (err) {
          log(`  Warning: could not back up ${filePath}: ${err.message}`);
        }
        approved.set(filePath, content);
      }
      // 'keep': don't add to approved
    }

    return approved;
  }

  // Non-interactive modes below (yes=true)

  if (force) {
    // Non-interactive + force: overwrite installer-owned, skip user-owned
    const userOwnedPaths = new Set(
      conflicts.filter((c) => c.reason === 'user-owned').map((c) => c.path),
    );

    const approved = new Map();
    for (const [filePath, content] of writeMap) {
      if (userOwnedPaths.has(filePath)) {
        log(`  Skipping user-owned file: ${filePath}`);
        continue;
      }
      approved.set(filePath, content);
    }
    return approved;
  }

  // Non-interactive without force: print conflicts and exit non-zero
  log('\nConflicts detected — cannot proceed without --force:');
  for (const c of conflicts) {
    log(`  ${c.path}: ${c.reason}`);
  }
  log('\nRe-run with --force to overwrite installer-owned files (user-owned files are always preserved).');
  exit(1);
  return null; // For testability when exit() is mocked
}

// ── Phase 4: Write to disk ────────────────────────────────────────────────────

/**
 * Write all approved files to the target directory.
 * Uses atomic temp-file + rename. Rolls back written files on error.
 *
 * @param {string} targetPath
 * @param {Map<string,string>} approvedMap
 * @returns {Promise<string[]>} list of relative paths actually written
 */
export async function executeWrite(targetPath, approvedMap) {
  const written = [];

  try {
    for (const [filePath, content] of approvedMap) {
      const fullPath = path.join(targetPath, filePath);
      const dir = path.dirname(fullPath);

      await fs.mkdir(dir, { recursive: true });

      // Normalize line endings to LF before writing
      const normalized = content.replace(/\r\n/g, '\n');

      // Atomic write: temp file → rename
      const tmpPath = `${fullPath}.ralph-tmp`;
      await fs.writeFile(tmpPath, normalized, 'utf8');
      await fs.rename(tmpPath, fullPath);

      // Shell scripts must be directly runnable (e.g. ./scripts/ralph-watch.sh).
      if (filePath.endsWith('.sh')) {
        await fs.chmod(fullPath, 0o755);
      }

      written.push(filePath);
    }
  } catch (err) {
    // Rollback: delete files written in this session
    // (We don't restore originals; a re-run will re-detect and re-prompt.)
    for (const filePath of written) {
      await fs.unlink(path.join(targetPath, filePath)).catch(() => {});
    }
    // Clean up any leftover temp file
    throw err;
  }

  return written;
}

// ── Phase 5: Write manifest ───────────────────────────────────────────────────

/**
 * Given the relative file paths about to be written, return the subset of their
 * ancestor directories that do NOT yet exist under targetPath — i.e. the dirs
 * this install will actually create. Must be called BEFORE executeWrite (which
 * does the mkdir). Recording only these lets uninstall prune "only those the
 * installer created" and never a directory the user made pre-install.
 *
 * @param {string} targetPath
 * @param {string[]} relPaths - relative file paths to be written
 * @returns {Promise<string[]>} relative dir paths (forward slashes) not yet present
 */
export async function computeCreatedDirs(targetPath, relPaths) {
  const candidates = new Set();
  for (const relPath of relPaths) {
    let dir = path.posix.dirname(relPath.replace(/\\/g, '/'));
    while (dir && dir !== '.' && dir !== '/') {
      candidates.add(dir);
      dir = path.posix.dirname(dir);
    }
  }

  const created = [];
  for (const relDir of candidates) {
    try {
      await fs.access(path.join(targetPath, relDir));
      // Already exists → pre-existing, not installer-created. Skip.
    } catch {
      created.push(relDir);
    }
  }
  return created;
}

async function getInstallerVersion() {
  try {
    const pkgPath = path.join(__dirname, '..', 'package.json');
    const content = await fs.readFile(pkgPath, 'utf8');
    return JSON.parse(content).version;
  } catch {
    return '0.0.0';
  }
}

/**
 * Write .ralph/manifest.json recording all written files with checksums and ownership.
 *
 * @param {object} plan - has .targetDir, .classification, .wizardAnswers
 * @param {string[]} writtenFiles - relative paths of files written in Phase 4
 * @param {object|null} [existingManifest] - prior manifest (for update scenarios)
 * @param {string[]} [createdDirs] - dirs THIS install created (persisted so uninstall
 *   prunes only installer-created dirs); merged with any prior record.
 * @returns {Promise<object>} the written manifest object
 */
export async function writeManifest(plan, writtenFiles, existingManifest = null, createdDirs = []) {
  const targetPath = plan.targetDir;
  const version = await getInstallerVersion();
  const now = new Date().toISOString();

  // Compute checksums for every written file
  const files = {};
  for (const filePath of writtenFiles) {
    const fullPath = path.join(targetPath, filePath);
    let checksum = null;
    try {
      checksum = await hashFile(fullPath);
    } catch {
      // File may have been cleaned up; leave checksum null
    }

    files[filePath] = {
      ownership: getOwnership(filePath),
      checksum,
      path: filePath,
    };
  }

  // Union prior + newly-created dirs so a re-install over an existing tree keeps
  // the original record (dirs the first install created but that now pre-exist).
  const mergedCreatedDirs = [
    ...new Set([...(existingManifest?.createdDirs ?? []), ...createdDirs]),
  ];

  const manifest = {
    version,
    installedAt: existingManifest?.installedAt ?? now,
    updatedAt: now,
    files,
    createdDirs: mergedCreatedDirs,
    wizardAnswers: plan.wizardAnswers ?? {},
    targetClass: plan.classification ?? 'empty',
    installedVersion: existingManifest?.version ?? null,
  };

  const ralphDir = path.join(targetPath, '.ralph');
  await fs.mkdir(ralphDir, { recursive: true });

  const manifestPath = path.join(ralphDir, 'manifest.json');
  const manifestContent = JSON.stringify(manifest, null, 2) + '\n';

  // Atomic write
  const tmpPath = `${manifestPath}.ralph-tmp`;
  await fs.writeFile(tmpPath, manifestContent, 'utf8');
  await fs.rename(tmpPath, manifestPath);

  return manifest;
}

// ── Update mode ───────────────────────────────────────────────────────────────

/**
 * Rewrite .ralph/manifest.json after an update run.
 * Preserves user-owned entries, wizardAnswers, installedAt, and targetClass from the
 * existing manifest. Updates `version`, `updatedAt`, and checksums only for files
 * that were actually written to disk.
 *
 * Files where the user chose "keep" are NOT included in writtenFiles, so their
 * manifest checksum stays as the prior installer checksum — this ensures the next
 * update run still detects them as locally modified and prompts again.
 *
 * @param {string} targetDir
 * @param {object} plan - update plan (used to supply wizardAnswers fallback)
 * @param {string[]} writtenFiles - relative paths actually written in this update
 * @returns {Promise<object>} the updated manifest
 */
async function writeUpdateManifest(targetDir, plan, writtenFiles) {
  const existingManifest = await loadManifest(targetDir);
  const version = await getInstallerVersion();
  const now = new Date().toISOString();

  // Start from existing file entries; only update checksums for files we wrote.
  const files = { ...(existingManifest?.files ?? {}) };

  for (const filePath of writtenFiles) {
    const fullPath = path.join(targetDir, filePath);
    let checksum = null;
    try {
      checksum = await hashFile(fullPath);
    } catch {
      // File may have been cleaned up; leave checksum null
    }
    const existingEntry = files[filePath];
    files[filePath] = {
      ownership: existingEntry?.ownership ?? getOwnership(filePath),
      checksum,
      path: filePath,
    };
  }

  const updatedManifest = {
    ...(existingManifest ?? {}),
    version,
    updatedAt: now,
    files,
    wizardAnswers: existingManifest?.wizardAnswers ?? plan.wizardAnswers ?? {},
  };

  const ralphDir = path.join(targetDir, '.ralph');
  await fs.mkdir(ralphDir, { recursive: true });

  const manifestPath = path.join(ralphDir, 'manifest.json');
  const manifestContent = JSON.stringify(updatedManifest, null, 2) + '\n';

  const tmpPath = `${manifestPath}.ralph-tmp`;
  await fs.writeFile(tmpPath, manifestContent, 'utf8');
  await fs.rename(tmpPath, manifestPath);

  return updatedManifest;
}

/**
 * Execute an update run: write only installer-owned files, applying conflict decisions.
 * User-owned files are never touched (enforced by ownership check).
 *
 * For each file in the write map:
 *   - user-owned          → skip always
 *   - installer-owned, not locally modified → write new version
 *   - installer-owned, locally modified:
 *       decision "keep"   → skip (manifest checksum preserved as prior value)
 *       decision "take"   → overwrite with new version
 *       decision "backup" → rename existing to <path>.backup, write new version
 *
 * After writing, rewrites .ralph/manifest.json with updated checksums.
 *
 * @param {string} targetDir
 * @param {object} installPlan - plan reconstructed from manifest.wizardAnswers
 * @param {object} delta       - from detectUpdate().delta
 * @param {{[path: string]: 'keep'|'take'|'backup'}} conflictDecisions
 * @param {object} [opts]
 * @param {Function} [opts.log]
 * @returns {Promise<{writtenFiles: string[], backedUpFiles: string[]}>}
 */
export async function executeUpdate(targetDir, installPlan, delta, conflictDecisions, opts = {}) {
  const log = opts.log ?? console.log;

  const writeMap = await buildWriteMap(installPlan);

  // Index modified files by path for O(1) lookup
  const modifiedByPath = new Map(
    delta.installerOwned.filter((e) => e.isModified).map((e) => [e.path, e]),
  );

  const filesToWrite = new Map();
  const backedUpFiles = [];

  for (const [filePath, newContent] of writeMap) {
    if (getOwnership(filePath) === 'user-owned') {
      continue; // never write user-owned files in update mode
    }

    const conflictEntry = modifiedByPath.get(filePath);

    if (conflictEntry) {
      const decision = conflictDecisions[filePath] ?? 'take';

      if (decision === 'keep') {
        log(`  Keeping (user-modified): ${filePath}`);
        continue;
      }

      if (decision === 'backup') {
        const fullPath = path.join(targetDir, filePath);
        const backupPath = `${fullPath}.backup`;
        try {
          // Warn if a backup already exists (it will be overwritten)
          try {
            await fs.access(backupPath);
            log(`  Warning: overwriting existing backup: ${filePath}.backup`);
          } catch {
            // No existing backup — proceed normally
          }
          await fs.rename(fullPath, backupPath);
          backedUpFiles.push(filePath);
          log(`  Backed up: ${filePath} → ${path.basename(backupPath)}`);
        } catch (err) {
          log(`  Warning: could not back up ${filePath}: ${err.message}`);
        }
      }

      // 'take' or 'backup': write the new file
      filesToWrite.set(filePath, newContent);
    } else {
      // No conflict (unmodified installer-owned file or new file not in prior manifest)
      filesToWrite.set(filePath, newContent);
    }
  }

  const writtenFiles = await executeWrite(targetDir, filesToWrite);
  log(`Updated ${writtenFiles.length} file(s).`);

  await writeUpdateManifest(targetDir, installPlan, writtenFiles);

  return { writtenFiles, backedUpFiles };
}

// ── Main entry point ──────────────────────────────────────────────────────────

/**
 * Execute a complete install based on the plan from runWizard().
 *
 * Phases:
 *   1. Build write map (render templates + populate file list)
 *   2. Detect conflicts against filesystem + existing manifest
 *   3. Confirm conflicts with user (or exit if non-interactive and blocked)
 *   4. Write approved files to disk (atomic, with rollback)
 *   5. Write .ralph/manifest.json
 *
 * @param {object} plan - InstallPlan from runWizard(), plus optional .force / .yes flags
 * @param {object} [opts] - injectable dependencies (for testing)
 * @param {object}   [opts.prompts]      - injectable { select, isCancel }
 * @param {Function} [opts.exit]         - injectable process.exit
 * @param {Function} [opts.log]          - injectable console.log
 * @param {Function} [opts.installBmad]  - injectable installBmad (for testing; defaults to real installBmad)
 * @returns {Promise<{status:'success'|'cancelled', filesWritten:number, manifest:object|null}>}
 */
export async function writeInstall(plan, opts = {}) {
  const log = opts.log ?? console.log;
  const installBmadFn = opts.installBmad ?? installBmad;

  log('Building write map...');
  const writeMap = await buildWriteMap(plan);

  log('Checking for conflicts...');
  const conflicts = await detectConflicts(plan, writeMap);

  const approvedMap = await confirmConflicts(plan, conflicts, writeMap, opts);

  if (!approvedMap) {
    return { status: 'cancelled', filesWritten: 0, manifest: null };
  }

  log(`Writing ${approvedMap.size} file(s)...`);
  // Snapshot which ancestor dirs don't yet exist BEFORE writing, so the manifest
  // records only the dirs this install creates (uninstall prunes only those).
  const createdDirs = await computeCreatedDirs(plan.targetDir, [...approvedMap.keys()]);
  const writtenFiles = await executeWrite(plan.targetDir, approvedMap);
  log(`Wrote ${writtenFiles.length} file(s).`);

  const existingManifest = await loadManifest(plan.targetDir);
  const manifest = await writeManifest(plan, writtenFiles, existingManifest, createdDirs);

  log('Installation complete.');

  // Run BMAD install step if the plan opts in (skipBmad === false is explicit opt-in;
  // undefined means old/test code path that did not collect this preference).
  // The BMAD step is best-effort: a failure never aborts the install, but it MUST be
  // surfaced honestly (the outro banner degrades to "1 step needing attention").
  let bmadFailed = false;
  if (plan.skipBmad === false) {
    const bmadResult = await installBmadFn({ isTTY: process.stdout.isTTY, log });
    bmadFailed = bmadResult?.success === false;
  }

  return { status: 'success', filesWritten: writtenFiles.length, manifest, bmadFailed };
}
