# Module 08 / Lesson 07 — The cluster Module

> A single Node.js process runs on a single CPU core. On a 16-core server, that means 15 cores sit idle while your application handles every request on one thread. The `cluster` module solves this by forking multiple worker processes that share the same server port, turning your single-threaded application into a multi-process powerhouse — with no code changes to your request handlers.

## Learning Objectives

- Explain why a single Node.js process cannot utilize multiple CPU cores and how `cluster` addresses this limitation
- Use `cluster.isPrimary`, `cluster.fork()`, and worker events to manage a pool of worker processes
- Implement automatic worker restart on crash and zero-downtime rolling restarts
- Configure scheduling policies and understand how port sharing works between primary and workers
- Communicate between primary and worker processes using `worker.send()` and `process.on('message')`

---

## Why Cluster Exists

Node.js uses a single-threaded event loop. One process runs on one CPU core. If your server receives 10,000 requests per second and each request takes 5ms of CPU time, a single core can handle about 200 requests per second. The rest queue up.

```
Without cluster:                    With cluster:

┌──────────────────┐               ┌──────────────────┐
│  CPU Core 0      │               │  Primary Process  │
│  Node.js  ◄──────│── all reqs    │  (distributes)    │
│                  │               │       │           │
├──────────────────┤               │  ┌────┴────┐      │
│  CPU Core 1      │               │  │  fork() │      │
│  (idle)          │               ├──┴─────────┴──────┤
├──────────────────┤               │  Worker 0  Core 0 │◄── reqs
│  CPU Core 2      │               │  Worker 1  Core 1 │◄── reqs
│  (idle)          │               │  Worker 2  Core 2 │◄── reqs
├──────────────────┤               │  Worker 3  Core 3 │◄── reqs
│  CPU Core 3      │               └──────────────────┘
│  (idle)          │
└──────────────────┘
```

The `cluster` module forks the current process into multiple workers. Each worker is a full Node.js process with its own event loop, V8 heap, and memory space. The primary process accepts incoming connections and distributes them to workers.

---

## Basic Cluster Setup

```javascript
'use strict';

const cluster = require('node:cluster');
const http = require('node:http');
const os = require('node:os');

if (cluster.isPrimary) {
  // ── Primary Process ──────────────────────────────────
  const cpuCount = os.cpus().length;
  console.log(`Primary ${process.pid} starting ${cpuCount} workers...`);

  for (let i = 0; i < cpuCount; i++) {
    cluster.fork();
  }

  cluster.on('online', (worker) => {
    console.log(`  Worker ${worker.process.pid} is online`);
  });

  cluster.on('exit', (worker, code, signal) => {
    console.log(`  Worker ${worker.process.pid} exited (code: ${code}, signal: ${signal})`);
  });
} else {
  // ── Worker Process ───────────────────────────────────
  const server = http.createServer((req, res) => {
    const body = JSON.stringify({
      worker: process.pid,
      url: req.url,
    });

    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
  });

  server.listen(3000, () => {
    console.log(`  Worker ${process.pid} listening on port 3000`);
  });
}
```

All workers call `server.listen(3000)`, but they do not conflict. The primary process owns the actual listening socket and distributes incoming connections to workers.

---

## isPrimary vs isWorker

Node.js renamed `isMaster` to `isPrimary` in v16. Both exist for backward compatibility, but always use the modern names.

```javascript
'use strict';

const cluster = require('node:cluster');

console.log('cluster.isPrimary:', cluster.isPrimary);
console.log('cluster.isWorker:', cluster.isWorker);

// In the primary:  isPrimary === true,  isWorker === false
// In a worker:     isPrimary === false, isWorker === true

if (cluster.isPrimary) {
  console.log(`I am the primary (PID: ${process.pid})`);
  const worker = cluster.fork();
  console.log(`Forked worker with PID: ${worker.process.pid}`);
  console.log(`Worker ID: ${worker.id}`); // Sequential integer starting at 1
} else {
  console.log(`I am worker ${cluster.worker.id} (PID: ${process.pid})`);
  console.log(`My worker object:`, {
    id: cluster.worker.id,
    pid: cluster.worker.process.pid,
    isConnected: cluster.worker.isConnected(),
    isDead: cluster.worker.isDead(),
  });
}
```

---

## How Port Sharing Works

When a worker calls `server.listen(port)`, it does not bind to the port directly. Instead:

1. The worker sends a message to the primary: "I want to listen on port 3000"
2. The primary binds to port 3000 (if not already bound)
3. When a new connection arrives, the primary accepts it
4. The primary sends the connection's file descriptor to a worker
5. The worker handles the request on its own event loop

This is invisible to your code. You write a normal `http.createServer` and `server.listen` — the cluster module handles the socket sharing behind the scenes via IPC.

```javascript
'use strict';

const cluster = require('node:cluster');
const http = require('node:http');
const os = require('node:os');

if (cluster.isPrimary) {
  console.log(`Primary PID: ${process.pid}`);
  console.log('The primary owns the listening socket.');
  console.log('Workers receive connections via IPC file descriptor passing.\n');

  for (let i = 0; i < 2; i++) {
    cluster.fork();
  }
} else {
  const server = http.createServer((req, res) => {
    // Each request is handled by exactly one worker
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`Handled by worker ${process.pid}\n`);
  });

  // Both workers "listen" on 3000, but the primary actually owns the socket
  server.listen(3000, () => {
    console.log(`Worker ${process.pid} ready (appears to listen on 3000)`);
  });
}
```

---

## Scheduling Policies

The primary decides which worker receives each new connection. Two policies exist:

| Policy | Constant | Behavior | Default On |
|---|---|---|---|
| Round-robin | `cluster.SCHED_RR` | Distributes connections sequentially | Linux, macOS |
| None (OS-level) | `cluster.SCHED_NONE` | Let the OS kernel decide | Windows |

```javascript
'use strict';

const cluster = require('node:cluster');
const http = require('node:http');

if (cluster.isPrimary) {
  // Set scheduling policy before forking
  cluster.schedulingPolicy = cluster.SCHED_RR; // Round-robin

  console.log('Scheduling policy:', cluster.schedulingPolicy === cluster.SCHED_RR
    ? 'Round-Robin' : 'OS-level');

  // You can also set it via environment variable:
  // NODE_CLUSTER_SCHED_POLICY=rr  (or "none")

  for (let i = 0; i < 4; i++) {
    cluster.fork();
  }

  // Track which worker handles each request
  const requestCounts = {};
  cluster.on('message', (worker, msg) => {
    if (msg.type === 'request') {
      requestCounts[worker.id] = (requestCounts[worker.id] || 0) + 1;
    }
  });

  // Print distribution every 5 seconds
  setInterval(() => {
    console.log('Request distribution:', requestCounts);
  }, 5000).unref();

} else {
  http.createServer((req, res) => {
    // Notify primary of each request
    process.send({ type: 'request' });

    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`Worker ${cluster.worker.id}\n`);
  }).listen(3000);
}
```

Round-robin provides better distribution. OS-level scheduling can lead to "thundering herd" behavior where one worker gets most connections.

---

## Cluster Settings

`cluster.setupPrimary()` (formerly `cluster.setupMaster()`) configures how workers are spawned:

```javascript
'use strict';

const cluster = require('node:cluster');

if (cluster.isPrimary) {
  // Configure before the first fork()
  cluster.setupPrimary({
    exec: __filename,       // Script to run in workers (default: current file)
    args: ['--worker'],     // Additional arguments for workers
    silent: false,          // If true, worker stdout/stderr is not piped to primary
    serialization: 'json',  // 'json' (default) or 'advanced' (supports more types)
  });

  console.log('Cluster settings:', cluster.settings);

  const worker = cluster.fork({
    // Environment variables passed to this specific worker
    WORKER_TYPE: 'http',
    NODE_ENV: 'production',
  });

  console.log(`Forked worker ${worker.id} with custom env`);

} else {
  console.log(`Worker ${process.pid} started`);
  console.log('  WORKER_TYPE:', process.env.WORKER_TYPE);
  console.log('  NODE_ENV:', process.env.NODE_ENV);
  console.log('  Args:', process.argv.slice(2));
}
```

---

## Worker Events

Workers emit events on the cluster object and on individual worker objects:

```javascript
'use strict';

const cluster = require('node:cluster');
const http = require('node:http');

if (cluster.isPrimary) {
  const worker = cluster.fork();

  // ── Individual Worker Events ───────────────────────
  worker.on('online', () => {
    console.log(`[worker ${worker.id}] online — process is running`);
  });

  worker.on('listening', (address) => {
    console.log(`[worker ${worker.id}] listening on ${address.address || '*'}:${address.port}`);
  });

  worker.on('message', (msg) => {
    console.log(`[worker ${worker.id}] message:`, msg);
  });

  worker.on('disconnect', () => {
    console.log(`[worker ${worker.id}] disconnect — IPC channel closed`);
  });

  worker.on('exit', (code, signal) => {
    console.log(`[worker ${worker.id}] exit — code: ${code}, signal: ${signal}`);
  });

  worker.on('error', (err) => {
    console.log(`[worker ${worker.id}] error:`, err.message);
  });

  // ── Cluster-Level Events ───────────────────────────
  cluster.on('fork', (w) => {
    console.log(`[cluster] fork — worker ${w.id} created`);
  });

  cluster.on('online', (w) => {
    console.log(`[cluster] online — worker ${w.id}`);
  });

  cluster.on('listening', (w, address) => {
    console.log(`[cluster] listening — worker ${w.id} on port ${address.port}`);
  });

  cluster.on('disconnect', (w) => {
    console.log(`[cluster] disconnect — worker ${w.id}`);
  });

  cluster.on('exit', (w, code, signal) => {
    console.log(`[cluster] exit — worker ${w.id}, code: ${code}, signal: ${signal}`);
  });

} else {
  // Worker sends a message, then starts a server
  process.send({ status: 'initializing' });

  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('OK\n');
  });

  server.listen(3000, () => {
    process.send({ status: 'ready' });
  });
}
```

---

## IPC Between Primary and Workers

The primary and workers communicate via `worker.send()` / `process.send()` and the `'message'` event. Messages are serialized (JSON by default).

```javascript
'use strict';

const cluster = require('node:cluster');

if (cluster.isPrimary) {
  const worker = cluster.fork();

  // Send a task to the worker
  worker.on('online', () => {
    worker.send({ type: 'task', payload: { numbers: [1, 2, 3, 4, 5] } });
  });

  // Receive the result
  worker.on('message', (msg) => {
    if (msg.type === 'result') {
      console.log(`Primary received result: ${msg.payload.sum}`);
      worker.disconnect(); // Gracefully close the worker
    }
  });

} else {
  // Worker receives tasks from primary
  process.on('message', (msg) => {
    if (msg.type === 'task') {
      console.log(`Worker ${process.pid} processing task...`);
      const sum = msg.payload.numbers.reduce((a, b) => a + b, 0);
      process.send({ type: 'result', payload: { sum } });
    }
  });
}
```

### Broadcasting to All Workers

```javascript
'use strict';

const cluster = require('node:cluster');
const os = require('node:os');

if (cluster.isPrimary) {
  const workerCount = Math.min(os.cpus().length, 4);

  for (let i = 0; i < workerCount; i++) {
    cluster.fork();
  }

  // Wait for all workers to be online, then broadcast
  let onlineCount = 0;
  cluster.on('online', () => {
    onlineCount += 1;
    if (onlineCount === workerCount) {
      console.log('All workers online. Broadcasting config...');
      broadcast({ type: 'config', logLevel: 'info', rateLimit: 100 });
    }
  });

  // Receive acknowledgments
  cluster.on('message', (worker, msg) => {
    if (msg.type === 'ack') {
      console.log(`Worker ${worker.id} acknowledged config`);
    }
  });

  function broadcast(msg) {
    for (const id in cluster.workers) {
      cluster.workers[id].send(msg);
    }
  }

} else {
  process.on('message', (msg) => {
    if (msg.type === 'config') {
      console.log(`Worker ${cluster.worker.id} received config:`, msg);
      process.send({ type: 'ack' });
    }
  });
}
```

---

## Auto-Restart on Crash

Workers can crash due to unhandled exceptions, segfaults, or OOM kills. The primary should detect this and fork a replacement.

```javascript
'use strict';

const cluster = require('node:cluster');
const http = require('node:http');
const os = require('node:os');

if (cluster.isPrimary) {
  const WORKER_COUNT = os.cpus().length;
  let restartCount = 0;
  const MAX_RESTARTS_PER_MINUTE = 20;
  let restartWindow = Date.now();

  console.log(`Primary ${process.pid} forking ${WORKER_COUNT} workers...`);

  for (let i = 0; i < WORKER_COUNT; i++) {
    cluster.fork();
  }

  cluster.on('exit', (worker, code, signal) => {
    console.log(`Worker ${worker.process.pid} died (code: ${code}, signal: ${signal})`);

    // Protect against restart loops (crash → restart → crash → ...)
    const now = Date.now();
    if (now - restartWindow > 60_000) {
      restartCount = 0;
      restartWindow = now;
    }

    restartCount += 1;

    if (restartCount > MAX_RESTARTS_PER_MINUTE) {
      console.error('Too many restarts in one minute. Halting.');
      return;
    }

    // Intentional shutdowns (code 0) should not be restarted
    if (code === 0) {
      console.log('Worker exited cleanly — not restarting.');
      return;
    }

    console.log('Forking replacement worker...');
    cluster.fork();
  });

} else {
  const server = http.createServer((req, res) => {
    // Simulate a crash on a specific route
    if (req.url === '/crash') {
      console.log(`Worker ${process.pid} crashing!`);
      process.exit(1);
    }

    // Simulate an unhandled exception
    if (req.url === '/throw') {
      throw new Error('Unhandled exception in worker');
    }

    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`Worker ${process.pid} OK\n`);
  });

  server.listen(3000, () => {
    console.log(`Worker ${process.pid} listening`);
  });
}
```

---

## Zero-Downtime Rolling Restart

When deploying new code, you want to restart workers one by one so the server is never fully down. This is called a rolling restart or zero-downtime reload.

```javascript
'use strict';

const cluster = require('node:cluster');
const http = require('node:http');
const os = require('node:os');

if (cluster.isPrimary) {
  const WORKER_COUNT = os.cpus().length;

  console.log(`Primary ${process.pid} starting ${WORKER_COUNT} workers`);

  for (let i = 0; i < WORKER_COUNT; i++) {
    cluster.fork();
  }

  // Auto-restart dead workers
  cluster.on('exit', (worker, code) => {
    if (code !== 0 && !worker.exitedAfterDisconnect) {
      console.log(`Worker ${worker.process.pid} crashed — restarting`);
      cluster.fork();
    }
  });

  // Listen for SIGUSR2 to trigger a rolling restart
  process.on('SIGUSR2', () => {
    console.log('\nSIGUSR2 received — starting rolling restart...');
    rollingRestart();
  });

  async function rollingRestart() {
    const workerIds = Object.keys(cluster.workers);

    for (const id of workerIds) {
      const oldWorker = cluster.workers[id];
      if (!oldWorker) continue;

      console.log(`Replacing worker ${id} (PID: ${oldWorker.process.pid})...`);

      // Fork a new worker first
      const newWorker = cluster.fork();

      // Wait for the new worker to be listening before killing the old one
      await new Promise((resolve) => {
        newWorker.on('listening', () => {
          console.log(`  New worker ${newWorker.id} (PID: ${newWorker.process.pid}) is listening`);

          // Gracefully disconnect the old worker
          oldWorker.disconnect();

          // Force kill if it takes too long
          const timeout = setTimeout(() => {
            console.log(`  Force-killing old worker ${id}`);
            oldWorker.process.kill('SIGKILL');
          }, 5000);

          oldWorker.on('exit', () => {
            clearTimeout(timeout);
            console.log(`  Old worker ${id} has exited`);
            resolve();
          });
        });
      });

      // Brief pause between worker replacements to avoid thundering herd
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }

    console.log('Rolling restart complete.\n');
  }

  console.log(`Send SIGUSR2 for rolling restart: kill -USR2 ${process.pid}`);

} else {
  const startTime = Date.now();

  http.createServer((req, res) => {
    const body = JSON.stringify({
      worker: cluster.worker.id,
      pid: process.pid,
      uptime: `${((Date.now() - startTime) / 1000).toFixed(0)}s`,
    });

    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
  }).listen(3000);
}
```

The key insight: fork the new worker **before** killing the old one. This guarantees there is always at least N-1 workers handling requests during the restart.

---

## disconnect vs kill

Three ways to stop a worker:

```javascript
'use strict';

const cluster = require('node:cluster');

if (cluster.isPrimary) {
  const worker = cluster.fork();

  worker.on('online', () => {
    // Option 1: Graceful disconnect
    // Closes the IPC channel. Worker can finish in-flight requests.
    // worker.exitedAfterDisconnect will be true.
    worker.disconnect();

    // Option 2: Send a signal via the worker object
    // Sends SIGTERM by default. Worker can handle the signal.
    // worker.kill();
    // worker.kill('SIGTERM');

    // Option 3: Send a signal directly to the process
    // Bypasses the cluster layer. Use for force-kill.
    // worker.process.kill('SIGKILL');
  });

  worker.on('disconnect', () => {
    console.log(`Worker ${worker.id} disconnected`);
    console.log('exitedAfterDisconnect:', worker.exitedAfterDisconnect);
  });

  worker.on('exit', (code, signal) => {
    console.log(`Worker ${worker.id} exited: code=${code}, signal=${signal}`);
  });
} else {
  // Worker stays alive until disconnected
  console.log(`Worker ${process.pid} running`);
}
```

| Method | Behavior |
|---|---|
| `worker.disconnect()` | Closes IPC channel. Worker finishes in-flight work, then exits. `exitedAfterDisconnect` = `true` |
| `worker.kill(signal)` | Sends a signal (default `SIGTERM`). Worker can handle it gracefully |
| `worker.process.kill('SIGKILL')` | Force-kills immediately. No cleanup possible. Use as last resort |

---

## The Shared State Problem

Workers are separate processes. They do **not** share memory. This means:

- In-memory sessions are local to each worker
- Caches exist independently in each worker
- Global variables are per-process

```javascript
'use strict';

const cluster = require('node:cluster');
const http = require('node:http');

if (cluster.isPrimary) {
  cluster.fork();
  cluster.fork();
} else {
  // Each worker has its OWN counter — they do not share it
  let requestCount = 0;

  http.createServer((req, res) => {
    requestCount += 1;

    const body = JSON.stringify({
      worker: process.pid,
      // This counter is per-worker, not global!
      requestsHandledByThisWorker: requestCount,
    });

    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
  }).listen(3000);
}
```

Solutions for shared state:

| Approach | Tradeoff |
|---|---|
| External store (Redis, database) | Adds latency and a dependency, but scales beyond one machine |
| IPC via primary | Primary becomes a bottleneck if traffic is high |
| Sticky sessions | Ties a client to one worker — defeats load balancing |
| SharedArrayBuffer (worker_threads) | Only works with worker threads, not cluster processes |

---

## Complete Example: Production Clustered Server

```javascript
'use strict';

const cluster = require('node:cluster');
const http = require('node:http');
const os = require('node:os');

const PORT = parseInt(process.env.PORT, 10) || 3000;
const WORKER_COUNT = parseInt(process.env.WORKERS, 10) || os.cpus().length;

if (cluster.isPrimary) {
  // ── Primary Process ──────────────────────────────────
  console.log('='.repeat(50));
  console.log(`Primary process: PID ${process.pid}`);
  console.log(`CPU cores: ${os.cpus().length}`);
  console.log(`Forking ${WORKER_COUNT} workers...`);
  console.log('='.repeat(50));

  const workerStats = new Map();

  for (let i = 0; i < WORKER_COUNT; i++) {
    const worker = cluster.fork();
    workerStats.set(worker.id, { requests: 0, errors: 0, startedAt: Date.now() });
  }

  // Collect stats from workers
  cluster.on('message', (worker, msg) => {
    if (msg.type === 'request-complete') {
      const stats = workerStats.get(worker.id);
      if (stats) stats.requests += 1;
    }
    if (msg.type === 'request-error') {
      const stats = workerStats.get(worker.id);
      if (stats) stats.errors += 1;
    }
  });

  // Auto-restart with crash protection
  let recentCrashes = 0;
  setInterval(() => { recentCrashes = 0; }, 60_000).unref();

  cluster.on('exit', (worker, code, signal) => {
    workerStats.delete(worker.id);

    if (worker.exitedAfterDisconnect) {
      console.log(`Worker ${worker.id} exited gracefully`);
      return;
    }

    console.error(`Worker ${worker.id} crashed (code: ${code}, signal: ${signal})`);
    recentCrashes += 1;

    if (recentCrashes > WORKER_COUNT * 3) {
      console.error('CRITICAL: Too many crashes. Stopping restarts.');
      return;
    }

    const replacement = cluster.fork();
    workerStats.set(replacement.id, { requests: 0, errors: 0, startedAt: Date.now() });
    console.log(`Replacement worker ${replacement.id} forked`);
  });

  // Print stats on SIGUSR2
  process.on('SIGUSR2', () => {
    console.log('\n── Cluster Stats ──');
    for (const [id, stats] of workerStats) {
      const uptime = ((Date.now() - stats.startedAt) / 1000).toFixed(0);
      console.log(`  Worker ${id}: ${stats.requests} requests, ${stats.errors} errors, ${uptime}s uptime`);
    }
    console.log('───────────────────\n');
  });

  // Graceful shutdown
  process.on('SIGTERM', () => {
    console.log('\nSIGTERM received. Shutting down all workers...');
    for (const id in cluster.workers) {
      cluster.workers[id].disconnect();
    }

    setTimeout(() => {
      console.error('Force-killing remaining workers');
      for (const id in cluster.workers) {
        cluster.workers[id].process.kill('SIGKILL');
      }
      process.exit(1);
    }, 10_000);
  });

} else {
  // ── Worker Process ───────────────────────────────────

  process.on('uncaughtException', (err) => {
    console.error(`Worker ${process.pid} uncaught:`, err.message);
    process.send({ type: 'request-error' });
    process.exit(1);
  });

  process.on('unhandledRejection', (reason) => {
    console.error(`Worker ${process.pid} unhandled rejection:`, reason);
    process.send({ type: 'request-error' });
    process.exit(1);
  });

  const server = http.createServer((req, res) => {
    if (req.url === '/health') {
      const body = JSON.stringify({
        status: 'ok',
        pid: process.pid,
        worker: cluster.worker.id,
        memory: process.memoryUsage().rss,
        uptime: process.uptime(),
      });
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      });
      res.end(body);
      process.send({ type: 'request-complete' });
      return;
    }

    // Simulate request processing
    const body = JSON.stringify({
      message: 'Hello from clustered server',
      worker: cluster.worker.id,
      pid: process.pid,
    });

    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
    process.send({ type: 'request-complete' });
  });

  server.listen(PORT, () => {
    console.log(`  Worker ${cluster.worker.id} (PID: ${process.pid}) listening on port ${PORT}`);
  });

  // Graceful shutdown for this worker
  process.on('SIGTERM', () => {
    server.close(() => {
      console.log(`  Worker ${process.pid} drained and exiting`);
      process.exit(0);
    });
  });
}
```

---

## When to Use cluster vs worker_threads

| Feature | `cluster` | `worker_threads` |
|---|---|---|
| Isolation | Full process isolation | Shared process, separate V8 isolates |
| Memory | Separate heaps | Can share memory via `SharedArrayBuffer` |
| Use case | Scale HTTP servers across CPU cores | CPU-intensive computation in parallel |
| Port sharing | Built-in | Not applicable |
| Crash impact | One worker dies, others unaffected | Thread crash can destabilize the process |
| Communication | IPC (JSON serialization) | `MessagePort` (structured clone, transferable) |
| Overhead | Higher (full process per worker) | Lower (shared process resources) |

Use `cluster` when you want to scale an HTTP server. Use `worker_threads` when you need parallel computation within a single application.

---

## Key Takeaways

- A single Node.js process uses one CPU core — `cluster.fork()` spawns worker processes that share a server port, letting you utilize all available cores without modifying request-handling code
- The primary process owns the listening socket and distributes connections to workers using round-robin scheduling (default on Linux/macOS), ensuring even load distribution across workers
- Auto-restart on worker crash is essential for resilience, but you must protect against restart storms — track crashes per time window and stop restarting if the failure rate is too high
- Zero-downtime rolling restarts work by forking a new worker and waiting for it to begin listening before disconnecting the old worker — guaranteeing at least N-1 workers are always available
- Workers do not share memory — any state that must be consistent across workers (sessions, counters, caches) must live in an external store or be coordinated through IPC messages via the primary process

## Next

Continue to [Lesson 08 — OS Module & System Information](lesson-08-os-module.md) where you will explore the `node:os` module for reading CPU details, memory usage, network interfaces, and building system health dashboards.
