# Module 09 / Lesson 08 — Performance Profiling & Benchmarking

> You cannot optimize what you cannot measure. Gut feelings about performance are almost always wrong — the bottleneck is never where you think it is. This lesson gives you the tools to see exactly where your Node.js application spends its time and memory: V8's built-in profiler, heap snapshots, the `perf_hooks` instrumentation API, and a disciplined benchmarking methodology that produces numbers you can trust.

## Learning Objectives

- Use `performance.mark()` and `performance.measure()` with `PerformanceObserver` to instrument code without cluttering it with timing logic
- Generate and interpret V8 CPU profiles using the `--prof` flag and Chrome DevTools
- Capture and analyze heap snapshots with `v8.writeHeapSnapshot()` to identify memory leaks
- Build a benchmark harness that accounts for warm-up, statistical variance, and garbage collection
- Apply `process.memoryUsage()`, `process.cpuUsage()`, and `process.resourceUsage()` to monitor runtime resource consumption

---

## The `perf_hooks` Module: Precision Instrumentation

The `perf_hooks` module provides high-resolution timing APIs that go far beyond `Date.now()`.

### `performance.now()`

Returns a high-resolution timestamp in milliseconds with sub-millisecond precision. Unlike `Date.now()`, it is monotonic — it never jumps backward due to clock adjustments:

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

const start = performance.now();

// Simulate work
let sum = 0;
for (let i = 0; i < 10_000_000; i++) {
  sum += Math.sqrt(i);
}

const elapsed = performance.now() - start;
console.log(`Elapsed: ${elapsed.toFixed(4)} ms`);
console.log(`Result: ${sum}`);

// Compare with Date.now()
const dateStart = Date.now();
for (let i = 0; i < 10_000_000; i++) { sum += Math.sqrt(i); }
const dateElapsed = Date.now() - dateStart;
console.log(`Date.now() elapsed: ${dateElapsed} ms (integer milliseconds only)`);
```

`performance.now()` gives you microsecond-level resolution. `Date.now()` gives you only whole milliseconds and can be affected by system clock changes.

### Marks and Measures

Marks are named timestamps. Measures are the duration between two marks. This lets you instrument code without scattering timing variables everywhere:

```javascript
'use strict';

const { performance, PerformanceObserver } = require('node:perf_hooks');
const fs = require('node:fs');
const crypto = require('node:crypto');

// Set up an observer to receive measurements automatically
const obs = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    console.log(`[${entry.name}] ${entry.duration.toFixed(3)} ms`);
  }
});
obs.observe({ entryTypes: ['measure'] });

// --- Instrument multiple operations ---

performance.mark('read-start');
const data = fs.readFileSync(__filename, 'utf8');
performance.mark('read-end');
performance.measure('file-read', 'read-start', 'read-end');

performance.mark('hash-start');
const hash = crypto.createHash('sha256').update(data).digest('hex');
performance.mark('hash-end');
performance.measure('hash-compute', 'hash-start', 'hash-end');

performance.mark('json-start');
const obj = { data, hash, lines: data.split('\n').length };
const json = JSON.stringify(obj);
performance.mark('json-end');
performance.measure('json-stringify', 'json-start', 'json-end');

performance.mark('parse-start');
JSON.parse(json);
performance.mark('parse-end');
performance.measure('json-parse', 'parse-start', 'parse-end');

// Clean up
setTimeout(() => {
  obs.disconnect();
  performance.clearMarks();
  performance.clearMeasures();
}, 100);
```

The `PerformanceObserver` collects measurements asynchronously — your instrumented code stays clean, and measurements flow to a central handler.

### `performance.timerify()`

Wrap any function to automatically measure its execution time:

```javascript
'use strict';

const { performance, PerformanceObserver } = require('node:perf_hooks');
const crypto = require('node:crypto');

const obs = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    console.log(`${entry.name}: ${entry.duration.toFixed(3)} ms`);
  }
});
obs.observe({ entryTypes: ['function'] });

// Wrap a function — every call is automatically timed
function computeHash(input, algorithm) {
  return crypto.createHash(algorithm).update(input).digest('hex');
}

const timedHash = performance.timerify(computeHash);

// Each call generates a performance entry
const data = Buffer.alloc(1024 * 1024, 'x'); // 1 MB
timedHash(data, 'sha256');
timedHash(data, 'sha512');
timedHash(data, 'md5');

setTimeout(() => obs.disconnect(), 100);
```

---

## `console.time()` vs `performance.measure()`

Both measure durations, but they serve different purposes:

```javascript
'use strict';

const { performance, PerformanceObserver } = require('node:perf_hooks');

// console.time: quick-and-dirty, logs to stderr, no programmatic access
console.time('sort');
const arr1 = Array.from({ length: 1_000_000 }, () => Math.random());
arr1.sort();
console.timeEnd('sort');
// Output: sort: 234.567ms (printed to stderr)

// performance.measure: structured, observable, programmable
const obs = new PerformanceObserver((list) => {
  const entry = list.getEntries()[0];
  // You can send this to a monitoring system, aggregate stats, etc.
  console.log(`Measured ${entry.name}: ${entry.duration.toFixed(3)} ms`);
});
obs.observe({ entryTypes: ['measure'] });

performance.mark('sort-start');
const arr2 = Array.from({ length: 1_000_000 }, () => Math.random());
arr2.sort();
performance.mark('sort-end');
performance.measure('sort-measure', 'sort-start', 'sort-end');

setTimeout(() => obs.disconnect(), 100);
```

| Feature | `console.time` | `performance.measure` |
|---------|---------------|----------------------|
| Output | Prints to stderr | Emits to `PerformanceObserver` |
| Programmatic access | No | Yes — `entry.duration`, `entry.name` |
| Nesting | Names must be unique | Marks can be reused |
| Production use | Debugging only | Monitoring, metrics export |
| Precision | Millisecond | Sub-millisecond |

Use `console.time` for quick debugging. Use `performance.measure` for anything you want to aggregate, alert on, or export to a monitoring system.

---

## CPU Profiling with `--prof`

V8 has a built-in sampling CPU profiler. The `--prof` flag tells V8 to write a profiling log as the program runs:

```javascript
'use strict';

// cpu-intensive.js — a program worth profiling
const crypto = require('node:crypto');

function hashMany(iterations) {
  const results = [];
  for (let i = 0; i < iterations; i++) {
    results.push(
      crypto.createHash('sha256')
        .update(`data-${i}`)
        .digest('hex')
    );
  }
  return results.length;
}

function fibonacci(n) {
  if (n <= 1) return n;
  return fibonacci(n - 1) + fibonacci(n - 2);
}

function sortLargeArray(size) {
  const arr = Array.from({ length: size }, () => Math.random());
  arr.sort((a, b) => a - b);
  return arr.length;
}

console.log('Starting profiled workload...');
const start = Date.now();

hashMany(50_000);
fibonacci(40);
sortLargeArray(500_000);

console.log(`Done in ${Date.now() - start} ms`);
```

Run it with profiling enabled:

```bash
# Step 1: Generate the V8 log
node --prof cpu-intensive.js
# Produces: isolate-0x...-v8.log

# Step 2: Process the log into human-readable output
node --prof-process isolate-0x*-v8.log > profile.txt

# Step 3: Read the processed output
cat profile.txt
```

The output shows a breakdown by function:

```
 [Summary]:
   ticks  total  nonlib   name
    523   52.3%   55.1%  JavaScript
    389   38.9%   41.0%  C++
     37    3.7%    3.9%  GC
     51    5.1%          Shared libraries

 [JavaScript]:
   ticks  total  nonlib   name
    201   20.1%   21.2%  fibonacci
    183   18.3%   19.3%  hashMany
    139   13.9%   14.6%  sortLargeArray
```

This tells you exactly which functions consume the most CPU. In this example, `fibonacci` dominates — it is the first optimization target.

---

## Chrome DevTools Profiling with `--inspect`

For visual profiling with flame charts, use the `--inspect` or `--inspect-brk` flag:

```bash
# Start with debugger attached (pauses on first line)
node --inspect-brk cpu-intensive.js
```

Then open Chrome and navigate to `chrome://inspect`. Click "Inspect" on your Node.js process. In DevTools:

1. Go to the **Performance** tab
2. Click **Record**
3. Resume execution (the script was paused at the first line)
4. When the script finishes, click **Stop**
5. Analyze the flame chart

The flame chart shows call stacks over time. Wide bars are expensive functions. Tall stacks indicate deep recursion. Look for:

- **Wide, flat bars:** Functions that take a long time per call
- **Tall, narrow towers:** Deep recursion (like `fibonacci`)
- **Repeating patterns:** Hot loops worth optimizing

You can also profile from code without Chrome by using `inspector`:

```javascript
'use strict';

const inspector = require('node:inspector');
const fs = require('node:fs');

const session = new inspector.Session();
session.connect();

// Start CPU profiling
session.post('Profiler.enable', () => {
  session.post('Profiler.start', () => {
    // Run the workload
    let sum = 0;
    for (let i = 0; i < 10_000_000; i++) {
      sum += Math.sqrt(i);
    }

    // Stop profiling and save
    session.post('Profiler.stop', (err, { profile }) => {
      if (err) throw err;

      const filename = `cpu-profile-${Date.now()}.cpuprofile`;
      fs.writeFileSync(filename, JSON.stringify(profile));
      console.log(`Profile saved to ${filename}`);
      console.log('Open in Chrome DevTools → Performance → Load profile');

      session.disconnect();
    });
  });
});
```

The `.cpuprofile` file can be loaded into Chrome DevTools for visualization.

---

## Heap Snapshots: Finding Memory Leaks

The `v8` module lets you capture heap snapshots at runtime:

```javascript
'use strict';

const v8 = require('node:v8');
const path = require('node:path');

// Take a snapshot of the current heap
function takeSnapshot(label) {
  const filename = v8.writeHeapSnapshot();
  console.log(`[${label}] Heap snapshot written to: ${filename}`);
  return filename;
}

// Simulate a memory leak
const leakedData = [];

takeSnapshot('baseline');

// Phase 1: Allocate data that is never freed
for (let i = 0; i < 10_000; i++) {
  leakedData.push({
    id: i,
    data: Buffer.alloc(1024).toString('hex'), // 2 KB string per entry
    timestamp: Date.now(),
  });
}

takeSnapshot('after-leak');

console.log(`Leaked array size: ${leakedData.length} entries`);
console.log(`Approximate leak: ${(leakedData.length * 2 / 1024).toFixed(1)} MB`);
console.log('');
console.log('To analyze:');
console.log('1. Open Chrome DevTools → Memory tab');
console.log('2. Load both .heapsnapshot files');
console.log('3. Switch to "Comparison" view');
console.log('4. Sort by "Size Delta" to find growing objects');
```

The `.heapsnapshot` files can be loaded into Chrome DevTools Memory tab. Use the "Comparison" view to see what grew between snapshots.

### Programmatic Heap Analysis

You can also inspect heap statistics without full snapshots:

```javascript
'use strict';

const v8 = require('node:v8');

function printHeapStats() {
  const stats = v8.getHeapStatistics();
  console.log('--- V8 Heap Statistics ---');
  console.log(`  Total heap size:      ${(stats.total_heap_size / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  Used heap size:       ${(stats.used_heap_size / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  Heap size limit:      ${(stats.heap_size_limit / 1024 / 1024).toFixed(0)} MB`);
  console.log(`  Malloced memory:      ${(stats.malloced_memory / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  External memory:      ${(stats.external_memory / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  Peak malloced memory: ${(stats.peak_malloced_memory / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  Number of contexts:   ${stats.number_of_native_contexts}`);
  console.log(`  Number of detached:   ${stats.number_of_detached_contexts}`);
}

// Heap space details
function printHeapSpaces() {
  const spaces = v8.getHeapSpaceStatistics();
  console.log('\n--- Heap Spaces ---');
  for (const space of spaces) {
    if (space.space_used_size > 0) {
      console.log(`  ${space.space_name.padEnd(22)} ` +
        `used: ${(space.space_used_size / 1024 / 1024).toFixed(1).padStart(6)} MB, ` +
        `total: ${(space.space_size / 1024 / 1024).toFixed(1).padStart(6)} MB`);
    }
  }
}

printHeapStats();
printHeapSpaces();
```

---

## `process.memoryUsage()`: Runtime Memory Monitoring

```javascript
'use strict';

function printMemory(label) {
  const usage = process.memoryUsage();
  console.log(`[${label}]`);
  console.log(`  rss:          ${(usage.rss / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  heapTotal:    ${(usage.heapTotal / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  heapUsed:     ${(usage.heapUsed / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  external:     ${(usage.external / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  arrayBuffers: ${(usage.arrayBuffers / 1024 / 1024).toFixed(1)} MB`);
  console.log();
}

printMemory('baseline');

// Allocate heap memory (JavaScript objects)
const objects = [];
for (let i = 0; i < 100_000; i++) {
  objects.push({ id: i, name: `item-${i}`, value: Math.random() });
}
printMemory('after 100K objects');

// Allocate external memory (Buffers)
const buffers = [];
for (let i = 0; i < 100; i++) {
  buffers.push(Buffer.alloc(1024 * 1024)); // 1 MB each
}
printMemory('after 100 MB of Buffers');

// Allocate SharedArrayBuffer (shows in arrayBuffers)
const sharedBufs = [];
for (let i = 0; i < 50; i++) {
  sharedBufs.push(new SharedArrayBuffer(1024 * 1024)); // 1 MB each
}
printMemory('after 50 MB of SharedArrayBuffers');
```

The fields explained:

| Field | What It Measures |
|-------|-----------------|
| `rss` | Resident Set Size — total memory allocated by the OS for this process |
| `heapTotal` | V8's total heap — space reserved for JavaScript objects |
| `heapUsed` | Portion of the heap actually occupied by live objects |
| `external` | Memory for C++ objects bound to JavaScript (Buffers, etc.) |
| `arrayBuffers` | Memory for `ArrayBuffer` and `SharedArrayBuffer` (subset of `external`) |

---

## `process.cpuUsage()` and `process.resourceUsage()`

### CPU Usage

```javascript
'use strict';

function measureCpuUsage(fn) {
  const startCpu = process.cpuUsage();
  fn();
  const endCpu = process.cpuUsage(startCpu);

  console.log(`  user:   ${(endCpu.user / 1000).toFixed(1)} ms`);
  console.log(`  system: ${(endCpu.system / 1000).toFixed(1)} ms`);
  console.log(`  total:  ${((endCpu.user + endCpu.system) / 1000).toFixed(1)} ms`);
}

console.log('CPU-bound work (math):');
measureCpuUsage(() => {
  let sum = 0;
  for (let i = 0; i < 50_000_000; i++) sum += Math.sqrt(i);
});

console.log('\nI/O-bound work (sync file read):');
const fs = require('node:fs');
measureCpuUsage(() => {
  for (let i = 0; i < 1000; i++) {
    fs.readFileSync(__filename);
  }
});
```

CPU-bound work shows high `user` time and low `system` time. I/O-bound work shows higher `system` time (kernel handles the I/O). The values are in microseconds.

### Resource Usage

`process.resourceUsage()` provides detailed resource consumption from the operating system:

```javascript
'use strict';

function printResourceUsage() {
  const r = process.resourceUsage();
  console.log('--- Resource Usage ---');
  console.log(`  User CPU time:         ${(r.userCPUTime / 1000).toFixed(1)} ms`);
  console.log(`  System CPU time:       ${(r.systemCPUTime / 1000).toFixed(1)} ms`);
  console.log(`  Max RSS:               ${(r.maxRSS / 1024).toFixed(1)} MB`);
  console.log(`  Shared memory size:    ${r.sharedMemorySize} KB`);
  console.log(`  Unshared data size:    ${r.unsharedDataSize} KB`);
  console.log(`  Unshared stack size:   ${r.unsharedStackSize} KB`);
  console.log(`  Minor page faults:     ${r.minorPageFault}`);
  console.log(`  Major page faults:     ${r.majorPageFault}`);
  console.log(`  FS reads:              ${r.fsRead}`);
  console.log(`  FS writes:             ${r.fsWrite}`);
  console.log(`  IPC messages sent:     ${r.ipcSent}`);
  console.log(`  IPC messages received: ${r.ipcReceived}`);
  console.log(`  Signals received:      ${r.signalsCount}`);
  console.log(`  Vol. context switches: ${r.voluntaryContextSwitches}`);
  console.log(`  Invol. context switches: ${r.involuntaryContextSwitches}`);
}

// Do some work first
const fs = require('node:fs');
for (let i = 0; i < 100; i++) {
  fs.readFileSync(__filename);
}

let sum = 0;
for (let i = 0; i < 10_000_000; i++) sum += Math.sqrt(i);

printResourceUsage();
```

Key metrics:

- **`maxRSS`**: Peak memory usage — useful for capacity planning
- **`fsRead`/`fsWrite`**: Total file system operations — a proxy for I/O activity
- **`voluntaryContextSwitches`**: Times the process yielded the CPU (waiting for I/O)
- **`involuntaryContextSwitches`**: Times the OS preempted the process (CPU contention)

---

## GC Tracing

Garbage collection pauses can cause latency spikes. V8 provides flags to observe GC activity:

```bash
# Trace every GC event
node --trace-gc gc-test.js

# Output includes:
# [4321:0x5578a40]    48 ms: Scavenge 2.1 (3.3) -> 1.8 (4.3) MB, 1.2 / 0.0 ms ...
# [4321:0x5578a40]   192 ms: Mark-Sweep 4.2 (5.3) -> 2.1 (5.3) MB, 3.4 / 0.0 ms ...
```

You can also trigger GC manually for benchmarking (requires `--expose-gc`):

```javascript
'use strict';

// Run with: node --expose-gc gc-benchmark.js
const { performance } = require('node:perf_hooks');

if (typeof global.gc !== 'function') {
  console.error('Run with --expose-gc flag: node --expose-gc gc-benchmark.js');
  process.exit(1);
}

function measureGC() {
  // Create garbage
  const garbage = [];
  for (let i = 0; i < 1_000_000; i++) {
    garbage.push({ id: i, data: `item-${i}` });
  }

  // Clear references — objects become eligible for collection
  garbage.length = 0;

  // Force GC and measure how long it takes
  const before = process.memoryUsage().heapUsed;
  const start = performance.now();
  global.gc();
  const elapsed = performance.now() - start;
  const after = process.memoryUsage().heapUsed;

  console.log(`GC took ${elapsed.toFixed(2)} ms`);
  console.log(`Freed ${((before - after) / 1024 / 1024).toFixed(1)} MB`);
  console.log(`Heap used: ${(after / 1024 / 1024).toFixed(1)} MB`);
}

console.log('--- GC Measurement ---');
measureGC();
console.log();
measureGC();
console.log();
measureGC();
```

### Observing GC Programmatically

```javascript
'use strict';

const { PerformanceObserver } = require('node:perf_hooks');

// Observe GC events
const gcObs = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    const kind = entry.detail?.kind || entry.kind;
    // kind: 1=Scavenge (young gen), 2=Mark-Sweep (old gen),
    //       4=Incremental, 8=Weak processing, 15=All
    const kindName = {
      1: 'Scavenge',
      2: 'Mark-Sweep',
      4: 'Incremental',
      8: 'Weak',
      15: 'All',
    }[kind] || `kind-${kind}`;

    console.log(`[GC] ${kindName.padEnd(12)} ${entry.duration.toFixed(2)} ms`);
  }
});
gcObs.observe({ entryTypes: ['gc'] });

// Generate GC pressure
function generateGarbage() {
  const data = [];
  for (let i = 0; i < 500_000; i++) {
    data.push({ x: Math.random(), y: Math.random(), label: `p${i}` });
  }
  return data.length;
}

setInterval(() => {
  generateGarbage();
}, 500);

setTimeout(() => {
  gcObs.disconnect();
  console.log('Done observing GC');
  process.exit(0);
}, 5000);
```

---

## Benchmarking Methodology

Microbenchmarks are notoriously misleading. Here are the rules for benchmarks you can trust.

### Rule 1: Warm Up the JIT

V8 compiles JavaScript in stages: first to bytecode (Ignition), then to optimized machine code (TurboFan). The first few runs of a function are slower than steady-state:

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

function targetFunction(n) {
  let sum = 0;
  for (let i = 0; i < n; i++) {
    sum += Math.sin(i) * Math.cos(i);
  }
  return sum;
}

const N = 100_000;
const WARMUP = 5;
const RUNS = 50;

// Warm up — V8 optimizes the function
for (let i = 0; i < WARMUP; i++) {
  targetFunction(N);
}

// Measure steady-state performance
const times = [];
for (let i = 0; i < RUNS; i++) {
  const start = performance.now();
  targetFunction(N);
  times.push(performance.now() - start);
}

// Compare first run (potentially unoptimized) to steady state
console.log(`First measured run:  ${times[0].toFixed(3)} ms`);
console.log(`Last measured run:   ${times[times.length - 1].toFixed(3)} ms`);
console.log(`Mean (all runs):     ${(times.reduce((a, b) => a + b) / times.length).toFixed(3)} ms`);
```

### Rule 2: Report Statistical Measures

A single timing is meaningless. Report mean, median, standard deviation, and percentiles:

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

function computeStats(times) {
  const sorted = [...times].sort((a, b) => a - b);
  const n = sorted.length;
  const sum = sorted.reduce((a, b) => a + b, 0);
  const mean = sum / n;
  const median = n % 2 === 0
    ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    : sorted[Math.floor(n / 2)];
  const variance = sorted.reduce((acc, t) => acc + (t - mean) ** 2, 0) / n;
  const stddev = Math.sqrt(variance);

  return {
    mean,
    median,
    stddev,
    min: sorted[0],
    max: sorted[n - 1],
    p5: sorted[Math.floor(n * 0.05)],
    p95: sorted[Math.floor(n * 0.95)],
    p99: sorted[Math.floor(n * 0.99)],
    cv: (stddev / mean * 100), // Coefficient of variation (%)
  };
}

function printStats(label, stats) {
  console.log(`--- ${label} ---`);
  console.log(`  Mean:   ${stats.mean.toFixed(3)} ms`);
  console.log(`  Median: ${stats.median.toFixed(3)} ms`);
  console.log(`  StdDev: ${stats.stddev.toFixed(3)} ms (CV: ${stats.cv.toFixed(1)}%)`);
  console.log(`  Min:    ${stats.min.toFixed(3)} ms`);
  console.log(`  Max:    ${stats.max.toFixed(3)} ms`);
  console.log(`  P5:     ${stats.p5.toFixed(3)} ms`);
  console.log(`  P95:    ${stats.p95.toFixed(3)} ms`);
  console.log(`  P99:    ${stats.p99.toFixed(3)} ms`);
  console.log();
}

// Benchmark two approaches
function approach1(data) {
  return data.filter((x) => x > 0.5).map((x) => x * 2);
}

function approach2(data) {
  const result = [];
  for (let i = 0; i < data.length; i++) {
    if (data[i] > 0.5) result.push(data[i] * 2);
  }
  return result;
}

const data = Array.from({ length: 1_000_000 }, () => Math.random());
const WARMUP = 5;
const RUNS = 100;

// Warm up both
for (let i = 0; i < WARMUP; i++) { approach1(data); approach2(data); }

const times1 = [];
const times2 = [];

for (let i = 0; i < RUNS; i++) {
  let start = performance.now();
  approach1(data);
  times1.push(performance.now() - start);

  start = performance.now();
  approach2(data);
  times2.push(performance.now() - start);
}

printStats('filter+map', computeStats(times1));
printStats('for loop', computeStats(times2));
```

If the coefficient of variation (CV) exceeds 10%, your measurements are noisy. Run more iterations or eliminate confounding factors.

### Rule 3: Prevent Dead Code Elimination

V8 may optimize away code whose result is never used:

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// BAD: V8 might eliminate this computation entirely
function badBenchmark() {
  const start = performance.now();
  let result = 0;
  for (let i = 0; i < 10_000_000; i++) {
    result += Math.sqrt(i);
  }
  return performance.now() - start;
  // `result` is computed but never observed — V8 may skip it
}

// GOOD: Use the result — V8 cannot eliminate it
function goodBenchmark() {
  const start = performance.now();
  let result = 0;
  for (let i = 0; i < 10_000_000; i++) {
    result += Math.sqrt(i);
  }
  const elapsed = performance.now() - start;
  if (result < 0) console.log('impossible'); // Forces V8 to keep the computation
  return elapsed;
}

console.log(`Bad benchmark:  ${badBenchmark().toFixed(3)} ms`);
console.log(`Good benchmark: ${goodBenchmark().toFixed(3)} ms`);
```

### Rule 4: Control for Garbage Collection

GC pauses during a benchmark corrupt your measurements. Force GC between runs:

```javascript
'use strict';

// Run with: node --expose-gc gc-aware-benchmark.js
const { performance } = require('node:perf_hooks');

if (typeof global.gc !== 'function') {
  console.error('Run with: node --expose-gc gc-aware-benchmark.js');
  process.exit(1);
}

function benchmark(label, fn, runs = 50) {
  // Warm up
  for (let i = 0; i < 5; i++) fn();

  const times = [];
  for (let i = 0; i < runs; i++) {
    global.gc(); // Force GC before each run — clean slate
    const start = performance.now();
    fn();
    times.push(performance.now() - start);
  }

  const sorted = [...times].sort((a, b) => a - b);
  const mean = sorted.reduce((a, b) => a + b) / sorted.length;
  const median = sorted[Math.floor(sorted.length / 2)];

  console.log(`[${label}] mean: ${mean.toFixed(3)} ms, median: ${median.toFixed(3)} ms, ` +
    `min: ${sorted[0].toFixed(3)} ms, max: ${sorted[sorted.length - 1].toFixed(3)} ms`);
}

// Compare string concatenation approaches
const iterations = 100_000;

benchmark('+ operator', () => {
  let s = '';
  for (let i = 0; i < iterations; i++) s += 'x';
  return s;
});

benchmark('Array.join', () => {
  const parts = [];
  for (let i = 0; i < iterations; i++) parts.push('x');
  return parts.join('');
});

benchmark('Buffer.concat', () => {
  const bufs = [];
  for (let i = 0; i < iterations; i++) bufs.push(Buffer.from('x'));
  return Buffer.concat(bufs).toString();
});
```

---

## Building a Complete Benchmark Harness

Here is a reusable benchmark harness that follows all the rules:

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

class BenchmarkSuite {
  #benchmarks = [];
  #warmupRuns;
  #measuredRuns;

  constructor(options = {}) {
    this.#warmupRuns = options.warmupRuns || 10;
    this.#measuredRuns = options.measuredRuns || 100;
  }

  add(name, fn) {
    this.#benchmarks.push({ name, fn });
    return this; // chainable
  }

  run() {
    const canGC = typeof global.gc === 'function';
    if (!canGC) {
      console.warn('Warning: --expose-gc not set. GC noise may affect results.\n');
    }

    console.log(`Benchmarking: ${this.#warmupRuns} warmup, ${this.#measuredRuns} measured runs`);
    if (canGC) console.log('GC: forced between runs\n');
    console.log('='.repeat(80));

    const results = [];

    for (const bench of this.#benchmarks) {
      // Warm up
      for (let i = 0; i < this.#warmupRuns; i++) bench.fn();

      // Measure
      const times = [];
      for (let i = 0; i < this.#measuredRuns; i++) {
        if (canGC) global.gc();

        const start = performance.now();
        bench.fn();
        times.push(performance.now() - start);
      }

      const stats = this.#computeStats(times);
      results.push({ name: bench.name, stats });

      console.log(`${bench.name}`);
      console.log(`  Mean:   ${stats.mean.toFixed(4)} ms  (+/- ${stats.stddev.toFixed(4)} ms)`);
      console.log(`  Median: ${stats.median.toFixed(4)} ms`);
      console.log(`  Range:  [${stats.min.toFixed(4)}, ${stats.max.toFixed(4)}] ms`);
      console.log(`  P95:    ${stats.p95.toFixed(4)} ms`);
      console.log(`  CV:     ${stats.cv.toFixed(1)}%`);
      console.log('-'.repeat(80));
    }

    // Relative comparison
    if (results.length > 1) {
      console.log('\n--- Relative Performance ---');
      const baseline = results[0].stats.mean;
      for (const r of results) {
        const ratio = r.stats.mean / baseline;
        const bar = '#'.repeat(Math.round(ratio * 20));
        console.log(`  ${r.name.padEnd(25)} ${ratio.toFixed(2)}x  ${bar}`);
      }
    }
  }

  #computeStats(times) {
    const sorted = [...times].sort((a, b) => a - b);
    const n = sorted.length;
    const sum = sorted.reduce((a, b) => a + b, 0);
    const mean = sum / n;
    const variance = sorted.reduce((acc, t) => acc + (t - mean) ** 2, 0) / n;
    const stddev = Math.sqrt(variance);

    return {
      mean,
      median: sorted[Math.floor(n / 2)],
      stddev,
      min: sorted[0],
      max: sorted[n - 1],
      p5: sorted[Math.floor(n * 0.05)],
      p95: sorted[Math.floor(n * 0.95)],
      p99: sorted[Math.floor(n * 0.99)],
      cv: (stddev / mean) * 100,
    };
  }
}

// Usage
const suite = new BenchmarkSuite({ warmupRuns: 5, measuredRuns: 50 });

const data = Array.from({ length: 100_000 }, (_, i) => ({
  id: i,
  value: Math.random(),
  name: `item-${i}`,
}));

suite
  .add('JSON.stringify', () => {
    const json = JSON.stringify(data);
    if (json.length < 0) throw new Error(); // prevent DCE
  })
  .add('JSON.parse (from string)', () => {
    const json = JSON.stringify(data);
    const parsed = JSON.parse(json);
    if (parsed.length < 0) throw new Error();
  })
  .add('structuredClone', () => {
    const cloned = structuredClone(data);
    if (cloned.length < 0) throw new Error();
  })
  .run();
```

---

## The `--max-old-space-size` Flag

By default, V8 limits the old generation heap to about 1.5 GB on 64-bit systems. For memory-intensive workloads, you may need to increase it:

```bash
# Default: ~1.5 GB heap limit
node app.js

# Increase to 4 GB
node --max-old-space-size=4096 app.js

# Increase to 8 GB
node --max-old-space-size=8192 app.js
```

You can check the current limit programmatically:

```javascript
'use strict';

const v8 = require('node:v8');

const stats = v8.getHeapStatistics();
console.log(`Heap size limit: ${(stats.heap_size_limit / 1024 / 1024).toFixed(0)} MB`);

// If you hit this limit, V8 throws:
// FATAL ERROR: CALL_AND_RETRY_LAST Allocation failed - JavaScript heap out of memory
```

Do not reflexively increase this. A growing heap usually indicates a memory leak. Fix the leak first; raise the limit only when the working set genuinely requires more memory.

---

## Common Performance Antipatterns

### 1. Creating Closures in Hot Loops

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

const data = Array.from({ length: 1_000_000 }, (_, i) => i);

// BAD: creates a new closure every iteration
function closureInLoop(arr) {
  return arr.filter((x) => x % 2 === 0);
  // The arrow function is recreated on every .filter() call
  // For a top-level call this is fine, but inside a tight loop it adds up
}

// GOOD: define the predicate once
const isEven = (x) => x % 2 === 0;
function reuseFunction(arr) {
  return arr.filter(isEven);
}

// Benchmark
for (let i = 0; i < 5; i++) { closureInLoop(data); reuseFunction(data); }

let start = performance.now();
for (let i = 0; i < 10; i++) closureInLoop(data);
console.log(`Inline closure: ${(performance.now() - start).toFixed(2)} ms`);

start = performance.now();
for (let i = 0; i < 10; i++) reuseFunction(data);
console.log(`Reused function: ${(performance.now() - start).toFixed(2)} ms`);
```

### 2. Unnecessary Buffer Allocations

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// BAD: allocates a new Buffer for every small piece of data
function badBufferUsage(iterations) {
  const results = [];
  for (let i = 0; i < iterations; i++) {
    const buf = Buffer.from(`data-${i}`);
    results.push(buf.toString('hex'));
  }
  return results.length;
}

// GOOD: reuse a single Buffer when possible
function goodBufferUsage(iterations) {
  const buf = Buffer.alloc(256);
  const results = [];
  for (let i = 0; i < iterations; i++) {
    const str = `data-${i}`;
    buf.write(str);
    results.push(buf.subarray(0, Buffer.byteLength(str)).toString('hex'));
  }
  return results.length;
}

const N = 100_000;
for (let i = 0; i < 3; i++) { badBufferUsage(N); goodBufferUsage(N); }

let start = performance.now();
badBufferUsage(N);
console.log(`New Buffer each time: ${(performance.now() - start).toFixed(2)} ms`);

start = performance.now();
goodBufferUsage(N);
console.log(`Reused Buffer:        ${(performance.now() - start).toFixed(2)} ms`);
```

### 3. Synchronous I/O in Request Handlers

```javascript
'use strict';

const http = require('node:http');
const fs = require('node:fs');

// BAD: blocks the event loop for every request
http.createServer((req, res) => {
  // Every concurrent request waits while this one reads
  const data = fs.readFileSync('/some/large/file.json', 'utf8');
  res.end(data);
});

// GOOD: non-blocking — the event loop stays free
http.createServer(async (req, res) => {
  try {
    const data = await fs.promises.readFile('/some/large/file.json', 'utf8');
    res.end(data);
  } catch (err) {
    res.statusCode = 500;
    res.end('Internal error');
  }
});
```

This is the most common performance mistake in Node.js. The `*Sync` methods are acceptable at startup but never in request paths.

---

## Profiling Checklist

When investigating a performance problem, follow this order:

1. **Measure event loop lag** — Is the main thread blocked? (`monitorEventLoopDelay`)
2. **Check memory** — Is the process leaking? (`process.memoryUsage()` over time)
3. **CPU profile** — Where is the CPU time going? (`--prof` or `--inspect`)
4. **Heap snapshot** — What objects are accumulating? (`v8.writeHeapSnapshot()`)
5. **GC trace** — Are GC pauses causing latency spikes? (`--trace-gc` or GC observer)
6. **Resource usage** — Are we hitting OS limits? (`process.resourceUsage()`)
7. **Benchmark** — Is the proposed fix actually faster? (controlled benchmark with statistical rigor)

Never skip step 1. The event loop lag tells you immediately whether the problem is CPU-bound (high lag) or I/O-bound (low lag but slow responses).

---

## Key Takeaways

- `performance.mark()` and `performance.measure()` with `PerformanceObserver` provide structured, programmatic instrumentation — use them for production monitoring instead of `console.time()`
- V8's `--prof` flag generates CPU profiles that show exactly which functions consume the most time — always profile before optimizing, because the bottleneck is rarely where you expect
- Heap snapshots (`v8.writeHeapSnapshot()`) combined with Chrome DevTools comparison view reveal memory leaks by showing which object types grew between snapshots
- Reliable benchmarks require warm-up runs (so V8's JIT optimizer reaches steady state), statistical analysis (mean, median, standard deviation, percentiles), and GC control (`--expose-gc` with `global.gc()` between runs)
- `process.memoryUsage()`, `process.cpuUsage()`, and `process.resourceUsage()` give you runtime visibility into memory, CPU, and OS-level resource consumption without any external tools

## Next

This concludes Module 09. Continue to [Module 10 — Cryptography, Compression & Security](../module-10-crypto-compression-security/lesson-01-crypto-fundamentals.md), where we explore Node.js's built-in `crypto` and `zlib` modules for hashing, encryption, digital signatures, and data compression.
