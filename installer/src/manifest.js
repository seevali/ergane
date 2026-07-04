import { promises as fs } from 'node:fs';
import path from 'node:path';

/**
 * The single shared manifest loader for every Ralph Loop subcommand
 * (install / update / uninstall / doctor). One loader, one honest error, so a
 * corrupted or missing `.ralph/manifest.json` is reported identically everywhere.
 */

export const MANIFEST_REL_PATH = '.ralph/manifest.json';

export const MANIFEST_NOT_FOUND_MESSAGE =
  'no Ralph Loop installation found here (looked for .ralph/manifest.json)';

export const MANIFEST_CORRUPTED_MESSAGE =
  'manifest is corrupted — re-run install to repair; your project files are untouched';

/**
 * Thrown by loadManifest(). `code` is 'not-found' (never installed here) or
 * 'corrupted' (file present but unreadable/malformed/structurally invalid).
 */
export class ManifestError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ManifestError';
    this.code = code;
  }
}

/** Absolute path to the manifest for a target directory. */
export function manifestPathFor(targetDir) {
  return path.join(targetDir, '.ralph', 'manifest.json');
}

/**
 * Load and validate `.ralph/manifest.json` for a target directory.
 *
 * @param {string} targetDir - directory that may contain a Ralph install
 * @returns {Promise<object>} the parsed manifest (guaranteed to have a `files` object)
 * @throws {ManifestError} code 'not-found' when the file is absent,
 *                         code 'corrupted' when present but malformed/invalid.
 */
export async function loadManifest(targetDir) {
  const manifestPath = manifestPathFor(targetDir);

  let raw;
  try {
    raw = await fs.readFile(manifestPath, 'utf8');
  } catch (err) {
    if (err && err.code === 'ENOENT') {
      throw new ManifestError('not-found', MANIFEST_NOT_FOUND_MESSAGE);
    }
    throw err;
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new ManifestError('corrupted', MANIFEST_CORRUPTED_MESSAGE);
  }

  if (!parsed || typeof parsed !== 'object' || typeof parsed.files !== 'object' || parsed.files === null) {
    throw new ManifestError('corrupted', MANIFEST_CORRUPTED_MESSAGE);
  }

  return parsed;
}

/**
 * Non-throwing wrapper: returns `{ manifest }` on success or `{ error }` with a
 * ManifestError. Handy for callers that want to branch on 'not-found' vs
 * 'corrupted' without a try/catch.
 *
 * @param {string} targetDir
 * @returns {Promise<{ manifest: object } | { error: ManifestError }>}
 */
export async function tryLoadManifest(targetDir) {
  try {
    return { manifest: await loadManifest(targetDir) };
  } catch (err) {
    if (err instanceof ManifestError) return { error: err };
    throw err;
  }
}

/**
 * File paths that signal a Ralph Loop install even without a manifest — used to
 * detect the "orphaned install" state (loop files present, manifest missing),
 * which is what an interrupted install leaves behind.
 */
export const LOOP_FILE_MARKERS = [
  'scripts/ralph-loop.sh',
  'scripts/ralph-watch.sh',
  'docs/project-conventions.md',
];

/**
 * Detect whether a directory contains loop files despite a missing manifest.
 * @param {string} targetDir
 * @returns {Promise<boolean>}
 */
export async function hasOrphanedLoopFiles(targetDir) {
  for (const rel of LOOP_FILE_MARKERS) {
    try {
      await fs.access(path.join(targetDir, rel));
      return true;
    } catch {
      // keep looking
    }
  }
  return false;
}
