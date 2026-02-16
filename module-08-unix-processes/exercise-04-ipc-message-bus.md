# E04: IPC Message Bus

## Objective

Build a parent-child IPC message bus with a request/response pattern using `child_process.fork`. Messages carry correlation IDs for matching responses to requests, support configurable timeouts, and the system handles worker crashes gracefully. This is the messaging pattern that underlies `cluster` module communication and distributed task delegation.

## Prerequisites

- Module 08 / Lesson 04 — Child Processes (spawn, fork)
- Module 08 / Lesson 05 — IPC

## Instructions

1. Create two files: `message-bus.js` (parent) and `bus-worker.js` (child). Add `'use strict';` at the top of both. The parent requires `node:child_process` and `node:crypto`.

2. In `message-bus.js`, define a message protocol. Every message is a plain object with:
   ```javascript
   {
     id: 'uuid-v4',          // correlation ID
     type: 'request' | 'response' | 'event',
     action: 'compute' | 'status' | ...,
     payload: { ... },
     timestamp: Date.now(),
     error: null | { message, code }
   }
   ```

3. Write a class `MessageBus` with the following interface:
   - `constructor(workerPath, workerCount)` — forks N worker processes.
   - `send(workerId, action, payload, timeoutMs)` — sends a request to a specific worker and returns a Promise that resolves with the response payload. Uses the correlation ID to match the response. Rejects if the timeout expires.
   - `broadcast(action, payload)` — sends a message to ALL workers. Returns a Promise that resolves with an array of responses.
   - `on(eventName, handler)` — registers a handler for events pushed from workers to the parent.
   - `shutdown()` — gracefully disconnects all workers.

4. Implement the correlation ID matching in `send`:
   - Generate a UUID v4 for the message ID.
   - Store a `{ resolve, reject, timer }` entry in a `pendingRequests` Map keyed by the message ID.
   - Send the message via `worker.send(message)`.
   - Set a timeout that rejects the Promise with `"Request ${id} timed out after ${ms}ms"` and cleans up the pending entry.
   - When a response arrives on the `'message'` event, look up the pending entry by `id`, clear the timeout, and resolve/reject based on whether the response has an error.

5. In `bus-worker.js`, listen for messages on `process.on('message', ...)`. Implement handlers for at least three actions:
   - `compute` — receives `{ a, b, operation }`, performs the math, returns the result. Simulate work with a random 50-500ms delay.
   - `status` — returns `{ pid: process.pid, uptime: process.uptime(), memory: process.memoryUsage() }`.
   - `crash` — calls `process.exit(1)` to simulate a crash (for testing).

6. When the worker finishes processing, send a response back:
   ```javascript
   process.send({
     id: msg.id,       // same correlation ID
     type: 'response',
     action: msg.action,
     payload: result,
     timestamp: Date.now(),
     error: null
   });
   ```

7. Handle worker crashes in the parent:
   - Listen for the `'exit'` event on each worker.
   - When a worker dies, reject all pending requests that were sent to that worker with an error `"Worker ${id} died with code ${code}"`.
   - Optionally auto-restart the worker (configurable via `autoRestart: true`).

8. Implement a round-robin `sendToAny(action, payload, timeoutMs)` method that distributes requests across available workers. Maintain a counter that cycles through worker indices.

9. Add a test section at the bottom that demonstrates the full system:
   ```javascript
   async function main() {
     const bus = new MessageBus('./bus-worker.js', 3);

     // Request/response
     const result = await bus.send(0, 'compute', { a: 10, b: 20, operation: 'add' }, 3000);
     console.log('Compute result:', result);

     // Broadcast
     const statuses = await bus.broadcast('status', {});
     console.log('Worker statuses:', statuses);

     // Round-robin
     for (let i = 0; i < 6; i++) {
       const r = await bus.sendToAny('compute', { a: i, b: i * 2, operation: 'multiply' }, 3000);
       console.log(`Round-robin ${i}:`, r);
     }

     // Timeout test
     try {
       await bus.send(0, 'compute', { a: 1, b: 2, operation: 'add' }, 10); // 10ms timeout
     } catch (err) {
       console.log('Timeout:', err.message);
     }

     await bus.shutdown();
   }
   main().catch(console.error);
   ```

10. Log all IPC traffic with timestamps to stderr when a `--debug` flag is passed, showing message direction (`parent -> worker-0`, `worker-0 -> parent`), correlation ID, action, and latency.

## Break-Then-Harden Challenge

1. **Worker crash with pending requests.** Send a `crash` action to a worker that has 5 pending `compute` requests. Observe that those 5 requests never resolve (they hang until timeout). Fix it by iterating over the `pendingRequests` Map on worker exit and immediately rejecting any requests assigned to the dead worker.

2. **Message ordering.** Send 100 rapid-fire requests to the same worker. Do the responses arrive in order? They should not necessarily — each has a random delay. Verify that your correlation ID matching correctly pairs responses to requests regardless of arrival order. Log the request order vs response arrival order to confirm.

3. **Serialization limit.** Try sending a `payload` that contains a `Buffer`, a `Function`, or a circular reference. Observe the serialization error (IPC uses structured clone, not JSON). Fix it by wrapping `worker.send` in a try/catch and rejecting the corresponding Promise with a clear error message about unsupported payload types.

## Expected Output

```
$ node message-bus.js

[bus] Forked worker-0 (PID: 61001)
[bus] Forked worker-1 (PID: 61002)
[bus] Forked worker-2 (PID: 61003)

Compute result: { result: 30 }

Worker statuses:
  worker-0: { pid: 61001, uptime: 0.52, memory: { rss: 30212096, ... } }
  worker-1: { pid: 61002, uptime: 0.52, memory: { rss: 29884416, ... } }
  worker-2: { pid: 61003, uptime: 0.52, memory: { rss: 30015488, ... } }

Round-robin 0: { result: 0 }    (worker-0)
Round-robin 1: { result: 2 }    (worker-1)
Round-robin 2: { result: 8 }    (worker-2)
Round-robin 3: { result: 18 }   (worker-0)
Round-robin 4: { result: 32 }   (worker-1)
Round-robin 5: { result: 50 }   (worker-2)

Timeout: Request abc123... timed out after 10ms

[bus] Shutting down workers...
[bus] worker-0 disconnected
[bus] worker-1 disconnected
[bus] worker-2 disconnected
[bus] All workers shut down.
```

## Bonus

1. Add a priority queue: high-priority messages skip ahead of normal-priority messages in the worker's processing queue. Workers process one message at a time, and if a high-priority message arrives while a normal message is in progress, it queues next.

2. Implement a dead letter queue: if a message fails processing 3 times (due to worker crashes and retries), move it to a "dead letter" list and log it for manual inspection instead of retrying forever.

## Hints

1. `child_process.fork(modulePath)` automatically sets up an IPC channel. Use `child.send(msg)` and `child.on('message', handler)` on the parent side, and `process.send(msg)` and `process.on('message', handler)` on the child side.
2. `crypto.randomUUID()` generates unique correlation IDs.
3. Store pending requests as `Map<id, { resolve, reject, timer, workerId }>`. The `workerId` lets you clean up on worker crash.
4. `worker.disconnect()` gracefully closes the IPC channel. Wait for the `'exit'` event to confirm the worker has shut down.
5. Round-robin is simply `workers[counter++ % workers.length]` — wrap the counter to prevent integer overflow on long-running systems.
