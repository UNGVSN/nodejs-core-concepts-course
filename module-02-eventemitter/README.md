# Module 02 — EventEmitter & Event-Driven Patterns

> Everything in Node.js that does something interesting is an EventEmitter. HTTP servers emit `request` events, streams emit `data` events, and child processes emit `exit` events. This module teaches you how EventEmitter works from the inside out — its listener storage, its emission algorithm, its memory traps — so you can build your own event-driven architectures with confidence.

---

## Learning Objectives

- Explain how `EventEmitter` stores and invokes listeners internally
- Register, emit, and remove event listeners using the full API surface (`on`, `once`, `off`, `removeAllListeners`, `prependListener`)
- Handle error events correctly and understand why unhandled error events crash the process
- Build custom classes that extend `EventEmitter` with domain-specific events
- Identify where `EventEmitter` appears inside Node.js core modules (streams, HTTP, `fs.watch`, net)
- Implement the Observer pattern and Pub/Sub pattern using only `node:events`

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| 01 | [EventEmitter Internals](lesson-01-eventemitter-internals.md) | How listeners are stored in a `Map`, emission order guarantees, and the `_events` object |
| 02 | [Registering, Emitting & Removing Events](lesson-02-registering-emitting-removing.md) | Full API walkthrough — `on`, `once`, `off`, `emit`, `removeAllListeners`, `prependListener`, `eventNames` |
| 03 | [Error Events & Edge Cases](lesson-03-error-events-edge-cases.md) | The special `error` event, `captureRejections`, max listeners warning, and `newListener`/`removeListener` events |
| 04 | [Building Custom EventEmitters](lesson-04-custom-eventemitters.md) | Extending `EventEmitter` for domain-specific logic — typed events, validation, lifecycle hooks |
| 05 | [EventEmitter in Node.js Core](lesson-05-eventemitter-in-node-core.md) | How streams, `net.Server`, `http.Server`, `fs.watch`, and `child_process` inherit from EventEmitter |
| 06 | [Observer Pattern & Pub/Sub](lesson-06-observer-pattern-pubsub.md) | Implementing Observer and Pub/Sub from scratch, then comparing with EventEmitter's built-in behavior |

---

## Exercises

| # | Exercise | Description |
|---|----------|-------------|
| 01 | [Build a Job Queue](exercise-01-job-queue.md) | Create an event-driven job queue that emits `enqueue`, `processing`, `completed`, and `failed` events |
| 02 | [Event-Driven Logger](exercise-02-event-driven-logger.md) | Build a logger that emits structured log events, supports multiple transports, and respects log levels |
| 03 | [Memory Leak Hunter](exercise-03-memory-leak-hunter.md) | Detect and fix listener leaks using `emitter.listenerCount()`, the `newListener` event, and heap snapshots |
| 04 | [Typed Event System](exercise-04-typed-event-system.md) | Build an EventEmitter subclass that validates event names and payload shapes at emission time |

---

## Progressive Project — Step 02: EventEmitter-Based Middleware Chain

Building on the `RequestDispatcher` from Step 01, you now add a middleware pipeline powered entirely by EventEmitter.

Each middleware is a listener on the `'request'` event. Middlewares execute in registration order and can:

1. **Modify the request context** — add headers, parse query strings, attach metadata
2. **Short-circuit the chain** — emit an `'error'` event to skip remaining middleware and jump to error handling
3. **Pass control explicitly** — call a `next()` function to hand off to the next listener
4. **Emit lifecycle events** — `'middleware:enter'`, `'middleware:exit'`, `'middleware:error'` for observability

```javascript
const { EventEmitter } = require('node:events');

class MiddlewareChain extends EventEmitter {
  #stack = [];

  use(name, fn) {
    this.#stack.push({ name, fn });
    return this;
  }

  async run(context) {
    let index = 0;

    const next = async () => {
      if (index >= this.#stack.length) return;
      const { name, fn } = this.#stack[index++];
      this.emit('middleware:enter', name);
      try {
        await fn(context, next);
        this.emit('middleware:exit', name);
      } catch (err) {
        this.emit('middleware:error', name, err);
      }
    };

    await next();
  }
}
```

**Deliverable:** A `MiddlewareChain` class integrated into the `RequestDispatcher` with at least 4 middleware functions (logging, timing, auth check, body validator), lifecycle event logging, and error short-circuiting.

---

## Key Takeaways

After completing this module you will see EventEmitter everywhere in Node.js — because it *is* everywhere. You will know how to build decoupled, event-driven systems where components communicate through events rather than direct function calls, and you will know exactly when that pattern helps and when it hinders.

---

## Next

[Module 03 — Buffers & Binary Data](../module-03-buffers/README.md)
