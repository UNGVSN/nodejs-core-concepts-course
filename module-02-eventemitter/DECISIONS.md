# Module 02 — EventEmitter Decisions

> Production trade-offs for event-driven architectures in Node.js. These decisions come up every time you build a system around EventEmitter — get them wrong and you get silent failures, memory leaks, or unhandled crashes.

---

## Decision 1: EventEmitter vs Callbacks vs Promises

**Decision:** When to use EventEmitter, when to use callbacks, and when to use Promises/async-await.

**Context:** Node.js offers three async communication patterns. Callbacks are the simplest. Promises represent a single future value. EventEmitter handles multiple events over time. Choosing the wrong abstraction leads to awkward APIs and maintenance pain.

**Trade-offs:**
- Callbacks: simplest for one-shot operations; no overhead; callback hell with nesting; no built-in error propagation beyond `(err, result)` convention
- Promises/async-await: perfect for single asynchronous results; composable with `Promise.all`, `Promise.race`; built-in error propagation via rejection; cannot represent repeated events cleanly
- EventEmitter: natural for streams of events (data arriving, connections opening/closing, state changes); listeners can be added/removed dynamically; no backpressure by default; memory leak risk from forgotten listeners
- Mixing patterns (e.g., a function that returns a Promise AND is an EventEmitter) creates confusing APIs

**Recommendation:** Use Promises for request/response operations (file reads, HTTP calls, DB queries). Use EventEmitter for ongoing event streams (server connections, file watchers, process signals). Use callbacks only when extending legacy APIs. Never mix — pick one pattern per API surface.

---

## Decision 2: captureRejections — Enable or Disable

**Decision:** Whether to enable `captureRejections` on EventEmitter instances that use async listeners.

**Context:** When an `async` function is registered as an event listener, a rejected Promise inside it will not automatically trigger the `'error'` event — it becomes an unhandled rejection. `captureRejections: true` (or `EventEmitter.captureRejections = true` globally) catches these and routes them to the `'error'` event.

**Trade-offs:**
- Enabled: async listener rejections become `'error'` events; consistent error handling; slight performance overhead per emission; global setting affects all emitters including third-party code
- Disabled (default): async errors must be caught manually inside each listener; easy to forget; unhandled rejections crash the process in Node.js 15+
- Per-instance setting is safer than global — apply only where you have async listeners
- Alternative: wrap every async listener in try/catch manually — verbose but explicit

**Recommendation:** Enable `captureRejections` per-instance on emitters that accept async listeners. Do not set it globally — you cannot predict how third-party emitters will behave. Always register an `'error'` event handler on any emitter where `captureRejections` is enabled.

---

## Decision 3: maxListeners in Production

**Decision:** What to set `maxListeners` to, and whether the default of 10 is appropriate.

**Context:** EventEmitter defaults `maxListeners` to 10. Exceeding this threshold emits a warning to stderr — it does not throw. The warning exists to catch accidental listener leaks, which are one of the most common memory leaks in Node.js applications.

**Trade-offs:**
- Default (10): catches leaks early; false positives in legitimate high-listener scenarios (e.g., connection pools, fan-out patterns)
- Increased (50-100): accommodates legitimate use cases; masks real leaks; warnings become less useful
- `setMaxListeners(0)` or `Infinity`: disables the warning entirely; memory leaks go undetected until the process runs out of memory
- Dynamic adjustment: set to expected count + buffer (e.g., pool size + 5); requires knowing your listener count at design time

**Recommendation:** Never set `maxListeners` to 0 or Infinity in production. If you need more than 10 listeners, set it to the exact expected count plus a small buffer (e.g., `setMaxListeners(pool.size + 5)`). If you are hitting the warning and do not know why, you have a leak — investigate before increasing the limit. Log the warning with a stack trace in production using `process.on('warning', ...)`.

---

## Decision 4: once() vs on() Listener Patterns

**Decision:** When to use `emitter.once()` vs `emitter.on()` for registering listeners.

**Context:** `on()` registers a persistent listener. `once()` registers a listener that auto-removes after the first emission. The `events.once()` static method returns a Promise that resolves on the first emission — useful for awaiting a single event.

**Trade-offs:**
- `on()`: required for ongoing events (stream `data`, server `request`); must be manually removed to prevent leaks; simple mental model
- `once()`: perfect for initialization events (`'listening'`, `'connect'`, `'ready'`); auto-cleanup prevents leaks; useless for repeated events
- `events.once(emitter, 'event')`: awaitable; great for startup sequences; rejects on `'error'` event — which is usually what you want but can surprise if your emitter emits `'error'` for non-fatal reasons
- Forgetting to use `once()` for one-shot events is a top source of listener leaks

**Recommendation:** Default to `once()` unless you explicitly need repeated notifications. Use the static `events.once()` for awaiting startup/shutdown events in async functions. Reserve `on()` for genuinely repeated events (incoming data, periodic ticks, connection events on servers). Always pair `on()` with a corresponding cleanup path (`off()` or `removeListener`).

---

## Decision 5: Error Event Handling Strategies

**Decision:** How to handle the special `'error'` event — at the instance level, globally, or both.

**Context:** EventEmitter has a unique behavior: if an `'error'` event is emitted and no listener is registered for it, Node.js throws the error as an uncaught exception, crashing the process. This is intentional — it prevents silent failures. But it means every EventEmitter in your application is a potential crash vector.

**Trade-offs:**
- Per-instance `'error'` handler: precise control; you decide what to log, retry, or ignore; must remember to add it to every emitter
- `process.on('uncaughtException')` catch-all: prevents crashes; masks bugs; process state may be corrupted after an uncaught exception — not safe to continue serving requests
- Domain-level error handling (deprecated): do not use
- `EventTarget` (the Web API alternative in Node.js): does not have the special error-crash behavior — unhandled errors are silently swallowed

**Recommendation:** Register an `'error'` handler on every EventEmitter you create or receive. Make this a code review checklist item. Use `process.on('uncaughtException')` only for logging and graceful shutdown — never to "recover" and continue. For critical emitters (servers, database connections), the error handler should trigger a structured shutdown: stop accepting new work, drain in-flight requests, then exit.

---

## Decision 6: EventEmitter vs EventTarget

**Decision:** Whether to use Node.js's `EventEmitter` or the Web-standard `EventTarget` API.

**Context:** Node.js 15+ includes `EventTarget`, the browser-standard event API. Some newer Node.js APIs (like `AbortController`) use `EventTarget` internally. The two systems are not interchangeable — they have different APIs, different semantics, and different performance characteristics.

**Trade-offs:**
- `EventEmitter`: Node.js native; faster (benchmarks show 2-5x); richer API (`once`, `prependListener`, `listenerCount`, `eventNames`); the `'error'` crash behavior is a feature for reliability
- `EventTarget`: Web standard; portable code between Node.js and browsers; `addEventListener`/`removeEventListener` API; no special error handling — unhandled errors are silent; supports `AbortSignal` natively
- Mixing both in one codebase creates confusion about which pattern to use where
- `EventTarget` does not support `emit()` — you must construct `Event` objects manually

**Recommendation:** Use `EventEmitter` for server-side Node.js code. Use `EventTarget` only when writing isomorphic code that must run in both Node.js and the browser, or when interfacing with APIs that require it (`AbortController`, `ReadableStream` from the WHATWG spec). Do not mix the two patterns in the same module.
