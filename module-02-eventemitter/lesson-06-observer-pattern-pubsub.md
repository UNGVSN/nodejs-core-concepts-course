# Module 02 / Lesson 06 — Observer Pattern & Pub/Sub

> EventEmitter did not appear out of thin air. It is an implementation of the Observer pattern — one of the original Gang of Four design patterns from 1994. This lesson connects EventEmitter to its theoretical roots, implements Observer and Pub/Sub from scratch, and shows you when each pattern is the right choice.

## Learning Objectives

- Define the Observer pattern and explain its structure (Subject, Observer, notify)
- Implement the Observer pattern from scratch without using EventEmitter
- Define the Pub/Sub pattern and explain how it differs from Observer
- Build a channel-based Pub/Sub system from scratch
- Compare Observer, Pub/Sub, and EventEmitter — strengths, trade-offs, and when to choose each

---

## The Observer Pattern

### The Problem

You have an object whose state changes over time. Other objects need to react to those changes. The naive approach — polling or direct function calls — creates tight coupling:

```javascript
'use strict';

// TIGHT COUPLING — the thermometer must know about every consumer
class Thermometer {
  #temp = 20;
  #display;
  #alarm;
  #logger;

  constructor(display, alarm, logger) {
    // Must know about all consumers at construction time
    this.#display = display;
    this.#alarm = alarm;
    this.#logger = logger;
  }

  setTemperature(temp) {
    this.#temp = temp;
    // Must call each consumer explicitly
    this.#display.update(temp);
    this.#alarm.check(temp);
    this.#logger.log(temp);
    // Adding a new consumer? Edit this class.
  }
}
```

Every time you add a new consumer, you must modify the producer. This violates the Open/Closed Principle: classes should be open for extension but closed for modification.

### The Solution — Observer Pattern

The Observer pattern inverts the dependency. The Subject (producer) maintains a list of Observers (consumers) and notifies them when state changes. Observers register and unregister themselves:

```javascript
'use strict';

/**
 * Subject — the object being observed.
 * Maintains a list of observers and notifies them of state changes.
 */
class Subject {
  #observers = new Set();

  subscribe(observer) {
    if (typeof observer.update !== 'function') {
      throw new TypeError('Observer must implement update()');
    }
    this.#observers.add(observer);
    return this;
  }

  unsubscribe(observer) {
    this.#observers.delete(observer);
    return this;
  }

  notify(data) {
    for (const observer of this.#observers) {
      observer.update(data);
    }
  }

  get observerCount() {
    return this.#observers.size;
  }
}

/**
 * Concrete Subject — a thermometer that notifies observers of temperature changes.
 */
class Thermometer extends Subject {
  #temperature = 20;

  get temperature() {
    return this.#temperature;
  }

  setTemperature(temp) {
    const previous = this.#temperature;
    this.#temperature = temp;
    this.notify({ current: temp, previous, timestamp: Date.now() });
  }
}

// Observers — each implements update()
const display = {
  update({ current }) {
    console.log(`[Display] Temperature: ${current}°C`);
  }
};

const alarm = {
  threshold: 30,
  update({ current }) {
    if (current > this.threshold) {
      console.log(`[Alarm] WARNING: ${current}°C exceeds threshold!`);
    }
  }
};

const logger = {
  log: [],
  update(data) {
    this.log.push(data);
    console.log(`[Logger] Recorded: ${data.current}°C (${this.log.length} entries)`);
  }
};

// Wire them up
const thermometer = new Thermometer();
thermometer.subscribe(display);
thermometer.subscribe(alarm);
thermometer.subscribe(logger);

thermometer.setTemperature(22);
// [Display] Temperature: 22°C
// [Logger] Recorded: 22°C (1 entries)

thermometer.setTemperature(35);
// [Display] Temperature: 35°C
// [Alarm] WARNING: 35°C exceeds threshold!
// [Logger] Recorded: 35°C (2 entries)

// Remove an observer
thermometer.unsubscribe(alarm);

thermometer.setTemperature(40);
// [Display] Temperature: 40°C
// [Logger] Recorded: 40°C (3 entries)
// (no alarm — it was unsubscribed)
```

### Key Characteristics

1. **Loose coupling** — the Subject does not know what its observers do, only that they have an `update()` method
2. **Dynamic registration** — observers can subscribe and unsubscribe at runtime
3. **One-to-many** — one Subject notifies many Observers
4. **Synchronous notification** — observers are called immediately when `notify()` is called

### Observer Pattern vs EventEmitter

EventEmitter is an Observer pattern implementation with these additions:

| Feature | Classic Observer | EventEmitter |
|---------|-----------------|--------------|
| Notification channel | Single (`update()`) | Multiple (event names) |
| Observer interface | Must implement `update()` | Any function |
| Registration | `subscribe(object)` | `on(name, function)` |
| Data passing | Single argument to `update()` | Multiple arguments to listener |
| Error handling | None built-in | Special `error` event |
| Execution order | Unspecified | Guaranteed insertion order |

EventEmitter is the Observer pattern evolved for JavaScript: functions instead of objects, event names instead of a single channel, and practical additions like `once()`, `prependListener()`, and error handling.

---

## The Pub/Sub Pattern

### How It Differs from Observer

In the Observer pattern, the Subject knows about its Observers (it holds references to them). In Pub/Sub, **publishers and subscribers do not know about each other**. A message broker (or event bus) sits between them:

```
Observer:   Subject ----> Observer1
                   ----> Observer2

Pub/Sub:    Publisher ----> [Broker] ----> Subscriber1
                                    ----> Subscriber2
```

This extra layer of indirection provides:

- **Complete decoupling** — publishers and subscribers never reference each other
- **Channel-based filtering** — subscribers choose which channels (topics) they care about
- **Potential for async delivery** — the broker can queue messages, batch them, or deliver them across process boundaries

### Building a Pub/Sub System from Scratch

```javascript
'use strict';

/**
 * A channel-based Pub/Sub message broker.
 * Publishers send messages to channels.
 * Subscribers listen on channels.
 * Neither knows about the other.
 */
class MessageBroker {
  #channels = new Map();
  #subscriberId = 0;

  /**
   * Subscribe to a channel. Returns an unsubscribe function.
   */
  subscribe(channel, callback) {
    if (!this.#channels.has(channel)) {
      this.#channels.set(channel, new Map());
    }

    const id = ++this.#subscriberId;
    this.#channels.get(channel).set(id, callback);

    // Return an unsubscribe function (no need to keep a reference)
    return () => {
      const subs = this.#channels.get(channel);
      if (subs) {
        subs.delete(id);
        if (subs.size === 0) {
          this.#channels.delete(channel);
        }
      }
    };
  }

  /**
   * Publish a message to a channel. All subscribers receive it.
   */
  publish(channel, message) {
    const subs = this.#channels.get(channel);
    if (!subs || subs.size === 0) return false;

    for (const callback of subs.values()) {
      callback(message, channel);
    }

    return true;
  }

  /**
   * Subscribe to a channel, but only receive the first message.
   */
  subscribeOnce(channel, callback) {
    const unsub = this.subscribe(channel, (message, ch) => {
      unsub();
      callback(message, ch);
    });

    return unsub;
  }

  /**
   * Get the number of subscribers on a channel.
   */
  subscriberCount(channel) {
    const subs = this.#channels.get(channel);
    return subs ? subs.size : 0;
  }

  /**
   * List all active channels.
   */
  channels() {
    return [...this.#channels.keys()];
  }

  /**
   * Remove all subscribers from all channels.
   */
  clear() {
    this.#channels.clear();
  }
}

// Usage — notice publishers and subscribers never reference each other

const broker = new MessageBroker();

// Subscriber A — cares about user events
const unsubA = broker.subscribe('user:created', (msg) => {
  console.log(`[Email Service] Welcome email to ${msg.email}`);
});

// Subscriber B — also cares about user events
const unsubB = broker.subscribe('user:created', (msg) => {
  console.log(`[Analytics] New user: ${msg.id}`);
});

// Subscriber C — cares about order events
broker.subscribe('order:placed', (msg) => {
  console.log(`[Inventory] Reserve stock for order ${msg.orderId}`);
});

// Publisher — does not know about any subscriber
broker.publish('user:created', { id: 'u-001', email: 'alice@example.com' });
// [Email Service] Welcome email to alice@example.com
// [Analytics] New user: u-001

broker.publish('order:placed', { orderId: 'ord-123', items: 3 });
// [Inventory] Reserve stock for order ord-123

// Unsubscribe the email service
unsubA();

broker.publish('user:created', { id: 'u-002', email: 'bob@example.com' });
// [Analytics] New user: u-002
// (no email — unsubscribed)

console.log('Active channels:', broker.channels());
// Active channels: ['user:created', 'order:placed']
```

### The Unsubscribe Function Pattern

Notice that `subscribe()` returns a function instead of requiring the subscriber to pass a reference to `unsubscribe()`. This is cleaner than EventEmitter's approach for two reasons:

1. Anonymous functions work — no need to keep a reference
2. The caller controls cleanup through a closure, not a method call on the broker

This pattern is used by React's `useEffect` cleanup, Redux's `store.subscribe()`, and many other modern APIs.

---

## Wildcard Subscriptions

A more advanced Pub/Sub system supports pattern-based subscriptions:

```javascript
'use strict';

class WildcardBroker {
  #exact = new Map();      // channel -> Map<id, callback>
  #patterns = new Map();   // pattern -> Map<id, { regex, callback }>
  #nextId = 0;

  subscribe(pattern, callback) {
    const id = ++this.#nextId;

    if (pattern.includes('*')) {
      // Wildcard subscription
      const regexStr = '^' + pattern
        .split('.')
        .map((seg) => seg === '*' ? '[^.]+' : seg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
        .join('\\.') + '$';

      const regex = new RegExp(regexStr);

      if (!this.#patterns.has(pattern)) {
        this.#patterns.set(pattern, new Map());
      }
      this.#patterns.get(pattern).set(id, { regex, callback });
    } else {
      // Exact subscription
      if (!this.#exact.has(pattern)) {
        this.#exact.set(pattern, new Map());
      }
      this.#exact.get(pattern).set(id, callback);
    }

    return () => {
      if (pattern.includes('*')) {
        const subs = this.#patterns.get(pattern);
        if (subs) subs.delete(id);
      } else {
        const subs = this.#exact.get(pattern);
        if (subs) subs.delete(id);
      }
    };
  }

  publish(channel, message) {
    let delivered = 0;

    // Exact matches
    const exact = this.#exact.get(channel);
    if (exact) {
      for (const callback of exact.values()) {
        callback(message, channel);
        delivered++;
      }
    }

    // Wildcard matches
    for (const [, subs] of this.#patterns) {
      for (const [, { regex, callback }] of subs) {
        if (regex.test(channel)) {
          callback(message, channel);
          delivered++;
        }
      }
    }

    return delivered;
  }
}

const broker = new WildcardBroker();

// Subscribe to all user events
broker.subscribe('user.*', (msg, channel) => {
  console.log(`[Audit] ${channel}:`, msg);
});

// Subscribe to specific events
broker.subscribe('user.created', (msg) => {
  console.log(`[Welcome] New user: ${msg.name}`);
});

broker.publish('user.created', { name: 'Alice' });
// [Audit] user.created: { name: 'Alice' }
// [Welcome] New user: Alice

broker.publish('user.deleted', { name: 'Bob' });
// [Audit] user.deleted: { name: 'Bob' }
// (no welcome — only the wildcard matches)
```

---

## Comparing the Three Patterns

### When to Use Each

**Direct Observer (Subject/Observer):**
- Small, tightly-scoped systems
- When observers need access to the Subject's state (not just the event data)
- When you control both sides of the relationship
- Example: a form field that notifies its parent form of changes

**EventEmitter:**
- The Node.js default — use it unless you have a reason not to
- When you need multiple event types on a single object
- When you want the `error` event safety net
- When you need `once()`, `prependListener()`, and other built-in conveniences
- Example: HTTP servers, streams, custom service classes

**Pub/Sub (Message Broker):**
- Large systems where publishers and subscribers should be completely decoupled
- When you need wildcard/pattern-based subscriptions
- When messages might cross process or network boundaries
- When you want the unsubscribe-function pattern
- Example: microservice event buses, application-wide notification systems

### Trade-Off Summary

```
Coupling:       Direct Call > Observer > EventEmitter > Pub/Sub
Flexibility:    Pub/Sub > EventEmitter > Observer > Direct Call
Performance:    Direct Call > Observer > EventEmitter > Pub/Sub
Debuggability:  Direct Call > Observer > EventEmitter > Pub/Sub
```

More indirection means more flexibility but harder debugging. Choose the simplest pattern that meets your requirements.

---

## Bridging Pub/Sub and EventEmitter

In practice, you might use Pub/Sub for cross-module communication and EventEmitter for intra-module events. Here is how to bridge them:

```javascript
'use strict';

const { EventEmitter } = require('node:events');

class MessageBroker {
  #channels = new Map();
  #id = 0;

  subscribe(channel, callback) {
    if (!this.#channels.has(channel)) {
      this.#channels.set(channel, new Map());
    }
    const id = ++this.#id;
    this.#channels.get(channel).set(id, callback);
    return () => {
      const subs = this.#channels.get(channel);
      if (subs) subs.delete(id);
    };
  }

  publish(channel, message) {
    const subs = this.#channels.get(channel);
    if (!subs) return;
    for (const cb of subs.values()) cb(message, channel);
  }
}

// Application-wide broker
const broker = new MessageBroker();

// A service that uses EventEmitter internally
// but publishes significant events to the broker
class UserService extends EventEmitter {
  #broker;

  constructor(broker) {
    super();
    this.#broker = broker;
  }

  async createUser(data) {
    // Internal event — for this service's own listeners
    this.emit('creating', data);

    const user = { id: Date.now(), ...data };

    // Internal event
    this.emit('created', user);

    // Publish to broker — for other services
    this.#broker.publish('user.created', user);

    return user;
  }
}

// Another service that subscribes via the broker
// It does NOT import or reference UserService
broker.subscribe('user.created', (user) => {
  console.log(`[Notification Service] Send welcome to ${user.email}`);
});

broker.subscribe('user.created', (user) => {
  console.log(`[Analytics Service] Track signup: ${user.id}`);
});

// Use the service
const users = new UserService(broker);

users.on('creating', (data) => {
  console.log(`[UserService] Validating: ${data.email}`);
});

users.on('created', (user) => {
  console.log(`[UserService] Stored user: ${user.id}`);
});

users.createUser({ email: 'alice@example.com', name: 'Alice' });
// [UserService] Validating: alice@example.com
// [UserService] Stored user: 1707936000000
// [Notification Service] Send welcome to alice@example.com
// [Analytics Service] Track signup: 1707936000000
```

This hybrid approach gives you the best of both worlds: EventEmitter's familiar API within a module, and Pub/Sub's decoupling between modules.

---

## Key Takeaways

- The **Observer pattern** decouples a Subject from its Observers by maintaining a subscriber list and calling `update()` on state changes — EventEmitter is Node.js's implementation of this pattern
- **Pub/Sub** adds a broker between publishers and subscribers, achieving **complete decoupling** — neither side knows the other exists
- The **unsubscribe function** pattern (return a cleanup function from subscribe) is cleaner than the EventEmitter approach for anonymous listeners
- Choose the **simplest pattern** that meets your needs: direct calls for simple cases, EventEmitter for most Node.js work, Pub/Sub for large decoupled systems
- In practice, **combine them**: EventEmitter for internal class events, Pub/Sub for cross-module communication

## Next

[Module 03 — Buffers & Binary Data](../module-03-buffers/README.md) leaves the event-driven world and dives into raw bytes — how computers represent data at the lowest level and how Node.js gives you the tools to manipulate it.
