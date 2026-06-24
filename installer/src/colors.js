/**
 * Color and TTY detection utilities for the installer.
 *
 * Colors are disabled when:
 * - NO_COLOR env var is defined (per https://no-color.org/ — presence, not value)
 * - process.stdout.isTTY is not true (piped output)
 *
 * Callers can inject opts.isTTY and opts.noColor for testing.
 */

/**
 * @param {object} [opts]
 * @param {boolean} [opts.isTTY]   - override process.stdout.isTTY (for testing)
 * @param {boolean} [opts.noColor] - override NO_COLOR env var check (for testing)
 * @returns {boolean}
 */
export function isColorEnabled(opts = {}) {
  const isTTY = 'isTTY' in opts ? opts.isTTY : process.stdout.isTTY === true;
  const noColor = 'noColor' in opts ? opts.noColor : process.env.NO_COLOR !== undefined;
  return isTTY && !noColor;
}

/**
 * Apply a picocolors function to text if colors are enabled; otherwise return plain text.
 *
 * @param {string} text
 * @param {function} picocolorsFunction - e.g. pc.green, pc.bold
 * @param {object} [opts] - same as isColorEnabled opts
 * @returns {string}
 */
export function colorize(text, picocolorsFunction, opts = {}) {
  if (!isColorEnabled(opts)) return text;
  return picocolorsFunction(text);
}

// A normalized marker safe in both TTY and non-TTY output (avoids Unicode issues in pipes)
export const note = '->';
