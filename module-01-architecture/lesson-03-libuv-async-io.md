# Module 01 / Lesson 03 — libuv and Asynchronous I/O

> V8 compiles your JavaScript, but it knows nothing about files, networks, or the operating system. That is libuv's job. libuv is the C library at the heart of Node.js that provides the event loop, a cross-platform thread pool, and abstractions over every major OS's asynchronous I/O primitives. Every time you call `fs.readFile`, open a TCP socket, or set a timer, libuv is the machinery making it happen.

## Learning Objectives

- Explain libuv's role as the bridge between V8's JavaScript world and the operating system kernel
- Describe how the thread pool works and which operations use it
- Identify the OS-specific async primitives libuv abstracts (epoll, kqueue, IOCP)
- Tune the thread pool size with `UV_THREADPOOL_SIZE` and understand the trade-offs
- Distinguish between operations that use the thread pool and operations that use OS-level async directly

---

## What libuv Does

libuv was originally written for Node.js in 2011 by Bert Belder and Ben Noordhuis to replace libev (which only supported Unix). Today it is a standalone project used by many runtimes and tools.

libuv provides Node.js with:

1. **The event loop** — the central dispatcher that polls for I/O events and invokes callbacks
2. **Async I/O** — wrappers around OS-specific mechanisms for non-blocking network I/O
3. **Thread pool** — a pool of background threads for operations that cannot be made async at the OS level
4. **Timers** — high-resolution timers for `setTimeout` and `setInterval`
5. **Child processes** — spawning and managing subprocesses
6. **Signal handling** — catching POSIX signals like `SIGTERM` and `SIGINT`
7. **DNS resolution** — both thread-pool-based (`dns.lookup`) and async (`dns.resolve`)

Without libuv, V8 would be limited to pure computation — no file access, no networking, no timers.

---

## The Thread Pool

Some operating system APIs are inherently blocking. File system operations on most platforms, DNS lookups via `getaddrinfo`, and certain cryptographic operations cannot be performed asynchronously at the kernel level. libuv handles these by delegating them to a **thread pool**.

### How It Works

```
┌──────────────────────────────────┐
│         Main Thread              │
│     (V8 + Event Loop)           │
│                                  │
│  fs.readFile('data.json', cb)   │
│         │                        │
│         ▼                        │
│  libuv: "This is a file op,     │
│   I'll queue it on the           │
│   thread pool"                   │
│         │                        │
└─────────┼────────────────────────┘
          │
          ▼
┌──────────────────────────────────┐
│        libuv Thread Pool         │
│                                  │
│  Thread 1: [reading data.json]  │
│  Thread 2: [idle]               │
│  Thread 3: [idle]               │
│  Thread 4: [idle]               │
│                                  │
│  When Thread 1 finishes:        │
│  → Push callback to event loop  │
└──────────────────────────────────┘
          │
          ▼
┌──────────────────────────────────┐
│         Main Thread              │
│  Event loop picks up callback   │
│  cb(null, data) runs on main    │
│  thread — NOT on pool thread    │
└──────────────────────────────────┘
```

The thread pool's default size is **4 threads**. This means at most 4 blocking operations can execute concurrently. If you queue 20 file reads simultaneously, the first 4 run in parallel and the remaining 16 wait in a FIFO queue.

### Seeing the Thread Pool in Action

```javascript
'use strict';

const fs = require('node:fs');
const crypto = require('node:crypto');

// Each pbkdf2 call runs on a thread pool thread.
// With 4 threads (default), the first 4 start immediately
// and the 5th waits until one finishes.

const ITERATIONS = 100_000;
const start = Date.now();

for (let i = 1; i <= 8; i++) {
  const taskStart = Date.now();

  crypto.pbkdf2('password', 'salt', ITERATIONS, 64, 'sha512', (err, key) => {
    const elapsed = Date.now() - taskStart;
    const total = Date.now() - start;
    console.log(`Task ${i}: ${elapsed}ms (total: ${total}ms)`);
  });
}

console.log('All 8 tasks queued — main thread is free');
```

Run this and observe the timing. You will see tasks 1-4 finish at roughly the same time (they ran in parallel), and tasks 5-8 finish later (they waited for a free thread). This is concrete proof that the thread pool has a fixed size.

---

## Operations That Use the Thread Pool

Not every async operation in Node.js uses the thread pool. This distinction is critical for understanding performance:

### Thread Pool Operations (Blocking at OS Level)

| Category | Examples |
|----------|----------|
| File system | `fs.readFile`, `fs.writeFile`, `fs.stat`, `fs.readdir`, `fs.open` |
| DNS | `dns.lookup` (uses `getaddrinfo`, which is blocking) |
| Crypto | `crypto.pbkdf2`, `crypto.scrypt`, `crypto.randomBytes` (large) |
| Zlib | `zlib.deflate`, `zlib.gzip`, `zlib.inflate` |

### OS-Level Async Operations (No Thread Pool)

| Category | Examples |
|----------|----------|
| Network I/O | TCP sockets, UDP sockets, HTTP connections |
| DNS | `dns.resolve`, `dns.resolve4` (uses c-ares, truly async) |
| Timers | `setTimeout`, `setInterval`, `setImmediate` |
| Signals | `process.on('SIGTERM', ...)` |
| Child processes | `child_process.spawn` (notification is async) |

```javascript
'use strict';

const dns = require('node:dns');

const start = Date.now();

// dns.lookup uses the thread pool (getaddrinfo is blocking)
dns.lookup('nodejs.org', (err, address) => {
  console.log(`dns.lookup:  ${address} — ${Date.now() - start}ms (thread pool)`);
});

// dns.resolve uses c-ares (truly async, no thread pool)
dns.resolve4('nodejs.org', (err, addresses) => {
  console.log(`dns.resolve: ${addresses?.[0]} — ${Date.now() - start}ms (OS async via c-ares)`);
});

console.log(`Both queued at ${Date.now() - start}ms — main thread free`);
```

This is why `dns.resolve` is sometimes recommended over `dns.lookup` in high-throughput servers — it does not consume a thread pool slot.

---

## OS-Specific Async Primitives

libuv abstracts away the differences between operating systems. Under the hood, it uses the most efficient async I/O mechanism available on each platform:

| OS | Mechanism | How It Works |
|----|-----------|-------------|
| **Linux** | `epoll` | Kernel monitors file descriptors; notifies when any are ready for I/O |
| **macOS / BSD** | `kqueue` | Similar to epoll; kernel-level event notification queue |
| **Windows** | IOCP (I/O Completion Ports) | Completion-based model; kernel notifies when I/O is *finished*, not just ready |

All three mechanisms allow a single thread to monitor thousands of file descriptors simultaneously. This is the technical foundation of Node.js's concurrency model — the event loop thread asks the OS to watch all active sockets, and the OS notifies it when data arrives.

```javascript
'use strict';

const net = require('node:net');

// Create a TCP server that handles many concurrent connections
// using a SINGLE thread — libuv uses epoll/kqueue/IOCP internally
const server = net.createServer((socket) => {
  socket.on('data', (chunk) => {
    // This fires on the main thread when the OS notifies
    // libuv that data is available on this socket
    socket.write(`Echo: ${chunk}`);
  });

  socket.on('end', () => {
    console.log('Client disconnected');
  });
});

server.listen(4000, () => {
  console.log('TCP echo server on port 4000');
  console.log(`Platform: ${process.platform}`);
  console.log(`This server uses ONE thread for ALL connections`);
  console.log(`libuv uses ${process.platform === 'linux' ? 'epoll' : process.platform === 'darwin' ? 'kqueue' : 'IOCP'} under the hood`);
});
```

You could connect 10,000 clients to this server and it would handle them all on a single thread, because network I/O goes through the OS's async mechanism — not the thread pool.

---

## Tuning UV_THREADPOOL_SIZE

The default thread pool of 4 threads is a conservative default. For applications that perform many concurrent blocking operations (heavy file I/O, many DNS lookups via `dns.lookup`, crypto operations), you may need to increase it.

### Setting the Pool Size

```javascript
'use strict';

// UV_THREADPOOL_SIZE must be set BEFORE the event loop starts.
// The safest way is via environment variable:
//   UV_THREADPOOL_SIZE=16 node script.js

// You can also set it programmatically, but ONLY at the very top
// of your entry file, before any async operation:
// process.env.UV_THREADPOOL_SIZE = '16';
// (This works because libuv reads it lazily on first use)

const crypto = require('node:crypto');

const poolSize = process.env.UV_THREADPOOL_SIZE || '4';
console.log(`Thread pool size: ${poolSize}`);
console.log(`Queuing 16 crypto operations...\n`);

const start = Date.now();

for (let i = 1; i <= 16; i++) {
  const taskStart = Date.now();
  crypto.pbkdf2('password', 'salt', 100_000, 64, 'sha512', (err, key) => {
    const elapsed = Date.now() - taskStart;
    console.log(`Task ${String(i).padStart(2)}: ${elapsed}ms`);
  });
}
```

Run this twice:

```bash
# Default: 4 threads — tasks complete in 4 batches
node pool-size-demo.js

# 16 threads — all 16 tasks run concurrently
UV_THREADPOOL_SIZE=16 node pool-size-demo.js
```

### Trade-offs of Increasing Pool Size

| Pool Size | Pros | Cons |
|-----------|------|------|
| 4 (default) | Low memory, minimal context switching | Bottleneck under heavy file/DNS/crypto load |
| 16-32 | Handles moderate concurrency well | ~2 MB stack per thread; OS context switching |
| 64-128 | Maximum throughput for blocking ops | Significant memory; diminishing returns |
| 128+ | Rarely beneficial | OS scheduling overhead exceeds gains |

**The valid range is 1 to 1024.** Setting it higher than the number of concurrent blocking operations is wasteful. Setting it lower creates artificial bottlenecks.

---

## The Bridge Architecture

The complete call path from JavaScript to the kernel looks like this:

```
Your JavaScript Code
       │
       ▼
    V8 Engine
  (compiles + executes JS)
       │
       ▼
  C++ Bindings (node_file.cc, node_crypto.cc, etc.)
  (translate JS objects ↔ C++ structures)
       │
       ├──── Network I/O ────→ libuv ────→ epoll/kqueue/IOCP ────→ Kernel
       │                        (no thread pool)
       │
       └──── File I/O ──────→ libuv ────→ Thread Pool ────→ POSIX read/write ────→ Kernel
             DNS lookup           (uses pool thread)
             Crypto
             Zlib
```

```javascript
'use strict';

const fs = require('node:fs');
const net = require('node:net');

// --- File I/O: goes through the thread pool ---
console.time('file-read');
fs.readFile(__filename, (err, data) => {
  console.timeEnd('file-read');
  console.log(`File read: ${data.length} bytes (via thread pool)`);
});

// --- Network I/O: goes through OS async directly ---
const server = net.createServer((socket) => {
  socket.end('hello\n');
});

server.listen(0, () => {
  const { port } = server.address();
  console.log(`Server on port ${port} (via OS async — no thread pool)`);

  // Connect to ourselves to prove network I/O works
  const client = net.connect(port, () => {
    client.on('data', (chunk) => {
      console.log(`Received: ${chunk.toString().trim()} (via OS async)`);
      client.end();
      server.close();
    });
  });
});
```

---

## libuv Handles and Requests

libuv uses two fundamental abstractions:

**Handles** represent long-lived objects that perform operations over time:
- TCP servers (`uv_tcp_t`)
- Timers (`uv_timer_t`)
- Signals (`uv_signal_t`)
- File system watchers (`uv_fs_event_t`)

**Requests** represent short-lived operations:
- A single file read (`uv_fs_t`)
- A single DNS lookup (`uv_getaddrinfo_t`)
- A single write to a socket (`uv_write_t`)

The event loop keeps running as long as there are active handles or pending requests. When all handles are closed and all requests are complete, the event loop exits and the Node.js process terminates.

```javascript
'use strict';

// This script demonstrates handle lifetime.
// The event loop exits when the last handle is closed.

const net = require('node:net');

const server = net.createServer();
server.listen(0, () => {
  const { port } = server.address();
  console.log(`Server listening on port ${port}`);
  console.log('The event loop will keep running because the server handle is active.');

  // Close the server after 2 seconds
  setTimeout(() => {
    server.close(() => {
      console.log('Server handle closed.');
      console.log('No more active handles — event loop will exit.');
    });
  }, 2000);

  // This timer is also a handle — it keeps the loop alive for 2 seconds
  console.log('Timer handle active for 2 seconds...');
});
```

Run this and notice the process exits exactly when all handles (server + timer) are closed. The event loop has nothing left to wait for.

---

## Monitoring the Thread Pool

In production, a saturated thread pool is a silent performance killer. You can detect it by measuring the time between queuing an operation and when it starts executing:

```javascript
'use strict';

const fs = require('node:fs');

// Measure thread pool queueing delay by timing how long
// a simple fs.stat takes under different levels of contention

function measurePoolLatency(concurrency) {
  return new Promise((resolve) => {
    const results = [];
    let completed = 0;

    for (let i = 0; i < concurrency; i++) {
      const start = process.hrtime.bigint();

      fs.stat(__filename, (err, stats) => {
        const elapsed = Number(process.hrtime.bigint() - start) / 1e6;
        results.push(elapsed);
        completed++;

        if (completed === concurrency) {
          results.sort((a, b) => a - b);
          const p50 = results[Math.floor(results.length * 0.5)];
          const p99 = results[Math.floor(results.length * 0.99)];
          const max = results[results.length - 1];
          console.log(
            `Concurrency ${String(concurrency).padStart(3)}: ` +
            `p50=${p50.toFixed(2)}ms  p99=${p99.toFixed(2)}ms  max=${max.toFixed(2)}ms`
          );
          resolve();
        }
      });
    }
  });
}

async function main() {
  console.log(`Thread pool size: ${process.env.UV_THREADPOOL_SIZE || 4}\n`);

  // Gradually increase contention
  await measurePoolLatency(1);
  await measurePoolLatency(4);
  await measurePoolLatency(16);
  await measurePoolLatency(64);
  await measurePoolLatency(256);
}

main();
```

Run with the default pool size and then with a larger pool:

```bash
node pool-latency.js
UV_THREADPOOL_SIZE=64 node pool-latency.js
```

You will see p99 latency climb dramatically under contention with the default pool size. This is the kind of insight that prevents production incidents.

---

## Key Takeaways

- libuv is the C library that gives Node.js its async I/O capabilities — it provides the event loop, thread pool, and cross-platform abstractions over epoll, kqueue, and IOCP
- The thread pool (default 4 threads) handles operations that are blocking at the OS level: file system operations, `dns.lookup`, crypto, and zlib
- Network I/O bypasses the thread pool entirely — it uses OS-level async primitives, which is why Node.js can handle thousands of concurrent connections on a single thread
- Tune `UV_THREADPOOL_SIZE` based on your workload, but always profile first — most applications never saturate the default pool
- The event loop exits when there are no active handles or pending requests — understanding this lifecycle prevents both premature exits and zombie processes

## Next

With V8 and libuv covered, the next lesson dives into the event loop itself — the six phases that determine exactly when your callbacks, timers, and I/O handlers execute.
