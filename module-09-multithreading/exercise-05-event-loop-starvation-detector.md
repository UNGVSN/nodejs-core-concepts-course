# E05: Event Loop Starvation Detector

## Objective

Build a monitoring tool that continuously measures event loop lag using multiple detection techniques: `setTimeout` drift measurement, `monitorEventLoopDelay()` from `perf_hooks`, and high-resolution timestamps. When lag exceeds a configurable threshold, the tool logs an alert with a histogram of recent delays. This is the diagnostic tool you wish you had the last time a production server stopped responding to health checks.

## Prerequisites

- Module 09 / Lesson 07 — Event Loop Optimization
- Module 09 / Lesson 08 — Performance Profiling & Benchmarking
- Module 01 / Lesson 04 — Event Loop Deep Dive

## Instructions

1. **Create `starvation-detector.js`** with `'use strict';` at the top. Require:

```javascript
'use strict';

const { monitorEventLoopDelay, performance } = require('node:perf_hooks');
const { EventEmitter } = require('node:events');
const crypto = require('node:crypto');
const fs = require('node:fs');
```

2. **Build the `StarvationDetector` class** extending `EventEmitter`. The constructor accepts an options object with sensible defaults:

```javascript
class StarvationDetector extends EventEmitter {
  #intervalMs;
  #thresholdMs;
  #historySize;
  #history;       // circular buffer of lag measurements
  #historyIndex;
  #timer;
  #histogram;     // from monitorEventLoopDelay
  #lastCheck;
  #running;
  #alertCount;

  constructor({
    intervalMs  = 100,
    thresholdMs = 50,
    historySize = 100
  } = {}) {
    super();
    this.#intervalMs  = intervalMs;
    this.#thresholdMs = thresholdMs;
    this.#historySize = historySize;
    this.#history     = new Float64Array(historySize);
    this.#historyIndex = 0;
    this.#running     = false;
    this.#alertCount  = 0;
  }
}
```

3. **Implement `start()`.** This method:
   - Creates the `monitorEventLoopDelay` histogram with `monitorEventLoopDelay({ resolution: 10 })` and calls `.enable()` on it
   - Records `this.#lastCheck = performance.now()`
   - Starts a recurring `setTimeout` that calls `this.#measure()` every `#intervalMs` milliseconds
   - Sets `#running = true`

4. **Implement `#measure()`.** This is the core detection method. On each invocation:
   - Compute actual elapsed: `const now = performance.now(); const elapsed = now - this.#lastCheck;`
   - Compute lag: `const lag = elapsed - this.#intervalMs;` (the overshoot beyond the expected interval)
   - Store the lag in the circular buffer: `this.#history[this.#historyIndex % this.#historySize] = lag; this.#historyIndex++;`
   - If `lag > this.#thresholdMs`, emit a `'starvation'` event with `{ lag, timestamp: Date.now(), alertNumber: ++this.#alertCount }`
   - Update `this.#lastCheck = now`
   - Schedule the next measurement: `this.#timer = setTimeout(() => this.#measure(), this.#intervalMs)`

5. **Implement `getStats()`.** Returns an object with statistics computed from the circular buffer:
   - `avg`: average lag across all recorded samples
   - `max`: maximum lag
   - `min`: minimum lag (ignoring unset zeros)
   - `p99`: 99th percentile (sort the filled portion, pick the value at index `Math.floor(count * 0.99)`)
   - `samples`: number of samples recorded
   - Also read from the `monitorEventLoopDelay` histogram: `histogramMin`, `histogramMean`, `histogramP50`, `histogramP99`, `histogramMax` (convert from nanoseconds to milliseconds by dividing by 1e6)

6. **Implement `printHistogram()`.** Render a text-based ASCII histogram of lag values from the circular buffer. Use these buckets: `0-5ms`, `5-10ms`, `10-20ms`, `20-50ms`, `50-100ms`, `100-200ms`, `200-500ms`, `500ms-1s`, `1s+`. For each bucket, print a bar using `#` characters (scale so the largest bucket is 40 characters wide) and the count:

```
  0-5ms    |########################################| 72
  5-10ms   |######                                  |  8
  10-20ms  |###                                     |  4
  20-50ms  |##                                      |  2
  50-100ms |#####                                   |  6
  100-200ms|                                        |  0
  200-500ms|########                                |  8
  500ms-1s |                                        |  0
  1s+      |                                        |  0
```

7. **Implement `stop()`.** Clears the timer with `clearTimeout(this.#timer)`. Disables the histogram with `this.#histogram.disable()`. Sets `#running = false`. Emits a `'stopped'` event with the final stats from `getStats()`. Ensure no timers keep the process alive after `stop()` — call `this.#timer.unref()` when scheduling.

8. **Write the demo section.** Below the class (still in the same file), create an async `main()` function that:
   - Instantiates the detector with default options
   - Registers listeners for `'starvation'` events (print alert with lag value)
   - Calls `detector.start()`
   - Runs three starvation scenarios with a 2-second pause of normal operation before each:

   **Scenario A — CPU burn:** Block with a `while` loop for 200ms:
   ```javascript
   const end = performance.now() + 200;
   while (performance.now() < end) { /* spin */ }
   ```

   **Scenario B — Synchronous I/O:** Read a large file synchronously in a tight loop:
   ```javascript
   for (let i = 0; i < 20; i++) {
     fs.readFileSync(__filename);
   }
   ```

   **Scenario C — Synchronous crypto:** Run `crypto.pbkdf2Sync('password', 'salt', 100000, 64, 'sha512')` which takes hundreds of milliseconds.

9. **After all scenarios**, print the histogram with `detector.printHistogram()`, print the full stats with `detector.getStats()`, and call `detector.stop()`.

10. **Handle the `unref` pattern.** When scheduling timers in the detector, call `.unref()` on the timeout so the detector does not prevent the Node.js process from exiting naturally when the demo is done.

## Break-Then-Harden Challenge

### Scenario 1 — Detector Measures Its Own Overhead

Set `intervalMs` to 1ms and run for 5 seconds (5,000 expected samples). Observe that even with no blocking code, the reported average lag is 1-5ms because `setTimeout(fn, 1)` has inherent imprecision and the callback scheduling itself costs time. Fix it by documenting the minimum meaningful interval (50ms+) and subtracting the baseline lag measured during a calm calibration period.

### Scenario 2 — Missed Starvation Events

Block the event loop for exactly 5 seconds with a `while` loop. Observe that only one `setTimeout` callback fires after the 5-second block (not 50 callbacks for the 50 missed 100ms intervals). The detector reports one 5,000ms lag spike instead of many smaller ones. Document this as a fundamental limitation: `setTimeout` does not "catch up" on missed ticks — all missed intervals are collapsed into a single delayed callback.

### Scenario 3 — Histogram Memory Growth

Never call `this.#histogram.reset()` on the `monitorEventLoopDelay` instance. Run the detector for 10 minutes. Observe that the internal histogram's memory footprint grows because it accumulates all samples forever. Fix it by periodically calling `this.#histogram.reset()` after reading percentiles (e.g., every 60 seconds), so the histogram reflects only recent behavior.

## Expected Output

```
$ node starvation-detector.js

Event Loop Starvation Detector
  Check interval: 100 ms
  Alert threshold: 50 ms
  History buffer:  100 samples

--- Phase 1: Normal operation (2 seconds) ---
[stats] avg=0.4ms  max=1.2ms  p99=0.9ms  samples=20

--- Phase 2: CPU burn (200ms while-loop) ---
[ALERT #1] Event loop starvation! Lag: 201.3 ms (4.0x threshold)
[stats] avg=10.7ms  max=201.3ms  p99=201.3ms  samples=22

--- Phase 3: Synchronous I/O burst ---
[ALERT #2] Event loop starvation! Lag: 87.4 ms (1.7x threshold)
[stats] avg=14.2ms  max=201.3ms  p99=87.4ms  samples=42

--- Phase 4: Synchronous crypto (pbkdf2Sync) ---
[ALERT #3] Event loop starvation! Lag: 312.7 ms (6.3x threshold)
[stats] avg=28.9ms  max=312.7ms  p99=312.7ms  samples=46

--- Lag Histogram ---
  0-5ms    |########################################| 34
  5-10ms   |####                                    |  4
  10-20ms  |##                                      |  2
  20-50ms  |##                                      |  2
  50-100ms |##                                      |  2
  100-200ms|                                        |  0
  200-500ms|##                                      |  2
  500ms+   |                                        |  0

--- monitorEventLoopDelay percentiles ---
  min:   0.10 ms
  mean:  14.27 ms
  p50:   0.41 ms
  p99:   312.68 ms
  max:   312.71 ms

Detector stopped. 3 alerts fired, 46 samples collected.
```

## Bonus

1. **HTTP health endpoint.** Wrap the detector in an HTTP server that exposes `GET /health` returning JSON with current lag stats and `GET /histogram` returning the ASCII histogram as `text/plain`. A load balancer could use the health endpoint to route traffic away from a Node.js instance experiencing starvation.

2. **Worker thread monitor.** Run the `monitorEventLoopDelay` polling inside a dedicated worker thread. The worker periodically reads the histogram percentiles and sends them to the main thread via `postMessage`. This way the monitoring itself adds zero overhead to the main event loop — the worker has its own event loop.

## Hints

1. `monitorEventLoopDelay({ resolution: 10 })` returns a `Histogram` object. Call `.enable()` to start sampling, `.percentile(99)` for the p99 value (returned in nanoseconds), `.mean` for the average (nanoseconds), and `.reset()` to clear accumulated data.

2. Measure `setTimeout` drift with this pattern: record `start = performance.now()` when scheduling the timeout, then inside the callback compute `lag = performance.now() - start - intervalMs`. Positive lag means the event loop was blocked.

3. A circular buffer is an array with a write index that wraps: `this.#history[this.#historyIndex % this.#historySize] = value; this.#historyIndex++`. To read filled entries, iterate from 0 to `Math.min(this.#historyIndex, this.#historySize)`.

4. `performance.now()` returns milliseconds with microsecond precision — far more accurate than `Date.now()` for measuring event loop jitter.

5. The event loop processes `setTimeout` callbacks in the "timers" phase. If a previous callback blocks for 200ms, the next timer callback will be delayed by at least 200ms regardless of its scheduled time — there is no preemption in JavaScript.
