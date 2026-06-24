import { execSync } from 'node:child_process';
import pc from 'picocolors';

function makeCommandChecker(platform) {
  const finder = platform === 'win32' ? 'where' : 'which';
  return function commandExists(cmd) {
    try {
      execSync(`${finder} ${cmd}`, { stdio: 'pipe' });
      return true;
    } catch {
      return false;
    }
  };
}

/**
 * Run preflight environment checks.
 *
 * @param {object} [opts]
 * @param {string}   [opts.nodeVersion]   - override process.version (for testing)
 * @param {string}   [opts.platform]      - override process.platform (for testing)
 * @param {function} [opts.commandExists] - (cmd: string) => boolean (for testing)
 * @returns {Promise<{node, git, jq, claude, bash}>}
 *
 * Caller responsibility for exit codes:
 *   results.node.status === 'fail'  → exit(1)
 *   results.bash.status === 'fail'  → exit(2)
 * This function never calls process.exit() directly.
 */
export async function preflight(opts = {}) {
  const nodeVersion = opts.nodeVersion ?? process.version;
  const platform = opts.platform ?? process.platform;
  const commandExists = opts.commandExists ?? makeCommandChecker(platform);

  const rawVersion = nodeVersion.startsWith('v') ? nodeVersion.slice(1) : nodeVersion;
  const major = parseInt(rawVersion.split('.')[0], 10);
  const node =
    major >= 20
      ? { status: 'pass', version: rawVersion, message: `Node.js v${rawVersion} found` }
      : {
          status: 'fail',
          version: rawVersion,
          message: `Node.js v${rawVersion} is too old (requires >= 20). Download at https://nodejs.org/download`,
        };

  const git = commandExists('git')
    ? { status: 'pass', message: 'git found' }
    : {
        status: 'warn',
        message:
          'git not found. Install: apt install git (Debian/Ubuntu), brew install git (macOS), or visit https://git-scm.com/download',
      };

  const jq = commandExists('jq')
    ? { status: 'pass', message: 'jq found' }
    : {
        status: 'warn',
        message: [
          'jq not found.',
          '  Debian/Ubuntu: apt install jq',
          '  macOS: brew install jq',
          '  Windows (Chocolatey): choco install jq',
          '  Windows (winget): winget install jqlang.jq',
        ].join('\n'),
      };

  const claude = commandExists('claude')
    ? { status: 'pass', message: "'claude' CLI found" }
    : {
        status: 'warn',
        message:
          "'claude' CLI not found. Install: npm install -g @anthropic-ai/claude-code or https://github.com/anthropics/claude-code",
      };

  let bash;
  if (platform === 'win32') {
    bash = commandExists('bash')
      ? { status: 'pass', message: 'bash environment detected' }
      : {
          status: 'fail',
          message: [
            'bash not found. The Ralph Loop requires a bash environment.',
            'On Windows, install WSL2: https://docs.microsoft.com/windows/wsl/install',
            'Alternatively, install Git Bash: https://git-scm.com/download/win',
          ].join('\n'),
        };
  } else {
    bash = { status: 'pass', message: 'bash environment detected' };
  }

  return { node, git, jq, claude, bash };
}

/**
 * Render a preflight results object as a checklist to stdout.
 *
 * @param {object} results - return value from preflight()
 * @param {object} [opts]
 * @param {boolean}  [opts.isTTY]    - override process.stdout.isTTY (for testing)
 * @param {boolean}  [opts.noColor]  - override NO_COLOR env var (for testing)
 * @param {function} [opts.writeFn]  - (s: string) => void (for testing)
 */
export function renderChecklist(results, opts = {}) {
  const isTTY = opts.isTTY ?? !!process.stdout.isTTY;
  const noColor = opts.noColor ?? !!process.env.NO_COLOR;
  const write = opts.writeFn ?? ((s) => process.stdout.write(s));

  if (isTTY) {
    renderTTY(results, write, noColor);
  } else {
    renderPlain(results, write);
  }
}

function statusGlyph(status) {
  if (status === 'pass') return '✓';
  if (status === 'warn') return '⚠';
  return '✗';
}

function renderTTY(results, write, noColor) {
  function colorize(status, text) {
    if (noColor) return text;
    if (status === 'pass') return pc.green(text);
    if (status === 'warn') return pc.yellow(text);
    return pc.red(text);
  }

  const { node, git, jq, claude, bash } = results;
  const entries = [
    { result: node, label: `Node.js v${node.version}` },
    { result: git, label: git.message.split('\n')[0] },
    { result: jq, label: jq.message.split('\n')[0] },
    { result: claude, label: claude.message.split('\n')[0] },
    { result: bash, label: bash.message.split('\n')[0] },
  ];

  for (const { result, label } of entries) {
    const g = statusGlyph(result.status);
    write(colorize(result.status, `${g} ${label}`) + '\n');
  }
}

function renderPlain(results, write) {
  const { node, git, jq, claude, bash } = results;
  write(`NODE_VERSION: ${node.version} (${node.status})\n`);
  write(`GIT: ${git.status} – ${git.message.split('\n')[0]}\n`);
  write(`JQ: ${jq.status} – ${jq.message.split('\n')[0]}\n`);
  write(`CLAUDE: ${claude.status} – ${claude.message.split('\n')[0]}\n`);
  write(`BASH: ${bash.status} – ${bash.message.split('\n')[0]}\n`);
}
