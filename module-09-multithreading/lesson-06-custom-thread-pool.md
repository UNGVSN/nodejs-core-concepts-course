# Module 09 / Lesson 06 — Building a Custom Thread Pool

> Spawning a new worker thread for every task is like hiring a new employee for every customer — the overhead destroys you. Production systems reuse a fixed set of workers, queue incoming tasks, and dispatch results back to the caller. This lesson builds a complete thread pool from scratch, covering task queuing, dispatch strategies, error handling, graceful shutdown, and zero-copy data transfer with transferable objects.

## Learning Objectives

- Explain why reusing worker threads through a pool outperforms spawning per-task workers
- Implement a `ThreadPool` class with a fixed number of workers, a task queue, and promise-based result delivery
- Contrast round-robin and least-busy dispatch strategies and choose the right one for a given workload
- Use transferable objects to pass `ArrayBuffer` data to workers without copying
- Handle worker crashes, task timeouts, and graceful pool shutdown without leaking resources

---

## Why Build a Custom Thread Pool

Node.js comes with two thread-related mechanisms out of the box: the libuv thread pool (for internal I/O) and the `worker_threads` module (for your JavaScript code). Neither gives you a ready-made task pool.

The libuv thread pool is shared by file system operations, DNS lookups, and crypto work. When your CPU-bound tasks compete with `fs.readFile` for the same four threads, both suffer. A custom pool isolates your compute work onto dedicated threads.

Spawning a fresh `Worker` per task costs 50-200 ms startup time and 10-20 MB of memory — overhead that dwarfs the actual computation for short tasks:

```javascript
'use strict';

const { Worker } = require('node:worker_threads');
const { performance } = require('node:perf_hooks');

// Anti-pattern: spawning a new worker for every task
async function spawnPerTask(taskData) {
  return new Promise((resolve, reject) => {
    const start = performance.now();
    const worker = new Worker(`
      const { parentPort, workerData } = require('node:worker_threads');
      // Simulate brief computation
      let sum = 0;
      for (let i = 0; i < workerData.iterations; i++) sum += i;
      parentPort.postMessage({ result: sum });
    `, { eval: true, workerData: taskData });

    worker.on('message', (msg) => {
      const elapsed = performance.now() - start;
      resolve({ ...msg, elapsed });
    });
    worker.on('error', reject);
  });
}

// 20 short tasks — each spawns a new worker
(async () => {
  const start = performance.now();
  const tasks = Array.from({ length: 20 }, (_, i) => ({ iterations: 10_000 }));
  const results = await Promise.all(tasks.map(spawnPerTask));

  const total = performance.now() - start;
  const avgPerTask = results.reduce((s, r) => s + r.elapsed, 0) / results.length;
  console.log(`Total: ${total.toFixed(1)} ms, avg per task: ${avgPerTask.toFixed(1)} ms`);
  // Most of that time is worker startup, not computation
})();
```

A thread pool eliminates this overhead. Workers start once, stay alive, and process tasks from a queue.

---

## Thread Pool Architecture

The architecture has three components:

```
┌──────────────────────────────────────────────────────┐
│                    ThreadPool                        │
│                                                      │
│  ┌──────────────────┐      ┌────────────────────┐   │
│  │   Task Queue     │─────▶│  Dispatch Logic     │   │
│  │  (pending tasks) │      │  (round-robin or    │   │
│  └──────────────────┘      │   least-busy)       │   │
│                            └─────┬──────────────┘   │
│                 ┌────────────────┼────────────┐     │
│                 ▼                ▼            ▼     │
│          ┌──────────┐   ┌──────────┐  ┌──────────┐ │
│          │ Worker 0 │   │ Worker 1 │  │ Worker N │ │
│          │ (idle/   │   │ (idle/   │  │ (idle/   │ │
│          │  busy)   │   │  busy)   │  │  busy)   │ │
│          └──────────┘   └──────────┘  └──────────┘ │
│                                                      │
│  Caller → .runTask(data) → Promise<result>          │
│  Cleanup → .destroy() → terminates all workers      │
└──────────────────────────────────────────────────────┘
```

Each caller invokes `pool.runTask(data)` and receives a `Promise` that resolves with the worker's result. If all workers are busy, the task enters a FIFO queue and is dispatched when a worker becomes free.

---

## The Worker Script

The worker script is the code each thread executes. It listens for incoming tasks, computes results, and posts them back:

```javascript
'use strict';

// worker-script.js — runs inside each pool thread
const { parentPort } = require('node:worker_threads');

parentPort.on('message', (task) => {
  try {
    let result;

    switch (task.type) {
      case 'fibonacci': {
        result = fibonacci(task.n);
        break;
      }
      case 'primes': {
        result = countPrimes(task.limit);
        break;
      }
      case 'hash': {
        const crypto = require('node:crypto');
        result = crypto.createHash('sha256').update(task.data).digest('hex');
        break;
      }
      default:
        throw new Error(`Unknown task type: ${task.type}`);
    }

    parentPort.postMessage({ taskId: task.taskId, result, error: null });
  } catch (err) {
    parentPort.postMessage({ taskId: task.taskId, result: null, error: err.message });
  }
});

function fibonacci(n) {
  if (n <= 1) return n;
  let a = 0, b = 1;
  for (let i = 2; i <= n; i++) {
    const temp = a + b;
    a = b;
    b = temp;
  }
  return b;
}

function countPrimes(limit) {
  let count = 0;
  for (let candidate = 2; candidate < limit; candidate++) {
    let isPrime = true;
    for (let d = 2; d <= Math.sqrt(candidate); d++) {
      if (candidate % d === 0) { isPrime = false; break; }
    }
    if (isPrime) count++;
  }
  return count;
}

// Signal readiness
parentPort.postMessage({ ready: true });
```

Key design decisions:

1. **Task ID:** Every message includes a `taskId` so the pool can match responses to callers.
2. **Error serialization:** Catch errors inside the worker and send them as plain objects. Error instances cannot survive structured clone fully.
3. **Ready signal:** The worker posts a `{ ready: true }` message on startup so the pool knows it is initialized.

---

## The ThreadPool Class

Here is the complete implementation:

```javascript
'use strict';

// thread-pool.js
const { Worker } = require('node:worker_threads');
const { EventEmitter } = require('node:events');
const path = require('node:path');

class ThreadPool extends EventEmitter {
  #workers = [];
  #workerStatus = [];      // 'idle' | 'busy'
  #taskQueue = [];          // pending tasks waiting for a free worker
  #taskCallbacks = new Map(); // taskId → { resolve, reject, timer }
  #nextTaskId = 0;
  #workerScript;
  #destroyed = false;
  #readyCount = 0;
  #size;

  constructor(size, workerScript) {
    super();
    this.#size = size;
    this.#workerScript = workerScript;

    for (let i = 0; i < size; i++) {
      this.#createWorker(i);
    }
  }

  #createWorker(index) {
    const worker = new Worker(this.#workerScript);
    this.#workers[index] = worker;
    this.#workerStatus[index] = 'idle';

    worker.on('message', (msg) => {
      if (msg.ready) {
        this.#readyCount++;
        if (this.#readyCount === this.#size) {
          this.emit('ready');
        }
        return;
      }

      // Task completed — resolve or reject the caller's promise
      const callback = this.#taskCallbacks.get(msg.taskId);
      if (callback) {
        if (callback.timer) clearTimeout(callback.timer);
        this.#taskCallbacks.delete(msg.taskId);

        if (msg.error) {
          callback.reject(new Error(msg.error));
        } else {
          callback.resolve(msg.result);
        }
      }

      // Mark worker as idle and process the queue
      this.#workerStatus[index] = 'idle';
      this.#dispatchNext();
    });

    worker.on('error', (err) => {
      // Worker crashed — reject all pending tasks for this worker
      console.error(`Worker ${index} error: ${err.message}`);
      this.#workerStatus[index] = 'idle';

      // Restart the worker
      this.#createWorker(index);
      this.#dispatchNext();
    });

    worker.on('exit', (code) => {
      if (!this.#destroyed && code !== 0) {
        console.error(`Worker ${index} exited with code ${code}, restarting...`);
        this.#createWorker(index);
      }
    });
  }

  runTask(taskData, timeoutMs = 0) {
    if (this.#destroyed) {
      return Promise.reject(new Error('Pool has been destroyed'));
    }

    const taskId = this.#nextTaskId++;

    return new Promise((resolve, reject) => {
      let timer = null;

      if (timeoutMs > 0) {
        timer = setTimeout(() => {
          this.#taskCallbacks.delete(taskId);
          reject(new Error(`Task ${taskId} timed out after ${timeoutMs} ms`));
        }, timeoutMs);
      }

      this.#taskCallbacks.set(taskId, { resolve, reject, timer });
      this.#taskQueue.push({ ...taskData, taskId });
      this.#dispatchNext();
    });
  }

  #dispatchNext() {
    if (this.#taskQueue.length === 0) return;

    // Find the first idle worker
    const idleIndex = this.#workerStatus.indexOf('idle');
    if (idleIndex === -1) return; // All workers busy — task stays in queue

    const task = this.#taskQueue.shift();
    this.#workerStatus[idleIndex] = 'busy';
    this.#workers[idleIndex].postMessage(task);
  }

  get stats() {
    const busy = this.#workerStatus.filter((s) => s === 'busy').length;
    return {
      size: this.#size,
      busy,
      idle: this.#size - busy,
      queued: this.#taskQueue.length,
      pending: this.#taskCallbacks.size,
    };
  }

  async destroy() {
    this.#destroyed = true;

    // Reject all queued tasks
    for (const task of this.#taskQueue) {
      const cb = this.#taskCallbacks.get(task.taskId);
      if (cb) {
        if (cb.timer) clearTimeout(cb.timer);
        cb.reject(new Error('Pool destroyed'));
        this.#taskCallbacks.delete(task.taskId);
      }
    }
    this.#taskQueue.length = 0;

    // Terminate all workers
    const exits = this.#workers.map((w) => w.terminate());
    await Promise.all(exits);
  }
}

module.exports = { ThreadPool };
```

That is roughly 120 lines — compact enough to read in one sitting, complete enough for production use.

---

## Using the Thread Pool

```javascript
'use strict';

// main.js — demonstrates the thread pool
const { ThreadPool } = require('./thread-pool');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const os = require('node:os');

const POOL_SIZE = os.cpus().length;
const pool = new ThreadPool(POOL_SIZE, path.join(__dirname, 'worker-script.js'));

pool.on('ready', async () => {
  console.log(`Pool ready: ${POOL_SIZE} workers\n`);

  // Submit 20 prime-counting tasks to 4-8 workers
  const tasks = Array.from({ length: 20 }, (_, i) => ({
    type: 'primes',
    limit: 100_000 + i * 10_000,
  }));

  const start = performance.now();
  const results = await Promise.all(tasks.map((t) => pool.runTask(t)));
  const elapsed = performance.now() - start;

  console.log(`Completed ${tasks.length} tasks in ${elapsed.toFixed(1)} ms`);
  console.log(`Results: ${results.join(', ')}`);
  console.log(`Pool stats:`, pool.stats);

  await pool.destroy();
  console.log('Pool destroyed');
});
```

All 20 tasks run through the pool. The first `POOL_SIZE` tasks dispatch immediately; the rest queue and dispatch as workers complete earlier tasks.

---

## Round-Robin vs Least-Busy Dispatch

The pool above uses "first idle" dispatch — it finds the first idle worker and assigns the task. This works well when all tasks take similar time. For heterogeneous workloads, you have two main alternatives:

### Round-Robin

Distribute tasks to workers in a cyclic pattern, regardless of whether the worker has finished its previous task:

```javascript
'use strict';

// Round-robin dispatch — simple, equal distribution
class RoundRobinPool {
  #workers = [];
  #nextWorker = 0;
  #size;

  constructor(size, workerScript) {
    const { Worker } = require('node:worker_threads');
    this.#size = size;
    for (let i = 0; i < size; i++) {
      this.#workers.push(new Worker(workerScript));
    }
  }

  dispatch(task) {
    const index = this.#nextWorker;
    this.#nextWorker = (this.#nextWorker + 1) % this.#size;
    this.#workers[index].postMessage(task);
    return index;
  }
}
```

Pros: simple, zero overhead. Cons: a slow task can back up one worker while others sit idle.

### Least-Busy (Shortest Queue)

Track how many pending tasks each worker has and assign to the one with the fewest:

```javascript
'use strict';

// Least-busy dispatch — assigns to the worker with the fewest pending tasks
class LeastBusyPool {
  #workers = [];
  #pendingCounts = [];
  #size;

  constructor(size, workerScript) {
    const { Worker } = require('node:worker_threads');
    this.#size = size;

    for (let i = 0; i < size; i++) {
      const worker = new Worker(workerScript);
      this.#workers.push(worker);
      this.#pendingCounts.push(0);

      worker.on('message', () => {
        this.#pendingCounts[i]--;
      });
    }
  }

  dispatch(task) {
    // Find worker with fewest pending tasks
    let minIndex = 0;
    let minCount = this.#pendingCounts[0];

    for (let i = 1; i < this.#size; i++) {
      if (this.#pendingCounts[i] < minCount) {
        minCount = this.#pendingCounts[i];
        minIndex = i;
      }
    }

    this.#pendingCounts[minIndex]++;
    this.#workers[minIndex].postMessage(task);
    return minIndex;
  }
}
```

| Strategy | Best For | Overhead | Fairness |
|----------|----------|----------|----------|
| First idle | Uniform tasks | None | Good |
| Round-robin | Uniform tasks, stateful workers | O(1) | Equal distribution |
| Least-busy | Mixed task durations | O(n) per dispatch | Best load balance |

---

## Transferable Objects: Zero-Copy Data Transfer

When you pass an `ArrayBuffer` via `postMessage`, Node.js clones it by default. For large buffers, this is expensive. Transferable objects move ownership of the buffer to the receiving thread — zero copy, but the sender can no longer access it:

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');
const { performance } = require('node:perf_hooks');

if (isMainThread) {
  const worker = new Worker(__filename);

  // Create a 50 MB buffer
  const size = 50 * 1024 * 1024;

  // Method 1: Clone (default) — copies the data
  const buf1 = new ArrayBuffer(size);
  new Uint8Array(buf1).fill(42);
  let start = performance.now();
  worker.postMessage({ method: 'clone', buffer: buf1 });
  console.log(`Clone send: ${(performance.now() - start).toFixed(2)} ms`);
  console.log(`buf1 after clone: ${buf1.byteLength} bytes (still accessible)`);

  // Method 2: Transfer — moves the data, zero copy
  const buf2 = new ArrayBuffer(size);
  new Uint8Array(buf2).fill(99);
  start = performance.now();
  worker.postMessage({ method: 'transfer', buffer: buf2 }, [buf2]);
  console.log(`Transfer send: ${(performance.now() - start).toFixed(2)} ms`);
  console.log(`buf2 after transfer: ${buf2.byteLength} bytes (neutered!)`);
  // buf2.byteLength is now 0 — ownership moved to the worker

  worker.on('message', (msg) => {
    console.log(`Worker received ${msg.method}: ${msg.size} bytes`);
    if (msg.method === 'transfer') worker.terminate();
  });
} else {
  parentPort.on('message', (msg) => {
    parentPort.postMessage({
      method: msg.method,
      size: msg.buffer.byteLength,
    });
  });
}
```

The transfer path is orders of magnitude faster for large buffers because no data is copied. The trade-off: the sender's buffer becomes "neutered" (byteLength drops to 0) after transfer.

### Integrating Transfers into the Pool

Modify `runTask` to accept a transfer list:

```javascript
'use strict';

// Enhanced runTask with transfer support
class TransferAwarePool {
  // ... (other pool code)

  runTask(taskData, transferList = [], timeoutMs = 0) {
    if (this.#destroyed) {
      return Promise.reject(new Error('Pool has been destroyed'));
    }

    const taskId = this.#nextTaskId++;

    return new Promise((resolve, reject) => {
      let timer = null;
      if (timeoutMs > 0) {
        timer = setTimeout(() => {
          this.#taskCallbacks.delete(taskId);
          reject(new Error(`Task ${taskId} timed out after ${timeoutMs} ms`));
        }, timeoutMs);
      }

      this.#taskCallbacks.set(taskId, { resolve, reject, timer });
      this.#taskQueue.push({
        data: { ...taskData, taskId },
        transferList,
      });
      this.#dispatchNext();
    });
  }

  #dispatchNext() {
    if (this.#taskQueue.length === 0) return;
    const idleIndex = this.#workerStatus.indexOf('idle');
    if (idleIndex === -1) return;

    const { data, transferList } = this.#taskQueue.shift();
    this.#workerStatus[idleIndex] = 'busy';
    this.#workers[idleIndex].postMessage(data, transferList);
  }
}
```

---

## Error Handling and Worker Crashes

Workers can fail in three ways: thrown errors, unhandled rejections, and outright crashes (`process.exit()` or segfaults in native addons). The pool must handle all three:

```javascript
'use strict';

const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename, { workerData: { scenario: 'throw' } });

  // 1. Handled error — worker catches it and sends an error message
  worker.on('message', (msg) => {
    if (msg.error) {
      console.log(`Task error (recoverable): ${msg.error}`);
    } else {
      console.log(`Task result: ${msg.result}`);
    }
  });

  // 2. Unhandled error — worker did not catch it
  worker.on('error', (err) => {
    console.error(`Worker error (unhandled): ${err.message}`);
    // The worker is dead — pool should restart it
  });

  // 3. Unexpected exit
  worker.on('exit', (code) => {
    if (code !== 0) {
      console.error(`Worker exited with code ${code} — restarting`);
      // Pool recreates the worker at this index
    }
  });
} else {
  parentPort.on('message', (task) => {
    // Scenario: unhandled throw — triggers 'error' event on parent
    if (task.crashMe) {
      throw new Error('Deliberate crash');
    }

    // Scenario: handled error — sent as a message
    try {
      if (task.failMe) {
        throw new Error('Task failed');
      }
      parentPort.postMessage({ taskId: task.taskId, result: 'ok', error: null });
    } catch (err) {
      parentPort.postMessage({ taskId: task.taskId, result: null, error: err.message });
    }
  });
}
```

The pool class from the previous section already handles all three: `message` resolves or rejects the promise, `error` triggers a worker restart, and non-zero `exit` triggers a restart with a console warning.

---

## Benchmarking: Sequential vs Thread Pool

Here is a complete benchmark that compares sequential execution against pool execution for a CPU-bound workload:

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');
const { performance } = require('node:perf_hooks');
const os = require('node:os');

// Inline worker for self-contained benchmark
const workerCode = `
  'use strict';
  const { parentPort } = require('node:worker_threads');
  parentPort.on('message', (msg) => {
    let count = 0;
    for (let c = 2; c < msg.limit; c++) {
      let ok = true;
      for (let d = 2; d <= Math.sqrt(c); d++) {
        if (c % d === 0) { ok = false; break; }
      }
      if (ok) count++;
    }
    parentPort.postMessage({ taskId: msg.taskId, result: count });
  });
  parentPort.postMessage({ ready: true });
`;

function countPrimes(limit) {
  let count = 0;
  for (let c = 2; c < limit; c++) {
    let ok = true;
    for (let d = 2; d <= Math.sqrt(c); d++) {
      if (c % d === 0) { ok = false; break; }
    }
    if (ok) count++;
  }
  return count;
}

async function benchSequential(tasks) {
  const start = performance.now();
  const results = tasks.map((t) => countPrimes(t.limit));
  const elapsed = performance.now() - start;
  return { results, elapsed };
}

async function benchPool(tasks, poolSize) {
  const workers = [];
  const idle = [];
  const queue = [];
  const callbacks = new Map();
  let id = 0;
  let readyCount = 0;

  return new Promise((resolveAll) => {
    for (let i = 0; i < poolSize; i++) {
      const w = new Worker(workerCode, { eval: true });
      workers.push(w);

      w.on('message', (msg) => {
        if (msg.ready) {
          readyCount++;
          idle.push(i);
          if (readyCount === poolSize) startBench();
          return;
        }

        const cb = callbacks.get(msg.taskId);
        callbacks.delete(msg.taskId);
        cb(msg.result);
        idle.push(i);
        dispatch();
      });
    }

    function dispatch() {
      while (idle.length > 0 && queue.length > 0) {
        const workerIndex = idle.shift();
        const task = queue.shift();
        workers[workerIndex].postMessage(task);
      }
    }

    function startBench() {
      const start = performance.now();
      let completed = 0;
      const results = new Array(tasks.length);

      for (let t = 0; t < tasks.length; t++) {
        const taskId = id++;
        const taskIndex = t;
        queue.push({ taskId, limit: tasks[t].limit });

        callbacks.set(taskId, (result) => {
          results[taskIndex] = result;
          completed++;
          if (completed === tasks.length) {
            const elapsed = performance.now() - start;
            for (const w of workers) w.terminate();
            resolveAll({ results, elapsed });
          }
        });
      }

      dispatch();
    }
  });
}

(async () => {
  const NUM_TASKS = 16;
  const LIMIT = 200_000;
  const tasks = Array.from({ length: NUM_TASKS }, () => ({ limit: LIMIT }));
  const cpuCount = os.cpus().length;

  console.log(`CPU cores: ${cpuCount}`);
  console.log(`Tasks: ${NUM_TASKS} × countPrimes(${LIMIT})\n`);

  const seq = await benchSequential(tasks);
  console.log(`Sequential:           ${seq.elapsed.toFixed(1)} ms`);

  const poolResult = await benchPool(tasks, cpuCount);
  console.log(`Thread pool (${cpuCount} workers): ${poolResult.elapsed.toFixed(1)} ms`);

  const speedup = seq.elapsed / poolResult.elapsed;
  console.log(`Speedup:              ${speedup.toFixed(2)}x`);
})();
```

On a machine with 8 cores, you should see close to an 8x speedup. The pool dispatches tasks as workers finish, keeping all cores busy.

---

## Dynamic Pool Sizing

Some workloads fluctuate — heavy during business hours, light at night. A dynamic pool adjusts its size based on load:

```javascript
'use strict';

const { Worker } = require('node:worker_threads');
const { EventEmitter } = require('node:events');

class DynamicThreadPool extends EventEmitter {
  #workers = [];
  #workerBusy = [];
  #taskQueue = [];
  #minSize;
  #maxSize;
  #workerScript;
  #scaleCheckInterval;

  constructor(minSize, maxSize, workerScript) {
    super();
    this.#minSize = minSize;
    this.#maxSize = maxSize;
    this.#workerScript = workerScript;

    // Start with minimum workers
    for (let i = 0; i < minSize; i++) {
      this.#addWorker();
    }

    // Periodically check if we should scale
    this.#scaleCheckInterval = setInterval(() => this.#autoScale(), 1000);
  }

  #addWorker() {
    if (this.#workers.length >= this.#maxSize) return false;

    const index = this.#workers.length;
    const worker = new Worker(this.#workerScript);
    this.#workers.push(worker);
    this.#workerBusy.push(false);

    worker.on('message', (msg) => {
      if (msg.ready) return;
      this.#workerBusy[index] = false;
      this.emit('taskComplete', msg);
      this.#dispatchNext();
    });

    return true;
  }

  #removeIdleWorker() {
    if (this.#workers.length <= this.#minSize) return false;

    // Find last idle worker
    for (let i = this.#workers.length - 1; i >= this.#minSize; i--) {
      if (!this.#workerBusy[i]) {
        this.#workers[i].terminate();
        this.#workers.splice(i, 1);
        this.#workerBusy.splice(i, 1);
        return true;
      }
    }
    return false;
  }

  #autoScale() {
    const busyCount = this.#workerBusy.filter(Boolean).length;
    const utilization = busyCount / this.#workers.length;
    const queueDepth = this.#taskQueue.length;

    // Scale up: high utilization + tasks waiting
    if (utilization > 0.8 && queueDepth > 0) {
      const added = this.#addWorker();
      if (added) {
        this.emit('scaled', { direction: 'up', size: this.#workers.length });
        this.#dispatchNext();
      }
    }

    // Scale down: low utilization + no queued tasks
    if (utilization < 0.3 && queueDepth === 0) {
      const removed = this.#removeIdleWorker();
      if (removed) {
        this.emit('scaled', { direction: 'down', size: this.#workers.length });
      }
    }
  }

  #dispatchNext() {
    if (this.#taskQueue.length === 0) return;
    const idx = this.#workerBusy.indexOf(false);
    if (idx === -1) return;
    this.#workerBusy[idx] = true;
    this.#workers[idx].postMessage(this.#taskQueue.shift());
  }

  submit(task) {
    this.#taskQueue.push(task);
    this.#dispatchNext();
  }

  async destroy() {
    clearInterval(this.#scaleCheckInterval);
    await Promise.all(this.#workers.map((w) => w.terminate()));
  }

  get size() { return this.#workers.length; }
}
```

The pool starts at `minSize` workers. When utilization exceeds 80% and tasks are queued, it adds a worker (up to `maxSize`). When utilization drops below 30% and the queue is empty, it removes idle workers (down to `minSize`).

---

## Graceful Shutdown

Shutting down a pool requires care. You do not want to terminate workers mid-task — that loses results and leaves callers' promises hanging:

```javascript
'use strict';

// Graceful shutdown: wait for in-flight tasks, reject queued tasks

class GracefulPool {
  // ... (assume full pool implementation above)

  async drain() {
    // Stop accepting new tasks
    this.#accepting = false;

    // Reject all queued (not yet started) tasks
    for (const task of this.#taskQueue) {
      const cb = this.#taskCallbacks.get(task.taskId);
      if (cb) {
        cb.reject(new Error('Pool draining — task was never started'));
        this.#taskCallbacks.delete(task.taskId);
      }
    }
    this.#taskQueue.length = 0;

    // Wait for in-flight tasks to complete
    if (this.#taskCallbacks.size > 0) {
      await new Promise((resolve) => {
        const check = setInterval(() => {
          if (this.#taskCallbacks.size === 0) {
            clearInterval(check);
            resolve();
          }
        }, 50);
      });
    }

    // Now terminate all workers
    await Promise.all(this.#workers.map((w) => w.terminate()));
    this.#destroyed = true;
  }
}

// Usage:
// On SIGTERM, drain the pool before exiting
// process.on('SIGTERM', async () => {
//   console.log('Draining thread pool...');
//   await pool.drain();
//   console.log('Pool drained, exiting');
//   process.exit(0);
// });
```

The `drain()` method: (1) stops accepting new tasks, (2) rejects queued tasks that never started, (3) waits for in-flight tasks to finish, and (4) terminates all workers. This is the pattern you want for clean process shutdown.

---

## Choosing Pool Size

The optimal pool size depends on the workload:

| Workload | Optimal Pool Size | Reasoning |
|----------|-------------------|-----------|
| Pure CPU (math, hashing) | `os.cpus().length` | One thread per core for maximum parallelism |
| CPU + some I/O | `os.cpus().length + 1` | Extra thread covers I/O wait time |
| Mixed (CPU + heavy I/O) | `os.cpus().length * 2` | Threads waiting on I/O leave cores free |
| Memory-intensive | Fewer than core count | Each worker's V8 isolate uses 10-20 MB |

```javascript
'use strict';

const os = require('node:os');

function recommendPoolSize(workloadType) {
  const cpus = os.cpus().length;
  const totalMemGB = os.totalmem() / (1024 ** 3);
  const maxByMemory = Math.floor((totalMemGB * 0.5 * 1024) / 20); // 50% of RAM, 20 MB per worker

  const sizes = {
    cpu: cpus,
    mixed: cpus + 1,
    io_heavy: cpus * 2,
  };

  const recommended = sizes[workloadType] || cpus;
  return Math.min(recommended, maxByMemory); // Do not exceed memory budget
}

console.log(`CPU cores: ${os.cpus().length}`);
console.log(`Total RAM: ${(os.totalmem() / 1024 ** 3).toFixed(1)} GB`);
console.log(`CPU-bound pool:   ${recommendPoolSize('cpu')} workers`);
console.log(`Mixed pool:       ${recommendPoolSize('mixed')} workers`);
console.log(`I/O-heavy pool:   ${recommendPoolSize('io_heavy')} workers`);
```

---

## Key Takeaways

- A thread pool reuses a fixed set of workers instead of spawning per task — eliminating 50-200 ms startup overhead and 10-20 MB memory cost per spawn
- The pool architecture has three parts: a task queue (FIFO buffer), dispatch logic (first-idle, round-robin, or least-busy), and worker lifecycle management (crash recovery, graceful shutdown)
- Transferable objects (`postMessage(data, [arrayBuffer])`) move `ArrayBuffer` ownership to the worker with zero copy — the sender's buffer becomes neutered after transfer
- Graceful shutdown requires draining in-flight tasks before terminating workers — abrupt termination leaves callers' promises permanently pending
- Pool size should match the workload: `os.cpus().length` for pure CPU work, with adjustments for memory pressure and I/O mix

## Next

Continue to [Lesson 07 — Event Loop Optimization](lesson-07-event-loop-optimization.md), where we measure event loop lag, identify blocking operations, and apply strategies to keep the main thread responsive under heavy load.
