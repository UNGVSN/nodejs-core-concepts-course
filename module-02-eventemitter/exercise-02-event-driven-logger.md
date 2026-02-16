# E02: Event-Driven Logger

## Objective

Build a structured logging system powered by EventEmitter that supports multiple transports (console, file), configurable log levels, and pluggable formatters. This exercise shows how the observer pattern turns a rigid utility into an extensible system where new output targets can be added without modifying existing code.

## Prerequisites

- Module 02 / Lesson 01 — EventEmitter Internals
- Module 02 / Lesson 02 — Registering, Emitting, and Removing Listeners
- Module 02 / Lesson 06 — Observer Pattern and Pub/Sub

## Instructions

1. Create a file called `event-logger.js`. Add `'use strict';` at the top:

```javascript
'use strict';

const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const path = require('node:path');
```

2. Define log level constants with numeric severity values:

```javascript
const LEVELS = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
  fatal: 4,
};
```

3. Create a `Logger` class extending `EventEmitter`. The constructor accepts a minimum log level and an optional context object (metadata attached to every log entry):

```javascript
class Logger extends EventEmitter {
  constructor(options = {}) {
    super();
    this.minLevel = options.level || 'info';
    this.context = options.context || {};
  }
}
```

4. Add a core `log(level, message, meta)` method. It should:
   - Check if the level meets the minimum threshold — if not, return silently
   - Build a structured log entry: `{ timestamp, level, message, meta: { ...this.context, ...meta } }`
   - Emit a `'log'` event with the entry
   - Also emit a level-specific event (e.g., `'error'`) with the same entry

```javascript
log(level, message, meta = {}) {
  if (LEVELS[level] === undefined) throw new Error(`Unknown level: ${level}`);
  if (LEVELS[level] < LEVELS[this.minLevel]) return;

  const entry = {
    timestamp: new Date().toISOString(),
    level,
    message,
    meta: { ...this.context, ...meta },
  };

  this.emit('log', entry);
  this.emit(level, entry);
}
```

5. Add convenience methods for each log level:

```javascript
debug(message, meta) { this.log('debug', message, meta); }
info(message, meta) { this.log('info', message, meta); }
warn(message, meta) { this.log('warn', message, meta); }
error(message, meta) { this.log('error', message, meta); }
fatal(message, meta) { this.log('fatal', message, meta); }
```

6. Create a `ConsoleTransport` function that registers a `'log'` listener with formatted, colorized output:

```javascript
function ConsoleTransport(logger, options = {}) {
  const colors = {
    debug: '\x1b[36m',   // cyan
    info:  '\x1b[32m',   // green
    warn:  '\x1b[33m',   // yellow
    error: '\x1b[31m',   // red
    fatal: '\x1b[35m',   // magenta
  };
  const reset = '\x1b[0m';

  logger.on('log', (entry) => {
    const color = colors[entry.level] || reset;
    const metaStr = Object.keys(entry.meta).length > 0
      ? ` ${JSON.stringify(entry.meta)}`
      : '';
    const output = `${color}[${entry.timestamp}] [${entry.level.toUpperCase().padEnd(5)}]${reset} ${entry.message}${metaStr}`;
    console.log(output);
  });
}
```

7. Create a `FileTransport` function that writes JSON-formatted log entries to a file, one per line (JSONL format):

```javascript
function FileTransport(logger, filePath, options = {}) {
  const minLevel = options.level || 'info';
  const stream = fs.createWriteStream(filePath, { flags: 'a' });

  logger.on('log', (entry) => {
    if (LEVELS[entry.level] < LEVELS[minLevel]) return;
    stream.write(JSON.stringify(entry) + '\n');
  });

  // Return a cleanup function
  return () => stream.end();
}
```

8. Create a `child(context)` method that returns a new Logger instance sharing the same listeners but with additional context merged in:

```javascript
child(additionalContext) {
  const childLogger = new Logger({
    level: this.minLevel,
    context: { ...this.context, ...additionalContext },
  });

  // Forward child's log events to parent's transports
  childLogger.on('log', (entry) => this.emit('log', entry));

  return childLogger;
}
```

9. Write a test script that creates a logger, attaches both transports, creates a child logger, and exercises all log levels:

```javascript
const logger = new Logger({ level: 'debug', context: { service: 'api' } });

ConsoleTransport(logger);
const cleanupFile = FileTransport(logger, path.join(__dirname, 'app.log'), { level: 'warn' });

logger.info('Server starting', { port: 3000 });
logger.debug('Loading configuration');

const reqLogger = logger.child({ requestId: 'abc-123', method: 'GET', path: '/users' });
reqLogger.info('Request received');
reqLogger.warn('Slow query detected', { queryTime: 1523 });
reqLogger.error('Database connection lost', { host: 'db-01', retryIn: 5000 });

logger.info('Server stopping');
cleanupFile();
```

10. Run the script, then inspect both the console output and the `app.log` file. Verify that: console shows all levels (debug and above), the file only contains warn/error/fatal entries, and child logger entries include both parent and child context.

## Break-Then-Harden Challenge

1. **Listener leak via child loggers.** In a loop, create 100 child loggers without ever removing them. Observe the `MaxListenersExceededWarning`. Fix it by either increasing `maxListeners` with a comment explaining why, or by implementing a `destroy()` method on child loggers that calls `removeAllListeners()`.

2. **Synchronous emit blocking.** Add a transport that performs a heavy synchronous computation (e.g., `JSON.stringify` on a 10MB object) inside the `'log'` listener. Observe how it blocks the event loop during logging. Fix it by deferring heavy work to `setImmediate` or by using a write buffer that flushes asynchronously.

3. **Error in transport.** Make the FileTransport write to an invalid path (e.g., `/nonexistent/dir/app.log`). Observe the unhandled error. Fix it by wrapping transport callbacks in `try/catch` and emitting a `'transport-error'` event instead of crashing.

## Expected Output

Console:
```
[2026-02-15T10:30:00.000Z] [INFO ] Server starting {"service":"api","port":3000}
[2026-02-15T10:30:00.001Z] [DEBUG] Loading configuration {"service":"api"}
[2026-02-15T10:30:00.002Z] [INFO ] Request received {"service":"api","requestId":"abc-123","method":"GET","path":"/users"}
[2026-02-15T10:30:00.003Z] [WARN ] Slow query detected {"service":"api","requestId":"abc-123","method":"GET","path":"/users","queryTime":1523}
[2026-02-15T10:30:00.004Z] [ERROR] Database connection lost {"service":"api","requestId":"abc-123","method":"GET","path":"/users","host":"db-01","retryIn":5000}
[2026-02-15T10:30:00.005Z] [INFO ] Server stopping {"service":"api"}
```

app.log (JSONL):
```json
{"timestamp":"2026-02-15T10:30:00.003Z","level":"warn","message":"Slow query detected","meta":{"service":"api","requestId":"abc-123","method":"GET","path":"/users","queryTime":1523}}
{"timestamp":"2026-02-15T10:30:00.004Z","level":"error","message":"Database connection lost","meta":{"service":"api","requestId":"abc-123","method":"GET","path":"/users","host":"db-01","retryIn":5000}}
```

## Bonus

1. Add a `FilterTransport` that accepts a predicate function `(entry) => boolean` and only forwards matching entries. Use it to create an "errors-only Slack alert" transport that logs to a file with the prefix `[ALERT]`.

2. Implement log rotation in `FileTransport`: when the file exceeds 1MB, rename it to `app.log.1` and start a new `app.log`. Use `fs.statSync` to check size before each write.

## Hints

1. ANSI color codes: `\x1b[32m` starts green text, `\x1b[0m` resets. These work in most terminals. Use them only in the console transport — the file transport should write plain JSON.
2. The `child()` pattern is how production loggers (like pino and winston) implement per-request context. Each child shares transports but adds its own metadata.
3. `fs.createWriteStream` with `{ flags: 'a' }` opens the file in append mode. This is safe for concurrent writes from the same process but not from multiple processes.
4. When comparing log levels, compare numeric values: `LEVELS[entry.level] >= LEVELS[minLevel]`. This avoids string comparison bugs.
5. Emitting both `'log'` and the level-specific event (like `'error'`) lets transports choose their subscription granularity — subscribe to everything via `'log'` or just errors via `'error'`.
