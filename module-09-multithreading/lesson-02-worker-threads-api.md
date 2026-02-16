# Module 09 / Lesson 02 — The worker_threads Module

> You understand why threads exist and when they help. Now it is time to use them. The `worker_threads` module is the gateway to multi-threaded JavaScript in Node.js. This lesson covers the complete API surface — creating workers, passing initialization data, communicating through ports, and handling every lifecycle event from birth to termination.

## Learning Objectives

- Create worker threads using `new Worker(filename)` and `new Worker(code, { eval: true })`
- Pass initialization data to workers with the `workerData` option
- Communicate between the main thread and workers using `parentPort`
- Detect which thread you are on with `isMainThread` and `threadId`
- Handle the complete worker lifecycle: `online`, `message`, `error`, `exit`, and `messageerror` events

---

## Creating a Worker

The `Worker` class lives in the `node:worker_threads` module. You create a worker by passing it a file path or an inline script:

```javascript
'use strict';

const { Worker } = require('node:worker_threads');

// Method 1: Point to a separate file
const worker1 = new Worker('./worker-script.js');

// Method 2: Inline code with eval option
const worker2 = new Worker(
  `
  const { parentPort } = require('node:worker_threads');
  parentPort.postMessage('Hello from inline worker');
  `,
  { eval: true }
);

worker2.on('message', (msg) => {
  console.log(msg); // "Hello from inline worker"
});
```

Method 1 is the standard approach for production code. The file path is resolved relative to the current working directory, not relative to the file that calls `new Worker()`. If you want a path relative to the current file, use `__filename` or `__dirname`:

```javascript
'use strict';

const path = require('node:path');
const { Worker } = require('node:worker_threads');

// Resolve relative to the current file's directory
const workerPath = path.join(__dirname, 'my-worker.js');
const worker = new Worker(workerPath);
```

Method 2 (`eval: true`) is useful for testing and prototyping but is generally avoided in production because it is harder to debug and lacks a proper file path for stack traces.

---

## The Same-File Pattern

A common pattern in Node.js is to use a single file for both the main thread and the worker. The `isMainThread` flag tells you which context you are in:

```javascript
'use strict';

const {
  Worker,
  isMainThread,
  parentPort,
  threadId,
} = require('node:worker_threads');

if (isMainThread) {
  // --- Main thread ---
  console.log(`Main thread started (threadId: ${threadId})`);

  const worker = new Worker(__filename);

  worker.on('message', (msg) => {
    console.log(`Main received: ${JSON.stringify(msg)}`);
  });

  worker.on('exit', (code) => {
    console.log(`Worker exited with code ${code}`);
  });
} else {
  // --- Worker thread ---
  console.log(`Worker started (threadId: ${threadId})`);

  parentPort.postMessage({ greeting: 'Hello from worker', tid: threadId });
}
```

The `__filename` reference resolves to the current file. When the `Worker` constructor receives it, Node.js loads the same file in a new V8 isolate. The `isMainThread` check branches into the worker code path. This pattern keeps related code together but scales poorly for large workers — at that point, split into separate files.

---

## workerData: Passing Initialization Data

When you create a worker, you often need to give it configuration or an initial payload. The `workerData` option lets you pass any cloneable value:

```javascript
'use strict';

const { Worker, isMainThread, workerData } = require('node:worker_threads');

if (isMainThread) {
  const config = {
    taskId: 1,
    input: [10, 20, 30, 40, 50],
    options: { verbose: true },
  };

  const worker = new Worker(__filename, { workerData: config });

  worker.on('message', (result) => {
    console.log(`Task ${result.taskId} result: ${result.sum}`);
  });
} else {
  // workerData is available immediately — no message passing needed
  const { taskId, input, options } = workerData;

  if (options.verbose) {
    console.log(`Worker processing task ${taskId} with ${input.length} items`);
  }

  const sum = input.reduce((acc, val) => acc + val, 0);

  const { parentPort } = require('node:worker_threads');
  parentPort.postMessage({ taskId, sum });
}
```

`workerData` is structured-cloned when the worker is created. This means:

- Primitives, objects, arrays, Maps, Sets, Dates, RegExps, and typed arrays are supported
- Functions, Symbols, and DOM objects are **not** supported (they throw a `DataCloneError`)
- `SharedArrayBuffer` instances are **shared**, not cloned — they are the exception to the copy rule
- The clone happens once at creation time — changes to the original object afterward are not reflected in the worker

```javascript
'use strict';

const { Worker, isMainThread, workerData } = require('node:worker_threads');

if (isMainThread) {
  const data = { value: 1 };
  const worker = new Worker(__filename, { workerData: data });

  // Modifying data after worker creation has NO effect on the worker's copy
  data.value = 999;

  worker.on('message', (msg) => {
    console.log(`Worker saw value: ${msg}`); // 1, not 999
  });
} else {
  const { parentPort } = require('node:worker_threads');
  parentPort.postMessage(workerData.value);
}
```

---

## parentPort: The Worker's Lifeline

Inside a worker thread, `parentPort` is a `MessagePort` connected to the main thread. It is the worker's primary communication channel:

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename);

  // Main thread sends to worker
  worker.postMessage({ type: 'TASK', payload: 'compute something' });

  // Main thread receives from worker
  worker.on('message', (msg) => {
    console.log(`Main received: ${msg.type} — ${msg.payload}`);
  });
} else {
  // Worker receives from main thread
  parentPort.on('message', (msg) => {
    console.log(`Worker received: ${msg.type}`);

    // Worker sends back to main thread
    parentPort.postMessage({ type: 'RESULT', payload: 'done' });
  });
}
```

Note the asymmetry: the main thread calls `worker.postMessage()` and listens on `worker.on('message')`. The worker calls `parentPort.postMessage()` and listens on `parentPort.on('message')`. They are opposite ends of the same `MessageChannel`.

### parentPort is null on the Main Thread

If you access `parentPort` on the main thread, it is `null`. Always check `isMainThread` or guard with a null check:

```javascript
'use strict';

const { parentPort, isMainThread } = require('node:worker_threads');

if (parentPort) {
  // We are in a worker
  parentPort.postMessage('I am a worker');
} else {
  // We are on the main thread
  console.log('parentPort is null — this is the main thread');
}
```

---

## Worker Lifecycle Events

A worker thread goes through a predictable lifecycle. The main thread can listen to these events:

### `online` — Worker Has Started

Fires when the worker thread starts executing JavaScript. This confirms the V8 isolate is initialized:

```javascript
'use strict';

const { Worker } = require('node:worker_threads');

const worker = new Worker('./heavy-task.js');

worker.on('online', () => {
  console.log('Worker is online — V8 isolate initialized');
  // Safe to start sending messages
  worker.postMessage({ type: 'START' });
});
```

### `message` — Worker Sent Data

Fires when the worker calls `parentPort.postMessage()`:

```javascript
worker.on('message', (data) => {
  console.log('Received from worker:', data);
});
```

### `messageerror` — Deserialization Failed

Fires when a received message cannot be deserialized. This is rare but happens if the message was corrupted or uses unsupported types:

```javascript
worker.on('messageerror', (err) => {
  console.error('Failed to deserialize message:', err.message);
});
```

### `error` — Uncaught Exception in Worker

Fires when the worker throws an uncaught exception. The error object is cloned from the worker's V8 isolate:

```javascript
worker.on('error', (err) => {
  console.error(`Worker error: ${err.message}`);
  console.error(err.stack);
});
```

If you do not listen for the `error` event, the error is silently swallowed — the worker exits and the main thread may never know why. Always attach an `error` handler.

### `exit` — Worker Has Terminated

Fires when the worker stops executing. The callback receives the exit code (0 for success, non-zero for failure):

```javascript
worker.on('exit', (code) => {
  if (code !== 0) {
    console.error(`Worker exited with error code ${code}`);
  } else {
    console.log('Worker exited cleanly');
  }
});
```

---

## Complete Lifecycle Example

Here is a full example demonstrating every lifecycle event in order:

```javascript
'use strict';

const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');

if (isMainThread) {
  console.log('[main] Creating worker...');

  const worker = new Worker(__filename, {
    workerData: { iterations: 10_000_000 },
  });

  worker.on('online', () => {
    console.log('[main] Worker is online');
  });

  worker.on('message', (msg) => {
    console.log(`[main] Message: ${JSON.stringify(msg)}`);
  });

  worker.on('messageerror', (err) => {
    console.error(`[main] Message error: ${err.message}`);
  });

  worker.on('error', (err) => {
    console.error(`[main] Worker error: ${err.message}`);
  });

  worker.on('exit', (code) => {
    console.log(`[main] Worker exited with code ${code}`);
  });
} else {
  console.log('[worker] Starting computation...');

  const { iterations } = workerData;
  let sum = 0;

  // Simulate CPU-bound work
  for (let i = 0; i < iterations; i++) {
    sum += Math.sqrt(i);
  }

  parentPort.postMessage({ result: sum });
  console.log('[worker] Done — exiting naturally');

  // Worker exits when there is no more work to do
  // (no open handles, no pending callbacks)
}
```

Expected output order:

```
[main] Creating worker...
[main] Worker is online
[worker] Starting computation...
[worker] Done — exiting naturally
[main] Message: {"result":21081849.486593034}
[main] Worker exited with code 0
```

---

## Worker Constructor Options

The `Worker` constructor accepts an options object with several useful properties:

```javascript
'use strict';

const { Worker } = require('node:worker_threads');

const worker = new Worker('./task.js', {
  // Data available as `workerData` inside the worker
  workerData: { taskId: 42 },

  // Environment variables for the worker (inherits from parent by default)
  env: { ...process.env, WORKER_MODE: 'compute' },

  // Redirect worker's stdout/stderr to the parent
  // By default, workers inherit stdout/stderr from the parent process
  stdout: true,  // Makes worker.stdout a Readable stream
  stderr: true,  // Makes worker.stderr a Readable stream

  // Resource limits for the V8 isolate
  resourceLimits: {
    maxOldGenerationSizeMb: 128,  // Max heap size
    maxYoungGenerationSizeMb: 32, // Max young generation (nursery)
    codeRangeSizeMb: 32,          // Max generated code size
    stackSizeMb: 4,               // Max call stack size
  },
});

// When stdout: true, you can read the worker's console output as a stream
worker.stdout.on('data', (chunk) => {
  console.log(`[worker stdout]: ${chunk.toString().trim()}`);
});

worker.stderr.on('data', (chunk) => {
  console.error(`[worker stderr]: ${chunk.toString().trim()}`);
});
```

### Resource Limits

The `resourceLimits` option is particularly valuable in production. It prevents a runaway worker from consuming all available memory and crashing the entire process:

```javascript
'use strict';

const { Worker, isMainThread } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename, {
    resourceLimits: {
      maxOldGenerationSizeMb: 50, // Limit heap to 50 MB
    },
  });

  worker.on('error', (err) => {
    // Worker hits the memory limit and dies
    console.error(`Worker error: ${err.message}`);
  });

  worker.on('exit', (code) => {
    console.log(`Worker exited with code ${code}`);
  });
} else {
  // Deliberately consume memory until we hit the limit
  const arrays = [];
  while (true) {
    arrays.push(new Array(100_000).fill('x'));
  }
}
```

---

## Terminating Workers

You can forcibly terminate a worker from the main thread using `worker.terminate()`:

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename);

  // Give the worker 5 seconds, then kill it
  const timeout = setTimeout(() => {
    console.log('[main] Worker took too long — terminating');
    worker.terminate();
  }, 5000);

  worker.on('message', (msg) => {
    console.log(`[main] Result: ${msg}`);
    clearTimeout(timeout);
  });

  worker.on('exit', (code) => {
    clearTimeout(timeout);
    console.log(`[main] Worker exited with code ${code}`);
    // code === 1 when terminated externally
  });
} else {
  // Simulate a task that might hang
  let result = 0;
  for (let i = 0; i < 1e10; i++) {
    result += Math.sin(i);
  }
  parentPort.postMessage(result);
}
```

`worker.terminate()` returns a Promise that resolves once the worker has fully exited:

```javascript
const exitCode = await worker.terminate();
console.log(`Worker terminated with code ${exitCode}`);
```

Important: `terminate()` is forceful. The worker does not get a chance to clean up. If you need graceful shutdown, send a message telling the worker to exit on its own:

```javascript
// Main thread
worker.postMessage({ type: 'SHUTDOWN' });

// Worker
parentPort.on('message', (msg) => {
  if (msg.type === 'SHUTDOWN') {
    // Clean up resources, close handles
    cleanup();
    process.exit(0);
  }
});
```

---

## threadId and isMainThread

Every thread in a Node.js process has a unique integer `threadId`. The main thread is always `threadId === 0`:

```javascript
'use strict';

const { Worker, isMainThread, threadId } = require('node:worker_threads');

if (isMainThread) {
  console.log(`Main thread: threadId=${threadId}, isMainThread=${isMainThread}`);
  // threadId=0, isMainThread=true

  for (let i = 0; i < 3; i++) {
    new Worker(__filename);
  }
} else {
  console.log(`Worker: threadId=${threadId}, isMainThread=${isMainThread}`);
  // threadId=1, 2, 3 (assigned sequentially), isMainThread=false
}
```

The `threadId` is useful for logging and debugging. It helps you trace which thread produced a given log line.

---

## Workers as Persistent Services

Workers do not have to be one-shot tasks. They can stay alive and process multiple messages, acting as persistent services:

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename);

  // Send multiple tasks to the same worker
  worker.postMessage({ id: 1, n: 35 });
  worker.postMessage({ id: 2, n: 38 });
  worker.postMessage({ id: 3, n: 40 });

  let received = 0;
  worker.on('message', (msg) => {
    console.log(`Task ${msg.id}: fib(${msg.n}) = ${msg.result}`);
    received++;
    if (received === 3) {
      worker.postMessage({ type: 'SHUTDOWN' });
    }
  });

  worker.on('exit', () => console.log('Worker done'));
} else {
  function fibonacci(n) {
    if (n <= 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
  }

  parentPort.on('message', (msg) => {
    if (msg.type === 'SHUTDOWN') {
      process.exit(0);
    }

    const result = fibonacci(msg.n);
    parentPort.postMessage({ id: msg.id, n: msg.n, result });
  });
}
```

This pattern — a long-lived worker that processes a stream of tasks — is the foundation of thread pools, which we will build in Lesson 06.

---

## Error Handling Best Practices

Errors in worker threads need careful handling. There are three failure modes:

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename);

  // 1. Uncaught exception — fires 'error' then 'exit'
  worker.on('error', (err) => {
    console.error(`[error event] ${err.message}`);
  });

  // 2. Worker exit — always fires, check code for failure
  worker.on('exit', (code) => {
    if (code !== 0) {
      console.error(`[exit event] Worker failed with code ${code}`);
    }
  });

  // 3. Caught errors — worker sends them as messages
  worker.on('message', (msg) => {
    if (msg.type === 'error') {
      console.error(`[message error] ${msg.message}`);
    } else {
      console.log(`[result] ${msg.value}`);
    }
  });

  worker.postMessage({ action: 'riskyTask' });
} else {
  parentPort.on('message', (msg) => {
    try {
      // Attempt the risky operation
      const result = JSON.parse('invalid json'); // This throws
      parentPort.postMessage({ type: 'result', value: result });
    } catch (err) {
      // Option A: Send the error as a message (worker stays alive)
      parentPort.postMessage({ type: 'error', message: err.message });

      // Option B: Throw (worker dies, main gets 'error' event)
      // throw err;
    }
  });
}
```

The best practice for production code is to catch errors inside the worker and report them via messages. This keeps the worker alive for the next task. Reserve uncaught exceptions for truly unrecoverable errors.

---

## Key Takeaways

- Create workers with `new Worker(filename)` — the file runs in a new V8 isolate with its own heap, event loop, and thread
- Pass initialization data via `workerData` — it is structured-cloned at creation time and immutable from the parent afterward
- Workers communicate through `parentPort.postMessage()` and `parentPort.on('message')` — the main thread uses `worker.postMessage()` and `worker.on('message')`
- Always handle the `error` and `exit` events on the main thread — unhandled worker errors are silently swallowed
- Workers can be one-shot (compute and exit) or persistent services (listen for messages in a loop) — persistent workers form the basis of thread pools

## Next

In the next lesson, we take a deep dive into message passing — structured cloning, `MessageChannel`, `MessagePort`, transferable objects, and the serialization overhead that determines whether message passing is fast enough for your use case.
