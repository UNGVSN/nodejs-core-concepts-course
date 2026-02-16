# Module 02 / Lesson 03 — Error Events & Edge Cases

> The `error` event is special. If you emit it without a listener, Node.js crashes your process — by design. This lesson covers that rule, the reasoning behind it, and the edge cases that trip up even experienced developers: async listener rejections, memory leak warnings, and the meta-events that let you observe the listener registry itself.

## Learning Objectives

- Explain why unhandled `error` events crash the process and how to prevent it
- Use `captureRejections` to handle rejected Promises in async listeners
- Leverage the `newListener` and `removeListener` meta-events for instrumentation
- Detect and fix the maxListeners warning before it becomes a real leak
- Handle edge cases like emitting during construction and error events with no Error object

---

## The Special `error` Event

Every EventEmitter has one hard rule: if you emit an `error` event and no listener is registered for it, Node.js throws the error as an uncaught exception. This will crash your process.

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

// No 'error' listener registered — this WILL crash
emitter.emit('error', new Error('Something went wrong'));
// Uncaught Error: Something went wrong
//     at ...
// Process exits with code 1
```

### Why Does Node.js Do This?

The alternative is worse. If unhandled errors were silently ignored, you would have broken systems running in production with no indication that anything was wrong. The Node.js philosophy is: errors that nobody handles are bugs. Bugs should be loud.

Compare with unhandled Promise rejections, which historically were silent and caused years of frustration before Node.js started warning about (and eventually crashing on) them.

### The Fix: Always Register an Error Listener

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter.on('error', (err) => {
  console.error('Caught error:', err.message);
  // Log it, record metrics, take corrective action — but don't crash
});

emitter.emit('error', new Error('Something went wrong'));
// Caught error: Something went wrong
// Process continues
```

This is not just good practice — it is required. Every emitter in your application that might ever emit an `error` event needs a listener. Node.js core modules (streams, servers, sockets) all emit `error` events, so if you create one, attach an error handler.

### What Gets Thrown?

If the argument to `emit('error', ...)` is an `Error` instance, that exact error is thrown. If it is something else (a string, a number, `undefined`), Node.js wraps it:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

try {
  emitter.emit('error', 'just a string');
} catch (err) {
  console.log(err instanceof Error);
  // false — the string itself is thrown

  console.log(err);
  // 'just a string'
}
```

Always emit actual `Error` objects. Throwing strings makes stack traces useless and makes error handling brittle.

### The `errorMonitor` Symbol

Sometimes you want to observe errors without suppressing the crash behavior. The `EventEmitter.errorMonitor` symbol lets you do exactly that — your listener runs, but if no regular `error` listener exists, the process still crashes:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

// This listener observes but does NOT prevent the crash
emitter.on(EventEmitter.errorMonitor, (err) => {
  console.error('Error monitor saw:', err.message);
  // Send to monitoring service, write to log, etc.
});

// No regular 'error' listener — process will still crash
// emitter.emit('error', new Error('boom'));

// Add a regular error listener to prevent the crash
emitter.on('error', (err) => {
  console.error('Handled:', err.message);
});

emitter.emit('error', new Error('boom'));
// Error monitor saw: boom
// Handled: boom
```

Use `errorMonitor` for telemetry and observability without changing error-handling semantics.

---

## `captureRejections` — Async Listener Safety

Event listeners are called synchronously. But what if a listener is an `async` function that throws?

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter.on('data', async (chunk) => {
  // This rejection is NOT caught by EventEmitter
  throw new Error('Async failure');
});

emitter.on('error', (err) => {
  console.error('Error handler:', err.message);
});

emitter.emit('data', 'test');
// UnhandledPromiseRejectionWarning: Error: Async failure
// The 'error' listener never fires!
```

The `error` listener does not fire because `emit()` is synchronous — it has no way to catch a Promise rejection from an async function. The Promise rejects asynchronously, after `emit()` has already returned.

### Enabling `captureRejections`

Node.js provides the `captureRejections` option to fix this. When enabled, if a listener returns a rejected Promise, the rejection is routed to the `error` event:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

// Per-instance
const emitter = new EventEmitter({ captureRejections: true });

emitter.on('data', async (chunk) => {
  throw new Error('Async failure');
});

emitter.on('error', (err) => {
  console.error('Caught via captureRejections:', err.message);
});

emitter.emit('data', 'test');
// Caught via captureRejections: Async failure
```

You can also enable it globally (affects all new emitters):

```javascript
'use strict';

const { EventEmitter } = require('node:events');

EventEmitter.captureRejections = true;
```

### The `Symbol.for('nodejs.rejection')` Hook

For fine-grained control, implement the rejection handler directly on your class:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

class SafeProcessor extends EventEmitter {
  constructor() {
    super({ captureRejections: true });
  }

  // Custom rejection handler — called instead of emitting 'error'
  [Symbol.for('nodejs.rejection')](err, eventName, ...args) {
    console.error(`Rejection in "${eventName}" listener:`, err.message);
    console.error('Listener args were:', args);
    // Custom recovery logic here
  }
}

const processor = new SafeProcessor();

processor.on('process', async (item) => {
  if (item.invalid) {
    throw new Error('Invalid item');
  }
});

processor.emit('process', { invalid: true });
// Rejection in "process" listener: Invalid item
// Listener args were: [{ invalid: true }]
```

### When to Use `captureRejections`

Use it when:

- Your event listeners are `async` functions
- You want consistent error handling for both sync and async failures
- You are building a framework where users provide async listeners

Do not use it as a substitute for proper error handling inside your async functions. Try/catch inside the listener is still the first line of defense.

---

## Meta-Events: `newListener` and `removeListener`

EventEmitter emits events about itself. Every time a listener is added or removed, it fires a corresponding meta-event.

### `newListener` — Triggered Before Addition

The `newListener` event fires **before** the listener is added to the internal array. This gives you a chance to inspect, modify, or reject the registration:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter.on('newListener', (eventName, listener) => {
  console.log(`About to add listener for "${eventName}": ${listener.name || 'anonymous'}`);
});

function onData(chunk) {
  console.log(chunk);
}

emitter.on('data', onData);
// About to add listener for "data": onData

emitter.on('close', () => {});
// About to add listener for "close": anonymous
```

Note: the `newListener` event fires for every `on()`, `once()`, `addListener()`, and `prependListener()` call — but it does **not** fire for adding `newListener` listeners themselves (that would cause infinite recursion).

### `removeListener` — Triggered After Removal

The `removeListener` event fires **after** the listener has been removed:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter.on('removeListener', (eventName, listener) => {
  console.log(`Removed listener for "${eventName}": ${listener.name || 'anonymous'}`);
});

function onData() {}

emitter.on('data', onData);
emitter.off('data', onData);
// Removed listener for "data": onData
```

### Practical Use: Listener Auditing

Use `newListener` and `removeListener` to build a listener audit trail:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

class AuditedEmitter extends EventEmitter {
  #listenerLog = [];

  constructor() {
    super();

    this.on('newListener', (event, fn) => {
      this.#listenerLog.push({
        action: 'add',
        event,
        listener: fn.name || '<anonymous>',
        time: Date.now(),
      });
    });

    this.on('removeListener', (event, fn) => {
      this.#listenerLog.push({
        action: 'remove',
        event,
        listener: fn.name || '<anonymous>',
        time: Date.now(),
      });
    });
  }

  getAuditLog() {
    return [...this.#listenerLog];
  }
}

const emitter = new AuditedEmitter();

function handleRequest() {}
function handleError() {}

emitter.on('request', handleRequest);
emitter.on('error', handleError);
emitter.off('request', handleRequest);

console.log(emitter.getAuditLog());
// [
//   { action: 'add', event: 'request', listener: 'handleRequest', ... },
//   { action: 'add', event: 'error', listener: 'handleError', ... },
//   { action: 'remove', event: 'request', listener: 'handleRequest', ... },
// ]
```

### Practical Use: Auto-Setup on First Listener

A pattern sometimes seen in frameworks — start a resource when the first listener is added, stop it when the last is removed:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

class DataFeed extends EventEmitter {
  #interval = null;

  constructor() {
    super();

    this.on('newListener', (event) => {
      if (event === 'tick' && this.listenerCount('tick') === 0) {
        // First 'tick' listener — start the feed
        console.log('Starting data feed...');
        this.#interval = setInterval(() => {
          this.emit('tick', { price: Math.random() * 100, time: Date.now() });
        }, 1000);
      }
    });

    this.on('removeListener', (event) => {
      if (event === 'tick' && this.listenerCount('tick') === 0) {
        // Last 'tick' listener removed — stop the feed
        console.log('Stopping data feed...');
        clearInterval(this.#interval);
        this.#interval = null;
      }
    });
  }
}

const feed = new DataFeed();

function onTick(data) {
  console.log('Price:', data.price.toFixed(2));
}

feed.on('tick', onTick);
// Starting data feed...
// Price: 42.17
// Price: 88.03
// ...

// Later:
// feed.off('tick', onTick);
// Stopping data feed...
```

---

## Memory Leak Warnings in Practice

The maxListeners warning (covered briefly in Lesson 01) deserves deeper treatment because it is one of the most common issues in production Node.js applications.

### The Warning

```
(node:12345) MaxListenersExceededWarning: Possible EventEmitter memory leak
detected. 11 data listeners added to [EventEmitter]. Use
emitter.setMaxListeners() to increase limit
```

### Common Causes

**1. Registering listeners in a loop without cleanup:**

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const bus = new EventEmitter();

// WRONG — each connection adds a listener that is never removed
function handleConnection(socket) {
  bus.on('broadcast', (msg) => {
    socket.write(msg);
  });
}

// After 11 connections, you get the warning
// After 10,000 connections, you have a real memory leak
```

**2. Re-registering listeners on every request:**

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const config = new EventEmitter();

// WRONG — called every request, but listener is never removed
function getConfig(req, res) {
  config.on('change', () => {
    // This fires for EVERY previous request too
    console.log('Config changed');
  });
}
```

### The Fix

Always remove listeners when the resource that registered them is done:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const bus = new EventEmitter();

function handleConnection(socket) {
  const onBroadcast = (msg) => {
    socket.write(msg);
  };

  bus.on('broadcast', onBroadcast);

  // Clean up when the socket closes
  socket.on('close', () => {
    bus.off('broadcast', onBroadcast);
  });
}
```

### Using `process.on('warning')` to Catch It Programmatically

```javascript
'use strict';

process.on('warning', (warning) => {
  if (warning.name === 'MaxListenersExceededWarning') {
    console.error('Listener leak detected:', warning.message);
    // Log stack trace, send alert, etc.
    console.error(warning.stack);
  }
});
```

---

## Edge Cases

### Emitting `error` with No Error Object

Do not do this, but know what happens if you do:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

try {
  emitter.emit('error');  // no argument at all
} catch (err) {
  console.log(err.message);
  // Unhandled 'error' event
  console.log(err.code);
  // ERR_UNHANDLED_ERROR
}
```

When no argument is provided, Node.js creates a generic error. When a non-Error argument is provided, it is embedded in the error's `.context` property.

### Recursive Emission

Nothing prevents a listener from emitting the same event, but this can cause infinite recursion:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();
let count = 0;

emitter.on('ping', () => {
  count++;
  if (count > 5) return;  // Safety valve
  console.log('ping', count);
  emitter.emit('ping');  // Re-entrant emission
});

emitter.emit('ping');
// ping 1
// ping 2
// ping 3
// ping 4
// ping 5
```

Without the safety valve, this would exhaust the call stack. Be cautious with patterns where listeners emit events — trace the chain to ensure it terminates.

### Throwing Inside a Listener

If a listener throws, the remaining listeners for that event do not execute:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter.on('step', () => console.log('Step 1'));
emitter.on('step', () => { throw new Error('Listener 2 failed'); });
emitter.on('step', () => console.log('Step 3'));  // Never reached

try {
  emitter.emit('step');
} catch (err) {
  console.error('Caught:', err.message);
}
// Step 1
// Caught: Listener 2 failed
// Step 3 never runs
```

This is because `emit()` is synchronous. Once a listener throws, the exception propagates up through `emit()` immediately. The remaining listeners are skipped. This is another reason to keep listeners small and to handle errors inside them rather than letting them throw.

---

## Key Takeaways

- The `error` event is unique: emitting it without a listener **crashes the process** — always register an error handler on every emitter
- `captureRejections` routes rejected Promises from async listeners to the `error` event, bridging the sync/async gap
- `newListener` fires before a listener is added; `removeListener` fires after removal — use them for auditing, auto-setup, and instrumentation
- The maxListeners warning is a leak detector, not a bug — fix the leak by removing listeners when their associated resource is done
- Throwing inside a listener aborts the current emission cycle — remaining listeners do not execute

## Next

[Lesson 04 — Building Custom EventEmitters](lesson-04-custom-eventemitters.md) shows you how to extend EventEmitter into your own domain-specific classes with typed events, validation, and lifecycle hooks.
