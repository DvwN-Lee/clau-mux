/**
 * @typedef {'DEBUG'|'INFO'|'WARN'|'ERROR'} LogLevel
 * @typedef {{ level: LogLevel, component: string, message: string, timestamp?: string }} LogEntry
 */

export function formatLogLine(entry) {
  const ts = entry.timestamp ?? new Date().toISOString();
  return `[${ts}] [${entry.level}] [${entry.component}] ${entry.message}`;
}

export function createLogger(component, opts = {}) {
  const sink = opts.sink ?? ((line) => process.stderr.write(line + '\n'));
  const emit = (level, message) => sink(formatLogLine({ level, component, message }));
  return {
    info: (msg) => emit('INFO', msg),
    warn: (msg) => emit('WARN', msg),
    error: (msg) => emit('ERROR', msg),
    debug: (msg) => {
      if (process.env.CLMUX_DEBUG === '1') emit('DEBUG', msg);
    },
  };
}
