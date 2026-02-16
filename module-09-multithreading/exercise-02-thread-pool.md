# E02: Thread Pool Implementation

## Objective

Build a generic, reusable thread pool with a fixed number of workers, an internal task queue, and Promise-based result collection. The pool dispatches tasks to free workers, queues overflow tasks until a worker becomes available, and automatically restarts workers that crash. This is the foundational pattern behind Node.js's own internal libuv thread pool and production job processing systems.

## Prerequisites

- Module 09 / Lesson 02 — The worker_threads Module
- Module 09 / Lesson 03 — Message Passing Between Threads
- Module 09 / Lesson 06 — Building a Custom Thread Pool

## Instructions

1. **Create three files:** `thread-pool.js` (the pool class), `compute-worker.js` (the generic worker), and `pool-demo.js` (the demo script). Add `'use strict';` to all three.

2. **Define the `ThreadPool` class** in `thread-pool.js`. Export it with `module.exports = ThreadPool`. The constructor takes two arguments: `workerScript` (absolute path to the worker file) and `poolSize` (number of workers, defaulting to `require('node:os').availableParallelism()`).

```javascript
'use strict';

const { Worker } = require('node:worker_threads');
const os = require('node:os');

class ThreadPool {
  #workers = [];
  #freeWorkers = [];
  #taskQueue = [];
  #pendingTasks = new Map();
  #nextTaskId = 0;
  #destroyed = false;
  #stats = { completed: 0, failed: 0, totalTime: 0 };

  constructor(workerScript, poolSize = os.availableParallelism()) {
    this.workerScript = workerScript;
    this.poolSize = poolSize;
    for (let i = 0; i < poolSize; i++) {
      this.#addWorker();
    }
  }
  // ... methods below
}
```

3. **Implement `#addWorker()`** as a private method that creates a new `Worker`, attaches `'message'`, `'error'`, and `'exit'` event listeners, and pushes the worker onto the `#freeWorkers` array. Each worker object in `#workers` should track: the `Worker` instance, a `currentTaskId` (null when idle), and a `tasksCompleted` count.

4. **Implement `run(taskData)`** which returns a Promise. If `#destroyed` is true, reject immediately with `new Error('Pool is destroyed')`. Assign a unique numeric ID via `#nextTaskId++`. If a free worker exists (pop from `#freeWorkers`), dispatch the task immediately. Otherwise, push the task onto `#taskQueue`. Store the `{ resolve, reject }` pair in `#pendingTasks` keyed by task ID.

```javascript
run(taskData) {
  return new Promise((resolve, reject) => {
    if (this.#destroyed) {
      return reject(new Error('Pool is destroyed'));
    }
    const id = this.#nextTaskId++;
    this.#pendingTasks.set(id, { resolve, reject, startTime: performance.now() });
    const freeWorker = this.#freeWorkers.pop();
    if (freeWorker) {
      this.#dispatch(freeWorker, id, taskData);
    } else {
      this.#taskQueue.push({ id, data: taskData });
    }
  });
}
```

5. **Implement `#dispatch(worker, id, data)`** that sets the worker's `currentTaskId` and calls `worker.postMessage({ id, data })`.

6. **Handle worker responses.** In the `'message'` handler, extract `{ id, result }` from the message. Look up the pending task by ID, resolve the Promise with the result, delete the entry from `#pendingTasks`, update stats, mark the worker as free, and call `#processQueue()` to dispatch the next queued task if any.

7. **Handle worker crashes.** In the `'error'` handler, reject the in-flight Promise if one exists. In the `'exit'` handler, if the exit code is non-zero, log a warning, remove the dead worker from `#workers`, and call `#addWorker()` to spawn a replacement. The replacement worker should immediately check the task queue.

8. **Implement `#processQueue(worker)`** that checks if `#taskQueue` has pending tasks. If so, shift the next task and dispatch it to the given worker. If the queue is empty, push the worker back onto `#freeWorkers`.

9. **Implement `destroy()`** that returns a Promise. Set `#destroyed = true` to stop accepting new tasks. Wait for all in-flight tasks by collecting Promises from `#pendingTasks`. Then call `worker.terminate()` on every worker. Resolve when all workers have exited.

```javascript
async destroy() {
  this.#destroyed = true;
  // Wait for in-flight tasks
  const inFlight = [...this.#pendingTasks.values()].map(
    (entry) => new Promise((resolve) => {
      const orig = entry.resolve;
      entry.resolve = (val) => { orig(val); resolve(); };
    })
  );
  if (inFlight.length > 0) await Promise.all(inFlight);
  // Terminate all workers
  await Promise.all(this.#workers.map((w) => w.instance.terminate()));
}
```

10. **Implement `stats()`** that returns `{ completed, failed, totalTime, avgTime, tasksPerSec, queueLength, activeWorkers, freeWorkers }`.

11. **Create the worker script** `compute-worker.js`. It receives `{ id, data }` via `parentPort.on('message')`, performs a computation based on `data.type` (e.g., `'primes'` computes all primes up to `data.limit` using a Sieve of Eratosthenes), and sends back `{ id, result }`.

```javascript
'use strict';
const { parentPort } = require('node:worker_threads');

parentPort.on('message', ({ id, data }) => {
  let result;
  if (data.type === 'primes') {
    result = sieveOfEratosthenes(data.limit);
  }
  parentPort.postMessage({ id, result });
});

function sieveOfEratosthenes(limit) {
  const sieve = new Uint8Array(limit + 1);
  const primes = [];
  for (let i = 2; i <= limit; i++) {
    if (!sieve[i]) {
      primes.push(i);
      for (let j = i * i; j <= limit; j += i) sieve[j] = 1;
    }
  }
  return { count: primes.length, largest: primes[primes.length - 1] };
}
```

12. **Write the demo** in `pool-demo.js`. Create a `ThreadPool` with 4 workers. Submit 20 tasks with varying prime limits (10,000 to 200,000 in increments of 10,000). Log each result as it arrives. After all tasks complete, print pool statistics and call `destroy()`.

## Break-Then-Harden Challenge

### Scenario 1 — Worker Crash Mid-Task

Add `if (data.limit === 50000) process.exit(1);` to the worker script. Observe that the task for limit 50,000 never resolves and subsequent tasks for that worker may stall. Verify that your `'exit'` handler rejects the in-flight Promise, spawns a replacement worker, and that the replacement immediately picks up the next queued task. The pool should recover without manual intervention.

### Scenario 2 — Memory Leak via Unreleased Promises

Comment out the `this.#pendingTasks.delete(id)` line in the message handler. Run 10,000 tasks and observe growing memory usage by logging `process.memoryUsage().heapUsed` every 1,000 tasks. The `#pendingTasks` Map grows unboundedly because resolved Promises still hold references. Fix it by always cleaning up the pending map entry after resolve or reject.

### Scenario 3 — Destroy During Active Tasks

Submit 20 tasks, then call `pool.destroy()` immediately after submission (before any resolve). Observe whether in-flight tasks complete or are dropped — they should complete. Verify that tasks still in the queue (not yet dispatched) are rejected with a clear error message. Test that calling `pool.run()` after `destroy()` throws immediately.

## Expected Output

```
$ node pool-demo.js

ThreadPool created: 4 workers running compute-worker.js
Submitting 20 tasks...

Task  1 completed: 1,229 primes up to  10,000  (worker 1, 3.2 ms)
Task  2 completed: 1,229 primes up to  10,000  (worker 2, 3.1 ms)
Task  3 completed: 2,262 primes up to  20,000  (worker 3, 5.8 ms)
Task  4 completed: 2,262 primes up to  20,000  (worker 4, 5.7 ms)
Task  5 completed: 3,401 primes up to  30,000  (worker 1, 9.4 ms)
Task  6 completed: 4,203 primes up to  40,000  (worker 2, 12.1 ms)
Task  7 completed: 5,133 primes up to  50,000  (worker 3, 15.3 ms)
Task  8 completed: 6,057 primes up to  60,000  (worker 4, 18.7 ms)
...
Task 19 completed: 16,252 primes up to 190,000 (worker 3, 128.4 ms)
Task 20 completed: 17,984 primes up to 200,000 (worker 4, 142.6 ms)

--- Pool Statistics ---
Total tasks:      20
Tasks completed:  20
Tasks failed:     0
Total time:       487.3 ms
Avg task time:    24.4 ms
Tasks/sec:        41.1
Peak queue depth: 16

Pool destroyed. All 4 workers terminated.
```

## Bonus

1. **Priority queue.** Replace the FIFO task queue with a priority queue (binary heap or sorted insert). Tasks submitted with `pool.run(data, { priority: 'high' })` should be dispatched before `{ priority: 'low' }` tasks. Demonstrate with 10 low-priority and 5 high-priority tasks submitted in interleaved order — the high-priority tasks should complete first despite being submitted later.

2. **Dynamic pool resizing.** Add a `resize(newSize)` method that spins up or tears down workers at runtime. When shrinking, wait for busy workers to finish their current task before terminating them. When growing, new workers should immediately start processing queued tasks. Test by starting with 2 workers, submitting 20 tasks, then resizing to 8 mid-flight.

## Hints

1. Use a `Map` keyed by task ID to store `{ resolve, reject, startTime }` entries for pending Promises. This gives O(1) lookup when a worker sends its result.

2. Track free workers with an array (`#freeWorkers = []`). Pop to get a free worker (O(1)), push when a worker becomes free. This avoids scanning the entire worker list.

3. The worker must always echo back the `id` field in its response so the main thread knows which Promise to resolve. Without this, there is no way to match responses to requests.

4. `worker.threadId` is assigned by Node.js and is useful for logging which worker handled which task. Access it on the `Worker` instance in the main thread.

5. In `destroy()`, use `Promise.all(this.#workers.map(w => w.instance.terminate()))`. The `terminate()` method returns a Promise that resolves with the exit code once the worker has been stopped.
