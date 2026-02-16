# Module 03 / Lesson 07 — TypedArrays & ArrayBuffer

> Node.js `Buffer` did not appear in a vacuum. The ECMAScript specification defines `ArrayBuffer`, `Uint8Array`, and a family of TypedArray classes for working with binary data in any JavaScript runtime — browsers included. Node.js `Buffer` is actually a subclass of `Uint8Array`, which means understanding the Web standard beneath it gives you portable skills and explains why certain Buffer behaviors work the way they do.

## Learning Objectives

- Explain the relationship between `ArrayBuffer`, TypedArrays, `DataView`, and Node.js `Buffer`
- Create and manipulate `ArrayBuffer` instances and view them through different TypedArray lenses
- Use `DataView` for mixed-type, mixed-endianness reads and writes
- Convert between `Buffer` and TypedArray/ArrayBuffer without unnecessary copies
- Decide when to use `Buffer`, TypedArray, or `DataView` based on the task at hand

---

## The Three Layers of Binary Data in JavaScript

Binary data in JavaScript is organized in three layers:

1. **`ArrayBuffer`** — A fixed-length, contiguous block of raw memory. You cannot read or write it directly. Think of it as a plot of land.
2. **TypedArrays** (`Uint8Array`, `Int32Array`, `Float64Array`, etc.) — Views over an `ArrayBuffer` that impose a data type on the raw bytes. Think of them as blueprints that tell you how to interpret the land.
3. **`DataView`** — A flexible view over an `ArrayBuffer` that lets you read and write any type at any byte offset with explicit endianness. Think of it as a surveyor who can measure anything anywhere.

Node.js `Buffer` is a fourth layer: a subclass of `Uint8Array` with extra methods (`readUInt32BE`, `toString('hex')`, etc.) and a custom memory allocator.

```
┌──────────────────────────────────────┐
│            ArrayBuffer               │  ← raw memory, no type
├──────────────────────────────────────┤
│  Uint8Array  │  Int32Array  │  ...   │  ← typed views
├──────────────────────────────────────┤
│            DataView                  │  ← flexible, explicit endianness
├──────────────────────────────────────┤
│        Node.js Buffer                │  ← Uint8Array subclass + extras
└──────────────────────────────────────┘
```

---

## ArrayBuffer — The Foundation

An `ArrayBuffer` represents a fixed-length region of memory. It has no methods for reading or writing data — you need a view for that.

```javascript
'use strict';

// Allocate 16 bytes of zeroed memory
const ab = new ArrayBuffer(16);

console.log(ab.byteLength); // 16
console.log(typeof ab);     // object

// You cannot index into an ArrayBuffer directly
// ab[0] = 42; // This sets a property on the object, not a byte in memory!
```

### Key Properties

```javascript
'use strict';

const ab = new ArrayBuffer(32);

console.log(ab.byteLength);  // 32
console.log(ab.maxByteLength); // 32 (or larger if created with maxByteLength option)

// Slice creates a new ArrayBuffer with copied data
const portion = ab.slice(8, 16);
console.log(portion.byteLength); // 8
```

Unlike `Buffer.slice()`, `ArrayBuffer.slice()` **creates a copy**. This is a critical distinction to remember.

---

## TypedArray Family

TypedArrays are views that impose a specific numeric type over an `ArrayBuffer`.

| TypedArray | Bytes per Element | Range |
|-----------|-------------------|-------|
| `Int8Array` | 1 | -128 to 127 |
| `Uint8Array` | 1 | 0 to 255 |
| `Uint8ClampedArray` | 1 | 0 to 255 (clamped) |
| `Int16Array` | 2 | -32768 to 32767 |
| `Uint16Array` | 2 | 0 to 65535 |
| `Int32Array` | 4 | -2^31 to 2^31-1 |
| `Uint32Array` | 4 | 0 to 2^32-1 |
| `Float32Array` | 4 | IEEE 754 float |
| `Float64Array` | 8 | IEEE 754 double |
| `BigInt64Array` | 8 | -2^63 to 2^63-1 |
| `BigUint64Array` | 8 | 0 to 2^64-1 |

### Creating TypedArrays

```javascript
'use strict';

// From length (creates its own ArrayBuffer)
const u8 = new Uint8Array(4);
u8[0] = 255;
u8[1] = 128;
console.log(u8); // Uint8Array(4) [ 255, 128, 0, 0 ]

// From an array
const i32 = new Int32Array([100, -200, 300]);
console.log(i32); // Int32Array(3) [ 100, -200, 300 ]
console.log(i32.byteLength); // 12 (3 elements x 4 bytes each)

// From an existing ArrayBuffer
const ab = new ArrayBuffer(8);
const f64 = new Float64Array(ab);
f64[0] = Math.PI;
console.log(f64[0]); // 3.141592653589793
```

### Multiple Views Over the Same Memory

This is where TypedArrays become powerful — the same underlying bytes can be interpreted through different type lenses.

```javascript
'use strict';

const ab = new ArrayBuffer(4);

const u8  = new Uint8Array(ab);
const u32 = new Uint32Array(ab);

// Write via the 32-bit view
u32[0] = 0xDEADBEEF;

// Read via the 8-bit view — see the individual bytes
console.log(u8[0].toString(16)); // ef (least significant byte first — little-endian on x86)
console.log(u8[1].toString(16)); // be
console.log(u8[2].toString(16)); // ad
console.log(u8[3].toString(16)); // de

// The endianness here is the platform's native endianness
// On x86/ARM little-endian systems, the LSB comes first
```

This is a zero-copy technique. No data is copied — both views point to the same 4 bytes in memory. Changes through one view are instantly visible through the other.

---

## Uint8Array — Buffer's Parent Class

Since Node.js Buffer extends `Uint8Array`, every `Uint8Array` method works on Buffers, and you can use Buffers anywhere a `Uint8Array` is expected.

```javascript
'use strict';

const buf = Buffer.from([10, 20, 30, 40, 50]);

// Buffer IS a Uint8Array
console.log(buf instanceof Uint8Array); // true

// All Uint8Array methods work
console.log(buf.find(x => x > 25));     // 30
console.log(buf.filter(x => x >= 30));   // Uint8Array(3) [ 30, 40, 50 ]
console.log(buf.map(x => x * 2));        // Uint8Array(5) [ 20, 40, 60, 80, 100 ]
console.log(buf.reduce((a, b) => a + b)); // 150

// Careful: map/filter/etc return Uint8Array, NOT Buffer
const doubled = buf.map(x => x * 2);
console.log(doubled instanceof Buffer);     // false
console.log(doubled instanceof Uint8Array); // true
```

This last point is important. When you call `map`, `filter`, `slice` (the TypedArray version), or `subarray` inherited from `Uint8Array`, the return type is `Uint8Array`, not `Buffer`. If you need Buffer methods on the result, wrap it: `Buffer.from(doubled)`.

---

## DataView — Flexible Mixed-Type Access

TypedArrays are fast but limited: each view imposes a single type and uses the platform's native endianness. `DataView` lets you read and write any type at any byte offset with explicit endianness control.

```javascript
'use strict';

const ab = new ArrayBuffer(16);
const dv = new DataView(ab);

// Write a mix of types at arbitrary offsets
dv.setUint8(0, 0x01);           // 1 byte at offset 0
dv.setUint16(1, 1000, false);    // 2 bytes at offset 1, big-endian (false = BE)
dv.setInt32(3, -50000, true);    // 4 bytes at offset 3, little-endian (true = LE)
dv.setFloat64(7, 3.14159, false); // 8 bytes at offset 7, big-endian

// Read them back
console.log(dv.getUint8(0));          // 1
console.log(dv.getUint16(1, false));  // 1000
console.log(dv.getInt32(3, true));    // -50000
console.log(dv.getFloat64(7, false)); // 3.14159
```

### DataView vs Buffer Read/Write Methods

Node.js Buffer's `readUInt16BE`, `writeInt32LE`, etc. are conceptually equivalent to DataView's `getUint16`, `setInt32`, etc. The key differences:

| Feature | Buffer | DataView |
|---------|--------|----------|
| Endianness | Encoded in method name (BE/LE) | Boolean parameter (false=BE, true=LE) |
| Extra methods | `toString('hex')`, `copy`, `concat` | None — pure read/write |
| Portability | Node.js only | Any JavaScript runtime |
| Performance | Slightly faster in Node.js | Slightly slower |

```javascript
'use strict';

// Equivalent operations:

// Buffer way
const buf = Buffer.alloc(4);
buf.writeUInt32BE(0xDEADBEEF, 0);
console.log(buf.readUInt32BE(0).toString(16)); // deadbeef

// DataView way
const ab = new ArrayBuffer(4);
const dv = new DataView(ab);
dv.setUint32(0, 0xDEADBEEF, false); // false = big-endian
console.log(dv.getUint32(0, false).toString(16)); // deadbeef
```

---

## Converting Between Buffer and TypedArray/ArrayBuffer

### Buffer to ArrayBuffer

Every Buffer has an `arrayBuffer` property (via its `Uint8Array` heritage), but there is a subtlety: because of Buffer's pool allocator, the underlying `ArrayBuffer` may be much larger than the Buffer itself.

```javascript
'use strict';

const buf = Buffer.from('Hello');

// The underlying ArrayBuffer — may be the 8KB pool!
console.log(buf.buffer.byteLength); // likely 8192, not 5

// buf.byteOffset tells you where in the ArrayBuffer this Buffer starts
console.log(buf.byteOffset); // some offset within the pool

// To get a right-sized ArrayBuffer, use slice
const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
console.log(ab.byteLength); // 5
```

### The Clean Way: `buf.buffer`, `buf.byteOffset`, `buf.byteLength`

```javascript
'use strict';

function bufferToArrayBuffer(buf) {
  return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
}

const buf = Buffer.from([0x01, 0x02, 0x03]);
const ab = bufferToArrayBuffer(buf);
console.log(new Uint8Array(ab)); // Uint8Array(3) [ 1, 2, 3 ]
```

### ArrayBuffer/TypedArray to Buffer

```javascript
'use strict';

// From ArrayBuffer
const ab = new ArrayBuffer(4);
new Uint8Array(ab).set([0x0A, 0x0B, 0x0C, 0x0D]);
const buf1 = Buffer.from(ab);
console.log(buf1); // <Buffer 0a 0b 0c 0d>

// From TypedArray — shares memory!
const u32 = new Uint32Array([1, 2, 3]);
const buf2 = Buffer.from(u32.buffer);
console.log(buf2.length); // 12 (3 x 4 bytes)

// If you want a copy instead of shared memory:
const buf3 = Buffer.from(Buffer.from(u32.buffer));
```

**Warning**: `Buffer.from(arrayBuffer)` shares memory with the source. `Buffer.from(buffer)` creates a copy. This inconsistency catches people off guard.

---

## Float64Array and Int32Array in Practice

### Float64Array — Working with Double-Precision Numbers

```javascript
'use strict';

// Store a time series of sensor readings
const readings = new Float64Array(5);
readings[0] = 22.5;
readings[1] = 22.7;
readings[2] = 23.1;
readings[3] = 22.9;
readings[4] = 23.4;

// Access the raw bytes via Buffer
const buf = Buffer.from(readings.buffer);
console.log(buf.length); // 40 (5 doubles x 8 bytes)

// Read the third value using Buffer methods
console.log(buf.readDoubleBE(16)); // Not 23.1! — platform is little-endian
console.log(buf.readDoubleLE(16)); // 23.1
```

### Int32Array — Packed Integer Data

```javascript
'use strict';

// Histogram of pixel intensities (256 bins)
const histogram = new Int32Array(256);

// Simulate counting pixel values
const pixelData = Buffer.from([128, 128, 255, 0, 128, 64, 64, 255]);
for (const pixel of pixelData) {
  histogram[pixel]++;
}

console.log(histogram[0]);   // 1
console.log(histogram[64]);  // 2
console.log(histogram[128]); // 3
console.log(histogram[255]); // 2
```

---

## When to Use What

### Use `Buffer` When

- You are doing Node.js-specific I/O (files, network, streams)
- You need `toString('hex')`, `toString('base64')`, or other encoding conversions
- You need `Buffer.concat()`, `copy()`, `indexOf()`, or `compare()`
- You are working with Node.js APIs that expect `Buffer` (most of the `node:` modules)

### Use TypedArrays When

- You are performing numeric computation on homogeneous data (arrays of floats, arrays of integers)
- You need `map`, `filter`, `reduce`, `sort` on byte-level data
- You want code that runs identically in browsers and Node.js
- You are interfacing with Web APIs (`WebSocket`, `crypto.subtle`, `WebGL`)

### Use `DataView` When

- You are parsing a binary format with mixed types at arbitrary offsets
- You need explicit control over endianness (not the platform default)
- The data structure has fields of different sizes packed together
- You want maximum portability and clarity about byte ordering

```javascript
'use strict';

// Good DataView use case: parsing a binary file header
// with mixed types and big-endian byte order

function parseHeader(arrayBuffer) {
  const dv = new DataView(arrayBuffer);

  return {
    magic:    dv.getUint32(0, false),   // 4 bytes, big-endian
    version:  dv.getUint16(4, false),   // 2 bytes, big-endian
    flags:    dv.getUint8(6),           // 1 byte
    padding:  dv.getUint8(7),           // 1 byte
    fileSize: dv.getFloat64(8, false),  // 8 bytes, big-endian
  };
}

// Good TypedArray use case: processing audio samples
function normalizeAudio(samples) {
  const f32 = new Float32Array(samples);
  const max = f32.reduce((m, v) => Math.max(m, Math.abs(v)), 0);
  return f32.map(v => v / max);
}

// Good Buffer use case: reading a file and extracting text
// const data = require('node:fs').readFileSync('file.txt');
// const text = data.toString('utf8');
```

---

## SharedArrayBuffer (Brief Note)

`SharedArrayBuffer` is like `ArrayBuffer` but can be shared across Worker threads. This is the foundation of multi-threaded memory sharing in Node.js.

```javascript
'use strict';

// SharedArrayBuffer works with all the same views
const sab = new SharedArrayBuffer(16);
const view = new Int32Array(sab);

view[0] = 42;
console.log(view[0]); // 42

// In a multi-threaded context, you would pass sab to a Worker
// and both threads could read/write the same memory
// (with Atomics for synchronization — covered in Module 09)
```

We will cover `SharedArrayBuffer` and `Atomics` in depth in Module 09 (Multithreading). For now, know that it exists and that the TypedArray/DataView layer works the same way over shared memory.

---

## Key Takeaways

- `ArrayBuffer` is raw memory with no type; TypedArrays and `DataView` are views that impose structure on those bytes
- Node.js `Buffer` is a subclass of `Uint8Array` — every Uint8Array method works on Buffers, but `map`/`filter`/`slice` return `Uint8Array`, not `Buffer`
- `DataView` gives you explicit endianness control and mixed-type access at arbitrary offsets, making it ideal for parsing binary protocols and file formats
- When converting between Buffer and ArrayBuffer, remember that Buffer's underlying ArrayBuffer may be the 8KB pool — always use `buf.byteOffset` and `buf.byteLength` to extract the correct slice
- Choose `Buffer` for Node.js I/O, TypedArrays for homogeneous numeric computation, and `DataView` for mixed-type binary parsing with explicit endianness

---

## Next

In [Lesson 08 — Buffer Performance & Memory Management](lesson-08-buffer-performance.md) you will learn how Buffer's pool allocator works under the hood, benchmark `alloc` vs `allocUnsafe`, master zero-copy patterns, and identify the memory leaks that Buffers can cause in long-running servers.
