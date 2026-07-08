/**
 * Per-question CLI flag definitions for the guided installer.
 *
 * Each entry maps a Commander option key (camelCase) to a wizard question,
 * with a default value, validation function, and description for --list-options.
 */
const FLAG_DEFINITIONS = [
  {
    key: 'appDir',
    flag: '--app-dir <path>',
    description: 'Application source directory (relative to project root)',
    defaultValue: 'src',
    validate(v) {
      const trimmed = v.trim();
      if (!trimmed) return 'App directory is required.';
      if (trimmed.startsWith('/') || trimmed.includes('..')) {
        return 'Use a relative path (e.g., src, packages/ui).';
      }
      return null;
    },
  },
  {
    key: 'checkpointCommand',
    flag: '--checkpoint-command <cmd>',
    description: 'Checkpoint command (build + test; shown in loop prompts)',
    defaultValue: 'npm run build && npm test',
    validate(v) {
      if (!v.trim()) return 'Checkpoint command is required.';
      return null;
    },
  },
  {
    key: 'stackDescription',
    flag: '--stack-description <text>',
    description: 'Stack description (tech choices, testing approach, etc.)',
    defaultValue: 'React 19 + Vite + TypeScript (strict mode)',
    validate(v) {
      if (!v.trim()) return 'Stack description is required.';
      return null;
    },
  },
  {
    key: 'useBmad',
    flag: '--use-bmad <yes|no>',
    description: 'Install BMAD method modules (core, bmm) alongside the loop',
    defaultValue: 'yes',
    validate(v) {
      if (!['yes', 'no'].includes(v)) return `Expected: yes | no, got: ${v}`;
      return null;
    },
  },
  {
    key: 'taskSource',
    flag: '--task-source <scaffold|existing|example>',
    description: 'Task source: scaffold template files, point to existing PRD/epic, or ship the worked example',
    defaultValue: 'scaffold',
    validate(v) {
      if (!['scaffold', 'existing', 'example'].includes(v)) {
        return `Expected: scaffold | existing | example, got: ${v}`;
      }
      return null;
    },
  },
  {
    key: 'skipNpmScript',
    flag: '--skip-npm-script <yes|no>',
    description: 'Skip adding npm scripts for the loop (dev-story, code-review)',
    defaultValue: 'no',
    validate(v) {
      if (!['yes', 'no'].includes(v)) return `Expected: yes | no, got: ${v}`;
      return null;
    },
  },
];

/**
 * The kebab-case CLI flag a user actually types for a given definition, derived
 * from `def.flag` by stripping the `<…>` argument placeholder. Validation errors
 * must name THIS (e.g. `--app-dir`), never the internal camelCase key (`appDir`),
 * so the text a user copies back into their shell matches a flag that parses.
 *
 * @param {object} def - a FLAG_DEFINITIONS entry
 * @returns {string} e.g. "--app-dir"
 */
export function flagNameFor(def) {
  return def.flag.split(/\s+/)[0];
}

/**
 * Extract CLI-provided answers from the Commander options object.
 * Returns an object mapping question keys to CLI-provided values.
 * Keys are omitted if the flag was not provided by the user.
 *
 * @param {object} opts - Commander command options (command.opts() or program.opts())
 * @returns {{ appDir?: string, checkpointCommand?: string, stackDescription?: string,
 *             useBmad?: string, taskSource?: string, skipNpmScript?: string }}
 */
export function parseCliArgs(opts) {
  const result = {};
  for (const def of FLAG_DEFINITIONS) {
    if (opts[def.key] !== undefined) {
      result[def.key] = opts[def.key];
    }
  }
  return result;
}

/**
 * Validate CLI-provided arguments.
 * Throws an Error if any value fails validation.
 *
 * @param {object} cliArgs - return value of parseCliArgs()
 */
export function validateCliArgs(cliArgs) {
  for (const def of FLAG_DEFINITIONS) {
    const value = cliArgs[def.key];
    if (value !== undefined && def.validate) {
      const error = def.validate(value);
      if (error) {
        throw new Error(`Invalid ${flagNameFor(def)}: ${error}`);
      }
    }
  }
}

/**
 * Returns a formatted list of all available per-question flags with defaults and descriptions.
 * Used by the --list-options flag.
 *
 * @returns {string}
 */
export function listOptions() {
  const lines = [
    'Available install flags:',
    '',
    '  Global flags:',
    '    -y, --yes                           Accept all defaults without prompting',
    '    -f, --force                         Overwrite installer-owned files even if locally modified',
    '    -d, --directory <path>              Target directory (default: current directory)',
    '',
    '  Per-question flags:',
  ];

  for (const def of FLAG_DEFINITIONS) {
    const flagPad = def.flag.padEnd(36);
    lines.push(`    ${flagPad}  ${def.description}`);
    lines.push(`    ${' '.repeat(36)}  (default: ${def.defaultValue})`);
  }

  return lines.join('\n');
}
