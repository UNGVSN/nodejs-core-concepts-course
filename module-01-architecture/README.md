# Module 01 — Node.js Architecture & the Event Loop

> Before you write a single line of server code, you need to understand what happens beneath it. This module tears open the hood of Node.js — the V8 engine that compiles your JavaScript, the libuv library that talks to the operating system, and the event loop that orchestrates everything in between. By the end, you will be able to predict exactly when any piece of asynchronous code will execute, and why.

---

## Learning Objectives

- Explain how Node.js combines V8, libuv, and C++ bindings into a single runtime
- Trace JavaScript execution through the call stack, callback queue, and microtask queue
- Identify every phase of the event loop and predict the execution order of timers, I/O callbacks, `setImmediate`, and `process.nextTick`
- Compare CommonJS and ESM module systems, including resolution algorithms
- Benchmark V8 garbage collection behavior under memory pressure
- Articulate how Node.js differs architecturally from Deno and Bun

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| 01 | [What Is Node.js](lesson-01-what-is-nodejs.md) | Runtime vs language, V8 + libuv, single-threaded event-driven architecture |
| 02 | [The V8 Engine](lesson-02-v8-engine.md) | JIT compilation, hidden classes, inline caching, garbage collection |
| 03 | [libuv and Asynchronous I/O](lesson-03-libuv-async-io.md) | Thread pool, OS async primitives, the bridge between JS and kernel |
| 04 | [Event Loop Deep Dive](lesson-04-event-loop-deep-dive.md) | Phases: timers, pending callbacks, idle/prepare, poll, check, close |
| 05 | [Call Stack, Callback Queue & Microtasks](lesson-05-call-stack-callbacks-microtasks.md) | Execution order, `process.nextTick`, `queueMicrotask`, `setImmediate` |
| 06 | [Module System](lesson-06-module-system.md) | CommonJS `require()` resolution, `module.exports`, ESM `import`/`export`, `.mjs` |
| 07 | [Global Objects & the REPL](lesson-07-global-objects-repl.md) | `process`, `global`, `Buffer`, `console`, `__dirname`, `__filename` |
| 08 | [Node.js vs Other Runtimes](lesson-08-nodejs-vs-runtimes.md) | Deno and Bun comparison — permissions, TS support, compatibility |

---

## Exercises

| # | Exercise | Description |
|---|----------|-------------|
| 01 | [Map the Event Loop](exercise-01-map-the-event-loop.md) | Trace async code through every event loop phase and predict output order |
| 02 | [Build an Event Loop Visualizer](exercise-02-event-loop-visualizer.md) | Create a script that logs phase transitions using timers, I/O, and `setImmediate` |
| 03 | [Module Resolution Detective](exercise-03-module-resolution-detective.md) | Instrument `require()` to trace the full resolution path for every loaded module |
| 04 | [GC Pressure Benchmark](exercise-04-gc-pressure-benchmark.md) | Generate controlled memory pressure and measure GC pauses with `--trace-gc` |
| 05 | [Async Ordering Puzzle](exercise-05-async-ordering-puzzle.md) | Solve 10 async ordering challenges mixing `nextTick`, microtasks, and timers |

---

## Progressive Project — Step 01: Event-Driven Request Dispatcher

This is the first step of the course-spanning progressive project: **Build Your Own Production HTTP Server**.

In this step you build the foundational request dispatcher — a pure event-loop-aware routing engine that does not yet use the `node:http` module. Instead, you wire together `EventEmitter`, `process.nextTick`, and `setImmediate` to create a dispatcher that:

1. **Accepts route registrations** as `(method, path, handler)` tuples stored in a `Map`
2. **Dispatches synthetic request objects** through the event loop, proving you understand phase ordering
3. **Logs phase timing** for every dispatched request — which phase handled it and how long it took
4. **Handles 404s** via a default handler registered at the end of the microtask queue

You will revisit and extend this dispatcher when you add EventEmitter middleware (Step 02), Buffer-based body parsing (Step 03), file-system static serving (Step 04), and stream-backed responses (Step 05) — all the way through to the final production server.

```javascript
const { EventEmitter } = require('node:events');

class RequestDispatcher extends EventEmitter {
  #routes = new Map();

  register(method, path, handler) {
    this.#routes.set(`${method}:${path}`, handler);
  }

  dispatch(method, path, body = null) {
    const key = `${method}:${path}`;
    const handler = this.#routes.get(key);

    if (handler) {
      // Dispatch in check phase (setImmediate)
      setImmediate(() => {
        this.emit('request', { method, path, body });
        handler({ method, path, body });
      });
    } else {
      // 404 via nextTick — runs before I/O callbacks
      process.nextTick(() => {
        this.emit('notFound', { method, path });
      });
    }
  }
}
```

**Deliverable:** A working `RequestDispatcher` class with at least 5 registered routes, phase-aware dispatch logging, and a test script that proves correct event loop ordering.

---

## Key Takeaways

After completing this module you will have a mental model of every layer in the Node.js architecture — from V8 bytecode compilation down to the libuv thread pool making system calls. This foundation makes everything else in the course (streams, networking, child processes) predictable rather than magical.

---

## Next

[Module 02 — EventEmitter & Event-Driven Patterns](../module-02-eventemitter/README.md)
