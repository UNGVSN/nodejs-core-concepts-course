# Track 01 / Lesson 03 — CPU Profiling & Flame Graphs

> A slow endpoint is not always doing too much I/O. Sometimes it is burning CPU cycles inside a function you would never suspect — a regex that backtracks exponentially, a JSON serialization that runs 10,000 times per request, a sorting algorithm on an array that grew from 50 items to 50,000. CPU profiling and flame graphs show you exactly where the time goes, function by function, line by line.

## Learning Objectives

- Generate V8 CPU profiles using `--prof` and process them with `--prof-process` to identify hot functions
- Use `--cpu-prof` to produce `.cpuprofile` files compatible with Chrome DevTools
- Read flame graphs and identify performance bottlenecks by their visual width
- Use the `node:inspector` module to start and stop CPU profiling programmatically
- Recognize V8 deoptimization markers and understand how they affect performance

---

## V8's --prof Flag: Tick-Based Profiling

The `--prof` flag enables V8's built-in statistical profiler, which samples the call stack at regular intervals (ticks) and records which function was executing at each sample. More samples on a function means more CPU time spent there.

```javascript
'use strict';

// Save as cpu-intensive.js
// Run with: node --prof cpu-intensive.js
// This produces a file like isolate-0x...-v8.log

const { createHash } = require('node:crypto');

function hashData(data, algorithm) {
  return createHash(algorithm).update(data).digest('hex');
}

function processItems(items) {
  const results = [];
  for (const item of items) {
    // Hash each item — this is CPU-bound work
    const hash = hashData(JSON.stringify(item), 'sha256');
    results.push({ ...item, hash });
  }
  return results;
}

function sortResults(results) {
  // Sort by hash — string comparison on 64-char hex strings
  return results.sort((a, b) => a.hash.localeCompare(b.hash));
}

function generateItems(count) {
  const items = [];
  for (let i = 0; i < count; i++) {
    items.push({
      id: i,
      name: `Item ${i}`,
      value: Math.random() * 1000,
      tags: ['alpha', 'beta', 'gamma'].slice(0, (i % 3) + 1)
    });
  }
  return items;
}

// Main
console.time('total');

const items = generateItems(50000);
console.timeLog('total', '— generated items');

const processed = processItems(items);
console.timeLog('total', '— processed items');

const sorted = sortResults(processed);
console.timeLog('total', '— sorted results');

console.timeEnd('total');
console.log(`Processed ${sorted.length} items`);
```

After running with `--prof`, process the log file:

```bash
# Find the log file
# ls isolate-*.log

# Process it into a readable report
# node --prof-process isolate-0xNNNNNN-v8.log > profile.txt
```

The processed output shows a breakdown by function:

```
 [JavaScript]:
   ticks  total  nonlib   name
   1523   45.2%   52.3%  processItems cpu-intensive.js:10
    892   26.5%   30.6%  sortResults cpu-intensive.js:20
    312    9.3%   10.7%  generateItems cpu-intensive.js:25

 [C++]:
   ticks  total  nonlib   name
    198    5.9%          v8::internal::JsonStringify
     87    2.6%          node::crypto::Hash::HashUpdate

 [Summary]:
   ticks  total
   2727   81.0%  JavaScript
    285    8.5%  C++
    354   10.5%  GC
```

The highest-tick functions are your optimization targets. In this example, `processItems` at 45% and `sortResults` at 27% account for over 70% of CPU time.

---

## The --cpu-prof Flag: Chrome DevTools Format

The `--cpu-prof` flag produces `.cpuprofile` files that Chrome DevTools can load directly, giving you a visual flame chart.

```javascript
'use strict';

// Save as profile-target.js
// Run with: node --cpu-prof --cpu-prof-dir=./profiles profile-target.js
// This creates a .cpuprofile file in the ./profiles directory

const { createHash, randomBytes } = require('node:crypto');

// Deliberately varied workloads so the profile shows different weights

function heavyComputation(iterations) {
  let result = 0;
  for (let i = 0; i < iterations; i++) {
    result += Math.sqrt(i) * Math.sin(i);
  }
  return result;
}

function hashManyTimes(data, count) {
  let hash = data;
  for (let i = 0; i < count; i++) {
    hash = createHash('sha256').update(hash).digest('hex');
  }
  return hash;
}

function buildLargeObject(size) {
  const obj = {};
  for (let i = 0; i < size; i++) {
    obj[`key_${i}`] = {
      value: randomBytes(16).toString('hex'),
      nested: { level: i % 10, flag: i % 2 === 0 }
    };
  }
  return obj;
}

function serializeAndParse(obj) {
  const json = JSON.stringify(obj);
  return JSON.parse(json);
}

// Run the workloads
console.log('Starting CPU-intensive workloads...');

console.time('heavyComputation');
heavyComputation(5e6);
console.timeEnd('heavyComputation');

console.time('hashManyTimes');
hashManyTimes('seed-data', 10000);
console.timeEnd('hashManyTimes');

console.time('buildLargeObject');
const obj = buildLargeObject(20000);
console.timeEnd('buildLargeObject');

console.time('serializeAndParse');
for (let i = 0; i < 10; i++) {
  serializeAndParse(obj);
}
console.timeEnd('serializeAndParse');

console.log('Done. Load the .cpuprofile file in Chrome DevTools.');
```

To view the profile:
1. Open Chrome and navigate to `chrome://inspect`
2. Click "Open dedicated DevTools for Node"
3. Go to the "Performance" tab (or "Profiler" tab in older versions)
4. Click "Load" and select the `.cpuprofile` file
5. The flame chart shows function execution over time

---

## Reading Flame Graphs

A flame graph is a visualization where:

- The **x-axis** represents the proportion of total CPU time (wider = more time)
- The **y-axis** represents the call stack depth (taller = deeper call chain)
- Each **box** is a function call — its width is proportional to how much CPU time it consumed

```
┌─────────────────────────────────────────────────┐
│                   (root)                         │
├─────────────────────┬───────────────────────────┤
│   processItems      │     sortResults            │
│       45%           │         27%                 │
├──────────┬──────────┼───────────────────────────┤
│ hashData │ JSON.str │     localeCompare           │
│   30%    │   15%    │         27%                 │
├──────────┤          │                             │
│sha256.upd│          │                             │
│   25%    │          │                             │
└──────────┴──────────┴───────────────────────────┘
```

**How to read it:**

- **Wide boxes at the top** — High-level functions that account for a lot of total time (including their children)
- **Wide boxes at the bottom** — Leaf functions that are the actual CPU consumers
- **Narrow, tall stacks** — Deep call chains that execute quickly (not a problem)
- **Wide plateaus** — The function itself is the bottleneck, not its callees

**What to look for:**

1. The widest leaf functions — these are your hot spots
2. Unexpected functions that appear wide — why is `JSON.stringify` 15% of CPU?
3. Functions that appear many times across the x-axis — they are called from multiple code paths

---

## Programmatic CPU Profiling with node:inspector

For production systems, you want to start and stop profiling on demand — during a specific request, during high load, or when an anomaly is detected.

```javascript
'use strict';

const inspector = require('node:inspector');
const fs = require('node:fs');
const path = require('node:path');

class CPUProfiler {
  constructor() {
    this._session = new inspector.Session();
    this._session.connect();
  }

  start() {
    return new Promise((resolve, reject) => {
      this._session.post('Profiler.enable', (err) => {
        if (err) return reject(err);
        this._session.post('Profiler.start', (err) => {
          if (err) return reject(err);
          resolve();
        });
      });
    });
  }

  stop() {
    return new Promise((resolve, reject) => {
      this._session.post('Profiler.stop', (err, { profile }) => {
        if (err) return reject(err);
        resolve(profile);
      });
    });
  }

  async profileFunction(fn, outputPath) {
    await this.start();
    const startTime = Date.now();

    const result = fn();

    const elapsed = Date.now() - startTime;
    const profile = await this.stop();

    if (outputPath) {
      fs.writeFileSync(outputPath, JSON.stringify(profile));
      console.log(`Profile saved to ${outputPath} (${elapsed}ms)`);
    }

    return { result, profile, elapsed };
  }

  destroy() {
    this._session.disconnect();
  }
}

// Usage: Profile a specific function
async function main() {
  const profiler = new CPUProfiler();

  const { elapsed } = await profiler.profileFunction(() => {
    // The code you want to profile
    const data = [];
    for (let i = 0; i < 100000; i++) {
      data.push({
        id: i,
        hash: require('node:crypto')
          .createHash('md5')
          .update(String(i))
          .digest('hex')
      });
    }
    data.sort((a, b) => a.hash.localeCompare(b.hash));
    return data.length;
  }, 'my-profile.cpuprofile');

  console.log(`Function took ${elapsed}ms`);
  console.log('Load my-profile.cpuprofile in Chrome DevTools to analyze');

  profiler.destroy();
}

main().catch(console.error);
```

This approach lets you profile a specific code path without profiling the entire application lifecycle. It is especially useful for profiling individual HTTP request handlers or batch processing jobs.

---

## Using console.profile() and console.profileEnd()

When the process is started with `--inspect`, you can use the simpler `console.profile()` API to capture profiles directly in Chrome DevTools.

```javascript
'use strict';

// Run with: node --inspect profile-console.js
// Connect Chrome DevTools and check the "JavaScript Profiler" panel

const { createHash } = require('node:crypto');

function fibonacci(n) {
  if (n <= 1) return n;
  return fibonacci(n - 1) + fibonacci(n - 2);
}

function hashNTimes(input, n) {
  let result = input;
  for (let i = 0; i < n; i++) {
    result = createHash('sha256').update(result).digest('hex');
  }
  return result;
}

// Profile the fibonacci computation
console.profile('fibonacci');
const fibResult = fibonacci(40);
console.profileEnd('fibonacci');
console.log(`fibonacci(40) = ${fibResult}`);

// Profile the hash chain
console.profile('hash-chain');
const hashResult = hashNTimes('hello', 50000);
console.profileEnd('hash-chain');
console.log(`Hash chain result: ${hashResult.slice(0, 16)}...`);

// Profile both together for comparison
console.profile('combined');
fibonacci(38);
hashNTimes('world', 25000);
console.profileEnd('combined');

console.log('Profiles captured. Check Chrome DevTools.');
```

Each `console.profile()` / `console.profileEnd()` pair creates a named profile in the DevTools profiler panel, making it easy to compare different operations side by side.

---

## Deoptimization: When V8 Gives Up Optimizing

V8's TurboFan compiler optimizes "hot" functions based on type assumptions. When those assumptions are violated, V8 **deoptimizes** — it discards the optimized code and falls back to interpreted execution. Deoptimization is one of the most subtle performance killers.

```javascript
'use strict';

// Run with: node --trace-deopt deopt-demo.js
// V8 will print deoptimization events to stderr

// CASE 1: Monomorphic (fast) — one type always
function addMonomorphic(a, b) {
  return a + b;
}

// Always called with numbers — V8 optimizes for number addition
for (let i = 0; i < 100000; i++) {
  addMonomorphic(i, i + 1);
}
console.log('Monomorphic: optimized and stays optimized');

// CASE 2: Megamorphic (slow) — too many types
function addMegamorphic(a, b) {
  return a + b;
}

// Called with numbers, then strings, then mixed — V8 cannot specialize
for (let i = 0; i < 50000; i++) {
  addMegamorphic(i, i + 1);       // number + number
}
for (let i = 0; i < 50000; i++) {
  addMegamorphic(`a${i}`, `b${i}`); // string + string
}
addMegamorphic(42, 'hello');          // number + string — deopt!
console.log('Megamorphic: deoptimized due to type instability');

// CASE 3: Hidden class transitions
function Point(x, y) {
  this.x = x;
  this.y = y;
}

const points = [];

// All points have the same hidden class — fast property access
for (let i = 0; i < 10000; i++) {
  points.push(new Point(i, i * 2));
}

// Now add a property to some points — changes their hidden class
for (let i = 0; i < 100; i++) {
  points[i].z = i; // Different hidden class than the rest!
}

function sumX(pointArray) {
  let total = 0;
  for (const p of pointArray) {
    total += p.x; // V8 expected one hidden class, now sees two — deopt
  }
  return total;
}

// Hot loop to trigger optimization, then deopt on mixed hidden classes
for (let i = 0; i < 100; i++) {
  sumX(points);
}
console.log('Hidden class: deoptimized due to inconsistent object shapes');
```

**Deoptimization flags:**

| Flag | Purpose |
|------|---------|
| `--trace-deopt` | Log every deoptimization event |
| `--trace-opt` | Log every optimization decision |
| `--trace-turbo-inlining` | Log function inlining decisions |

---

## Inlining Decisions

V8's optimizer inlines small functions at their call sites, eliminating function call overhead. Understanding inlining helps you write code that V8 can optimize effectively.

```javascript
'use strict';

// Run with: node --trace-turbo-inlining inlining-demo.js

// Small function — likely to be inlined
function square(x) {
  return x * x;
}

// Larger function — less likely to be inlined
function complexCalculation(x) {
  let result = 0;
  for (let i = 0; i < 10; i++) {
    result += Math.sqrt(x + i) * Math.sin(x - i);
    result = Math.abs(result);
  }
  return result;
}

function processArray(arr) {
  let sum = 0;
  for (let i = 0; i < arr.length; i++) {
    // square() will likely be inlined here — no function call overhead
    sum += square(arr[i]);

    // complexCalculation() may not be inlined — too large
    // sum += complexCalculation(arr[i]);
  }
  return sum;
}

const data = Array.from({ length: 100000 }, (_, i) => i);

// Run enough times to trigger optimization
let result;
for (let i = 0; i < 100; i++) {
  result = processArray(data);
}

console.log(`Result: ${result}`);
console.log('Check stderr for inlining decisions');
```

**Inlining rules of thumb:**

- Functions under ~600 bytes of bytecode are candidates for inlining
- Recursive functions are not inlined
- Functions called from only one site are more likely to be inlined
- Getters and setters are aggressively inlined
- `try/catch` blocks historically prevented inlining in older V8 versions (no longer true in modern V8)

---

## A Practical Profiling Workflow

Putting it all together, here is a systematic approach to CPU profiling a Node.js application:

```javascript
'use strict';

// Step 1: Instrument suspected hot paths with timing
const { performance, PerformanceObserver } = require('node:perf_hooks');

// Set up observer to log performance entries
const obs = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    if (entry.duration > 10) { // Only log entries over 10ms
      console.log(`[SLOW] ${entry.name}: ${entry.duration.toFixed(2)}ms`);
    }
  }
});
obs.observe({ entryTypes: ['measure'] });

// Step 2: Wrap suspected functions with marks
function profiledOperation(name, fn) {
  performance.mark(`${name}-start`);
  const result = fn();
  performance.mark(`${name}-end`);
  performance.measure(name, `${name}-start`, `${name}-end`);
  return result;
}

// Step 3: Run your workload
const data = Array.from({ length: 50000 }, (_, i) => ({
  id: i,
  value: Math.random().toString(36)
}));

profiledOperation('sort', () => {
  data.sort((a, b) => a.value.localeCompare(b.value));
});

profiledOperation('serialize', () => {
  JSON.stringify(data);
});

profiledOperation('hash', () => {
  const { createHash } = require('node:crypto');
  return createHash('sha256')
    .update(JSON.stringify(data))
    .digest('hex');
});

// Step 4: If a slow operation is found, use --cpu-prof to get the full profile
// node --cpu-prof this-script.js

// Step 5: Load the .cpuprofile in Chrome DevTools and drill into the slow function

// Step 6: Check for deoptimizations
// node --trace-deopt this-script.js 2>&1 | grep "deopt"

setTimeout(() => {
  obs.disconnect();
  performance.clearMarks();
  performance.clearMeasures();
}, 1000);
```

**The workflow in summary:**

1. **Reproduce** — Trigger the slow behavior consistently
2. **Instrument** — Add `performance.mark()` / `performance.measure()` around suspected code
3. **Profile** — Run with `--cpu-prof` to capture a full profile
4. **Visualize** — Load the `.cpuprofile` in Chrome DevTools flame chart
5. **Identify** — Find the widest leaf functions in the flame graph
6. **Verify** — Check for deoptimizations with `--trace-deopt`
7. **Optimize** — Fix the bottleneck and re-profile to confirm improvement

---

## Key Takeaways

- V8's `--prof` flag produces tick-based profiles that show CPU time distribution across functions — process the log with `--prof-process` to get a human-readable report
- The `--cpu-prof` flag generates `.cpuprofile` files that Chrome DevTools can visualize as flame charts — wide boxes at the leaf level are your optimization targets
- Programmatic profiling via `node:inspector` lets you profile specific code paths on demand, which is more useful than profiling the entire process lifecycle
- Deoptimization (`--trace-deopt`) is a hidden performance killer — V8 falls back to slow interpreted execution when type assumptions are violated by megamorphic call sites or inconsistent object shapes
- The profiling workflow is: reproduce, instrument with `perf_hooks`, profile with `--cpu-prof`, visualize the flame graph, identify the widest leaf functions, check for deopts, optimize, and re-profile to confirm

## Next

Profiling tells you what is slow. The next lesson teaches you how to measure whether your fix actually made it faster — with statistically rigorous benchmarking methodology that accounts for JIT warmup, GC variance, and the many traps of micro-benchmarks.
