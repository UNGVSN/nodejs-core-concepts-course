# Module 09 / Lesson 07 — Event Loop Optimization

> The event loop is the heartbeat of every Node.js process. When it runs smoothly, your server handles thousands of concurrent connections without breaking a sweat. When it stalls — even for 50 milliseconds — every client in the queue feels the delay. This lesson teaches you how to measure event loop health, identify what is blocking it, and apply targeted strategies to keep the main thread responsive.

## Learning Objectives

- Measure event loop lag using both manual techniques and the built-in `monitorEventLoopDelay()` API
- Explain how `UV_THREADPOOL_SIZE` affects I/O throughput and determine when to increase it
- Identify the most common sources of event loop blocking: synchronous I/O, large JSON operations, and RegExp backtracking
- Apply offloading strategies including worker threads, `setImmediate()` yielding, and chunked processing
- Distinguish between `process.nextTick()` and `setImmediate()` and understand the starvation risks of each

---

## The Event Loop Is the Bottleneck

Node.js runs your JavaScript on a single thread. Every callback — HTTP requests, timers, file system results, DNS lookups — funnels through one event loop. If any single callback takes 100 ms to execute, every other callback waits 100 ms.

Here is the problem, made visible:

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  if (req.url === '/fast') {
    res.end('Fast response\n');
    return;
  }

  if (req.url === '/slow') {
    // Simulate a CPU-bound operation that blocks for 2 seconds
    const start = Date.now();
    while (Date.now() - start < 2000) {
      // Burn CPU — nothing else can run
    }
    res.end('Slow response\n');
    return;
  }

  res.statusCode = 404;
  res.end('Not found\n');
});

server.listen(3000, () => {
  console.log('Server on http://localhost:3000');
  console.log('Try: curl http://localhost:3000/fast');
  console.log('Then in another terminal: curl http://localhost:3000/slow');
  console.log('Then immediately: curl http://localhost:3000/fast');
  console.log('The second /fast request waits until /slow finishes.');
});
```

One slow request blocks the entire server. Every other request — no matter how trivial — stalls until the blocking callback returns. This is why event loop optimization matters more in Node.js than in thread-per-request architectures.

---

## Measuring Event Loop Lag: The Manual Approach

The simplest way to detect event loop blocking is to schedule a timer and measure how late it fires. A `setTimeout(fn, 0)` should fire in about 1 ms. If it fires in 200 ms, the event loop was blocked for roughly 199 ms:

```javascript
'use strict';

function measureLag() {
  const start = process.hrtime.bigint();

  setTimeout(() => {
    const elapsed = Number(process.hrtime.bigint() - start) / 1e6; // ms
    const lag = Math.max(0, elapsed - 1); // subtract the 1 ms minimum delay
    console.log(`Event loop lag: ${lag.toFixed(2)} ms`);
  }, 1); // setTimeout minimum is ~1 ms
}

// Measure every second
setInterval(measureLag, 1000);

// Simulate blocking after 3 seconds
setTimeout(() => {
  console.log('--- Blocking for 500 ms ---');
  const end = Date.now() + 500;
  while (Date.now() < end) { /* spin */ }
}, 3000);
```

This technique is crude but effective. For production monitoring, use the built-in histogram API.

---

## The `monitorEventLoopDelay()` API

Node.js 11.10+ provides `perf_hooks.monitorEventLoopDelay()`, which samples the event loop delay at configurable intervals and accumulates a high-resolution histogram:

```javascript
'use strict';

const { monitorEventLoopDelay } = require('node:perf_hooks');

// Create a histogram that samples every 20 ms (default)
const histogram = monitorEventLoopDelay({ resolution: 20 });
histogram.enable();

// Print stats every 5 seconds
setInterval(() => {
  console.log('--- Event Loop Delay Histogram ---');
  console.log(`  Min:    ${(histogram.min / 1e6).toFixed(2)} ms`);
  console.log(`  Max:    ${(histogram.max / 1e6).toFixed(2)} ms`);
  console.log(`  Mean:   ${(histogram.mean / 1e6).toFixed(2)} ms`);
  console.log(`  StdDev: ${(histogram.stddev / 1e6).toFixed(2)} ms`);
  console.log(`  P50:    ${(histogram.percentile(50) / 1e6).toFixed(2)} ms`);
  console.log(`  P90:    ${(histogram.percentile(90) / 1e6).toFixed(2)} ms`);
  console.log(`  P99:    ${(histogram.percentile(99) / 1e6).toFixed(2)} ms`);
  console.log(`  P99.9:  ${(histogram.percentile(99.9) / 1e6).toFixed(2)} ms`);
  console.log();

  // Reset the histogram for the next interval
  histogram.reset();
}, 5000);

// Simulate periodic blocking
let iteration = 0;
setInterval(() => {
  iteration++;
  if (iteration % 5 === 0) {
    // Block for 100 ms every 5th iteration
    const end = Date.now() + 100;
    while (Date.now() < end) { /* spin */ }
  }
}, 200);
```

The histogram values are in nanoseconds. Divide by `1e6` to get milliseconds. Key percentiles:

| Percentile | Meaning |
|-----------|---------|
| P50 | Median lag — half of all samples are below this |
| P90 | 90% of samples are below this — typical worst case |
| P99 | 99% of samples — tail latency, spikes |
| P99.9 | Extreme tail — rare but impactful |

For a healthy server, P99 should stay below 10 ms. If it regularly exceeds 50 ms, you have a blocking problem.

---

## `UV_THREADPOOL_SIZE`: Tuning the libuv Pool

The libuv thread pool handles file system operations, DNS lookups (`dns.lookup`), and some crypto work. The default size is 4 threads. When more than 4 of these operations are in flight simultaneously, the extras queue:

```javascript
'use strict';

const fs = require('node:fs');
const { performance } = require('node:perf_hooks');

// Demonstrate thread pool saturation
// Run with: UV_THREADPOOL_SIZE=4 node this-script.js
// Then with: UV_THREADPOOL_SIZE=8 node this-script.js

const FILE = __filename;
const CONCURRENT_READS = 8;
const start = performance.now();
let completed = 0;

for (let i = 0; i < CONCURRENT_READS; i++) {
  const readStart = performance.now();

  fs.readFile(FILE, () => {
    const readElapsed = performance.now() - readStart;
    completed++;
    console.log(`Read ${i}: ${readElapsed.toFixed(1)} ms`);

    if (completed === CONCURRENT_READS) {
      console.log(`\nAll ${CONCURRENT_READS} reads: ${(performance.now() - start).toFixed(1)} ms`);
      console.log(`UV_THREADPOOL_SIZE: ${process.env.UV_THREADPOOL_SIZE || '4 (default)'}`);
    }
  });
}
```

With the default pool size of 4, the first 4 reads start immediately and the remaining 4 wait. Double the pool size and all 8 run in parallel:

```bash
# Default: reads 5-8 wait for reads 1-4
node pool-test.js

# Doubled: all 8 run in parallel
UV_THREADPOOL_SIZE=8 node pool-test.js
```

### When to Increase `UV_THREADPOOL_SIZE`

| Scenario | Recommendation |
|----------|---------------|
| Few concurrent fs/DNS operations | Keep default (4) |
| Many concurrent fs reads (e.g., static file server) | 8-16 |
| Heavy `dns.lookup` usage (many outbound HTTP requests) | 8-16 |
| Heavy `crypto.pbkdf2` or `crypto.scrypt` usage | Match concurrency level |
| Maximum value | 1024 (but each thread uses ~128 KB stack) |

Set it early — before any async operations start:

```bash
# In your start script or Dockerfile
UV_THREADPOOL_SIZE=16 node server.js
```

You cannot change it at runtime. It must be set as an environment variable before the Node.js process starts.

---

## Identifying Blocking Code

The most common event loop blockers in Node.js applications:

### 1. Synchronous File System Operations

```javascript
'use strict';

const fs = require('node:fs');

// BAD: blocks the event loop
function readConfigSync() {
  return JSON.parse(fs.readFileSync('/etc/app/config.json', 'utf8'));
}

// GOOD: non-blocking
async function readConfigAsync() {
  const data = await fs.promises.readFile('/etc/app/config.json', 'utf8');
  return JSON.parse(data);
}
```

Every `*Sync` method in the `fs` module blocks the event loop. They are acceptable at startup (before the server listens) but never in request handlers.

### 2. Large JSON Operations

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// JSON.parse and JSON.stringify are synchronous and single-threaded.
// For large payloads, they block the event loop.

function measureJsonPerformance(sizeInMB) {
  // Create a large object
  const items = [];
  const targetBytes = sizeInMB * 1024 * 1024;
  while (JSON.stringify(items).length < targetBytes) {
    items.push({
      id: items.length,
      name: 'Item ' + items.length,
      value: Math.random(),
      tags: ['alpha', 'beta', 'gamma'],
    });
  }

  // Measure stringify
  let start = performance.now();
  const json = JSON.stringify(items);
  const stringifyMs = performance.now() - start;

  // Measure parse
  start = performance.now();
  JSON.parse(json);
  const parseMs = performance.now() - start;

  console.log(`${sizeInMB} MB JSON:`);
  console.log(`  stringify: ${stringifyMs.toFixed(1)} ms`);
  console.log(`  parse:     ${parseMs.toFixed(1)} ms`);
  console.log(`  items:     ${items.length}`);
}

measureJsonPerformance(1);
measureJsonPerformance(5);
measureJsonPerformance(10);
// 10 MB of JSON can block for 100+ ms
```

### 3. RegExp Catastrophic Backtracking

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// This regex has catastrophic backtracking on certain inputs
const evilRegex = /^(a+)+$/;

function testRegex(input) {
  const start = performance.now();
  const result = evilRegex.test(input);
  const elapsed = performance.now() - start;
  console.log(`Input length ${input.length}: ${elapsed.toFixed(1)} ms (match: ${result})`);
}

// Safe inputs — fast
testRegex('aaaaaaaaaaaaaaa');           // matches quickly
testRegex('bbbbbb');                     // fails quickly

// Dangerous input — exponential backtracking
testRegex('aaaaaaaaaaaaaaaaaaaaaaX');   // fails SLOWLY
// Each additional 'a' doubles the time. 25 'a's can take seconds.
```

Never use user-provided regular expressions without validation. Even your own regexes can backtrack if the input is adversarial.

---

## Offloading Strategy 1: Worker Threads

Move CPU-intensive work to a worker thread so the main thread stays responsive:

```javascript
'use strict';

const { Worker } = require('node:worker_threads');
const http = require('node:http');

function runInWorker(code, workerData) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(code, { eval: true, workerData });
    worker.on('message', resolve);
    worker.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (req.url === '/heavy') {
    // Offload to a worker — event loop stays free
    const result = await runInWorker(`
      'use strict';
      const { parentPort, workerData } = require('node:worker_threads');
      let count = 0;
      for (let c = 2; c < workerData.limit; c++) {
        let ok = true;
        for (let d = 2; d <= Math.sqrt(c); d++) {
          if (c % d === 0) { ok = false; break; }
        }
        if (ok) count++;
      }
      parentPort.postMessage({ primes: count });
    `, { limit: 500_000 });

    res.end(`Primes found: ${result.primes}\n`);
    return;
  }

  res.end('Hello\n');
});

server.listen(3000, () => {
  console.log('Server on :3000 — /heavy is offloaded to a worker');
});
```

In production, use a thread pool (Lesson 06) instead of spawning a fresh worker per request.

---

## Offloading Strategy 2: Chunked Processing with `setImmediate()`

When you cannot move work to a worker thread (perhaps it needs access to main-thread state), break it into chunks and yield between them:

```javascript
'use strict';

// Process a large array in chunks, yielding to the event loop between batches

function processInChunks(items, chunkSize, processFn) {
  return new Promise((resolve) => {
    const results = [];
    let index = 0;

    function nextChunk() {
      const end = Math.min(index + chunkSize, items.length);

      for (; index < end; index++) {
        results.push(processFn(items[index]));
      }

      if (index < items.length) {
        // Yield to the event loop — let I/O callbacks, timers run
        setImmediate(nextChunk);
      } else {
        resolve(results);
      }
    }

    nextChunk();
  });
}

// Example: processing 1,000,000 items without blocking
(async () => {
  const items = Array.from({ length: 1_000_000 }, (_, i) => i);

  console.log('Processing 1M items in chunks of 10,000...');

  // Monitor event loop responsiveness during processing
  const lagCheck = setInterval(() => {
    const start = process.hrtime.bigint();
    setImmediate(() => {
      const lag = Number(process.hrtime.bigint() - start) / 1e6;
      console.log(`  Event loop lag: ${lag.toFixed(2)} ms`);
    });
  }, 100);

  const results = await processInChunks(items, 10_000, (item) => {
    // Simulate per-item computation
    return item * item + Math.sqrt(item);
  });

  clearInterval(lagCheck);
  console.log(`Processed ${results.length} items`);
  console.log(`Last result: ${results[results.length - 1]}`);
})();
```

The key is `setImmediate(nextChunk)`. This schedules the next batch at the end of the current event loop iteration, allowing I/O callbacks and timers to run between chunks. Without it, the 1M-item loop would block the event loop for the entire duration.

### Choosing Chunk Size

Too small: the overhead of scheduling dominates. Too large: the event loop blocks too long.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

async function benchmarkChunkSize(totalItems, chunkSize) {
  const items = Array.from({ length: totalItems }, (_, i) => i);
  let maxLag = 0;

  const lagMonitor = setInterval(() => {
    const start = process.hrtime.bigint();
    setImmediate(() => {
      const lag = Number(process.hrtime.bigint() - start) / 1e6;
      if (lag > maxLag) maxLag = lag;
    });
  }, 5);

  const start = performance.now();

  await new Promise((resolve) => {
    let idx = 0;
    let sum = 0;
    function next() {
      const end = Math.min(idx + chunkSize, items.length);
      for (; idx < end; idx++) {
        sum += Math.sqrt(items[idx]);
      }
      if (idx < items.length) {
        setImmediate(next);
      } else {
        resolve(sum);
      }
    }
    next();
  });

  clearInterval(lagMonitor);
  const elapsed = performance.now() - start;

  // Allow final lag measurement to fire
  await new Promise((r) => setTimeout(r, 50));

  console.log(`Chunk ${chunkSize.toLocaleString().padStart(10)}: ` +
    `${elapsed.toFixed(0).padStart(6)} ms total, ` +
    `max lag ${maxLag.toFixed(2).padStart(7)} ms`);
}

(async () => {
  const TOTAL = 5_000_000;
  console.log(`Processing ${TOTAL.toLocaleString()} items\n`);

  for (const size of [100, 1_000, 10_000, 100_000, 500_000]) {
    await benchmarkChunkSize(TOTAL, size);
  }
})();
```

A good starting point: chunk sizes that take 1-5 ms to process. Measure and adjust.

---

## `process.nextTick()` Starvation

`process.nextTick()` callbacks run before the event loop continues to the next phase. If you recursively schedule `nextTick` callbacks, the event loop never advances — I/O callbacks, timers, and `setImmediate` callbacks all starve:

```javascript
'use strict';

// DANGEROUS: process.nextTick() starvation

let nextTickCount = 0;
let immediateRan = false;

// Schedule a setImmediate — should run "soon"
setImmediate(() => {
  immediateRan = true;
  console.log(`setImmediate ran after ${nextTickCount} nextTick calls`);
});

// Schedule a timer — should run after 100 ms
setTimeout(() => {
  console.log(`setTimeout ran after ${nextTickCount} nextTick calls`);
}, 100);

// Flood nextTick — this blocks setImmediate and setTimeout
function flood() {
  nextTickCount++;
  if (nextTickCount < 1_000_000) {
    process.nextTick(flood);
  } else {
    console.log(`Finished ${nextTickCount} nextTick calls`);
    console.log(`setImmediate ran during flooding: ${immediateRan}`);
  }
}

process.nextTick(flood);

// Output:
// Finished 1000000 nextTick calls
// setImmediate ran during flooding: false    <-- starved!
// setImmediate ran after 1000000 nextTick calls
// setTimeout ran after 1000000 nextTick calls
```

The `setImmediate` and `setTimeout` callbacks do not run until all `nextTick` callbacks drain. This is by design — `nextTick` is a microtask-level priority. Use it sparingly.

### The Safe Alternative: `setImmediate()`

`setImmediate()` runs at the end of the current event loop iteration, after I/O callbacks. It does not block other phases:

```javascript
'use strict';

// SAFE: setImmediate() does not starve the event loop

let immediateCount = 0;

setTimeout(() => {
  console.log(`setTimeout ran after ${immediateCount} setImmediate calls`);
  // This fires during the setImmediate chain — not starved
}, 100);

function chain() {
  immediateCount++;
  if (immediateCount < 1_000_000) {
    setImmediate(chain); // yields between each call
  } else {
    console.log(`Finished ${immediateCount} setImmediate calls`);
  }
}

setImmediate(chain);
```

The `setTimeout` fires at roughly 100 ms, even though the `setImmediate` chain is running a million iterations. Each `setImmediate` yields back to the event loop, allowing timers and I/O to run.

---

## Event Loop Phases Revisited

Understanding the phase order helps you optimize:

```
   ┌───────────────────────────┐
┌─▶│         Timers            │ ← setTimeout, setInterval callbacks
│  └────────────┬──────────────┘
│  ┌────────────▼──────────────┐
│  │     Pending callbacks     │ ← System-level callbacks (TCP errors, etc.)
│  └────────────┬──────────────┘
│  ┌────────────▼──────────────┐
│  │       Idle / Prepare      │ ← Internal use only
│  └────────────┬──────────────┘
│  ┌────────────▼──────────────┐
│  │          Poll             │ ← I/O callbacks (fs, net, etc.)
│  │   (blocks here if idle)   │    Incoming connections, data arrival
│  └────────────┬──────────────┘
│  ┌────────────▼──────────────┐
│  │          Check            │ ← setImmediate callbacks
│  └────────────┬──────────────┘
│  ┌────────────▼──────────────┐
│  │      Close callbacks      │ ← socket.on('close'), etc.
│  └────────────┘──────────────┘
│          │
└──────────┘
   (nextTick and Promise microtasks run between EVERY phase transition)
```

Key optimization insights:

1. **The poll phase is where the loop parks.** When there is nothing to do, the event loop waits in the poll phase for I/O events. This is efficient — no CPU usage while idle.

2. **Timers fire before I/O.** If a timer and an I/O callback are both ready, the timer runs first.

3. **`setImmediate` runs after I/O.** This makes it ideal for processing the results of I/O operations without blocking the next batch of I/O.

4. **`nextTick` runs between every phase.** It is the highest-priority user-land callback. Overuse causes starvation.

---

## Timer Coalescing

The event loop processes all expired timers in a single batch during the timers phase. If 50 timers all expire at the same millisecond, they all fire in one pass — not 50 separate event loop iterations:

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// Schedule 100 timers that all expire at the same time
const DELAY = 100;
const COUNT = 100;

const start = performance.now();
let fired = 0;
const firstFire = { time: 0 };
const lastFire = { time: 0 };

for (let i = 0; i < COUNT; i++) {
  setTimeout(() => {
    const now = performance.now() - start;
    fired++;
    if (fired === 1) firstFire.time = now;
    if (fired === COUNT) {
      lastFire.time = now;
      console.log(`First timer fired at: ${firstFire.time.toFixed(2)} ms`);
      console.log(`Last timer fired at:  ${lastFire.time.toFixed(2)} ms`);
      console.log(`Spread:               ${(lastFire.time - firstFire.time).toFixed(2)} ms`);
      console.log(`All ${COUNT} timers fired in one batch`);
    }
  }, DELAY);
}
```

The spread between the first and last timer should be sub-millisecond — they all fire in the same timers phase. This means scheduling many short-delay timers is not as expensive as you might think. The event loop batches them efficiently.

---

## Practical Pattern: Event Loop Health Monitor

A production-grade health monitor that exposes event loop metrics and triggers alerts:

```javascript
'use strict';

const { monitorEventLoopDelay } = require('node:perf_hooks');
const { EventEmitter } = require('node:events');

class EventLoopMonitor extends EventEmitter {
  #histogram;
  #interval;
  #thresholdMs;
  #checkIntervalMs;
  #isHealthy = true;

  constructor(options = {}) {
    super();
    this.#thresholdMs = options.thresholdMs || 50;      // P99 alert threshold
    this.#checkIntervalMs = options.checkIntervalMs || 5000;

    this.#histogram = monitorEventLoopDelay({ resolution: 20 });
  }

  start() {
    this.#histogram.enable();

    this.#interval = setInterval(() => {
      const stats = this.getStats();
      this.emit('stats', stats);

      if (stats.p99Ms > this.#thresholdMs) {
        if (this.#isHealthy) {
          this.#isHealthy = false;
          this.emit('unhealthy', stats);
        }
      } else {
        if (!this.#isHealthy) {
          this.#isHealthy = true;
          this.emit('recovered', stats);
        }
      }

      this.#histogram.reset();
    }, this.#checkIntervalMs);
  }

  stop() {
    if (this.#interval) clearInterval(this.#interval);
    this.#histogram.disable();
  }

  getStats() {
    return {
      minMs:    this.#histogram.min / 1e6,
      maxMs:    this.#histogram.max / 1e6,
      meanMs:   this.#histogram.mean / 1e6,
      stddevMs: this.#histogram.stddev / 1e6,
      p50Ms:    this.#histogram.percentile(50) / 1e6,
      p90Ms:    this.#histogram.percentile(90) / 1e6,
      p99Ms:    this.#histogram.percentile(99) / 1e6,
      p999Ms:   this.#histogram.percentile(99.9) / 1e6,
      healthy:  this.#isHealthy,
    };
  }
}

// Usage
const monitor = new EventLoopMonitor({ thresholdMs: 25, checkIntervalMs: 3000 });

monitor.on('stats', (stats) => {
  console.log(`[EL] mean=${stats.meanMs.toFixed(2)} ms, ` +
    `p99=${stats.p99Ms.toFixed(2)} ms, ` +
    `max=${stats.maxMs.toFixed(2)} ms ` +
    `[${stats.healthy ? 'HEALTHY' : 'DEGRADED'}]`);
});

monitor.on('unhealthy', (stats) => {
  console.warn(`[ALERT] Event loop degraded! P99: ${stats.p99Ms.toFixed(2)} ms`);
  // In production: send to monitoring system, trigger auto-scaling, etc.
});

monitor.on('recovered', (stats) => {
  console.log(`[OK] Event loop recovered. P99: ${stats.p99Ms.toFixed(2)} ms`);
});

monitor.start();

// Simulate periodic blocking to trigger alerts
let tick = 0;
setInterval(() => {
  tick++;
  if (tick % 4 === 0) {
    const end = Date.now() + 80; // Block for 80 ms
    while (Date.now() < end) { /* spin */ }
  }
}, 1000);
```

---

## Auto-Offloading When Lag Exceeds Threshold

Combine the event loop monitor with the thread pool from Lesson 06 to automatically offload work when the main thread is under pressure:

```javascript
'use strict';

const { monitorEventLoopDelay } = require('node:perf_hooks');
const { Worker } = require('node:worker_threads');

class AdaptiveProcessor {
  #lagThresholdMs;
  #histogram;
  #currentLagMs = 0;

  constructor(lagThresholdMs = 20) {
    this.#lagThresholdMs = lagThresholdMs;
    this.#histogram = monitorEventLoopDelay({ resolution: 10 });
    this.#histogram.enable();

    // Sample lag every second
    setInterval(() => {
      this.#currentLagMs = this.#histogram.mean / 1e6;
      this.#histogram.reset();
    }, 1000);
  }

  async process(data, computeFn) {
    if (this.#currentLagMs > this.#lagThresholdMs) {
      // Event loop is stressed — offload to a worker
      console.log(`Lag ${this.#currentLagMs.toFixed(1)} ms > ${this.#lagThresholdMs} ms — offloading`);
      return this.#offload(data, computeFn.toString());
    }

    // Event loop is healthy — run on main thread
    return computeFn(data);
  }

  #offload(data, fnSource) {
    return new Promise((resolve, reject) => {
      const code = `
        'use strict';
        const { parentPort, workerData } = require('node:worker_threads');
        const fn = new Function('data', 'return (' + workerData.fnSource + ')(data)');
        const result = fn(workerData.data);
        parentPort.postMessage(result);
      `;
      const worker = new Worker(code, {
        eval: true,
        workerData: { data, fnSource },
      });
      worker.on('message', resolve);
      worker.on('error', reject);
    });
  }
}

// Usage
const processor = new AdaptiveProcessor(15);

// When event loop lag is low, this runs on the main thread.
// When lag is high, it offloads to a worker thread automatically.
setInterval(async () => {
  const result = await processor.process(100_000, (limit) => {
    let count = 0;
    for (let c = 2; c < limit; c++) {
      let ok = true;
      for (let d = 2; d <= Math.sqrt(c); d++) {
        if (c % d === 0) { ok = false; break; }
      }
      if (ok) count++;
    }
    return count;
  });
  console.log(`Primes: ${result}`);
}, 2000);
```

This is a simplified example. In production, you would use a pre-created thread pool instead of spawning workers on the fly, and the offload decision would factor in pool utilization, not just event loop lag.

---

## Common Pitfalls Summary

| Pitfall | Why It Hurts | Fix |
|---------|-------------|-----|
| `fs.readFileSync` in request handlers | Blocks event loop for entire read duration | Use `fs.promises.readFile` |
| `JSON.parse(hugeString)` | Single-threaded, blocks proportional to size | Offload to worker or stream-parse |
| Recursive `process.nextTick()` | Starves I/O and timers indefinitely | Use `setImmediate()` instead |
| Regex with `(a+)+` pattern | Exponential backtracking on malicious input | Rewrite regex, add timeout |
| `UV_THREADPOOL_SIZE=4` with many DNS lookups | DNS lookups queue behind fs operations | Increase to 8-16 |
| Unbounded `Promise.all` | Thousands of concurrent ops spike memory | Batch with concurrency limit |
| `crypto.pbkdf2Sync` | CPU-intensive, blocks event loop | Use async `crypto.pbkdf2` |
| Large `Buffer.concat` in a loop | Repeated allocation and copy | Pre-allocate or use streams |

---

## Key Takeaways

- The event loop is the single point of failure in Node.js — any callback that blocks for more than a few milliseconds degrades every concurrent operation in the process
- `monitorEventLoopDelay()` provides a high-resolution histogram of event loop lag — monitor P99 in production and alert when it exceeds your latency budget
- `setImmediate()` yields to the event loop between chunks of work, keeping I/O responsive; `process.nextTick()` runs before I/O and can starve the entire event loop if used recursively
- `UV_THREADPOOL_SIZE` controls libuv's internal thread pool — increase it when fs, DNS, or crypto operations queue behind each other, but set it as an environment variable before process start
- The best defense is layered: measure lag continuously, offload CPU work to worker threads, break long operations into chunks, and eliminate synchronous I/O from hot paths

## Next

Continue to [Lesson 08 — Performance Profiling & Benchmarking](lesson-08-profiling-benchmarking.md), where we explore V8's CPU profiler, heap snapshots, `perf_hooks` instrumentation, and the methodology for building reliable benchmarks.
