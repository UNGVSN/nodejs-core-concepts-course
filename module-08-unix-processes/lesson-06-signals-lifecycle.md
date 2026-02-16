# Module 08 / Lesson 06 — Signals & Process Lifecycle

> In the Unix world, processes do not just start and stop — they receive signals. A `SIGTERM` from your process manager means "please shut down." A `SIGINT` from Ctrl+C means "the user wants out." How your Node.js process responds to these signals determines whether it drops connections or drains them gracefully. This lesson teaches you to handle the entire process lifecycle.

---

## Learning Objectives

- Identify the most important Unix signals and understand when the OS or process manager sends each one
- Register signal handlers with `process.on('SIGTERM')` and `process.on('SIGINT')` for controlled shutdown
- Implement a graceful shutdown pattern that drains connections, closes handles, and exits cleanly
- Handle `uncaughtException` and `unhandledRejection` as last-resort safety nets
- Design a lifecycle manager that coordinates startup, readiness, and shutdown phases

---

## Unix Signals

A **signal** is an asynchronous notification sent to a process by the OS or another process. The process can catch the signal and run custom logic, ignore it, or accept the default behavior (usually termination).

| Signal | Number | Default | Trigger | Can Catch? |
|--------|--------|---------|---------|------------|
| `SIGINT` | 2 | Terminate | Ctrl+C in terminal | Yes |
| `SIGTERM` | 15 | Terminate | `kill <pid>`, process managers, Docker stop | Yes |
| `SIGHUP` | 1 | Terminate | Terminal closes, SSH disconnect | Yes |
| `SIGKILL` | 9 | Terminate | `kill -9`, OOM killer | No |
| `SIGSTOP` | 19 | Suspend | `kill -STOP` | No |
| `SIGUSR1` | 10 | Terminate | User-defined (Node.js: start debugger) | Yes |
| `SIGUSR2` | 12 | Terminate | User-defined | Yes |
| `SIGPIPE` | 13 | Terminate | Write to a broken pipe | Yes (Node ignores by default) |

```javascript
'use strict';

// Register handlers for the most important signals
process.on('SIGINT', () => {
  console.log('\nReceived SIGINT (Ctrl+C)');
  process.exit(0);
});

process.on('SIGTERM', () => {
  console.log('Received SIGTERM');
  process.exit(0);
});

process.on('SIGHUP', () => {
  console.log('Received SIGHUP (terminal closed)');
  // Common use: reload configuration without restarting
});

console.log(`Process ${process.pid} running. Press Ctrl+C to send SIGINT.`);

// Keep the process alive
setInterval(() => {}, 1000);
```

---

## SIGINT — The User Interrupt

`SIGINT` is sent when the user presses Ctrl+C in the terminal. By default, Node.js terminates. When you register a handler, Node.js suppresses the default behavior — you become responsible for exiting.

```javascript
'use strict';

let interruptCount = 0;

process.on('SIGINT', () => {
  interruptCount += 1;
  console.log(`\nSIGINT received (${interruptCount} times)`);

  if (interruptCount >= 3) {
    console.log('Three interrupts — forcing exit.');
    process.exit(1);
  }

  console.log('Press Ctrl+C two more times to force exit.');
});

console.log('Running... Press Ctrl+C');
setInterval(() => {
  process.stdout.write('.');
}, 500);
```

---

## SIGTERM — The Graceful Termination Request

`SIGTERM` is the standard signal for requesting a process to shut down. Process managers (`systemd`, `pm2`, Docker, Kubernetes) send `SIGTERM` first, wait a grace period, then send `SIGKILL` if the process is still running.

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // Simulate a slow request
  setTimeout(() => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Hello, world\n');
  }, 2000);
});

server.listen(3000, () => {
  console.log(`Server running on port 3000 (PID: ${process.pid})`);
  console.log('Send SIGTERM: kill', process.pid);
});

process.on('SIGTERM', () => {
  console.log('SIGTERM received. Shutting down gracefully...');

  // Stop accepting new connections
  server.close(() => {
    console.log('All connections drained. Exiting.');
    process.exit(0);
  });

  // Force exit if draining takes too long
  setTimeout(() => {
    console.error('Forced shutdown — connections did not drain in time.');
    process.exit(1);
  }, 10_000);
});
```

---

## SIGHUP — Terminal Hangup / Config Reload

`SIGHUP` was originally sent when a terminal disconnected (modem "hung up"). Today it is commonly used to tell a daemon to reload its configuration.

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

let config = loadConfig();

function loadConfig() {
  const configPath = path.join(__dirname, 'config.json');
  try {
    const raw = fs.readFileSync(configPath, 'utf8');
    const parsed = JSON.parse(raw);
    console.log('Config loaded:', parsed);
    return parsed;
  } catch {
    console.log('No config file found, using defaults');
    return { port: 3000, logLevel: 'info' };
  }
}

process.on('SIGHUP', () => {
  console.log('SIGHUP received — reloading configuration...');
  config = loadConfig();
  console.log('Configuration reloaded:', config);
});

console.log(`PID: ${process.pid}`);
console.log('Send SIGHUP to reload config: kill -HUP', process.pid);

// Keep the process alive
setInterval(() => {}, 5000);
```

---

## SIGUSR1 and SIGUSR2 — Custom Signals

`SIGUSR1` and `SIGUSR2` are reserved for user-defined behavior. Node.js has a default use for `SIGUSR1` — it starts the built-in debugger. `SIGUSR2` is free for you.

```javascript
'use strict';

// SIGUSR2: dump diagnostic information
process.on('SIGUSR2', () => {
  const mem = process.memoryUsage();
  const info = {
    pid: process.pid,
    uptime: `${process.uptime().toFixed(0)}s`,
    rss: `${(mem.rss / 1024 / 1024).toFixed(1)} MB`,
    heapUsed: `${(mem.heapUsed / 1024 / 1024).toFixed(1)} MB`,
    heapTotal: `${(mem.heapTotal / 1024 / 1024).toFixed(1)} MB`,
    activeHandles: process._getActiveHandles().length,
    activeRequests: process._getActiveRequests().length
  };

  console.log('\n=== DIAGNOSTIC DUMP ===');
  console.log(JSON.stringify(info, null, 2));
  console.log('======================\n');
});

console.log(`PID: ${process.pid}`);
console.log(`Send SIGUSR2 for diagnostics: kill -USR2 ${process.pid}`);

// Simulate a running server
setInterval(() => {}, 1000);
```

---

## uncaughtException — The Last Resort

When an exception is thrown and nothing catches it, Node.js emits `'uncaughtException'` on the `process` object. If no handler is registered, Node.js prints the stack trace and exits with code 1.

```javascript
'use strict';

process.on('uncaughtException', (err, origin) => {
  // Log the error
  console.error('=== UNCAUGHT EXCEPTION ===');
  console.error('Error:', err.message);
  console.error('Stack:', err.stack);
  console.error('Origin:', origin);
  console.error('==========================');

  // CRITICAL: You MUST exit after an uncaughtException.
  // The process is in an undefined state — continuing is dangerous.
  // Flush logs, close what you can, then exit.
  process.exit(1);
});

// This will trigger the handler
setTimeout(() => {
  throw new Error('Something catastrophic happened');
}, 100);
```

### Why You Must Exit

After an uncaught exception, the state of your application is unknown. Variables might be corrupted, connections might be half-open, transactions might be uncommitted. The Node.js documentation is explicit: **use `uncaughtException` only for synchronous cleanup before exiting.**

```javascript
'use strict';

const fs = require('node:fs');

process.on('uncaughtException', (err) => {
  // Synchronous logging — async operations may not complete
  const timestamp = new Date().toISOString();
  const logLine = `${timestamp} FATAL: ${err.message}\n${err.stack}\n`;

  try {
    fs.appendFileSync('/tmp/crash.log', logLine);
  } catch {
    // If even logging fails, there's nothing more we can do
  }

  process.exit(1);
});
```

---

## unhandledRejection — Unhandled Promise Rejections

When a Promise rejects and no `.catch()` or `try/catch` (in async functions) handles it, Node.js emits `'unhandledRejection'`.

```javascript
'use strict';

process.on('unhandledRejection', (reason, promise) => {
  console.error('=== UNHANDLED REJECTION ===');
  console.error('Reason:', reason);
  console.error('Promise:', promise);
  console.error('===========================');

  // In production, treat this the same as uncaughtException
  process.exit(1);
});

// This will trigger the handler
async function riskyOperation() {
  throw new Error('Async failure');
}

// No await, no .catch() — the rejection is unhandled
riskyOperation();
```

### Node.js Behavior Changes

Starting with Node.js v15, unhandled rejections throw an error by default (matching `uncaughtException` behavior). In older versions, they only produced a warning. Always register a handler to ensure consistent behavior.

```javascript
'use strict';

// Unified error handling for both sync and async errors
function setupErrorHandlers() {
  process.on('uncaughtException', (err) => {
    console.error('[FATAL] Uncaught exception:', err.message);
    process.exit(1);
  });

  process.on('unhandledRejection', (reason) => {
    console.error('[FATAL] Unhandled rejection:', reason);
    process.exit(1);
  });
}

setupErrorHandlers();
```

---

## The Graceful Shutdown Pattern

A production-grade shutdown sequence has three phases:

1. **Stop accepting new work** — close the server, stop polling queues
2. **Drain in-flight work** — wait for active requests, transactions, and writes to finish
3. **Clean up resources** — close database connections, flush logs, release file handles

```javascript
'use strict';

const http = require('node:http');

class GracefulServer {
  #server;
  #connections = new Set();
  #isShuttingDown = false;

  constructor(handler) {
    this.#server = http.createServer(handler);

    // Track all active connections
    this.#server.on('connection', (socket) => {
      this.#connections.add(socket);
      socket.on('close', () => {
        this.#connections.delete(socket);
      });
    });
  }

  listen(port) {
    return new Promise((resolve) => {
      this.#server.listen(port, () => {
        console.log(`Server listening on port ${port} (PID: ${process.pid})`);
        this.#registerSignalHandlers();
        resolve();
      });
    });
  }

  #registerSignalHandlers() {
    const shutdown = (signal) => {
      console.log(`\n${signal} received. Starting graceful shutdown...`);
      this.#shutdown();
    };

    process.on('SIGINT', () => shutdown('SIGINT'));
    process.on('SIGTERM', () => shutdown('SIGTERM'));
  }

  async #shutdown() {
    if (this.#isShuttingDown) return;
    this.#isShuttingDown = true;

    console.log('Phase 1: Stop accepting new connections');
    this.#server.close();

    console.log(`Phase 2: Draining ${this.#connections.size} active connections...`);

    // Set a hard deadline
    const forceTimeout = setTimeout(() => {
      console.error('Phase 3: Force shutdown — destroying remaining connections');
      for (const socket of this.#connections) {
        socket.destroy();
      }
      process.exit(1);
    }, 10_000);

    // Wait for all connections to close naturally
    await new Promise((resolve) => {
      if (this.#connections.size === 0) {
        resolve();
        return;
      }

      const checkInterval = setInterval(() => {
        console.log(`  Waiting... ${this.#connections.size} connections remaining`);
        if (this.#connections.size === 0) {
          clearInterval(checkInterval);
          resolve();
        }
      }, 1000);
    });

    clearTimeout(forceTimeout);
    console.log('Phase 3: All connections drained. Exiting cleanly.');
    process.exit(0);
  }
}

// Usage
const app = new GracefulServer((req, res) => {
  // Simulate a slow request
  const delay = parseInt(req.url.slice(1), 10) || 100;
  setTimeout(() => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`Response after ${delay}ms\n`);
  }, delay);
});

app.listen(3000);
```

---

## Process Lifecycle: The Complete Picture

```
┌──────────────────────────────────────────────────┐
│                                                  │
│  1. STARTUP                                      │
│     - Parse arguments                            │
│     - Load configuration                         │
│     - Connect to databases                       │
│     - Register error handlers                    │
│                                                  │
│  2. READY                                        │
│     - Start accepting connections                │
│     - Begin processing work                      │
│     - Emit 'ready' signal (for process managers) │
│                                                  │
│  3. RUNNING                                      │
│     - Handle requests                            │
│     - SIGHUP → reload config                     │
│     - SIGUSR2 → dump diagnostics                 │
│                                                  │
│  4. SHUTTING DOWN (SIGTERM / SIGINT)             │
│     - Stop accepting new work                    │
│     - Drain in-flight requests                   │
│     - Close database connections                 │
│     - Flush log buffers                          │
│                                                  │
│  5. EXIT                                         │
│     - process.exit(0) on success                 │
│     - process.exit(1) on forced / error          │
│                                                  │
└──────────────────────────────────────────────────┘
```

### A Complete Lifecycle Manager

```javascript
'use strict';

const http = require('node:http');

class LifecycleManager {
  #shutdownCallbacks = [];
  #isShuttingDown = false;

  constructor() {
    this.#setupErrorHandlers();
    this.#setupSignalHandlers();
  }

  onShutdown(callback) {
    this.#shutdownCallbacks.push(callback);
  }

  #setupErrorHandlers() {
    process.on('uncaughtException', (err) => {
      console.error('[FATAL] Uncaught exception:', err.stack);
      this.#shutdown(1);
    });

    process.on('unhandledRejection', (reason) => {
      console.error('[FATAL] Unhandled rejection:', reason);
      this.#shutdown(1);
    });
  }

  #setupSignalHandlers() {
    process.on('SIGINT', () => {
      console.log('\nSIGINT received');
      this.#shutdown(0);
    });

    process.on('SIGTERM', () => {
      console.log('SIGTERM received');
      this.#shutdown(0);
    });
  }

  async #shutdown(code) {
    if (this.#isShuttingDown) return;
    this.#isShuttingDown = true;

    console.log(`Shutdown initiated (exit code: ${code})`);

    // Force exit after 15 seconds
    const forceTimer = setTimeout(() => {
      console.error('Shutdown timed out. Forcing exit.');
      process.exit(code);
    }, 15_000);
    forceTimer.unref(); // Don't let the timer keep the process alive

    // Run all shutdown callbacks in order
    for (const callback of this.#shutdownCallbacks) {
      try {
        await callback();
      } catch (err) {
        console.error('Shutdown callback error:', err.message);
      }
    }

    console.log('Shutdown complete.');
    process.exit(code);
  }
}

// Usage
const lifecycle = new LifecycleManager();

const server = http.createServer((req, res) => {
  res.end('OK\n');
});

server.listen(3000, () => {
  console.log('Server ready on port 3000');
});

lifecycle.onShutdown(() => {
  return new Promise((resolve) => {
    console.log('Closing HTTP server...');
    server.close(resolve);
  });
});

lifecycle.onShutdown(async () => {
  console.log('Flushing logs...');
  // Simulate async log flush
  await new Promise((resolve) => setTimeout(resolve, 100));
  console.log('Logs flushed.');
});
```

---

## Sending Signals from Node.js

You can send signals to other processes using `process.kill()` (misleading name — it sends any signal, not just lethal ones):

```javascript
'use strict';

const { spawn } = require('node:child_process');

// Spawn a long-running child
const child = spawn('sleep', ['60']);
console.log('Child PID:', child.pid);

// Send SIGTERM after 2 seconds
setTimeout(() => {
  process.kill(child.pid, 'SIGTERM');
  console.log('Sent SIGTERM to child');
}, 2000);

// Check if a process exists (signal 0 does not kill, just checks)
setTimeout(() => {
  try {
    process.kill(child.pid, 0);
    console.log('Child is still running');
  } catch (err) {
    if (err.code === 'ESRCH') {
      console.log('Child has exited');
    }
  }
}, 3000);

child.on('exit', (code, signal) => {
  console.log(`Child exited: code=${code}, signal=${signal}`);
});
```

---

## Key Takeaways

- `SIGTERM` is the standard graceful termination signal used by process managers, Docker, and Kubernetes — always handle it by draining work before exiting.
- `SIGINT` (Ctrl+C) is the user interrupt — once you register a handler, you own the exit responsibility.
- `uncaughtException` and `unhandledRejection` are last-resort safety nets; log the error and exit immediately because the process state is unreliable.
- A production graceful shutdown follows three phases: stop accepting new work, drain in-flight operations, then clean up resources — all within a hard timeout.
- Use `SIGHUP` for configuration reload and `SIGUSR2` for diagnostic dumps, keeping your process running without restart.

---

## Next

In the next lesson you will learn how the `cluster` module uses everything from this module — fork, IPC, and signals — to scale your HTTP server across all CPU cores with zero-downtime restarts.
