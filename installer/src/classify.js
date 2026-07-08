import { promises as fs } from 'node:fs';
import path from 'node:path';

const FILE_SIGNALS = new Set([
  '.git', 'package.json', 'Gemfile', 'pyproject.toml', 'pom.xml',
  'go.mod', 'Cargo.toml', 'composer.json', 'pubspec.yaml',
]);

async function checkManifest(dirPath) {
  try {
    await fs.access(path.join(dirPath, '.ralph', 'manifest.json'));
    return true;
  } catch {
    return false;
  }
}

/**
 * Walk up from a target directory (excluding the target itself) looking for an
 * ancestor that already contains an Ergane install (`.ralph/manifest.json`).
 * Used to warn before creating a second, independent nested install.
 *
 * @param {string} dirPath - the target directory
 * @returns {Promise<string|null>} absolute path to the ancestor's manifest, or null
 */
export async function findAncestorInstall(dirPath) {
  let current = path.resolve(dirPath);
  let parent = path.dirname(current);

  while (parent !== current) {
    const manifestPath = path.join(parent, '.ralph', 'manifest.json');
    try {
      await fs.access(manifestPath);
      return manifestPath;
    } catch {
      // keep walking up
    }
    current = parent;
    parent = path.dirname(current);
  }
  return null;
}

/**
 * Classify a target directory for installer decision-making.
 *
 * @param {string} dirPath - path to target directory (absolute or relative)
 * @returns {Promise<{type: 'empty'|'existing-project'|'existing-install', signals: string[], hasManifest: boolean, projectRoot: string}>}
 */
export async function classifyTarget(dirPath) {
  const absolutePath = path.resolve(dirPath);

  // Resolve symlinks and verify existence simultaneously
  let projectRoot;
  try {
    projectRoot = await fs.realpath(absolutePath);
  } catch (err) {
    if (err.code === 'ENOENT') {
      throw new Error(`Target directory not found: ${absolutePath}`);
    }
    if (err.code === 'EACCES') {
      throw new Error(`Permission denied on target directory. Check permissions: chmod +rx ${absolutePath}`);
    }
    throw err;
  }

  const stat = await fs.stat(projectRoot);
  if (!stat.isDirectory()) {
    throw new Error(`Target path is not a directory: ${projectRoot}`);
  }

  let entries;
  try {
    entries = await fs.readdir(projectRoot, { withFileTypes: true });
  } catch (err) {
    if (err.code === 'EACCES') {
      throw new Error(`Cannot read target directory. Check permissions: chmod +rx ${projectRoot}`);
    }
    throw err;
  }

  const hasManifest = await checkManifest(projectRoot);

  const signals = [];
  if (hasManifest) {
    signals.push('.ralph');
  }

  for (const entry of entries) {
    const name = entry.name;
    if (FILE_SIGNALS.has(name)) {
      signals.push(name);
    } else if (name.endsWith('.sln')) {
      signals.push(name);
    }
  }

  const type =
    hasManifest ? 'existing-install'
    : signals.length > 0 ? 'existing-project'
    : 'empty';

  return { type, signals, hasManifest, projectRoot };
}
