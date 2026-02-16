# Track 03 / Lesson 03 — Shared Memory Between Processes

> Message passing is safe but slow. Every IPC message is serialized, copied, deserialized, and garbage collected. When you need millions of updates per second between threads, the only answer is shared memory — a single block of bytes that multiple threads read and write simultaneously. This lesson teaches you to use it without tearing your data apart.

## Learning Objectives

- Create a `SharedArrayBuffer` and share it between `worker_threads` using `workerData` and `postMessage`
- Use `Atomics` operations (`wait`, `notify`, `add`, `compareExchange`) to coordinate access and prevent data races
- Build a lock-free ring buffer for high-throughput producer-consumer communication
- Understand why `SharedArrayBuffer` does not work with `child_process` by default and what the alternatives are
- Benchmark shared memory versus IPC message passing to quantify the performance difference

---

## Why Shared Memory

Every `worker.postMessage()` call in Node.js triggers structured cloning: the data is serialized into a binary format, copied across the thread boundary, and deserialized on the other side. For small messages this is fine. For large messages or high-frequency updates, the overhead dominates.

Shared memory eliminates the copy. Multiple threads see the same bytes in the same physical memory. There is no serialization, no copying, and no garbage collection pressure from temporary objects. The trade-off is that you must coordinate access yourself — the runtime will not protect you from data races.

```javascript
'use strict';

const { Worker, isMainThread, workerData } = require('node:worker_threads');

if (isMainThread) {
  // Allocate 1 KB of shared memory
  const shared = new SharedArrayBuffer(1024);
  const view = new Int32Array(shared);

  // Write a value from the main thread
  view[0] = 42;
  console.log(`Main thread wrote: ${view[0]}`);

  // Pass the shared buffer to a worker
  const worker = new Worker(__filename, { workerData: { shared } });

  worker.on('message', (msg) => {
    console.log(`Worker says: ${msg}`);
    // Read the value the worker modified
    console.log(`Main thread reads: ${view[0]}`);
    // Output: Main thread reads: 84
    // The worker doubled the value IN THE SAME MEMORY.
  });
} else {
  const view = new Int32Array(workerData.shared);
  console.log(`Worker thread reads: ${view[0]}`);
  // Modify the shared memory
  view[0] *= 2;
  const { parentPort } = require('node:worker_threads');
  parentPort.postMessage('I doubled view[0]');
}
```

The critical insight: `view[0]` in the main thread and `view[0]` in the worker point to the *same physical memory location*. No copy occurred. This is fundamentally different from `postMessage`, which creates a new copy in the receiver's heap.

---

## The Data Race Problem

Without coordination, two threads writing to the same memory location will corrupt data. This is not theoretical — it happens reliably under load.

```javascript
'use strict';

const { Worker, isMainThread, workerData } = require('node:worker_threads');

const ITERATIONS = 1_000_000;

if (isMainThread) {
  const shared = new SharedArrayBuffer(4); // One Int32
  const view = new Int32Array(shared);
  view[0] = 0;

  // Spawn two workers that both increment the same counter
  const worker1 = new Worker(__filename, { workerData: { shared } });
  const worker2 = new Worker(__filename, { workerData: { shared } });

  let finished = 0;
  function onDone() {
    finished++;
    if (finished === 2) {
      // Expected: 2,000,000 (if no race condition)
      // Actual: something less — often significantly less
      console.log(`Final counter: ${view[0]}`);
      console.log(`Expected:      ${ITERATIONS * 2}`);
      console.log(`Lost updates:  ${ITERATIONS * 2 - view[0]}`);
    }
  }

  worker1.on('message', onDone);
  worker2.on('message', onDone);
} else {
  const view = new Int32Array(workerData.shared);
  const { parentPort } = require('node:worker_threads');

  // Non-atomic increment: read, add 1, write
  // This is a classic read-modify-write race condition
  for (let i = 0; i < ITERATIONS; i++) {
    view[0] = view[0] + 1; // NOT atomic — data race!
  }

  parentPort.postMessage('done');
}
```

Run this multiple times. The final counter will be less than 2,000,000 because both threads sometimes read the same value, increment it, and write back — losing one update. This is the fundamental problem that `Atomics` solves.

---

## Atomics: Coordinating Shared Memory Access

The `Atomics` object provides atomic operations on `SharedArrayBuffer` views. "Atomic" means the operation is indivisible — no other thread can observe it halfway through.

### Atomic Add

```javascript
'use strict';

const { Worker, isMainThread, workerData } = require('node:worker_threads');

const ITERATIONS = 1_000_000;

if (isMainThread) {
  const shared = new SharedArrayBuffer(4);
  const view = new Int32Array(shared);
  view[0] = 0;

  const worker1 = new Worker(__filename, { workerData: { shared } });
  const worker2 = new Worker(__filename, { workerData: { shared } });

  let finished = 0;
  function onDone() {
    finished++;
    if (finished === 2) {
      console.log(`Final counter: ${view[0]}`);
      console.log(`Expected:      ${ITERATIONS * 2}`);
      // Now these will ALWAYS be equal
      console.log(`Match: ${view[0] === ITERATIONS * 2}`);
    }
  }

  worker1.on('message', onDone);
  worker2.on('message', onDone);
} else {
  const view = new Int32Array(workerData.shared);
  const { parentPort } = require('node:worker_threads');

  // Atomic increment: guaranteed no lost updates
  for (let i = 0; i < ITERATIONS; i++) {
    Atomics.add(view, 0, 1); // Atomically: view[0] += 1
  }

  parentPort.postMessage('done');
}
```

### Core Atomics Operations

```javascript
'use strict';

// Demonstration of all major Atomics operations
const shared = new SharedArrayBuffer(32);
const view = new Int32Array(shared);

// Atomics.store — write a value atomically
Atomics.store(view, 0, 100);
console.log(`store(100): ${view[0]}`); // 100

// Atomics.load — read a value atomically
const val = Atomics.load(view, 0);
console.log(`load: ${val}`); // 100

// Atomics.add — add and return the OLD value
const oldVal = Atomics.add(view, 0, 50);
console.log(`add(50) returned old: ${oldVal}, new: ${view[0]}`); // old: 100, new: 150

// Atomics.sub — subtract and return the OLD value
const oldSub = Atomics.sub(view, 0, 25);
console.log(`sub(25) returned old: ${oldSub}, new: ${view[0]}`); // old: 150, new: 125

// Atomics.exchange — set new value, return OLD value
const oldExch = Atomics.exchange(view, 0, 999);
console.log(`exchange(999) returned old: ${oldExch}, new: ${view[0]}`); // old: 125, new: 999

// Atomics.compareExchange — CAS (compare-and-swap)
// Only sets the new value if the current value matches the expected value
Atomics.store(view, 0, 10);
const casResult = Atomics.compareExchange(view, 0, 10, 20); // expect 10, set to 20
console.log(`CAS(10->20): old=${casResult}, new=${view[0]}`); // old=10, new=20

const casFail = Atomics.compareExchange(view, 0, 10, 30); // expect 10, but it's 20
console.log(`CAS(10->30): old=${casFail}, new=${view[0]}`); // old=20, new=20 (unchanged)

// Bitwise operations
Atomics.store(view, 1, 0b1100);
Atomics.and(view, 1, 0b1010);
console.log(`AND: ${view[1].toString(2)}`); // 1000

Atomics.store(view, 2, 0b1100);
Atomics.or(view, 2, 0b0011);
console.log(`OR: ${view[2].toString(2)}`);  // 1111

Atomics.store(view, 3, 0b1100);
Atomics.xor(view, 3, 0b1010);
console.log(`XOR: ${view[3].toString(2)}`); // 0110
```

---

## Atomics.wait and Atomics.notify: Thread Signaling

`Atomics.wait` puts a thread to sleep until another thread calls `Atomics.notify`. This is the foundation for building mutexes, semaphores, and condition variables in JavaScript.

```javascript
'use strict';

const { Worker, isMainThread, workerData } = require('node:worker_threads');

if (isMainThread) {
  const shared = new SharedArrayBuffer(8);
  const signal = new Int32Array(shared);

  // signal[0] = 0 means "no data ready"
  // signal[1] = the data itself
  Atomics.store(signal, 0, 0);

  const worker = new Worker(__filename, { workerData: { shared } });

  // Simulate doing some work, then signal the worker
  setTimeout(() => {
    console.log('[Main] Preparing data...');
    Atomics.store(signal, 1, 12345); // Write the data
    Atomics.store(signal, 0, 1);     // Set the "ready" flag
    Atomics.notify(signal, 0, 1);    // Wake one waiting thread
    console.log('[Main] Data sent, worker notified');
  }, 1000);

  worker.on('message', (msg) => {
    console.log(`[Main] Worker received: ${msg}`);
  });
} else {
  const signal = new Int32Array(workerData.shared);
  const { parentPort } = require('node:worker_threads');

  console.log('[Worker] Waiting for data...');

  // Block until signal[0] is no longer 0
  // This puts the thread to sleep — no CPU usage while waiting
  const result = Atomics.wait(signal, 0, 0);
  // result is 'ok' (notified), 'not-equal' (value changed), or 'timed-out'
  console.log(`[Worker] Wait result: ${result}`);

  const data = Atomics.load(signal, 1);
  console.log(`[Worker] Received data: ${data}`);
  parentPort.postMessage(data);
}
```

Important: `Atomics.wait` blocks the thread. You must NEVER call it on the main thread — it will freeze the event loop. It is only safe inside `worker_threads`.

---

## Building a Spinlock with Atomics

A spinlock is the simplest mutual exclusion primitive. It uses `Atomics.compareExchange` to acquire a lock and `Atomics.store` to release it.

```javascript
'use strict';

const { Worker, isMainThread, workerData, threadId } = require('node:worker_threads');

const WORKER_COUNT = 4;
const INCREMENTS_PER_WORKER = 100_000;

// Layout: [lock, counter, pad, pad, pad, pad, pad, pad]
// lock at index 0: 0 = unlocked, 1 = locked
// counter at index 1: the shared value we protect

if (isMainThread) {
  const shared = new SharedArrayBuffer(32);
  const view = new Int32Array(shared);
  Atomics.store(view, 0, 0); // lock = unlocked
  Atomics.store(view, 1, 0); // counter = 0

  const workers = [];
  for (let i = 0; i < WORKER_COUNT; i++) {
    workers.push(new Worker(__filename, { workerData: { shared } }));
  }

  let finished = 0;
  for (const w of workers) {
    w.on('message', () => {
      finished++;
      if (finished === WORKER_COUNT) {
        const counter = Atomics.load(view, 1);
        const expected = WORKER_COUNT * INCREMENTS_PER_WORKER;
        console.log(`Final counter: ${counter}`);
        console.log(`Expected:      ${expected}`);
        console.log(`Correct:       ${counter === expected}`);
      }
    });
  }
} else {
  const view = new Int32Array(workerData.shared);
  const { parentPort } = require('node:worker_threads');

  function spinLock(view, lockIndex) {
    // Spin until we successfully set lock from 0 to 1
    while (Atomics.compareExchange(view, lockIndex, 0, 1) !== 0) {
      // Busy-wait — burns CPU but has minimal latency
    }
  }

  function spinUnlock(view, lockIndex) {
    Atomics.store(view, lockIndex, 0);
  }

  for (let i = 0; i < INCREMENTS_PER_WORKER; i++) {
    spinLock(view, 0);
    // Critical section — only one thread at a time
    const current = Atomics.load(view, 1);
    Atomics.store(view, 1, current + 1);
    spinUnlock(view, 0);
  }

  parentPort.postMessage('done');
}
```

Spinlocks are simple but wasteful — they burn CPU while waiting. For longer critical sections, use `Atomics.wait`/`Atomics.notify` instead.

---

## Lock-Free Ring Buffer: Producer-Consumer Pattern

A ring buffer (circular buffer) allows one thread to produce data and another to consume it without any locks. The key is that only the producer writes the `writeIndex` and only the consumer writes the `readIndex`.

```javascript
'use strict';

const { Worker, isMainThread, workerData } = require('node:worker_threads');

// Ring buffer layout in SharedArrayBuffer:
// [0]: writeIndex (only producer writes)
// [1]: readIndex  (only consumer writes)
// [2..capacity+1]: data slots

const CAPACITY = 1024;          // Must be a power of 2 for fast modulo
const HEADER_SIZE = 2;          // writeIndex + readIndex
const TOTAL_INTS = HEADER_SIZE + CAPACITY;
const MASK = CAPACITY - 1;      // Fast modulo: index & MASK == index % CAPACITY

if (isMainThread) {
  const shared = new SharedArrayBuffer(TOTAL_INTS * 4);
  const view = new Int32Array(shared);

  // Initialize
  Atomics.store(view, 0, 0); // writeIndex
  Atomics.store(view, 1, 0); // readIndex

  // Start consumer worker
  const consumer = new Worker(__filename, {
    workerData: { shared, role: 'consumer' },
  });

  consumer.on('message', (msg) => {
    console.log(`[Main/Consumer report] ${msg}`);
  });

  // Producer runs on main thread
  const ITEMS_TO_PRODUCE = 100_000;
  let produced = 0;

  function produce() {
    while (produced < ITEMS_TO_PRODUCE) {
      const writeIdx = Atomics.load(view, 0);
      const readIdx = Atomics.load(view, 1);

      // Check if buffer is full
      if (((writeIdx + 1) & MASK) === (readIdx & MASK)) {
        // Buffer full — yield and retry
        setImmediate(produce);
        return;
      }

      // Write the data
      const slot = HEADER_SIZE + (writeIdx & MASK);
      view[slot] = produced + 1; // Data: 1, 2, 3, ...

      // Advance write index (atomic so consumer sees it)
      Atomics.store(view, 0, writeIdx + 1);
      produced++;
    }

    console.log(`[Producer] Done. Produced ${produced} items.`);
  }

  produce();
} else {
  const view = new Int32Array(workerData.shared);
  const { parentPort } = require('node:worker_threads');

  let consumed = 0;
  let sum = 0;

  function consume() {
    // eslint-disable-next-line no-constant-condition
    while (true) {
      const writeIdx = Atomics.load(view, 0);
      const readIdx = Atomics.load(view, 1);

      // Check if buffer is empty
      if (readIdx === writeIdx) {
        // Buffer empty — wait briefly then retry
        // Use Atomics.wait with a short timeout instead of busy-waiting
        Atomics.wait(view, 0, writeIdx, 1); // Wait up to 1ms
        continue;
      }

      // Read the data
      const slot = HEADER_SIZE + (readIdx & MASK);
      const value = view[slot];
      sum += value;
      consumed++;

      // Advance read index
      Atomics.store(view, 1, readIdx + 1);

      // Report progress periodically
      if (consumed % 25_000 === 0) {
        parentPort.postMessage(`Consumed ${consumed} items, running sum: ${sum}`);
      }

      // Stop condition (we know the producer sends 100,000 items)
      if (consumed >= 100_000) {
        parentPort.postMessage(`Final: consumed ${consumed}, sum ${sum}`);
        break;
      }
    }
  }

  consume();
}
```

---

## SharedArrayBuffer and child_process: Why It Does Not Work

`SharedArrayBuffer` works with `worker_threads` because workers share the same process memory space. `child_process.fork()` creates a separate process with its own memory space — you cannot share a `SharedArrayBuffer` directly.

```javascript
'use strict';

const { fork } = require('node:child_process');

// This does NOT share memory — the buffer is COPIED
const shared = new SharedArrayBuffer(4);
const view = new Int32Array(shared);
view[0] = 42;

if (process.argv[2] === 'child') {
  // In a forked child, we cannot receive SharedArrayBuffer via IPC
  // The IPC channel uses structured clone, which does not support
  // cross-process SharedArrayBuffer transfer
  process.on('message', (msg) => {
    console.log(`[Child] Received message type: ${typeof msg}`);
    // msg will be a regular object, not a SharedArrayBuffer
  });
} else {
  const child = fork(__filename, ['child']);

  // This sends a copy, not a shared reference
  child.send({ data: 'hello' });

  // To share memory between processes, you need:
  // 1. OS-level shared memory (mmap) via a native addon
  // 2. Memory-mapped files (partial support via fs)
  // 3. A shared memory segment via a native module
  console.log('[Parent] SharedArrayBuffer cannot cross process boundaries');
  console.log('[Parent] Use worker_threads for shared memory');

  child.on('exit', () => process.exit(0));
  setTimeout(() => child.kill(), 500);
}
```

### Simulating Shared State with Memory-Mapped Files

While Node.js does not have `mmap`, you can approximate shared-file state with `fs.open` and positioned reads/writes:

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { fork } = require('node:child_process');

const SHARED_FILE = path.join('/tmp', 'shared-state.bin');

if (process.argv[2] === 'child') {
  // Child process: read the shared file periodically
  const fd = fs.openSync(SHARED_FILE, 'r');
  const buf = Buffer.alloc(4);

  const interval = setInterval(() => {
    fs.readSync(fd, buf, 0, 4, 0);
    const value = buf.readInt32LE(0);
    console.log(`[Child] Read value: ${value}`);
    if (value >= 10) {
      clearInterval(interval);
      fs.closeSync(fd);
      console.log('[Child] Done');
    }
  }, 100);
} else {
  // Parent: create the shared file and write to it
  const buf = Buffer.alloc(4);
  buf.writeInt32LE(0, 0);
  fs.writeFileSync(SHARED_FILE, buf);

  const child = fork(__filename, ['child']);
  const fd = fs.openSync(SHARED_FILE, 'r+');

  let counter = 0;
  const interval = setInterval(() => {
    counter++;
    const writeBuf = Buffer.alloc(4);
    writeBuf.writeInt32LE(counter, 0);
    fs.writeSync(fd, writeBuf, 0, 4, 0);
    console.log(`[Parent] Wrote value: ${counter}`);

    if (counter >= 10) {
      clearInterval(interval);
      fs.closeSync(fd);
    }
  }, 200);

  child.on('exit', () => {
    fs.unlinkSync(SHARED_FILE);
    console.log('[Parent] Cleaned up');
  });
}
```

This is not true shared memory — each read/write goes through the kernel's VFS layer. It is orders of magnitude slower than `SharedArrayBuffer` but works across process boundaries without native addons.

---

## Performance Benchmark: Shared Memory vs Message Passing

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');
const { performance } = require('node:perf_hooks');

const ITERATIONS = 1_000_000;

if (isMainThread) {
  async function benchmarkSharedMemory() {
    const shared = new SharedArrayBuffer(8);
    const view = new Int32Array(shared);
    Atomics.store(view, 0, 0);

    const worker = new Worker(__filename, {
      workerData: { mode: 'shared', shared },
    });

    return new Promise((resolve) => {
      worker.on('message', () => {
        const final = Atomics.load(view, 0);
        resolve(final);
      });
    });
  }

  async function benchmarkMessagePassing() {
    const worker = new Worker(__filename, {
      workerData: { mode: 'message' },
    });

    return new Promise((resolve) => {
      let count = 0;
      worker.on('message', (msg) => {
        if (msg === 'done') {
          resolve(count);
          return;
        }
        count += msg;
      });
    });
  }

  async function main() {
    console.log(`Benchmarking ${ITERATIONS.toLocaleString()} operations...\n`);

    // Shared memory benchmark
    const sharedStart = performance.now();
    const sharedResult = await benchmarkSharedMemory();
    const sharedTime = performance.now() - sharedStart;

    console.log(`Shared Memory:`);
    console.log(`  Time:   ${sharedTime.toFixed(2)} ms`);
    console.log(`  Result: ${sharedResult}`);
    console.log(`  Ops/s:  ${(ITERATIONS / sharedTime * 1000).toFixed(0)}\n`);

    // Message passing benchmark
    const msgStart = performance.now();
    const msgResult = await benchmarkMessagePassing();
    const msgTime = performance.now() - msgStart;

    console.log(`Message Passing:`);
    console.log(`  Time:   ${msgTime.toFixed(2)} ms`);
    console.log(`  Result: ${msgResult}`);
    console.log(`  Ops/s:  ${(ITERATIONS / msgTime * 1000).toFixed(0)}\n`);

    const speedup = (msgTime / sharedTime).toFixed(1);
    console.log(`Shared memory is ${speedup}x faster than message passing`);
  }

  main().catch(console.error);
} else {
  if (workerData.mode === 'shared') {
    const view = new Int32Array(workerData.shared);
    for (let i = 0; i < ITERATIONS; i++) {
      Atomics.add(view, 0, 1);
    }
    parentPort.postMessage('done');
  } else {
    // Message passing: send individual increments
    // (in practice you would batch, but this shows the raw overhead)
    for (let i = 0; i < ITERATIONS; i++) {
      parentPort.postMessage(1);
    }
    parentPort.postMessage('done');
  }
}
```

Typical results: shared memory with `Atomics.add` is 10-100x faster than individual `postMessage` calls. The gap narrows if you batch messages, but shared memory always wins for high-frequency updates.

---

## Key Takeaways

- `SharedArrayBuffer` provides true shared memory between `worker_threads` — no serialization, no copying, no GC pressure — but it requires manual coordination to avoid data races
- `Atomics` operations (`add`, `compareExchange`, `store`, `load`) are the building blocks for thread-safe shared memory access; a single non-atomic read-modify-write on shared memory will lose updates under contention
- `Atomics.wait` and `Atomics.notify` provide efficient thread signaling (sleep/wake) — but `Atomics.wait` must NEVER be called on the main thread because it blocks the event loop
- `SharedArrayBuffer` does not work across `child_process` boundaries because forked processes have separate memory spaces — use `worker_threads` for shared memory, or fall back to file-based coordination for cross-process state
- For high-throughput producer-consumer patterns, a lock-free ring buffer using `SharedArrayBuffer` delivers orders-of-magnitude better performance than message passing with `postMessage`

## Next

In the next lesson, we explore file descriptor passing — the ability to transfer open file handles between processes, enabling patterns like zero-downtime restarts and socket handoff between cluster workers.
