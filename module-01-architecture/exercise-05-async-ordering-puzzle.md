# E05: Async Ordering Puzzle

## Objective

Solve 10 increasingly difficult async ordering challenges that mix `process.nextTick`, `queueMicrotask`, `Promise`, `setTimeout`, `setImmediate`, and I/O callbacks. Each puzzle tests a specific edge case in the event loop — the kind that causes production race conditions when developers rely on assumptions instead of understanding.

## Prerequisites

- Module 01 / Lesson 04 — Event Loop Deep Dive
- Module 01 / Lesson 05 — Call Stack, Callbacks, and Microtasks
- Module 01 / Exercise 01 — Map the Event Loop

## Instructions

1. Create a file called `async-puzzles.js`. For each puzzle, write your predicted output as a comment, then run to verify. Track your score: how many did you predict correctly on the first attempt?

2. **Puzzle 1 — The Classic Trio**

```javascript
'use strict';

setImmediate(() => console.log('1'));
setTimeout(() => console.log('2'), 0);
process.nextTick(() => console.log('3'));
```

Predict the output. Then explain why `3` always appears first, but `1` and `2` may swap.

3. **Puzzle 2 — Nested Ticks**

```javascript
'use strict';

process.nextTick(() => {
  console.log('A');
  process.nextTick(() => {
    console.log('B');
    process.nextTick(() => console.log('C'));
  });
});
setTimeout(() => console.log('D'), 0);
```

Predict: does `D` ever print before `C`?

4. **Puzzle 3 — Promise vs. nextTick Interleaving**

```javascript
'use strict';

process.nextTick(() => console.log('A'));
Promise.resolve().then(() => console.log('B'));
process.nextTick(() => console.log('C'));
Promise.resolve().then(() => console.log('D'));
queueMicrotask(() => console.log('E'));
```

Explain the sub-ordering within microtask queues.

5. **Puzzle 4 — I/O Callback Context**

```javascript
'use strict';

const fs = require('node:fs');

fs.readFile(__filename, () => {
  setImmediate(() => console.log('A'));
  setTimeout(() => console.log('B'), 0);
  process.nextTick(() => console.log('C'));
  queueMicrotask(() => console.log('D'));
  console.log('E');
});
```

Why is the order from inside an I/O callback different from the main module?

6. **Puzzle 5 — Timer Coalescing**

```javascript
'use strict';

setTimeout(() => console.log('A'), 0);
setTimeout(() => console.log('B'), 0);
setTimeout(() => console.log('C'), 0);
setImmediate(() => {
  setTimeout(() => console.log('D'), 0);
  setTimeout(() => console.log('E'), 0);
});
```

Do `D` and `E` fire in the same timer phase as `A`, `B`, `C`?

7. **Puzzle 6 — Async/Await Desugaring**

```javascript
'use strict';

async function first() {
  console.log('A');
  await null;
  console.log('B');
}

async function second() {
  console.log('C');
  await null;
  console.log('D');
}

first();
second();
process.nextTick(() => console.log('E'));
console.log('F');
```

Rewrite the `async` functions as explicit Promise chains to prove the ordering.

8. **Puzzle 7 — setImmediate Recursion vs. setTimeout Recursion**

```javascript
'use strict';

let immCount = 0;
let timeCount = 0;

function immediateLoop() {
  if (immCount >= 5) return;
  immCount++;
  console.log(`immediate-${immCount}`);
  setImmediate(immediateLoop);
}

function timerLoop() {
  if (timeCount >= 5) return;
  timeCount++;
  console.log(`timer-${timeCount}`);
  setTimeout(timerLoop, 0);
}

setImmediate(immediateLoop);
setTimeout(timerLoop, 0);
```

Do the loops interleave or does one complete first?

9. **Puzzle 8 — The nextTick Promise Trap**

```javascript
'use strict';

Promise.resolve()
  .then(() => {
    console.log('A');
    process.nextTick(() => console.log('B'));
  })
  .then(() => console.log('C'));

process.nextTick(() => {
  console.log('D');
  Promise.resolve().then(() => console.log('E'));
});
```

Does `B` fire before or after `C`? Explain the microtask sub-queue ordering.

10. **Puzzle 9 — Close vs. Check Phase Race**

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer();
server.listen(0, () => {
  const { port } = server.address();
  const socket = net.connect(port, () => {
    socket.destroy();
    setImmediate(() => console.log('A'));
    setTimeout(() => console.log('B'), 0);
  });
  socket.on('close', () => {
    console.log('C');
    server.close();
  });
});
```

Does the `close` event fire before or after `setImmediate`?

11. **Puzzle 10 — The Grand Finale**

```javascript
'use strict';

const fs = require('node:fs');

console.log('1');

setTimeout(() => {
  console.log('2');
  process.nextTick(() => console.log('3'));
  Promise.resolve().then(() => console.log('4'));
}, 0);

fs.readFile(__filename, () => {
  console.log('5');
  setImmediate(() => {
    console.log('6');
    process.nextTick(() => console.log('7'));
  });
  setTimeout(() => console.log('8'), 0);
  process.nextTick(() => console.log('9'));
});

setImmediate(() => {
  console.log('10');
  process.nextTick(() => console.log('11'));
});

process.nextTick(() => console.log('12'));
Promise.resolve().then(() => console.log('13'));
console.log('14');
```

Write the full predicted order. This puzzle combines every mechanism from the course. Create a summary table with columns: Puzzle, Predicted Order, Actual Order, Correct (Y/N), Key Insight.

## Break-Then-Harden Challenge

1. **Race condition.** Write a file-reading cache where check and write are separated by `await`. Two concurrent calls both miss the cache. Fix with a "pending promise" pattern — cache the Promise, not the result.

2. **Unhandled rejection timing.** Create a rejected Promise without `.catch()`. Prove the `unhandledRejection` event fires asynchronously. Show that adding `.catch()` in `process.nextTick` is too late, but synchronously works.

3. **Microtask starvation.** Write a recursive `Promise.resolve().then(...)` chain. Observe that timers and immediates never fire. Rewrite with `setImmediate` recursion and confirm interleaving.

## Expected Output

Puzzle 1: `3, 1 or 2, 2 or 1` (nextTick always first; timer vs. immediate is non-deterministic)

Puzzle 4: `E, C, D, A, B` (sync first, then microtasks, then check, then timers)

Puzzle 6: `A, C, F, E, B, D` (sync bodies run, then nextTick, then awaited continuations)

Puzzle 10 (deterministic portion): `1, 14, 12, 13, ...` (sync first, then nextTick, then promise; remaining order depends on I/O vs. timer race)

## Bonus

1. Build an auto-grading script that runs each puzzle in a `require('node:child_process').fork()`, captures stdout, and compares against expected output. Print a scorecard with pass/fail per puzzle.

## Hints

1. `process.nextTick` callbacks always drain before Promise/queueMicrotask callbacks within the same microtask checkpoint.
2. Inside an I/O callback, the loop has just exited the poll phase. The next phase is check (`setImmediate`), not timers — so `setImmediate` always beats `setTimeout(fn, 0)` from within I/O.
3. `async/await` desugars to Promises. `await null` is equivalent to `Promise.resolve(null).then(continuation)`. The code after `await` runs as a microtask.
4. Timers scheduled inside a `setImmediate` callback do not fire in the current timers phase — they fire in the **next** loop iteration's timers phase.
5. Each `setImmediate` callback runs one per check phase visit (unlike timers, which can batch). This is what allows `setImmediate` recursion to interleave with timers.
