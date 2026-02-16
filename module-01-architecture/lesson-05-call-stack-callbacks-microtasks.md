# Module 01 / Lesson 05 — Call Stack, Callback Queue & Microtasks

> The event loop determines *when* callbacks run. The call stack determines *how* they run. Understanding the interplay between the call stack (LIFO), the callback queue (FIFO), and the microtask queue (priority drain) is what separates developers who can predict async behavior from those who guess and pray. This lesson builds your mental model through increasingly complex execution order puzzles.

## Learning Objectives

- Explain how the call stack processes synchronous code using Last-In-First-Out (LIFO) semantics
- Distinguish between the callback queue (macrotasks) and the microtask queue
- Describe the priority relationship: `process.nextTick` > `queueMicrotask` / Promises > `setTimeout` / `setImmediate`
- Predict execution order for nested combinations of `process.nextTick`, `queueMicrotask`, `Promise.then`, `setTimeout`, and `setImmediate`
- Identify starvation scenarios where microtasks block the event loop

---

## The Call Stack

The call stack is a LIFO (Last-In, First-Out) data structure that tracks which function is currently executing. Every time a function is called, a new frame is pushed onto the stack. When the function returns, its frame is popped off.

```javascript
'use strict';

function first() {
  console.log('first — start');
  second();
  console.log('first — end');
}

function second() {
  console.log('  second — start');
  third();
  console.log('  second — end');
}

function third() {
  console.log('    third — executing');
}

first();

// Output:
// first — start
//   second — start
//     third — executing
//   second — end
// first — end

// Call stack at the moment third() runs:
// ┌──────────┐
// │  third() │  ← top of stack (currently executing)
// │ second() │
// │  first() │
// │  <main>  │  ← bottom of stack (module-level code)
// └──────────┘
```

Node.js is single-threaded, so there is exactly **one call stack**. If a function is on the stack, nothing else can run. This is why synchronous CPU-bound work blocks everything — the call stack is occupied.

### Stack Overflow

The call stack has a finite size. Exceeding it throws a `RangeError`:

```javascript
'use strict';

function recurse(depth) {
  // Each call adds a frame to the stack
  return recurse(depth + 1);
}

try {
  recurse(0);
} catch (err) {
  console.log(err.message);
  // "Maximum call stack size exceeded"
  // Typical limit: ~10,000–15,000 frames depending on V8 version
}
```

This is why you should convert deep recursion to iteration or use `process.nextTick` / `setImmediate` to break the recursion across event loop ticks.

---

## The Callback Queue (Macrotask Queue)

When an async operation completes — a timer fires, a file read finishes, a network response arrives — its callback is placed on the **callback queue** (also called the macrotask queue or task queue). The event loop processes these callbacks according to its phase ordering.

The callback queue is FIFO (First-In, First-Out) within each phase. Callbacks are only pulled from the queue when the call stack is empty.

```javascript
'use strict';

console.log('1. Synchronous — on the call stack now');

setTimeout(() => {
  console.log('4. setTimeout callback — pulled from callback queue');
}, 0);

console.log('2. Still synchronous — stack not empty yet');

setTimeout(() => {
  console.log('5. Second setTimeout — FIFO within timers phase');
}, 0);

console.log('3. Last synchronous line — after this, stack empties');

// Output:
// 1. Synchronous — on the call stack now
// 2. Still synchronous — stack not empty yet
// 3. Last synchronous line — after this, stack empties
// 4. setTimeout callback — pulled from callback queue
// 5. Second setTimeout — FIFO within timers phase
```

Even though `setTimeout(fn, 0)` says "0 milliseconds," the callback cannot run until the call stack is empty and the event loop reaches the timers phase.

---

## The Microtask Queue

Microtasks are callbacks that should run as soon as possible — after the current operation, before the event loop continues to the next phase or callback. There are two microtask queues in Node.js, drained in this order:

1. **`process.nextTick` queue** — drains completely
2. **Promise microtask queue** (`queueMicrotask`, `.then()`, `await` continuations) — drains completely

This drain happens:
- After every synchronous block of code finishes
- Between every event loop phase
- After every individual macrotask callback

```javascript
'use strict';

console.log('1. Synchronous');

process.nextTick(() => {
  console.log('2. process.nextTick — first microtask queue');
});

queueMicrotask(() => {
  console.log('3. queueMicrotask — second microtask queue');
});

Promise.resolve().then(() => {
  console.log('4. Promise.then — same queue as queueMicrotask');
});

process.nextTick(() => {
  console.log('5. Second nextTick — still draining first queue');
});

console.log('6. Still synchronous');

// Output:
// 1. Synchronous
// 6. Still synchronous
// 2. process.nextTick — first microtask queue
// 5. Second nextTick — still draining first queue
// 3. queueMicrotask — second microtask queue
// 4. Promise.then — same queue as queueMicrotask
```

Notice that both `nextTick` callbacks run before any Promise callbacks, regardless of registration order. The `nextTick` queue always drains first.

---

## process.nextTick vs queueMicrotask vs setImmediate

These three functions are the most commonly confused async scheduling mechanisms in Node.js. Here is the definitive comparison:

| Function | Queue | When It Runs | Use Case |
|----------|-------|-------------|----------|
| `process.nextTick(fn)` | nextTick microtask queue | After current operation, before everything else | Error handling, API consistency (ensure callback is async) |
| `queueMicrotask(fn)` | Promise microtask queue | After nextTick drains, before next macrotask | Standard microtask scheduling (ECMAScript standard) |
| `setImmediate(fn)` | Check phase (macrotask) | After I/O callbacks, in the check phase | Yielding to the event loop for I/O processing |

```javascript
'use strict';

// The ordering proof

setImmediate(() => {
  console.log('5. setImmediate — check phase (macrotask)');
});

setTimeout(() => {
  console.log('4. setTimeout — timers phase (macrotask)');
}, 0);

queueMicrotask(() => {
  console.log('3. queueMicrotask — Promise microtask queue');
});

process.nextTick(() => {
  console.log('2. process.nextTick — nextTick microtask queue');
});

console.log('1. Synchronous — call stack');

// Output:
// 1. Synchronous — call stack
// 2. process.nextTick — nextTick microtask queue
// 3. queueMicrotask — Promise microtask queue
// 4. setTimeout — timers phase (macrotask)
// 5. setImmediate — check phase (macrotask)
```

The priority ladder is clear: synchronous > nextTick > Promise/queueMicrotask > setTimeout > setImmediate.

(Note: setTimeout and setImmediate order may vary outside I/O callbacks, as discussed in Lesson 04.)

---

## Nested Microtasks

When a microtask schedules another microtask, the new microtask is added to the same queue and drained in the same cycle. This means microtasks can starve the event loop.

```javascript
'use strict';

// Nested nextTick — each one fires before any macrotask

process.nextTick(() => {
  console.log('A. nextTick 1');
  process.nextTick(() => {
    console.log('B. nextTick 2 (nested inside A)');
    process.nextTick(() => {
      console.log('C. nextTick 3 (nested inside B)');
    });
  });
});

setTimeout(() => {
  console.log('D. setTimeout — cannot run until ALL nextTicks drain');
}, 0);

// Output:
// A. nextTick 1
// B. nextTick 2 (nested inside A)
// C. nextTick 3 (nested inside B)
// D. setTimeout — cannot run until ALL nextTicks drain
```

The setTimeout callback at D cannot fire until the entire nextTick chain finishes. If the chain were infinite, the setTimeout would never fire — this is **starvation**.

---

## Starvation: The Microtask Trap

Recursive microtask scheduling can freeze the event loop. No I/O callbacks, no timers, no setImmediate — nothing else runs until the microtask queue is empty.

```javascript
'use strict';

// WARNING: This creates a microtask that never ends.
// The event loop is permanently starved.

let count = 0;

function starvingNextTick() {
  count++;
  if (count <= 1_000_000) {
    process.nextTick(starvingNextTick);
  } else {
    console.log(`Finally done after ${count} nextTick calls`);
  }
}

starvingNextTick();

// This timer will not fire until 1,000,000 nextTick calls complete
setTimeout(() => {
  console.log('setTimeout — I had to wait for a million microtasks');
}, 0);

// This is why setImmediate is preferred for recursive scheduling:
// it yields to the event loop between iterations
```

Compare with the safe alternative using `setImmediate`:

```javascript
'use strict';

let count = 0;

function safeRecursion() {
  count++;
  if (count <= 100) {
    // setImmediate yields to the event loop — I/O and timers can fire
    setImmediate(safeRecursion);
  } else {
    console.log(`Done after ${count} iterations`);
  }
}

safeRecursion();

setTimeout(() => {
  console.log(`Timer fired at count=${count} — event loop was not starved`);
}, 10);
```

**Rule:** Use `setImmediate` for recursive async patterns. Reserve `process.nextTick` for cases where you genuinely need to run before I/O.

---

## Execution Order Puzzles

### Puzzle 1: Mixed Scheduling

```javascript
'use strict';

console.log('1');

setTimeout(() => console.log('2'), 0);
setImmediate(() => console.log('3'));

Promise.resolve().then(() => console.log('4'));
process.nextTick(() => console.log('5'));

console.log('6');

// Guaranteed output: 1, 6, 5, 4, then 2 and 3 in either order
// (2 and 3 order is non-deterministic outside I/O context)
```

### Puzzle 2: Nested Inside setTimeout

```javascript
'use strict';

setTimeout(() => {
  console.log('A');

  process.nextTick(() => console.log('B'));
  Promise.resolve().then(() => console.log('C'));

  setTimeout(() => console.log('D'), 0);
  setImmediate(() => console.log('E'));

  console.log('F');
}, 0);

// Output: A, F, B, C, E, D
// A and F are synchronous within the timer callback
// B (nextTick) and C (Promise) drain before next macrotask
// E (setImmediate/check) before D (setTimeout/timers) because
// we are inside a timer callback — check phase comes before
// the next timers phase
```

### Puzzle 3: I/O Context Ordering

```javascript
'use strict';

const fs = require('node:fs');

fs.readFile(__filename, () => {
  // Inside I/O callback (poll phase)
  console.log('1. I/O callback');

  setImmediate(() => {
    console.log('3. setImmediate (check phase)');

    process.nextTick(() => {
      console.log('4. nextTick inside setImmediate');
    });
  });

  process.nextTick(() => {
    console.log('2. nextTick (microtask drain after I/O callback)');
  });

  setTimeout(() => {
    console.log('5. setTimeout (timers phase — next iteration)');
  }, 0);
});

// Output: 1, 2, 3, 4, 5
```

### Puzzle 4: Promise Chain vs nextTick Chain

```javascript
'use strict';

process.nextTick(() => {
  console.log('nextTick 1');
  Promise.resolve().then(() => console.log('promise inside nextTick'));
});

Promise.resolve().then(() => {
  console.log('promise 1');
  process.nextTick(() => console.log('nextTick inside promise'));
});

process.nextTick(() => {
  console.log('nextTick 2');
});

Promise.resolve().then(() => {
  console.log('promise 2');
});

// Output:
// nextTick 1
// nextTick 2
// promise inside nextTick  ← queued by nextTick 1, runs after nextTick queue drains
// promise 1
// promise 2
// nextTick inside promise  ← queued by promise 1, runs in next microtask cycle
```

Wait — this one is tricky. After all initial nextTicks drain, the Promise microtask queue runs. But a Promise callback can queue a new nextTick, which goes into the *next* microtask drain cycle. The interleaving depends on whether Node.js re-checks the nextTick queue after Promise microtasks. In modern Node.js (v11+), nextTick and Promise queues alternate: after each nextTick drain, Promises drain, then if new nextTicks were added, they drain again.

---

## Visualizing the Flow

Here is a mental model for how the runtime processes your code:

```
┌──────────────────────────────────────────────────────┐
│                    CALL STACK                         │
│  Synchronous code executes here. Nothing else runs   │
│  until the stack is empty.                            │
└────────────────────┬─────────────────────────────────┘
                     │ (stack empties)
                     ▼
┌──────────────────────────────────────────────────────┐
│              MICROTASK DRAIN                          │
│  1. Drain ALL process.nextTick callbacks              │
│  2. Drain ALL Promise / queueMicrotask callbacks      │
│  3. If new microtasks were added, repeat              │
└────────────────────┬─────────────────────────────────┘
                     │ (microtask queues empty)
                     ▼
┌──────────────────────────────────────────────────────┐
│              EVENT LOOP PHASE                         │
│  Run ONE callback from the current phase              │
└────────────────────┬─────────────────────────────────┘
                     │ (callback returns)
                     ▼
                   (back to MICROTASK DRAIN)
```

This cycle repeats for every callback in every phase. The microtask drain is the checkpoint that runs between every macrotask.

---

## When to Use Which

| Scenario | Use | Why |
|----------|-----|-----|
| Ensure callback fires asynchronously (API consistency) | `process.nextTick` | Runs before any I/O, guarantees async behavior |
| Standard microtask scheduling | `queueMicrotask` | ECMAScript standard, same as Promise microtasks |
| Yield to I/O between recursive steps | `setImmediate` | Prevents starvation, allows I/O callbacks to fire |
| Delay execution by time | `setTimeout` | Timer-based, minimum 1ms resolution |
| Run on every event loop tick | `setInterval` | Recurring timer (but consider `setImmediate` for precision) |

```javascript
'use strict';

// Pattern: Ensure a callback is always async
// (Even if the data is available synchronously)

function fetchData(key, callback) {
  const cache = { user: 'Alice' };

  if (cache[key]) {
    // BAD: calling callback synchronously sometimes
    // callback(null, cache[key]);

    // GOOD: always async via process.nextTick
    process.nextTick(() => callback(null, cache[key]));
  } else {
    // Simulate async fetch
    setTimeout(() => callback(null, 'fetched'), 100);
  }
}

// The caller can always rely on the callback being async
fetchData('user', (err, data) => {
  console.log(`Got: ${data}`); // Always fires after the current synchronous code
});

console.log('This always prints before the callback');
```

---

## Key Takeaways

- The call stack is a LIFO structure that processes synchronous code — nothing else can run while the stack is occupied
- The callback queue holds macrotasks (timers, I/O, setImmediate); the microtask queue holds nextTick and Promise callbacks
- Microtask priority order: `process.nextTick` drains first, then `queueMicrotask` / Promises drain — both queues empty completely before any macrotask runs
- Recursive `process.nextTick` or `queueMicrotask` can starve the event loop — use `setImmediate` for recursive patterns that should yield to I/O
- Use `process.nextTick` for API consistency (ensuring callbacks are always async) and `setImmediate` for yielding to the event loop between work chunks

## Next

With the event loop and execution model thoroughly mapped, the next lesson shifts to the module system — how `require()` finds, loads, caches, and exports code, and how ESM changes the picture.
