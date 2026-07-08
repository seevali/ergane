/**
 * Shared helper for the installer's own package identity.
 *
 * User-facing copy (the outro tip, the GETTING-STARTED template) must name the
 * real published CLI, never a literal `<package>` placeholder. Both the outro
 * (sync) and the writer (renders the template) read the name through this one
 * helper so the invocation string is defined in exactly one place.
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * Read the installer's package name from installer/package.json.
 * Falls back to a sane default if the file is unreadable.
 * @returns {string} e.g. "@seevali/ergane"
 */
export function getPackageName() {
  try {
    const pkgPath = path.join(__dirname, '..', 'package.json');
    const name = JSON.parse(readFileSync(pkgPath, 'utf8')).name;
    return typeof name === 'string' && name.length > 0 ? name : '@seevali/ergane';
  } catch {
    return '@seevali/ergane';
  }
}

/**
 * The `npx <name>` invocation users should type to run the CLI.
 * @returns {string} e.g. "npx @seevali/ergane"
 */
export function cliInvocation() {
  return `npx ${getPackageName()}`;
}
