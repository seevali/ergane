/**
 * Domain-specific assertions for the Ergane installer E2E test suite.
 *
 * Each function throws a descriptive Error on failure, compatible with
 * node:assert/strict-style testing. On success, functions return undefined.
 */
import { promises as fs } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

/**
 * Compute SHA256 of a file's content, normalizing CRLF → LF before hashing.
 * Matches the algorithm used by the installer's writer.js, so checksums
 * returned here are directly comparable to manifest checksums.
 *
 * @param {string} filePath - absolute path
 * @returns {Promise<string>} "sha256:<hex>"
 */
export async function sha256File(filePath) {
  const content = await fs.readFile(filePath, 'utf8');
  const normalized = content.replace(/\r\n/g, '\n');
  return 'sha256:' + crypto.createHash('sha256').update(normalized).digest('hex');
}

/**
 * Assert all FR-6 required files and directories are present in the installed directory.
 *
 * FR-6 is the installer's functional requirement for what a complete install produces:
 *   - scripts/ralph-loop.sh          (loop execution script)
 *   - scripts/prompts/               (at least one file inside)
 *   - docs/project-conventions.md   (always written, installer-owned)
 *   - docs/epics/                    (directory with scaffold stubs)
 *   - GETTING-STARTED.md            (always written, user-owned)
 *   - .gitignore                    (written when addGitignoreEntries=true, the default)
 *   - .ralph/manifest.json          (always written)
 *
 * @param {string} dir - absolute path to the installed target directory
 */
export async function assertFR6FilesPresent(dir) {
  const requiredFiles = [
    'scripts/ralph-loop.sh',
    'docs/project-conventions.md',
    'GETTING-STARTED.md',
    '.gitignore',
    '.ralph/manifest.json',
  ];

  const requiredDirs = [
    'scripts/prompts',
    'docs/epics',
  ];

  for (const rel of requiredFiles) {
    const fullPath = path.join(dir, rel);
    try {
      await fs.access(fullPath);
    } catch {
      throw new Error(`FR-6 file missing: ${rel}\n  expected at: ${fullPath}`);
    }
  }

  for (const rel of requiredDirs) {
    const fullPath = path.join(dir, rel);
    let stat;
    try {
      stat = await fs.stat(fullPath);
    } catch {
      throw new Error(`FR-6 directory missing: ${rel}\n  expected at: ${fullPath}`);
    }
    if (!stat.isDirectory()) {
      throw new Error(`FR-6 path exists but is not a directory: ${rel}`);
    }
  }

  // scripts/prompts must contain at least one file (not just the directory)
  const promptEntries = await fs.readdir(path.join(dir, 'scripts', 'prompts'));
  if (promptEntries.length === 0) {
    throw new Error(
      'scripts/prompts/ exists but is empty — expected prompt subdirectories',
    );
  }
}

/**
 * Assert that all Markdown files in docs/epics/ contain valid story headers.
 *
 * The loop parser expects headers in the format: ### Story X.Y: Title
 * where X and Y are one-or-more digit numbers (e.g. ### Story 1.1: App Shell).
 *
 * @param {string} dir - absolute path to the installed target directory
 */
export async function assertEpicStubsParseable(dir) {
  const epicsDir = path.join(dir, 'docs', 'epics');

  let files;
  try {
    files = await fs.readdir(epicsDir);
  } catch (err) {
    if (err.code === 'ENOENT') {
      throw new Error('docs/epics/ directory not found');
    }
    throw err;
  }

  // Skip PRD stubs (*-prd.md) — they are project requirements docs, not epic files.
  // Epic files (e.g. *-stories.md) are the ones the loop parser reads for story headers.
  const mdFiles = files.filter((f) => f.endsWith('.md') && !f.endsWith('-prd.md'));
  if (mdFiles.length === 0) {
    throw new Error('docs/epics/ contains no epic .md files — expected scaffold stubs');
  }

  // Regex matches the canonical story header format used by the loop parser
  const storyHeaderRe = /^###\s+Story\s+\d+\.\d+:\s+.+/m;

  for (const file of mdFiles) {
    const filePath = path.join(epicsDir, file);
    const content = await fs.readFile(filePath, 'utf8');

    if (!storyHeaderRe.test(content)) {
      throw new Error(
        `Epic file "${file}" has no parseable "### Story X.Y: Title" headers\n` +
        `  file: ${filePath}`,
      );
    }
  }
}

/**
 * Assert that .ralph/manifest.json is structurally valid and all installer-owned
 * file checksums match the files currently on disk.
 *
 * Checks:
 *   1. JSON is readable and parseable
 *   2. Required top-level fields: version, installedAt, files, wizardAnswers
 *   3. Each file entry has: ownership, checksum, path
 *   4. Installer-owned file checksums match actual files on disk
 *
 * @param {string} dir - absolute path to the installed target directory
 */
export async function assertManifestValid(dir) {
  const manifestPath = path.join(dir, '.ralph', 'manifest.json');

  let manifest;
  try {
    const raw = await fs.readFile(manifestPath, 'utf8');
    manifest = JSON.parse(raw);
  } catch (err) {
    throw new Error(`Manifest unreadable or invalid JSON: ${err.message}\n  path: ${manifestPath}`);
  }

  if (typeof manifest.version !== 'string') {
    throw new Error('Manifest missing required field: version (string)');
  }
  if (typeof manifest.installedAt !== 'string') {
    throw new Error('Manifest missing required field: installedAt (string)');
  }
  if (typeof manifest.files !== 'object' || manifest.files === null) {
    throw new Error('Manifest missing required field: files (object)');
  }
  if (typeof manifest.wizardAnswers !== 'object') {
    throw new Error('Manifest missing required field: wizardAnswers (object)');
  }

  for (const [relPath, entry] of Object.entries(manifest.files)) {
    if (!entry.ownership || !entry.checksum || !entry.path) {
      throw new Error(
        `Manifest entry "${relPath}" missing required fields (ownership, checksum, path)`,
      );
    }

    if (entry.ownership === 'installer-owned') {
      const fullPath = path.join(dir, relPath);
      let actualChecksum;
      try {
        actualChecksum = await sha256File(fullPath);
      } catch {
        throw new Error(
          `Manifest references file that cannot be read: ${relPath}\n  path: ${fullPath}`,
        );
      }

      if (actualChecksum !== entry.checksum) {
        throw new Error(
          `Checksum mismatch for installer-owned file: ${relPath}\n` +
          `  manifest: ${entry.checksum}\n` +
          `  actual:   ${actualChecksum}`,
        );
      }
    }
  }
}

/**
 * Assert that a string contains no ANSI escape codes.
 * Checks for CSI sequences (\x1b[) and OSC sequences (\x1b]).
 *
 * @param {string} text - captured stdout or stderr to inspect
 */
export function assertNoANSIEscapes(text) {
  // Match ESC followed by [ or ] (the most common ANSI escape starters)
  const ansiRe = /\x1b[\x5b\x5d]|[\x5b\x5d]/;
  if (ansiRe.test(text)) {
    const found = text.match(/\x1b[^m]*m/g) ?? [];
    throw new Error(
      'Output contains ANSI escape codes — expected plain text in non-TTY mode\n' +
      `  First matches: ${found.slice(0, 3).map((m) => JSON.stringify(m)).join(', ')}`,
    );
  }
}

/**
 * Assert that a set of files are byte-identical to their baseline checksums.
 * Used to verify that a subsequent install/update did not overwrite certain files.
 *
 * @param {string} dir - base directory (absolute)
 * @param {string[]} relPaths - file paths relative to dir
 * @param {Record<string, string>} baselineChecksums - map of relPath → "sha256:<hex>"
 */
export async function assertFilesUnchanged(dir, relPaths, baselineChecksums) {
  for (const relPath of relPaths) {
    const expected = baselineChecksums[relPath];
    if (!expected) {
      throw new Error(`No baseline checksum provided for: ${relPath}`);
    }

    const fullPath = path.join(dir, relPath);
    const actual = await sha256File(fullPath);

    if (actual !== expected) {
      throw new Error(
        `File was modified but should be preserved: ${relPath}\n` +
        `  baseline: ${expected}\n` +
        `  actual:   ${actual}`,
      );
    }
  }
}

/**
 * Assert that a directory has no files or subdirectories.
 * Non-existent directory is treated as empty.
 *
 * @param {string} dir - absolute path to check
 */
export async function assertDirEmpty(dir) {
  let entries;
  try {
    entries = await fs.readdir(dir);
  } catch (err) {
    if (err.code === 'ENOENT') return; // non-existent counts as empty
    throw err;
  }

  if (entries.length > 0) {
    throw new Error(
      `Directory is not empty: ${dir}\n  Contents: ${entries.slice(0, 8).join(', ')}`,
    );
  }
}

/**
 * Format a structured error message useful for debugging test failures.
 * @param {string} message - primary message
 * @param {Record<string, unknown>} [details] - additional context key/value pairs
 * @returns {string}
 */
export function formatError(message, details = {}) {
  const lines = [message];
  for (const [key, val] of Object.entries(details)) {
    const str = typeof val === 'object' ? JSON.stringify(val, null, 2) : String(val);
    lines.push(`  ${key}: ${str}`);
  }
  return lines.join('\n');
}
