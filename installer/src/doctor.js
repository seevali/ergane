import { promises as fs } from 'node:fs';
import path from 'node:path';
import { hashFile } from './writer.js';
import { cliInvocation } from './pkg.js';
import {
  tryLoadManifest,
  hasOrphanedLoopFiles,
  MANIFEST_CORRUPTED_MESSAGE,
} from './manifest.js';

/**
 * Installer files the outro explicitly invites the user to edit (tech stack /
 * checkpoint in project-conventions.md; agent behavior in scripts/prompts/**).
 * Drift in these is EXPECTED customization → reported as INFO, never a red FAIL that
 * can never clear. Everything else installer-owned is ralph-owned (drift = real FAIL).
 *
 * @param {string} relPath
 * @returns {boolean}
 */
export function isUserEditableInstalledFile(relPath) {
  const n = relPath.replace(/\\/g, '/');
  return n === 'docs/project-conventions.md' || n.startsWith('scripts/prompts/');
}

/**
 * Validate an existing Ergane installation.
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
 * @param {Function} [opts.checkGhAuth]  - injectable () => Promise<{authenticated: boolean}>
 * @returns {Promise<{passed: boolean, findings: Array<{check, status, message, informational?}>}>}
 */
export async function runDoctor(targetPath, opts = {}) {
  const log = opts.log ?? console.log;
  const checkCommand = opts.checkCommand ?? checkCommandAvailable;
  const checkGhAuth = opts.checkGhAuth ?? checkGhAuthStatus;

  const cli = cliInvocation();
  const findings = [];

  // Load manifest through the shared loader so corrupted vs never-installed vs
  // orphaned (loop files present, manifest gone) are reported distinctly and
  // consistently with the other subcommands.
  const loaded = await tryLoadManifest(targetPath);
  const manifest = loaded.manifest ?? null;
  if (!manifest) {
    if (loaded.error && loaded.error.code === 'corrupted') {
      findings.push({
        check: 'manifest-valid',
        status: 'fail',
        message: `${MANIFEST_CORRUPTED_MESSAGE} (remediation: ${cli} install to repair)`,
      });
    } else if (await hasOrphanedLoopFiles(targetPath)) {
      findings.push({
        check: 'manifest-exists',
        status: 'fail',
        message:
          'found loop files but no manifest (.ralph/manifest.json) — re-run install to adopt them',
      });
    } else {
      findings.push({
        check: 'manifest-exists',
        status: 'fail',
        message:
          'no Ergane installation found here (looked for .ralph/manifest.json)',
      });
    }
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
          message: `Required file missing: ${filePath} — remediation: run '${cli} install' to restore it`,
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
          // Two kinds of drift are EXPECTED customization, not failures:
          //   1. user-owned files (the PRD, epic, source the user authors/edits) —
          //      `update` structurally skips every user-owned path (writer.js
          //      executeUpdate), so a "run update to restore" remediation would be
          //      false: update will never rewrite these. The example task source
          //      explicitly invites editing them ("edit them freely; update won't
          //      clobber them"), so a drift FAIL here is unreachable-to-clear.
          //   2. installer-owned files the outro invites editing (project-conventions.md,
          //      scripts/prompts/**) — see isUserEditableInstalledFile.
          // Manifest-recorded ownership is authoritative for (1); the path allowlist
          // handles (2). Everything else installer-owned is ralph-owned (drift = FAIL).
          const userOwned = fileEntry.ownership === 'user-owned';
          if (userOwned || isUserEditableInstalledFile(filePath)) {
            // Report as INFO so doctor can still pass (it never could before —
            // permanently red on a file the user was told to customize).
            findings.push({
              check: `file-customized:${filePath}`,
              status: 'info',
              informational: true,
              message: `Customized (expected): ${filePath} — user edits here are fine`,
            });
          } else {
            findings.push({
              check: `file-checksum:${filePath}`,
              status: 'fail',
              message: `File modified: ${filePath} (manifest checksum mismatch) — remediation: run '${cli} update' to restore the shipped version`,
            });
          }
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
      message:
        'jq not found in PATH — required for loop operation. ' +
        'Remediation: install jq (macOS: `brew install jq`; Debian/Ubuntu: `sudo apt-get install jq`; see https://jqlang.github.io/jq/download/)',
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
      message:
        'claude CLI not found in PATH — required for agent orchestration. ' +
        'Remediation: install it with `npm install -g @anthropic-ai/claude-code` (see https://docs.claude.com/en/docs/claude-code)',
    });
  } else {
    findings.push({
      check: 'claude-cli-available',
      status: 'pass',
      message: `claude CLI found at ${claudeCheck.path}`,
    });
  }

  // Check 4b: scripts/ralph-watch.sh present + executable.
  // Only validated for installs that shipped it (manifest lists it). Fail-level is
  // consistent with how a missing loop script is treated (a hard fail).
  if (manifest?.files?.['scripts/ralph-watch.sh']) {
    const watchPath = path.join(targetPath, 'scripts/ralph-watch.sh');
    try {
      const stat = await fs.stat(watchPath);
      if ((stat.mode & 0o111) === 0) {
        findings.push({
          check: 'ralph-watch-executable',
          status: 'fail',
          message: 'scripts/ralph-watch.sh is present but not executable — run: chmod +x scripts/ralph-watch.sh',
        });
      } else {
        findings.push({
          check: 'ralph-watch-executable',
          status: 'pass',
          message: 'scripts/ralph-watch.sh present and executable',
        });
      }
    } catch {
      findings.push({
        check: 'ralph-watch-executable',
        status: 'fail',
        message: 'scripts/ralph-watch.sh is missing — re-run install to restore it',
      });
    }
  }

  // Check 4c: gh CLI presence + auth (INFORMATIONAL — never fails the doctor).
  // The GitHub CLI is only needed for the issue-driven workflow (--issue/--write/--issues);
  // a project that only uses the epic-file workflow never touches it.
  const ghCheck = await checkCommand('gh');
  let ghMessage;
  if (!ghCheck.found) {
    ghMessage =
      'gh CLI not found — needed only for the GitHub-issue workflow (--issue/--write/--issues). ' +
      'Install from https://cli.github.com';
  } else {
    let authed = false;
    try {
      authed = (await checkGhAuth()).authenticated === true;
    } catch {
      authed = false;
    }
    ghMessage = authed
      ? `gh CLI found at ${ghCheck.path} and authenticated — GitHub-issue workflow ready (--issue/--write/--issues)`
      : `gh CLI found at ${ghCheck.path} but not authenticated (run: gh auth login) — ` +
        'needed only for the GitHub-issue workflow (--issue/--write/--issues)';
  }
  findings.push({
    check: 'gh-available',
    status: 'pass',
    informational: true,
    message: ghMessage,
  });

  // Check 5: Epic story headers are parseable.
  // Manifest-driven so it validates whichever epic the install actually shipped —
  // the scaffold stub (docs/epics/project-stories.md) OR the worked example
  // (docs/epics/exchange-rates-dashboard.md) — instead of a hardcoded name pair that
  // would silently skip the example's epic. Convention (shared with the E2E
  // assertions): every `.md` under docs/epics/ is an epic to validate, EXCEPT
  // `*-prd.md` (requirements docs, not story lists). PRDs written outside docs/epics/
  // (e.g. the example's docs/prd.md) are not epics and are not scanned here.
  if (manifest) {
    const epicPaths = Object.keys(manifest.files ?? {}).filter((p) => {
      const n = p.replace(/\\/g, '/');
      return n.startsWith('docs/epics/') && n.endsWith('.md') && !n.endsWith('-prd.md');
    });
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

  // Only hard failures block; informational findings (e.g. the gh check) never fail.
  const passed = findings.every((f) => f.status !== 'fail');
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
    const icon = f.informational ? 'ℹ' : f.status === 'pass' ? '✓' : '✗';
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
 * Check whether `gh` is authenticated. Runs `gh auth status` locally (no network).
 * @returns {Promise<{authenticated: boolean}>}
 */
async function checkGhAuthStatus() {
  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const execFileAsync = promisify(execFile);

  try {
    await execFileAsync('gh', ['auth', 'status']);
    return { authenticated: true };
  } catch {
    return { authenticated: false };
  }
}
