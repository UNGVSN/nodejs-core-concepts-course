# E02: Graceful Shutdown Handler

## Objective

Implement a production-grade graceful shutdown sequence for an HTTP server. You will handle SIGINT and SIGTERM signals, stop accepting new connections, drain in-flight requests with a timeout, close resource handles (database, file), flush pending writes, and exit with a clean status code. Every production Node.js server needs this, and getting it wrong causes data loss and broken connections.

## Prerequisites

- Module 07 / Lesson 06 — The HTTP Module
- Module 08 / Lesson 02 — The Process Module
- Module 08 / Lesson 06 — Signals and Lifecycle

## Instructions

1. Create a file called `graceful-shutdown.js`. Add `'use strict';` at the top. Require `node:http`, `node:fs`, and `node:path`.

2. Create a simulated "database" as a class `FakeDB` that mimics real database lifecycle:
   ```javascript
   class FakeDB {
     constructor() { this.connected = false; }
     open() {
       this.connected = true;
       console.log('[db] Connection opened');
     }
     query(sql) {
       if (!this.connected) return Promise.reject(new Error('DB not connected'));
       const delay = 50 + Math.random() * 150; // 50-200ms
       return new Promise(resolve =>
         setTimeout(() => resolve({ sql, rows: [], duration: delay }), delay)
       );
     }
     close() {
       return new Promise(resolve => {
         setTimeout(() => {
           this.connected = false;
           console.log('[db] Connection closed');
           resolve();
         }, 100);
       });
     }
   }
   ```

3. Create a write-ahead log file (`wal.log`) using `fs.createWriteStream` in append mode:
   ```javascript
   const walPath = path.resolve(__dirname, 'wal.log');
   const wal = fs.createWriteStream(walPath, { flags: 'a' });
   console.log(`[server] WAL log opened: ${walPath}`);
   ```
   Write a timestamped line for every request received:
   ```javascript
   wal.write(`${new Date().toISOString()} ${req.method} ${req.url}\n`);
   ```
   This simulates a log file that must be flushed completely before shutdown to prevent data loss.

4. Create an HTTP server that handles three routes:
   - `GET /fast` — responds immediately with `{ "status": "ok" }`. Writes a line to the WAL log.
   - `GET /slow` — calls `db.query('SELECT * FROM orders')` and responds after it resolves with `{ "query": "SELECT ...", "duration": Nms }`. Writes a line to the WAL log.
   - `GET /health` — responds with `200 OK` when healthy, `503 Service Unavailable` during shutdown. This is the endpoint that load balancers hit.

5. Track active connections and in-flight requests using three data structures:
   - A `Set` of open sockets. Listen for the `'connection'` event on the server. Add each socket to the set. Remove it when the socket emits `'close'`.
   - An `activeRequests` counter (simple integer). Increment at the start of each request handler. Decrement when `res.on('finish')` fires.
   - A `WeakMap` from socket to boolean indicating whether a request is currently in-flight on that socket. This is needed to distinguish idle keep-alive connections from active ones during shutdown.

6. Write a `shutdown(signal)` async function that executes the following steps in order, timing each one:
   - Log `"Received ${signal}. Starting graceful shutdown..."`.
   - Set a `shuttingDown = true` flag so the `/health` endpoint returns 503 and new calls to `shutdown()` return early.
   - Call `server.close()` to stop accepting new connections. Wrap in a Promise that resolves when the callback fires.
   - Set a hard deadline timer: if the shutdown is not complete within 10 seconds, log `"[shutdown] HARD DEADLINE: forcing exit"` and call `process.exit(1)`.
   - Destroy any idle keep-alive sockets (those not handling a request). For sockets with active requests, let them finish.
   - Wait for all in-flight requests to complete. Write a helper `waitForDrain()`:
     ```javascript
     function waitForDrain() {
       return new Promise(resolve => {
         if (activeRequests <= 0) return resolve();
         const interval = setInterval(() => {
           if (activeRequests <= 0) { clearInterval(interval); resolve(); }
         }, 100);
       });
     }
     ```
   - Close the database connection with `await db.close()`.
   - End the write-ahead log stream: `wal.end()` and wait for the `'finish'` event via a Promise wrapper.
   - Clear the hard deadline timer.
   - Log the total shutdown time and call `process.exit(0)`.

7. Register signal handlers:
   ```javascript
   process.on('SIGINT', () => shutdown('SIGINT'));
   process.on('SIGTERM', () => shutdown('SIGTERM'));
   ```
   Ensure that receiving the signal a second time during shutdown forces an immediate exit (for impatient operators who press Ctrl+C twice).

8. After calling `server.close()`, destroy any idle keep-alive connections. Iterate over tracked sockets: if a socket has no in-flight request, call `socket.destroy()`. For sockets with active requests, set the `Connection: close` header on the response so the client does not send more requests on the same socket.

9. Log a shutdown timeline showing each step and how long it took:
   ```
   [shutdown] server.close()              ... done (0ms)
   [shutdown] drain active requests (3)   ... done (1,234ms)
   [shutdown] db.close()                  ... done (102ms)
   [shutdown] flush WAL log               ... done (5ms)
   [shutdown] total shutdown time: 1,341ms
   ```

10. Start the server on port 3000. Open the database connection. Log readiness. Log the PID so it is easy to send signals from another terminal:
    ```
    [server] PID: 12345
    [server] DB connection opened
    [server] WAL log opened: /path/to/wal.log
    [server] Listening on port 3000 — send SIGINT or SIGTERM to shut down
    ```

## Break-Then-Harden Challenge

1. **Signal during shutdown.** Send SIGTERM, then immediately send another SIGTERM before shutdown completes. Observe a double-shutdown race. Fix it by setting a `shuttingDown` flag at the top of `shutdown()` and returning immediately if already shutting down. Allow a second SIGINT to force-exit.

2. **Stuck request.** Modify the `/slow` route to hang forever (never call `res.end()`). Observe the shutdown waiting indefinitely for in-flight requests. Verify that the 10-second hard deadline triggers and the process exits with code 1. Then improve: after 5 seconds, forcibly destroy remaining sockets to free stuck requests.

3. **Unclosed file handle.** Comment out the `wal.end()` call. Observe the process exiting with data still in the write stream buffer (lost writes). Re-enable flushing and confirm that the `'finish'` event fires before exit, proving all data is written to disk.

## Expected Output

```
$ node graceful-shutdown.js
[server] DB connection opened
[server] WAL log opened: wal.log
[server] Listening on port 3000

# In another terminal, send some requests:
$ curl http://localhost:3000/fast
{"status":"ok"}

$ curl http://localhost:3000/slow &
# (takes 100-200ms)

# Press Ctrl+C in the server terminal:
[shutdown] Received SIGINT. Starting graceful shutdown...
[shutdown] server.close()              ... done (1ms)
[shutdown] Waiting for 1 active request(s)...
[shutdown] drain active requests (1)   ... done (187ms)
[shutdown] db.close()                  ... done (101ms)
[shutdown] flush WAL log               ... done (3ms)
[shutdown] ──────────────────────────────────
[shutdown] Shutdown complete in 292ms
[shutdown] Exiting with code 0.

# The slow request finishes normally:
{"query":"SELECT ...","duration":187}
```

## Bonus

1. Implement a pre-shutdown hook system: maintain an array of cleanup functions registered with `onShutdown(name, asyncFn, timeoutMs)`. During shutdown, run all hooks in parallel using `Promise.allSettled`. Log each hook's name, duration, and whether it succeeded or timed out. This pattern scales to real applications with multiple resources (Redis, Postgres, Kafka, etc.).

2. Add a `beforeExit` event handler that catches any case where the event loop drains unexpectedly (no more work scheduled). Log a warning that the process is about to exit without an explicit shutdown, which usually indicates a bug (e.g., forgetting to keep the server listening).

## Hints

1. `server.close(callback)` stops accepting new connections but does NOT close existing ones. You must track and manage sockets yourself.
2. The `'connection'` event on `http.Server` fires for every new TCP connection, giving you the raw `net.Socket`. Track it in a Set and remove it on `'close'`.
3. `res.on('finish', () => activeRequests--)` fires when the response has been fully handed off to the OS — this is when you can consider the request complete.
4. To flush a write stream, call `stream.end()` and wait for the `'finish'` event. Do NOT call `process.exit()` before this event fires, or you will lose buffered data.
5. A double Ctrl+C pattern is idiomatic in CLI tools: first press begins graceful shutdown, second press forces immediate exit. Implement this with a counter or flag.
