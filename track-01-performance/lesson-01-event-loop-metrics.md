# Track 01 / Lesson 01 — Event Loop Metrics

> The event loop is the heartbeat of every Node.js process. When that heartbeat stutters — when a synchronous operation blocks the loop for 200ms or a runaway Promise chain starves I/O callbacks — your server stops responding to requests. This lesson teaches you to attach an EKG to the event loop and detect problems before your users do.

## Learning Objectives

- Use `monitorEventLoopDelay()` to build a high-resolution histogram of event loop latency
- Compute event loop utilization with `performance.eventLoopUtilization()` and interpret its output
- Build a real-time loop-lag monitor that detects stalls as they happen
- Set alerting thresholds for p50, p99, and max event loop delay in production
- Correlate event loop metrics with application behavior to identify the root cause of latency spikes

---

## The Event Loop Delay Histogram

The `node:perf_hooks` module provides `monitorEventLoopDelay()`, which creates a histogram that samples the delay between when the event loop *should* wake up and when it *actually* wakes up. This delay is the time the loop was blocked by synchronous code, garbage collection, or other work.

```javascript
'use strict';

const { monitorEventLoopDelay } = require('node:perf_hooks');

// Resolution: how often to sample, in milliseconds
// Lower resolution = more samples = more accurate = slightly more overhead
const histogram = monitorEventLoopDelay({ resolution: 20 });

histogram.enable();

// Simulate a healthy server doing async work
let tick = 0;
const interval = setInterval(() => {
  tick++;

  if (tick >= 50) {
    clearInterval(interval);
    histogram.disable();

    // All values are in nanoseconds — divide by 1e6 for milliseconds
    console.log('=== Event Loop Delay (healthy) ===');
    console.log(`Samples:  ${histogram.exceeds}`);
    console.log(`Min:      ${(histogram.min / 1e6).toFixed(3)}ms`);
    console.log(`Max:      ${(histogram.max / 1e6).toFixed(3)}ms`);
    console.log(`Mean:     ${(histogram.mean / 1e6).toFixed(3)}ms`);
    console.log(`StdDev:   ${(histogram.stddev / 1e6).toFixed(3)}ms`);
    console.log(`p50:      ${(histogram.percentile(50) / 1e6).toFixed(3)}ms`);
    console.log(`p90:      ${(histogram.percentile(90) / 1e6).toFixed(3)}ms`);
    console.log(`p99:      ${(histogram.percentile(99) / 1e6).toFixed(3)}ms`);
  }
}, 100);
```

Under a healthy, idle event loop, the min delay is typically under 1ms and the p99 stays under 10ms. These are your baseline numbers — record them before you start optimizing anything.

---

## Understanding the Histogram API

The histogram object returned by `monitorEventLoopDelay()` is an `IntervalHistogram` backed by an `hdr_histogram` C implementation. It records delay values in nanoseconds with configurable resolution.

```javascript
'use strict';

const { monitorEventLoopDelay } = require('node:perf_hooks');

const h = monitorEventLoopDelay({ resolution: 10 });
h.enable();

setTimeout(() => {
  h.disable();

  // Available percentiles: any value from 0 to 100
  const percentiles = [1, 5, 25, 50, 75, 90, 95, 99, 99.9, 99.99];

  console.log('=== Full Percentile Distribution ===');
  for (const p of percentiles) {
    const valueMs = (h.percentile(p) / 1e6).toFixed(3);
    console.log(`  p${String(p).padEnd(5)} ${valueMs}ms`);
  }

  // The percentiles map gives you all recorded percentile entries
  console.log('\n=== Percentiles Map (first 10) ===');
  let count = 0;
  for (const [pct, ns] of h.percentiles) {
    if (count++ >= 10) break;
    console.log(`  ${pct}% → ${(ns / 1e6).toFixed(3)}ms`);
  }

  // Reset clears the histogram for a fresh measurement window
  h.reset();
  console.log('\nAfter reset — min:', h.min, 'max:', h.max);
}, 2000);
```

**Key properties:**

| Property | Type | Description |
|----------|------|-------------|
| `min` | `number` | Minimum delay recorded (nanoseconds) |
| `max` | `number` | Maximum delay recorded (nanoseconds) |
| `mean` | `number` | Arithmetic mean of all samples (nanoseconds) |
| `stddev` | `number` | Standard deviation (nanoseconds) |
| `exceeds` | `number` | Number of times the delay exceeded the resolution |
| `percentile(p)` | `function` | Get the value at percentile `p` (0-100) |
| `percentiles` | `Map` | All percentile entries as a Map |

---

## Detecting Event Loop Stalls

A stall happens when synchronous code blocks the event loop for a noticeable duration. The histogram captures the evidence, but you need to detect stalls in real time — not after the fact.

```javascript
'use strict';

const { monitorEventLoopDelay } = require('node:perf_hooks');

const STALL_THRESHOLD_MS = 50;
const CHECK_INTERVAL_MS = 1000;

const histogram = monitorEventLoopDelay({ resolution: 20 });
histogram.enable();

let previousMax = 0;

const checker = setInterval(() => {
  const currentMax = histogram.max / 1e6;
  const p99 = histogram.percentile(99) / 1e6;
  const mean = histogram.mean / 1e6;

  // Detect if any new sample exceeded the threshold
  if (currentMax > previousMax && currentMax > STALL_THRESHOLD_MS) {
    console.error(`[STALL DETECTED] Max event loop delay: ${currentMax.toFixed(1)}ms`);
    console.error(`  p99: ${p99.toFixed(1)}ms | mean: ${mean.toFixed(1)}ms`);
  }

  previousMax = currentMax;
}, CHECK_INTERVAL_MS);

// Unref so the checker does not keep the process alive
checker.unref();

// Simulate a stall after 2 seconds
setTimeout(() => {
  console.log('Simulating CPU-bound work for 150ms...');
  const end = Date.now() + 150;
  while (Date.now() < end) {
    // Blocking the event loop
  }
  console.log('CPU-bound work complete.');
}, 2000);

// Simulate another stall after 4 seconds
setTimeout(() => {
  console.log('Simulating CPU-bound work for 300ms...');
  const end = Date.now() + 300;
  while (Date.now() < end) {
    // Blocking the event loop again
  }
  console.log('CPU-bound work complete.');
}, 4000);

// Let the process run for 6 seconds
setTimeout(() => {
  clearInterval(checker);
  histogram.disable();
  console.log('\n=== Final Histogram ===');
  console.log(`Max:  ${(histogram.max / 1e6).toFixed(1)}ms`);
  console.log(`p99:  ${(histogram.percentile(99) / 1e6).toFixed(1)}ms`);
  console.log(`Mean: ${(histogram.mean / 1e6).toFixed(1)}ms`);
}, 6000);
```

The key insight: `histogram.max` gives you the worst-case delay since the histogram was created (or last reset). Checking it periodically and comparing to the previous value tells you whether a new stall occurred.

---

## Building a Loop-Lag Monitor

A more practical approach measures loop lag directly — schedule a timer and measure how late it fires. This gives you a real-time signal without the statistical overhead of histograms.

```javascript
'use strict';

class LoopLagMonitor {
  constructor(options = {}) {
    this.interval = options.interval || 500;     // Check every 500ms
    this.threshold = options.threshold || 50;     // Alert above 50ms
    this.onLag = options.onLag || this._defaultHandler;
    this._timer = null;
    this._expected = 0;
    this._samples = [];
    this._maxSamples = options.maxSamples || 120; // 1 minute at 500ms
  }

  start() {
    this._expected = Date.now() + this.interval;
    this._timer = setTimeout(() => this._check(), this.interval);
    this._timer.unref();
    return this;
  }

  stop() {
    if (this._timer) {
      clearTimeout(this._timer);
      this._timer = null;
    }
    return this;
  }

  _check() {
    const now = Date.now();
    const lag = now - this._expected;

    this._samples.push(lag);
    if (this._samples.length > this._maxSamples) {
      this._samples.shift();
    }

    if (lag > this.threshold) {
      this.onLag({
        lag,
        threshold: this.threshold,
        timestamp: new Date().toISOString(),
        stats: this.getStats()
      });
    }

    // Schedule next check
    this._expected = now + this.interval;
    this._timer = setTimeout(() => this._check(), this.interval);
    this._timer.unref();
  }

  getStats() {
    if (this._samples.length === 0) return null;

    const sorted = [...this._samples].sort((a, b) => a - b);
    const sum = sorted.reduce((acc, v) => acc + v, 0);
    const len = sorted.length;

    return {
      count: len,
      min: sorted[0],
      max: sorted[len - 1],
      mean: Math.round(sum / len),
      p50: sorted[Math.floor(len * 0.5)],
      p90: sorted[Math.floor(len * 0.9)],
      p99: sorted[Math.floor(len * 0.99)]
    };
  }

  _defaultHandler(event) {
    console.error(
      `[LOOP LAG] ${event.lag}ms (threshold: ${event.threshold}ms) at ${event.timestamp}`
    );
  }
}

// Usage
const monitor = new LoopLagMonitor({
  interval: 200,
  threshold: 30,
  onLag(event) {
    console.error(`[ALERT] Event loop lag: ${event.lag}ms`);
    console.error(`  Stats — p50: ${event.stats.p50}ms, p99: ${event.stats.p99}ms`);
  }
});

monitor.start();

// Simulate varying workloads
setTimeout(() => {
  const end = Date.now() + 80;
  while (Date.now() < end) {}
  console.log('Blocked for 80ms');
}, 1000);

setTimeout(() => {
  const end = Date.now() + 200;
  while (Date.now() < end) {}
  console.log('Blocked for 200ms');
}, 2000);

setTimeout(() => {
  monitor.stop();
  console.log('\nFinal stats:', monitor.getStats());
}, 4000);
```

This monitor has a smaller footprint than the histogram API and is easy to hook into any alerting system. The trade-off is lower resolution — it only measures lag at the configured interval rather than continuously sampling.

---

## Event Loop Utilization

Node.js 14+ provides `performance.eventLoopUtilization()`, which measures the proportion of time the event loop spends in an "active" state (executing callbacks) versus "idle" (waiting for I/O in the poll phase).

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// Take the first snapshot
const elu1 = performance.eventLoopUtilization();

console.log('Initial ELU:', elu1);
// { idle: 0, active: 0, utilization: 0 }

// Simulate some work
let counter = 0;
const work = setInterval(() => {
  // Light CPU work
  for (let i = 0; i < 1e6; i++) {
    counter += Math.sqrt(i);
  }
}, 10);

setTimeout(() => {
  clearInterval(work);

  // Take the second snapshot
  const elu2 = performance.eventLoopUtilization();

  // Calculate utilization between the two snapshots
  const diff = performance.eventLoopUtilization(elu2, elu1);

  console.log('\n=== Event Loop Utilization ===');
  console.log(`Idle:        ${diff.idle.toFixed(2)}ms`);
  console.log(`Active:      ${diff.active.toFixed(2)}ms`);
  console.log(`Utilization: ${(diff.utilization * 100).toFixed(1)}%`);

  // Interpretation:
  // - Low utilization (< 30%): Server is mostly idle, plenty of headroom
  // - Medium utilization (30-70%): Healthy under load
  // - High utilization (> 80%): Approaching saturation
  // - Near 100%: Event loop is never idle — latency will spike
}, 3000);
```

**The two-snapshot pattern** is critical: calling `eventLoopUtilization(elu2, elu1)` gives you the utilization for the *interval between the snapshots*, not since process start. This lets you track utilization over rolling windows.

---

## Periodic ELU Reporter

In production, you want to report ELU on a fixed interval — say every 5 seconds — to a metrics system.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

function createELUReporter(intervalMs = 5000) {
  let previous = performance.eventLoopUtilization();

  const timer = setInterval(() => {
    const current = performance.eventLoopUtilization();
    const delta = performance.eventLoopUtilization(current, previous);
    previous = current;

    const report = {
      timestamp: Date.now(),
      utilization: Math.round(delta.utilization * 10000) / 100, // 2 decimal %
      activeMs: Math.round(delta.active * 100) / 100,
      idleMs: Math.round(delta.idle * 100) / 100
    };

    // In production, send this to your metrics backend
    console.log(`[ELU] ${report.utilization}% active | ` +
      `${report.activeMs}ms active / ${report.idleMs}ms idle`);

    if (delta.utilization > 0.8) {
      console.error('[WARNING] Event loop utilization above 80% — investigate');
    }

    if (delta.utilization > 0.95) {
      console.error('[CRITICAL] Event loop utilization above 95% — shedding load recommended');
    }
  }, intervalMs);

  timer.unref();
  return timer;
}

const reporter = createELUReporter(1000);

// Simulate increasing load
let intensity = 0;
const loadGenerator = setInterval(() => {
  intensity++;
  const iterations = intensity * 5e5;

  for (let i = 0; i < iterations; i++) {
    Math.sqrt(i);
  }
}, 50);

setTimeout(() => {
  clearInterval(loadGenerator);
  clearInterval(reporter);
  console.log('\nLoad test complete');
}, 8000);
```

---

## Combining Histogram and ELU

The histogram tells you about *latency spikes* — how long individual delays were. ELU tells you about *overall saturation* — what fraction of time the loop was busy. Together, they give you a complete picture.

```javascript
'use strict';

const { monitorEventLoopDelay, performance } = require('node:perf_hooks');

class EventLoopHealth {
  constructor(options = {}) {
    this.resolution = options.resolution || 20;
    this.reportInterval = options.reportInterval || 5000;
    this.histogram = monitorEventLoopDelay({ resolution: this.resolution });
    this._previousELU = null;
    this._timer = null;
  }

  start() {
    this.histogram.enable();
    this._previousELU = performance.eventLoopUtilization();

    this._timer = setInterval(() => {
      this._report();
    }, this.reportInterval);
    this._timer.unref();

    return this;
  }

  stop() {
    this.histogram.disable();
    if (this._timer) {
      clearInterval(this._timer);
      this._timer = null;
    }
    return this;
  }

  _report() {
    const currentELU = performance.eventLoopUtilization();
    const deltaELU = performance.eventLoopUtilization(currentELU, this._previousELU);
    this._previousELU = currentELU;

    const report = {
      timestamp: new Date().toISOString(),
      utilization: (deltaELU.utilization * 100).toFixed(1) + '%',
      delay: {
        min: (this.histogram.min / 1e6).toFixed(2) + 'ms',
        max: (this.histogram.max / 1e6).toFixed(2) + 'ms',
        mean: (this.histogram.mean / 1e6).toFixed(2) + 'ms',
        p50: (this.histogram.percentile(50) / 1e6).toFixed(2) + 'ms',
        p99: (this.histogram.percentile(99) / 1e6).toFixed(2) + 'ms'
      }
    };

    console.log(JSON.stringify(report));

    // Reset histogram for the next window
    this.histogram.reset();
  }

  snapshot() {
    const elu = performance.eventLoopUtilization();
    const delta = performance.eventLoopUtilization(elu, this._previousELU);

    return {
      utilization: delta.utilization,
      p50Ms: this.histogram.percentile(50) / 1e6,
      p99Ms: this.histogram.percentile(99) / 1e6,
      maxMs: this.histogram.max / 1e6,
      healthy: delta.utilization < 0.8 && this.histogram.percentile(99) / 1e6 < 50
    };
  }
}

// Usage
const health = new EventLoopHealth({ reportInterval: 2000 });
health.start();

// Phase 1: Light load (0-3s)
console.log('Phase 1: Light load');
setTimeout(() => {
  // Phase 2: Heavy load (3-6s)
  console.log('\nPhase 2: Heavy load');
  const heavyWork = setInterval(() => {
    const end = Date.now() + 30;
    while (Date.now() < end) {}
  }, 50);

  setTimeout(() => {
    clearInterval(heavyWork);
    console.log('\nPhase 3: Recovery');

    setTimeout(() => {
      health.stop();
      console.log('\nFinal snapshot:', health.snapshot());
    }, 3000);
  }, 3000);
}, 3000);
```

---

## Correlating Lag with Application Behavior

Raw metrics are useful, but the real value comes from correlating event loop metrics with specific operations in your application.

```javascript
'use strict';

const { monitorEventLoopDelay, performance } = require('node:perf_hooks');
const { createHash } = require('node:crypto');

const histogram = monitorEventLoopDelay({ resolution: 10 });
histogram.enable();

// Tag each operation window with what the server was doing
const operations = [];

function measureOperation(name, fn) {
  const before = {
    max: histogram.max,
    p99: histogram.percentile(99)
  };

  histogram.reset();
  const start = performance.now();

  fn();

  const duration = performance.now() - start;
  const after = {
    max: histogram.max,
    p99: histogram.percentile(99)
  };

  operations.push({
    name,
    durationMs: duration.toFixed(1),
    loopDelayMaxMs: ((after.max) / 1e6).toFixed(2),
    loopDelayP99Ms: ((after.p99) / 1e6).toFixed(2)
  });
}

// Simulate different operations
measureOperation('small-hash', () => {
  for (let i = 0; i < 100; i++) {
    createHash('sha256').update('hello').digest('hex');
  }
});

measureOperation('large-hash', () => {
  const bigData = Buffer.alloc(50 * 1024 * 1024, 'x'); // 50 MB
  createHash('sha256').update(bigData).digest('hex');
});

measureOperation('json-parse', () => {
  const obj = {};
  for (let i = 0; i < 10000; i++) {
    obj[`key_${i}`] = { value: i, nested: { deep: true } };
  }
  const str = JSON.stringify(obj);
  JSON.parse(str);
});

measureOperation('sort-large-array', () => {
  const arr = Array.from({ length: 1e6 }, () => Math.random());
  arr.sort((a, b) => a - b);
});

histogram.disable();

// Report
console.log('\n=== Operation Impact on Event Loop ===\n');
console.log(
  'Operation'.padEnd(25),
  'Duration'.padEnd(12),
  'Loop Max'.padEnd(12),
  'Loop p99'
);
console.log('-'.repeat(60));

for (const op of operations) {
  console.log(
    op.name.padEnd(25),
    (op.durationMs + 'ms').padEnd(12),
    (op.loopDelayMaxMs + 'ms').padEnd(12),
    op.loopDelayP99Ms + 'ms'
  );
}
```

This technique lets you answer the question "which operation is causing my event loop stalls?" by correlating delay spikes with specific code paths.

---

## Production Alerting Thresholds

Not all event loop delay is a problem. Here are practical thresholds based on production experience.

```javascript
'use strict';

// Recommended alerting thresholds for production Node.js servers
const THRESHOLDS = {
  // Event Loop Delay (from monitorEventLoopDelay)
  delay: {
    p50:  { warn: 10,  critical: 25  },  // Median delay
    p99:  { warn: 50,  critical: 100 },  // Tail latency
    max:  { warn: 200, critical: 500 }   // Worst-case spike
  },
  // Event Loop Utilization (from eventLoopUtilization)
  utilization: {
    warn:     0.7,   // 70% — approaching saturation
    critical: 0.9    // 90% — actively degraded
  }
};

function evaluateHealth(metrics) {
  const alerts = [];

  // Check delay thresholds
  for (const [percentile, limits] of Object.entries(THRESHOLDS.delay)) {
    const value = metrics.delay[percentile];
    if (value >= limits.critical) {
      alerts.push({ level: 'CRITICAL', metric: `delay.${percentile}`, value, limit: limits.critical });
    } else if (value >= limits.warn) {
      alerts.push({ level: 'WARNING', metric: `delay.${percentile}`, value, limit: limits.warn });
    }
  }

  // Check utilization
  if (metrics.utilization >= THRESHOLDS.utilization.critical) {
    alerts.push({ level: 'CRITICAL', metric: 'utilization', value: metrics.utilization });
  } else if (metrics.utilization >= THRESHOLDS.utilization.warn) {
    alerts.push({ level: 'WARNING', metric: 'utilization', value: metrics.utilization });
  }

  return {
    healthy: alerts.length === 0,
    alerts
  };
}

// Example evaluation
const mockMetrics = {
  delay: { p50: 8, p99: 75, max: 250 },
  utilization: 0.65
};

const result = evaluateHealth(mockMetrics);
console.log('Health check:', JSON.stringify(result, null, 2));
// This would produce warnings for p99 (75 > 50) and max (250 > 200)
// but not utilization (0.65 < 0.7)
```

**Rules of thumb:**

- **p50 delay > 10ms** — Something is regularly blocking the loop. Investigate synchronous operations.
- **p99 delay > 50ms** — Tail latency is high. Some requests are experiencing noticeable delay.
- **Max delay > 200ms** — A stall occurred. A specific operation blocked the loop for a fifth of a second.
- **Utilization > 70%** — The loop is busy more than it is idle. Scale horizontally or offload work to workers.
- **Utilization > 90%** — The loop is saturated. Response times are degrading. Shed load immediately.

---

## Key Takeaways

- `monitorEventLoopDelay()` provides a high-resolution histogram of event loop latency in nanoseconds — use it to detect latency spikes and measure tail latency (p99)
- `performance.eventLoopUtilization()` measures the ratio of active to idle time — use the two-snapshot pattern to track utilization over rolling windows
- A simple loop-lag monitor using `setTimeout` drift detection provides a lightweight, real-time alternative to histograms for stall detection
- Correlating event loop metrics with specific operations (hashing, JSON parsing, sorting) identifies which code paths are responsible for latency degradation
- Production thresholds should alert on p99 delay above 50ms and utilization above 70% — these are the early warning signals before users notice degradation

## Next

With event loop metrics in hand, the next lesson turns to memory — how to profile heap allocations, detect memory leaks, and understand where every byte of your Node.js process's memory is going.
