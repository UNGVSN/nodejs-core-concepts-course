# E02: Build an Event Loop Visualizer

## Objective

Create a script that makes the invisible visible: log which event loop phase is currently executing by strategically placing callbacks in every phase. By the end, you will have a reusable diagnostic tool that proves phase ordering with timestamped evidence.

## Prerequisites

- Module 01 / Lesson 04 — Event Loop Deep Dive
- Module 01 / Lesson 05 — Call Stack, Callbacks, and Microtasks
- Module 01 / Exercise 01 — Map the Event Loop

## Instructions

1. Create a file called `event-loop-visualizer.js`. Add `'use strict';` at the top. Require only built-in modules:

```javascript
'use strict';

const fs = require('node:fs');
const net = require('node:net');
const { performance } = require('node:perf_hooks');
```

2. Create a `log` helper that prefixes every message with a high-resolution timestamp relative to script start:

```javascript
const start = performance.now();

function log(phase, message) {
  const elapsed = (performance.now() - start).toFixed(3);
  console.log(`[${elapsed.padStart(10)}ms] [${phase.padEnd(18)}] ${message}`);
}
```

3. Write a function `markPhase(label, callback)` that logs entry and exit for any phase:

```javascript
function markPhase(label, callback) {
  return (...args) => {
    log(label, 'ENTER');
    callback(...args);
    log(label, 'EXIT');
  };
}
```

4. **Instrument the microtask queues.** Schedule a `process.nextTick` and a `queueMicrotask` callback that each log their execution. Inside each callback, schedule one more of the same type to prove the queue drains completely before moving on:

```javascript
process.nextTick(markPhase('NEXTTICK', () => {
  process.nextTick(markPhase('NEXTTICK-2', () => {}));
}));

queueMicrotask(markPhase('MICROTASK', () => {
  queueMicrotask(markPhase('MICROTASK-2', () => {}));
}));
```

5. **Instrument the timers phase.** Schedule two `setTimeout` callbacks with delays of 0 and 50ms. Each should use `markPhase('TIMERS', ...)`:

```javascript
setTimeout(markPhase('TIMERS', () => {
  log('TIMERS', '0ms timer callback');
}), 0);

setTimeout(markPhase('TIMERS-50', () => {
  log('TIMERS-50', '50ms timer callback');
}), 50);
```

6. **Instrument the I/O phase.** Use `fs.readFile(__filename, ...)` to trigger a callback in the poll phase. Inside that callback, schedule a `setImmediate` and a `setTimeout(fn, 0)` to demonstrate the check-before-timers ordering from within I/O:

```javascript
fs.readFile(__filename, markPhase('POLL/IO', () => {
  setImmediate(markPhase('CHECK-FROM-IO', () => {}));
  setTimeout(markPhase('TIMERS-FROM-IO', () => {}), 0);
}));
```

7. **Instrument the check phase.** Schedule a `setImmediate` callback using `markPhase('CHECK', ...)`:

```javascript
setImmediate(markPhase('CHECK', () => {
  log('CHECK', 'setImmediate callback');
}));
```

8. **Instrument close callbacks.** Create a temporary TCP server, connect to it, then immediately destroy the socket. The `socket.on('close', ...)` callback fires in the close callbacks phase. Log it with `markPhase('CLOSE', ...)`:

```javascript
const server = net.createServer();
server.listen(0, () => {
  const { port } = server.address();
  const socket = net.connect(port, () => {
    socket.destroy();
  });
  socket.on('close', markPhase('CLOSE', () => {
    server.close();
  }));
});
```

9. **Add a multi-iteration mode.** Wrap your entire instrumentation in a function `runIteration(n)` that can be called multiple times. Use `setImmediate` to schedule the next iteration so you can observe the loop cycling through phases repeatedly:

```javascript
function runIteration(n, max) {
  if (n > max) return;
  log('ITERATION', `--- Iteration ${n} of ${max} ---`);

  // ... schedule all phase markers here ...

  setImmediate(() => runIteration(n + 1, max));
}

runIteration(1, 3);
```

10. Run the script and verify your output shows the correct phase ordering: microtasks drain between phases, check fires after poll when inside I/O, close callbacks fire last.

## Break-Then-Harden Challenge

1. **Block the poll phase.** Add a synchronous `fs.readFileSync` call inside a `setImmediate` callback that reads a 100MB file (generate one with `Buffer.alloc`). Observe how all other phases are delayed until the synchronous operation completes. Then replace it with the async version and confirm phases resume normally.

2. **Microtask flood.** Inside the I/O callback, schedule 10,000 `process.nextTick` calls. Observe how the check phase (`setImmediate`) is delayed until all 10,000 microtasks drain. Measure the delay with `performance.now()`. Then refactor to use `setImmediate` batching (process 100 at a time, then yield) and confirm the delay drops.

3. **Timer drift.** Schedule `setTimeout(fn, 50)` and measure actual elapsed time with `performance.now()`. Add a CPU-busy loop (`while (performance.now() - start < 100) {}`) before the timer to demonstrate that timers are not real-time guarantees. Log the drift.

## Expected Output

```
[     0.042ms] [ITERATION         ] --- Iteration 1 of 3 ---
[     0.089ms] [NEXTTICK          ] ENTER
[     0.091ms] [NEXTTICK          ] EXIT
[     0.093ms] [NEXTTICK-2        ] ENTER
[     0.094ms] [NEXTTICK-2        ] EXIT
[     0.096ms] [MICROTASK         ] ENTER
[     0.097ms] [MICROTASK         ] EXIT
[     0.099ms] [MICROTASK-2       ] ENTER
[     0.100ms] [MICROTASK-2       ] EXIT
[     0.512ms] [TIMERS            ] ENTER
[     0.514ms] [TIMERS            ] EXIT
[     1.205ms] [CHECK             ] ENTER
[     1.207ms] [CHECK             ] EXIT
[     2.341ms] [POLL/IO           ] ENTER — file read complete
[     2.345ms] [POLL/IO           ] EXIT
[     2.350ms] [CHECK-FROM-IO     ] ENTER
[     2.352ms] [CHECK-FROM-IO     ] EXIT
[     3.780ms] [CLOSE             ] ENTER
[     3.782ms] [CLOSE             ] EXIT
[    50.210ms] [TIMERS            ] ENTER — 50ms timer
[    50.212ms] [TIMERS            ] EXIT
...
```

(Exact timestamps will vary. The ordering of phase labels is what matters.)

## Bonus

1. Add color-coded output using ANSI escape codes (no npm packages). Assign each phase a different color so the terminal output is scannable at a glance.

2. Export your visualizer as a module that other scripts can `require()`. The module should expose a `visualize(iterations)` function that returns a Promise that resolves with an array of `{ timestamp, phase, message }` objects.

## Hints

1. `performance.now()` gives sub-millisecond precision. `Date.now()` only gives millisecond precision and is subject to system clock adjustments.
2. Inside an I/O callback, `setImmediate` always fires before `setTimeout(fn, 0)` — use this to confirm you are actually inside the poll phase.
3. To create a close callback, you need a resource that can be destroyed. A TCP socket via `net.createServer` / `net.connect` is the simplest approach.
4. Microtask callbacks registered inside a microtask are drained in the same microtask checkpoint — they do not wait for the next phase.
5. If your close callback never fires, make sure you are calling `socket.destroy()` (not `socket.end()`) and that you are listening on the `'close'` event (not `'finish'`).
