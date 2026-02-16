# E04: Buffer vs String Performance

> Measure the real cost of different concatenation strategies when building HTTP responses from pieces. This exercise replaces folklore ("Buffers are faster") with hard numbers from your own benchmarks.

## Objective

Benchmark four different strategies for assembling a 1 MB HTTP response body from 1,000 small chunks: string concatenation with `+=`, array-of-strings with `.join()`, `Buffer.concat()`, and pre-allocated `Buffer.allocUnsafe()` with offset writes. Measure throughput, memory allocation, and GC pressure to understand when Buffers beat strings and when they do not.

## Prerequisites

- Module 03, Lesson 04 (Buffer Creation and Allocation)
- Module 03, Lesson 05 (Buffer Reading and Writing)
- Module 03, Lesson 06 (Buffer Slicing and Copying)
- Module 03, Lesson 08 (Buffer Performance)

## Instructions

1. **Create `bench.js`** with `'use strict';` and require `node:buffer` and `node:perf_hooks` (for `performance.now()`).

2. **Generate test data.** Create an array of 1,000 chunks, each a random-length string between 500 and 1,500 characters (ASCII only). Also create the corresponding Buffer versions with `Buffer.from(chunk)`. Pre-compute the total byte length.

   ```javascript
   const { performance } = require('node:perf_hooks');
   const chunks = [];
   const bufChunks = [];
   let totalBytes = 0;
   for (let i = 0; i < 1000; i++) {
     const len = 500 + Math.floor(Math.random() * 1000);
     const str = 'A'.repeat(len);
     chunks.push(str);
     bufChunks.push(Buffer.from(str));
     totalBytes += len;
   }
   ```

3. **Strategy 1: String `+=` concatenation.** Loop through all string chunks and accumulate with `+=`. Measure time with `performance.now()`. Run 100 iterations and report the average.

4. **Strategy 2: Array `.join('')`.** Push each string chunk into an array, then call `.join('')` at the end. Measure time. Run 100 iterations.

5. **Strategy 3: `Buffer.concat()`.** Call `Buffer.concat(bufChunks)` to merge all Buffer chunks into one. Measure time. Run 100 iterations.

6. **Strategy 4: Pre-allocated `Buffer.allocUnsafe()` with copy.** Allocate a single Buffer of `totalBytes` size upfront. Loop through `bufChunks`, copying each into the pre-allocated Buffer at the correct offset using `buf.copy(target, targetStart)`. Measure time. Run 100 iterations.

7. **Measure memory.** Before and after each strategy's 100 iterations, call `process.memoryUsage()` and report the delta in `heapUsed`. Force GC between strategies with `global.gc()` (run Node with `--expose-gc`).

8. **Print a results table.** Show strategy name, average time (ms), total time, and heap delta. Sort by average time.

9. **Analyze the results.** Add `console.log()` statements explaining:
   - Why string `+=` is O(n^2) for large concatenations (immutable string copies).
   - Why `Buffer.concat()` is faster (single allocation + memcpy).
   - Why pre-allocated is fastest (zero intermediate allocations).
   - When string `.join()` beats naive `+=` (V8 optimizes array join).

10. **Vary the parameters.** Run with 10 chunks, 100 chunks, 1,000 chunks, and 10,000 chunks. Note the crossover point where Buffer strategies start winning decisively.

## Break-Then-Harden Challenge

### Scenario 1 — Encoding Cost Hidden
Change the test data from ASCII to strings containing Unicode characters outside BMP (e.g., emoji `\u{1F600}`). Observe that `Buffer.from(str)` now produces more bytes than `str.length` characters, and the pre-allocated strategy's offset calculation breaks. Fix by using `Buffer.byteLength(str)` instead of `str.length` to compute the total allocation size.

### Scenario 2 — allocUnsafe Leak
In Strategy 4, allocate the buffer with `Buffer.allocUnsafe()` but only copy 900 of 1,000 chunks (simulate an early exit bug). Convert the result to a string and observe uninitialized memory leaking as garbage characters in the tail. Fix by tracking the actual bytes written and calling `buf.subarray(0, bytesWritten)` to return only the valid portion.

### Scenario 3 — GC Thrashing
Remove the `--expose-gc` flag and the `global.gc()` calls. Run the full benchmark suite in a tight loop 1,000 times. Observe inconsistent timings as GC kicks in unpredictably mid-benchmark. Fix by adding a warm-up phase (run each strategy 10 times before measuring) and by using `performance.now()` with statistical analysis (median instead of average).

## Expected Output

```
$ node --expose-gc bench.js
=== Buffer vs String Concatenation Benchmark ===
Chunks: 1000 | Chunk size: 500-1500 bytes | Total: ~750 KB
Iterations per strategy: 100

Strategy                       Avg (ms)   Heap Delta (KB)
─────────────────────────────────────────────────────────
Pre-allocated Buffer.copy()     0.42       +12
Buffer.concat()                 0.68       +780
Array.join('')                  1.15       +1,540
String +=                       3.87       +4,200

Winner: Pre-allocated Buffer.copy() (9.2x faster than string +=)

=== Scaling Test ===
Chunks      String +=    Buffer.concat()   Pre-alloc
10          0.01 ms      0.01 ms            0.01 ms
100         0.12 ms      0.05 ms            0.03 ms
1,000       3.87 ms      0.68 ms            0.42 ms
10,000      185.00 ms    6.20 ms            3.80 ms
```

## Bonus

1. **Add a streaming strategy.** Instead of building the entire response in memory, write chunks directly to a `Writable` stream (e.g., `/dev/null` or a `PassThrough` stream). Measure throughput in MB/s and compare memory usage.

2. **Add a `Buffer.allocUnsafe()` vs `Buffer.alloc()` micro-benchmark.** Measure the cost of zero-filling for allocation sizes from 1 byte to 10 MB. Find the size threshold where the zero-fill cost becomes noticeable.

3. **Add a `Rope` data structure strategy.** Instead of concatenating, build a tree of string references and only flatten when needed. Compare memory usage and concatenation time with the other strategies.

## Implementation Guidance

Here is a helper function for running each benchmark:

```javascript
function benchmark(name, fn, iterations = 100) {
  // Warm-up phase
  for (let i = 0; i < 10; i++) fn();

  if (typeof global.gc === 'function') global.gc();
  const heapBefore = process.memoryUsage().heapUsed;

  const times = [];
  for (let i = 0; i < iterations; i++) {
    const t0 = performance.now();
    fn();
    times.push(performance.now() - t0);
  }

  const heapAfter = process.memoryUsage().heapUsed;
  times.sort((a, b) => a - b);
  const median = times[Math.floor(times.length / 2)];
  const avg = times.reduce((s, t) => s + t, 0) / times.length;
  const heapDelta = heapAfter - heapBefore;

  return { name, avg, median, heapDelta };
}
```

And the four strategy functions:

```javascript
function strategyStringConcat() {
  let result = '';
  for (const chunk of chunks) result += chunk;
  return result;
}

function strategyArrayJoin() {
  const parts = [];
  for (const chunk of chunks) parts.push(chunk);
  return parts.join('');
}

function strategyBufferConcat() {
  return Buffer.concat(bufChunks);
}

function strategyPreAlloc() {
  const result = Buffer.allocUnsafe(totalBytes);
  let offset = 0;
  for (const chunk of bufChunks) {
    chunk.copy(result, offset);
    offset += chunk.length;
  }
  return result;
}
```

## Hints

1. `performance.now()` returns milliseconds with sub-millisecond precision. Wrap your loop: `const t0 = performance.now(); for (...) { ... } const elapsed = performance.now() - t0;`.

2. Run with `node --expose-gc bench.js` to enable `global.gc()`. Call it before each strategy to start from a clean heap state.

3. `process.memoryUsage().heapUsed` gives you the current heap in bytes. Take a snapshot before and after to measure allocation pressure.

4. For the scaling test, wrap everything in a function that takes `numChunks` as a parameter and call it with `[10, 100, 1000, 10000]`.

5. String `+=` creates a new string object on every iteration because JavaScript strings are immutable. With 1,000 iterations, you copy roughly `500 * 1000 * 1001 / 2` characters total — classic quadratic behavior.
