# Module 03 / Lesson 08 — Buffer Performance & Memory Management

> In a high-throughput server, Buffer allocation and deallocation can happen millions of times per second. How Node.js allocates those Buffers — pooled or unpooled, zeroed or unzeroed — has measurable impact on throughput, latency, and memory usage. This lesson opens the hood on Buffer's pool allocator, benchmarks the allocation strategies, and teaches you the zero-copy patterns and memory-leak traps that separate toy code from production code.

## Learning Objectives

- Explain how Node.js Buffer pool allocation works (the 8KB slab)
- Benchmark `Buffer.alloc()` vs `Buffer.allocUnsafe()` and understand the performance/security trade-off
- Apply zero-copy patterns to avoid unnecessary memory allocation in hot paths
- Configure `--max-old-space-size` to control V8 heap limits for Buffer-heavy workloads
- Identify and fix the most common sources of Buffer memory leaks

---

## The 8KB Pool: How Buffer Allocation Really Works

When you call `Buffer.allocUnsafe()` or `Buffer.from()` for small Buffers (less than half the pool size), Node.js does not ask the operating system for new memory each time. Instead, it maintains a pre-allocated **slab** — a single 8192-byte (`Buffer.poolSize`) chunk — and hands out slices of it.

```javascript
'use strict';

console.log(Buffer.poolSize); // 8192

// These two small buffers likely share the same underlying ArrayBuffer
const a = Buffer.allocUnsafe(10);
const b = Buffer.allocUnsafe(20);

console.log(a.buffer === b.buffer); // true — same 8KB pool slab
console.log(a.byteOffset);         // 0 (or wherever the pool cursor was)
console.log(b.byteOffset);         // 16 (aligned after 'a', with possible padding)
```

### How the Pool Fills Up

```
Pool slab (8192 bytes):
┌────────────┬──────────────┬───────────┬──────────────────────────────┐
│ Buffer 'a' │  Buffer 'b'  │ Buffer 'c'│        free space             │
│  (10 bytes)│  (20 bytes)  │ (100 bytes│                              │
└────────────┴──────────────┴───────────┴──────────────────────────────┘
  offset 0      offset 16     offset 40    offset 140 → 8191
```

When the remaining space in the slab is too small for the next allocation, Node.js allocates a fresh 8KB slab and starts filling that one. The old slab stays alive as long as any Buffer referencing it exists.

### The Pool Retention Problem

This is a subtle but important memory issue:

```javascript
'use strict';

function getSmallSlice() {
  // Allocate a large-ish buffer from the pool
  const big = Buffer.allocUnsafe(4000);

  // Return a tiny 4-byte slice
  return big.subarray(0, 4);
}

const tiny = getSmallSlice();
// 'tiny' is only 4 bytes, but it holds a reference to the entire
// 8KB pool slab. The GC cannot free the slab until 'tiny' is released.
```

If you accumulate many such tiny references, each one pins an 8KB slab in memory. The fix: copy the data into its own buffer when storing long-lived small values.

```javascript
'use strict';

function getSmallSliceSafely() {
  const big = Buffer.allocUnsafe(4000);
  // Copy into an independent buffer — does not pin the pool
  return Buffer.from(big.subarray(0, 4));
}
```

---

## `alloc()` vs `allocUnsafe()` — Benchmarking the Difference

`Buffer.alloc(size)` always zeroes the memory. `Buffer.allocUnsafe(size)` skips zeroing, which means the buffer may contain old data from previous allocations — including potentially sensitive information like passwords or cryptographic keys.

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

function benchmark(label, fn, iterations = 100_000) {
  const start = performance.now();
  for (let i = 0; i < iterations; i++) {
    fn();
  }
  const elapsed = performance.now() - start;
  console.log(`${label}: ${elapsed.toFixed(2)}ms for ${iterations} iterations`);
}

// Small buffers (pool-allocated)
benchmark('alloc(64)',       () => Buffer.alloc(64));
benchmark('allocUnsafe(64)', () => Buffer.allocUnsafe(64));

// Medium buffers (still pool-eligible)
benchmark('alloc(4000)',       () => Buffer.alloc(4000));
benchmark('allocUnsafe(4000)', () => Buffer.allocUnsafe(4000));

// Large buffers (direct allocation, no pool)
benchmark('alloc(16384)',       () => Buffer.alloc(16384));
benchmark('allocUnsafe(16384)', () => Buffer.allocUnsafe(16384));
```

Typical results on modern hardware:

| Size | `alloc` | `allocUnsafe` | Speedup |
|------|---------|---------------|---------|
| 64 bytes | ~45ms | ~20ms | ~2x |
| 4000 bytes | ~90ms | ~25ms | ~3.5x |
| 16384 bytes | ~180ms | ~60ms | ~3x |

### When to Use Each

| Scenario | Method | Reason |
|----------|--------|--------|
| Receiving network data you will immediately overwrite | `allocUnsafe` | Every byte will be written before read |
| Buffer you return to users or log | `alloc` | Prevents information leakage |
| Buffer for cryptographic operations | `alloc` | Security-critical; never leak old key material |
| Temporary scratch buffer in a hot loop | `allocUnsafe` | Performance-critical, fully overwritten |
| Default / when unsure | `alloc` | Safety first |

```javascript
'use strict';

// SAFE: allocUnsafe is fine because we immediately fill every byte
function createHeader(type, length) {
  const buf = Buffer.allocUnsafe(4);
  buf.writeUInt16BE(type, 0);
  buf.writeUInt16BE(length, 2);
  return buf;
}

// DANGEROUS: allocUnsafe exposes stale data
function createResponse(statusCode) {
  const buf = Buffer.allocUnsafe(256);
  buf.writeUInt16BE(statusCode, 0);
  // bytes 2-255 contain whatever was in memory before!
  return buf; // DO NOT send this over the network
}
```

---

## Zero-Copy Patterns

"Zero-copy" means processing data without duplicating it in memory. In a high-throughput server, avoiding copies can be the difference between handling 10K and 100K requests per second.

### Pattern 1: `subarray()` Instead of `slice()` + Copy

```javascript
'use strict';

const incoming = Buffer.from('HEADER:payload-data-here');

// Zero-copy: parse without allocating new memory
const colonIndex = incoming.indexOf(0x3A); // ':'
const header  = incoming.subarray(0, colonIndex);
const payload = incoming.subarray(colonIndex + 1);

// Both header and payload point into 'incoming' — no new memory allocated
console.log(header.toString());  // HEADER
console.log(payload.toString()); // payload-data-here
```

### Pattern 2: Reuse a Single Buffer

```javascript
'use strict';

const net = require('node:net');

// Pre-allocate a read buffer — reused for every connection
const READ_BUFFER_SIZE = 65536;

function createConnectionHandler() {
  // Each connection gets its own reusable buffer
  const readBuf = Buffer.allocUnsafe(READ_BUFFER_SIZE);

  return function handleData(socket) {
    socket.on('data', (chunk) => {
      // Process chunk directly — do not copy it unless you need to store it
      const messageType = chunk.readUInt8(0);
      // ... process based on type
    });
  };
}
```

### Pattern 3: Writev — Scatter/Gather I/O

Instead of concatenating Buffers into one large Buffer before writing, pass an array of Buffers to `writev()`. The OS kernel combines them in a single system call without copying.

```javascript
'use strict';

const net = require('node:net');

function sendResponse(socket, statusLine, headers, body) {
  // BAD: concat allocates a new buffer
  // const response = Buffer.concat([statusLine, headers, body]);
  // socket.write(response);

  // GOOD: writev sends multiple buffers without copying
  socket.cork();
  socket.write(statusLine);
  socket.write(headers);
  socket.write(body);
  socket.uncork(); // Flushes all writes in a single writev() syscall
}
```

### Pattern 4: Direct Buffer Passing in Streams

```javascript
'use strict';

const fs = require('node:fs');

// Pipe a file to the network — Node.js handles this with minimal copying
// The ReadStream produces Buffers that pass through to the WriteStream
// without intermediate copies

function serveFile(filePath, socket) {
  const readStream = fs.createReadStream(filePath);
  readStream.pipe(socket);
  // Under the hood, the same Buffer references flow from
  // the file read callback to the socket write callback
}
```

---

## `--max-old-space-size` and Buffer Memory

V8's garbage collector manages JavaScript objects in the "heap." Buffers are a hybrid: the Buffer **object** lives on the V8 heap, but the actual **byte data** may live outside it (for large Buffers, V8 allocates "external" memory via `ArrayBuffer`).

```javascript
'use strict';

const v8 = require('node:v8');

// Check current heap statistics
const stats = v8.getHeapStatistics();
console.log('Heap size limit:', (stats.heap_size_limit / 1024 / 1024).toFixed(0), 'MB');
console.log('Total available:', (stats.total_available_size / 1024 / 1024).toFixed(0), 'MB');
```

### Setting the Heap Limit

```bash
# Default is ~1.5GB on 64-bit systems
node --max-old-space-size=4096 server.js   # 4GB heap
node --max-old-space-size=512 server.js    # 512MB heap (for constrained environments)
```

### Monitoring Buffer Memory Usage

```javascript
'use strict';

function logMemoryUsage() {
  const usage = process.memoryUsage();
  console.log({
    rss:          `${(usage.rss / 1024 / 1024).toFixed(1)} MB`,     // total process memory
    heapUsed:     `${(usage.heapUsed / 1024 / 1024).toFixed(1)} MB`, // V8 heap used
    heapTotal:    `${(usage.heapTotal / 1024 / 1024).toFixed(1)} MB`, // V8 heap allocated
    external:     `${(usage.external / 1024 / 1024).toFixed(1)} MB`, // C++ objects (Buffers!)
    arrayBuffers: `${(usage.arrayBuffers / 1024 / 1024).toFixed(1)} MB`, // ArrayBuffer memory
  });
}

// Demonstrate: allocating Buffers increases 'external' and 'arrayBuffers'
logMemoryUsage();

const buffers = [];
for (let i = 0; i < 1000; i++) {
  buffers.push(Buffer.alloc(1024 * 1024)); // 1MB each
}

logMemoryUsage();
// 'external' and 'arrayBuffers' will jump by ~1000 MB
// 'heapUsed' will increase only modestly (the Buffer objects are small)
```

The `arrayBuffers` field (added in Node.js 12) specifically tracks memory used by `ArrayBuffer` instances, which includes Buffer backing stores. This is the most accurate metric for tracking Buffer memory.

---

## Common Buffer Memory Leaks

### Leak 1: Accumulating Chunks Without Bounds

```javascript
'use strict';

// BAD: unbounded chunk accumulation
class BadStreamCollector {
  #chunks = [];

  addChunk(chunk) {
    this.#chunks.push(chunk); // Grows forever if the stream never ends
  }
}

// GOOD: enforce a maximum size
class BoundedStreamCollector {
  #chunks = [];
  #totalBytes = 0;
  #maxBytes;

  constructor(maxBytes = 10 * 1024 * 1024) { // 10MB default
    this.#maxBytes = maxBytes;
  }

  addChunk(chunk) {
    if (this.#totalBytes + chunk.length > this.#maxBytes) {
      throw new Error(`Stream exceeds max size of ${this.#maxBytes} bytes`);
    }
    this.#chunks.push(chunk);
    this.#totalBytes += chunk.length;
  }

  getResult() {
    return Buffer.concat(this.#chunks, this.#totalBytes);
  }

  clear() {
    this.#chunks = [];
    this.#totalBytes = 0;
  }
}
```

### Leak 2: Pool Slab Pinning (The Tiny Reference Problem)

```javascript
'use strict';

// BAD: small slices pin entire 8KB pool slabs
const cache = new Map();

function cacheHeader(id, data) {
  // 'data' is a large pool-allocated buffer
  // Storing a subarray pins the entire pool slab
  cache.set(id, data.subarray(0, 8)); // 8 bytes pin 8192 bytes
}

// GOOD: copy small values to independent buffers
function cacheHeaderSafely(id, data) {
  cache.set(id, Buffer.from(data.subarray(0, 8))); // independent 8-byte allocation
}
```

### Leak 3: Closures Capturing Buffers

```javascript
'use strict';

// BAD: closure keeps the large buffer alive
function processData(largeBuffer) {
  const metadata = largeBuffer.readUInt32BE(0);

  // This closure captures 'largeBuffer' — it cannot be GC'd
  // even though we only need 'metadata'
  return function getMetadata() {
    return metadata;
  };
}

// GOOD: extract what you need, let the buffer be collected
function processDataSafely(largeBuffer) {
  const metadata = largeBuffer.readUInt32BE(0);
  // largeBuffer is NOT referenced in the returned closure

  return function getMetadata() {
    return metadata;
  };
}
```

### Leak 4: Event Listeners Holding Buffer References

```javascript
'use strict';

const EventEmitter = require('node:events');

// BAD: each listener closure captures its buffer
const emitter = new EventEmitter();
const bufferStore = [];

function attachLeakyListener(data) {
  const buf = Buffer.from(data);

  emitter.on('process', () => {
    // This closure captures 'buf' — it lives as long as the listener exists
    console.log(buf.length);
  });
}

// After 10,000 calls, 10,000 buffers are trapped in listener closures
// Fix: use removeListener, or store only the data you need (not the buffer)
```

---

## Profiling Buffer Allocations

### Using `--trace-gc`

```bash
node --trace-gc server.js
```

This prints a line for every garbage collection, including the time spent. Look for frequent GC pauses that correlate with heavy Buffer allocation.

### Using `process.memoryUsage()` at Intervals

```javascript
'use strict';

setInterval(() => {
  const usage = process.memoryUsage();
  const mb = (bytes) => (bytes / 1024 / 1024).toFixed(1);
  console.log(
    `[memory] rss=${mb(usage.rss)}MB heap=${mb(usage.heapUsed)}MB ` +
    `external=${mb(usage.external)}MB buffers=${mb(usage.arrayBuffers)}MB`
  );
}, 5000);
```

### Detecting Buffer Growth Over Time

```javascript
'use strict';

class MemoryMonitor {
  #samples = [];
  #interval;

  start(intervalMs = 10_000) {
    this.#interval = setInterval(() => {
      const usage = process.memoryUsage();
      this.#samples.push({
        timestamp: Date.now(),
        external: usage.external,
        arrayBuffers: usage.arrayBuffers,
        rss: usage.rss,
      });

      // Keep only the last 100 samples
      if (this.#samples.length > 100) {
        this.#samples.shift();
      }

      // Check for sustained growth
      if (this.#samples.length >= 10) {
        const first = this.#samples[0].arrayBuffers;
        const last = this.#samples[this.#samples.length - 1].arrayBuffers;
        const growthMB = (last - first) / 1024 / 1024;

        if (growthMB > 50) {
          console.warn(`[WARNING] ArrayBuffer memory grew by ${growthMB.toFixed(1)}MB — possible Buffer leak`);
        }
      }
    }, intervalMs);
  }

  stop() {
    clearInterval(this.#interval);
  }
}
```

---

## Allocation Strategy Comparison

Here is a summary of every Buffer allocation method and its characteristics:

| Method | Zeroed? | Pooled? | Use Case |
|--------|---------|---------|----------|
| `Buffer.alloc(size)` | Yes | No | Default safe allocation |
| `Buffer.alloc(size, fill)` | Filled | No | Pre-filled buffers |
| `Buffer.allocUnsafe(size)` | No | Yes (<4KB) | Hot paths where you will overwrite every byte |
| `Buffer.allocUnsafeSlow(size)` | No | No | Large buffers without pool overhead |
| `Buffer.from(array)` | N/A | Yes (<4KB) | Creating from known data |
| `Buffer.from(string, enc)` | N/A | Yes (<4KB) | String-to-buffer conversion |
| `Buffer.from(buffer)` | N/A | Yes (<4KB) | Copying an existing buffer |

### `allocUnsafeSlow()` — When You Want Direct Allocation

`allocUnsafeSlow()` bypasses the pool entirely. Each call allocates a new `ArrayBuffer` from the OS. This is useful when you need Buffers that are independently garbage-collectible.

```javascript
'use strict';

const a = Buffer.allocUnsafeSlow(100);
const b = Buffer.allocUnsafeSlow(100);

console.log(a.buffer === b.buffer); // false — each has its own ArrayBuffer
// Compare with:
const c = Buffer.allocUnsafe(100);
const d = Buffer.allocUnsafe(100);
console.log(c.buffer === d.buffer); // true — same pool slab
```

Use `allocUnsafeSlow()` when each Buffer has a different lifetime and you want the GC to be able to collect them independently.

---

## Practical: High-Throughput Packet Processing

Putting it all together — a buffer allocation strategy for a packet processor handling 100K+ packets per second.

```javascript
'use strict';

const HEADER_SIZE = 12;
const MAX_PAYLOAD = 65536;

class PacketProcessor {
  // Pre-allocate a reusable header buffer — never allocate in the hot path
  #headerBuf = Buffer.allocUnsafe(HEADER_SIZE);

  // Reusable payload buffer — resized only when needed
  #payloadBuf = Buffer.allocUnsafe(MAX_PAYLOAD);

  processPacket(rawData) {
    // Zero-copy header read — subarray into rawData
    const type     = rawData.readUInt8(0);
    const flags    = rawData.readUInt8(1);
    const sequence = rawData.readUInt32BE(2);
    const length   = rawData.readUInt16BE(6);

    // Validate before reading payload
    if (length > MAX_PAYLOAD) {
      throw new Error(`Payload too large: ${length}`);
    }

    // Zero-copy payload reference
    const payload = rawData.subarray(HEADER_SIZE, HEADER_SIZE + length);

    // Only copy if we need to store this packet beyond the current tick
    if (type === 0x01) {
      return {
        type,
        flags,
        sequence,
        payload: Buffer.from(payload), // copy for storage
      };
    }

    // For transient processing, use the zero-copy reference
    return { type, flags, sequence, payload };
  }
}
```

---

## Key Takeaways

- Node.js pools small Buffers (under ~4KB) into 8KB slabs (`Buffer.poolSize`) to avoid per-allocation OS overhead — but this means small `subarray()` references can pin large slabs in memory
- `Buffer.allocUnsafe()` is 2-3x faster than `Buffer.alloc()` because it skips zeroing, but it may expose stale memory — only use it when you will overwrite every byte before reading
- Zero-copy patterns (`subarray`, `cork`/`uncork` writev, stream piping) eliminate the allocation overhead in hot paths; copy data only when you need to store it beyond the current processing tick
- Monitor `process.memoryUsage().arrayBuffers` to track Buffer memory separately from the V8 heap; sustained growth indicates a leak
- The most common Buffer leaks are unbounded chunk accumulation, pool slab pinning from tiny references, and closures that accidentally capture large Buffers

---

## Next

With Buffers mastered, you are ready to work with the file system. In [Module 04 / Lesson 01 — File Descriptors & Handles](../module-04-filesystem/lesson-01-file-descriptors-handles.md) you will learn what a file descriptor really is at the OS level and how Node.js wraps it.
