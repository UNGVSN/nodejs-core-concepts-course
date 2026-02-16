# Module 01 / Lesson 04 — Event Loop Deep Dive

> Every Node.js developer knows "the event loop exists." Far fewer can name its six phases, explain why `setTimeout(fn, 0)` does not mean "run immediately," or predict whether `setImmediate` fires before or after a timer in a given context. This lesson maps the event loop phase by phase so you can reason about execution order with precision.

## Learning Objectives

- Name and describe all six phases of the Node.js event loop
- Explain when microtasks (Promises, `queueMicrotask`, `process.nextTick`) drain relative to phases
- Predict the execution order of timers, I/O callbacks, `setImmediate`, and close callbacks
- Describe what happens during the poll phase and when the loop blocks vs. continues
- Use `setTimeout`, `setImmediate`, and I/O callbacks to prove phase ordering experimentally

---

## The Six Phases

The Node.js event loop is not a simple "check for callbacks and run them" mechanism. It is a structured loop with six distinct phases, each responsible for a specific category of callbacks. On every iteration (called a "tick"), the loop visits each phase in order:

```
   ┌───────────────────────────┐
┌─►│         timers             │  setTimeout, setInterval callbacks
│  └─────────────┬─────────────┘
│  ┌─────────────▼─────────────┐
│  │     pending callbacks      │  I/O callbacks deferred from previous tick
│  └─────────────┬─────────────┘
│  ┌─────────────▼─────────────┐
│  │     idle, prepare          │  Internal use only (libuv housekeeping)
│  └─────────────┬─────────────┘
│  ┌─────────────▼─────────────┐
│  │         poll               │  Retrieve new I/O events; execute I/O callbacks
│  └─────────────┬─────────────┘
│  ┌─────────────▼─────────────┐
│  │         check              │  setImmediate callbacks
│  └─────────────┬─────────────┘
│  ┌─────────────▼─────────────┐
│  │     close callbacks        │  socket.on('close', ...), etc.
│  └─────────────┘─────────────┘
│                │
└────────────────┘
```

Between **every phase transition** and after **every individual callback**, Node.js drains the microtask queues (`process.nextTick` queue first, then the Promise microtask queue). This microtask draining is the mechanism that gives `process.nextTick` and Promises their "run as soon as possible" behavior.

---

## Phase 1: Timers

The timers phase executes callbacks scheduled by `setTimeout` and `setInterval` whose threshold has elapsed.

A timer does not guarantee execution at the exact specified time — it guarantees execution *no earlier than* the specified time. If the event loop is busy processing I/O callbacks when a timer expires, the timer callback waits until the loop reaches the timers phase again.

```javascript
'use strict';

// Demonstrate that setTimeout(fn, 0) does not mean "immediate"
const start = Date.now();

setTimeout(() => {
  const delay = Date.now() - start;
  console.log(`setTimeout(fn, 0) fired after ${delay}ms`);
  // On most systems this prints 1-4ms, not 0ms
  // Node.js enforces a minimum delay of 1ms for setTimeout
}, 0);

setTimeout(() => {
  const delay = Date.now() - start;
  console.log(`setTimeout(fn, 100) fired after ${delay}ms`);
}, 100);

// Keep the event loop busy for a bit to show timer imprecision
const busyEnd = Date.now() + 50;
while (Date.now() < busyEnd) {
  // Blocking the event loop for 50ms
}

console.log(`Busy wait done at ${Date.now() - start}ms`);
// The first timer was scheduled for 0ms but could not fire
// until the synchronous code finished and the loop reached
// the timers phase
```

**Key detail:** Node.js clamps `setTimeout(fn, 0)` to `setTimeout(fn, 1)`. A delay of 0 is treated as 1 millisecond.

---

## Phase 2: Pending Callbacks

This phase executes callbacks for certain system operations that were deferred to the next loop iteration. The most common case is TCP error callbacks — for example, if a TCP connection attempt receives `ECONNREFUSED`, the error callback is queued here rather than in the poll phase.

Most applications never interact with this phase directly. It exists for correctness: some OS-level error notifications arrive at awkward times, and this phase gives them a clean place to execute.

---

## Phase 3: Idle, Prepare

This phase is used internally by libuv for housekeeping. Node.js uses it to gather statistics and prepare for the poll phase. You cannot schedule callbacks here from JavaScript — it is not part of the public API.

---

## Phase 4: Poll

The poll phase is the heart of the event loop. It does two things:

1. **Calculates how long it should block** waiting for I/O
2. **Processes events in the poll queue** — these are I/O completion callbacks (file reads, network data, etc.)

When the event loop enters the poll phase:

- If the poll queue is **not empty**, the loop iterates through the queue, executing callbacks synchronously until the queue is drained or the system-dependent hard limit is reached.
- If the poll queue **is empty**:
  - If `setImmediate` callbacks are queued, the loop moves to the check phase
  - If no `setImmediate` is queued, the loop **blocks here**, waiting for new I/O events
  - The blocking time is bounded by the nearest pending timer — the loop will wake up in time to execute it

```javascript
'use strict';

const fs = require('node:fs');

// This callback fires during the POLL phase
// because it is an I/O completion callback
fs.readFile(__filename, () => {
  console.log('1. fs.readFile callback (poll phase)');

  // Inside an I/O callback, setImmediate ALWAYS fires before setTimeout
  setTimeout(() => {
    console.log('3. setTimeout (timers phase — next iteration)');
  }, 0);

  setImmediate(() => {
    console.log('2. setImmediate (check phase — same iteration)');
  });
});
```

This always prints in the order 1, 2, 3 because inside an I/O callback, we are in the poll phase. The check phase (setImmediate) comes next in the current iteration, and the timers phase comes at the start of the next iteration.

---

## Phase 5: Check

The check phase runs `setImmediate` callbacks. `setImmediate` is specifically designed to execute after the poll phase completes.

```javascript
'use strict';

// setImmediate vs setTimeout(fn, 0) outside of I/O context
// The order is NON-DETERMINISTIC because it depends on process performance

// Run this multiple times — the order may vary
setTimeout(() => {
  console.log('setTimeout');
}, 0);

setImmediate(() => {
  console.log('setImmediate');
});

// Sometimes setTimeout fires first, sometimes setImmediate does.
// This is because when the script starts, the event loop has not
// yet entered any phase — whether the 1ms timer threshold has
// elapsed by the time the loop reaches the timers phase depends
// on system performance.
```

**The rule:** Inside an I/O callback, `setImmediate` always fires before `setTimeout(fn, 0)`. Outside an I/O callback, the order is non-deterministic.

---

## Phase 6: Close Callbacks

This phase runs callbacks for close events — `socket.on('close', ...)`, `server.on('close', ...)`, and similar. If a handle is destroyed abruptly (e.g., `socket.destroy()`), the close callback fires here.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  // This close callback fires in the "close callbacks" phase
  socket.on('close', () => {
    console.log('Socket close callback (close callbacks phase)');
    server.close();
  });

  socket.destroy(); // Abruptly close the socket
});

server.listen(0, () => {
  const { port } = server.address();
  const client = net.connect(port);
  client.on('error', () => {}); // Swallow connection reset
});
```

---

## Microtask Draining: The Hidden Seventh Step

Between every phase — and after every individual callback within a phase — Node.js drains the microtask queues. There are two microtask queues, and they drain in this order:

1. **`process.nextTick` queue** — drains completely first
2. **Promise microtask queue** (`queueMicrotask`, `.then`, `await`) — drains after nextTick

```javascript
'use strict';

// Prove that microtasks drain between phases

setTimeout(() => {
  console.log('1. setTimeout callback (timers phase)');

  process.nextTick(() => {
    console.log('2. process.nextTick (microtask — drains before next callback)');
  });

  Promise.resolve().then(() => {
    console.log('3. Promise.then (microtask — drains after nextTick)');
  });
}, 0);

setTimeout(() => {
  console.log('4. Second setTimeout (timers phase — after microtasks drained)');
}, 0);
```

Output (deterministic):
```
1. setTimeout callback (timers phase)
2. process.nextTick (microtask — drains before next callback)
3. Promise.then (microtask — drains after nextTick)
4. Second setTimeout (timers phase — after microtasks drained)
```

The microtask drain between callbacks 1 and 4 is what makes this predictable. Without it, callbacks 1 and 4 would run back-to-back in the timers phase, and the microtasks would fire later.

---

## Complete Execution Order Demonstration

Here is a comprehensive example that touches every phase:

```javascript
'use strict';

const fs = require('node:fs');

console.log('A. Synchronous — runs first (call stack)');

process.nextTick(() => {
  console.log('B. process.nextTick — microtask after sync code');
});

Promise.resolve().then(() => {
  console.log('C. Promise.then — microtask after nextTick');
});

setTimeout(() => {
  console.log('D. setTimeout — timers phase');
}, 0);

setImmediate(() => {
  console.log('E. setImmediate — check phase');
});

fs.readFile(__filename, () => {
  console.log('F. fs.readFile — poll phase (I/O callback)');

  process.nextTick(() => {
    console.log('G. nextTick inside I/O — microtask drain');
  });

  Promise.resolve().then(() => {
    console.log('H. Promise inside I/O — microtask drain');
  });

  setImmediate(() => {
    console.log('I. setImmediate inside I/O — check phase (guaranteed before timer)');
  });

  setTimeout(() => {
    console.log('J. setTimeout inside I/O — timers phase (next iteration)');
  }, 0);
});

console.log('K. Synchronous — still on the call stack');
```

Expected output:
```
A. Synchronous — runs first (call stack)
K. Synchronous — still on the call stack
B. process.nextTick — microtask after sync code
C. Promise.then — microtask after nextTick
D. setTimeout — timers phase
E. setImmediate — check phase
F. fs.readFile — poll phase (I/O callback)
G. nextTick inside I/O — microtask drain
H. Promise inside I/O — microtask drain
I. setImmediate inside I/O — check phase (guaranteed before timer)
J. setTimeout inside I/O — timers phase (next iteration)
```

Note: D and E may swap depending on system timing (outside I/O context), but F through J are always in that order.

---

## Event Loop Latency

Event loop latency is the delay between when a callback is scheduled and when it actually executes. High latency means the event loop is congested — some phase is taking too long.

```javascript
'use strict';

const { monitorEventLoopDelay } = require('node:perf_hooks');

// Create a histogram that samples event loop delay every 20ms
const histogram = monitorEventLoopDelay({ resolution: 20 });
histogram.enable();

// Simulate some work
let iterations = 0;
const interval = setInterval(() => {
  iterations++;

  // Simulate CPU-bound work blocking the event loop
  if (iterations === 5) {
    const end = Date.now() + 200; // Block for 200ms
    while (Date.now() < end) {} // Busy loop
    console.log('--- Blocked event loop for 200ms ---');
  }

  if (iterations >= 10) {
    clearInterval(interval);
    histogram.disable();

    console.log('\n=== Event Loop Delay Histogram ===\n');
    console.log(`Min:    ${(histogram.min / 1e6).toFixed(2)}ms`);
    console.log(`Max:    ${(histogram.max / 1e6).toFixed(2)}ms`);
    console.log(`Mean:   ${(histogram.mean / 1e6).toFixed(2)}ms`);
    console.log(`StdDev: ${(histogram.stddev / 1e6).toFixed(2)}ms`);
    console.log(`p50:    ${(histogram.percentile(50) / 1e6).toFixed(2)}ms`);
    console.log(`p99:    ${(histogram.percentile(99) / 1e6).toFixed(2)}ms`);
  }
}, 100);
```

In production, p99 event loop delay above 50ms warrants investigation, and above 200ms is an incident. The `monitorEventLoopDelay` API from `node:perf_hooks` is the standard tool for tracking this.

---

## When Does the Event Loop Exit?

The event loop continues running as long as there is pending work. It exits when:

1. There are no pending timers (`setTimeout`, `setInterval`)
2. There are no active handles (servers, sockets, file watchers)
3. There are no pending I/O operations
4. There are no queued `setImmediate` callbacks

```javascript
'use strict';

// This script exits immediately — no async work keeps the loop alive
console.log('Start');
// ... nothing queued ...
console.log('End');
// Process exits after these synchronous lines

// Compare with:
// setTimeout(() => console.log('Timer'), 1000);
// The timer handle keeps the loop alive for 1 second
```

You can force the event loop to stay alive or allow it to exit using `ref()` and `unref()`:

```javascript
'use strict';

// An unreffed timer does NOT keep the event loop alive
const timer = setTimeout(() => {
  console.log('This may never print');
}, 5000);

timer.unref(); // Tell the event loop: do not wait for this timer

console.log('Process will exit immediately because the timer is unreffed');
// The process exits right away — the unreffed timer does not keep it alive
```

This is useful for background tasks (metrics reporting, heartbeats) that should not prevent process shutdown.

---

## Phase Ordering Summary

| Order | Phase | Callback Source | Fires When |
|-------|-------|-----------------|------------|
| 1 | Timers | `setTimeout`, `setInterval` | Threshold elapsed |
| 2 | Pending | Deferred system errors | Previous tick deferred |
| 3 | Idle/Prepare | (internal) | Every tick |
| 4 | Poll | I/O callbacks (`fs`, `net`) | I/O completes |
| 5 | Check | `setImmediate` | After poll |
| 6 | Close | `socket.on('close')` | Handle destroyed |
| * | Microtasks | `nextTick`, Promises | Between every callback |

---

## Key Takeaways

- The event loop has six phases visited in a fixed order: timers, pending callbacks, idle/prepare, poll, check, close callbacks
- Microtasks (`process.nextTick` first, then Promises) drain between every phase and after every individual callback — they have the highest priority
- Inside an I/O callback, `setImmediate` always fires before `setTimeout(fn, 0)` because the check phase follows the poll phase in the same iteration
- Outside an I/O callback, the order of `setTimeout(fn, 0)` vs `setImmediate` is non-deterministic
- The poll phase is where the event loop spends most of its time — it blocks waiting for I/O events, bounded by the nearest pending timer

## Next

Now that you understand the event loop's phases, the next lesson zooms into the call stack, callback queue, and microtask queue to understand exactly how individual function calls flow through the system.
