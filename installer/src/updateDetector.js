import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { hashFile } from './writer.js';
import { loadManifest, ManifestError } from './manifest.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function readInstallerVersion() {
  try {
    const pkgPath = path.join(__dirname, '..', 'package.json');
    const raw = await fs.readFile(pkgPath, 'utf8');
    return JSON.parse(raw).version ?? '0.0.0';
  } catch {
    return '0.0.0';
  }
}

/**
 * Detect whether a target directory has an existing Ralph Loop install and compute the
 * update delta: which files are installer-owned vs user-owned, which have been locally
 * modified since the last install, and which are missing from disk.
 *
 * Returns `{ isUpdate: false }` when no manifest is present. A present-but-corrupted
 * manifest throws a ManifestError (code 'corrupted') so callers report it honestly
 * instead of silently downgrading to "already up to date".
 *
 * `upToDate` is true when the installed version equals the available version AND no
 * installer-owned file has drifted AND nothing is missing — the honest no-op state.
 *
 * @param {string} targetDir - absolute path to the target directory
 * @param {object} [opts]
 * @param {Function} [opts.getInstallerVersion] - override installer version lookup (for tests)
 * @param {Function} [opts.log]                 - override console.warn (for tests)
 * @returns {Promise<{
 *   isUpdate: boolean,
 *   upToDate?: boolean,
 *   installedVersion?: string,
 *   availableVersion?: string,
 *   manifest?: object,
 *   delta?: {
 *     installerOwned: Array<{path: string, checksum: string|null, currentChecksum: string, isModified: boolean}>,
 *     userOwned:     Array<{path: string, checksum: string|null, currentChecksum: string}>,
 *     missing:       string[]
 *   }
 * }>}
 */
export async function detectUpdate(targetDir, opts = {}) {
  const getVersion = opts.getInstallerVersion ?? readInstallerVersion;
  const warn = opts.log ?? console.warn;

  let manifest;
  try {
    manifest = await loadManifest(targetDir);
  } catch (err) {
    if (err instanceof ManifestError && err.code === 'not-found') {
      return { isUpdate: false };
    }
    // 'corrupted' (and any unexpected error) propagates so the caller can report it.
    throw err;
  }

  const rawVersion = manifest.version;
  if (!rawVersion) {
    warn('Old manifest format; treating as v0.0.0');
  }

  const installedVersion = rawVersion ?? '0.0.0';
  const availableVersion = await getVersion();

  const installerOwned = [];
  const userOwned = [];
  const missing = [];

  for (const [filePath, entry] of Object.entries(manifest.files ?? {})) {
    if (!entry || typeof entry !== 'object') continue;

    const fullPath = path.join(targetDir, filePath);
    let currentChecksum;

    try {
      currentChecksum = await hashFile(fullPath);
    } catch {
      missing.push(filePath);
      continue;
    }

    const storedChecksum = entry.checksum ?? null;
    const isModified = currentChecksum !== storedChecksum;

    if (entry.ownership === 'installer-owned') {
      installerOwned.push({ path: filePath, checksum: storedChecksum, currentChecksum, isModified });
    } else {
      userOwned.push({ path: filePath, checksum: storedChecksum, currentChecksum });
    }
  }

  const anyDrifted = installerOwned.some((e) => e.isModified);
  const upToDate =
    installedVersion === availableVersion && !anyDrifted && missing.length === 0;

  return {
    isUpdate: true,
    upToDate,
    installedVersion,
    availableVersion,
    manifest,
    delta: { installerOwned, userOwned, missing },
  };
}
