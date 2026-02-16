# E03: Shared Memory Counter

## Objective

Demonstrate the difference between unsafe and safe shared memory access across multiple worker threads. First, observe race conditions when multiple threads increment a counter in a raw `SharedArrayBuffer` without synchronization. Then, fix the race condition using `Atomics.add()` and verify that the final count is always correct. This exercise makes the invisible danger of data races tangible and quantifiable.

## Prerequisites

- Module 09 / Lesson 02 — The worker_threads Module
- Module 09 / Lesson 04 — SharedArrayBuffer & Atomics
- Module 09 / Lesson 05 — Thread Synchronization

## Instructions

1. **Create `shared-counter.js`** with `'use strict';` at the top. Require the following:

```javascript
'use strict';

const {
  Worker, isMainThread, parentPort, workerData
} = require('node:worker_threads');
const { performance } = require('node:perf_hooks');
```

2. **Define constants.** Set `WORKER_COUNT = 4` and `INCREMENTS_PER_WORKER = 1_000_000`. The expected final count is `WORKER_COUNT * INCREMENTS_PER_WORKER` which equals 4,000,000.

3. **Create the SharedArrayBuffer.** In the main thread, allocate a `SharedArrayBuffer` of 4 bytes. Wrap it in an `Int32Array` (1 element at index 0). This single integer is the shared counter that all workers will try to increment simultaneously.

```javascript
const sharedBuffer = new SharedArrayBuffer(4);
const view = new Int32Array(sharedBuffer);
// view[0] starts at 0 — this is the counter
```

4. **Implement the unsafe worker path.** When running as a worker (`!isMainThread`), receive the `SharedArrayBuffer` via `workerData.buffer` and the mode via `workerData.useAtomics`. Create an `Int32Array` view over the received buffer. When `useAtomics` is `false`, use a deliberate non-atomic read-modify-write loop:

```javascript
if (!isMainThread) {
  const view = new Int32Array(workerData.buffer);
  const increments = workerData.increments;

  if (!workerData.useAtomics) {
    // UNSAFE: non-atomic read-modify-write
    for (let i = 0; i < increments; i++) {
      const current = view[0];   // read
      view[0] = current + 1;     // write — another thread may have changed view[0]
    }
  } else {
    // SAFE: atomic increment
    for (let i = 0; i < increments; i++) {
      Atomics.add(view, 0, 1);
    }
  }

  parentPort.postMessage('done');
}
```

5. **Implement the safe worker path.** When `workerData.useAtomics` is `true`, use `Atomics.add(view, 0, 1)` inside the loop. This performs the read-modify-write as a single atomic CPU instruction that cannot be interrupted by another thread.

6. **Write a `runTest(useAtomics)` function** in the main thread that:
   - Resets the counter to 0 with `Atomics.store(view, 0, 0)`
   - Records the start time with `performance.now()`
   - Spawns `WORKER_COUNT` workers, each passing `{ buffer: sharedBuffer, increments: INCREMENTS_PER_WORKER, useAtomics }`
   - Wraps each worker in a Promise that resolves on the `'message'` event
   - Awaits `Promise.all()` to wait for all workers to finish
   - Reads the final counter value from `view[0]`
   - Returns `{ finalValue, expected, elapsed, correct }`

```javascript
async function runTest(useAtomics) {
  Atomics.store(view, 0, 0);  // reset counter
  const expected = WORKER_COUNT * INCREMENTS_PER_WORKER;
  const start = performance.now();

  const workers = [];
  for (let i = 0; i < WORKER_COUNT; i++) {
    workers.push(new Promise((resolve, reject) => {
      const w = new Worker(__filename, {
        workerData: { buffer: sharedBuffer, increments: INCREMENTS_PER_WORKER, useAtomics }
      });
      w.on('message', resolve);
      w.on('error', reject);
    }));
  }
  await Promise.all(workers);

  const elapsed = performance.now() - start;
  const finalValue = view[0];
  return { finalValue, expected, elapsed, correct: finalValue === expected };
}
```

7. **Run the unsafe version.** Call `runTest(false)` five times. Print each run's final value alongside the expected value (4,000,000). Every run should show a different (wrong) result — this is the race condition in action. Calculate the average error (how many increments were lost).

8. **Run the safe version.** Call `runTest(true)` five times. Print results. Every run should show exactly 4,000,000. No lost increments.

9. **Measure performance.** After both test suites, print a comparison: average time for the unsafe version versus the safe (atomic) version. The atomic version will be slower because `Atomics.add` issues a memory barrier on every iteration. Calculate the overhead factor.

10. **Print a final summary** comparing correctness versus performance for both approaches. The takeaway: the unsafe version is faster but wrong; the atomic version is slower but provably correct. There is no middle ground — in concurrent programming, "almost correct" means "wrong."

## Break-Then-Harden Challenge

### Scenario 1 — Invisible Race Condition

Reduce `INCREMENTS_PER_WORKER` to 100. Run the unsafe version 50 times and tally how many runs produce the correct result (4 * 100 = 400). You will find that many runs accidentally succeed because 100 iterations complete so fast that threads rarely overlap. This demonstrates the most dangerous property of race conditions: they can hide in small tests and only surface under production load. Increase back to 1,000,000 and confirm the bug is obvious every single run.

### Scenario 2 — Wrong TypedArray View

Replace `Int32Array` with `Uint8Array` but keep the `SharedArrayBuffer` at 4 bytes. Use `Atomics.add(uint8View, 0, 1)` in the safe path. Observe that the counter overflows at 255 and wraps around — after 256 increments, the value is 0 again. The atomics work correctly but the data type is wrong. Fix it by matching the TypedArray type to the expected value range. For counters exceeding 2^31, use `BigInt64Array` with `Atomics.add(bigView, 0, 1n)`.

### Scenario 3 — Forgetting to Reset

Remove the `Atomics.store(view, 0, 0)` reset between the unsafe and safe test suites. The safe run now starts from whatever (wrong) value the unsafe run left behind. Even though every atomic increment is correct, the starting value is corrupted, so the "safe" result is also wrong. This shows that atomics only protect individual operations — you are still responsible for the correctness of the overall protocol.

## Expected Output

```
$ node shared-counter.js

Configuration: 4 workers x 1,000,000 increments = 4,000,000 expected

=== Unsafe Counter (no Atomics) ===
Run 1: 2,847,193 (expected 4,000,000) WRONG  lost 1,152,807
Run 2: 3,124,507 (expected 4,000,000) WRONG  lost   875,493
Run 3: 2,956,832 (expected 4,000,000) WRONG  lost 1,043,168
Run 4: 3,201,445 (expected 4,000,000) WRONG  lost   798,555
Run 5: 2,789,661 (expected 4,000,000) WRONG  lost 1,210,339
Average value:  2,983,928
Average lost:   1,016,072 (25.4% of increments lost to races)
Average time:   52.3 ms

=== Safe Counter (Atomics.add) ===
Run 1: 4,000,000 (expected 4,000,000) CORRECT
Run 2: 4,000,000 (expected 4,000,000) CORRECT
Run 3: 4,000,000 (expected 4,000,000) CORRECT
Run 4: 4,000,000 (expected 4,000,000) CORRECT
Run 5: 4,000,000 (expected 4,000,000) CORRECT
Average value:  4,000,000 (100% correct)
Average time:   187.6 ms

=== Performance Comparison ===
Unsafe average:  52.3 ms (fast but wrong)
Atomic average:  187.6 ms (slow but correct)
Atomics overhead: 3.59x slower
Cost of correctness: 135.3 ms per run
```

## Bonus

1. **Atomic spinlock.** Implement a mutex using `Atomics.compareExchange(view, lockIndex, 0, 1)` to acquire a lock and `Atomics.store(view, lockIndex, 0)` to release it. Protect a critical section where you do a non-atomic read-modify-write on a second counter element. Verify correctness and compare performance to raw `Atomics.add()` — the spinlock should be slower due to contention.

2. **Multiple counters.** Extend the `SharedArrayBuffer` to 16 bytes (`Int32Array` of length 4). Assign each of the 4 workers a different counter index. Verify all four counters reach 1,000,000 independently. Then have all 4 workers increment the *same* index and verify atomics still produce the correct total (4,000,000).

## Hints

1. `new SharedArrayBuffer(4)` allocates 4 bytes of memory visible to all threads. `new Int32Array(sharedBuffer)` creates a typed view into that memory — both the main thread and workers share the same underlying bytes.

2. The race condition happens because `read -> add 1 -> write` is three separate CPU operations. Between your read and your write, another thread can read the same "old" value and write its own increment, causing one of the two increments to be silently lost.

3. `Atomics.add(view, index, value)` performs the read-modify-write as a single atomic CPU instruction (typically a `lock xadd` on x86). No other thread can see the intermediate state.

4. Pass the `SharedArrayBuffer` to workers via `workerData`, not the `Int32Array` view. The view cannot be transferred across threads — workers must create their own `Int32Array` from the received buffer.

5. Use `Promise.all()` with worker exit or message Promises to wait for all workers to finish before reading the final counter value. Reading the counter before all workers exit gives a partial (and misleading) result.
