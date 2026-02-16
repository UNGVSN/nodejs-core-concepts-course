# Module 09 / Lesson 01 — Thread Fundamentals

> Node.js built its reputation on a single thread and a fast event loop. But "single-threaded" was never the whole story — libuv has always used a thread pool behind the scenes. Starting with Node.js 10, the `worker_threads` module gave JavaScript code direct access to OS-level threads. Before you touch that API, you need to understand what a thread actually is, how it differs from a process, and when parallelism helps versus when it just adds complexity.

## Learning Objectives

- Distinguish between a process and a thread at the operating system level
- Explain the shared memory model of threads and contrast it with the isolated memory of processes
- Define concurrency and parallelism and explain why they are not the same thing
- Identify workloads where threads improve Node.js performance and workloads where they do not
- Describe the thread pool that libuv already manages inside every Node.js process

---

## Processes vs Threads

A **process** is an independent instance of a running program. The operating system gives each process its own virtual address space, file descriptor table, and environment. When you run `node app.js`, the OS creates a process. When you run `node worker.js` in a second terminal, the OS creates a completely separate process. They share nothing by default.

A **thread** is a unit of execution within a process. All threads in the same process share the same virtual address space — the same heap, the same global variables, the same file descriptors. Each thread gets its own stack (for local variables and function call frames), its own program counter (tracking which instruction it is executing), and its own register set. But the heap is communal property.

```javascript
'use strict';

const { Worker, isMainThread, threadId } = require('node:worker_threads');

if (isMainThread) {
  console.log(`Main thread (threadId ${threadId}), PID ${process.pid}`);

  // Spawn a worker thread — same process, same PID
  const worker = new Worker(__filename);

  worker.on('message', (msg) => {
    console.log(`Main received: ${msg}`);
  });

  worker.on('exit', () => {
    console.log('Worker exited');
  });
} else {
  console.log(`Worker thread (threadId ${threadId}), PID ${process.pid}`);

  // Same PID — we are in the same OS process.
  // But we have our own V8 isolate (our own heap, our own stack).
  const { parentPort } = require('node:worker_threads');
  parentPort.postMessage('Hello from the worker');
}
```

Run this script and notice: both threads print the same PID. They live inside the same OS process. But each thread has its own V8 isolate — its own JavaScript heap, its own garbage collector, its own call stack. This is a critical distinction from languages like Java or C++ where threads share a single heap directly.

### The Key Differences

| Aspect | Process | Thread |
|--------|---------|--------|
| Memory | Isolated address space | Shared address space (with caveats in Node.js) |
| Creation cost | High (fork a full process) | Lower (new thread in same process) |
| Communication | IPC (pipes, sockets, message passing) | Shared memory or message passing |
| Crash isolation | One process crash does not kill others | One thread crash can kill the entire process |
| Overhead | Full V8 heap per process (~30-50 MB) | V8 isolate per thread (~10-20 MB) |
| Scheduling | OS schedules processes independently | OS schedules threads within the same process |

In Node.js, the memory picture is nuanced. Each `Worker` thread gets its own V8 isolate with its own heap — so ordinary JavaScript objects are *not* shared. You must explicitly opt into sharing via `SharedArrayBuffer`. This is deliberate: it prevents the data races that plague traditional multithreaded programs.

---

## Shared Memory: The Double-Edged Sword

In C or C++, threads share everything on the heap. If thread A writes to address `0x7FFF0100`, thread B can read that address immediately. This makes communication fast — no copying, no serialization. It also makes programming dangerous: if both threads write to the same address at the same time, the result is undefined.

Node.js takes a conservative approach. Worker threads do not share the V8 heap. Each worker has its own isolated set of JavaScript objects. To share raw memory, you must create a `SharedArrayBuffer` explicitly:

```javascript
'use strict';

const { Worker, isMainThread, workerData } = require('node:worker_threads');

if (isMainThread) {
  // Create a SharedArrayBuffer — raw bytes visible to all threads
  const shared = new SharedArrayBuffer(4); // 4 bytes
  const view = new Int32Array(shared);
  view[0] = 0; // Initial value

  console.log(`Before worker: value = ${view[0]}`);

  const worker = new Worker(__filename, { workerData: { shared } });

  worker.on('exit', () => {
    // The worker modified the shared buffer directly — no message passing
    console.log(`After worker: value = ${view[0]}`);
  });
} else {
  const view = new Int32Array(workerData.shared);
  // Direct memory write — the main thread sees this change
  view[0] = 42;
}
```

This design gives you two communication channels:

1. **Message passing** via `postMessage()` — safe, isolated, involves copying (structured clone)
2. **Shared memory** via `SharedArrayBuffer` — fast, zero-copy, but you are responsible for synchronization

We will explore both in depth in Lessons 03 and 04.

---

## Concurrency vs Parallelism

These terms are often confused. They describe different things.

**Concurrency** means multiple tasks make progress over the same time period. They may not execute simultaneously — they may interleave on a single CPU core. Node.js has always been concurrent: the event loop juggles thousands of I/O callbacks on one thread by interleaving them.

**Parallelism** means multiple tasks execute at the exact same instant on different CPU cores. This requires multiple threads (or multiple processes), and multiple physical cores.

```
Concurrency (single core):          Parallelism (multi-core):
  Task A ██░░██░░                      Core 1: Task A ████████
  Task B ░░██░░██                      Core 2: Task B ████████
  (interleaved on one core)            (simultaneous on two cores)
```

Node.js without worker threads gives you concurrency for free. The event loop handles thousands of I/O-bound tasks concurrently on a single thread. Adding worker threads gives you parallelism — the ability to compute on multiple cores simultaneously.

### An Analogy

A single chef (single thread) can cook multiple dishes concurrently: start the pasta, while it boils, chop vegetables, while they roast, prepare the sauce. The chef is never idle, but only one pair of hands is working at any moment.

Four chefs (four threads) can cook four dishes in parallel: each chef works on their own dish at the same time. Throughput quadruples for CPU-bound work (actual cooking), but coordination becomes necessary to avoid collisions at shared resources (the oven, the sink).

---

## When Threads Help in Node.js

Worker threads improve performance when the bottleneck is CPU computation — work that occupies the call stack and blocks the event loop.

### CPU-Bound Work (Threads Help)

```javascript
'use strict';

// This function blocks the event loop for ~2 seconds
function computePrimes(limit) {
  const primes = [];
  for (let candidate = 2; candidate < limit; candidate++) {
    let isPrime = true;
    for (let divisor = 2; divisor <= Math.sqrt(candidate); divisor++) {
      if (candidate % divisor === 0) {
        isPrime = false;
        break;
      }
    }
    if (isPrime) primes.push(candidate);
  }
  return primes.length;
}

// On the main thread, this blocks everything:
const start = Date.now();
const count = computePrimes(2_000_000);
console.log(`Found ${count} primes in ${Date.now() - start} ms`);
// During those ~2 seconds, no HTTP requests are served,
// no timers fire, no I/O callbacks run.
```

With worker threads, you can offload `computePrimes` to a background thread. The main thread continues serving requests while the worker computes.

### I/O-Bound Work (Threads Do NOT Help)

```javascript
'use strict';

const fs = require('node:fs');

// This is already non-blocking — the event loop handles it.
// Adding worker threads adds overhead without benefit.
fs.readFile('/var/log/syslog', (err, data) => {
  if (err) throw err;
  console.log(`Read ${data.length} bytes`);
});

console.log('This runs immediately — fs.readFile did not block.');
```

I/O operations (`fs.readFile`, `http.request`, DNS lookups, TCP connections) are already handled asynchronously by libuv. They do not block the event loop. Wrapping them in a worker thread just adds the overhead of thread creation and message passing with no benefit.

### The Decision Rule

| Workload Type | Event Loop | Worker Threads |
|--------------|------------|----------------|
| File reads/writes | Already async via libuv | No benefit |
| Network I/O | Already async via event loop | No benefit |
| JSON parsing (small) | Fast enough on main thread | Unnecessary overhead |
| JSON parsing (100MB+) | Blocks the loop | Good candidate |
| Image processing | Blocks the loop | Good candidate |
| Cryptographic hashing | Blocks the loop | Good candidate |
| Regular expression on large input | Blocks the loop | Good candidate |
| Mathematical computation | Blocks the loop | Good candidate |

The rule of thumb: if the work spends most of its time on the call stack (computing), use threads. If it spends most of its time waiting (I/O), the event loop already handles it.

---

## The Hidden Thread Pool: libuv

Even without `worker_threads`, Node.js is not truly single-threaded. libuv maintains a thread pool (default size: 4) for operations that do not have native async support at the OS level:

- **File system operations** (`fs.readFile`, `fs.stat`, `fs.writeFile`)
- **DNS lookups** (`dns.lookup` — but not `dns.resolve`, which uses c-ares)
- **Some crypto operations** (`crypto.pbkdf2`, `crypto.randomBytes` for large sizes)
- **Zlib compression** (when not using streaming)

```javascript
'use strict';

const fs = require('node:fs');
const crypto = require('node:crypto');

// These four operations run on libuv's thread pool simultaneously
// (default pool size is 4, so all four run in parallel)
const start = Date.now();
let completed = 0;

function done(label) {
  completed++;
  console.log(`${label} completed at +${Date.now() - start} ms`);
  if (completed === 4) {
    console.log(`All done at +${Date.now() - start} ms`);
  }
}

fs.readFile(__filename, () => done('readFile'));
fs.stat(__filename, () => done('stat'));
crypto.pbkdf2('password', 'salt', 100000, 64, 'sha512', () => done('pbkdf2'));
crypto.randomBytes(256, () => done('randomBytes'));

console.log('All four operations dispatched to the thread pool');
```

You can control the thread pool size with the `UV_THREADPOOL_SIZE` environment variable:

```bash
UV_THREADPOOL_SIZE=8 node app.js
```

The maximum is 1024, but common production values are 4-16. Setting it too high wastes memory (each thread has a stack); setting it too low creates a bottleneck for file system and DNS operations.

### libuv Thread Pool vs Worker Threads

| Feature | libuv Thread Pool | Worker Threads |
|---------|-------------------|----------------|
| Purpose | Background I/O that lacks OS async support | Your JavaScript code running in parallel |
| Runs JavaScript? | No — runs C/C++ code only | Yes — each worker has a V8 isolate |
| You control it? | Only via `UV_THREADPOOL_SIZE` | Fully — you create, communicate, terminate |
| Memory per thread | Small (C stack only) | Large (V8 isolate ~10-20 MB) |
| Default count | 4 | 0 (you create them explicitly) |

---

## Thread Safety: Why It Matters

When two threads access the same memory location and at least one of them writes, you have a **data race**. The result depends on the exact timing of the two operations — it is nondeterministic.

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const shared = new SharedArrayBuffer(4);
  const view = new Int32Array(shared);
  view[0] = 0;

  const ITERATIONS = 1_000_000;

  // Two workers both incrementing the same shared counter
  const w1 = new Worker(__filename, { workerData: { shared, iterations: ITERATIONS } });
  const w2 = new Worker(__filename, { workerData: { shared, iterations: ITERATIONS } });

  let exited = 0;
  function onExit() {
    exited++;
    if (exited === 2) {
      // Expected: 2,000,000. Actual: some number less than that.
      console.log(`Final value: ${view[0]}`);
      console.log(`Expected:    ${ITERATIONS * 2}`);
      console.log(`Lost updates: ${ITERATIONS * 2 - view[0]}`);
    }
  }

  w1.on('exit', onExit);
  w2.on('exit', onExit);
} else {
  const view = new Int32Array(workerData.shared);
  for (let i = 0; i < workerData.iterations; i++) {
    // This is NOT atomic — read + increment + write can be interrupted
    view[0] = view[0] + 1;
  }
  parentPort.postMessage('done');
}
```

Run this multiple times. The final value will be different each time and almost always less than 2,000,000. This is a classic data race. Lesson 04 and 05 will teach you how to fix it with `Atomics`.

---

## The Cost of Threads

Threads are not free. Each `Worker` in Node.js creates a new V8 isolate with its own heap. Typical overhead:

- **Memory:** 10-20 MB per idle worker (V8 isolate + stack)
- **Startup time:** 50-200 ms to create a worker and start executing JavaScript
- **Communication:** `postMessage` involves structured cloning (deep copy), which can be expensive for large objects

```javascript
'use strict';

const { Worker, isMainThread } = require('node:worker_threads');

if (isMainThread) {
  const before = process.memoryUsage().rss;
  const workers = [];

  // Create 10 workers and measure memory impact
  for (let i = 0; i < 10; i++) {
    workers.push(new Worker(__filename));
  }

  // Wait a moment for workers to initialize
  setTimeout(() => {
    const after = process.memoryUsage().rss;
    const perWorker = (after - before) / 10;
    console.log(`Memory before: ${(before / 1024 / 1024).toFixed(1)} MB`);
    console.log(`Memory after:  ${(after / 1024 / 1024).toFixed(1)} MB`);
    console.log(`Per worker:    ~${(perWorker / 1024 / 1024).toFixed(1)} MB`);

    // Clean up
    for (const w of workers) w.terminate();
  }, 2000);
} else {
  // Worker does nothing — just stays alive
  setTimeout(() => {}, 60_000);
}
```

The takeaway: do not create a new worker for every request. Create a fixed pool of workers (Lesson 06) and reuse them. The optimal pool size is typically the number of CPU cores for CPU-bound work.

---

## How Node.js Worker Threads Differ from Traditional Threads

If you have experience with threads in Java, C++, or Python, Node.js workers will feel both familiar and foreign:

1. **No shared heap by default.** In Java, every thread accesses the same object graph. In Node.js, each worker has its own V8 isolate. You must explicitly create `SharedArrayBuffer` for shared memory.

2. **No thread-local JavaScript objects.** You cannot create a JavaScript object in one thread and access it in another. You can only share raw bytes via `SharedArrayBuffer`.

3. **No mutexes in the standard library.** Traditional threading libraries provide mutexes, semaphores, and condition variables. Node.js provides `Atomics` — low-level atomic operations on typed arrays. You build your own synchronization primitives.

4. **Message passing is first-class.** The primary communication mechanism is `postMessage`, which uses structured cloning (deep copy). This is the safe default path.

5. **Each worker has its own event loop.** A worker thread is not just a computational context — it is a full Node.js environment with its own event loop, timers, and I/O capabilities.

---

## Key Takeaways

- A thread is a unit of execution within a process — threads share the process's address space, while processes are fully isolated
- Concurrency (interleaving tasks on one core) is what the event loop gives you; parallelism (simultaneous execution on multiple cores) requires worker threads or multiple processes
- Worker threads help with CPU-bound work that blocks the event loop; they do not help with I/O-bound work, which the event loop already handles efficiently
- Each Node.js `Worker` gets its own V8 isolate — JavaScript objects are not shared; only raw bytes via `SharedArrayBuffer` can be shared across threads
- Threads have real costs (10-20 MB memory per worker, startup latency, communication overhead) — create a fixed pool and reuse workers rather than spawning per-task

## Next

In the next lesson, we dive into the `worker_threads` API — creating workers, passing initial data with `workerData`, communicating through `parentPort`, and handling the full worker lifecycle.
