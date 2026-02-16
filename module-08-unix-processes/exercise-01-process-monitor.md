# E01: Process Monitor

## Objective

Build a process monitor that spawns child processes, tracks their CPU and memory usage over time, detects crashes, and auto-restarts them with exponential backoff. This is the core of what tools like PM2 and systemd do — you will build a simplified version using only `node:child_process` and `node:os`.

## Prerequisites

- Module 01 / Lesson 04 — Event Loop Deep Dive
- Module 08 / Lesson 02 — The Process Module
- Module 08 / Lesson 03 — Child Processes (exec)
- Module 08 / Lesson 04 — Child Processes (spawn, fork)
- Module 08 / Lesson 06 — Signals and Lifecycle

## Instructions

1. Create a file called `process-monitor.js`. Add `'use strict';` at the top. Require `node:child_process`, `node:os`, and `node:path`.

2. Create a simple worker script called `worker.js` in the same directory. This is the process the monitor will manage:
   ```javascript
   'use strict';
   const id = process.env.WORKER_ID || '0';
   console.log(`[Worker ${id}] Started (PID: ${process.pid})`);

   // Simulate periodic work and memory reporting
   let requestCount = 0;
   setInterval(() => {
     requestCount++;
     const mem = process.memoryUsage();
     console.log(`[Worker ${id}] tick=${requestCount} RSS: ${(mem.rss / 1024 / 1024).toFixed(1)} MB`);
   }, 2000);

   // Handle SIGTERM for graceful shutdown
   process.on('SIGTERM', () => {
     console.log(`[Worker ${id}] Received SIGTERM, shutting down...`);
     process.exit(0);
   });
   ```

3. Define a `ProcessEntry` structure (plain object) with fields: `name`, `command`, `args`, `childProcess`, `restartCount`, `lastExitCode`, `lastExitTime`, `backoffMs`, `status` (one of `'running'`, `'stopped'`, `'restarting'`).

4. Write a function `spawnProcess(entry)` that spawns the child using `child_process.spawn`:
   - Use `spawn('node', [entry.command], { env: { ...process.env, WORKER_ID: entry.name } })`.
   - Listen for `data` events on `child.stdout` and `child.stderr`. Prefix each line with `[${entry.name}]` before writing to the parent's stdout/stderr.
   - Update `entry.status` to `'running'` and store the child process reference in `entry.childProcess`.
   - Store the spawn timestamp in `entry.startedAt` for uptime tracking.

5. Attach an `'exit'` handler on the child process. When the child exits:
   - Log the exit code and signal.
   - Update `entry.lastExitCode` and `entry.lastExitTime`.
   - If the exit was non-zero (crash), increment `entry.restartCount` and calculate the backoff delay using exponential backoff: `Math.min(1000 * Math.pow(2, restartCount), 30000)` — start at 1s, double each time, cap at 30s. Update `entry.status` to `'restarting'` and log the restart delay.
   - Schedule a restart after the backoff delay using `setTimeout`, calling `spawnProcess(entry)` inside the callback.
   - If the child exits with code 0, log that it exited cleanly, update `entry.status` to `'stopped'`, and do not restart.
   - Reset `entry.restartCount` to 0 if the process has been running for more than 60 seconds before crashing (it was stable, so the next crash is a fresh failure).

6. Write a function `getProcessStats(pid)` that reads CPU and memory metrics for a running child process. Spawn a quick `ps` command and parse the output:
   ```javascript
   const { execSync } = require('node:child_process');
   const output = execSync(`ps -o %cpu=,rss= -p ${pid}`).toString().trim();
   const [cpu, rssKB] = output.split(/\s+/).map(Number);
   return { cpuPercent: cpu, memMB: (rssKB / 1024).toFixed(1) };
   ```
   Wrap in a try/catch — if the process has already exited, `ps` will fail. Return `{ cpuPercent: 0, memMB: 0 }` in that case.

7. Set up a monitoring interval (every 3 seconds) that iterates over all managed processes, calls `getProcessStats` for each running child, and logs a status table:
   ```
   ┌──────────┬───────┬────────┬─────────┬──────────┐
   │ Name     │ PID   │ Status │ CPU (%) │ Mem (MB) │
   ├──────────┼───────┼────────┼─────────┼──────────┤
   │ worker-1 │ 12345 │ running│ 2.3     │ 45.1     │
   │ worker-2 │ 12346 │ running│ 1.8     │ 42.7     │
   └──────────┴───────┴────────┴─────────┴──────────┘
   ```

8. Write a function `stopProcess(entry)` that sends `SIGTERM` to the child. If the child does not exit within 5 seconds, escalate to `SIGKILL`. Update the entry status to `'stopped'`.

9. Handle `SIGINT` on the parent process: when the user presses Ctrl+C, gracefully stop all child processes using `stopProcess`, wait for all to exit, then exit the parent cleanly.

10. Accept a configuration from `process.argv`:
    ```bash
    node process-monitor.js --workers 3
    node process-monitor.js --workers 3 --script ./custom-worker.js
    ```
    Parse `--workers N` to set the count (default: `os.cpus().length`). Parse `--script <path>` to set the worker script (default: `worker.js`). Create N `ProcessEntry` objects named `worker-1` through `worker-N` and spawn all of them. Log the configuration at startup.

## Break-Then-Harden Challenge

1. **Rapid crash loop.** Modify `worker.js` to crash immediately by adding `process.exit(1)` as the first line. Observe the monitor restarting it in a tight loop. Verify that exponential backoff kicks in and the restart interval grows: 1s, 2s, 4s, 8s, 16s, 30s (capped). Then add a maximum restart count (e.g., 10) — after which the monitor gives up, marks the process status as `'failed'`, and logs `"Giving up on <name> after 10 restarts"`.

2. **Zombie process.** Modify `worker.js` to ignore `SIGTERM` (`process.on('SIGTERM', () => {})`). Observe your `stopProcess` hanging forever. Verify that the 5-second `SIGKILL` escalation fires and successfully kills the stubborn process.

3. **Fork bomb protection.** What happens if `worker.js` itself spawns child processes? Your monitor only tracks the direct child PID. Kill the parent and observe orphaned grandchildren. Fix it by spawning with `{ detached: false }` (default) and using `child.kill(-child.pid)` on stop to kill the entire process group (requires spawning with `detached: true` and calling `process.kill(-pid)`).

## Expected Output

```
$ node process-monitor.js --workers 2

[Monitor] Starting process monitor...
[Monitor] Spawning worker-1 (PID: 54321)
[Monitor] Spawning worker-2 (PID: 54322)

[worker-1] Started (PID: 54321)
[worker-2] Started (PID: 54322)

┌──────────┬───────┬─────────┬─────────┬──────────┬──────────┐
│ Name     │ PID   │ Status  │ CPU (%) │ Mem (MB) │ Restarts │
├──────────┼───────┼─────────┼─────────┼──────────┼──────────┤
│ worker-1 │ 54321 │ running │ 0.5     │ 28.3     │ 0        │
│ worker-2 │ 54322 │ running │ 0.4     │ 27.9     │ 0        │
└──────────┴───────┴─────────┴─────────┴──────────┴──────────┘

[worker-1] RSS: 28.3 MB
[worker-2] RSS: 27.9 MB

# After killing worker-1 manually:
[Monitor] worker-1 (PID: 54321) exited with code null, signal SIGTERM
[Monitor] Restarting worker-1 in 1000ms (restart #1)
[Monitor] Spawning worker-1 (PID: 54399)

# After Ctrl+C:
[Monitor] Shutting down all processes...
[Monitor] Stopping worker-1 (SIGTERM)
[Monitor] Stopping worker-2 (SIGTERM)
[Monitor] worker-1 exited cleanly
[Monitor] worker-2 exited cleanly
[Monitor] All processes stopped. Goodbye.
```

## Bonus

1. Add a memory threshold alert: if any child process exceeds 100 MB RSS, log a warning. If it exceeds 200 MB, kill and restart it (potential memory leak).

2. Expose a simple HTTP status endpoint on port 9000 that returns the current state of all managed processes as JSON, enabling remote monitoring dashboards.

## Hints

1. `child_process.spawn('node', ['worker.js'], { env: { ...process.env, WORKER_ID: '1' } })` passes environment variables to the child without losing existing env vars like `PATH`.
2. To prefix child stdout, listen for `data` events on `child.stdout` and prepend the tag before writing to `process.stdout`. Convert each chunk to a string, split on newlines, prefix each line, and write.
3. `child.kill('SIGTERM')` sends a signal. Check `child.killed` or listen for the `'exit'` event to confirm termination. Note that `child.killed` only becomes `true` if the parent sent the signal — it stays `false` if the child exits on its own.
4. Exponential backoff formula: `delay = Math.min(baseMs * Math.pow(2, attempt), maxMs)`. Reset the attempt counter after a process runs successfully for a sustained period (e.g., 60 seconds without crashing).
5. `os.cpus().length` tells you how many CPU cores are available — useful for deciding default worker count.
6. Use `child.pid` to get the PID of the spawned child. Store it in the entry for monitoring. The PID becomes `undefined` after the child exits.
7. When building the status table, use `String.prototype.padEnd()` to align columns. For example: `name.padEnd(12)` ensures all name cells are 12 characters wide.
8. To stop all children on SIGINT, remove the default SIGINT handler with `process.on('SIGINT', handler)` and iterate over all entries, calling `stopProcess` on each. Use `Promise.all` to wait for all to exit before calling `process.exit(0)`.
