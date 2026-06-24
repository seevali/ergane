import { promises as fs } from 'node:fs';
import path from 'node:path';
import { hashFile } from './writer.js';

/**
 * Validate an existing Ralph Loop installation.
 * Checks:
 *   1. All manifest-required files exist
 *   2. File checksums match manifest
 *   3. jq is available
 *   4. claude CLI is available
 *   5. Epic story headers are parseable (### Story X.Y: Title)
 *
 * @param {string} targetPath - directory to validate
 * @param {object} [opts]
 * @param {Function} [opts.log] - injectable console.log
 * @param {Function} [opts.checkCommand] - injectable (cmd) => Promise<{found, path?}>
 * @returns {Promise<{passed: boolean, findings: Array<{check, status, message}>}>}
 */
export async function runDoctor(targetPath, opts = {}) {
  const log = opts.log ?? console.log;
  const checkCommand = opts.checkCommand ?? checkCommandAvailable;

  const findings = [];

  // Load manifest (if missing, it's a finding)
  const manifest = await loadManifest(targetPath);
  if (!manifest) {
    findings.push({
      check: 'manifest-exists',
      status: 'fail',
      message: '.ralph/manifest.json not found — is this a Ralph installation?',
    });
    // Continue validation with other checks (don't bail)
  }

  // Check 1: All manifest files exist
  if (manifest) {
    for (const [filePath] of Object.entries(manifest.files ?? {})) {
      const fullPath = path.join(targetPath, filePath);
      let exists = false;
      try {
        await fs.access(fullPath);
        exists = true;
      } catch {
        // File doesn't exist
      }

      if (!exists) {
        findings.push({
          check: `file-exists:${filePath}`,
          status: 'fail',
          message: `Required file missing: ${filePath}`,
        });
      }
    }
  }

  // Check 2: File checksums match manifest
  if (manifest) {
    for (const [filePath, fileEntry] of Object.entries(manifest.files ?? {})) {
      if (!fileEntry.checksum) continue;

      const fullPath = path.join(targetPath, filePath);
      let exists = false;
      try {
        await fs.access(fullPath);
        exists = true;
      } catch {
        // Already reported above
        continue;
      }

      if (exists) {
        const actualChecksum = await hashFile(fullPath);
        if (actualChecksum !== fileEntry.checksum) {
          findings.push({
            check: `file-checksum:${filePath}`,
            status: 'fail',
            message: `File modified: ${filePath} (manifest checksum mismatch)`,
          });
        }
      }
    }
  }

  // Check 3: jq is available
  const jqCheck = await checkCommand('jq');
  if (!jqCheck.found) {
    findings.push({
      check: 'jq-available',
      status: 'fail',
      message: 'jq not found in PATH — required for loop operation',
    });
  } else {
    findings.push({
      check: 'jq-available',
      status: 'pass',
      message: `jq found at ${jqCheck.path}`,
    });
  }

  // Check 4: claude CLI is available
  const claudeCheck = await checkCommand('claude');
  if (!claudeCheck.found) {
    findings.push({
      check: 'claude-cli-available',
      status: 'fail',
      message: 'claude CLI not found in PATH — required for agent orchestration',
    });
  } else {
    findings.push({
      check: 'claude-cli-available',
      status: 'pass',
      message: `claude CLI found at ${claudeCheck.path}`,
    });
  }

  // Check 5: Epic story headers are parseable
  if (manifest) {
    const epicPaths = ['docs/epics/project-stories.md', 'docs/epics/project-prd.md'];
    for (const epicPath of epicPaths) {
      const fullPath = path.join(targetPath, epicPath);
      let content;
      try {
        content = await fs.readFile(fullPath, 'utf8');
      } catch {
        // File doesn't exist; skip
        continue;
      }

      const storyMatches = [...content.matchAll(/^###\s+Story\s+(\d+\.\d+):/gm)];
      if (storyMatches.length === 0 && content.includes('### Story')) {
        findings.push({
          check: `epic-headers:${epicPath}`,
          status: 'fail',
          message: `Story headers found but not parseable in ${epicPath}. Ensure format is: ### Story X.Y: Title`,
        });
      } else if (storyMatches.length > 0) {
        findings.push({
          check: `epic-headers:${epicPath}`,
          status: 'pass',
          message: `${storyMatches.length} story header(s) parsed correctly`,
        });
      }
    }
  }

  const isTTY = process.stdout.isTTY ?? false;
  log('\n' + renderChecklist(findings, isTTY));

  const passed = findings.every((f) => f.status === 'pass');
  return { passed, findings };
}

/**
 * Render findings as a structured checklist.
 * @param {Array<{check: string, status: string, message: string}>} findings
 * @param {boolean} [isTTY] - whether to use ANSI colors
 * @returns {string}
 */
export function renderChecklist(findings, isTTY = false) {
  let output = 'Installation validation:\n\n';

  for (const f of findings) {
    const icon = f.status === 'pass' ? '✓' : '✗';
    const color = isTTY && f.status === 'fail' ? '\x1b[31m' : '';
    const reset = isTTY ? '\x1b[0m' : '';

    output += `  ${color}${icon} ${f.message}${reset}\n`;
  }

  const failCount = findings.filter((f) => f.status === 'fail').length;
  output += '\n';

  if (failCount === 0) {
    output += 'All checks passed! ✓\n';
  } else {
    output += `${failCount} check(s) failed. Review above.\n`;
  }

  return output;
}

/**
 * Check if a command is available in PATH.
 * @param {string} command - e.g. 'jq', 'claude'
 * @returns {Promise<{found: boolean, path?: string}>}
 */
async function checkCommandAvailable(command) {
  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const execFileAsync = promisify(execFile);

  try {
    const result = await execFileAsync('which', [command]);
    return { found: true, path: result.stdout.trim() };
  } catch {
    return { found: false };
  }
}

/**
 * Load manifest from targetPath/.ralph/manifest.json.
 * @param {string} targetPath
 * @returns {Promise<object|null>}
 */
async function loadManifest(targetPath) {
  try {
    const manifestPath = path.join(targetPath, '.ralph', 'manifest.json');
    const content = await fs.readFile(manifestPath, 'utf8');
    return JSON.parse(content);
  } catch {
    return null;
  }
}
