# E04: GC Pressure Benchmark

## Objective

Generate controlled memory pressure in V8 and measure garbage collection pauses using the `--trace-gc` flag and `process.memoryUsage()`. By comparing different allocation patterns, you will learn which coding patterns trigger expensive GC cycles and how to structure code to minimize pause times.

## Prerequisites

- Module 01 / Lesson 02 — V8 Engine (Compilation Pipeline, Memory Model)
- Module 01 / Lesson 04 — Event Loop Deep Dive

## Instructions

1. Create a file called `gc-pressure.js`. Add `'use strict';` at the top:

```javascript
'use strict';

const { performance, PerformanceObserver } = require('node:perf_hooks');
```

2. Write a helper function to capture memory snapshots:

```javascript
function memSnapshot(label) {
  const mem = process.memoryUsage();
  console.log(`[${label}]`);
  console.log(`  RSS:       ${(mem.rss / 1024 / 1024).toFixed(2)} MB`);
  console.log(`  Heap Used: ${(mem.heapUsed / 1024 / 1024).toFixed(2)} MB`);
  console.log(`  Heap Total:${(mem.heapTotal / 1024 / 1024).toFixed(2)} MB`);
  console.log(`  External:  ${(mem.external / 1024 / 1024).toFixed(2)} MB`);
  return mem;
}
```

3. **Benchmark 1 — Short-Lived Object Flood.** Allocate 1 million small objects in a tight loop. Each object should have 3 properties. Measure time and memory before and after:

```javascript
function shortLivedFlood(count) {
  memSnapshot('Before short-lived flood');
  const start = performance.now();

  for (let i = 0; i < count; i++) {
    const obj = { id: i, name: `item-${i}`, active: i % 2 === 0 };
    // obj becomes garbage immediately — no reference retained
  }

  const elapsed = performance.now() - start;
  memSnapshot('After short-lived flood');
  console.log(`  Elapsed: ${elapsed.toFixed(2)}ms\n`);
}
```

4. **Benchmark 2 — Retained Object Growth.** Allocate the same 1 million objects but push each into an array so they cannot be garbage collected:

```javascript
function retainedGrowth(count) {
  memSnapshot('Before retained growth');
  const start = performance.now();
  const retained = [];

  for (let i = 0; i < count; i++) {
    retained.push({ id: i, name: `item-${i}`, active: i % 2 === 0 });
  }

  const elapsed = performance.now() - start;
  memSnapshot('After retained growth');
  console.log(`  Retained: ${retained.length} objects`);
  console.log(`  Elapsed: ${elapsed.toFixed(2)}ms\n`);
  return retained;
}
```

5. **Benchmark 3 — Buffer Allocation Patterns.** Compare three patterns: `Buffer.alloc(1024)` (zero-filled), `Buffer.allocUnsafe(1024)` (uninitialized), and `Buffer.from('x'.repeat(1024))` (copy from string). Allocate 100,000 of each and measure time:

```javascript
function bufferBenchmark(count) {
  const patterns = [
    { name: 'Buffer.alloc', fn: () => Buffer.alloc(1024) },
    { name: 'Buffer.allocUnsafe', fn: () => Buffer.allocUnsafe(1024) },
    { name: 'Buffer.from(string)', fn: () => Buffer.from('x'.repeat(1024)) },
  ];

  for (const pattern of patterns) {
    memSnapshot(`Before ${pattern.name}`);
    const start = performance.now();
    const buffers = [];

    for (let i = 0; i < count; i++) {
      buffers.push(pattern.fn());
    }

    const elapsed = performance.now() - start;
    memSnapshot(`After ${pattern.name}`);
    console.log(`  Elapsed: ${elapsed.toFixed(2)}ms\n`);
    buffers.length = 0; // release for GC
  }
}
```

6. **Benchmark 4 — String Concatenation vs. Array Join.** Build a 1MB string two ways: repeated `+=` concatenation vs. pushing to an array and calling `.join('')`. Measure memory and time for each:

```javascript
function stringBenchmark(iterations) {
  // Pattern A: concatenation
  memSnapshot('Before string concat');
  let start = performance.now();
  let result = '';
  for (let i = 0; i < iterations; i++) {
    result += 'abcdefghij'; // 10 chars per iteration
  }
  console.log(`  Concat: ${(performance.now() - start).toFixed(2)}ms, length=${result.length}`);
  memSnapshot('After string concat');
  result = null;

  // Pattern B: array join
  memSnapshot('Before array join');
  start = performance.now();
  const parts = [];
  for (let i = 0; i < iterations; i++) {
    parts.push('abcdefghij');
  }
  const joined = parts.join('');
  console.log(`  Join:   ${(performance.now() - start).toFixed(2)}ms, length=${joined.length}\n`);
  memSnapshot('After array join');
}
```

7. **Run all benchmarks** in sequence and add a final summary:

```javascript
shortLivedFlood(1_000_000);
const retained = retainedGrowth(1_000_000);
retained.length = 0; // release before next benchmark
bufferBenchmark(100_000);
stringBenchmark(100_000);
memSnapshot('FINAL');
```

8. Run the script with GC tracing enabled:

```bash
node --trace-gc gc-pressure.js
```

9. Count the number of `Scavenge` (minor GC) and `Mark-Sweep` (major GC) lines in the `--trace-gc` output. Record which benchmark triggered the most major GC pauses.

10. Run again with `--max-old-space-size=64` to simulate a memory-constrained environment and observe how GC behavior changes under pressure.

## Break-Then-Harden Challenge

1. **Force an OOM crash.** Remove the `retained.length = 0` line and increase `retainedGrowth` to 10 million objects. Run with `--max-old-space-size=128`. Observe the `FATAL ERROR: CALL_AND_RETRY_LAST Allocation failed - JavaScript heap out of memory`. Then add a WeakRef-based cache pattern that allows GC to reclaim objects when memory is scarce.

2. **Hidden class deoptimization.** Modify the short-lived flood to add properties in random order (sometimes `{ id, name, active }`, sometimes `{ active, id, name }`). Run with `--trace-gc` and compare the number of GC pauses. Explain why V8's hidden classes make consistent property order matter for performance.

3. **Global leak.** Accidentally assign one of the retained arrays to `global.leak` instead of a local variable. Run the benchmark, then use `process.memoryUsage()` in a `setInterval` to prove the memory is never reclaimed even after you null the local reference.

## Expected Output

```
[Before short-lived flood]
  RSS:       28.34 MB
  Heap Used: 4.12 MB
  Heap Total:6.78 MB
  External:  1.09 MB
[After short-lived flood]
  RSS:       29.81 MB
  Heap Used: 5.01 MB
  Heap Total:8.52 MB
  External:  1.09 MB
  Elapsed: 142.56ms

[Before retained growth]
  RSS:       29.81 MB
  Heap Used: 5.01 MB
  ...
[After retained growth]
  RSS:       198.42 MB
  Heap Used: 152.34 MB
  ...
  Retained: 1000000 objects
  Elapsed: 1023.45ms

...

[FINAL]
  RSS:       45.12 MB
  Heap Used: 8.91 MB
  Heap Total:12.50 MB
  External:  1.09 MB
```

(Exact numbers vary by machine and Node.js version. The pattern — retained objects causing dramatically higher heap usage — is what matters.)

## Bonus

1. Use `v8.getHeapStatistics()` from `require('node:v8')` to get detailed heap space breakdowns (new space, old space, code space, map space). Print these for each benchmark.

2. Set up a `PerformanceObserver` for the `'gc'` entry type to programmatically capture GC pause durations instead of parsing `--trace-gc` output. Compute mean, median, and p99 pause times.

## Hints

1. `--trace-gc` output lines starting with `Scavenge` are minor (young generation) collections. Lines with `Mark-Sweep` or `Mark-Compact` are major (old generation) collections.
2. Short-lived objects that die in young generation are cheap to collect. Objects that survive multiple scavenges get promoted to old space, where collection is expensive.
3. `Buffer.allocUnsafe` is faster than `Buffer.alloc` because it skips zero-filling, but the memory may contain sensitive data from previous allocations.
4. String concatenation with `+=` creates intermediate strings that become garbage — V8 optimizes small concatenations but large ones generate significant GC pressure.
5. `process.memoryUsage().rss` is the Resident Set Size (total OS-level memory), while `heapUsed` is only the V8 heap portion. The difference includes native C++ objects, Buffers stored in external memory, and the Node.js runtime itself.
