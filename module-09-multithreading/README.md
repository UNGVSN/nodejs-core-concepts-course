# Module 09 — Multi-Threading & Performance

> Node.js is single-threaded — until it is not. The `worker_threads` module gives you true OS-level threads with shared memory, message passing, and parallel execution. This module teaches you when threads actually help (CPU-bound work), when they hurt (I/O-bound work that the event loop already handles), and how to build thread pools, synchronize shared state, and profile performance.

---

## Learning Objectives

- Distinguish between concurrency (event loop) and parallelism (threads/processes) and choose the right tool for each
- Create and manage worker threads using `new Worker()`, `workerData`, `parentPort`, and `isMainThread`
- Transfer data between threads via `postMessage`, `MessageChannel`, and transferable objects
- Use `SharedArrayBuffer` and `Atomics` for zero-copy shared memory between threads
- Build a production-grade thread pool with task queuing, result callbacks, and graceful shutdown
- Profile event loop health, diagnose starvation, and benchmark with `perf_hooks`

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| 01 | [Thread Fundamentals](lesson-01-thread-fundamentals.md) | Threads vs processes, shared memory model, concurrency vs parallelism, when threads help |
| 02 | [The worker_threads Module](lesson-02-worker-threads-api.md) | `new Worker()`, `workerData`, `parentPort`, `isMainThread`, worker lifecycle events |
| 03 | [Message Passing Between Threads](lesson-03-message-passing.md) | `postMessage`, `MessageChannel`, `MessagePort`, structured clone overhead |
| 04 | [SharedArrayBuffer & Atomics](lesson-04-shared-memory-atomics.md) | Shared memory, `Atomics.wait`, `Atomics.notify`, `Atomics.add`, lock-free data structures |
| 05 | [Thread Synchronization](lesson-05-thread-synchronization.md) | Race conditions, deadlocks, mutexes via Atomics, critical sections, ordering guarantees |
| 06 | [Building a Custom Thread Pool](lesson-06-custom-thread-pool.md) | Fixed-size worker pool, task queue, result collection, error handling, graceful shutdown |
| 07 | [Event Loop Optimization](lesson-07-event-loop-optimization.md) | `setImmediate` chunking, avoiding starvation, `--prof` profiling, lag measurement |
| 08 | [Performance Profiling & Benchmarking](lesson-08-profiling-benchmarking.md) | `perf_hooks`, `performance.now()`, `PerformanceObserver`, histograms, Chrome DevTools |

---

## Exercises

| # | Exercise | Description |
|---|----------|-------------|
| E01 | [Parallel File Hasher](exercise-01-parallel-file-hasher.md) | Hash multiple large files in parallel using worker threads — compare to sequential |
| E02 | [Thread Pool Implementation](exercise-02-thread-pool.md) | Build a generic thread pool — queue tasks, dispatch to workers, collect results with callbacks |
| E03 | [Shared Memory Counter](exercise-03-shared-memory-counter.md) | Multiple threads increment a shared counter — observe race conditions, then fix with Atomics |
| E04 | [Mandelbrot Set Generator](exercise-04-mandelbrot-generator.md) | Compute the Mandelbrot set in parallel — each thread handles a horizontal slice of the image |
| E05 | [Event Loop Starvation Detector](exercise-05-event-loop-starvation-detector.md) | Build a monitoring tool that measures event loop lag and alerts when the loop is blocked |

---

## Progressive Project — Step 09: Worker Thread Request Handling

This is the ninth step of the course-spanning progressive project: **Build Your Own Production HTTP Server**.

In Step 08 you offloaded CPU-intensive work to child processes. Child processes work, but each one carries the overhead of a full V8 heap and IPC serialization. In this step you replace the child process worker pool with `worker_threads` — same parallelism, lower overhead, and the option to share memory.

**What you will build:**

- A `ThreadPool` class that manages a fixed pool of `worker_threads`
- A framework API like `app.worker('/compute', handlerPath)` that dispatches matching requests to worker threads
- Message passing between the main thread and workers using structured clone for request/response data
- `SharedArrayBuffer`-based metrics — request count, active threads, total processing time — readable from the main thread without IPC
- Benchmark tooling that compares event loop blocking vs child process offloading vs worker thread offloading
- Graceful thread pool shutdown: stop accepting new tasks, wait for in-flight tasks, then terminate workers

**Key code pattern:**

```javascript
'use strict';

const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');

if (!isMainThread) {
  // Worker: receive tasks, process, send results
  parentPort.on('message', (task) => {
    const result = heavyComputation(task.payload);
    parentPort.postMessage({ id: task.id, result });
  });
} else {
  // Main thread: create pool and dispatch
  class ThreadPool {
    #workers = [];
    #taskQueue = [];
    #pending = new Map();
    #nextId = 0;

    constructor(script, size) {
      for (let i = 0; i < size; i++) {
        const worker = new Worker(script);
        worker.on('message', (msg) => {
          const resolve = this.#pending.get(msg.id);
          this.#pending.delete(msg.id);
          resolve(msg.result);
          this.#processQueue(worker);
        });
        this.#workers.push(worker);
      }
    }

    run(payload) {
      return new Promise((resolve) => {
        const id = this.#nextId++;
        this.#pending.set(id, resolve);
        this.#taskQueue.push({ id, payload });
        this.#dispatch();
      });
    }
  }
}
```

**Builds on:** Step 08 (Child Process Worker Pool) — you already have process-based parallelism; now you upgrade to threads for lower overhead and shared memory.

**Leads to:** Step 10 (TLS/HTTPS + Compression) — the final step adds encryption and compression to make the framework production-complete.

---

## Key Takeaways

After completing this module you will understand exactly when multi-threading helps in Node.js (CPU-bound computation) and when it does not (I/O-bound work). You will be able to build thread pools, share memory safely with Atomics, and profile event loop performance to find bottlenecks before your users do.

---

## Next

Continue to [Module 10 — Cryptography, Compression & Security](../module-10-crypto-compression-security/README.md) to add encryption, hashing, TLS, and compression to your Node.js toolkit.
