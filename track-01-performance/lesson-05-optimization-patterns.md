# Track 01 / Lesson 05 — Optimization Patterns

> Most "Node.js performance tips" found online are cargo-culted micro-optimizations that make no measurable difference. This lesson focuses on the patterns that actually matter — the ones that show up in flame graphs, the ones that prevent event loop stalls under load, and the ones that determine whether your server handles 1,000 requests per second or 10,000. Every pattern here is backed by the profiling and benchmarking techniques you learned in the previous lessons.

## Learning Objectives

- Evaluate when streaming data reduces memory pressure versus when it adds unnecessary overhead
- Offload CPU-intensive work to worker threads using a threshold-based decision heuristic
- Configure `http.Agent` connection pooling to eliminate TCP handshake overhead for outbound requests
- Apply object reuse, allocation reduction, and `Buffer.allocUnsafe` safely in hot paths
- Avoid megamorphic property access and hidden class instability to keep V8's TurboFan optimizations intact

---

## Pattern 1: Stream vs Buffer Trade-offs

Streams are not always faster. They reduce peak memory by processing data in chunks, but they add overhead through object creation, backpressure management, and event emission. The trade-off depends on data size and processing complexity.

```javascript
'use strict';

const fs = require('node:fs');
const { createHash } = require('node:crypto');
const { performance } = require('node:perf_hooks');
const path = require('node:path');

// Approach 1: Buffer — read entire file into memory, then hash
function hashWithBuffer(filePath) {
  return new Promise((resolve, reject) => {
    fs.readFile(filePath, (err, data) => {
      if (err) return reject(err);
      const hash = createHash('sha256').update(data).digest('hex');
      resolve(hash);
    });
  });
}

// Approach 2: Stream — pipe file through hash incrementally
function hashWithStream(filePath) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    const stream = fs.createReadStream(filePath);

    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
    stream.on('error', reject);
  });
}

// Benchmark both approaches
async function compareMethods(filePath) {
  const stat = fs.statSync(filePath);
  const sizeMB = (stat.size / 1024 / 1024).toFixed(2);

  // Buffer approach
  const memBefore1 = process.memoryUsage().heapUsed;
  const start1 = performance.now();
  const hash1 = await hashWithBuffer(filePath);
  const time1 = performance.now() - start1;
  const memAfter1 = process.memoryUsage().heapUsed;

  // Stream approach
  const memBefore2 = process.memoryUsage().heapUsed;
  const start2 = performance.now();
  const hash2 = await hashWithStream(filePath);
  const time2 = performance.now() - start2;
  const memAfter2 = process.memoryUsage().heapUsed;

  console.log(`File: ${filePath} (${sizeMB} MB)`);
  console.log(`  Buffer: ${time1.toFixed(2)}ms | Memory delta: ${((memAfter1 - memBefore1) / 1024).toFixed(0)} KB`);
  console.log(`  Stream: ${time2.toFixed(2)}ms | Memory delta: ${((memAfter2 - memBefore2) / 1024).toFixed(0)} KB`);
  console.log(`  Hashes match: ${hash1 === hash2}`);
}

// Use this script's own source as a small test file
compareMethods(__filename).catch(console.error);
```

**When to use streams:**

- File or payload is **larger than available memory** (obvious)
- File is **larger than ~10 MB** — buffer approach spikes RSS
- You are processing data **in a pipeline** (read, transform, write) — streams compose naturally
- You are handling **concurrent requests** — each buffered request holds the full payload in memory simultaneously

**When buffers are fine (or better):**

- Data is **under 1 MB** — stream overhead (event emission, object creation per chunk) exceeds the memory savings
- You need **random access** to the data (seeking, slicing) — streams are sequential
- The operation is a **single transformation** with no pipeline — `readFile` + process is simpler and often faster

---

## Pattern 2: Worker Thread Offloading

The event loop should never spend more than a few milliseconds on synchronous computation. When a function takes longer, offload it to a worker thread. The threshold heuristic: **if it blocks for more than 5ms, move it to a worker.**

```javascript
'use strict';

const {
  Worker,
  isMainThread,
  parentPort,
  workerData
} = require('node:worker_threads');

if (!isMainThread) {
  // Worker code: perform CPU-intensive computation
  const { task, data } = workerData;

  let result;
  switch (task) {
    case 'hash': {
      const { createHash } = require('node:crypto');
      result = createHash('sha256').update(data).digest('hex');
      break;
    }
    case 'sort': {
      const arr = JSON.parse(data);
      arr.sort((a, b) => a - b);
      result = JSON.stringify(arr);
      break;
    }
    case 'compute': {
      let sum = 0;
      const iterations = parseInt(data, 10);
      for (let i = 0; i < iterations; i++) {
        sum += Math.sqrt(i) * Math.sin(i);
      }
      result = sum;
      break;
    }
    default:
      result = null;
  }

  parentPort.postMessage(result);
} else {
  // Main thread code

  function runInWorker(task, data) {
    return new Promise((resolve, reject) => {
      const worker = new Worker(__filename, {
        workerData: { task, data }
      });

      worker.on('message', resolve);
      worker.on('error', reject);
      worker.on('exit', (code) => {
        if (code !== 0) reject(new Error(`Worker exited with code ${code}`));
      });
    });
  }

  // Decision heuristic: measure synchronous time, offload if > threshold
  const { performance } = require('node:perf_hooks');
  const OFFLOAD_THRESHOLD_MS = 5;

  function shouldOffload(fn) {
    const start = performance.now();
    fn();
    const elapsed = performance.now() - start;
    return elapsed > OFFLOAD_THRESHOLD_MS;
  }

  async function main() {
    // Test 1: Small computation — keep on main thread
    const smallWork = () => {
      let s = 0;
      for (let i = 0; i < 1000; i++) s += Math.sqrt(i);
      return s;
    };

    console.log('Small computation should offload:', shouldOffload(smallWork));
    // false — runs in < 1ms

    // Test 2: Large computation — offload to worker
    const largeWork = () => {
      let s = 0;
      for (let i = 0; i < 1e7; i++) s += Math.sqrt(i) * Math.sin(i);
      return s;
    };

    console.log('Large computation should offload:', shouldOffload(largeWork));
    // true — runs in > 50ms

    // Actually offload the large computation
    const start = performance.now();
    const result = await runInWorker('compute', '10000000');
    console.log(`Worker result: ${result} in ${(performance.now() - start).toFixed(1)}ms`);

    // The main thread event loop was NOT blocked during that computation
  }

  main().catch(console.error);
}
```

**Worker thread overhead:** Creating a worker takes approximately 5-30ms and allocates ~5 MB of memory. For tasks under 5ms, the overhead exceeds the computation time. For tasks over 50ms, the overhead is negligible. For intermediate tasks (5-50ms), profile to decide. For thread pool patterns that reuse workers across multiple tasks, see Module 09 Lesson 06.

---

## Pattern 3: Connection Pooling with http.Agent

Every outbound HTTP request without an agent creates a new TCP connection — a 3-way handshake that adds 1-50ms of latency. `http.Agent` reuses connections via keep-alive.

```javascript
'use strict';

const http = require('node:http');

// Default agent: keep-alive is disabled — every request opens a new connection
// Custom agent: keep-alive enabled with connection pooling
const pooledAgent = new http.Agent({
  keepAlive: true,           // Reuse connections
  keepAliveMsecs: 30000,     // Send TCP keep-alive probes every 30s
  maxSockets: 50,            // Max 50 concurrent connections per host
  maxFreeSockets: 10,        // Keep up to 10 idle connections
  timeout: 60000             // Socket timeout: 60s
});

function makeRequest(agent, requestId) {
  return new Promise((resolve, reject) => {
    const options = {
      hostname: 'localhost',
      port: 3000,
      path: '/api/data',
      method: 'GET',
      agent: agent  // Pass the pooled agent
    };

    const start = Date.now();
    const req = http.request(options, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        resolve({
          requestId,
          statusCode: res.statusCode,
          elapsed: Date.now() - start,
          connection: res.headers['connection']
        });
      });
    });

    req.on('error', reject);
    req.end();
  });
}

// Agent configuration by traffic level:
// Low   (< 100 req/s):  maxSockets: 10,  maxFreeSockets: 5
// Med   (100-1000 req/s): maxSockets: 50,  maxFreeSockets: 10
// High  (> 1000 req/s): maxSockets: 200, maxFreeSockets: 25
// Note: maxSockets is PER HOST, not global

// When you are done with the agent:
// pooledAgent.destroy();
```

**Key insight:** Node.js's default `http.globalAgent` has `keepAlive: false` in versions before Node.js 19. Starting with Node.js 19, the default agent has `keepAlive: true`. If you are on an older version, always create a custom agent with `keepAlive: true` for outbound requests.

---

## Pattern 4: Avoiding JSON.parse on Hot Paths

`JSON.parse` and `JSON.stringify` are synchronous and their execution time scales linearly with payload size. On a hot path (thousands of calls per second), this becomes a bottleneck.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// Problem: Parsing a large JSON payload on every request
function parseFullPayload(jsonString) {
  const obj = JSON.parse(jsonString);
  // But we only need one field!
  return obj.status;
}

// Solution 1: Extract just the field you need with a regex
// Only works for simple, known structures
function extractField(jsonString, field) {
  const regex = new RegExp(`"${field}"\\s*:\\s*"([^"]*)"`, 's');
  const match = jsonString.match(regex);
  return match ? match[1] : null;
}

// Benchmark
const largeObj = {};
for (let i = 0; i < 5000; i++) {
  largeObj[`field_${i}`] = { value: `data-${i}`, nested: { level: i } };
}
largeObj.status = 'active';

const jsonString = JSON.stringify(largeObj);
console.log(`JSON payload size: ${(jsonString.length / 1024).toFixed(1)} KB`);

// Warmup
for (let i = 0; i < 1000; i++) {
  parseFullPayload(jsonString);
  extractField(jsonString, 'status');
}

// Measure
const iterations = 1000;

let start = performance.now();
let sink = '';
for (let i = 0; i < iterations; i++) {
  sink = parseFullPayload(jsonString);
}
console.log(`JSON.parse:     ${(performance.now() - start).toFixed(2)}ms (${sink})`);

start = performance.now();
for (let i = 0; i < iterations; i++) {
  sink = extractField(jsonString, 'status');
}
console.log(`Regex extract:  ${(performance.now() - start).toFixed(2)}ms (${sink})`);
```

**When this matters:** Only when you are parsing large JSON payloads (> 100 KB) on a hot path (> 100 times/second). For small payloads or infrequent parsing, `JSON.parse` is fine.

---

## Pattern 5: Object Reuse and Allocation Reduction

Every object allocation puts pressure on the garbage collector. In hot loops, reusing objects instead of creating new ones can significantly reduce GC pauses.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// BAD: Creating new objects in a hot loop
function processWithAllocation(data) {
  const results = [];
  for (let i = 0; i < data.length; i++) {
    // New object on every iteration
    results.push({
      index: i,
      value: data[i] * 2,
      squared: data[i] * data[i],
      label: `item-${i}`
    });
  }
  return results;
}

// GOOD: Pre-allocate and reuse the result array
function processWithReuse(data) {
  const len = data.length;
  const results = new Array(len);

  for (let i = 0; i < len; i++) {
    // Still creates objects, but the array is pre-sized
    results[i] = {
      index: i,
      value: data[i] * 2,
      squared: data[i] * data[i],
      label: `item-${i}`
    };
  }
  return results;
}

// BEST: Object pool for truly hot paths
class ObjectPool {
  constructor(factory, reset, initialSize = 100) {
    this._factory = factory;
    this._reset = reset;
    this._pool = [];

    for (let i = 0; i < initialSize; i++) {
      this._pool.push(factory());
    }
  }

  acquire() {
    if (this._pool.length > 0) {
      return this._pool.pop();
    }
    return this._factory();
  }

  release(obj) {
    this._reset(obj);
    this._pool.push(obj);
  }

  get available() {
    return this._pool.length;
  }
}

// Pool usage example
const resultPool = new ObjectPool(
  // Factory: create a new result object
  () => ({ index: 0, value: 0, squared: 0, label: '' }),
  // Reset: clear the object for reuse
  (obj) => { obj.index = 0; obj.value = 0; obj.squared = 0; obj.label = ''; },
  1000
);

function processWithPool(data) {
  const len = data.length;
  const results = new Array(len);

  for (let i = 0; i < len; i++) {
    const obj = resultPool.acquire();
    obj.index = i;
    obj.value = data[i] * 2;
    obj.squared = data[i] * data[i];
    obj.label = `item-${i}`;
    results[i] = obj;
  }

  return results;
}

function releaseResults(results) {
  for (const obj of results) {
    resultPool.release(obj);
  }
}

// Benchmark
const data = Array.from({ length: 50000 }, () => Math.random() * 100);

// Warmup
for (let i = 0; i < 100; i++) {
  processWithAllocation(data);
  processWithReuse(data);
  const r = processWithPool(data);
  releaseResults(r);
}

const iterations = 50;

let start = performance.now();
for (let i = 0; i < iterations; i++) processWithAllocation(data);
console.log(`New objects:    ${(performance.now() - start).toFixed(2)}ms`);

start = performance.now();
for (let i = 0; i < iterations; i++) processWithReuse(data);
console.log(`Pre-allocated:  ${(performance.now() - start).toFixed(2)}ms`);

start = performance.now();
for (let i = 0; i < iterations; i++) {
  const r = processWithPool(data);
  releaseResults(r);
}
console.log(`Object pool:    ${(performance.now() - start).toFixed(2)}ms`);
```

**Object pooling trade-offs:** Pools add complexity and can cause subtle bugs if objects are not properly reset. Use them only when profiling shows that GC pauses are a measurable problem in a specific hot path.

---

## Pattern 6: Buffer.allocUnsafe When Safe to Do So

`Buffer.alloc(size)` zero-fills the buffer, which is safe but costs CPU time. `Buffer.allocUnsafe(size)` skips zero-filling, which is faster but may contain old memory data.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// Safe: Zero-filled (secure, but slower for large allocations)
function allocSafe(size) {
  return Buffer.alloc(size);
}

// Unsafe: Not zero-filled (faster, but contains old memory)
function allocUnsafe(size) {
  return Buffer.allocUnsafe(size);
}

// When is allocUnsafe safe to use?
// When you will OVERWRITE every byte before reading

// Example: Reading a file into a buffer — every byte will be overwritten
const fs = require('node:fs');

function readFileUnsafe(fd, size) {
  // Safe because fs.read() overwrites the buffer contents
  const buf = Buffer.allocUnsafe(size);
  fs.readSync(fd, buf, 0, size, 0);
  return buf;
}

// Example: Filling a buffer with computed data
function fillBuffer(size) {
  // Safe because every byte is written before anyone reads
  const buf = Buffer.allocUnsafe(size);
  for (let i = 0; i < size; i++) {
    buf[i] = i % 256;
  }
  return buf;
}

// DANGEROUS: Returning allocUnsafe without filling
function dangerousAlloc(size) {
  const buf = Buffer.allocUnsafe(size);
  // NOT filling the buffer — it may contain passwords,
  // keys, or other sensitive data from previous allocations!
  return buf; // NEVER send this to a client
}

// Benchmark
const sizes = [64, 1024, 64 * 1024, 1024 * 1024];

for (const size of sizes) {
  const label = size >= 1024 * 1024
    ? `${size / 1024 / 1024} MB`
    : size >= 1024
      ? `${size / 1024} KB`
      : `${size} B`;

  // Warmup
  for (let i = 0; i < 1000; i++) {
    allocSafe(size);
    allocUnsafe(size);
  }

  const iterations = 10000;

  let start = performance.now();
  for (let i = 0; i < iterations; i++) allocSafe(size);
  const safeTime = performance.now() - start;

  start = performance.now();
  for (let i = 0; i < iterations; i++) allocUnsafe(size);
  const unsafeTime = performance.now() - start;

  const speedup = (safeTime / unsafeTime).toFixed(1);
  console.log(
    `${label.padEnd(8)} alloc: ${safeTime.toFixed(1)}ms | ` +
    `allocUnsafe: ${unsafeTime.toFixed(1)}ms | ` +
    `speedup: ${speedup}x`
  );
}
```

**Rule:** Use `Buffer.allocUnsafe` only when you will overwrite every byte before the buffer is read or sent anywhere. Common safe cases: reading from file descriptors, receiving network data, and filling with computed values.

---

## Pattern 7: Hidden Class Stability

V8 assigns a "hidden class" (internal Map) to every object based on its property names and order. Objects with the same hidden class share optimized property access code. When objects diverge, V8 falls back to slow dictionary-mode lookups.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// BAD: Objects with inconsistent shapes
function createUsersInconsistent(count) {
  const users = [];
  for (let i = 0; i < count; i++) {
    const user = { id: i, name: `User ${i}` };
    // Conditionally adding properties creates DIFFERENT hidden classes
    if (i % 2 === 0) user.email = `user${i}@example.com`;
    if (i % 3 === 0) user.phone = '555-0100';
    if (i % 5 === 0) user.address = '123 Main St';
    users.push(user);
  }
  return users;
}

// GOOD: All objects have the same shape
function createUsersConsistent(count) {
  const users = [];
  for (let i = 0; i < count; i++) {
    // Every object has ALL properties — use null for missing values
    users.push({
      id: i,
      name: `User ${i}`,
      email: i % 2 === 0 ? `user${i}@example.com` : null,
      phone: i % 3 === 0 ? '555-0100' : null,
      address: i % 5 === 0 ? '123 Main St' : null
    });
  }
  return users;
}

// Function that accesses properties — benefits from hidden class stability
function sumIds(users) {
  let total = 0;
  for (let i = 0; i < users.length; i++) {
    total += users[i].id;
  }
  return total;
}

function collectEmails(users) {
  const emails = [];
  for (let i = 0; i < users.length; i++) {
    if (users[i].email) emails.push(users[i].email);
  }
  return emails;
}

const count = 100000;
const inconsistent = createUsersInconsistent(count);
const consistent = createUsersConsistent(count);

// Warmup
for (let i = 0; i < 100; i++) {
  sumIds(inconsistent);
  sumIds(consistent);
  collectEmails(inconsistent);
  collectEmails(consistent);
}

const iterations = 100;

let start = performance.now();
let sink = 0;
for (let i = 0; i < iterations; i++) sink += sumIds(inconsistent);
console.log(`sumIds (inconsistent): ${(performance.now() - start).toFixed(2)}ms`);

start = performance.now();
for (let i = 0; i < iterations; i++) sink += sumIds(consistent);
console.log(`sumIds (consistent):   ${(performance.now() - start).toFixed(2)}ms`);

start = performance.now();
let emailSink = [];
for (let i = 0; i < iterations; i++) emailSink = collectEmails(inconsistent);
console.log(`collectEmails (inconsistent): ${(performance.now() - start).toFixed(2)}ms`);

start = performance.now();
for (let i = 0; i < iterations; i++) emailSink = collectEmails(consistent);
console.log(`collectEmails (consistent):   ${(performance.now() - start).toFixed(2)}ms`);

if (sink === -1) console.log(sink, emailSink.length);
```

**Rules for hidden class stability:**

1. **Always initialize all properties in the constructor or object literal** — do not add properties conditionally after creation
2. **Initialize properties in the same order** — `{ a: 1, b: 2 }` has a different hidden class than `{ b: 2, a: 1 }`
3. **Use `null` for absent values** rather than omitting the property
4. **Avoid `delete`** — it forces objects into slow dictionary mode
5. **Do not change property types** — a property that starts as a number should stay a number

---

## Pattern 8: Avoiding Megamorphic Call Sites

When a function receives objects with different hidden classes at the same call site, V8 must use a generic (slow) property access path. This is called a "megamorphic" call site.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// Monomorphic: always receives the same type
function getNameMono(obj) {
  return obj.name;
}

// Test with consistent objects (monomorphic)
function Point(x, y, name) {
  this.x = x;
  this.y = y;
  this.name = name;
}

const monoObjects = [];
for (let i = 0; i < 100000; i++) {
  monoObjects.push(new Point(i, i * 2, `point-${i}`));
}

// Test with mixed object types (megamorphic)
function Circle(r, name) { this.r = r; this.name = name; }
function Rect(w, h, name) { this.w = w; this.h = h; this.name = name; }
function Triangle(a, b, c, name) { this.a = a; this.b = b; this.c = c; this.name = name; }

const megaObjects = [];
for (let i = 0; i < 100000; i++) {
  switch (i % 4) {
    case 0: megaObjects.push(new Point(i, i, `p-${i}`)); break;
    case 1: megaObjects.push(new Circle(i, `c-${i}`)); break;
    case 2: megaObjects.push(new Rect(i, i, `r-${i}`)); break;
    case 3: megaObjects.push(new Triangle(i, i, i, `t-${i}`)); break;
  }
}

// Warmup
for (let i = 0; i < monoObjects.length; i++) getNameMono(monoObjects[i]);
// Note: use a SEPARATE function for mega to avoid polluting mono
function getNameMega(obj) {
  return obj.name;
}
for (let i = 0; i < megaObjects.length; i++) getNameMega(megaObjects[i]);

// Benchmark
const iterations = 200;
let sink = '';

let start = performance.now();
for (let iter = 0; iter < iterations; iter++) {
  for (let i = 0; i < monoObjects.length; i++) {
    sink = getNameMono(monoObjects[i]);
  }
}
console.log(`Monomorphic: ${(performance.now() - start).toFixed(2)}ms`);

start = performance.now();
for (let iter = 0; iter < iterations; iter++) {
  for (let i = 0; i < megaObjects.length; i++) {
    sink = getNameMega(megaObjects[i]);
  }
}
console.log(`Megamorphic: ${(performance.now() - start).toFixed(2)}ms`);

if (sink === '__impossible__') console.log(sink);

// Megamorphic access is typically 2-5x slower than monomorphic
```

**Fixing megamorphic sites:**

- Use a common base class or ensure all objects passed to a function have the same hidden class
- If you must handle different types, use explicit type checks at the top of the function rather than relying on duck typing
- Separate hot paths: do not mix object types through the same function if performance matters

---

## Optimization Decision Checklist

Before optimizing, ask these questions in order:

1. **Have you profiled it?** Run `--cpu-prof` and look at the flame graph. If the function is not in the top 10 widest boxes, optimizing it will not help.
2. **Is it the event loop or worker threads?** Check event loop utilization. If ELU < 50%, the bottleneck is probably I/O or downstream services, not your code.
3. **Is it CPU or memory?** High CPU + low memory = algorithmic optimization. Low CPU + growing memory = leak or excessive allocation.
4. **Can you avoid the work entirely?** Caching, memoization, or skipping unnecessary computation is always faster than optimizing the computation itself.
5. **Can you do less work?** Process fewer items, use a more efficient algorithm, reduce payload sizes, paginate results.
6. **Can you offload the work?** Worker threads for CPU. Streams for memory. Background jobs for latency-tolerant tasks.
7. **Can you batch the work?** Batch database queries, aggregate network requests, buffer writes.
8. **Have you benchmarked the fix?** Profile again after the change. Confirm the improvement is real and statistically significant.

---

## Key Takeaways

- Streams reduce peak memory for large data (> 10 MB) but add overhead for small payloads — buffer the data when it fits comfortably in memory and you need random access or simple transformation
- Offload synchronous computation to worker threads when it blocks the event loop for more than 5ms — use a thread pool to amortize the ~5-30ms worker creation overhead across multiple tasks
- Configure `http.Agent` with `keepAlive: true` and tuned `maxSockets` for outbound HTTP requests — connection reuse eliminates TCP handshake latency that adds up under concurrent load
- Hidden class stability is the most impactful V8-level optimization: always initialize all properties in the same order, use `null` for absent values instead of omitting properties, and never `delete` properties from objects in hot paths
- Before optimizing anything, profile it — the optimization decision tree starts with "have you profiled it?" and ends with "have you benchmarked the fix?" because unmeasured optimization is guesswork

## Next

This concludes Track 01 — Performance & Profiling. You now have the tools and patterns to measure event loop health, diagnose memory leaks, read flame graphs, benchmark with statistical rigor, and apply optimizations that make a measurable difference. Return to the [Track 01 README](README.md) for a summary of the full track.
