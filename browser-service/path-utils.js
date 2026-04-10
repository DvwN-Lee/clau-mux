import os from 'node:os';
import path from 'node:path';

export class InvalidInboxPathError extends Error {
  constructor(reason, targetPath) {
    super(`invalid inbox path: ${reason} (${targetPath})`);
    this.name = 'InvalidInboxPathError';
  }
}

// Allowed pattern: ~/.claude/teams/<team-path>/inboxes/<agent>.json
// - team-path: one or more path segments (supports nested team names like "repo/custom")
// - agent: single path segment ending in .json
const INBOX_PATTERN = /^teams\/[^/]+(?:\/[^/]+)*\/inboxes\/[^/]+\.json$/;

/**
 * Validates inbox path. Mirrors bridge-mcp-server.js security pattern with tighter scope.
 * Uses path.resolve() (not normalize) to fully expand relative segments and symlinks.
 *
 * @param {string} inboxPath absolute path
 * @throws {InvalidInboxPathError}
 */
export function validateInboxPath(inboxPath) {
  if (typeof inboxPath !== 'string' || inboxPath.length === 0) {
    throw new InvalidInboxPathError('empty or non-string', inboxPath);
  }

  const home = os.homedir();
  const claudeRoot = path.resolve(home, '.claude');
  const resolved = path.resolve(inboxPath);

  // Must be under ~/.claude
  if (!resolved.startsWith(claudeRoot + path.sep)) {
    throw new InvalidInboxPathError('not under ~/.claude', inboxPath);
  }

  // Must match exact inbox pattern
  const relative = path.relative(claudeRoot, resolved);
  if (!INBOX_PATTERN.test(relative)) {
    throw new InvalidInboxPathError(
      `not a valid inbox path (expected teams/<team>/inboxes/<agent>.json, got ${relative})`,
      inboxPath,
    );
  }

  if (!resolved.endsWith('.json')) {
    throw new InvalidInboxPathError('not a .json file', inboxPath);
  }
}
