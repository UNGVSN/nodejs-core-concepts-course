# Module 03 / Lesson 04 — Buffer Creation & Allocation

> Creating a Buffer seems trivial — call a constructor and get bytes. But the way you create a Buffer determines whether it is safe (zero-filled) or fast (uninitialized with potentially sensitive data from previous operations). Understanding the allocation strategies — `alloc`, `allocUnsafe`, `from`, and the internal 8 KB pool — is the difference between writing secure, performant code and leaking passwords into network responses.

## Learning Objectives

- Choose the correct Buffer creation method (`alloc`, `allocUnsafe`, `from`) for each use case
- Explain the security implications of uninitialized memory in `allocUnsafe`
- Describe how the internal 8 KB Buffer pool works and why `allocUnsafeSlow` bypasses it
- Use `Buffer.from()` to create Buffers from strings, arrays, other Buffers, and ArrayBuffers
- Apply utility methods like `Buffer.byteLength()`, `Buffer.isBuffer()`, `Buffer.isEncoding()`, and `Buffer.concat()`

---

## The Three Allocation Methods

Node.js provides three methods for creating Buffers of a given size:

```javascript
'use strict';

// 1. Buffer.alloc(size) — zero-filled, safe, slightly slower
const safe = Buffer.alloc(16);
console.log(safe); // <Buffer 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00>

// 2. Buffer.allocUnsafe(size) — NOT zero-filled, fast, may contain old data
const fast = Buffer.allocUnsafe(16);
console.log(fast); // <Buffer ?? ?? ?? ... > — unpredictable content

// 3. Buffer.allocUnsafeSlow(size) — NOT zero-filled, not pooled
const unpooled = Buffer.allocUnsafeSlow(16);
console.log(unpooled); // <Buffer ?? ?? ?? ... > — unpredictable content
```

| Method | Zero-filled | Uses Pool | Speed | Safety |
|--------|------------|-----------|-------|--------|
| `Buffer.alloc(size)` | Yes | No | Baseline | Safe |
| `Buffer.allocUnsafe(size)` | No | Yes (if size <= poolSize/2) | Fastest | Dangerous |
| `Buffer.allocUnsafeSlow(size)` | No | No | Fast | Dangerous |

---

## `Buffer.alloc(size)` — The Safe Default

`Buffer.alloc()` creates a zero-filled Buffer. Every byte is guaranteed to be `0x00`. This is the method you should use by default.

```javascript
'use strict';

// Basic allocation
const buf = Buffer.alloc(8);
console.log(buf); // <Buffer 00 00 00 00 00 00 00 00>

// Verify every byte is zero
for (let i = 0; i < buf.length; i++) {
  if (buf[i] !== 0) {
    console.log('Non-zero byte found!'); // Never fires
  }
}
console.log('All bytes zero: true');

// Alloc with fill value (second parameter)
const filled = Buffer.alloc(8, 0xFF);
console.log(filled); // <Buffer ff ff ff ff ff ff ff ff>

// Alloc with string fill
const abc = Buffer.alloc(10, 'abc', 'utf8');
console.log(abc); // <Buffer 61 62 63 61 62 63 61 62 63 61>
console.log(abc.toString()); // abcabcabca — pattern repeats to fill the buffer

// Alloc with Buffer fill
const pattern = Buffer.from([0xDE, 0xAD]);
const repeated = Buffer.alloc(8, pattern);
console.log(repeated); // <Buffer de ad de ad de ad de ad>
```

### Why Zero-Filling Matters

When the operating system gives your process a chunk of memory, that memory may contain data from a previous operation — database passwords, encryption keys, user data from another request. `Buffer.alloc()` overwrites all of it with zeros before you use it.

```javascript
'use strict';

// With alloc: guaranteed clean slate
const safe = Buffer.alloc(256);
const safeStr = safe.toString('utf8');
console.log('Contains only null bytes:', safeStr === '\0'.repeat(256)); // true
```

---

## `Buffer.allocUnsafe(size)` — Speed at a Cost

`Buffer.allocUnsafe()` skips zero-filling. The Buffer is created immediately with whatever bytes happened to be in that memory region. This is faster but potentially dangerous.

```javascript
'use strict';

// allocUnsafe may contain stale data from previous operations
const buf = Buffer.allocUnsafe(256);

// Check if any bytes are non-zero
let nonZeroCount = 0;
for (let i = 0; i < buf.length; i++) {
  if (buf[i] !== 0) nonZeroCount++;
}

console.log(`Non-zero bytes: ${nonZeroCount} out of ${buf.length}`);
// In a long-running process, this is almost always > 0
```

### Demonstrating the Security Risk

```javascript
'use strict';

// Step 1: Create a buffer with sensitive data
const secret = Buffer.from('password=hunter2&token=abc123xyz');

// Step 2: The buffer goes out of scope (not garbage collected yet)
// In a real application, this could be a password, credit card, JWT...

// Step 3: Later, allocUnsafe might return that same memory
// Run this in a loop to increase the chances
function findLeakedData() {
  for (let i = 0; i < 1000; i++) {
    const buf = Buffer.allocUnsafe(1024);
    const content = buf.toString('utf8');
    if (content.includes('password') || content.includes('token')) {
      console.log('LEAKED DATA FOUND in allocUnsafe buffer!');
      console.log('Content:', content.substring(0, 80));
      return true;
    }
  }
  return false;
}

// In production, this can and does happen:
// findLeakedData();

// The fix: ALWAYS use Buffer.alloc() when the buffer will be
// sent to users, written to files, or transmitted over the network
// before being fully overwritten.
```

### When allocUnsafe Is Acceptable

`allocUnsafe` is safe when you will immediately overwrite every byte before anyone reads the Buffer:

```javascript
'use strict';

const fs = require('node:fs');

// OK: Every byte will be overwritten by fs.readSync
const readBuf = Buffer.allocUnsafe(4096);
// fs.readSync(fd, readBuf, 0, 4096, 0);
// All bytes 0 through bytesRead-1 are now file data

// OK: Filling the entire buffer with computed values
const computed = Buffer.allocUnsafe(256);
for (let i = 0; i < 256; i++) {
  computed[i] = i; // Every byte explicitly set
}
console.log(computed);

// NOT OK: Allocating a buffer and only partially filling it
// The unfilled portion may contain stale data
const partial = Buffer.allocUnsafe(100);
partial.write('Hello', 0, 'utf8'); // Only writes 5 bytes
// Bytes 5-99 contain unknown data — DO NOT send this to a client!
```

---

## The Internal Buffer Pool

When you call `Buffer.allocUnsafe()` for sizes up to half of `Buffer.poolSize` (default: 4096 bytes, since `poolSize` is 8192), Node.js does not allocate a new block of memory. Instead, it carves a slice from a pre-allocated 8 KB slab.

```
┌──────────────────────────────────────────────────────┐
│                  8 KB Buffer Pool (Slab)             │
├────────┬────────┬────────┬───────────────────────────┤
│ Buf A  │ Buf B  │ Buf C  │     Unused space          │
│ 100 B  │ 256 B  │ 50 B   │                           │
├────────┴────────┴────────┴───────────────────────────┤
│ poolOffset advances →                                │
└──────────────────────────────────────────────────────┘
```

```javascript
'use strict';

// Default pool size
console.log('Pool size:', Buffer.poolSize); // 8192

// These small allocations share the same underlying ArrayBuffer
const a = Buffer.allocUnsafe(100);
const b = Buffer.allocUnsafe(256);
const c = Buffer.allocUnsafe(50);

// They share the same ArrayBuffer (the pool slab)
console.log('Same underlying ArrayBuffer:',
  a.buffer === b.buffer && b.buffer === c.buffer
); // true (usually)

// Different byte offsets within that shared ArrayBuffer
console.log('a offset:', a.byteOffset);
console.log('b offset:', b.byteOffset);
console.log('c offset:', c.byteOffset);

// When the pool is exhausted, a new 8 KB slab is allocated
// This is invisible to your code
```

### Why the Pool Matters

The pool reduces the number of memory allocations. Allocating memory from the OS is expensive — it involves system calls, page table updates, and potential context switches. The pool amortizes that cost across many small Buffer allocations.

```javascript
'use strict';

// Pool allocation (fast): one system call for many buffers
const pooled = [];
for (let i = 0; i < 100; i++) {
  pooled.push(Buffer.allocUnsafe(64)); // Carved from pool slab
}

// Non-pooled allocation (slower): one system call per buffer
const nonPooled = [];
for (let i = 0; i < 100; i++) {
  nonPooled.push(Buffer.allocUnsafeSlow(64)); // Separate allocation each time
}
```

### The Pool and Memory Leaks

Because pooled buffers share an underlying `ArrayBuffer`, keeping a reference to one small Buffer can prevent the entire 8 KB slab from being garbage collected.

```javascript
'use strict';

// This tiny 10-byte buffer keeps the entire 8 KB slab alive
const tiny = Buffer.allocUnsafe(10);

// If you need to hold onto a small piece of a pooled buffer long-term,
// copy it to its own allocation:
const independent = Buffer.from(tiny); // Creates a copy with its own ArrayBuffer
console.log(independent.buffer === tiny.buffer); // false — separate memory
```

---

## `Buffer.allocUnsafeSlow(size)` — Bypassing the Pool

`Buffer.allocUnsafeSlow()` allocates memory directly from the OS without using the internal pool. It is uninitialized (like `allocUnsafe`) but never pooled.

```javascript
'use strict';

// Each call gets its own ArrayBuffer allocation
const a = Buffer.allocUnsafeSlow(100);
const b = Buffer.allocUnsafeSlow(100);

console.log(a.buffer === b.buffer); // false — always separate allocations
console.log(a.byteOffset); // 0 — starts at the beginning of its own ArrayBuffer
console.log(b.byteOffset); // 0

// Use case: when you need a buffer that will live long-term and you
// do not want it to pin an 8 KB pool slab in memory
```

### Decision Matrix

```
Need a Buffer of size N?
│
├── Will you overwrite every byte before reading?
│   ├── Yes → Is N <= 4096?
│   │         ├── Yes → Buffer.allocUnsafe(N)  [fastest: pooled]
│   │         └── No  → Buffer.allocUnsafe(N)  [fast: direct alloc]
│   └── No  → Buffer.alloc(N)  [safe: zero-filled]
│
├── Will buffer live a long time? (cache, global)
│   └── Yes → Buffer.allocUnsafeSlow(N) or Buffer.alloc(N)
│             (avoid pinning pool slab)
│
└── Default: Buffer.alloc(N)
```

---

## `Buffer.from()` — Creating from Existing Data

`Buffer.from()` is an overloaded factory method with several signatures.

### From a String

```javascript
'use strict';

// Buffer.from(string, encoding)
const utf8 = Buffer.from('Hello, world!', 'utf8');
console.log(utf8); // <Buffer 48 65 6c 6c 6f 2c 20 77 6f 72 6c 64 21>
console.log(utf8.length); // 13

// Default encoding is 'utf8'
const defaultEnc = Buffer.from('Hello');
console.log(defaultEnc.toString()); // Hello

// Different encodings produce different Buffers
const hex = Buffer.from('48656c6c6f', 'hex');
console.log(hex.toString('utf8')); // Hello

const base64 = Buffer.from('SGVsbG8=', 'base64');
console.log(base64.toString('utf8')); // Hello

// Multi-byte characters
const emoji = Buffer.from('\u{1F600}', 'utf8');
console.log(emoji.length); // 4 bytes
console.log(emoji.toString('hex')); // f09f9880
```

### From an Array of Bytes

```javascript
'use strict';

// Buffer.from(array) — each element is clamped to 0-255
const buf = Buffer.from([72, 101, 108, 108, 111]);
console.log(buf.toString()); // Hello

// Values outside 0-255 are clamped (modulo 256)
const clamped = Buffer.from([256, -1, 300]);
console.log(clamped[0]); // 0   (256 % 256)
console.log(clamped[1]); // 255 (-1 → unsigned)
console.log(clamped[2]); // 44  (300 % 256)

// Hex bytes for readability
const header = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
console.log(header.toString('ascii', 1, 4)); // PNG — it is a PNG signature!
```

### From Another Buffer (Copy)

```javascript
'use strict';

// Buffer.from(buffer) creates an independent copy
const original = Buffer.from('Hello');
const copy = Buffer.from(original);

// Modifying the copy does not affect the original
copy[0] = 0x4A; // 'J'
console.log(original.toString()); // Hello (unchanged)
console.log(copy.toString());     // Jello

// They have separate underlying memory
console.log(original.buffer === copy.buffer); // false
```

### From an ArrayBuffer (Shared View)

```javascript
'use strict';

// Buffer.from(arrayBuffer, byteOffset, length) creates a VIEW, not a copy
const ab = new ArrayBuffer(16);
const view = new Uint8Array(ab);
view[0] = 0x48; // 'H'
view[1] = 0x69; // 'i'

// Create a Buffer that shares memory with the ArrayBuffer
const buf = Buffer.from(ab, 0, 2);
console.log(buf.toString()); // Hi

// Changes in one are visible in the other
view[0] = 0x59; // 'Y'
console.log(buf.toString()); // Yi — shared memory!

buf[1] = 0x6F; // 'o'
console.log(view[1]); // 111 (0x6F) — visible in the Uint8Array

// To create an independent copy from an ArrayBuffer:
const independent = Buffer.from(Buffer.from(ab));
view[0] = 0x41; // 'A'
console.log(independent[0]); // 89 (0x59) — still 'Y', not affected
```

### From a TypedArray

```javascript
'use strict';

// Buffer.from(typedArray) creates a COPY (not a view)
const uint16 = new Uint16Array([0x0048, 0x0065, 0x006C, 0x006C, 0x006F]);
const buf = Buffer.from(uint16);

// Note: only the low byte of each Uint16 element is used
console.log(buf.length); // 5 (not 10)
console.log(buf.toString()); // Hello

// This is a copy, not a shared view
uint16[0] = 0x004A;
console.log(buf[0]); // 72 (0x48) — unchanged
```

---

## Buffer.poolSize

You can adjust the size of the internal pool slab. The default is 8192 (8 KB).

```javascript
'use strict';

console.log('Default pool size:', Buffer.poolSize); // 8192

// You can change it (affects future allocations)
Buffer.poolSize = 16384; // 16 KB pool
const buf = Buffer.allocUnsafe(100);
console.log('New pool size:', Buffer.poolSize); // 16384

// Reset to default
Buffer.poolSize = 8192;

// Buffers larger than poolSize / 2 get their own allocation
// even with allocUnsafe
const large = Buffer.allocUnsafe(Buffer.poolSize); // 8192 bytes
console.log(large.byteOffset); // 0 — not from the pool (too large)
```

---

## Utility Methods

### `Buffer.byteLength()`

Returns the byte length of a string in a given encoding without creating a Buffer.

```javascript
'use strict';

// String length vs byte length
const ascii = 'Hello';
console.log('string.length:', ascii.length);                  // 5
console.log('byte length:',   Buffer.byteLength(ascii, 'utf8')); // 5

const unicode = 'cafe\u0301'; // cafe with combining accent
console.log('string.length:', unicode.length);                    // 5
console.log('UTF-8 bytes:',   Buffer.byteLength(unicode, 'utf8')); // 6

const cjk = '\u4E16\u754C'; // Two Chinese characters
console.log('string.length:', cjk.length);                      // 2
console.log('UTF-8 bytes:',   Buffer.byteLength(cjk, 'utf8'));   // 6
console.log('UTF-16LE bytes:', Buffer.byteLength(cjk, 'utf16le')); // 4

// Also works with Buffers, ArrayBuffers, and TypedArrays
const buf = Buffer.from('Hello');
console.log(Buffer.byteLength(buf)); // 5
```

### `Buffer.isBuffer()`

```javascript
'use strict';

console.log(Buffer.isBuffer(Buffer.alloc(4)));        // true
console.log(Buffer.isBuffer(Buffer.from('Hi')));      // true
console.log(Buffer.isBuffer(new Uint8Array(4)));      // false
console.log(Buffer.isBuffer('Hello'));                 // false
console.log(Buffer.isBuffer(null));                    // false
console.log(Buffer.isBuffer(42));                      // false

// Buffer is a subclass of Uint8Array
const buf = Buffer.alloc(4);
console.log(buf instanceof Uint8Array); // true
console.log(buf instanceof Buffer);     // true
```

### `Buffer.isEncoding()`

```javascript
'use strict';

// Check if an encoding name is valid
console.log(Buffer.isEncoding('utf8'));     // true
console.log(Buffer.isEncoding('utf-8'));    // true (alias)
console.log(Buffer.isEncoding('UTF-8'));    // true (case-insensitive)
console.log(Buffer.isEncoding('hex'));      // true
console.log(Buffer.isEncoding('base64'));   // true
console.log(Buffer.isEncoding('base64url'));// true
console.log(Buffer.isEncoding('latin1'));   // true
console.log(Buffer.isEncoding('binary'));   // true
console.log(Buffer.isEncoding('ascii'));    // true
console.log(Buffer.isEncoding('utf16le')); // true

// Invalid encodings
console.log(Buffer.isEncoding('utf32'));    // false
console.log(Buffer.isEncoding('windows-1252')); // false
console.log(Buffer.isEncoding(''));         // false
console.log(Buffer.isEncoding(null));       // false
```

---

## `Buffer.concat()` — Combining Multiple Buffers

`Buffer.concat()` joins an array of Buffers into a single new Buffer.

```javascript
'use strict';

const a = Buffer.from('Hello');
const b = Buffer.from(', ');
const c = Buffer.from('world!');

const combined = Buffer.concat([a, b, c]);
console.log(combined.toString()); // Hello, world!
console.log(combined.length);     // 13

// The result is a new, independent buffer
a[0] = 0x4A; // 'J'
console.log(combined.toString()); // Hello, world! — not affected
```

### Specifying Total Length

If you know the total length in advance, pass it as the second argument to avoid an extra traversal to compute the length.

```javascript
'use strict';

const chunks = [
  Buffer.from('aaa'),
  Buffer.from('bbb'),
  Buffer.from('ccc'),
];

// Without totalLength — Node.js iterates once to compute length, then again to copy
const auto = Buffer.concat(chunks);
console.log(auto.length); // 9

// With totalLength — slightly faster, skips length computation
const manual = Buffer.concat(chunks, 9);
console.log(manual.length); // 9

// If totalLength is shorter, the result is truncated
const truncated = Buffer.concat(chunks, 6);
console.log(truncated.toString()); // aaabbb

// If totalLength is longer, the extra bytes are zero-filled
const padded = Buffer.concat(chunks, 12);
console.log(padded.toString('hex')); // 616161626262636363000000
```

### Efficient Chunk Collection Pattern

```javascript
'use strict';

// Common pattern: collecting chunks from a stream
function collectChunks(readable) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalLength = 0;

    readable.on('data', (chunk) => {
      chunks.push(chunk);
      totalLength += chunk.length;
    });

    readable.on('end', () => {
      resolve(Buffer.concat(chunks, totalLength));
    });

    readable.on('error', reject);
  });
}

// Usage (with a file stream):
// const fs = require('node:fs');
// const stream = fs.createReadStream('/tmp/data.bin');
// const fullBuffer = await collectChunks(stream);
```

---

## Memory Model: Where Buffers Live

Buffers occupy memory outside the V8 JavaScript heap. The raw bytes live in C++ (libuv/V8 external memory), but the Buffer object itself (the JavaScript wrapper) lives on the V8 heap and is tracked by the garbage collector.

```
┌─────────────────────────────────┐
│         V8 Heap (JavaScript)    │
│                                 │
│  ┌───────────────────┐          │
│  │ Buffer object      │ ──────────── reference ──┐
│  │ .length = 1024     │          │               │
│  │ .byteOffset = 0    │          │               │
│  └───────────────────┘          │               │
│                                 │               │
└─────────────────────────────────┘               │
                                                  ▼
┌─────────────────────────────────────────────────────┐
│          C++ External Memory                         │
│                                                     │
│  ┌──────────────────────────────────────────┐       │
│  │  1024 bytes of raw data                   │       │
│  │  [0x48] [0x65] [0x6C] [0x6C] [0x6F] ...  │       │
│  └──────────────────────────────────────────┘       │
│                                                     │
└─────────────────────────────────────────────────────┘
```

```javascript
'use strict';

const v8 = require('node:v8');

// V8 heap statistics
const heapBefore = v8.getHeapStatistics().used_heap_size;

// Allocate 10 MB in Buffers (outside V8 heap)
const bigBuf = Buffer.alloc(10 * 1024 * 1024);

const heapAfter = v8.getHeapStatistics().used_heap_size;

console.log('V8 heap growth:', heapAfter - heapBefore, 'bytes');
// Much less than 10 MB — only the Buffer wrapper object is on the heap

// process.memoryUsage() shows both
const mem = process.memoryUsage();
console.log('heapUsed:',     mem.heapUsed);     // V8 heap
console.log('external:',     mem.external);     // C++ allocations (includes Buffers)
console.log('arrayBuffers:', mem.arrayBuffers); // ArrayBuffer memory (subset of external)
```

### Garbage Collection

When the Buffer object on the V8 heap is collected, the C++ memory is freed. But the GC only knows about the small JavaScript object — it does not see the 10 MB of external memory. This means Buffer-heavy applications may appear to use little heap memory while consuming large amounts of RSS. GC frequency is based on heap pressure, not external memory pressure, so Buffer-heavy apps may need manual tuning.

---

## The Deprecated `new Buffer()` Constructor

Before Node.js v6, Buffers were created with `new Buffer()`. This is now deprecated because it was overloaded in a way that made security bugs easy.

```javascript
'use strict';

// DO NOT USE — deprecated and dangerous
// new Buffer(10)         → allocUnsafe (uninitialized!)
// new Buffer('hello')    → from string
// new Buffer([1, 2, 3])  → from array

// The problem: new Buffer(userInput) where userInput could be
// a number (allocating uninitialized memory) or a string

// Modern equivalents:
// new Buffer(10)         → Buffer.alloc(10)     or Buffer.allocUnsafe(10)
// new Buffer('hello')    → Buffer.from('hello')
// new Buffer([1, 2, 3])  → Buffer.from([1, 2, 3])
```

Node.js emits a deprecation warning (`DEP0005`) if you use `new Buffer()`. ESLint's `no-buffer-constructor` rule catches this statically.

---

## Key Takeaways

- `Buffer.alloc(size)` is the safe default — it zero-fills memory and prevents information leakage from previous operations; use it unless you have a measured performance reason not to
- `Buffer.allocUnsafe(size)` is faster because it skips zero-filling, but the buffer may contain sensitive data from previous memory operations — only use it when you will immediately overwrite every byte
- Small `allocUnsafe` buffers (up to `poolSize / 2`) are carved from a shared 8 KB slab to minimize allocation overhead; holding a reference to a tiny pooled buffer pins the entire slab in memory
- `Buffer.from()` creates Buffers from strings, arrays, other Buffers, and ArrayBuffers — from a Buffer it copies, from an ArrayBuffer it creates a shared view
- Buffer memory lives outside the V8 heap (in C++ external memory), but the Buffer JavaScript object is tracked by V8's garbage collector; this means RSS can be high even when heap usage looks low

---

## Next

Continue to [Lesson 05 — Buffer Reading & Writing](lesson-05-buffer-reading-writing.md) where you will learn how to read and write integers, floats, and strings at specific byte offsets — the fundamental skills for parsing network protocols and binary file formats.
