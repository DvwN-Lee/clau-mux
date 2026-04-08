import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { validateInboxPath } from './path-utils.js';

export const MAX_ENTRIES = 50;

export function writeToInbox(teamDir, subscriber, payload) {
  const inboxPath = path.join(teamDir, 'inboxes', `${subscriber}.json`);
  validateInboxPath(inboxPath);

  let entries = [];
  try {
    const raw = fs.readFileSync(inboxPath, 'utf8');
    entries = JSON.parse(raw);
    if (!Array.isArray(entries)) entries = [];
  } catch {
    entries = [];
  }

  const summary = `browser-inspect: ${String(payload.user_intent || '').slice(0, 60)}`;
  entries.push({
    from: 'browser-inspect',
    text: JSON.stringify(payload),
    timestamp: new Date().toISOString(),
    read: false,
    summary,
  });

  if (entries.length > MAX_ENTRIES) {
    entries = entries.slice(-MAX_ENTRIES);
  }

  const tmp = inboxPath + '.' + crypto.randomBytes(4).toString('hex') + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(entries, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, inboxPath);
  // M6 fix: explicit chmod after rename — mode option only affects new file creation,
  // not overwrites of existing files with different permissions.
  try { fs.chmodSync(inboxPath, 0o600); } catch { /* best-effort */ }
}
