# Module 09 / Lesson 05 — Thread Synchronization

> Shared memory is fast. Shared memory without synchronization is a minefield. The moment two threads touch the same data, you need rules — who reads first, who writes first, what happens when both try at once. This lesson confronts the three fundamental problems of concurrent programming: race conditions, deadlocks, and ordering violations. Then it shows you how to solve each one using the `Atomics` primitives from the previous lesson.

## Learning Objectives

- Identify and reproduce race conditions in shared memory programs
- Explain what deadlocks are and demonstrate how they occur with two competing locks
- Implement a mutex (mutual exclusion lock) using `Atomics.compareExchange`
- Define critical sections and apply mutual exclusion to protect them
- Understand memory ordering guarantees provided by `Atomics` operations

---

## Race Conditions: The Core Problem

A **race condition** occurs when the correctness of a program depends on the relative timing of operations in different threads. The result is nondeterministic — it changes from run to run.

We saw the classic increment race in Lesson 04. Here is a more subtle example — a check-then-act race:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

// Shared state: [0] = balance
if (isMainThread) {
  const sab = new SharedArrayBuffer(4);
  const account = new Int32Array(sab);
  account[0] = 100; // Start with $100

  const w1 = new Worker(__filename, { workerData: { sab, withdraw: 80 } });
  const w2 = new Worker(__filename, { workerData: { sab, withdraw: 80 } });

  let exited = 0;
  function done() {
    exited++;
    if (exited === 2) {
      console.log(`Final balance: $${account[0]}`);
      // Could be $20 (one succeeded), -$60 (both succeeded — BUG), or $100 (both failed)
      // On most runs, both succeed → negative balance
    }
  }

  w1.on('message', (msg) => console.log(`Worker 1: ${msg}`));
  w2.on('message', (msg) => console.log(`Worker 2: ${msg}`));
  w1.on('exit', done);
  w2.on('exit', done);
} else {
  const account = new Int32Array(workerData.sab);
  const amount = workerData.withdraw;

  // CHECK: Is there enough money?
  const balance = account[0]; // Both threads read 100

  // Simulate a brief delay (context switch opportunity)
  const end = Date.now() + 1;
  while (Date.now() < end) { /* spin */ }

  // ACT: Withdraw if sufficient
  if (balance >= amount) {
    account[0] = balance - amount; // Both threads write 100 - 80 = 20
    parentPort.postMessage(`Withdrew $${amount}, new balance: $${account[0]}`);
  } else {
    parentPort.postMessage(`Insufficient funds: $${balance} < $${amount}`);
  }
}
```

Both threads read the balance as $100, both decide there is enough money, both subtract $80. The final balance should never go below $0, but it does. The bug is in the gap between the check (`balance >= amount`) and the act (`account[0] = balance - amount`). Another thread can interleave between them.

---

## Fixing Race Conditions with Atomics

### Approach 1: Atomic Compare-Exchange

For simple state transitions, `Atomics.compareExchange` can replace the check-then-act pattern:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const sab = new SharedArrayBuffer(4);
  const account = new Int32Array(sab);
  account[0] = 100;

  const w1 = new Worker(__filename, { workerData: { sab, withdraw: 80 } });
  const w2 = new Worker(__filename, { workerData: { sab, withdraw: 80 } });

  let exited = 0;
  function done() {
    exited++;
    if (exited === 2) {
      console.log(`Final balance: $${Atomics.load(account, 0)}`);
      // Always $20 — exactly one withdrawal succeeds
    }
  }

  w1.on('message', (msg) => console.log(`Worker 1: ${msg}`));
  w2.on('message', (msg) => console.log(`Worker 2: ${msg}`));
  w1.on('exit', done);
  w2.on('exit', done);
} else {
  const account = new Int32Array(workerData.sab);
  const amount = workerData.withdraw;

  // CAS loop: atomically check and update
  let success = false;
  while (!success) {
    const current = Atomics.load(account, 0);

    if (current < amount) {
      parentPort.postMessage(`Insufficient funds: $${current} < $${amount}`);
      break;
    }

    // Atomically: if account[0] is still `current`, set it to `current - amount`
    const actual = Atomics.compareExchange(account, 0, current, current - amount);

    if (actual === current) {
      // Success — we were the one who updated it
      parentPort.postMessage(`Withdrew $${amount}, new balance: $${current - amount}`);
      success = true;
    }
    // If actual !== current, another thread changed it — loop and retry
  }
}
```

### Approach 2: Mutex (for Complex Critical Sections)

When the critical section involves multiple operations that cannot be reduced to a single CAS, you need a mutex. We will build one shortly.

---

## Deadlocks: When Threads Wait Forever

A **deadlock** occurs when two or more threads are each waiting for the other to release a resource. Neither can proceed, and the program freezes.

The classic scenario requires two locks and two threads that acquire them in opposite order:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

// Two locks: lock A at index 0, lock B at index 1
// 0 = unlocked, 1 = locked

if (isMainThread) {
  const sab = new SharedArrayBuffer(8);
  const locks = new Int32Array(sab);
  locks[0] = 0; // Lock A
  locks[1] = 0; // Lock B

  const w1 = new Worker(__filename, {
    workerData: { sab, first: 0, second: 1, name: 'Worker-1' },
  });
  const w2 = new Worker(__filename, {
    workerData: { sab, first: 1, second: 0, name: 'Worker-2' },
  });

  // Detect deadlock with a timeout
  setTimeout(() => {
    console.log('DEADLOCK DETECTED — both workers stuck for 5 seconds');
    console.log(`Lock A: ${Atomics.load(locks, 0)}, Lock B: ${Atomics.load(locks, 1)}`);
    w1.terminate();
    w2.terminate();
  }, 5000);

  w1.on('message', (msg) => console.log(msg));
  w2.on('message', (msg) => console.log(msg));
} else {
  const locks = new Int32Array(workerData.sab);
  const { first, second, name } = workerData;

  function spinLock(index) {
    while (Atomics.compareExchange(locks, index, 0, 1) !== 0) {
      // Spin until we acquire the lock
    }
  }

  function unlock(index) {
    Atomics.store(locks, index, 0);
  }

  parentPort.postMessage(`${name}: Acquiring lock ${first}...`);
  spinLock(first);
  parentPort.postMessage(`${name}: Got lock ${first}, acquiring lock ${second}...`);

  // Simulate work between acquiring the two locks
  const end = Date.now() + 10;
  while (Date.now() < end) { /* spin */ }

  spinLock(second); // DEADLOCK: the other worker holds this lock and wants ours
  parentPort.postMessage(`${name}: Got both locks!`);

  unlock(second);
  unlock(first);
}
```

Worker-1 grabs Lock A, then tries to grab Lock B. Worker-2 grabs Lock B, then tries to grab Lock A. Neither can proceed. This is a deadlock.

### Preventing Deadlocks

The classic solution: **always acquire locks in the same order**. If every thread acquires Lock A before Lock B, deadlocks cannot occur:

```javascript
// Both workers acquire locks in index order: 0 first, then 1
const orderedFirst = Math.min(first, second);
const orderedSecond = Math.max(first, second);

spinLock(orderedFirst);
spinLock(orderedSecond);
// ... critical section ...
unlock(orderedSecond);
unlock(orderedFirst);
```

Other deadlock prevention strategies:

1. **Lock ordering** — Always acquire locks in a global, consistent order
2. **Try-lock with timeout** — If you cannot acquire a lock within N milliseconds, release all held locks and retry
3. **Single lock** — Use one lock for all shared resources (simpler but less concurrent)
4. **Lock-free algorithms** — Avoid locks entirely by using CAS loops

---

## Building a Mutex with Atomics.compareExchange

A **mutex** (mutual exclusion) ensures that only one thread can execute a critical section at a time. Here is a complete implementation:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');
const { Atomics: A } = globalThis;

// Mutex protocol:
// index 0 in Int32Array: 0 = unlocked, 1 = locked

class AtomicMutex {
  #lockArray;
  #index;

  constructor(sharedInt32Array, index) {
    this.#lockArray = sharedInt32Array;
    this.#index = index;
  }

  lock() {
    // Spin until we atomically change 0 → 1
    while (Atomics.compareExchange(this.#lockArray, this.#index, 0, 1) !== 0) {
      // Wait for the lock to be released
      // Atomics.wait blocks efficiently instead of burning CPU
      Atomics.wait(this.#lockArray, this.#index, 1);
    }
  }

  unlock() {
    // Set back to 0
    Atomics.store(this.#lockArray, this.#index, 0);
    // Wake one waiting thread
    Atomics.notify(this.#lockArray, this.#index, 1);
  }
}

if (isMainThread) {
  // Layout: [lock (1 Int32)] [balance (1 Int32)] [transactionCount (1 Int32)]
  const sab = new SharedArrayBuffer(12);
  const shared = new Int32Array(sab);
  shared[0] = 0;    // Lock: unlocked
  shared[1] = 1000; // Balance: $1000
  shared[2] = 0;    // Transaction count

  const NUM_WORKERS = 4;
  const TRANSACTIONS_PER_WORKER = 1000;

  const workers = [];
  for (let i = 0; i < NUM_WORKERS; i++) {
    workers.push(new Worker(__filename, {
      workerData: { sab, transactions: TRANSACTIONS_PER_WORKER, workerId: i },
    }));
  }

  let exited = 0;
  for (const w of workers) {
    w.on('exit', () => {
      exited++;
      if (exited === NUM_WORKERS) {
        console.log(`Final balance:      $${shared[1]}`);
        console.log(`Transactions:       ${shared[2]}`);
        console.log(`Expected balance:   $1000 (all deposits and withdrawals should net zero)`);
        console.log(`Expected txns:      ${NUM_WORKERS * TRANSACTIONS_PER_WORKER}`);
      }
    });
  }
} else {
  const shared = new Int32Array(workerData.sab);
  const mutex = new AtomicMutex(shared, 0);

  for (let i = 0; i < workerData.transactions; i++) {
    mutex.lock();
    try {
      // --- Critical section: multiple operations that must be atomic ---
      const balance = shared[1];
      const amount = Math.floor(Math.random() * 20) - 10; // -10 to +10

      // Only allow withdrawal if sufficient funds
      if (balance + amount >= 0) {
        shared[1] = balance + amount;
      } else {
        shared[1] = balance; // No change
      }
      shared[2]++; // Count transaction
      // --- End critical section ---
    } finally {
      mutex.unlock();
    }
  }
}
```

### Spin Lock vs Wait Lock

The mutex above uses `Atomics.wait` to sleep when the lock is held. A pure spin lock would loop without sleeping:

```javascript
// Pure spin lock — burns CPU while waiting
lock() {
  while (Atomics.compareExchange(this.#lockArray, this.#index, 0, 1) !== 0) {
    // Busy-wait: CPU runs at 100% doing nothing useful
  }
}

// Wait lock — sleeps until notified
lock() {
  while (Atomics.compareExchange(this.#lockArray, this.#index, 0, 1) !== 0) {
    Atomics.wait(this.#lockArray, this.#index, 1);
    // Thread is parked — no CPU usage until notify
  }
}
```

Use spin locks only when you expect the critical section to be extremely short (nanoseconds). For anything longer, use `Atomics.wait` to avoid wasting CPU.

---

## Critical Sections

A **critical section** is a region of code that accesses shared resources and must be executed by only one thread at a time. The mutex ensures mutual exclusion:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const sab = new SharedArrayBuffer(4 + 4 * 100); // lock + 100 Int32 slots
  const shared = new Int32Array(sab);
  shared[0] = 0; // Lock

  // Initialize array with 0..99
  for (let i = 0; i < 100; i++) {
    shared[i + 1] = i;
  }

  const workers = [];
  for (let i = 0; i < 4; i++) {
    workers.push(new Worker(__filename, { workerData: { sab } }));
  }

  let exited = 0;
  for (const w of workers) {
    w.on('exit', () => {
      exited++;
      if (exited === 4) {
        // Verify consistency: array should still sum to 0+1+2+...+99 = 4950
        let sum = 0;
        for (let i = 1; i <= 100; i++) sum += shared[i];
        console.log(`Sum: ${sum} (expected 4950)`);
      }
    });
  }
} else {
  const shared = new Int32Array(workerData.sab);

  function lock() {
    while (Atomics.compareExchange(shared, 0, 0, 1) !== 0) {
      Atomics.wait(shared, 0, 1);
    }
  }

  function unlock() {
    Atomics.store(shared, 0, 0);
    Atomics.notify(shared, 0, 1);
  }

  // Perform 10,000 swap operations
  for (let iter = 0; iter < 10_000; iter++) {
    const i = 1 + Math.floor(Math.random() * 100);
    const j = 1 + Math.floor(Math.random() * 100);

    // Critical section: swap two elements
    // Without the lock, reads and writes could interleave, corrupting data
    lock();
    const temp = shared[i];
    shared[i] = shared[j];
    shared[j] = temp;
    unlock();
  }
}
```

Without the mutex, interleaved swaps can lose values — the sum would drift from 4950. With the mutex, every swap is atomic as a unit, and the invariant holds.

---

## Memory Ordering

Modern CPUs reorder memory operations for performance. In single-threaded code, you never notice because the CPU preserves the illusion of sequential execution. In multi-threaded code, reordering can make one thread's writes appear in a different order to another thread.

`Atomics` operations provide **sequential consistency**: all threads agree on a single global order of all atomic operations. This is the strongest memory ordering guarantee:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const sab = new SharedArrayBuffer(8);
  const flags = new Int32Array(sab);
  flags[0] = 0; // data_ready flag
  flags[1] = 0; // data value

  const writer = new Worker(__filename, { workerData: { sab, role: 'writer' } });
  const reader = new Worker(__filename, { workerData: { sab, role: 'reader' } });

  writer.on('message', (msg) => console.log(`[writer] ${msg}`));
  reader.on('message', (msg) => console.log(`[reader] ${msg}`));
} else {
  const flags = new Int32Array(workerData.sab);

  if (workerData.role === 'writer') {
    // Step 1: Write the data
    Atomics.store(flags, 1, 42);

    // Step 2: Signal that data is ready
    Atomics.store(flags, 0, 1);
    Atomics.notify(flags, 0);

    parentPort.postMessage('Data written and signal set');

    // The sequential consistency of Atomics guarantees:
    // If the reader sees flags[0] === 1, it will also see flags[1] === 42
    // Without Atomics, the CPU could reorder the two stores
  } else {
    // Wait for the signal
    Atomics.wait(flags, 0, 0);

    // Guaranteed to see 42 because of memory ordering
    const value = Atomics.load(flags, 1);
    parentPort.postMessage(`Data: ${value}`);
  }
}
```

### Rules of Thumb

1. **Always use `Atomics.load` and `Atomics.store`** when reading/writing shared memory that another thread might access. Never use raw `view[i]` access.
2. **Use `Atomics.add`/`Atomics.sub`** for counters and accumulators.
3. **Use `Atomics.compareExchange`** for complex state transitions and lock implementations.
4. **Use `Atomics.wait`/`Atomics.notify`** for thread coordination (blocking waits).
5. **Keep critical sections short.** The longer you hold a lock, the more other threads wait.

---

## Common Synchronization Patterns

### Read-Write Separation

Many workloads have frequent reads and rare writes. A simple approach uses a generation counter:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  // [0] = generation, [1..10] = data
  const sab = new SharedArrayBuffer(44);
  const shared = new Int32Array(sab);
  shared[0] = 0;

  const reader = new Worker(__filename, { workerData: { sab, role: 'reader' } });
  const writer = new Worker(__filename, { workerData: { sab, role: 'writer' } });

  reader.on('message', (msg) => console.log(`[reader] ${msg}`));
  writer.on('message', (msg) => console.log(`[writer] ${msg}`));

  setTimeout(() => {
    reader.terminate();
    writer.terminate();
  }, 3000);
} else {
  const shared = new Int32Array(workerData.sab);

  if (workerData.role === 'writer') {
    let gen = 0;
    setInterval(() => {
      // Write new data
      for (let i = 1; i <= 10; i++) {
        Atomics.store(shared, i, gen * 100 + i);
      }
      // Bump generation — readers know data has changed
      gen++;
      Atomics.store(shared, 0, gen);
      Atomics.notify(shared, 0);
      parentPort.postMessage(`Wrote generation ${gen}`);
    }, 500);
  } else {
    let lastGen = 0;
    const check = () => {
      const gen = Atomics.load(shared, 0);
      if (gen !== lastGen) {
        const values = [];
        for (let i = 1; i <= 10; i++) {
          values.push(Atomics.load(shared, i));
        }
        parentPort.postMessage(`Gen ${gen}: [${values.join(', ')}]`);
        lastGen = gen;
      }
      setTimeout(check, 100);
    };
    check();
  }
}
```

### Barrier: Wait for All Threads

A barrier ensures all threads reach a synchronization point before any proceed past it:

```javascript
'use strict';

const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');

if (isMainThread) {
  const NUM_WORKERS = 4;
  // [0] = count of arrived threads
  const sab = new SharedArrayBuffer(4);
  const barrier = new Int32Array(sab);
  barrier[0] = 0;

  for (let i = 0; i < NUM_WORKERS; i++) {
    const w = new Worker(__filename, {
      workerData: { sab, total: NUM_WORKERS, workerId: i },
    });
    w.on('message', (msg) => console.log(msg));
  }
} else {
  const barrier = new Int32Array(workerData.sab);
  const { total, workerId } = workerData;

  // Phase 1: Each worker does some work
  const delay = Math.random() * 1000;
  const end = Date.now() + delay;
  while (Date.now() < end) { /* spin */ }
  parentPort.postMessage(`Worker ${workerId} finished phase 1 after ${delay.toFixed(0)} ms`);

  // Barrier: arrive and wait
  const arrived = Atomics.add(barrier, 0, 1) + 1;
  if (arrived < total) {
    // Not all threads have arrived — wait
    Atomics.wait(barrier, 0, arrived);
  } else {
    // Last thread to arrive — wake everyone
    Atomics.notify(barrier, 0);
  }

  parentPort.postMessage(`Worker ${workerId} passed the barrier`);
}
```

---

## Key Takeaways

- Race conditions occur when correctness depends on thread timing — the check-then-act pattern is the most common source, and `Atomics.compareExchange` is the fix for simple cases
- Deadlocks happen when threads hold locks and wait for each other in circular dependency — prevent them by always acquiring locks in a consistent global order
- A mutex built from `Atomics.compareExchange` and `Atomics.wait`/`Atomics.notify` protects critical sections where multiple shared memory operations must execute atomically
- Keep critical sections as short as possible — long critical sections reduce concurrency and increase contention
- `Atomics` operations provide sequential consistency — all threads agree on a single order of events, preventing the CPU memory reordering bugs that plague lock-free code in other languages

## Next

In the next lesson, we put everything together and build a production-grade custom thread pool — a fixed set of workers with a task queue, result dispatch, error handling, and graceful shutdown.
