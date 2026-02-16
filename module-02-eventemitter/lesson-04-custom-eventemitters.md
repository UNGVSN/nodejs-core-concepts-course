# Module 02 / Lesson 04 — Building Custom EventEmitters

> You rarely use `EventEmitter` directly. Instead, you extend it — creating classes like `HttpServer`, `ReadableStream`, or `DatabaseConnection` that emit domain-specific events with domain-specific payloads. This lesson teaches you how to build custom EventEmitters that are self-documenting, validated, and production-ready.

## Learning Objectives

- Extend `EventEmitter` using `class ... extends` to create domain-specific event classes
- Define typed events with JSDoc annotations so consumers know what to expect
- Validate event names and payloads at emission time
- Implement lifecycle hooks (init, start, stop, destroy) as events
- Apply encapsulation using private fields alongside the public event API

---

## Extending EventEmitter

The fundamental pattern is `class MyClass extends EventEmitter`. Your constructor calls `super()`, and your class gains all EventEmitter methods:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

class TaskRunner extends EventEmitter {
  #tasks = [];

  add(task) {
    this.#tasks.push(task);
    this.emit('task:added', { name: task.name, total: this.#tasks.length });
  }

  async run() {
    this.emit('run:start', { count: this.#tasks.length });

    for (let i = 0; i < this.#tasks.length; i++) {
      const task = this.#tasks[i];
      this.emit('task:start', { name: task.name, index: i });

      try {
        const result = await task.fn();
        this.emit('task:complete', { name: task.name, result });
      } catch (err) {
        this.emit('task:error', { name: task.name, error: err });
      }
    }

    this.emit('run:end', { count: this.#tasks.length });
  }
}

// Usage
const runner = new TaskRunner();

runner.on('task:added', ({ name, total }) => {
  console.log(`Task "${name}" added (${total} total)`);
});

runner.on('task:start', ({ name, index }) => {
  console.log(`Running task ${index}: ${name}`);
});

runner.on('task:complete', ({ name, result }) => {
  console.log(`Task "${name}" completed:`, result);
});

runner.on('task:error', ({ name, error }) => {
  console.error(`Task "${name}" failed:`, error.message);
});

runner.on('run:start', ({ count }) => console.log(`Starting ${count} tasks`));
runner.on('run:end', ({ count }) => console.log(`Finished ${count} tasks`));

runner.add({ name: 'fetch-data', fn: async () => ({ rows: 42 }) });
runner.add({ name: 'fail-task', fn: async () => { throw new Error('timeout'); } });

runner.run();
```

### Why Extend Instead of Compose?

You could use composition — store an emitter as a private property and delegate to it. But extension is the Node.js convention because it lets consumers use the standard EventEmitter API without learning a new interface:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

// COMPOSITION — works, but consumers need to know about .events
class ServerComposed {
  events = new EventEmitter();

  start() {
    this.events.emit('listening');
  }
}

const s1 = new ServerComposed();
s1.events.on('listening', () => console.log('ready'));
s1.start();

// EXTENSION — Node.js convention, consumers use standard API
class ServerExtended extends EventEmitter {
  start() {
    this.emit('listening');
  }
}

const s2 = new ServerExtended();
s2.on('listening', () => console.log('ready'));
s2.start();
```

Extension wins because it is what every Node.js developer already knows. When you see `server.on('request', ...)`, you immediately know it is an EventEmitter.

---

## Typed Events with JSDoc

JavaScript does not have a built-in event type system, but JSDoc annotations give you documentation and IDE support:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

/**
 * @typedef {Object} ConnectionEvent
 * @property {string} host - The remote host
 * @property {number} port - The remote port
 * @property {number} timestamp - Connection time (ms since epoch)
 */

/**
 * @typedef {Object} MessageEvent
 * @property {string} from - Sender ID
 * @property {string} body - Message content
 * @property {number} size - Message size in bytes
 */

/**
 * @typedef {Object} DisconnectEvent
 * @property {string} reason - Why the connection was closed
 * @property {number} duration - How long the connection lasted (ms)
 */

/**
 * A WebSocket-like connection that emits typed events.
 *
 * Events:
 * - `connect` — {@link ConnectionEvent} — Fired when the connection is established
 * - `message` — {@link MessageEvent} — Fired for each incoming message
 * - `disconnect` — {@link DisconnectEvent} — Fired when the connection closes
 * - `error` — {Error} — Fired on connection errors
 */
class Connection extends EventEmitter {
  #host;
  #port;
  #connectedAt = null;

  constructor(host, port) {
    super();
    this.#host = host;
    this.#port = port;
  }

  connect() {
    this.#connectedAt = Date.now();

    /** @type {ConnectionEvent} */
    const event = {
      host: this.#host,
      port: this.#port,
      timestamp: this.#connectedAt,
    };

    this.emit('connect', event);
  }

  receive(from, body) {
    /** @type {MessageEvent} */
    const event = {
      from,
      body,
      size: Buffer.byteLength(body, 'utf8'),
    };

    this.emit('message', event);
  }

  disconnect(reason) {
    /** @type {DisconnectEvent} */
    const event = {
      reason,
      duration: Date.now() - this.#connectedAt,
    };

    this.emit('disconnect', event);
    this.#connectedAt = null;
  }
}

// Consumers get IntelliSense for event payloads in supported editors
const conn = new Connection('api.example.com', 443);

conn.on('connect', (/** @type {ConnectionEvent} */ event) => {
  console.log(`Connected to ${event.host}:${event.port}`);
});

conn.on('message', (/** @type {MessageEvent} */ event) => {
  console.log(`[${event.from}] ${event.body} (${event.size} bytes)`);
});

conn.on('disconnect', (/** @type {DisconnectEvent} */ event) => {
  console.log(`Disconnected: ${event.reason} (session: ${event.duration}ms)`);
});

conn.connect();
conn.receive('server', 'Hello, client!');
conn.disconnect('idle timeout');
```

This is not type enforcement — JavaScript will not throw if the payload shape is wrong. But it gives you three things: autocomplete in VS Code, documentation in hover tooltips, and a contract that other developers can read.

---

## Event Name Validation

You can enforce that only known event names are used by overriding `emit()`:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

class StrictEmitter extends EventEmitter {
  /** @type {Set<string|symbol>} */
  static KNOWN_EVENTS = new Set();

  emit(eventName, ...args) {
    // Allow meta-events and error events unconditionally
    const allowed = new Set(['newListener', 'removeListener', 'error']);

    if (!allowed.has(eventName) && !this.constructor.KNOWN_EVENTS.has(eventName)) {
      throw new TypeError(
        `Unknown event "${String(eventName)}". ` +
        `Known events: ${[...this.constructor.KNOWN_EVENTS].map(String).join(', ')}`
      );
    }

    return super.emit(eventName, ...args);
  }
}

class OrderSystem extends StrictEmitter {
  static KNOWN_EVENTS = new Set(['order:created', 'order:shipped', 'order:delivered']);

  createOrder(id) {
    this.emit('order:created', { id, timestamp: Date.now() });
  }

  shipOrder(id) {
    this.emit('order:shipped', { id, timestamp: Date.now() });
  }
}

const orders = new OrderSystem();

orders.on('order:created', (e) => console.log('New order:', e.id));
orders.createOrder('ORD-001');
// New order: ORD-001

// This would throw:
// orders.emit('order:cancelled', { id: 'ORD-001' });
// TypeError: Unknown event "order:cancelled". Known events: order:created, order:shipped, order:delivered
```

### When to Validate

Validation adds overhead on every `emit()` call. Use it during development and in frameworks where catching misspelled event names early saves hours of debugging. In performance-critical paths, you might disable it in production via an environment flag.

---

## Lifecycle Hooks as Events

Many systems have a lifecycle: initialize, start, run, stop, destroy. Modeling each stage as an event gives consumers hooks to plug into:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

class Service extends EventEmitter {
  #name;
  #state = 'created';

  constructor(name) {
    super();
    this.#name = name;
  }

  get name() { return this.#name; }
  get state() { return this.#state; }

  async init(config = {}) {
    this.#transition('created', 'initializing');
    this.emit('init:start', { name: this.#name, config });

    // Simulate async initialization (loading config, connecting to DB, etc.)
    await new Promise((resolve) => setTimeout(resolve, 50));

    this.#transition('initializing', 'initialized');
    this.emit('init:complete', { name: this.#name });
  }

  async start() {
    this.#transition('initialized', 'starting');
    this.emit('start', { name: this.#name });

    await new Promise((resolve) => setTimeout(resolve, 50));

    this.#transition('starting', 'running');
    this.emit('running', { name: this.#name });
  }

  async stop() {
    this.#transition('running', 'stopping');
    this.emit('stop:start', { name: this.#name });

    await new Promise((resolve) => setTimeout(resolve, 50));

    this.#transition('stopping', 'stopped');
    this.emit('stop:complete', { name: this.#name });
  }

  async destroy() {
    const validFrom = ['stopped', 'initialized', 'created'];
    if (!validFrom.includes(this.#state)) {
      throw new Error(`Cannot destroy from state "${this.#state}" — stop first`);
    }

    this.#state = 'destroying';
    this.emit('destroy:start', { name: this.#name });

    // Clean up resources
    this.removeAllListeners();

    this.#state = 'destroyed';
    // Note: no emit here — listeners were just removed
    console.log(`[${this.#name}] Destroyed`);
  }

  #transition(from, to) {
    if (this.#state !== from) {
      throw new Error(
        `Invalid state transition: "${this.#state}" -> "${to}" (expected "${from}" -> "${to}")`
      );
    }
    this.#state = to;
  }
}

// Usage
async function main() {
  const svc = new Service('auth-service');

  svc.on('init:start', (e) => console.log(`[${e.name}] Initializing...`));
  svc.on('init:complete', (e) => console.log(`[${e.name}] Initialized`));
  svc.on('running', (e) => console.log(`[${e.name}] Running`));
  svc.on('stop:complete', (e) => console.log(`[${e.name}] Stopped`));

  await svc.init({ port: 3000 });
  await svc.start();

  console.log(`State: ${svc.state}`);
  // State: running

  await svc.stop();
  await svc.destroy();
}

main();
```

### Key Design Decisions

1. **Events are paired** — `init:start` / `init:complete`, `stop:start` / `stop:complete` — so consumers can measure timing between them
2. **State is private** — only the class can change state; consumers can read it via a getter
3. **State transitions are validated** — you cannot `start()` before `init()` or `destroy()` while running
4. **`destroy()` removes all listeners** — preventing memory leaks from forgotten handlers

---

## Encapsulation: Private Fields + Public Events

Private class fields (`#field`) work naturally alongside the public EventEmitter API. The pattern is: internal state is private, external communication is through events:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

class RateLimiter extends EventEmitter {
  #maxRequests;
  #windowMs;
  #requests = new Map();  // IP -> [timestamps]

  constructor(maxRequests = 100, windowMs = 60_000) {
    super();
    this.#maxRequests = maxRequests;
    this.#windowMs = windowMs;
  }

  check(ip) {
    const now = Date.now();
    const windowStart = now - this.#windowMs;

    // Get or create request history
    let timestamps = this.#requests.get(ip) || [];

    // Remove expired timestamps
    timestamps = timestamps.filter((t) => t > windowStart);

    if (timestamps.length >= this.#maxRequests) {
      const retryAfter = timestamps[0] + this.#windowMs - now;
      this.emit('limited', { ip, retryAfter, count: timestamps.length });
      return false;
    }

    timestamps.push(now);
    this.#requests.set(ip, timestamps);

    if (timestamps.length === Math.floor(this.#maxRequests * 0.8)) {
      this.emit('warning', { ip, count: timestamps.length, max: this.#maxRequests });
    }

    this.emit('allowed', { ip, count: timestamps.length, max: this.#maxRequests });
    return true;
  }

  reset(ip) {
    this.#requests.delete(ip);
    this.emit('reset', { ip });
  }
}

const limiter = new RateLimiter(5, 10_000);

limiter.on('allowed', (e) => {
  console.log(`[ALLOW] ${e.ip}: ${e.count}/${e.max}`);
});

limiter.on('warning', (e) => {
  console.log(`[WARN]  ${e.ip}: approaching limit (${e.count}/${e.max})`);
});

limiter.on('limited', (e) => {
  console.log(`[LIMIT] ${e.ip}: retry after ${e.retryAfter}ms`);
});

// Simulate requests
for (let i = 0; i < 7; i++) {
  limiter.check('192.168.1.1');
}
```

The consumer never touches `#requests` or `#maxRequests`. They interact only through `check()`, `reset()`, and events. This is the EventEmitter encapsulation pattern at its best.

---

## Event Namespacing

As your class grows, event names can collide or become confusing. Use a colon-separated namespace convention:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

class Database extends EventEmitter {
  connect() {
    this.emit('connection:open', { host: 'localhost' });
  }

  disconnect() {
    this.emit('connection:close', { reason: 'shutdown' });
  }

  query(sql) {
    this.emit('query:start', { sql });
    // ... execute query ...
    this.emit('query:complete', { sql, rows: 42, ms: 12 });
  }

  beginTransaction() {
    this.emit('transaction:begin', { id: 'tx-001' });
  }

  commitTransaction() {
    this.emit('transaction:commit', { id: 'tx-001' });
  }
}
```

Namespacing gives you:

- **Grouping** — `connection:*`, `query:*`, `transaction:*` are visually distinct
- **Filtering** — easy to log all `query:*` events with a `newListener` filter
- **Documentation** — the namespace acts as a mini-taxonomy of your class's behavior

Node.js core does not use this convention (it uses flat names like `data`, `end`, `close`), but for application-level code with many events, it is a helpful practice.

---

## Anti-Patterns to Avoid

### Emitting Before Construction Completes

If you emit events in the constructor, listeners registered after `new MyClass()` will miss them:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

// BAD — event fires before consumer can register a listener
class BadService extends EventEmitter {
  constructor() {
    super();
    this.emit('ready');  // Nobody is listening yet!
  }
}

const svc = new BadService();
svc.on('ready', () => console.log('Ready'));
// (never fires — the event was emitted in the constructor)
```

Use `process.nextTick()` or a separate `.init()` method:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

class GoodService extends EventEmitter {
  constructor() {
    super();
    // Defer emission to the next tick so listeners can be registered
    process.nextTick(() => {
      this.emit('ready');
    });
  }
}

const svc = new GoodService();
svc.on('ready', () => console.log('Ready'));
// Ready — works because nextTick runs after the current call stack
```

### Passing `this` Mutably Through Events

Do not emit the entire class instance as an event argument. Consumers could modify internal state:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

// BAD — leaks mutable internal state
class LeakyCounter extends EventEmitter {
  count = 0;

  increment() {
    this.count++;
    this.emit('changed', this);  // Consumer gets full access
  }
}

// GOOD — emit only the data consumers need
class SafeCounter extends EventEmitter {
  #count = 0;

  increment() {
    this.#count++;
    this.emit('changed', { count: this.#count });  // Snapshot, not reference
  }

  get count() { return this.#count; }
}
```

---

## Key Takeaways

- Extend `EventEmitter` with `class ... extends` to create domain-specific event classes — this is the Node.js convention over composition
- Use JSDoc `@typedef` annotations to document event payloads — it gives consumers autocomplete and a readable contract
- Validate event names by overriding `emit()` in development to catch misspelled events early
- Model service lifecycles as paired events (`init:start` / `init:complete`) with validated state transitions
- Never emit events in the constructor — use `process.nextTick()` or a separate init method so consumers can register listeners first

## Next

[Lesson 05 — EventEmitter in Node.js Core](lesson-05-eventemitter-in-node-core.md) traces the EventEmitter inheritance chain through the most important Node.js core modules — streams, HTTP, networking, file watching, and child processes.
