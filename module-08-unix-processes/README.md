# Module 08 — Unix, Processes & IPC

> Node.js is a Unix citizen. It inherits processes, signals, file descriptors, and environment variables from the operating system — and it gives you first-class APIs to manage them. This module teaches you how to work with the process model, spawn child processes, communicate between them, and scale your server across CPU cores using the cluster module.

---

## Learning Objectives

- Navigate the `process` module — environment variables, arguments, memory usage, exit codes, and standard I/O streams
- Spawn child processes with `exec`, `execFile`, `spawn`, and `fork`, choosing the right method for each use case
- Build inter-process communication channels using IPC message passing and serialization
- Handle Unix signals (`SIGINT`, `SIGTERM`, `SIGHUP`) for graceful shutdown and process lifecycle management
- Scale HTTP servers across all CPU cores using the `cluster` module with zero-downtime restarts
- Query system information through `node:os` to make runtime decisions based on the host environment

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| 01 | [Unix Fundamentals for Node.js](lesson-01-unix-fundamentals.md) | Processes, file descriptors, signals, stdin/stdout/stderr, exit codes, UIDs |
| 02 | [The process Module](lesson-02-process-module.md) | `process.env`, `process.argv`, `process.cwd()`, `process.memoryUsage()`, `process.exit()` |
| 03 | [Child Processes — exec & execFile](lesson-03-child-processes-exec.md) | Spawning shell commands, capturing output, buffer limits, shell vs no-shell security |
| 04 | [Child Processes — spawn & fork](lesson-04-child-processes-spawn-fork.md) | Streaming I/O with `spawn`, IPC channel with `fork`, `stdio` configuration |
| 05 | [Inter-Process Communication](lesson-05-ipc.md) | IPC channels, `process.send`, `child.send`, message passing patterns, serialization limits |
| 06 | [Signals & Process Lifecycle](lesson-06-signals-lifecycle.md) | `SIGINT`, `SIGTERM`, `SIGHUP`, `uncaughtException`, `unhandledRejection`, graceful shutdown |
| 07 | [The cluster Module](lesson-07-cluster-module.md) | Primary/worker architecture, `cluster.fork`, load balancing, zero-downtime restart |
| 08 | [OS Module & System Information](lesson-08-os-module.md) | `os.cpus()`, `os.totalmem()`, `os.freemem()`, `os.networkInterfaces()`, platform detection |

---

## Exercises

| # | Exercise | Description |
|---|----------|-------------|
| E01 | [Process Monitor](exercise-01-process-monitor.md) | Monitor child processes — spawn, track CPU/memory usage, auto-restart on crash |
| E02 | [Graceful Shutdown Handler](exercise-02-graceful-shutdown.md) | Handle SIGINT/SIGTERM, drain active connections, close handles, exit cleanly with code 0 |
| E03 | [CLI Task Runner](exercise-03-cli-task-runner.md) | Build a task runner (like a mini `make`) that spawns child processes for each task |
| E04 | [IPC Message Bus](exercise-04-ipc-message-bus.md) | Parent-child message bus with request/response pattern, correlation IDs, and timeouts |
| E05 | [Clustered HTTP Server](exercise-05-clustered-http-server.md) | Wrap an HTTP server with the `cluster` module, benchmark single-process vs multi-process throughput |

---

## Progressive Project — Step 08: Child Process Worker Pool

This is the eighth step of the course-spanning progressive project: **Build Your Own Production HTTP Server**.

In this step you add a worker pool to the framework so CPU-intensive request handlers never block the event loop. Heavy computation gets dispatched to child processes, and the main process stays responsive for I/O-bound requests.

**What you will build:**

- A configurable worker pool that spawns N child processes via `child_process.fork()`
- Round-robin task dispatch — each incoming CPU-heavy request goes to the next available worker
- IPC-based request/response protocol with correlation IDs to match results to requests
- Automatic worker respawn when a child process crashes or exits unexpectedly
- Health monitoring — track worker memory usage and kill workers that exceed a threshold
- Graceful shutdown that sends `SIGTERM` to all workers and waits for in-flight tasks to complete

**Key code pattern:**

```javascript
'use strict';

const { fork } = require('node:child_process');
const { cpus } = require('node:os');
const { EventEmitter } = require('node:events');

class WorkerPool extends EventEmitter {
  #workers = [];
  #queue = [];
  #nextWorker = 0;

  constructor(workerScript, size = cpus().length) {
    super();
    for (let i = 0; i < size; i++) {
      this.#spawnWorker(workerScript);
    }
  }

  #spawnWorker(script) {
    const worker = fork(script);
    worker.on('message', (msg) => this.emit('result', msg));
    worker.on('exit', (code) => {
      if (code !== 0) {
        this.emit('workerCrash', { pid: worker.pid, code });
        this.#spawnWorker(script); // Auto-respawn
      }
    });
    this.#workers.push(worker);
  }

  dispatch(task) {
    const worker = this.#workers[this.#nextWorker];
    this.#nextWorker = (this.#nextWorker + 1) % this.#workers.length;
    worker.send(task);
  }
}
```

**Builds on:** Step 07 (Full HTTP Protocol Implementation) — you have a working HTTP server with routing; now you keep it responsive by offloading heavy work.

**Leads to:** Step 09 (Worker Thread Request Handling) — you will replace child processes with `worker_threads` for computation that benefits from shared memory.

---

## Key Takeaways

After completing this module you will know how to manage the full lifecycle of processes on a Unix system from Node.js — spawning, communicating, monitoring, and terminating them. You will understand when to reach for child processes vs threads, and you will be able to implement graceful shutdown patterns that production servers demand.

---

## Next

Continue to [Module 09 — Multi-Threading & Performance](../module-09-multithreading/README.md) to learn how `worker_threads` bring true parallelism to Node.js without the overhead of separate processes.
