# E03: Memory Leak Hunter

## Objective

Detect, diagnose, and fix EventEmitter listener leaks using `listenerCount()`, the `newListener` event, `process.memoryUsage()`, and heap inspection techniques. Listener leaks are the most common EventEmitter bug in production Node.js applications — this exercise teaches you to find them before your monitoring dashboard does.

## Prerequisites

- Module 02 / Lesson 01 — EventEmitter Internals
- Module 02 / Lesson 02 — Registering, Emitting, and Removing Listeners
- Module 02 / Lesson 03 — Error Events and Edge Cases

## Instructions

1. Create a file called `leak-hunter.js`. Add `'use strict';` at the top:

```javascript
'use strict';

const { EventEmitter } = require('node:events');
const { performance } = require('node:perf_hooks');
```

2. **Step 1 — Create the leak.** Write a `ConnectionPool` class that simulates a database connection pool. On every `getConnection()` call, it registers a `'healthCheck'` listener but never removes it:

```javascript
class ConnectionPool extends EventEmitter {
  constructor() {
    super();
    this.connections = 0;
  }

  getConnection() {
    this.connections++;
    const connId = this.connections;

    // BUG: registers a new listener every time, never removes it
    this.on('healthCheck', () => {
      // simulate checking connection health
      return { id: connId, healthy: true };
    });

    return { id: connId, release: () => {} };
  }

  runHealthCheck() {
    this.emit('healthCheck');
  }
}
```

3. **Step 2 — Observe the warning.** Call `getConnection()` in a loop 15 times and observe the `MaxListenersExceededWarning`:

```javascript
const pool = new ConnectionPool();

for (let i = 0; i < 15; i++) {
  pool.getConnection();
}

console.log(`Listener count for 'healthCheck': ${pool.listenerCount('healthCheck')}`);
// Should print 15 — way too many
```

4. **Step 3 — Build a leak detector.** Create a `LeakDetector` class that monitors any EventEmitter for growing listener counts:

```javascript
class LeakDetector {
  constructor(emitter, options = {}) {
    this.emitter = emitter;
    this.threshold = options.threshold || 10;
    this.snapshots = [];
    this._monitorNewListeners();
  }

  _monitorNewListeners() {
    this.emitter.on('newListener', (eventName) => {
      const count = this.emitter.listenerCount(eventName) + 1; // +1 because newListener fires before add
      if (count > this.threshold) {
        console.warn(`[LEAK DETECTED] '${eventName}' has ${count} listeners (threshold: ${this.threshold})`);
        console.warn(`  Stack trace:\n${new Error().stack.split('\n').slice(2, 6).join('\n')}`);
      }
    });
  }

  snapshot(label) {
    const eventNames = this.emitter.eventNames();
    const counts = {};
    for (const name of eventNames) {
      counts[name] = this.emitter.listenerCount(name);
    }
    this.snapshots.push({
      label,
      timestamp: performance.now(),
      counts,
      memory: process.memoryUsage().heapUsed,
    });
  }

  report() {
    console.log('\n=== Leak Detection Report ===\n');
    for (const snap of this.snapshots) {
      console.log(`[${snap.label}] Heap: ${(snap.memory / 1024 / 1024).toFixed(2)} MB`);
      for (const [event, count] of Object.entries(snap.counts)) {
        const marker = count > this.threshold ? ' *** LEAK ***' : '';
        console.log(`  '${event}': ${count} listeners${marker}`);
      }
    }
  }
}
```

5. **Step 4 — Attach the detector and reproduce the leak.** Wire up the `LeakDetector` to the `ConnectionPool`, take snapshots at intervals, and generate the report:

```javascript
const pool2 = new ConnectionPool();
const detector = new LeakDetector(pool2, { threshold: 5 });

detector.snapshot('initial');

for (let i = 0; i < 50; i++) {
  pool2.getConnection();
  if (i % 10 === 9) {
    detector.snapshot(`after ${i + 1} connections`);
  }
}

pool2.runHealthCheck();
detector.snapshot('after health check');
detector.report();
```

6. **Step 5 — Fix the leak.** Refactor `ConnectionPool` so that `getConnection()` does not register a new listener each time. Instead, use a single listener that iterates over active connections:

```javascript
class FixedConnectionPool extends EventEmitter {
  constructor() {
    super();
    this.activeConnections = new Map();
    this.nextId = 0;

    // ONE listener, registered once
    this.on('healthCheck', () => {
      for (const [id, conn] of this.activeConnections) {
        conn.lastCheck = Date.now();
      }
    });
  }

  getConnection() {
    const id = ++this.nextId;
    this.activeConnections.set(id, { id, healthy: true, lastCheck: null });

    return {
      id,
      release: () => {
        this.activeConnections.delete(id);
      },
    };
  }

  runHealthCheck() {
    this.emit('healthCheck');
  }
}
```

7. **Step 6 — Verify the fix.** Run the same 50-connection test against `FixedConnectionPool` and confirm that `listenerCount('healthCheck')` stays at 1 throughout.

8. **Step 7 — Measure memory impact.** Compare `process.memoryUsage().heapUsed` between the leaking and fixed versions after 10,000 `getConnection()` calls. Print the difference.

9. **Step 8 — Test listener removal.** Call `release()` on every connection returned by `FixedConnectionPool` and verify that `activeConnections.size` drops to 0. Run a final health check and confirm it completes instantly with no connections to check.

10. Run the full script with `node leak-hunter.js` and review all output.

## Break-Then-Harden Challenge

1. **Listener stacking in event handlers.** Create an HTTP-like simulation where every "request" registers a `'response'` listener on a shared emitter. Process 1,000 requests and watch the listener count grow. Fix it using `once()` instead of `on()`, then verify the count stays bounded.

2. **removeListener mismatch.** Try to remove a listener using `removeListener` with an anonymous function that looks identical but is a different reference. Observe that the listener is NOT removed. Fix it by saving the function reference to a variable before registering, then using that same reference to remove.

3. **Error event without listener.** On the `FixedConnectionPool`, emit `'error'` without registering an error listener. Observe the crash. Add a defensive `this.on('error', ...)` handler in the constructor and verify the process survives.

## Expected Output

```
[LEAK DETECTED] 'healthCheck' has 6 listeners (threshold: 5)
  Stack trace:
    at ConnectionPool.getConnection (leak-hunter.js:XX:XX)
    at Object.<anonymous> (leak-hunter.js:XX:XX)
[LEAK DETECTED] 'healthCheck' has 7 listeners (threshold: 5)
...

Listener count for 'healthCheck': 15

=== Leak Detection Report ===

[initial] Heap: 4.12 MB
  'newListener': 1 listeners

[after 10 connections] Heap: 4.35 MB
  'healthCheck': 10 listeners *** LEAK ***
  'newListener': 1 listeners

[after 20 connections] Heap: 4.58 MB
  'healthCheck': 20 listeners *** LEAK ***
  'newListener': 1 listeners

[after 30 connections] Heap: 4.82 MB
  'healthCheck': 30 listeners *** LEAK ***
  'newListener': 1 listeners

[after 40 connections] Heap: 5.05 MB
  'healthCheck': 40 listeners *** LEAK ***
  'newListener': 1 listeners

[after 50 connections] Heap: 5.28 MB
  'healthCheck': 50 listeners *** LEAK ***
  'newListener': 1 listeners

[after health check] Heap: 5.30 MB
  'healthCheck': 50 listeners *** LEAK ***
  'newListener': 1 listeners

--- Fixed Pool ---
After 50 connections, listener count for 'healthCheck': 1
Heap difference (10000 connections): leaky=42.50 MB, fixed=12.10 MB
```

## Bonus

1. Extend `LeakDetector` to automatically generate a flamegraph-style output showing which call sites are registering the most listeners. Use `Error().stack` captured in the `newListener` hook to group by call site.

2. Add a `watch(interval)` method to `LeakDetector` that takes periodic snapshots and emits a `'leak-warning'` event when listener growth rate exceeds a threshold (e.g., more than 5 new listeners per second for the same event name).

## Hints

1. The `'newListener'` event fires **before** the listener is actually added, so `listenerCount()` inside the handler returns the count **before** the addition. Add 1 to get the count after.
2. `emitter.eventNames()` returns an array of all event names that currently have listeners — this is your starting point for auditing.
3. Anonymous arrow functions cannot be removed with `removeListener` because each declaration creates a new function reference. Always save listener references if you plan to remove them later.
4. `process.memoryUsage().heapUsed` is the best quick indicator of JS object memory growth. For deeper analysis, use `v8.getHeapStatistics()`.
5. In production, the default `maxListeners` limit of 10 is deliberately conservative. The warning is not an error — it is a signal that something might be wrong. Never blindly set `maxListeners` to `Infinity` without investigating first.
