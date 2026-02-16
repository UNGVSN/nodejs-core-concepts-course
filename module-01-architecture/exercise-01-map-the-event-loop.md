# E01: Map the Event Loop

## Objective

Trace asynchronous code through every event loop phase and predict the exact output order before running it. This exercise transforms your mental model of the event loop from "it runs callbacks sometime" into a precise phase-by-phase understanding you can reason about under pressure.

## Prerequisites

- Module 01 / Lesson 04 — Event Loop Deep Dive
- Module 01 / Lesson 05 — Call Stack, Callbacks, and Microtasks

## Instructions

1. Create a file called `event-loop-map.js`. Add `'use strict';` at the top.

2. For each of the 10 puzzles below, **write your predicted output order in a comment** before running the code. Then run the snippet with `node event-loop-map.js` and compare.

3. **Puzzle 1 — Timers vs. Microtasks**

```javascript
'use strict';

setTimeout(() => console.log('A'), 0);
Promise.resolve().then(() => console.log('B'));
process.nextTick(() => console.log('C'));
console.log('D');
```

4. **Puzzle 2 — Nested Microtasks**

```javascript
'use strict';

process.nextTick(() => {
  console.log('A');
  process.nextTick(() => console.log('B'));
});

Promise.resolve().then(() => {
  console.log('C');
  Promise.resolve().then(() => console.log('D'));
});

console.log('E');
```

5. **Puzzle 3 — setImmediate vs. setTimeout**

```javascript
'use strict';

setTimeout(() => console.log('A'), 0);
setImmediate(() => console.log('B'));
```

Write a comment explaining why the order is **non-deterministic** when called from the main module. Then wrap both calls inside a `require('node:fs').readFile(__filename, () => { ... })` callback and predict the new order.

6. **Puzzle 4 — I/O Callback Ordering**

```javascript
'use strict';

const fs = require('node:fs');

fs.readFile(__filename, () => {
  setTimeout(() => console.log('A'), 0);
  setImmediate(() => console.log('B'));
  process.nextTick(() => console.log('C'));
  Promise.resolve().then(() => console.log('D'));
});
```

7. **Puzzle 5 — nextTick Starvation**

```javascript
'use strict';

function flood(count) {
  if (count <= 0) return;
  process.nextTick(() => {
    console.log(`tick ${count}`);
    flood(count - 1);
  });
}

flood(5);
setTimeout(() => console.log('timeout fires'), 0);
setImmediate(() => console.log('immediate fires'));
```

Predict: does the timeout or immediate ever fire before all ticks complete? Explain why.

8. **Puzzle 6 — queueMicrotask vs. nextTick**

```javascript
'use strict';

process.nextTick(() => console.log('A'));
queueMicrotask(() => console.log('B'));
process.nextTick(() => console.log('C'));
queueMicrotask(() => console.log('D'));
```

9. **Puzzle 7 — Timers with Different Delays**

```javascript
'use strict';

setTimeout(() => console.log('A'), 1);
setTimeout(() => console.log('B'), 0);
setImmediate(() => console.log('C'));
process.nextTick(() => console.log('D'));
```

10. **Puzzle 8 — Promise Chain Depth**

```javascript
'use strict';

setTimeout(() => console.log('A'), 0);

Promise.resolve()
  .then(() => console.log('B'))
  .then(() => console.log('C'))
  .then(() => console.log('D'));

process.nextTick(() => console.log('E'));
console.log('F');
```

11. **Puzzle 9 — Mixed I/O and Timers**

```javascript
'use strict';

const fs = require('node:fs');

console.log('start');

fs.readFile(__filename, () => {
  console.log('file read');
});

setTimeout(() => console.log('timeout 1'), 0);
setImmediate(() => console.log('immediate 1'));

process.nextTick(() => {
  console.log('nextTick');
  setTimeout(() => console.log('timeout 2'), 0);
});

console.log('end');
```

12. **Puzzle 10 — Close Callbacks**

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer();
server.listen(0, () => {
  const addr = server.address();
  const socket = net.connect(addr.port, () => {
    console.log('connected');
    socket.destroy();
  });

  socket.on('close', () => {
    console.log('close callback');
    server.close(() => console.log('server closed'));
  });

  setImmediate(() => console.log('immediate'));
  setTimeout(() => console.log('timeout'), 0);
});
```

13. Create a summary table at the bottom of your file mapping each puzzle number to the correct output order and which event loop phase or microtask queue triggered each line.

## Break-Then-Harden Challenge

1. **Starve the loop.** Replace Puzzle 5's `flood(5)` with `flood(100000)`. Observe how the timer and immediate are delayed indefinitely. Then rewrite `flood` using `setImmediate` instead of `process.nextTick` and verify that timers can now interleave. Explain the difference.

2. **Blow the stack.** Call `process.nextTick` recursively with no base case. Observe the `Maximum call stack size exceeded` error (or indefinite starvation depending on Node.js version). Explain why `setImmediate` does not cause the same problem.

3. **Timer precision trap.** Run Puzzle 3 in a tight loop 1,000 times and tally how often `setTimeout` fires before `setImmediate`. Then wrap them in an I/O callback and confirm the order becomes deterministic. Explain the role of the poll phase.

## Expected Output

Puzzle 1:
```
D
C
B
A
```

Puzzle 4:
```
C
D
B
A
```

Puzzle 6:
```
A
C
B
D
```

Puzzle 8:
```
F
E
B
C
D
A
```

(Other puzzles have partial non-determinism or depend on system load — your summary table should document which and why.)

## Bonus

1. Write a Puzzle 11 that demonstrates the difference between `process.nextTick` and `queueMicrotask` when called from inside a `Promise.then()` callback. Predict whether nextTick fires before or after the next chained `.then()`.

2. Use `perf_hooks` to measure the actual delay of `setTimeout(fn, 0)` across 1,000 iterations and compute the mean, median, and p99 latency. Compare with `setImmediate`.

## Hints

1. The microtask queue drains completely between **every phase transition** and after **every individual callback**.
2. `process.nextTick` callbacks always drain before Promise microtasks within the same microtask checkpoint.
3. Inside an I/O callback, `setImmediate` always fires before `setTimeout(fn, 0)` because the check phase follows the poll phase.
4. `setTimeout(fn, 0)` is internally clamped to `setTimeout(fn, 1)` — this 1ms delay is what makes the timer-vs-immediate race non-deterministic from the main module.
5. Close callbacks (like `socket.on('close')`) run in their own phase, which is the last phase before the loop restarts.
