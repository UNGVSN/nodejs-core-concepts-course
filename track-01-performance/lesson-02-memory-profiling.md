# Track 01 / Lesson 02 — Memory Profiling

> A memory leak does not crash your server immediately. It creeps — 50 MB at startup, 200 MB after an hour, 1.2 GB after a day — until the process runs out of heap space and V8 terminates it with a cryptic "FATAL ERROR: CALL_AND_RETRY_LAST Allocation failed - JavaScript heap out of memory." This lesson teaches you to catch leaks long before they reach that point.

## Learning Objectives

- Interpret every field of `process.memoryUsage()` and understand what RSS, heapTotal, heapUsed, external, and arrayBuffers measure
- Use `v8.getHeapStatistics()` and `v8.getHeapSpaceStatistics()` to inspect V8 heap internals
- Build a memory usage tracker that detects growth trends over time
- Identify the five most common memory leak patterns in Node.js applications
- Use heap snapshots via the `--inspect` flag and Chrome DevTools to pinpoint leaking objects

---

## Understanding process.memoryUsage()

Every Node.js process can report its own memory consumption through `process.memoryUsage()`. This is the first tool you should reach for when investigating memory issues.

```javascript
'use strict';

const mem = process.memoryUsage();

console.log('=== process.memoryUsage() ===\n');

for (const [key, bytes] of Object.entries(mem)) {
  const mb = (bytes / 1024 / 1024).toFixed(2);
  console.log(`  ${key.padEnd(15)} ${mb} MB`);
}
```

Output on a fresh Node.js process (approximate):

```
  rss             25.38 MB
  heapTotal       4.70 MB
  heapUsed        3.92 MB
  external        1.07 MB
  arrayBuffers    0.01 MB
```

**What each field means:**

| Field | Description |
|-------|-------------|
| `rss` | Resident Set Size — total memory allocated to the process by the OS, including code, stack, and heap |
| `heapTotal` | V8's total allocated heap space — this grows as more objects are created |
| `heapUsed` | V8's actually used heap space — the live objects |
| `external` | Memory used by C++ objects bound to JavaScript objects (e.g., Buffers allocated outside V8 heap) |
| `arrayBuffers` | Memory used by `ArrayBuffer` and `SharedArrayBuffer` instances (subset of `external`) |

The gap between `heapTotal` and `heapUsed` is memory V8 has reserved but not yet filled. V8 grows `heapTotal` in chunks and rarely shrinks it, so this gap tends to widen over time.

---

## The Difference Between RSS and Heap

RSS includes *everything* the process uses — V8 heap, C++ heap (libuv, OpenSSL), stack, loaded shared libraries, and memory-mapped files. The V8 heap (`heapTotal`/`heapUsed`) is a subset of RSS.

```javascript
'use strict';

function formatMB(bytes) {
  return (bytes / 1024 / 1024).toFixed(2) + ' MB';
}

function reportMemory(label) {
  const m = process.memoryUsage();
  console.log(`\n[${label}]`);
  console.log(`  RSS:          ${formatMB(m.rss)}`);
  console.log(`  Heap Total:   ${formatMB(m.heapTotal)}`);
  console.log(`  Heap Used:    ${formatMB(m.heapUsed)}`);
  console.log(`  External:     ${formatMB(m.external)}`);
  console.log(`  Non-heap:     ${formatMB(m.rss - m.heapTotal)}`);
}

reportMemory('Baseline');

// Allocate JS objects — grows heapUsed and heapTotal
const jsObjects = [];
for (let i = 0; i < 100000; i++) {
  jsObjects.push({ id: i, name: `item-${i}`, data: new Array(10).fill(i) });
}
reportMemory('After 100K JS objects');

// Allocate Buffers — grows external and RSS, NOT heap
const buffers = [];
for (let i = 0; i < 1000; i++) {
  buffers.push(Buffer.alloc(1024 * 100)); // 100 KB each = ~100 MB total
}
reportMemory('After 100MB of Buffers');

// Key observation: Buffers over 8KB are allocated OUTSIDE the V8 heap.
// They increase RSS and external, but heapUsed barely changes.
// This is why you can "leak" Buffers without heapUsed ever looking alarming.
```

This distinction is critical: if RSS is growing but `heapUsed` is stable, the leak is in native/external memory (Buffers, C++ addons, file descriptors), not in JavaScript objects.

---

## V8 Heap Internals

For deeper analysis, the `node:v8` module exposes V8's internal heap statistics.

```javascript
'use strict';

const v8 = require('node:v8');

function formatBytes(bytes) {
  if (bytes > 1024 * 1024 * 1024) return (bytes / 1024 / 1024 / 1024).toFixed(2) + ' GB';
  if (bytes > 1024 * 1024) return (bytes / 1024 / 1024).toFixed(2) + ' MB';
  if (bytes > 1024) return (bytes / 1024).toFixed(2) + ' KB';
  return bytes + ' B';
}

// Global heap overview
const stats = v8.getHeapStatistics();
console.log('=== v8.getHeapStatistics() ===\n');
for (const [key, value] of Object.entries(stats)) {
  const formatted = key.includes('size') || key.includes('limit')
    ? formatBytes(value)
    : value;
  console.log(`  ${key.padEnd(35)} ${formatted}`);
}

console.log('\n=== v8.getHeapSpaceStatistics() ===\n');
const spaces = v8.getHeapSpaceStatistics();

console.log(
  'Space'.padEnd(22),
  'Size'.padEnd(12),
  'Used'.padEnd(12),
  'Available'.padEnd(12),
  'Physical'
);
console.log('-'.repeat(70));

for (const space of spaces) {
  console.log(
    space.space_name.padEnd(22),
    formatBytes(space.space_size).padEnd(12),
    formatBytes(space.space_used_size).padEnd(12),
    formatBytes(space.space_available_size).padEnd(12),
    formatBytes(space.physical_space_size)
  );
}
```

**Key heap spaces:**

| Space | Purpose |
|-------|---------|
| `new_space` | Young generation — newly allocated objects. Small (1-8 MB). Collected frequently by Scavenge GC. |
| `old_space` | Old generation — objects that survived two Scavenge cycles. Collected by Mark-Sweep-Compact. |
| `code_space` | Compiled code (JIT output). |
| `large_object_space` | Objects larger than the max new_space allocation. Directly in old generation. |
| `map_space` | V8 hidden class (Map) descriptors. |

**Critical statistic:** `heap_size_limit` is the maximum heap V8 will allocate before throwing OOM. Default is ~1.7 GB on 64-bit systems. Override with `--max-old-space-size=4096` (in MB).

---

## Building a Memory Trend Tracker

A single snapshot tells you current memory usage. A series of snapshots over time tells you whether memory is leaking.

```javascript
'use strict';

class MemoryTracker {
  constructor(options = {}) {
    this.intervalMs = options.intervalMs || 10000;
    this.windowSize = options.windowSize || 60;  // Keep 60 samples
    this.growthThresholdMB = options.growthThresholdMB || 50;
    this._samples = [];
    this._timer = null;
  }

  start() {
    this._sample(); // Take initial sample
    this._timer = setInterval(() => this._sample(), this.intervalMs);
    this._timer.unref();
    return this;
  }

  stop() {
    if (this._timer) {
      clearInterval(this._timer);
      this._timer = null;
    }
    return this;
  }

  _sample() {
    const mem = process.memoryUsage();
    this._samples.push({
      timestamp: Date.now(),
      rss: mem.rss,
      heapUsed: mem.heapUsed,
      heapTotal: mem.heapTotal,
      external: mem.external
    });

    if (this._samples.length > this.windowSize) {
      this._samples.shift();
    }

    this._checkTrend();
  }

  _checkTrend() {
    if (this._samples.length < 5) return; // Need enough data

    const first = this._samples[0];
    const last = this._samples[this._samples.length - 1];

    const rssGrowthMB = (last.rss - first.rss) / 1024 / 1024;
    const heapGrowthMB = (last.heapUsed - first.heapUsed) / 1024 / 1024;
    const durationMin = (last.timestamp - first.timestamp) / 60000;

    if (rssGrowthMB > this.growthThresholdMB) {
      console.error(
        `[MEMORY WARNING] RSS grew ${rssGrowthMB.toFixed(1)}MB ` +
        `over ${durationMin.toFixed(1)} minutes ` +
        `(${(rssGrowthMB / durationMin).toFixed(1)} MB/min)`
      );
    }

    if (heapGrowthMB > this.growthThresholdMB) {
      console.error(
        `[MEMORY WARNING] Heap grew ${heapGrowthMB.toFixed(1)}MB ` +
        `over ${durationMin.toFixed(1)} minutes`
      );
    }
  }

  report() {
    if (this._samples.length === 0) return 'No samples collected';

    const latest = this._samples[this._samples.length - 1];
    const first = this._samples[0];
    const toMB = (b) => (b / 1024 / 1024).toFixed(2);

    return {
      current: {
        rss: toMB(latest.rss) + ' MB',
        heapUsed: toMB(latest.heapUsed) + ' MB',
        heapTotal: toMB(latest.heapTotal) + ' MB',
        external: toMB(latest.external) + ' MB'
      },
      growth: {
        rss: toMB(latest.rss - first.rss) + ' MB',
        heapUsed: toMB(latest.heapUsed - first.heapUsed) + ' MB',
        durationMs: latest.timestamp - first.timestamp,
        samples: this._samples.length
      }
    };
  }
}

// Demonstrate with a simulated leak
const tracker = new MemoryTracker({
  intervalMs: 500,
  windowSize: 30,
  growthThresholdMB: 10
});

tracker.start();

// Simulate a leak: accumulating data in an unbounded array
const leakyCache = [];

const leaker = setInterval(() => {
  for (let i = 0; i < 5000; i++) {
    leakyCache.push({
      id: Math.random().toString(36),
      payload: Buffer.alloc(512).toString('hex'),
      timestamp: Date.now()
    });
  }
}, 200);

setTimeout(() => {
  clearInterval(leaker);
  tracker.stop();
  console.log('\n=== Memory Report ===');
  console.log(JSON.stringify(tracker.report(), null, 2));
  console.log(`Leaky cache entries: ${leakyCache.length}`);
}, 5000);
```

---

## Common Memory Leak Patterns

### Pattern 1: The Unbounded Cache

The most common leak in Node.js. A Map or object used as a cache that grows without bounds.

```javascript
'use strict';

// LEAK: Cache with no eviction policy
const cache = new Map();

function processRequest(userId) {
  // Every unique userId adds an entry that is NEVER removed
  if (!cache.has(userId)) {
    cache.set(userId, {
      profile: { name: `User ${userId}` },
      sessions: [],
      lastAccess: Date.now()
    });
  }
  cache.get(userId).sessions.push({ ts: Date.now() });
  return cache.get(userId);
}

// FIX: Bounded LRU cache
class LRUCache {
  constructor(maxSize = 1000) {
    this._map = new Map();
    this._maxSize = maxSize;
  }

  get(key) {
    if (!this._map.has(key)) return undefined;
    // Move to end (most recently used)
    const value = this._map.get(key);
    this._map.delete(key);
    this._map.set(key, value);
    return value;
  }

  set(key, value) {
    if (this._map.has(key)) this._map.delete(key);
    this._map.set(key, value);
    // Evict oldest entry if over capacity
    if (this._map.size > this._maxSize) {
      const oldest = this._map.keys().next().value;
      this._map.delete(oldest);
    }
  }

  get size() { return this._map.size; }
}

// Usage with bounded cache
const safeCache = new LRUCache(500);

for (let i = 0; i < 10000; i++) {
  safeCache.set(`user-${i}`, { name: `User ${i}` });
}

console.log(`Cache size: ${safeCache.size}`); // Always <= 500
```

### Pattern 2: Forgotten Event Listeners

Adding listeners in a loop or on every request without removing them.

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const emitter = new EventEmitter();

// LEAK: Adding a new listener on every "request"
function handleRequest(data) {
  // This adds a NEW listener every time — they accumulate
  emitter.on('update', () => {
    // Process update for this specific request's data
    console.log('Update for:', data.id);
  });
}

// After 100 requests, there are 100 listeners for 'update'
// Node.js warns at 11: "MaxListenersExceededWarning"
for (let i = 0; i < 100; i++) {
  handleRequest({ id: i });
}

console.log(`Listener count: ${emitter.listenerCount('update')}`); // 100

// FIX: Use once(), or store and remove the listener
const emitter2 = new EventEmitter();

function handleRequestFixed(data) {
  // Option A: Use once() if you only need one notification
  emitter2.once('update', () => {
    console.log('One-time update for:', data.id);
  });

  // Option B: Store reference and remove when done
  // const handler = () => { ... };
  // emitter2.on('update', handler);
  // cleanup: emitter2.off('update', handler);
}
```

### Pattern 3: Closures Holding References

A closure captures variables from its enclosing scope, keeping those variables alive as long as the closure exists.

```javascript
'use strict';

// LEAK: Closure captures the entire large object
function createHandler() {
  const largeData = Buffer.alloc(10 * 1024 * 1024); // 10 MB

  // This closure captures largeData — even if it never uses it,
  // V8 may keep the entire scope alive
  return function handler(req) {
    // Only uses req, but largeData cannot be GC'd
    return req.url;
  };
}

// FIX: Explicitly null out large references
function createHandlerFixed() {
  let largeData = Buffer.alloc(10 * 1024 * 1024);

  // Do the work that needs largeData
  const digest = require('node:crypto')
    .createHash('sha256')
    .update(largeData)
    .digest('hex');

  largeData = null; // Release the reference

  return function handler(req) {
    // Closure now only holds digest (64 bytes), not largeData (10 MB)
    return { url: req.url, hash: digest };
  };
}
```

### Pattern 4: Global Arrays and Growing Logs

```javascript
'use strict';

// LEAK: Pushing to a global array forever
const requestLog = [];

function logRequest(req) {
  requestLog.push({
    url: req.url,
    method: req.method,
    timestamp: Date.now(),
    headers: { ...req.headers } // Deep copy of all headers
  });
  // This array grows unbounded for the lifetime of the process
}

// FIX: Circular buffer with fixed capacity
class CircularBuffer {
  constructor(capacity) {
    this._buffer = new Array(capacity);
    this._capacity = capacity;
    this._index = 0;
    this._size = 0;
  }

  push(item) {
    this._buffer[this._index] = item;
    this._index = (this._index + 1) % this._capacity;
    if (this._size < this._capacity) this._size++;
  }

  toArray() {
    if (this._size < this._capacity) {
      return this._buffer.slice(0, this._size);
    }
    return [
      ...this._buffer.slice(this._index),
      ...this._buffer.slice(0, this._index)
    ];
  }

  get size() { return this._size; }
}

const safeLog = new CircularBuffer(1000);

for (let i = 0; i < 50000; i++) {
  safeLog.push({ url: `/api/data/${i}`, timestamp: Date.now() });
}

console.log(`Log entries kept: ${safeLog.size}`); // Always 1000
```

### Pattern 5: Timers and Intervals Not Cleared

```javascript
'use strict';

// LEAK: Creating intervals that are never cleared
function startPolling(resourceId) {
  // Each call creates a NEW interval — if called repeatedly,
  // the old intervals are never cleared
  setInterval(() => {
    // Poll for updates
    console.log(`Polling ${resourceId}...`);
  }, 1000);
}

// FIX: Track and clear previous intervals
const pollingTimers = new Map();

function startPollingFixed(resourceId) {
  // Clear existing timer for this resource
  if (pollingTimers.has(resourceId)) {
    clearInterval(pollingTimers.get(resourceId));
  }

  const timer = setInterval(() => {
    console.log(`Polling ${resourceId}...`);
  }, 1000);

  pollingTimers.set(resourceId, timer);

  // Return cleanup function
  return () => {
    clearInterval(timer);
    pollingTimers.delete(resourceId);
  };
}

const cleanup = startPollingFixed('resource-1');
// When done:
// cleanup();
```

---

## Heap Snapshots with --inspect

For finding leaks that resist simple analysis, heap snapshots are the definitive tool. Start your process with `--inspect` and use Chrome DevTools to capture and compare snapshots.

```javascript
'use strict';

// Start this script with: node --inspect leak-demo.js
// Then open Chrome and navigate to chrome://inspect
// Click "inspect" on your Node.js process
// Go to the Memory tab

const http = require('node:http');

// A realistic leak: session data stored in memory without expiration
const sessions = new Map();

const server = http.createServer((req, res) => {
  const sessionId = req.headers['x-session-id'] || `sess-${Date.now()}`;

  if (!sessions.has(sessionId)) {
    sessions.set(sessionId, {
      id: sessionId,
      created: Date.now(),
      requestLog: [],   // This grows with every request
      data: {}
    });
  }

  const session = sessions.get(sessionId);
  session.requestLog.push({
    url: req.url,
    timestamp: Date.now(),
    headers: Object.keys(req.headers)
  });

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    sessionId,
    totalSessions: sessions.size,
    requestCount: session.requestLog.length,
    memoryMB: (process.memoryUsage().heapUsed / 1024 / 1024).toFixed(2)
  }));
});

server.listen(3000, () => {
  console.log('Leak demo server on http://localhost:3000');
  console.log('Open chrome://inspect to take heap snapshots');
  console.log('\nWorkflow:');
  console.log('1. Take Snapshot 1 (baseline)');
  console.log('2. Send 1000 requests with unique session IDs');
  console.log('3. Take Snapshot 2');
  console.log('4. Compare snapshots — look for growing Maps and Arrays');
});
```

**The three-snapshot technique:**

1. Take Snapshot 1 after warmup
2. Perform the suspected leaky operation
3. Take Snapshot 2
4. Perform the operation again
5. Take Snapshot 3
6. Compare Snapshot 2 vs Snapshot 3 — objects present in 3 but not in 2 were allocated *and retained* by the second round

In Chrome DevTools, use the "Comparison" view to see which constructors gained instances between snapshots. Sort by "Size Delta" to find the largest growth.

---

## Programmatic Heap Snapshots

You can trigger heap snapshots from code using `v8.writeHeapSnapshot()`, which is useful for automated leak detection in CI or production.

```javascript
'use strict';

const v8 = require('node:v8');
const path = require('node:path');

function takeSnapshot(label) {
  const filename = v8.writeHeapSnapshot();
  console.log(`[${label}] Heap snapshot written to: ${filename}`);
  return filename;
}

// Take a baseline snapshot
takeSnapshot('baseline');

// Create some objects
const data = [];
for (let i = 0; i < 50000; i++) {
  data.push({ index: i, value: `item-${i}`.repeat(10) });
}

// Take a snapshot after allocation
takeSnapshot('after-allocation');

// The .heapsnapshot files can be loaded into Chrome DevTools:
// 1. Open chrome://inspect → Open dedicated DevTools for Node
// 2. Go to Memory tab
// 3. Click "Load" and select the .heapsnapshot file
// 4. Compare the two snapshots

console.log('\nLoad these files in Chrome DevTools Memory tab to compare');
```

---

## GC Observation with --trace-gc

For understanding garbage collection behavior without DevTools, use the `--trace-gc` flag.

```javascript
'use strict';

// Run with: node --trace-gc gc-demo.js
// V8 will print every GC event to stderr

function formatMB(bytes) {
  return (bytes / 1024 / 1024).toFixed(1);
}

console.log('Watch stderr for GC events...\n');

// Phase 1: Allocate rapidly to trigger Scavenge (young gen GC)
console.log('Phase 1: Rapid allocation (triggers Scavenge)');
for (let i = 0; i < 100; i++) {
  const arr = new Array(10000).fill({ x: i });
  // arr goes out of scope and becomes eligible for GC
}

const mem1 = process.memoryUsage();
console.log(`After Phase 1 — heapUsed: ${formatMB(mem1.heapUsed)} MB\n`);

// Phase 2: Allocate and retain to trigger Mark-Sweep (old gen GC)
console.log('Phase 2: Retain allocations (triggers Mark-Sweep-Compact)');
const retained = [];
for (let i = 0; i < 200000; i++) {
  retained.push({ id: i, data: `payload-${i}` });
}

const mem2 = process.memoryUsage();
console.log(`After Phase 2 — heapUsed: ${formatMB(mem2.heapUsed)} MB\n`);

// Phase 3: Release and force GC (requires --expose-gc flag)
console.log('Phase 3: Release references');
retained.length = 0;

// If started with --expose-gc, we can force GC:
if (global.gc) {
  global.gc();
  const mem3 = process.memoryUsage();
  console.log(`After forced GC — heapUsed: ${formatMB(mem3.heapUsed)} MB`);
} else {
  console.log('Run with --expose-gc to force garbage collection');
  console.log('Example: node --trace-gc --expose-gc gc-demo.js');
}
```

**Reading --trace-gc output:**

```
[12345:0x...] 12 ms: Scavenge 2.3 (3.0) -> 1.8 (4.0) MB, 0.5 / 0.0 ms ...
[12345:0x...] 350 ms: Mark-sweep 45.2 (52.0) -> 12.1 (48.0) MB, 8.2 / 0.0 ms ...
```

- **Scavenge** — Young generation GC. Fast (< 1ms). Happens frequently.
- **Mark-sweep** — Old generation GC. Slower. The "45.2 -> 12.1" shows heap before and after. Large drops mean lots of garbage was collected.

---

## Key Takeaways

- `process.memoryUsage()` gives you five metrics: RSS (total process memory), heapTotal (V8 allocated), heapUsed (V8 live objects), external (C++ bound memory), and arrayBuffers — always check all five, not just heapUsed
- RSS growing while heapUsed is stable indicates a native/external memory leak (Buffers, file descriptors, C++ addons), not a JavaScript object leak
- The five most common JavaScript memory leaks are: unbounded caches, forgotten event listeners, closures retaining large scopes, global arrays without caps, and timers/intervals never cleared
- Heap snapshots via `--inspect` and Chrome DevTools are the definitive tool for finding leaks — use the three-snapshot comparison technique to isolate objects allocated and retained during a specific operation
- `v8.getHeapSpaceStatistics()` reveals which heap generation is growing, helping you distinguish between short-lived allocation pressure (new_space) and long-lived leaks (old_space)

## Next

Knowing your memory profile is half the picture. The next lesson covers CPU profiling — using V8's built-in profiler and flame graphs to find which functions are consuming the most execution time.
