# E01: Build a Job Queue

## Objective

Build an event-driven job queue using `EventEmitter` that supports concurrency limits, retry with exponential backoff, and job priorities. This exercise demonstrates how EventEmitter transforms a complex state machine into a clean, observable system where every state transition is an event.

## Prerequisites

- Module 02 / Lesson 01 — EventEmitter Internals
- Module 02 / Lesson 02 — Registering, Emitting, and Removing Listeners
- Module 02 / Lesson 04 — Custom EventEmitters

## Instructions

1. Create a file called `job-queue.js`. Add `'use strict';` at the top and require only built-in modules:

```javascript
'use strict';

const { EventEmitter } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
```

2. Define a `JobQueue` class that extends `EventEmitter`. The constructor accepts a `concurrency` limit (default 2):

```javascript
class JobQueue extends EventEmitter {
  constructor(concurrency = 2) {
    super();
    this.concurrency = concurrency;
    this.queue = [];       // pending jobs sorted by priority
    this.running = 0;      // currently executing jobs
    this.completed = 0;
    this.failed = 0;
    this.results = new Map();
  }
}
```

3. Add an `enqueue(job)` method. Each job is an object with `{ id, task, priority, maxRetries }` where `task` is an async function. Insert the job into `this.queue` sorted by priority (lower number = higher priority). Emit an `'enqueue'` event with the job id and queue length:

```javascript
enqueue(job) {
  const entry = {
    id: job.id,
    task: job.task,
    priority: job.priority || 10,
    maxRetries: job.maxRetries || 3,
    attempts: 0,
  };
  // Insert sorted by priority
  const insertIdx = this.queue.findIndex(j => j.priority > entry.priority);
  if (insertIdx === -1) {
    this.queue.push(entry);
  } else {
    this.queue.splice(insertIdx, 0, entry);
  }
  this.emit('enqueue', { id: entry.id, queueLength: this.queue.length });
  this._drain();
}
```

4. Implement `_drain()`. This method pulls jobs from the queue up to the concurrency limit and starts executing them:

```javascript
_drain() {
  while (this.running < this.concurrency && this.queue.length > 0) {
    const job = this.queue.shift();
    this.running++;
    this._execute(job);
  }
}
```

5. Implement `_execute(job)`. This is the core execution logic with retry and backoff. It should:
   - Emit `'processing'` with `{ id, attempt }` when a job starts
   - Call `job.task()` and await the result
   - On success: emit `'completed'` with `{ id, result, attempts }`, store result, increment `this.completed`
   - On failure: if retries remain, emit `'retry'` with `{ id, attempt, error, nextDelay }`, wait for exponential backoff (`2^attempt * 100`ms), then retry
   - On final failure: emit `'failed'` with `{ id, error, attempts }`, increment `this.failed`
   - Always decrement `this.running` and call `this._drain()` when finished
   - Emit `'idle'` when both queue is empty and running is 0

6. Add a `getResult(id)` method that returns the stored result for a completed job.

7. Add a `stats()` method that returns `{ queued, running, completed, failed }`.

8. Write a test script below the class definition. Create a queue with concurrency 2 and register listeners for all events:

```javascript
const queue = new JobQueue(2);

queue.on('enqueue', (data) => console.log(`[ENQUEUE]    Job ${data.id} (queue: ${data.queueLength})`));
queue.on('processing', (data) => console.log(`[PROCESSING] Job ${data.id} (attempt ${data.attempt})`));
queue.on('completed', (data) => console.log(`[COMPLETED]  Job ${data.id} after ${data.attempts} attempt(s)`));
queue.on('retry', (data) => console.log(`[RETRY]      Job ${data.id} attempt ${data.attempt} failed: ${data.error}. Retry in ${data.nextDelay}ms`));
queue.on('failed', (data) => console.log(`[FAILED]     Job ${data.id} after ${data.attempts} attempts: ${data.error}`));
queue.on('idle', () => console.log(`[IDLE]       Queue is empty. Stats: ${JSON.stringify(queue.stats())}`));
```

9. Enqueue 5 jobs: three that succeed (with varying delays), one that fails once then succeeds on retry, and one that always fails:

```javascript
// Succeeds immediately
queue.enqueue({ id: 'fast-1', priority: 1, task: async () => { await delay(50); return 'done'; } });

// Succeeds after 200ms
queue.enqueue({ id: 'slow-2', priority: 5, task: async () => { await delay(200); return 'done'; } });

// Succeeds immediately, low priority
queue.enqueue({ id: 'low-3', priority: 20, task: async () => { await delay(30); return 'done'; } });

// Fails once, then succeeds
let failOnce = 0;
queue.enqueue({ id: 'flaky-4', priority: 3, maxRetries: 3, task: async () => {
  failOnce++;
  if (failOnce <= 1) throw new Error('transient');
  return 'recovered';
}});

// Always fails
queue.enqueue({ id: 'broken-5', priority: 2, maxRetries: 2, task: async () => {
  throw new Error('permanent');
}});
```

10. Run with `node job-queue.js` and verify that: priority ordering is respected, concurrency limit is never exceeded, retries use increasing delays, and the `'idle'` event fires exactly once at the end.

## Break-Then-Harden Challenge

1. **Listener leak.** Inside the `_execute` method, register a new `'drain'` listener on every retry instead of calling `_drain` directly. Run the queue with 100 jobs that each retry 3 times. Observe the `MaxListenersExceededWarning`. Fix it by using `this.once()` instead of `this.on()`, or better yet, by calling `_drain` directly without events.

2. **Concurrency violation.** Remove the `this.running < this.concurrency` guard from `_drain`. Enqueue 20 jobs and observe that all 20 execute simultaneously. Add the guard back and also add a defensive check in `_execute` that throws if `this.running > this.concurrency`.

3. **Unhandled rejection.** Remove the `try/catch` around `job.task()` in `_execute`. Enqueue a job that throws. Observe the unhandled promise rejection crash. Fix it by ensuring the `try/catch` wraps the entire async execution path, and emit `'error'` (not just `'failed'`) for truly unexpected errors.

## Expected Output

```
[ENQUEUE]    Job fast-1 (queue: 1)
[ENQUEUE]    Job slow-2 (queue: 2)
[ENQUEUE]    Job low-3 (queue: 3)
[ENQUEUE]    Job flaky-4 (queue: 4)
[ENQUEUE]    Job broken-5 (queue: 5)
[PROCESSING] Job fast-1 (attempt 1)
[PROCESSING] Job broken-5 (attempt 1)
[RETRY]      Job broken-5 attempt 1 failed: permanent. Retry in 200ms
[COMPLETED]  Job fast-1 after 1 attempt(s)
[PROCESSING] Job flaky-4 (attempt 1)
[RETRY]      Job flaky-4 attempt 1 failed: transient. Retry in 200ms
[PROCESSING] Job slow-2 (attempt 1)
[COMPLETED]  Job slow-2 after 1 attempt(s)
[PROCESSING] Job low-3 (attempt 1)
[PROCESSING] Job broken-5 (attempt 2)
[RETRY]      Job broken-5 attempt 2 failed: permanent. Retry in 400ms
[COMPLETED]  Job low-3 after 1 attempt(s)
[PROCESSING] Job flaky-4 (attempt 2)
[COMPLETED]  Job flaky-4 after 2 attempt(s)
[FAILED]     Job broken-5 after 2 attempts: permanent
[IDLE]       Queue is empty. Stats: {"queued":0,"running":0,"completed":3,"failed":1}
```

(Exact interleaving may vary due to timing. Priority order and retry behavior are deterministic.)

## Bonus

1. Add a `pause()` and `resume()` method. When paused, `_drain` should not start new jobs, but currently running jobs should finish. Emit `'paused'` and `'resumed'` events.

2. Add a `cancel(id)` method that removes a queued (not yet running) job and emits `'cancelled'`. If the job is already running, emit a `'cancel-requested'` event and let the task check an `AbortSignal`.

## Hints

1. Exponential backoff formula: `delay = Math.pow(2, attempt) * baseDelay`. Use `100` as the base delay.
2. The `_drain` method should be called after every job completion (success or final failure) to pull the next job from the queue.
3. Use `async/await` inside `_execute` to keep the retry logic readable. The `setTimeout` from `node:timers/promises` returns a Promise you can `await`.
4. To detect idle state, check `this.queue.length === 0 && this.running === 0` after decrementing `this.running` in the finally block.
5. Remember that `emit('error', ...)` without a registered `'error'` listener throws an uncaught exception. Always register an `'error'` listener or use `emitter.on('error', () => {})` as a safety net.
