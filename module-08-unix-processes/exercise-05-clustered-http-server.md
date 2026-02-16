# E05: Clustered HTTP Server

## Objective

Wrap an HTTP server with the `node:cluster` module to run one worker per CPU core. You will implement automatic worker restart on crash, zero-downtime rolling restarts, and benchmark single-process versus clustered throughput using the load tester from Module 07. This is how production Node.js servers scale beyond a single thread.

## Prerequisites

- Module 07 / Lesson 06 — The HTTP Module
- Module 07 / Exercise 06 — Load Tester
- Module 08 / Lesson 07 — Cluster Module
- Module 08 / Lesson 06 — Signals and Lifecycle

## Instructions

1. Create a file called `clustered-server.js`. Add `'use strict';` at the top. Require `node:cluster`, `node:http`, `node:os`, and `node:process`.

2. Structure the file with the standard cluster pattern:
   ```javascript
   if (cluster.isPrimary) {
     // primary process logic
   } else {
     // worker process logic
   }
   ```

3. In the **primary process**:
   - Determine the number of CPUs with `os.availableParallelism()` (Node 18+) or `os.cpus().length`.
   - Fork one worker for each CPU.
   - Log the primary PID and the number of workers being spawned.
   - Track all workers in a Map keyed by worker ID.

4. Implement **auto-restart** in the primary:
   - Listen for the `'exit'` event on the cluster.
   - If a worker exits with a non-zero code or is killed by a signal, fork a replacement.
   - Add a rate limit: if more than 5 workers crash within 10 seconds, log an error and stop restarting (the application itself is broken, not just a fluke).

5. In the **worker process**, create an HTTP server that handles four routes:
   - `GET /` — responds with `{ "worker": process.pid, "requests": N }` where N is a per-worker request counter that increments on every request.
   - `GET /health` — responds with `200 OK` and `{ "status": "healthy", "pid": process.pid, "uptime": process.uptime() }`.
   - `GET /heavy` — computes a CPU-intensive task to simulate real load. Implement a naive recursive Fibonacci function and compute `fib(40)`. This blocks the event loop for 1-2 seconds, demonstrating why clustering helps.
     ```javascript
     function fib(n) { return n <= 1 ? n : fib(n - 1) + fib(n - 2); }
     ```
   - `GET /crash` — calls `process.exit(1)` after responding. This route is for testing auto-restart. Log a warning before crashing.
   - Any other route returns `404` with `{ "error": "Not found" }`.

6. Listen on port 3000. Because all workers share the same port (the cluster module distributes connections via the primary process), every worker calls `http.createServer().listen(3000)`. Each worker should log its PID and confirmation of listening:
   ```javascript
   server.listen(3000, () => {
     console.log(`[worker] Worker ${cluster.worker.id} (PID: ${process.pid}) listening on port 3000`);
   });
   ```

7. Implement a **rolling restart** triggered by `SIGUSR2` on the primary process:
   - When the primary receives `SIGUSR2`, restart workers one at a time.
   - Fork a new worker, wait for it to emit `'listening'`, then disconnect the old worker.
   - Wait for the old worker to exit before moving to the next.
   - This ensures zero downtime — at least N-1 workers are always serving traffic.

8. Add **primary-to-worker messaging** for graceful worker shutdown:
   - The primary sends `{ type: 'shutdown' }` to a worker before disconnecting it.
   - The worker listens for this message with `process.on('message', ...)`.
   - When received, the worker calls `server.close()` to stop accepting new connections, waits for in-flight requests to finish, then exits cleanly.
   - The worker also sends stats back to the primary periodically: `process.send({ type: 'stats', requests: requestCount, pid: process.pid })`. The primary collects these to maintain an aggregate view.

9. Log a status report every 10 seconds from the primary:
   ```
   [primary] Workers: 4 active, 0 restarting, 2 total restarts
   [primary] Worker PIDs: 12001, 12002, 12003, 12004
   ```

10. Run a comparative benchmark using the load tester from Module 07 Exercise 06:
    ```bash
    # Single process (comment out cluster logic, just run the HTTP server)
    node clustered-server.js --single &
    node load-tester.js --url http://localhost:3000/heavy -c 20 -n 200

    # Clustered
    node clustered-server.js &
    node load-tester.js --url http://localhost:3000/heavy -c 20 -n 200
    ```
    Record the throughput (req/sec) and latency percentiles for both. The clustered version should show a significant improvement on the CPU-heavy `/heavy` endpoint.

## Break-Then-Harden Challenge

1. **Crash storm.** Send 100 rapid requests to `/crash`. Observe the primary frantically forking workers. Verify that the crash rate limiter kicks in after 5 crashes in 10 seconds and the primary logs a fatal error instead of continuing to fork. Without this safeguard, a broken worker creates an infinite fork-crash loop that can bring down the host.

2. **Port conflict.** Start the clustered server, then try to start another instance on the same port. Observe the `EADDRINUSE` error. Ensure the error is handled in the worker and communicated to the primary via IPC so the primary can log the real cause and shut down cleanly.

3. **Rolling restart under load.** Start a load test with high concurrency, then trigger a rolling restart with `kill -SIGUSR2 <primary-pid>` mid-test. Observe whether any requests fail during the restart. If they do, ensure the old worker fully drains before being disconnected. Measure the error rate during rolling restart — it should be zero.

## Expected Output

```
$ node clustered-server.js

[primary] Primary process PID: 50000
[primary] Forking 4 workers...
[worker]  Worker 1 (PID: 50001) listening on port 3000
[worker]  Worker 2 (PID: 50002) listening on port 3000
[worker]  Worker 3 (PID: 50003) listening on port 3000
[worker]  Worker 4 (PID: 50004) listening on port 3000
[primary] All 4 workers are online.

# Requests are distributed across workers:
$ curl http://localhost:3000/
{"worker":50001,"requests":1}
$ curl http://localhost:3000/
{"worker":50003,"requests":1}
$ curl http://localhost:3000/
{"worker":50002,"requests":1}

# Crash a worker:
$ curl http://localhost:3000/crash
[primary] Worker 1 (PID: 50001) exited with code 1
[primary] Forking replacement worker...
[worker]  Worker 5 (PID: 50010) listening on port 3000
[primary] Workers: 4 active, 0 restarting, 1 total restarts

# Rolling restart:
$ kill -SIGUSR2 50000
[primary] Rolling restart initiated...
[primary] Restarting worker 2 (PID: 50002)...
[worker]  Worker 6 (PID: 50011) listening on port 3000
[primary] Worker 2 (PID: 50002) drained and exited
[primary] Restarting worker 3 (PID: 50003)...
[worker]  Worker 7 (PID: 50012) listening on port 3000
[primary] Worker 3 (PID: 50003) drained and exited
...
[primary] Rolling restart complete. 0 requests dropped.

# Benchmark comparison (example numbers):
Single process /heavy:   45 req/sec, p99: 890ms
Clustered (4 workers):  172 req/sec, p99: 245ms
```

## Bonus

1. Implement sticky sessions: route requests from the same client IP to the same worker using a hash of the IP address. This is necessary when workers hold in-memory session state. Override the cluster scheduling policy with `cluster.schedulingPolicy = cluster.SCHED_NONE` and implement your own routing in the primary.

2. Add a `/metrics` endpoint on the primary (listening on a separate port, e.g., 9090) that aggregates request counts, error counts, and average latency from all workers via IPC. Workers periodically send their stats to the primary.

## Hints

1. `cluster.fork()` returns a `Worker` object. The worker communicates with the primary via `worker.send(msg)` and `worker.on('message', handler)`.
2. Workers share the server port because the primary process creates the listening socket and distributes connections to workers via round-robin (on most platforms).
3. `worker.disconnect()` closes the IPC channel and causes the worker's `server.close()` to trigger. The worker exits when all connections are closed.
4. For rolling restart, process workers sequentially with `for...of` and `await` — do not restart all at once, or you will have zero workers serving traffic briefly.
5. `os.availableParallelism()` (Node 18.14+) is preferred over `os.cpus().length` because it respects cgroup CPU limits in containers.
