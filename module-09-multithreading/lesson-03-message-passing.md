# Module 09 / Lesson 03 — Message Passing Between Threads

> Threads that cannot communicate are useless. In Node.js, the primary communication mechanism between worker threads is message passing via `postMessage()`. Under the hood, this uses the structured clone algorithm to deep-copy data across thread boundaries. This lesson explores every facet of inter-thread communication — structured clone semantics, `MessageChannel` and `MessagePort` for direct thread-to-thread channels, transferable objects for zero-copy ArrayBuffer handoffs, and the serialization overhead you need to account for.

## Learning Objectives

- Explain how `postMessage()` uses the structured clone algorithm to deep-copy messages
- Identify which JavaScript types can be cloned and which cannot
- Create direct communication channels between workers using `MessageChannel` and `MessagePort`
- Transfer `ArrayBuffer` ownership between threads for zero-copy performance using `transferList`
- Measure and minimize serialization overhead in high-throughput messaging scenarios

---

## Structured Clone: How postMessage Works

When you call `worker.postMessage(data)` from the main thread (or `parentPort.postMessage(data)` from a worker), Node.js does not send a reference. It creates a deep copy of `data` using the **structured clone algorithm** and delivers that copy to the receiving thread.

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename);

  const original = {
    name: 'Alice',
    scores: [95, 87, 92],
    metadata: { created: new Date(), active: true },
  };

  worker.postMessage(original);

  // Modify the original after sending — the worker's copy is unaffected
  original.name = 'MODIFIED';
  original.scores.push(100);

  worker.on('message', (msg) => {
    console.log('Worker saw:', msg);
    // { name: 'Alice', scores: [95, 87, 92], metadata: { created: ..., active: true } }
    // The worker received the original values — proof that it is a deep copy
  });
} else {
  parentPort.on('message', (msg) => {
    parentPort.postMessage(msg);
  });
}
```

### What Structured Clone Supports

The structured clone algorithm handles most built-in JavaScript types:

| Supported | Not Supported |
|-----------|---------------|
| Primitives (string, number, boolean, null, undefined, BigInt) | Functions |
| Plain objects and arrays | Symbols |
| `Date` | DOM nodes (browser-only, irrelevant in Node.js) |
| `RegExp` | `WeakMap`, `WeakSet`, `WeakRef` |
| `Map`, `Set` | Closures |
| `ArrayBuffer`, `SharedArrayBuffer` | Class prototypes (objects are cloned as plain objects) |
| Typed arrays (`Uint8Array`, `Int32Array`, etc.) | `Error` objects (partially — message is preserved, custom properties may not be) |
| `Blob` (Node.js 18+) | Property getters/setters |

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename);

  // These all clone successfully
  worker.postMessage({
    str: 'hello',
    num: 42,
    big: 123456789n,
    date: new Date(),
    regex: /^foo\d+$/gi,
    map: new Map([['key', 'value']]),
    set: new Set([1, 2, 3]),
    buffer: new Uint8Array([10, 20, 30]).buffer,
    typed: new Float64Array([1.1, 2.2, 3.3]),
  });

  // This throws DataCloneError — functions cannot be cloned
  try {
    worker.postMessage({ fn: () => 'hello' });
  } catch (err) {
    console.error(`Cannot clone: ${err.message}`);
  }

  worker.on('message', (msg) => {
    console.log('Round-tripped:', typeof msg.date, msg.regex, msg.map.size);
  });
} else {
  parentPort.on('message', (msg) => {
    parentPort.postMessage(msg);
  });
}
```

### Class Instances Lose Their Prototype

When you clone an object that is an instance of a class, the clone is a plain object. Methods and the prototype chain are not preserved:

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');

class Task {
  constructor(name, priority) {
    this.name = name;
    this.priority = priority;
  }

  describe() {
    return `${this.name} (priority: ${this.priority})`;
  }
}

if (isMainThread) {
  const worker = new Worker(__filename);
  const task = new Task('compile', 5);

  console.log(`Before clone: ${task.describe()}`); // Works
  console.log(`Is Task? ${task instanceof Task}`);  // true

  worker.postMessage(task);

  worker.on('message', (msg) => {
    console.log(`After clone: name=${msg.name}, priority=${msg.priority}`);
    console.log(`Is Task? ${msg instanceof Task}`); // false — plain object
    // msg.describe is undefined — methods are not cloned
  });
} else {
  parentPort.on('message', (msg) => {
    parentPort.postMessage(msg);
  });
}
```

To preserve class behavior across threads, serialize to plain objects and reconstruct on the other side:

```javascript
// Worker receives plain data and reconstructs
parentPort.on('message', (msg) => {
  const task = new Task(msg.name, msg.priority);
  // Now task.describe() works
});
```

---

## MessageChannel and MessagePort

By default, each worker has one communication channel — the implicit channel between `parentPort` (worker side) and the `worker` instance (main thread side). But what if you need two workers to communicate directly? That is where `MessageChannel` comes in.

A `MessageChannel` creates a pair of connected `MessagePort` objects. Anything sent on `port1` arrives on `port2`, and vice versa:

```javascript
'use strict';

const { Worker, isMainThread, parentPort, MessageChannel } = require('node:worker_threads');

if (isMainThread) {
  // Create two workers
  const workerA = new Worker(__filename);
  const workerB = new Worker(__filename);

  // Create a direct channel between them
  const { port1, port2 } = new MessageChannel();

  // Transfer port1 to workerA and port2 to workerB
  workerA.postMessage({ type: 'CONNECT', port: port1 }, [port1]);
  workerB.postMessage({ type: 'CONNECT', port: port2 }, [port2]);

  // Now workerA and workerB can talk directly — the main thread is not involved
  workerA.postMessage({ type: 'SEND', text: 'Hello from main via A' });

  workerA.on('message', (msg) => console.log('[main from A]:', msg));
  workerB.on('message', (msg) => console.log('[main from B]:', msg));
} else {
  let peerPort = null;

  parentPort.on('message', (msg) => {
    if (msg.type === 'CONNECT') {
      peerPort = msg.port;
      peerPort.on('message', (peerMsg) => {
        parentPort.postMessage(`Received from peer: ${peerMsg}`);
      });
    } else if (msg.type === 'SEND') {
      if (peerPort) {
        peerPort.postMessage(msg.text);
      }
    }
  });
}
```

The key line is the second argument to `postMessage`: the **transfer list**. When you transfer a `MessagePort`, ownership moves to the receiving thread. The sender can no longer use it. This is the same mechanism used for `ArrayBuffer` transfers (covered next).

### When to Use MessageChannel

- **Worker-to-worker communication** without routing through the main thread
- **Multiple independent channels** to the same worker (e.g., one for tasks, one for logs)
- **Dedicated control channels** separate from data channels

```javascript
'use strict';

const { Worker, isMainThread, parentPort, MessageChannel } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename);

  // Channel 1: Task data
  const taskChannel = new MessageChannel();
  // Channel 2: Health monitoring
  const healthChannel = new MessageChannel();

  worker.postMessage(
    { taskPort: taskChannel.port1, healthPort: healthChannel.port1 },
    [taskChannel.port1, healthChannel.port1]
  );

  // Send tasks on the task channel
  taskChannel.port2.on('message', (msg) => {
    console.log(`Task result: ${msg}`);
  });
  taskChannel.port2.postMessage({ compute: 42 });

  // Monitor health on the health channel
  healthChannel.port2.on('message', (msg) => {
    console.log(`Health: ${JSON.stringify(msg)}`);
  });

  setInterval(() => {
    healthChannel.port2.postMessage('ping');
  }, 1000);
} else {
  parentPort.once('message', ({ taskPort, healthPort }) => {
    taskPort.on('message', (msg) => {
      taskPort.postMessage(`Result for ${msg.compute}: ${msg.compute * 2}`);
    });

    healthPort.on('message', () => {
      healthPort.postMessage({
        memory: process.memoryUsage().heapUsed,
        uptime: process.uptime(),
      });
    });
  });
}
```

---

## Transferable Objects: Zero-Copy ArrayBuffer

Structured cloning copies data. For large `ArrayBuffer` objects, this copy is expensive. The **transfer list** offers an alternative: instead of copying, you transfer ownership of the buffer to the receiving thread. The original thread loses access entirely.

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename);

  // Create a 10 MB buffer
  const buffer = new ArrayBuffer(10 * 1024 * 1024);
  const view = new Uint8Array(buffer);
  view[0] = 42;

  console.log(`Before transfer: buffer.byteLength = ${buffer.byteLength}`);
  // 10485760

  // Transfer (not clone) the buffer to the worker
  worker.postMessage({ buffer }, [buffer]);

  console.log(`After transfer: buffer.byteLength = ${buffer.byteLength}`);
  // 0 — the buffer has been neutered. We no longer own it.

  try {
    console.log(view[0]); // Throws or returns undefined — buffer is detached
  } catch (err) {
    console.error(`Cannot access: ${err.message}`);
  }

  worker.on('message', (msg) => {
    console.log(`Worker read: ${msg}`);
  });
} else {
  parentPort.on('message', (msg) => {
    const view = new Uint8Array(msg.buffer);
    parentPort.postMessage(`First byte: ${view[0]}`);
  });
}
```

### Transfer vs Clone: Performance Comparison

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const SIZE = 50 * 1024 * 1024; // 50 MB

  // --- Clone benchmark ---
  const cloneWorker = new Worker(__filename);
  const cloneBuffer = new ArrayBuffer(SIZE);
  new Uint8Array(cloneBuffer).fill(1);

  let cloneStart = Date.now();
  cloneWorker.postMessage({ buffer: cloneBuffer, mode: 'clone' });
  // No transfer list — buffer is deep-copied

  cloneWorker.on('message', (msg) => {
    if (msg.mode === 'clone') {
      console.log(`Clone 50 MB: ${msg.elapsed} ms (worker side)`);
      console.log(`Clone total: ${Date.now() - cloneStart} ms`);
      console.log(`Original still valid: ${cloneBuffer.byteLength} bytes`);
      cloneWorker.terminate();

      // --- Transfer benchmark ---
      const transferWorker = new Worker(__filename);
      const transferBuffer = new ArrayBuffer(SIZE);
      new Uint8Array(transferBuffer).fill(2);

      const transferStart = Date.now();
      transferWorker.postMessage(
        { buffer: transferBuffer, mode: 'transfer' },
        [transferBuffer]  // Transfer list
      );

      transferWorker.on('message', (msg2) => {
        console.log(`\nTransfer 50 MB: ${msg2.elapsed} ms (worker side)`);
        console.log(`Transfer total: ${Date.now() - transferStart} ms`);
        console.log(`Original detached: ${transferBuffer.byteLength} bytes`);
        transferWorker.terminate();
      });
    }
  });
} else {
  parentPort.on('message', (msg) => {
    const start = Date.now();
    const view = new Uint8Array(msg.buffer);
    const sum = view[0] + view[view.length - 1]; // Access to prove we have data
    const elapsed = Date.now() - start;
    parentPort.postMessage({ mode: msg.mode, elapsed, sum });
  });
}
```

Typical results: cloning 50 MB takes 20-100 ms. Transferring takes <1 ms. The difference is dramatic for large buffers.

### What Can Be Transferred?

- `ArrayBuffer`
- `MessagePort`
- `FileHandle` (from `fs.promises.open`)

`SharedArrayBuffer` is never transferred — it is always shared by reference. You do not need to put it in the transfer list.

---

## SharedArrayBuffer: The Third Option

Besides cloning and transferring, there is a third way: sharing. `SharedArrayBuffer` instances are visible to all threads simultaneously without copying or transferring:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  // Allocate shared memory
  const shared = new SharedArrayBuffer(1024);
  const view = new Uint8Array(shared);

  // Write some data
  view[0] = 10;
  view[1] = 20;
  view[2] = 30;

  // Pass to worker via workerData — SharedArrayBuffer is NOT cloned
  const worker = new Worker(__filename, { workerData: { shared } });

  worker.on('message', () => {
    // Worker modified the same memory — we see the changes immediately
    console.log(`Main sees: [${view[0]}, ${view[1]}, ${view[2]}]`);
    // [100, 200, 30] — worker changed first two bytes
  });
} else {
  const view = new Uint8Array(workerData.shared);

  // Modify shared memory — main thread sees these changes
  view[0] = 100;
  view[1] = 200;

  parentPort.postMessage('done');
}
```

We will cover `SharedArrayBuffer` in depth in Lesson 04, including the `Atomics` API for safe concurrent access.

---

## Serialization Overhead: Measuring the Cost

Every `postMessage` call involves serialization (sender side) and deserialization (receiver side). For small messages, this is negligible. For large or frequent messages, it can become a bottleneck.

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');
const { performance } = require('node:perf_hooks');

if (isMainThread) {
  const worker = new Worker(__filename);

  const payloads = {
    tiny: { x: 1 },
    small: { data: 'a'.repeat(1000) },
    medium: { data: 'a'.repeat(100_000) },
    large: { data: 'a'.repeat(1_000_000) },
    array: { data: new Array(10_000).fill({ id: 1, name: 'test', value: 42.5 }) },
  };

  let pending = Object.keys(payloads).length;

  worker.on('message', (msg) => {
    if (msg.type === 'ready') {
      // Send each payload and measure round-trip time
      for (const [name, payload] of Object.entries(payloads)) {
        const start = performance.now();
        worker.postMessage({ name, payload, sendTime: start });
      }
    } else if (msg.type === 'echo') {
      const rtt = performance.now() - msg.sendTime;
      console.log(`${msg.name.padEnd(8)} round-trip: ${rtt.toFixed(2)} ms`);
      pending--;
      if (pending === 0) worker.terminate();
    }
  });
} else {
  parentPort.postMessage({ type: 'ready' });

  parentPort.on('message', (msg) => {
    // Echo back with the original send time for RTT measurement
    parentPort.postMessage({
      type: 'echo',
      name: msg.name,
      sendTime: msg.sendTime,
    });
  });
}
```

### Strategies for Reducing Overhead

1. **Batch messages.** Instead of sending 1,000 small messages, collect them and send one large message.

2. **Use typed arrays instead of objects.** A `Float64Array` serializes as a compact binary blob. An array of objects serializes each key, value, and type individually.

3. **Transfer large ArrayBuffers** instead of cloning them.

4. **Use SharedArrayBuffer** for data that both threads need to access repeatedly.

5. **Minimize message frequency.** Send results, not progress. If you must report progress, batch updates (e.g., every 1,000 iterations, not every iteration).

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename);

  // BAD: Sending 10,000 individual messages
  // for (let i = 0; i < 10_000; i++) {
  //   worker.postMessage({ id: i, value: Math.random() });
  // }

  // GOOD: Send one batch
  const batch = new Float64Array(10_000);
  for (let i = 0; i < 10_000; i++) {
    batch[i] = Math.random();
  }

  // Even better: transfer the underlying buffer
  worker.postMessage({ batch: batch.buffer }, [batch.buffer]);

  worker.on('message', (msg) => {
    console.log(`Processed ${msg.count} items, sum = ${msg.sum.toFixed(2)}`);
    worker.terminate();
  });
} else {
  parentPort.on('message', (msg) => {
    const batch = new Float64Array(msg.batch);
    let sum = 0;
    for (let i = 0; i < batch.length; i++) {
      sum += batch[i];
    }
    parentPort.postMessage({ count: batch.length, sum });
  });
}
```

---

## Practical Pattern: Request-Response with Correlation IDs

In production thread pools, the main thread sends tasks and must match responses to the original requests. The standard pattern uses correlation IDs:

```javascript
'use strict';

const { Worker, isMainThread, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename);
  const pending = new Map();
  let nextId = 0;

  function sendTask(payload) {
    return new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      worker.postMessage({ id, payload });
    });
  }

  worker.on('message', (msg) => {
    const handler = pending.get(msg.id);
    if (!handler) return;
    pending.delete(msg.id);

    if (msg.error) {
      handler.reject(new Error(msg.error));
    } else {
      handler.resolve(msg.result);
    }
  });

  // Use it with async/await
  (async () => {
    try {
      const r1 = await sendTask({ action: 'square', value: 7 });
      console.log(`square(7) = ${r1}`);

      const r2 = await sendTask({ action: 'factorial', value: 10 });
      console.log(`factorial(10) = ${r2}`);

      const r3 = await sendTask({ action: 'unknown', value: 0 });
    } catch (err) {
      console.error(`Error: ${err.message}`);
    }

    worker.terminate();
  })();
} else {
  function factorial(n) {
    let result = 1n;
    for (let i = 2n; i <= BigInt(n); i++) result *= i;
    return result.toString();
  }

  parentPort.on('message', (msg) => {
    const { id, payload } = msg;

    try {
      let result;
      switch (payload.action) {
        case 'square':
          result = payload.value * payload.value;
          break;
        case 'factorial':
          result = factorial(payload.value);
          break;
        default:
          throw new Error(`Unknown action: ${payload.action}`);
      }
      parentPort.postMessage({ id, result });
    } catch (err) {
      parentPort.postMessage({ id, error: err.message });
    }
  });
}
```

This pattern forms the backbone of every thread pool implementation. Lesson 06 will build a full pool around it.

---

## MessagePort Lifecycle

A `MessagePort` can be explicitly closed and has its own event lifecycle:

```javascript
'use strict';

const { MessageChannel } = require('node:worker_threads');

const { port1, port2 } = new MessageChannel();

port2.on('message', (msg) => {
  console.log(`port2 received: ${msg}`);
});

port2.on('close', () => {
  console.log('port2: channel closed');
});

port1.postMessage('hello');
port1.postMessage('world');

// Close the channel — no more messages can be sent
port1.close();

// This will not be received
try {
  port1.postMessage('after close');
} catch (err) {
  console.error(`Cannot send: ${err.message}`);
}
```

Ports must be explicitly started when received via `postMessage`. In worker threads, `parentPort` and ports received through `workerData` are started automatically. Ports received via `postMessage` in a `message` event need manual starting by adding a `message` listener (which implicitly calls `.start()`).

---

## Key Takeaways

- `postMessage()` uses the structured clone algorithm to deep-copy data — functions, Symbols, and WeakMaps cannot be cloned, and class prototypes are lost
- `MessageChannel` creates a pair of connected `MessagePort` objects for direct thread-to-thread communication without routing through the main thread
- Use the `transferList` (second argument to `postMessage`) to transfer `ArrayBuffer` ownership for zero-copy performance — the sender loses access but avoids the cost of copying
- `SharedArrayBuffer` is neither cloned nor transferred — it is shared by reference, visible to all threads simultaneously, and requires `Atomics` for safe concurrent access
- Serialization overhead is real — batch messages, prefer typed arrays over objects, and transfer large buffers rather than cloning them

## Next

In the next lesson, we explore `SharedArrayBuffer` and the `Atomics` API — the low-level primitives that let threads share memory safely, wait for each other, and perform atomic read-modify-write operations without data races.
