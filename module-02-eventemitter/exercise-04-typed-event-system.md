# E04: Typed Event System

## Objective

Build an EventEmitter subclass that validates event names against a registry and validates payload shapes at emission time. When someone emits an unregistered event or passes a malformed payload, the system rejects it immediately with a clear error. This exercise demonstrates defensive EventEmitter design — the kind that catches integration bugs at development time instead of production.

## Prerequisites

- Module 02 / Lesson 01 — EventEmitter Internals
- Module 02 / Lesson 03 — Error Events and Edge Cases
- Module 02 / Lesson 04 — Custom EventEmitters

## Instructions

1. Create a file called `typed-events.js`. Add `'use strict';` at the top:

```javascript
'use strict';

const { EventEmitter } = require('node:events');
```

2. Define a schema validation system. A `TYPES` object maps type names to validator functions (`string`, `number`, `boolean`, `object`, `array`, `function`, `any`). A `validatePayload(schema, payload)` function iterates schema entries, checks each field against its type validator, and returns an array of error strings. Support optional fields via `{ type: 'string', optional: true }` syntax:

```javascript
const TYPES = {
  string: (v) => typeof v === 'string',
  number: (v) => typeof v === 'number' && !Number.isNaN(v),
  boolean: (v) => typeof v === 'boolean',
  object: (v) => typeof v === 'object' && v !== null && !Array.isArray(v),
  array: (v) => Array.isArray(v),
  any: () => true,
};

function validatePayload(schema, payload) {
  const errors = [];
  for (const [key, rule] of Object.entries(schema)) {
    const isOptional = typeof rule === 'object' && rule.optional;
    const type = typeof rule === 'object' ? rule.type : rule;
    if (payload[key] === undefined) {
      if (!isOptional) errors.push(`Missing required field: '${key}'`);
      continue;
    }
    const validator = typeof type === 'function' ? type : TYPES[type];
    if (validator && !validator(payload[key]))
      errors.push(`Field '${key}': expected ${type}, got ${typeof payload[key]}`);
  }
  return errors;
}
```

3. Create the `TypedEventEmitter` class extending `EventEmitter`. The constructor accepts an event registry:

```javascript
class TypedEventEmitter extends EventEmitter {
  constructor(registry = {}) {
    super();
    this._registry = new Map();
    this._strict = true; // reject unregistered events

    for (const [eventName, schema] of Object.entries(registry)) {
      this._registry.set(eventName, schema);
    }
  }
}
```

4. Override the `emit` method to validate before emission:

```javascript
emit(eventName, payload) {
  // Allow internal Node.js events to pass through
  const internalEvents = ['newListener', 'removeListener', 'error'];
  if (internalEvents.includes(eventName)) {
    return super.emit(eventName, payload);
  }

  // Check if event is registered
  if (!this._registry.has(eventName)) {
    if (this._strict) {
      throw new Error(
        `Unregistered event: '${eventName}'. Registered events: ${[...this._registry.keys()].join(', ')}`
      );
    }
    return super.emit(eventName, payload);
  }

  // Validate payload against schema
  const schema = this._registry.get(eventName);
  if (schema && typeof payload === 'object' && payload !== null) {
    const errors = validatePayload(schema, payload);
    if (errors.length > 0) {
      throw new Error(
        `Invalid payload for '${eventName}':\n  ${errors.join('\n  ')}`
      );
    }
  }

  return super.emit(eventName, payload);
}
```

5. Override the `on` method to warn when subscribing to unregistered events:

```javascript
on(eventName, listener) {
  const internalEvents = ['newListener', 'removeListener', 'error'];
  if (!internalEvents.includes(eventName) && !this._registry.has(eventName)) {
    if (this._strict) {
      throw new Error(
        `Cannot listen for unregistered event: '${eventName}'. Register it first.`
      );
    }
  }
  return super.on(eventName, listener);
}
```

6. Add utility methods: `register(eventName, schema)` for dynamic registration (throw if already registered), `setStrict(enabled)` to toggle strict mode, `getSchema(eventName)` to inspect a schema, and `getRegisteredEvents()` to list all registered event names.

```javascript
register(eventName, schema) {
  if (this._registry.has(eventName)) throw new Error(`Event '${eventName}' already registered`);
  this._registry.set(eventName, schema);
  return this;
}
setStrict(enabled) { this._strict = enabled; return this; }
getSchema(eventName) { return this._registry.get(eventName) || null; }
getRegisteredEvents() { return [...this._registry.keys()]; }
```

8. Write a test script that defines a typed event system for an order processing domain:

```javascript
const orderSystem = new TypedEventEmitter({
  'order:created': {
    orderId: 'string',
    customerId: 'string',
    items: 'array',
    total: 'number',
  },
  'order:paid': {
    orderId: 'string',
    paymentMethod: 'string',
    amount: 'number',
    paidAt: { type: 'string', optional: true },
  },
  'order:shipped': {
    orderId: 'string',
    trackingNumber: 'string',
    carrier: 'string',
  },
  'order:cancelled': {
    orderId: 'string',
    reason: 'string',
  },
});
```

9. Register listeners and test with both valid and invalid payloads:

```javascript
// Register listeners
orderSystem.on('order:created', (data) => {
  console.log(`[ORDER CREATED] ${data.orderId}: ${data.items.length} items, $${data.total}`);
});

orderSystem.on('order:paid', (data) => {
  console.log(`[ORDER PAID] ${data.orderId} via ${data.paymentMethod}: $${data.amount}`);
});

orderSystem.on('order:shipped', (data) => {
  console.log(`[ORDER SHIPPED] ${data.orderId}: ${data.carrier} ${data.trackingNumber}`);
});

// Valid emissions
console.log('--- Valid Events ---');
orderSystem.emit('order:created', {
  orderId: 'ORD-001',
  customerId: 'CUST-42',
  items: ['Widget A', 'Widget B'],
  total: 59.99,
});

orderSystem.emit('order:paid', {
  orderId: 'ORD-001',
  paymentMethod: 'credit_card',
  amount: 59.99,
});

// Invalid emissions — each should throw
console.log('\n--- Invalid Events ---');

const testCases = [
  { label: 'Missing required field',
    fn: () => orderSystem.emit('order:shipped', { orderId: 'ORD-001', carrier: 'UPS' }) },
  { label: 'Wrong type',
    fn: () => orderSystem.emit('order:created', { orderId: 123, customerId: 'CUST-42', items: ['Widget'], total: 10 }) },
  { label: 'Unregistered event',
    fn: () => orderSystem.emit('order:refunded', { orderId: 'ORD-001' }) },
  { label: 'NaN amount',
    fn: () => orderSystem.emit('order:paid', { orderId: 'ORD-001', paymentMethod: 'cash', amount: NaN }) },
];

for (const tc of testCases) {
  try {
    tc.fn();
    console.log(`  ${tc.label}: UNEXPECTED SUCCESS`);
  } catch (err) {
    console.log(`  ${tc.label}: CAUGHT — ${err.message}`);
  }
}
```

10. Run the script and verify that valid events pass through to listeners while invalid events throw descriptive errors.

## Break-Then-Harden Challenge

1. **Bypass via direct `super.emit`.** Subclass `TypedEventEmitter` and call `super.emit(...)` to bypass validation. Demonstrate the bypass, then fix it with a `Symbol`-based validated flag that the base class checks.

2. **Schema evolution.** Add a new required field `transactionId` to `order:paid`. Observe that all existing emitters break. Implement a `migrate(eventName, newSchema, transformer)` method that fills in defaults for backward compatibility.

3. **Performance impact.** Benchmark validation overhead by emitting 100,000 events with and without strict mode. If overhead exceeds 50%, implement a production mode controlled by `NODE_ENV`.

## Expected Output

```
--- Valid Events ---
[ORDER CREATED] ORD-001: 2 items, $59.99
[ORDER PAID] ORD-001 via credit_card: $59.99

--- Invalid Events ---
  Missing required field: CAUGHT — Invalid payload for 'order:shipped':
  Missing required field: 'trackingNumber'
  Wrong type: CAUGHT — Invalid payload for 'order:created':
  Field 'orderId': expected string, got number (123)
  Unregistered event: CAUGHT — Unregistered event: 'order:refunded'...
  NaN amount: CAUGHT — Invalid payload for 'order:paid':
  Field 'amount': expected number, got number (null)
```

## Bonus

1. Add support for nested schemas (e.g., `order:created` has an `address` field with sub-schema `{ street: 'string', city: 'string', zip: 'string' }`). Implement recursive validation.

2. Add a `freeze()` method that locks the registry. After freezing, calls to `register()` throw — useful for production hardening.

## Hints

1. Override both `on` and `once` to catch invalid event subscriptions — developers use both methods to register listeners.
2. The `typeof NaN` is `'number'`, which is why the number validator must also check `!Number.isNaN(v)`.
3. Internal Node.js events like `'newListener'` and `'removeListener'` must always pass through without validation, or EventEmitter's own internals will break.
4. When throwing from `emit`, the event is never delivered to listeners. This is a design choice: fail fast on invalid data rather than silently delivering garbage.
5. For the schema, `{ type: 'string', optional: true }` marks a field as optional. The short form `'string'` means required. This two-form pattern keeps common schemas concise.
