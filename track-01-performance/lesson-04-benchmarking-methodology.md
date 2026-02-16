# Track 01 / Lesson 04 — Benchmarking Methodology

> "We rewrote the function and it is 3x faster!" is a meaningless claim without methodology. Did you warm up the JIT? Did you account for garbage collection pauses? Did you run enough iterations to reach statistical significance? This lesson teaches you to benchmark Node.js code with the rigor that turns anecdotes into evidence.

## Learning Objectives

- Use `performance.mark()`, `performance.measure()`, and `PerformanceObserver` to instrument code with high-resolution timing
- Apply `performance.timerify()` to automatically measure function execution time
- Build a reusable benchmark harness that computes mean, median, standard deviation, and p99
- Identify and avoid common micro-benchmark traps: dead code elimination, insufficient warmup, and GC interference
- Design benchmarks with warmup runs, multiple iterations, and statistical validation

---

## High-Resolution Timing with perf_hooks

The `node:perf_hooks` module provides microsecond-precision timing backed by the Performance Timeline API. It is the foundation of all serious benchmarking in Node.js.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// performance.now() returns time in milliseconds with sub-millisecond precision
const start = performance.now();

// Do some work
let sum = 0;
for (let i = 0; i < 1e7; i++) {
  sum += Math.sqrt(i);
}

const end = performance.now();
console.log(`Elapsed: ${(end - start).toFixed(3)}ms`);
console.log(`Result: ${sum}`); // Always use the result!

// Compare with Date.now() — millisecond precision only
const dateStart = Date.now();
for (let i = 0; i < 1e7; i++) {
  sum += Math.sqrt(i);
}
const dateEnd = Date.now();
console.log(`Date.now() elapsed: ${dateEnd - dateStart}ms`);
// Date.now() can only resolve to 1ms — too coarse for fast operations
```

**Never use `Date.now()` for benchmarking.** It has only millisecond resolution and is subject to system clock adjustments. `performance.now()` uses a monotonic clock with sub-millisecond precision.

---

## Marks and Measures

`performance.mark()` creates named timestamps. `performance.measure()` calculates the duration between two marks. This is cleaner than manual `performance.now()` arithmetic.

```javascript
'use strict';

const { performance, PerformanceObserver } = require('node:perf_hooks');

// Observe all measure entries
const observer = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    console.log(`${entry.name}: ${entry.duration.toFixed(3)}ms`);
  }
});
observer.observe({ entryTypes: ['measure'] });

// Mark the start of each operation
performance.mark('sort-start');

const data = Array.from({ length: 100000 }, () => Math.random());
data.sort((a, b) => a - b);

performance.mark('sort-end');
performance.measure('Array.sort (100K numbers)', 'sort-start', 'sort-end');

// Another operation
performance.mark('stringify-start');

const obj = {};
for (let i = 0; i < 10000; i++) {
  obj[`key${i}`] = { value: i, nested: { data: `item-${i}` } };
}
JSON.stringify(obj);

performance.mark('stringify-end');
performance.measure('JSON.stringify (10K keys)', 'stringify-start', 'stringify-end');

// Cleanup
setTimeout(() => {
  observer.disconnect();
  performance.clearMarks();
  performance.clearMeasures();
}, 100);
```

The `PerformanceObserver` pattern decouples measurement from reporting. The code being measured does not need to know what happens with the timing data.

---

## performance.timerify()

`timerify()` wraps a function so that every call is automatically measured and reported through the `PerformanceObserver`.

```javascript
'use strict';

const { performance, PerformanceObserver } = require('node:perf_hooks');
const { createHash } = require('node:crypto');

// Observe timerified function entries
const observer = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    console.log(`${entry.name}(): ${entry.duration.toFixed(3)}ms`);
  }
});
observer.observe({ entryTypes: ['function'] });

// Original functions
function hashData(data) {
  return createHash('sha256').update(data).digest('hex');
}

function sortNumbers(arr) {
  return [...arr].sort((a, b) => a - b);
}

function buildObject(size) {
  const obj = {};
  for (let i = 0; i < size; i++) {
    obj[`k${i}`] = i * Math.PI;
  }
  return obj;
}

// Wrap with timerify — returns a new function that measures every call
const timedHash = performance.timerify(hashData);
const timedSort = performance.timerify(sortNumbers);
const timedBuild = performance.timerify(buildObject);

// Now every call is measured automatically
const bigData = Buffer.alloc(1024 * 1024, 'x').toString();
timedHash(bigData);
timedHash(bigData);
timedHash(bigData);

const numbers = Array.from({ length: 50000 }, () => Math.random());
timedSort(numbers);
timedSort(numbers);

timedBuild(10000);
timedBuild(50000);

setTimeout(() => observer.disconnect(), 100);
```

`timerify()` is useful for rapid instrumentation — you can wrap any function without modifying its internals. The overhead is minimal (a few microseconds per call), but avoid using it in production hot paths where even that overhead matters.

---

## The Warmup Problem

V8 interprets JavaScript before it optimizes it. The first few runs of a function execute in the interpreter (or Sparkplug baseline compiler), which is significantly slower than TurboFan-optimized code. If you benchmark without warmup, you are measuring the interpreter — not the optimized path your production code takes.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

function fibonacci(n) {
  if (n <= 1) return n;
  let a = 0, b = 1;
  for (let i = 2; i <= n; i++) {
    [a, b] = [b, a + b];
  }
  return b;
}

// Benchmark WITHOUT warmup
const coldTimes = [];
for (let i = 0; i < 20; i++) {
  // Create a NEW function each time to prevent V8 from optimizing
  // (This simulates what happens without warmup)
  const fn = new Function('n', `
    if (n <= 1) return n;
    let a = 0, b = 1;
    for (let i = 2; i <= n; i++) { [a, b] = [b, a + b]; }
    return b;
  `);
  const start = performance.now();
  fn(1000);
  coldTimes.push(performance.now() - start);
}

// Benchmark WITH warmup
// First, run the function enough times to trigger optimization
for (let i = 0; i < 10000; i++) {
  fibonacci(1000);
}

const warmTimes = [];
for (let i = 0; i < 20; i++) {
  const start = performance.now();
  fibonacci(1000);
  warmTimes.push(performance.now() - start);
}

function stats(times) {
  const sorted = [...times].sort((a, b) => a - b);
  const sum = sorted.reduce((a, b) => a + b, 0);
  return {
    mean: (sum / sorted.length).toFixed(4),
    median: sorted[Math.floor(sorted.length / 2)].toFixed(4),
    min: sorted[0].toFixed(4),
    max: sorted[sorted.length - 1].toFixed(4)
  };
}

console.log('Cold (no warmup):', stats(coldTimes));
console.log('Warm (after 10K runs):', stats(warmTimes));
// The warm runs are typically 5-50x faster than cold runs
```

**Rule: Always run at least 1,000-10,000 warmup iterations before measuring.** The exact number depends on the function complexity, but err on the side of more warmup.

---

## Dead Code Elimination

V8 is smart enough to eliminate code whose result is never used. If your benchmark does not use the return value of the function being measured, V8 may optimize the entire function body away — and you will measure nothing.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

function computeSum(n) {
  let sum = 0;
  for (let i = 0; i < n; i++) {
    sum += Math.sqrt(i);
  }
  return sum;
}

// BAD: Result is never used — V8 may eliminate the computation
function benchmarkBad() {
  const start = performance.now();
  for (let i = 0; i < 1000; i++) {
    computeSum(10000); // Return value discarded!
  }
  return performance.now() - start;
}

// GOOD: Result is accumulated and used
function benchmarkGood() {
  let sink = 0; // "Sink" variable prevents dead code elimination
  const start = performance.now();
  for (let i = 0; i < 1000; i++) {
    sink += computeSum(10000); // Result is used
  }
  const elapsed = performance.now() - start;
  if (sink === 0) console.log(sink); // Ensure sink is not optimized away
  return elapsed;
}

// Warmup
for (let i = 0; i < 5000; i++) computeSum(100);

console.log(`Bad benchmark: ${benchmarkBad().toFixed(2)}ms`);
console.log(`Good benchmark: ${benchmarkGood().toFixed(2)}ms`);
// The "bad" benchmark may report suspiciously fast times
```

**The sink pattern:** Accumulate results into a variable and reference it after the benchmark loop. This prevents V8 from proving the computation is useless and eliminating it.

---

## GC Interference

Garbage collection pauses inject noise into benchmarks. A GC pause during one iteration can make it appear 100x slower than the others, skewing your mean.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

function allocateAndProcess(size) {
  const arr = new Array(size);
  for (let i = 0; i < size; i++) {
    arr[i] = { id: i, value: Math.random().toString(36) };
  }
  return arr.reduce((sum, item) => sum + item.value.length, 0);
}

// Run benchmark and track each iteration
const iterations = 50;
const times = [];

// Warmup
for (let i = 0; i < 1000; i++) allocateAndProcess(100);

for (let i = 0; i < iterations; i++) {
  const start = performance.now();
  allocateAndProcess(50000);
  times.push(performance.now() - start);
}

// Analyze the results
const sorted = [...times].sort((a, b) => a - b);
const sum = sorted.reduce((a, b) => a + b, 0);
const mean = sum / sorted.length;
const median = sorted[Math.floor(sorted.length / 2)];
const p99 = sorted[Math.floor(sorted.length * 0.99)];
const stddev = Math.sqrt(
  sorted.reduce((acc, t) => acc + (t - mean) ** 2, 0) / sorted.length
);

console.log('=== Raw Benchmark Results ===');
console.log(`Iterations:  ${iterations}`);
console.log(`Mean:        ${mean.toFixed(3)}ms`);
console.log(`Median:      ${median.toFixed(3)}ms`);
console.log(`StdDev:      ${stddev.toFixed(3)}ms`);
console.log(`Min:         ${sorted[0].toFixed(3)}ms`);
console.log(`Max:         ${sorted[sorted.length - 1].toFixed(3)}ms`);
console.log(`p99:         ${p99.toFixed(3)}ms`);
console.log(`CoV:         ${((stddev / mean) * 100).toFixed(1)}%`);

// If CoV (coefficient of variation) > 10%, results are too noisy
// Common cause: GC pauses in the middle of iterations
if ((stddev / mean) > 0.1) {
  console.log('\n[WARNING] High variance — likely GC interference');
  console.log('Mitigation: use median instead of mean, or run with --expose-gc');
  console.log('and call global.gc() between iterations');
}
```

**Mitigation strategies:**

1. Use **median** instead of mean — it is resistant to GC outliers
2. Run with `--expose-gc` and call `global.gc()` between iterations to force GC outside measurement
3. Increase iteration count — more samples dilute the GC noise
4. Report both mean and median — a large gap between them signals GC interference

---

## Building a Reusable Benchmark Harness

Here is a complete benchmark harness that handles warmup, statistics, and reporting.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

class Benchmark {
  constructor(name, fn, options = {}) {
    this.name = name;
    this.fn = fn;
    this.warmup = options.warmup || 1000;
    this.iterations = options.iterations || 100;
    this.times = [];
  }

  run() {
    // Phase 1: Warmup
    let sink = 0;
    for (let i = 0; i < this.warmup; i++) {
      const r = this.fn();
      if (typeof r === 'number') sink += r;
    }

    // Force GC if available (run with --expose-gc)
    if (global.gc) global.gc();

    // Phase 2: Measurement
    for (let i = 0; i < this.iterations; i++) {
      // Force GC between iterations if available
      if (global.gc && i % 10 === 0) global.gc();

      const start = performance.now();
      const result = this.fn();
      const elapsed = performance.now() - start;
      this.times.push(elapsed);

      if (typeof result === 'number') sink += result;
    }

    // Reference sink to prevent DCE
    if (sink === -Infinity) console.log(sink);

    return this.stats();
  }

  stats() {
    const sorted = [...this.times].sort((a, b) => a - b);
    const len = sorted.length;
    const sum = sorted.reduce((a, b) => a + b, 0);
    const mean = sum / len;

    const variance = sorted.reduce((acc, t) => acc + (t - mean) ** 2, 0) / len;
    const stddev = Math.sqrt(variance);

    // Remove top and bottom 5% for trimmed mean
    const trimCount = Math.floor(len * 0.05);
    const trimmed = sorted.slice(trimCount, len - trimCount);
    const trimmedMean = trimmed.reduce((a, b) => a + b, 0) / trimmed.length;

    return {
      name: this.name,
      iterations: len,
      mean: mean,
      median: sorted[Math.floor(len / 2)],
      stddev: stddev,
      min: sorted[0],
      max: sorted[len - 1],
      p90: sorted[Math.floor(len * 0.9)],
      p99: sorted[Math.floor(len * 0.99)],
      trimmedMean: trimmedMean,
      cov: stddev / mean // Coefficient of variation
    };
  }
}

class BenchmarkSuite {
  constructor(name) {
    this.name = name;
    this.benchmarks = [];
  }

  add(name, fn, options) {
    this.benchmarks.push(new Benchmark(name, fn, options));
    return this;
  }

  run() {
    console.log(`\n=== ${this.name} ===\n`);

    const results = [];
    for (const bench of this.benchmarks) {
      const stats = bench.run();
      results.push(stats);
    }

    // Print results table
    console.log(
      'Benchmark'.padEnd(30),
      'Mean'.padStart(10),
      'Median'.padStart(10),
      'StdDev'.padStart(10),
      'p99'.padStart(10),
      'CoV'.padStart(8)
    );
    console.log('-'.repeat(80));

    for (const r of results) {
      console.log(
        r.name.padEnd(30),
        (r.mean.toFixed(3) + 'ms').padStart(10),
        (r.median.toFixed(3) + 'ms').padStart(10),
        (r.stddev.toFixed(3) + 'ms').padStart(10),
        (r.p99.toFixed(3) + 'ms').padStart(10),
        ((r.cov * 100).toFixed(1) + '%').padStart(8)
      );
    }

    // Compare: fastest vs slowest
    if (results.length > 1) {
      const sorted = [...results].sort((a, b) => a.median - b.median);
      const fastest = sorted[0];
      const slowest = sorted[sorted.length - 1];
      const ratio = slowest.median / fastest.median;

      console.log(`\nFastest: ${fastest.name} (${fastest.median.toFixed(3)}ms)`);
      console.log(
        `Slowest: ${slowest.name} (${slowest.median.toFixed(3)}ms) — ` +
        `${ratio.toFixed(1)}x slower`
      );
    }

    return results;
  }
}

// Example: Compare different approaches to the same problem
const suite = new BenchmarkSuite('String Concatenation Methods');

const parts = Array.from({ length: 1000 }, (_, i) => `segment-${i}`);

suite.add('Array.join', () => {
  return parts.join('');
}, { warmup: 5000, iterations: 200 });

suite.add('String +=', () => {
  let result = '';
  for (const part of parts) {
    result += part;
  }
  return result.length;
}, { warmup: 5000, iterations: 200 });

suite.add('Template literal', () => {
  let result = '';
  for (const part of parts) {
    result = `${result}${part}`;
  }
  return result.length;
}, { warmup: 5000, iterations: 200 });

suite.run();
```

---

## Avoiding Micro-Benchmark Traps

### Trap 1: Measuring the Wrong Thing

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// BAD: Benchmarking Map vs Object lookup
// but the benchmark is dominated by setup, not lookup

function badBenchmark() {
  const start = performance.now();

  // 99% of time is spent here (setup) — not in the lookup
  const map = new Map();
  for (let i = 0; i < 100000; i++) {
    map.set(`key-${i}`, i);
  }
  map.get('key-50000'); // This is what we want to measure!

  return performance.now() - start;
}

// GOOD: Separate setup from measurement
function goodBenchmark() {
  // Setup (not measured)
  const map = new Map();
  for (let i = 0; i < 100000; i++) {
    map.set(`key-${i}`, i);
  }

  // Measurement (only the lookup)
  let sink = 0;
  const start = performance.now();
  for (let i = 0; i < 100000; i++) {
    sink += map.get(`key-${i % 100000}`);
  }
  const elapsed = performance.now() - start;
  if (sink === -1) console.log(sink);
  return elapsed;
}

console.log(`Bad benchmark: ${badBenchmark().toFixed(3)}ms (measures setup + lookup)`);
console.log(`Good benchmark: ${goodBenchmark().toFixed(3)}ms (measures only lookup)`);
```

### Trap 2: Constant Folding

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// BAD: V8 can compute this at compile time
function badConstantBenchmark() {
  let sink = 0;
  const start = performance.now();
  for (let i = 0; i < 1e6; i++) {
    sink += 2 * 3.14159 * 10; // Constant expression — folded by V8
  }
  const elapsed = performance.now() - start;
  if (sink === 0) console.log(sink);
  return elapsed;
}

// GOOD: Use variable input that V8 cannot predict
function goodVariableBenchmark() {
  let sink = 0;
  const radii = Array.from({ length: 1000 }, () => Math.random() * 100);
  const start = performance.now();
  for (let i = 0; i < 1e6; i++) {
    sink += 2 * Math.PI * radii[i % radii.length]; // Variable input
  }
  const elapsed = performance.now() - start;
  if (sink === 0) console.log(sink);
  return elapsed;
}

console.log(`Constant: ${badConstantBenchmark().toFixed(3)}ms (may be folded)`);
console.log(`Variable: ${goodVariableBenchmark().toFixed(3)}ms (real computation)`);
```

### Trap 3: Insufficient Iterations

```javascript
'use strict';

const { performance } = require('node:perf_hooks');
const { createHash } = require('node:crypto');

function hashOnce(data) {
  return createHash('sha256').update(data).digest('hex');
}

const testData = 'benchmark-input-data';

// Warmup
for (let i = 0; i < 10000; i++) hashOnce(testData);

// Compare different iteration counts
for (const count of [5, 20, 100, 1000]) {
  const times = [];
  for (let i = 0; i < count; i++) {
    const start = performance.now();
    hashOnce(testData);
    times.push(performance.now() - start);
  }

  const sorted = [...times].sort((a, b) => a - b);
  const mean = sorted.reduce((a, b) => a + b, 0) / sorted.length;
  const median = sorted[Math.floor(sorted.length / 2)];
  const stddev = Math.sqrt(
    sorted.reduce((acc, t) => acc + (t - mean) ** 2, 0) / sorted.length
  );
  const cov = ((stddev / mean) * 100).toFixed(1);

  console.log(
    `N=${String(count).padStart(5)}: ` +
    `mean=${mean.toFixed(4)}ms, ` +
    `median=${median.toFixed(4)}ms, ` +
    `CoV=${cov}%`
  );
}

// Rule: CoV should be under 5% for reliable results
// If it is not, increase iterations until it stabilizes
```

---

## Statistical Significance: Is the Difference Real?

When comparing two implementations, you need to determine whether the observed difference is real or just noise.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// Simple two-sample t-test approximation
function isSignificantlyDifferent(samplesA, samplesB, confidence = 0.95) {
  const meanA = samplesA.reduce((a, b) => a + b, 0) / samplesA.length;
  const meanB = samplesB.reduce((a, b) => a + b, 0) / samplesB.length;

  const varA = samplesA.reduce((acc, x) => acc + (x - meanA) ** 2, 0) / (samplesA.length - 1);
  const varB = samplesB.reduce((acc, x) => acc + (x - meanB) ** 2, 0) / (samplesB.length - 1);

  const se = Math.sqrt(varA / samplesA.length + varB / samplesB.length);
  const tStat = Math.abs(meanA - meanB) / se;

  // Approximate critical t-value for 95% confidence with large N
  const criticalT = confidence === 0.95 ? 1.96 : 2.576; // 99%

  return {
    meanA: meanA.toFixed(4),
    meanB: meanB.toFixed(4),
    difference: (meanA - meanB).toFixed(4),
    percentDiff: (((meanA - meanB) / meanB) * 100).toFixed(1) + '%',
    tStatistic: tStat.toFixed(2),
    significant: tStat > criticalT,
    verdict: tStat > criticalT
      ? `Statistically significant (t=${tStat.toFixed(2)} > ${criticalT})`
      : `NOT significant (t=${tStat.toFixed(2)} < ${criticalT})`
  };
}

// Compare two approaches: for-of vs traditional for loop
function benchmarkForOf(arr) {
  let sum = 0;
  for (const val of arr) sum += val;
  return sum;
}

function benchmarkForLoop(arr) {
  let sum = 0;
  for (let i = 0; i < arr.length; i++) sum += arr[i];
  return sum;
}

const data = Array.from({ length: 100000 }, () => Math.random());

// Warmup both
for (let i = 0; i < 5000; i++) {
  benchmarkForOf(data);
  benchmarkForLoop(data);
}

// Collect samples
const samplesA = [];
const samplesB = [];

for (let i = 0; i < 200; i++) {
  let start = performance.now();
  benchmarkForOf(data);
  samplesA.push(performance.now() - start);

  start = performance.now();
  benchmarkForLoop(data);
  samplesB.push(performance.now() - start);
}

console.log('for-of vs for loop comparison:');
console.log(JSON.stringify(isSignificantlyDifferent(samplesA, samplesB), null, 2));
```

---

## Key Takeaways

- Always use `performance.now()` from `node:perf_hooks` for benchmarking — never `Date.now()`, which has only millisecond resolution and is subject to clock drift
- Run at least 1,000-10,000 warmup iterations before measuring to ensure V8 has optimized the function with TurboFan — benchmarking cold/interpreted code produces misleading results
- Prevent dead code elimination by accumulating and referencing results (the sink pattern) — V8 will eliminate computations whose results are never used
- Report median alongside mean, and compute coefficient of variation (CoV) — if CoV exceeds 5-10%, your results are too noisy and you need more iterations or GC mitigation
- A performance difference is only real if it is statistically significant — run enough iterations and apply a t-test before claiming one approach is faster than another

## Next

With profiling skills and benchmarking rigor established, the final lesson in this track covers the optimization patterns that actually matter in Node.js — from stream versus buffer trade-offs to object pooling, hidden class stability, and worker thread offloading.
