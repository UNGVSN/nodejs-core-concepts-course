# Module 08 / Lesson 05 — Inter-Process Communication

> Processes are isolated by design — they cannot read each other's memory. When you need two Node.js processes to coordinate, you need an explicit communication channel. The `child_process.fork()` IPC channel is Node.js's built-in answer: a bidirectional message pipe that serializes JavaScript objects between parent and child.

---

## Learning Objectives

- Explain how the IPC channel created by `fork()` works at the OS level (Unix domain sockets)
- Send and receive structured messages with `process.send()` and `process.on('message')`
- Understand serialization limits — what can and cannot cross the IPC boundary
- Implement request-response patterns with correlation IDs
- Build a fire-and-forget logging pattern and a supervised task delegation system

---

## How IPC Works

When you call `fork()`, Node.js creates a child process and opens a **Unix domain socket** (on Unix) or **named pipe** (on Windows) between parent and child. This is the IPC channel.

Messages are serialized to JSON by default, sent over the socket, and deserialized on the other side. This happens automatically — you just call `send()` and listen for `'message'`.

```javascript
'use strict';

const { fork } = require('node:child_process');
const path = require('node:path');

// Parent creates a child with an IPC channel (automatic with fork)
const child = fork(path.join(__dirname, 'ipc-child.js'));

// Send a message to the child
child.send({ greeting: 'Hello from parent', timestamp: Date.now() });

// Receive messages from the child
child.on('message', (msg) => {
  console.log('[Parent] Received:', msg);
});

// Clean up after 2 seconds
setTimeout(() => {
  child.send({ type: 'shutdown' });
}, 2000);

child.on('exit', (code) => {
  console.log('[Parent] Child exited with code:', code);
});
```

And the child (`ipc-child.js`):

```javascript
'use strict';

// In a forked process, process.send() and process.on('message') exist
process.on('message', (msg) => {
  console.log('[Child] Received:', msg);

  if (msg.type === 'shutdown') {
    process.exit(0);
  }

  // Reply to the parent
  process.send({
    reply: `Got your message at ${new Date(msg.timestamp).toISOString()}`,
    childPid: process.pid
  });
});

// Let the parent know we are ready
process.send({ type: 'ready', pid: process.pid });
```

---

## Serialization: What Crosses the Wire

IPC messages are serialized using the **structured clone algorithm** (since Node.js v10.10+). This is more powerful than JSON but still has limits.

### What Works

```javascript
'use strict';

// All of these can be sent via IPC:
const validMessages = {
  // Primitives
  string: 'hello',
  number: 42,
  boolean: true,
  null_val: null,

  // Objects and arrays
  object: { nested: { deep: true } },
  array: [1, 2, 3],

  // Typed arrays and Buffers
  uint8: new Uint8Array([1, 2, 3]),
  buffer: Buffer.from('hello'),

  // Date objects
  date: new Date(),

  // RegExp
  regex: /pattern/gi,

  // Map and Set
  map: new Map([['key', 'value']]),
  set: new Set([1, 2, 3]),

  // Error objects
  error: new Error('something broke'),

  // BigInt
  bigint_val: 42n,

  // undefined (as object values — top-level undefined is dropped)
  undef: undefined
};

// You would send each like: child.send(validMessages);
console.log('Valid message types:', Object.keys(validMessages));
```

### What Does Not Work

```javascript
'use strict';

// These CANNOT be sent via IPC:

// 1. Functions
const withFunction = {
  callback: () => console.log('hello')
};
// TypeError: function could not be cloned

// 2. Symbols
const withSymbol = {
  id: Symbol('unique')
};
// Symbols cannot be serialized

// 3. Circular references (in JSON mode — structured clone handles these)
const circular = {};
circular.self = circular;
// Works with structured clone, fails with JSON serialization

// 4. WeakMap and WeakSet
const withWeak = {
  cache: new WeakMap()
};
// Cannot be cloned

// 5. Streams, sockets, file descriptors
// These are OS-level handles — they don't survive serialization

// 6. Class instances lose their prototype chain
class MyClass {
  constructor(value) { this.value = value; }
  compute() { return this.value * 2; }
}
const instance = new MyClass(21);
// After IPC: { value: 21 } — plain object, compute() is gone
```

### Handling Serialization Gracefully

```javascript
'use strict';

// Parent-side message wrapper that validates before sending
function safeSend(child, message) {
  try {
    // Test serialization before sending
    // (structured clone is used internally, but JSON check catches most issues)
    JSON.stringify(message);
    child.send(message);
    return true;
  } catch (err) {
    console.error('Cannot serialize message:', err.message);
    return false;
  }
}

// A more robust approach: define a message schema
function createMessage(type, payload) {
  return {
    type,
    payload,
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    timestamp: Date.now()
  };
}

// Usage:
// const msg = createMessage('compute', { n: 42, operation: 'fibonacci' });
// safeSend(child, msg);
```

---

## Pattern 1: Fire-and-Forget

The simplest IPC pattern. The parent sends a message and does not expect a response. Useful for logging, metrics, and notifications.

```javascript
'use strict';

// === Parent (fire-and-forget-parent.js) ===
const { fork } = require('node:child_process');
const path = require('node:path');

const logger = fork(path.join(__dirname, 'fire-and-forget-logger.js'));

// Send log entries to the child — don't wait for acknowledgment
function log(level, message, meta = {}) {
  logger.send({
    type: 'log',
    level,
    message,
    meta,
    timestamp: Date.now(),
    pid: process.pid
  });
}

// Simulate application activity
log('info', 'Application starting');
log('info', 'Loading configuration', { file: 'config.json' });
log('warn', 'Deprecated API called', { endpoint: '/v1/users' });
log('error', 'Database connection failed', { host: 'db.example.com' });
log('info', 'Application ready', { port: 3000 });

// Shut down the logger after a delay
setTimeout(() => {
  logger.send({ type: 'shutdown' });
}, 1000);

logger.on('exit', () => {
  console.log('[Parent] Logger process exited');
});
```

```javascript
'use strict';

// === Child (fire-and-forget-logger.js) ===
const fs = require('node:fs');
const path = require('node:path');

const logPath = path.join('/tmp', 'app.log');
const stream = fs.createWriteStream(logPath, { flags: 'a' });

process.on('message', (msg) => {
  if (msg.type === 'shutdown') {
    stream.end(() => process.exit(0));
    return;
  }

  if (msg.type === 'log') {
    const line = JSON.stringify({
      time: new Date(msg.timestamp).toISOString(),
      level: msg.level,
      msg: msg.message,
      pid: msg.pid,
      ...msg.meta
    });
    stream.write(line + '\n');
  }
});

process.send({ type: 'ready' });
```

---

## Pattern 2: Request-Response with Correlation IDs

When the parent needs a result back from the child, you need a way to match responses to requests. The standard approach is **correlation IDs**: each request carries a unique ID, and the child includes that ID in the response.

```javascript
'use strict';

// === Parent (request-response-parent.js) ===
const { fork } = require('node:child_process');
const path = require('node:path');
const crypto = require('node:crypto');

const worker = fork(path.join(__dirname, 'request-response-worker.js'));

// Store pending requests keyed by correlation ID
const pending = new Map();

// Listen for responses
worker.on('message', (msg) => {
  if (msg.type === 'response') {
    const entry = pending.get(msg.correlationId);
    if (entry) {
      pending.delete(msg.correlationId);
      clearTimeout(entry.timer);

      if (msg.error) {
        entry.reject(new Error(msg.error));
      } else {
        entry.resolve(msg.result);
      }
    }
  }
});

function request(action, data, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const correlationId = crypto.randomUUID();

    const timer = setTimeout(() => {
      pending.delete(correlationId);
      reject(new Error(`Request ${correlationId} timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    pending.set(correlationId, { resolve, reject, timer });

    worker.send({
      type: 'request',
      correlationId,
      action,
      data
    });
  });
}

// Usage
async function main() {
  try {
    const sum = await request('add', { a: 10, b: 20 });
    console.log('Sum:', sum); // 30

    const fib = await request('fibonacci', { n: 35 });
    console.log('Fibonacci(35):', fib);

    const fail = await request('unknown', {});
    console.log('Should not reach here:', fail);
  } catch (err) {
    console.error('Request failed:', err.message);
  }

  worker.disconnect();
}

main();
```

```javascript
'use strict';

// === Child (request-response-worker.js) ===
function fibonacci(n) {
  if (n <= 1) return n;
  return fibonacci(n - 1) + fibonacci(n - 2);
}

const handlers = {
  add: (data) => data.a + data.b,
  multiply: (data) => data.a * data.b,
  fibonacci: (data) => fibonacci(data.n)
};

process.on('message', (msg) => {
  if (msg.type !== 'request') return;

  const handler = handlers[msg.action];

  if (!handler) {
    process.send({
      type: 'response',
      correlationId: msg.correlationId,
      error: `Unknown action: ${msg.action}`
    });
    return;
  }

  try {
    const result = handler(msg.data);
    process.send({
      type: 'response',
      correlationId: msg.correlationId,
      result
    });
  } catch (err) {
    process.send({
      type: 'response',
      correlationId: msg.correlationId,
      error: err.message
    });
  }
});
```

---

## Pattern 3: Pub/Sub Between Workers

When you have multiple forked workers, the parent can act as a message broker:

```javascript
'use strict';

// === Parent (pubsub-parent.js) ===
const { fork } = require('node:child_process');
const path = require('node:path');

const workers = [];
const subscriptions = new Map(); // topic → Set of workers

// Spawn 3 workers
for (let i = 0; i < 3; i++) {
  const worker = fork(path.join(__dirname, 'pubsub-worker.js'));
  worker.workerId = i;
  workers.push(worker);

  worker.on('message', (msg) => {
    if (msg.type === 'subscribe') {
      if (!subscriptions.has(msg.topic)) {
        subscriptions.set(msg.topic, new Set());
      }
      subscriptions.get(msg.topic).add(worker);
      console.log(`Worker ${i} subscribed to '${msg.topic}'`);
    }

    if (msg.type === 'publish') {
      const subscribers = subscriptions.get(msg.topic) || new Set();
      for (const sub of subscribers) {
        if (sub !== worker) { // Don't echo back to sender
          sub.send({ type: 'event', topic: msg.topic, data: msg.data, from: i });
        }
      }
    }
  });
}

// Give workers time to subscribe, then trigger a publish
setTimeout(() => {
  workers[0].send({ type: 'trigger-publish', topic: 'updates', data: { version: '2.0' } });
}, 500);

// Cleanup after demo
setTimeout(() => {
  for (const w of workers) w.disconnect();
}, 2000);
```

---

## Disconnecting and Cleanup

The IPC channel keeps both processes alive. You must explicitly disconnect when communication is done.

```javascript
'use strict';

const { fork } = require('node:child_process');
const path = require('node:path');

const child = fork(path.join(__dirname, 'long-running-worker.js'));

// Check if the channel is open
console.log('Connected:', child.connected); // true

// Listen for disconnect
child.on('disconnect', () => {
  console.log('[Parent] IPC channel closed');
});

// Method 1: Parent disconnects
// child.disconnect();

// Method 2: Child disconnects
// (In the child: process.disconnect())

// Method 3: Child exits — channel closes automatically
child.on('exit', (code) => {
  console.log('Connected after exit:', child.connected); // false
});

// Tell the child to exit after some work
setTimeout(() => {
  child.send({ type: 'shutdown' });
}, 1000);
```

### Avoiding Orphaned Channels

If neither side disconnects and the child has no reason to exit, the parent process will hang — it waits for the child to close. Always design a shutdown protocol:

```javascript
'use strict';

const { fork } = require('node:child_process');
const path = require('node:path');

function createManagedWorker(script) {
  const worker = fork(script);
  let isShuttingDown = false;

  function shutdown(timeoutMs = 5000) {
    if (isShuttingDown) return;
    isShuttingDown = true;

    return new Promise((resolve) => {
      // Ask the child to exit gracefully
      if (worker.connected) {
        worker.send({ type: 'shutdown' });
      }

      // If it doesn't exit in time, kill it
      const timer = setTimeout(() => {
        console.log('Worker did not exit in time, killing...');
        worker.kill('SIGKILL');
      }, timeoutMs);

      worker.on('exit', () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }

  return { worker, shutdown };
}

// Usage:
// const { worker, shutdown } = createManagedWorker('./worker.js');
// worker.send({ type: 'task', data: 'process this' });
// await shutdown();
```

---

## Performance Considerations

IPC is not free. Every message crosses a process boundary, which involves:

1. **Serialization** — converting the JavaScript object to bytes (structured clone algorithm)
2. **System call** — writing to and reading from the Unix domain socket
3. **Deserialization** — reconstructing the object in the other process

### Benchmarking IPC Throughput

```javascript
'use strict';

const { fork } = require('node:child_process');
const path = require('node:path');

// This benchmark measures round-trip IPC latency
const child = fork(path.join(__dirname, 'echo-worker.js'));

const ITERATIONS = 10_000;
let completed = 0;
let startTime;

child.on('message', () => {
  completed += 1;
  if (completed === ITERATIONS) {
    const elapsed = Number(process.hrtime.bigint() - startTime) / 1_000_000;
    console.log(`${ITERATIONS} round-trips in ${elapsed.toFixed(1)} ms`);
    console.log(`${(elapsed / ITERATIONS).toFixed(3)} ms per round-trip`);
    console.log(`${Math.floor(ITERATIONS / (elapsed / 1000))} messages/sec`);
    child.disconnect();
  }
});

// Wait for worker to be ready
child.once('message', () => {
  startTime = process.hrtime.bigint();
  for (let i = 0; i < ITERATIONS; i++) {
    child.send({ i });
  }
});
```

```javascript
'use strict';

// echo-worker.js — echoes every message back
process.send({ type: 'ready' });

process.on('message', (msg) => {
  process.send(msg);
});
```

### Message Size Guidelines

| Message Size | Recommendation |
|-------------|----------------|
| < 1 KB | Ideal — fast serialization, minimal overhead |
| 1 KB - 100 KB | Fine for most use cases |
| 100 KB - 1 MB | Measure latency — consider chunking or shared files |
| > 1 MB | Use the filesystem or shared memory instead of IPC |

For large data, write to a temporary file and send only the file path over IPC. The child reads the file directly. This avoids serialization overhead and memory duplication.

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

// Instead of sending large data through IPC:
// child.send({ type: 'data', payload: hugeArray }); // BAD

// Write to a temp file and send the path:
function sendLargeData(child, data) {
  const tmpPath = path.join('/tmp', `ipc-${Date.now()}-${process.pid}.json`);
  fs.writeFileSync(tmpPath, JSON.stringify(data));
  child.send({ type: 'data-file', path: tmpPath });
}

// The child reads the file, processes it, and cleans up:
// process.on('message', (msg) => {
//   if (msg.type === 'data-file') {
//     const data = JSON.parse(fs.readFileSync(msg.path, 'utf8'));
//     fs.unlinkSync(msg.path); // Clean up
//     // process data...
//   }
// });
```

---

## Passing Server Handles

A unique feature of Node.js IPC: you can send TCP server or socket handles to child processes. This is how the `cluster` module works internally.

```javascript
'use strict';

const { fork } = require('node:child_process');
const net = require('node:net');
const path = require('node:path');

// Parent creates a TCP server and passes connections to a child
const child = fork(path.join(__dirname, 'handle-worker.js'));

const server = net.createServer((socket) => {
  // Send the socket handle to the child for processing
  child.send({ type: 'connection' }, socket);
});

server.listen(8080, () => {
  console.log('Server listening on port 8080');
  console.log('Connections will be handled by child process');
});

// After 10 seconds, shut down
setTimeout(() => {
  server.close();
  child.disconnect();
}, 10_000);
```

```javascript
'use strict';

// handle-worker.js — receives socket handles from the parent
process.on('message', (msg, socket) => {
  if (msg.type === 'connection' && socket) {
    socket.end(`Handled by worker PID ${process.pid}\n`);
  }
});
```

---

## Key Takeaways

- The IPC channel created by `fork()` is a bidirectional Unix domain socket (or named pipe on Windows) that automatically serializes/deserializes JavaScript objects using the structured clone algorithm.
- Functions, Symbols, WeakMaps, and class prototype chains cannot survive IPC serialization — design your message format around plain objects, arrays, and primitives.
- Use correlation IDs to implement request-response patterns over the inherently asynchronous IPC channel, with timeouts to prevent orphaned promises.
- IPC adds measurable overhead (serialization + system calls); keep messages under 100 KB and use the filesystem for large payloads.
- Always design a shutdown protocol — disconnect the IPC channel explicitly or the parent process will hang waiting for the child.

---

## Next

In the next lesson you will learn how Unix signals control the process lifecycle — handling `SIGINT`, `SIGTERM`, and `SIGHUP` to build graceful shutdown patterns that production servers demand.
