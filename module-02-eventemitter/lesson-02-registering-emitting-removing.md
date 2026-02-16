# Module 02 / Lesson 02 — Registering, Emitting & Removing Events

> Lesson 01 showed you what happens inside EventEmitter. This lesson puts the full API in your hands — every method for adding listeners, firing events, and cleaning up when you are done. Mastering this API is the difference between event-driven code that works and event-driven code that does not leak memory or miss events.

## Learning Objectives

- Register listeners with `on()`, `once()`, `addListener()`, and `prependListener()`
- Emit events with arguments using `emit()` and interpret the return value
- Remove listeners precisely with `off()`, `removeListener()`, and `removeAllListeners()`
- Query emitter state with `eventNames()`, `listenerCount()`, `listeners()`, and `rawListeners()`
- Understand the difference between `once()` wrappers and regular listeners in the removal API

---

## Registering Listeners

### `on(eventName, listener)` — The Workhorse

The `on()` method appends a listener to the end of the listeners array for the named event. It returns the emitter, enabling method chaining:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter
  .on('data', (chunk) => {
    console.log('Chunk received:', chunk);
  })
  .on('end', () => {
    console.log('Stream finished');
  });

emitter.emit('data', 'hello');
emitter.emit('data', 'world');
emitter.emit('end');
// Chunk received: hello
// Chunk received: world
// Stream finished
```

`addListener()` is an alias for `on()` — they are the same function. Use whichever reads better in your codebase, but be consistent.

### `once(eventName, listener)` — Fire and Forget

`once()` registers a listener that automatically removes itself after the first invocation:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter.once('connect', () => {
  console.log('Connected — this runs only once');
});

emitter.emit('connect');
// Connected — this runs only once

emitter.emit('connect');
// (nothing — listener was removed after first call)

console.log(emitter.listenerCount('connect'));
// 0
```

Under the hood, `once()` wraps your function in a special wrapper that calls `emitter.off(eventName, wrapper)` before invoking your function. This means the listener is removed **before** your code runs, so if your code throws, the listener is still properly cleaned up.

### `prependListener(eventName, listener)` — Cut in Line

By default, listeners execute in registration order. `prependListener()` inserts a listener at the **beginning** of the array:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();
const order = [];

emitter.on('request', () => order.push('second'));
emitter.prependListener('request', () => order.push('first'));

emitter.emit('request');
console.log(order);
// ['first', 'second']
```

There is also `prependOnceListener()` — the combination of `prependListener` and `once`:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter.on('boot', () => console.log('Normal listener'));
emitter.prependOnceListener('boot', () => console.log('Runs first, only once'));

emitter.emit('boot');
// Runs first, only once
// Normal listener

emitter.emit('boot');
// Normal listener
```

### When to Use `prependListener`

Use it sparingly. Legitimate use cases include:

- **Error-handling middleware** that must intercept events before any other listener
- **Instrumentation** that records timing before application logic runs
- **Framework internals** where execution order is a correctness requirement, not a preference

If you find yourself using `prependListener` frequently, your architecture may be fighting the natural registration-order model. Consider restructuring.

---

## Emitting Events

### `emit(eventName, ...args)` — The Trigger

`emit()` synchronously calls every listener registered for `eventName`, passing the remaining arguments to each listener:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter.on('message', (sender, text, timestamp) => {
  console.log(`[${timestamp}] ${sender}: ${text}`);
});

emitter.emit('message', 'Alice', 'Hello!', Date.now());
// [1707936000000] Alice: Hello!
```

### Passing Multiple Arguments

There is no limit on the number of arguments, but the common pattern is to pass a single object for complex event data:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

// Many arguments — hard to remember the order
emitter.on('bad', (user, action, resource, ip, timestamp) => {});

// Single object — self-documenting
emitter.on('audit', (event) => {
  console.log(`${event.user} ${event.action} ${event.resource} from ${event.ip}`);
});

emitter.emit('audit', {
  user: 'admin',
  action: 'DELETE',
  resource: '/api/users/42',
  ip: '192.168.1.1',
  timestamp: Date.now(),
});
```

### The Return Value

`emit()` returns `true` if the event had any listeners, `false` otherwise. This is useful for conditional logic:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter.on('handled', () => {});

console.log(emitter.emit('handled'));    // true
console.log(emitter.emit('unhandled'));  // false — no listeners registered
```

The `error` event uses this return value to decide whether to throw — if `emit('error', err)` returns `false`, the error is unhandled and Node.js throws it (covered in Lesson 03).

---

## Removing Listeners

Proper cleanup is not optional. Every listener you add must eventually be removed, or you will leak memory. This is especially critical in long-running servers where connections come and go.

### `off(eventName, listener)` — Surgical Removal

`off()` removes **the first occurrence** of `listener` from the array for `eventName`:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

function handler() {
  console.log('I will be removed');
}

emitter.on('signal', handler);
emitter.emit('signal');
// I will be removed

emitter.off('signal', handler);
emitter.emit('signal');
// (nothing)
```

`removeListener()` is an alias for `off()`.

### Critical: You Must Pass the Same Function Reference

This is the most common mistake with listener removal. Anonymous functions cannot be removed because you have no reference to pass to `off()`:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

// WRONG — cannot remove this later
emitter.on('data', (chunk) => {
  console.log(chunk);
});

// You cannot call emitter.off('data', ???)
// The arrow function is lost — no reference to it

// CORRECT — keep a reference
const onData = (chunk) => {
  console.log(chunk);
};

emitter.on('data', onData);
emitter.off('data', onData);  // works
```

### Removing `once` Listeners Before They Fire

If you registered a listener with `once()` but need to remove it before it fires, pass the original function — not the wrapper:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

function onReady() {
  console.log('Ready');
}

emitter.once('ready', onReady);

// Remove before it fires — pass the original function
emitter.off('ready', onReady);

console.log(emitter.listenerCount('ready'));
// 0 — successfully removed
```

Node.js handles this because it checks both the stored wrapper function and the wrapper's `.listener` property.

### `removeAllListeners([eventName])` — The Nuclear Option

Removes all listeners for a specific event, or all listeners for all events if no argument is provided:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter.on('a', () => {});
emitter.on('a', () => {});
emitter.on('b', () => {});

// Remove all listeners for 'a' only
emitter.removeAllListeners('a');
console.log(emitter.listenerCount('a'));  // 0
console.log(emitter.listenerCount('b'));  // 1

// Remove ALL listeners for ALL events
emitter.removeAllListeners();
console.log(emitter.eventNames());  // []
```

Use `removeAllListeners()` carefully. Removing listeners you did not register — for example, listeners added by a library — can break things in ways that are difficult to debug.

### Removal During Emission

If a listener removes another listener during emission, the removed listener **still runs** in the current emission cycle (because `emit()` iterates over a copy of the array):

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();
const order = [];

function listenerA() {
  order.push('A');
  emitter.off('event', listenerB);
}

function listenerB() {
  order.push('B');
}

emitter.on('event', listenerA);
emitter.on('event', listenerB);

emitter.emit('event');
console.log(order);
// ['A', 'B'] — B still ran even though A removed it

emitter.emit('event');
console.log(order);
// ['A', 'B', 'A'] — B is gone now
```

---

## Querying Emitter State

### `eventNames()`

Returns an array of event names for which at least one listener is registered. Includes Symbol event names:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();
const secret = Symbol('secret');

emitter.on('data', () => {});
emitter.on(secret, () => {});

console.log(emitter.eventNames());
// ['data', Symbol(secret)]
```

### `listenerCount(eventName)`

Returns the number of listeners for a given event. Available both as an instance method and as a static method:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

emitter.on('data', () => {});
emitter.on('data', () => {});
emitter.once('data', () => {});

// Instance method
console.log(emitter.listenerCount('data'));
// 3

// Static method (deprecated but still works)
console.log(EventEmitter.listenerCount(emitter, 'data'));
// 3
```

### `listeners(eventName)` vs `rawListeners(eventName)`

Both return copies of the listener array. The difference is how they handle `once` wrappers:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

function handler() {}

emitter.once('signal', handler);

// listeners() unwraps once wrappers — returns the original function
const unwrapped = emitter.listeners('signal');
console.log(unwrapped[0] === handler);
// true

// rawListeners() returns the actual stored wrappers
const raw = emitter.rawListeners('signal');
console.log(raw[0] === handler);
// false — it is the once wrapper

// The wrapper can be called directly
raw[0]();  // executes handler AND removes it
console.log(emitter.listenerCount('signal'));
// 0
```

---

## Symbol Event Names

Event names are not limited to strings. You can use Symbols for private or collision-free events:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const INTERNAL_RESET = Symbol('internal:reset');

class Cache extends EventEmitter {
  #data = new Map();

  constructor() {
    super();
    this.on(INTERNAL_RESET, () => {
      this.#data.clear();
      console.log('Cache cleared via internal reset');
    });
  }

  set(key, value) {
    this.#data.set(key, value);
  }

  reset() {
    this.emit(INTERNAL_RESET);
  }
}

const cache = new Cache();
cache.set('user:1', { name: 'Alice' });
cache.reset();
// Cache cleared via internal reset

// External code cannot accidentally emit this event
// because they do not have a reference to the Symbol
```

---

## Common Patterns

### The Cleanup Pattern

Always clean up listeners when a resource is done. This pattern appears throughout Node.js:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

function waitForEvent(emitter, eventName, timeout = 5000) {
  return new Promise((resolve, reject) => {
    let timer;

    const onEvent = (...args) => {
      clearTimeout(timer);
      emitter.off('error', onError);
      resolve(args);
    };

    const onError = (err) => {
      clearTimeout(timer);
      emitter.off(eventName, onEvent);
      reject(err);
    };

    emitter.once(eventName, onEvent);
    emitter.once('error', onError);

    timer = setTimeout(() => {
      emitter.off(eventName, onEvent);
      emitter.off('error', onError);
      reject(new Error(`Timeout waiting for "${String(eventName)}"`));
    }, timeout);
  });
}

// Usage
const emitter = new EventEmitter();

setTimeout(() => emitter.emit('ready', 'all systems go'), 100);

waitForEvent(emitter, 'ready')
  .then(([msg]) => console.log('Got:', msg))
  .catch((err) => console.error(err));
```

Note how every code path (success, error, timeout) removes all the listeners it registered. This is not paranoia — it is mandatory in production code.

### The `events.once()` Static Helper

Node.js provides a built-in Promise-based helper that does the cleanup pattern for you:

```javascript
'use strict';

const { once, EventEmitter } = require('node:events');

async function main() {
  const emitter = new EventEmitter();

  setTimeout(() => emitter.emit('ready', 'data', 42), 100);

  // Returns a Promise that resolves with an array of arguments
  const [arg1, arg2] = await once(emitter, 'ready');
  console.log(arg1, arg2);
  // data 42
}

main();
```

`events.once()` handles error events, cleanup, and AbortSignal support. Prefer it over writing your own cleanup logic when you need a one-shot event.

---

## Key Takeaways

- `on()` appends listeners; `prependListener()` inserts at the beginning; `once()` auto-removes after one call
- `emit()` is synchronous, passes all extra arguments to listeners, and returns a boolean indicating whether listeners existed
- Always keep a function reference when calling `on()` so you can later pass it to `off()` — anonymous listeners cannot be removed
- `removeAllListeners()` is a blunt instrument; prefer surgical `off()` calls that only remove what you registered
- Use `eventNames()`, `listenerCount()`, and `listeners()` for runtime inspection; use `events.once()` for clean Promise-based one-shot listeners

## Next

[Lesson 03 — Error Events & Edge Cases](lesson-03-error-events-edge-cases.md) covers the special `error` event that crashes your process if unhandled, `captureRejections` for async listeners, and the meta-events `newListener` and `removeListener`.
