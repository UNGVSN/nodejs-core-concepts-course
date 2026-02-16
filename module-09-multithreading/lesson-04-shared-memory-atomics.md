# Module 09 / Lesson 04 — SharedArrayBuffer & Atomics

> Message passing copies data. For high-frequency, low-latency communication between threads, copying is too expensive. `SharedArrayBuffer` gives you raw shared memory — a region of bytes visible to every thread simultaneously, with zero copying. But shared memory without synchronization is a recipe for data corruption. The `Atomics` API provides the atomic operations and synchronization primitives you need to use shared memory safely.

## Learning Objectives

- Create `SharedArrayBuffer` instances and access them from multiple threads simultaneously
- Use `Atomics.add`, `Atomics.sub`, `Atomics.load`, and `Atomics.store` for safe concurrent reads and writes
- Synchronize threads with `Atomics.wait` and `Atomics.notify` for blocking coordination
- Build typed array views (`Int32Array`, `Uint8Array`, `Float64Array`) on top of shared memory
- Understand the memory model: why ordinary reads and writes on shared memory are unsafe

---

## SharedArrayBuffer: Shared Memory in Node.js

A `SharedArrayBuffer` is like an `ArrayBuffer`, but it can be shared across threads without copying. When you pass a `SharedArrayBuffer` to a worker via `workerData` or `postMessage`, both threads see the exact same bytes in memory.

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  // Allocate 16 bytes of shared memory
  const sab = new SharedArrayBuffer(16);

  // Create a view to write integers
  const view = new Int32Array(sab); // 4 elements (4 bytes each = 16 bytes)
  view[0] = 100;
  view[1] = 200;
  view[2] = 300;
  view[3] = 400;

  const worker = new Worker(__filename, { workerData: { sab } });

  worker.on('message', () => {
    // Worker modified element [2] — we see the change immediately
    console.log(`Main reads: [${view[0]}, ${view[1]}, ${view[2]}, ${view[3]}]`);
    // [100, 200, 999, 400] — element [2] was changed by the worker
  });
} else {
  const view = new Int32Array(workerData.sab);

  // Direct memory write — main thread sees this change
  view[2] = 999;

  parentPort.postMessage('done');
}
```

### Key Properties

- `SharedArrayBuffer` is not cloned by `postMessage` or `workerData` — it is shared by reference
- You cannot read or write a `SharedArrayBuffer` directly — you must create a typed array view on top of it
- All threads that receive the same `SharedArrayBuffer` see the same bytes
- Writes from one thread are eventually visible to other threads, but without `Atomics`, the timing is undefined

---

## Typed Array Views on Shared Memory

A `SharedArrayBuffer` is just a block of bytes. To read and write meaningful values, you overlay a typed array view:

```javascript
'use strict';

const sab = new SharedArrayBuffer(32);

// Different views on the same shared memory
const int32View  = new Int32Array(sab);   // 8 elements (32 / 4)
const uint8View  = new Uint8Array(sab);   // 32 elements (32 / 1)
const float64View = new Float64Array(sab); // 4 elements (32 / 8)

// Writing via one view is visible through another
int32View[0] = 42;
console.log(uint8View[0]); // 42 (little-endian: low byte of int32)

float64View[0] = 3.14;
console.log(int32View[0]); // Some integer — reinterpreted bytes
```

In multi-threaded scenarios, you typically standardize on one view type per region:

```javascript
'use strict';

const sab = new SharedArrayBuffer(256);

// First 16 bytes: 4 x Int32 for counters
const counters = new Int32Array(sab, 0, 4);

// Next 32 bytes: 4 x Float64 for metrics
const metrics = new Float64Array(sab, 16, 4);

// Remaining bytes: raw data
const data = new Uint8Array(sab, 48);
```

The second argument is the byte offset, and the third is the element count. This lets you partition a single `SharedArrayBuffer` into multiple regions.

---

## Why Ordinary Read/Write Is Unsafe

On modern CPUs, a simple read-modify-write operation like `view[0] = view[0] + 1` is not atomic. It compiles to multiple instructions:

1. Load the value from memory into a register
2. Add 1 to the register
3. Store the result back to memory

If two threads execute this simultaneously, they can both load the same value, both add 1, and both store the same result — losing one increment:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const sab = new SharedArrayBuffer(4);
  const counter = new Int32Array(sab);
  counter[0] = 0;

  const ITERATIONS = 1_000_000;
  const NUM_WORKERS = 4;

  const workers = [];
  let exited = 0;

  for (let i = 0; i < NUM_WORKERS; i++) {
    const w = new Worker(__filename, {
      workerData: { sab, iterations: ITERATIONS },
    });
    w.on('exit', () => {
      exited++;
      if (exited === NUM_WORKERS) {
        console.log(`Final counter: ${counter[0]}`);
        console.log(`Expected:      ${ITERATIONS * NUM_WORKERS}`);
        console.log(`Lost updates:  ${ITERATIONS * NUM_WORKERS - counter[0]}`);
      }
    });
    workers.push(w);
  }
} else {
  const counter = new Int32Array(workerData.sab);
  for (let i = 0; i < workerData.iterations; i++) {
    // UNSAFE: non-atomic read-modify-write
    counter[0] = counter[0] + 1;
  }
}
```

Run this multiple times. The final counter will be significantly less than 4,000,000. This is a data race. The `Atomics` API fixes it.

---

## Atomics.add and Atomics.sub

`Atomics.add()` performs a read-modify-write operation as a single, indivisible (atomic) step. No other thread can see a half-completed state:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const sab = new SharedArrayBuffer(4);
  const counter = new Int32Array(sab);
  counter[0] = 0;

  const ITERATIONS = 1_000_000;
  const NUM_WORKERS = 4;

  let exited = 0;

  for (let i = 0; i < NUM_WORKERS; i++) {
    const w = new Worker(__filename, {
      workerData: { sab, iterations: ITERATIONS },
    });
    w.on('exit', () => {
      exited++;
      if (exited === NUM_WORKERS) {
        const final = Atomics.load(counter, 0);
        console.log(`Final counter: ${final}`);
        console.log(`Expected:      ${ITERATIONS * NUM_WORKERS}`);
        console.log(`Match: ${final === ITERATIONS * NUM_WORKERS}`);
        // Match: true — always exactly 4,000,000
      }
    });
  }
} else {
  const counter = new Int32Array(workerData.sab);
  for (let i = 0; i < workerData.iterations; i++) {
    // SAFE: atomic read-modify-write
    Atomics.add(counter, 0, 1);
  }
}
```

`Atomics.add(typedArray, index, value)` atomically adds `value` to the element at `index` and returns the old value. `Atomics.sub()` does the same for subtraction:

```javascript
'use strict';

const sab = new SharedArrayBuffer(4);
const view = new Int32Array(sab);
view[0] = 100;

const oldValue = Atomics.add(view, 0, 5);
console.log(`Old: ${oldValue}, New: ${Atomics.load(view, 0)}`);
// Old: 100, New: 105

const oldValue2 = Atomics.sub(view, 0, 10);
console.log(`Old: ${oldValue2}, New: ${Atomics.load(view, 0)}`);
// Old: 105, New: 95
```

---

## Atomics.load and Atomics.store

For plain reads and writes (without arithmetic), use `Atomics.load()` and `Atomics.store()`:

```javascript
'use strict';

const sab = new SharedArrayBuffer(4);
const view = new Int32Array(sab);

// Atomic store — guaranteed to be visible to other threads
Atomics.store(view, 0, 42);

// Atomic load — guaranteed to see the latest value
const value = Atomics.load(view, 0);
console.log(value); // 42
```

Why not just use `view[0] = 42`? On some architectures, the CPU may reorder memory operations or cache values in registers. `Atomics.load` and `Atomics.store` include memory ordering guarantees — they ensure that writes from one thread are visible to other threads in a predictable order.

### Full Atomics Arithmetic API

| Method | Operation | Returns |
|--------|-----------|---------|
| `Atomics.add(ta, i, val)` | `ta[i] += val` | Old value |
| `Atomics.sub(ta, i, val)` | `ta[i] -= val` | Old value |
| `Atomics.and(ta, i, val)` | `ta[i] &= val` | Old value |
| `Atomics.or(ta, i, val)` | `ta[i] \|= val` | Old value |
| `Atomics.xor(ta, i, val)` | `ta[i] ^= val` | Old value |
| `Atomics.load(ta, i)` | Read `ta[i]` | Current value |
| `Atomics.store(ta, i, val)` | Write `val` to `ta[i]` | Value written |
| `Atomics.exchange(ta, i, val)` | Set `ta[i] = val` | Old value |
| `Atomics.compareExchange(ta, i, expected, replacement)` | If `ta[i] === expected`, set `ta[i] = replacement` | Old value |

All methods work on `Int8Array`, `Uint8Array`, `Int16Array`, `Uint16Array`, `Int32Array`, `Uint32Array`, `BigInt64Array`, and `BigUint64Array` backed by a `SharedArrayBuffer`. They do **not** work on `Float32Array` or `Float64Array`.

---

## Atomics.compareExchange: The Building Block

`Atomics.compareExchange` is the most powerful primitive. It atomically checks if an element equals an expected value and, if so, replaces it with a new value. This is the foundation for building locks, mutexes, and lock-free data structures:

```javascript
'use strict';

const sab = new SharedArrayBuffer(4);
const view = new Int32Array(sab);
view[0] = 10;

// Try to change 10 to 20
const old = Atomics.compareExchange(view, 0, 10, 20);
console.log(`Old: ${old}, Current: ${Atomics.load(view, 0)}`);
// Old: 10, Current: 20 — success: value was 10, now it is 20

// Try to change 10 to 30 — fails because current value is 20, not 10
const old2 = Atomics.compareExchange(view, 0, 10, 30);
console.log(`Old: ${old2}, Current: ${Atomics.load(view, 0)}`);
// Old: 20, Current: 20 — failed: value was 20 (not 10), unchanged
```

This is often called CAS (Compare-And-Swap) in computer science literature. It is the universal building block for lock-free algorithms.

### CAS Loop Pattern

When multiple threads compete to update a value, use a CAS loop:

```javascript
'use strict';

const { Worker, isMainThread, workerData } = require('node:worker_threads');

if (isMainThread) {
  const sab = new SharedArrayBuffer(4);
  const view = new Int32Array(sab);
  view[0] = 0;

  const workers = [];
  for (let i = 0; i < 4; i++) {
    workers.push(new Worker(__filename, { workerData: { sab } }));
  }

  let exited = 0;
  for (const w of workers) {
    w.on('exit', () => {
      exited++;
      if (exited === 4) {
        console.log(`Final: ${Atomics.load(view, 0)}`); // Always 4,000,000
      }
    });
  }
} else {
  const view = new Int32Array(workerData.sab);

  for (let i = 0; i < 1_000_000; i++) {
    // CAS loop: keep trying until we successfully update
    let current;
    do {
      current = Atomics.load(view, 0);
    } while (Atomics.compareExchange(view, 0, current, current + 1) !== current);
  }
}
```

In practice, use `Atomics.add` for simple increments. Use the CAS loop for complex updates where you need to compute the new value based on the old value.

---

## Atomics.wait and Atomics.notify

Sometimes a thread needs to wait for a specific condition before proceeding. Polling (busy-waiting) wastes CPU. `Atomics.wait` puts the thread to sleep until another thread wakes it with `Atomics.notify`.

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const sab = new SharedArrayBuffer(4);
  const signal = new Int32Array(sab);
  signal[0] = 0; // 0 = "not ready"

  const worker = new Worker(__filename, { workerData: { sab } });

  worker.on('message', (msg) => {
    console.log(`[main] Worker says: ${msg}`);
  });

  // Simulate some setup work
  setTimeout(() => {
    console.log('[main] Setting signal to 1 and notifying worker...');
    Atomics.store(signal, 0, 1); // Set "ready" flag
    Atomics.notify(signal, 0, 1); // Wake one waiting thread
  }, 2000);
} else {
  const signal = new Int32Array(workerData.sab);

  parentPort.postMessage('Waiting for signal...');

  // Block this thread until signal[0] is no longer 0
  const result = Atomics.wait(signal, 0, 0);
  // result is 'ok' (woken by notify), 'not-equal' (value already changed), or 'timed-out'

  parentPort.postMessage(`Woke up! Result: ${result}, value: ${Atomics.load(signal, 0)}`);
}
```

### Critical Rules

1. **`Atomics.wait` cannot be called on the main thread.** It blocks the calling thread, and blocking the main thread would freeze the event loop. If you try, Node.js throws: `TypeError: Atomics.wait cannot be called in this context`. It can only be called in worker threads.

2. **`Atomics.notify` can be called from any thread**, including the main thread.

3. **`Atomics.wait` only works with `Int32Array` and `BigInt64Array`** views on `SharedArrayBuffer`.

### Wait with Timeout

You can specify a maximum wait time in milliseconds:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const sab = new SharedArrayBuffer(4);
  const signal = new Int32Array(sab);
  signal[0] = 0;

  const worker = new Worker(__filename, { workerData: { sab } });

  worker.on('message', (msg) => {
    console.log(`[main] ${msg}`);
  });

  // Never notify — worker will time out
} else {
  const signal = new Int32Array(workerData.sab);

  parentPort.postMessage('Waiting with 3-second timeout...');

  const result = Atomics.wait(signal, 0, 0, 3000); // 3000 ms timeout

  parentPort.postMessage(`Result: ${result}`); // "timed-out"
}
```

### Atomics.waitAsync (Non-Blocking Wait)

Node.js 16+ provides `Atomics.waitAsync`, which returns a Promise instead of blocking the thread. This can be called on the main thread:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const sab = new SharedArrayBuffer(4);
  const signal = new Int32Array(sab);
  signal[0] = 0;

  const worker = new Worker(__filename, { workerData: { sab } });

  // Non-blocking wait on the main thread
  const { async: isAsync, value } = Atomics.waitAsync(signal, 0, 0);
  console.log(`Is async: ${isAsync}`);

  if (isAsync) {
    value.then((result) => {
      console.log(`[main] waitAsync resolved: ${result}`);
      console.log(`[main] Value: ${Atomics.load(signal, 0)}`);
    });
  }
} else {
  const signal = new Int32Array(workerData.sab);

  // Worker sets the signal after a delay
  setTimeout(() => {
    Atomics.store(signal, 0, 1);
    Atomics.notify(signal, 0);
  }, 1000);
}
```

---

## Practical Example: Producer-Consumer Queue

A common multi-threaded pattern: one thread produces data, another consumes it. `Atomics.wait` and `Atomics.notify` coordinate them:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  // Layout: [signal (1 Int32)] [data (256 Int32s)]
  const sab = new SharedArrayBuffer(4 + 256 * 4);
  const signal = new Int32Array(sab, 0, 1);
  const data = new Int32Array(sab, 4, 256);

  signal[0] = 0; // 0 = empty, 1 = data ready, 2 = done

  const consumer = new Worker(__filename, { workerData: { sab } });

  consumer.on('message', (msg) => {
    console.log(`[main] Consumer: ${msg}`);
  });

  // Produce 5 batches of data
  let batch = 0;
  const interval = setInterval(() => {
    if (batch >= 5) {
      // Signal completion
      Atomics.store(signal, 0, 2);
      Atomics.notify(signal, 0);
      clearInterval(interval);
      return;
    }

    // Fill data buffer
    for (let i = 0; i < 256; i++) {
      data[i] = batch * 1000 + i;
    }

    // Signal data is ready
    Atomics.store(signal, 0, 1);
    Atomics.notify(signal, 0);
    console.log(`[main] Produced batch ${batch}`);
    batch++;
  }, 500);
} else {
  const signal = new Int32Array(workerData.sab, 0, 1);
  const data = new Int32Array(workerData.sab, 4, 256);

  function consume() {
    while (true) {
      // Wait for data or done signal
      Atomics.wait(signal, 0, 0);

      const status = Atomics.load(signal, 0);

      if (status === 2) {
        parentPort.postMessage('Received done signal — exiting');
        break;
      }

      if (status === 1) {
        // Process data
        let sum = 0;
        for (let i = 0; i < 256; i++) {
          sum += data[i];
        }
        parentPort.postMessage(`Consumed batch, sum = ${sum}`);

        // Mark as empty and wait again
        Atomics.store(signal, 0, 0);
      }
    }
  }

  consume();
}
```

---

## Shared Metrics: A Real-World Use Case

One of the most practical uses of `SharedArrayBuffer` in Node.js is shared metrics. Workers update counters atomically, and the main thread reads them at any time without message passing overhead:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

// Metrics layout (Int32Array indices):
// [0] = total requests processed
// [1] = total errors
// [2] = active tasks
// [3] = max concurrent tasks seen

if (isMainThread) {
  const metricsSab = new SharedArrayBuffer(4 * 4); // 4 x Int32
  const metrics = new Int32Array(metricsSab);

  const NUM_WORKERS = 4;
  const workers = [];

  for (let i = 0; i < NUM_WORKERS; i++) {
    workers.push(
      new Worker(__filename, { workerData: { metricsSab, workerId: i } })
    );
  }

  // Read metrics every second — no message passing needed
  const report = setInterval(() => {
    console.log('--- Metrics ---');
    console.log(`  Requests:    ${Atomics.load(metrics, 0)}`);
    console.log(`  Errors:      ${Atomics.load(metrics, 1)}`);
    console.log(`  Active:      ${Atomics.load(metrics, 2)}`);
    console.log(`  Max conc.:   ${Atomics.load(metrics, 3)}`);
  }, 1000);

  let exited = 0;
  for (const w of workers) {
    w.on('exit', () => {
      exited++;
      if (exited === NUM_WORKERS) {
        clearInterval(report);
        console.log('\nFinal metrics:');
        console.log(`  Total requests: ${Atomics.load(metrics, 0)}`);
        console.log(`  Total errors:   ${Atomics.load(metrics, 1)}`);
      }
    });
  }
} else {
  const metrics = new Int32Array(workerData.metricsSab);

  // Simulate processing 100 tasks
  for (let i = 0; i < 100; i++) {
    Atomics.add(metrics, 2, 1); // Increment active

    // Update max concurrent (CAS loop)
    const active = Atomics.load(metrics, 2);
    let maxSeen;
    do {
      maxSeen = Atomics.load(metrics, 3);
      if (active <= maxSeen) break;
    } while (Atomics.compareExchange(metrics, 3, maxSeen, active) !== maxSeen);

    // Simulate work
    const spinEnd = Date.now() + Math.random() * 10;
    while (Date.now() < spinEnd) { /* spin */ }

    // Simulate occasional errors
    if (Math.random() < 0.05) {
      Atomics.add(metrics, 1, 1); // Increment errors
    }

    Atomics.add(metrics, 0, 1); // Increment total
    Atomics.sub(metrics, 2, 1); // Decrement active
  }
}
```

---

## Key Takeaways

- `SharedArrayBuffer` provides raw shared memory visible to all threads simultaneously — no copying, no serialization, no message passing overhead
- You access shared memory through typed array views (`Int32Array`, `Uint8Array`, etc.) — different views can overlay the same buffer for different data types
- Non-atomic reads and writes on shared memory cause data races — always use `Atomics.load`, `Atomics.store`, `Atomics.add`, and `Atomics.compareExchange` for safe access
- `Atomics.wait` blocks a worker thread until another thread calls `Atomics.notify` — this enables efficient producer-consumer patterns without busy-waiting
- Shared memory excels for counters, metrics, and flags where threads need to coordinate frequently — use message passing for complex objects that do not fit in typed arrays

## Next

In the next lesson, we tackle thread synchronization head-on — race conditions, deadlocks, building a mutex with `Atomics.compareExchange`, and the discipline required to write correct concurrent code.
