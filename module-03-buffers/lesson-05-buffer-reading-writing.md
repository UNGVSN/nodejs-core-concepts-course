# Module 03 / Lesson 05 — Buffer Reading & Writing

> A Buffer is an array of bytes, but raw bytes are meaningless until you impose structure. This lesson teaches you how to read and write integers, floats, and strings at specific byte offsets — the same skills network protocol parsers, file format readers, and hardware interfaces demand every day.

## Learning Objectives

- Read unsigned and signed integers of various widths from a Buffer using the correct method
- Write integers and floating-point numbers at precise byte offsets
- Distinguish big-endian (BE) and little-endian (LE) byte ordering and choose the right one for your protocol
- Extract strings from Buffers using `toString()` with explicit encoding parameters
- Perform byte offset arithmetic to navigate multi-field binary structures

---

## The Read/Write Method Naming Convention

Every Buffer read/write method follows a naming pattern:

```
read<Type><Size><Endianness>(offset)
write<Type><Size><Endianness>(value, offset)
```

Where:

- **Type**: `UInt` (unsigned integer), `Int` (signed integer), `Float`, `Double`
- **Size**: `8`, `16`, `32` (bits) — omitted for Float (32-bit) and Double (64-bit)
- **Endianness**: `BE` (big-endian) or `LE` (little-endian) — omitted for 8-bit (no byte ordering needed)

```javascript
'use strict';

const buf = Buffer.from([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);

// 8-bit reads — no endianness suffix
console.log(buf.readUInt8(0));   // 1
console.log(buf.readInt8(0));    // 1 (same for positive values < 128)

// 16-bit reads — endianness matters
console.log(buf.readUInt16BE(0)); // 258  (0x0102)
console.log(buf.readUInt16LE(0)); // 513  (0x0201)

// 32-bit reads
console.log(buf.readUInt32BE(0)); // 16909060  (0x01020304)
console.log(buf.readUInt32LE(0)); // 67305985  (0x04030201)
```

Notice how the same bytes produce completely different numbers depending on endianness. This is one of the most common sources of binary data bugs.

---

## Reading Unsigned Integers

Unsigned integers have no sign bit — every bit contributes to magnitude. The range is always 0 to 2^N - 1.

```javascript
'use strict';

const buf = Buffer.from([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA]);

// readUInt8(offset) — 1 byte, range: 0 to 255
console.log(buf.readUInt8(0));    // 255 (0xFF)
console.log(buf.readUInt8(1));    // 254 (0xFE)

// readUInt16BE(offset) — 2 bytes, range: 0 to 65535
console.log(buf.readUInt16BE(0)); // 65534 (0xFFFE)
console.log(buf.readUInt16LE(0)); // 65279 (0xFEFF)

// readUInt32BE(offset) — 4 bytes, range: 0 to 4294967295
console.log(buf.readUInt32BE(0)); // 4294901244 (0xFFFEFDFC)
console.log(buf.readUInt32LE(0)); // 4244504319 (0xFCFDFEFF)
```

### Why Offset Matters

The offset parameter tells the read method where to start within the Buffer. It is a byte offset, not a bit offset, not an element index for multi-byte values.

```javascript
'use strict';

// A buffer representing two 16-bit values: 1000 and 2000 (big-endian)
const buf = Buffer.alloc(4);
buf.writeUInt16BE(1000, 0); // bytes 0-1
buf.writeUInt16BE(2000, 2); // bytes 2-3

console.log(buf); // <Buffer 03 e8 07 d0>

// Read them back
console.log(buf.readUInt16BE(0)); // 1000
console.log(buf.readUInt16BE(2)); // 2000

// Wrong offset — reads the wrong pair of bytes
console.log(buf.readUInt16BE(1)); // 59399 (0xE807) — garbage
```

---

## Reading Signed Integers

Signed integers use two's complement representation. The most significant bit is the sign bit — 0 for positive, 1 for negative.

```javascript
'use strict';

const buf = Buffer.alloc(4);

// Writing a negative number
buf.writeInt8(-42, 0);
console.log(buf[0]);           // 214 (0xD6) — two's complement of -42
console.log(buf.readUInt8(0)); // 214 — unsigned interpretation
console.log(buf.readInt8(0));  // -42 — signed interpretation

// Ranges:
// Int8:  -128 to 127
// Int16: -32768 to 32767
// Int32: -2147483648 to 2147483647

// Signed 16-bit example
buf.writeInt16BE(-1000, 0);
console.log(buf.readInt16BE(0));  // -1000
console.log(buf.readUInt16BE(0)); // 64536 (unsigned interpretation of same bytes)
```

The difference between `readInt` and `readUInt` is purely about interpretation. The bytes in the Buffer do not change — only the meaning you assign to them changes.

---

## Big-Endian vs Little-Endian

Endianness defines the order in which bytes represent a multi-byte value.

- **Big-endian (BE)**: Most significant byte first. Network protocols (TCP/IP), Java, and many file formats use this. It is also called "network byte order."
- **Little-endian (LE)**: Least significant byte first. Intel/AMD CPUs, Windows, and most desktop hardware use this.

```javascript
'use strict';

const buf = Buffer.alloc(4);
const value = 0x0A0B0C0D; // 168496141 in decimal

buf.writeUInt32BE(value, 0);
console.log(buf); // <Buffer 0a 0b 0c 0d> — most significant byte (0A) first

buf.writeUInt32LE(value, 0);
console.log(buf); // <Buffer 0d 0c 0b 0a> — least significant byte (0D) first
```

### Choosing the Right Endianness

| Protocol / Format | Endianness |
|-------------------|------------|
| TCP/IP headers | Big-endian |
| DNS wire format | Big-endian |
| HTTP/2 frames | Big-endian |
| PNG chunk lengths | Big-endian |
| WAV audio headers | Little-endian |
| x86 memory layout | Little-endian |
| Protocol Buffers varint | Little-endian |
| WebAssembly memory | Little-endian |

When in doubt, check the specification for whatever protocol or file format you are working with.

---

## Reading Floating-Point Numbers

Floating-point numbers follow the IEEE 754 standard. Node.js supports two sizes:

- **Float** (32-bit / 4 bytes): ~7 decimal digits of precision
- **Double** (64-bit / 8 bytes): ~15 decimal digits of precision

```javascript
'use strict';

const buf = Buffer.alloc(12);

// Write a 32-bit float (4 bytes)
buf.writeFloatBE(3.14, 0);
console.log(buf.readFloatBE(0)); // 3.140000104904175 — float precision loss!

// Write a 64-bit double (8 bytes)
buf.writeDoubleBE(3.14, 4);
console.log(buf.readDoubleBE(4)); // 3.14 — double has enough precision

// Little-endian variants
buf.writeFloatLE(2.718, 0);
console.log(buf.readFloatLE(0)); // 2.7179999351501465

buf.writeDoubleLE(2.718281828459045, 4);
console.log(buf.readDoubleLE(4)); // 2.718281828459045
```

Notice the precision loss with `Float`. This is inherent to 32-bit floating-point representation, not a Buffer bug. If you need exact decimal values (money, for example), do not use floats — use integers representing the smallest unit (cents, not dollars).

---

## Writing Values to Buffers

Every write method returns the offset plus the number of bytes written. This makes sequential writes clean.

```javascript
'use strict';

const buf = Buffer.alloc(16);
let offset = 0;

offset = buf.writeUInt8(0x01, offset);      // offset now 1
offset = buf.writeUInt16BE(0x0203, offset);  // offset now 3
offset = buf.writeUInt32BE(0x04050607, offset); // offset now 7
offset = buf.writeDoubleBE(Math.PI, offset); // offset now 15

console.log(offset); // 15
console.log(buf);
// <Buffer 01 02 03 04 05 06 07 40 09 21 fb 54 44 2d 18 00>
```

### Building a Binary Packet

Here is a practical example: constructing a binary message with a header and payload.

```javascript
'use strict';

function buildPacket(type, sequenceId, payload) {
  // Header: 1 byte type + 4 byte sequence + 2 byte payload length
  const headerSize = 7;
  const header = Buffer.alloc(headerSize);
  let offset = 0;

  offset = header.writeUInt8(type, offset);              // 1 byte
  offset = header.writeUInt32BE(sequenceId, offset);     // 4 bytes
  offset = header.writeUInt16BE(payload.length, offset); // 2 bytes

  return Buffer.concat([header, payload]);
}

const payload = Buffer.from('Hello, protocol!', 'utf8');
const packet = buildPacket(0x01, 42, payload);

console.log(packet.length); // 23 (7 header + 16 payload)
console.log(packet.toString('hex'));
// 0100000002a001048656c6c6f2c2070726f746f636f6c21
```

### Parsing the Packet Back

```javascript
'use strict';

function parsePacket(packet) {
  let offset = 0;

  const type = packet.readUInt8(offset);
  offset += 1;

  const sequenceId = packet.readUInt32BE(offset);
  offset += 4;

  const payloadLength = packet.readUInt16BE(offset);
  offset += 2;

  const payload = packet.subarray(offset, offset + payloadLength);

  return { type, sequenceId, payloadLength, payload };
}

// Using the packet from the previous example
const packet = Buffer.from(
  '0100000002a001048656c6c6f2c2070726f746f636f6c21',
  'hex'
);

const parsed = parsePacket(packet);
console.log(parsed.type);                     // 1
console.log(parsed.sequenceId);               // 42
console.log(parsed.payloadLength);            // 16
console.log(parsed.payload.toString('utf8')); // Hello, protocol!
```

---

## The `toString()` Method

`Buffer.prototype.toString()` converts bytes to a string. The first argument is the encoding, and the optional second and third arguments define the byte range.

```javascript
'use strict';

const buf = Buffer.from('Hello, Node.js!', 'utf8');

// Full buffer to string
console.log(buf.toString('utf8'));    // Hello, Node.js!
console.log(buf.toString('hex'));     // 48656c6c6f2c204e6f64652e6a7321
console.log(buf.toString('base64')); // SGVsbG8sIE5vZGUuanMh

// Partial: toString(encoding, start, end)
console.log(buf.toString('utf8', 0, 5));  // Hello
console.log(buf.toString('utf8', 7, 14)); // Node.js

// Default encoding is 'utf8'
console.log(buf.toString()); // Hello, Node.js!
```

### Supported Encodings

| Encoding | Description |
|----------|-------------|
| `'utf8'` | Multi-byte Unicode (default) |
| `'ascii'` | 7-bit ASCII only |
| `'latin1'` | ISO-8859-1, one byte per character |
| `'utf16le'` | UTF-16 little-endian, two bytes per character |
| `'base64'` | Base64 encoding |
| `'base64url'` | URL-safe Base64 |
| `'hex'` | Hexadecimal string |
| `'binary'` | Alias for `'latin1'` (deprecated) |

```javascript
'use strict';

// Hex encoding — useful for debugging
const raw = Buffer.from([0xDE, 0xAD, 0xBE, 0xEF]);
console.log(raw.toString('hex')); // deadbeef

// Base64 encoding — useful for embedding binary in text protocols
const text = Buffer.from('Hello');
console.log(text.toString('base64')); // SGVsbG8=

// Round-trip: base64 string back to Buffer
const decoded = Buffer.from('SGVsbG8=', 'base64');
console.log(decoded.toString('utf8')); // Hello
```

---

## Byte Offset Math

When working with structured binary data, you must track offsets manually. Every field has a position (offset from the start) and a width (number of bytes).

```javascript
'use strict';

// Imagine a sensor data record:
// Offset 0:  timestamp  (UInt32BE) — 4 bytes
// Offset 4:  sensorId   (UInt16BE) — 2 bytes
// Offset 6:  temperature (FloatBE) — 4 bytes
// Offset 10: humidity    (FloatBE) — 4 bytes
// Total: 14 bytes per record

const RECORD_SIZE = 14;

function createRecord(timestamp, sensorId, temperature, humidity) {
  const buf = Buffer.alloc(RECORD_SIZE);
  buf.writeUInt32BE(timestamp, 0);
  buf.writeUInt16BE(sensorId, 4);
  buf.writeFloatBE(temperature, 6);
  buf.writeFloatBE(humidity, 10);
  return buf;
}

function readRecord(buf, recordIndex) {
  const base = recordIndex * RECORD_SIZE;
  return {
    timestamp:   buf.readUInt32BE(base),
    sensorId:    buf.readUInt16BE(base + 4),
    temperature: buf.readFloatBE(base + 6),
    humidity:    buf.readFloatBE(base + 10),
  };
}

// Store three records in a single buffer
const records = Buffer.concat([
  createRecord(1700000000, 1, 22.5, 45.0),
  createRecord(1700000060, 2, 23.1, 43.2),
  createRecord(1700000120, 3, 21.8, 47.5),
]);

console.log(records.length); // 42 (3 x 14)

for (let i = 0; i < 3; i++) {
  const r = readRecord(records, i);
  console.log(`Sensor ${r.sensorId}: ${r.temperature.toFixed(1)}C, ${r.humidity.toFixed(1)}%`);
}
// Sensor 1: 22.5C, 45.0%
// Sensor 2: 23.1C, 43.2%
// Sensor 3: 21.8C, 47.5%
```

### Common Offset Mistakes

```javascript
'use strict';

const buf = Buffer.alloc(8);

// Mistake 1: Off-by-one offset
buf.writeUInt32BE(100, 0);
// buf.readUInt32BE(1); // Reads bytes 1-4, not 0-3 — wrong value

// Mistake 2: Overlapping writes
buf.writeUInt32BE(0xAABBCCDD, 0); // bytes 0-3
buf.writeUInt32BE(0x11223344, 2); // bytes 2-5 — overwrites bytes 2-3!
console.log(buf.toString('hex')); // aabb11223344 followed by zeros

// Mistake 3: Reading past the end
try {
  buf.readUInt32BE(6); // needs 4 bytes starting at offset 6, but buffer is only 8 bytes
  // offset 6 + 4 = 10 > 8 — this actually works (6+4=10 > 8 means only 2 bytes left)
} catch (err) {
  console.log(err.code); // ERR_OUT_OF_RANGE
}
```

---

## BigInt Methods for 64-Bit Integers

JavaScript `Number` can only safely represent integers up to 2^53 - 1. For true 64-bit integers, use the BigInt read/write methods.

```javascript
'use strict';

const buf = Buffer.alloc(8);

// Write a 64-bit unsigned integer
buf.writeBigUInt64BE(18446744073709551615n, 0); // max uint64
console.log(buf.toString('hex')); // ffffffffffffffff

// Read it back
console.log(buf.readBigUInt64BE(0)); // 18446744073709551615n

// Signed 64-bit
buf.writeBigInt64BE(-1n, 0);
console.log(buf.readBigInt64BE(0));  // -1n
console.log(buf.readBigUInt64BE(0)); // 18446744073709551615n (unsigned view)
```

These methods are essential for timestamps with nanosecond precision, large file sizes, and database IDs that exceed Number.MAX_SAFE_INTEGER.

---

## Bounds Checking

All read and write methods perform bounds checking. If you attempt to read or write beyond the Buffer's length, Node.js throws a `RangeError` with code `ERR_OUT_OF_RANGE`.

```javascript
'use strict';

const buf = Buffer.alloc(4);

try {
  buf.readUInt32BE(1); // needs bytes 1-4, but buffer only has 0-3
} catch (err) {
  console.log(err.message);
  // Attempt to access memory outside buffer bounds
  console.log(err.code); // ERR_OUT_OF_RANGE
}

try {
  buf.writeUInt16BE(1000, 4); // offset 4 + 2 bytes = 6 > buffer length 4
} catch (err) {
  console.log(err.code); // ERR_OUT_OF_RANGE
}
```

This is a safety feature. Unlike C, where out-of-bounds memory access causes undefined behavior and security vulnerabilities, Node.js Buffers are bounds-checked.

---

## Practical Example: Parsing a PNG Header

Every PNG file starts with an 8-byte signature followed by chunks. The first chunk is always IHDR, containing the image dimensions.

```javascript
'use strict';

const fs = require('node:fs');

function parsePngHeader(filePath) {
  // Read just the first 33 bytes — enough for signature + IHDR chunk
  const fd = fs.openSync(filePath, 'r');
  const buf = Buffer.alloc(33);
  fs.readSync(fd, buf, 0, 33, 0);
  fs.closeSync(fd);

  // PNG signature: 8 bytes
  const signature = buf.subarray(0, 8);
  const PNG_SIG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

  if (!signature.equals(PNG_SIG)) {
    throw new Error('Not a PNG file');
  }

  // IHDR chunk starts at byte 8
  // Bytes 8-11:  chunk data length (UInt32BE)
  // Bytes 12-15: chunk type ('IHDR' as ASCII)
  // Bytes 16-19: width (UInt32BE)
  // Bytes 20-23: height (UInt32BE)
  // Byte 24:     bit depth (UInt8)
  // Byte 25:     color type (UInt8)

  const chunkLength = buf.readUInt32BE(8);
  const chunkType = buf.toString('ascii', 12, 16);
  const width = buf.readUInt32BE(16);
  const height = buf.readUInt32BE(20);
  const bitDepth = buf.readUInt8(24);
  const colorType = buf.readUInt8(25);

  return { chunkType, chunkLength, width, height, bitDepth, colorType };
}

// Usage:
// const info = parsePngHeader('image.png');
// console.log(info);
// { chunkType: 'IHDR', chunkLength: 13, width: 1920, height: 1080, bitDepth: 8, colorType: 6 }
```

This is exactly how real-world binary file parsers work: read a fixed number of bytes, interpret them at known offsets with the correct type and endianness, and advance through the structure.

---

## Key Takeaways

- Every read/write method name encodes the type, bit width, and endianness — learn the naming convention once and you can read any method signature
- Big-endian means most significant byte first (network order); little-endian means least significant byte first (x86 hardware) — using the wrong one produces silent, wrong results
- Floating-point reads (`readFloatBE`, `readDoubleBE`) follow IEEE 754; use doubles for precision, integers for exactness
- Track byte offsets carefully when parsing structured data — off-by-one bugs in binary parsing corrupt every subsequent field
- Use the BigInt variants (`readBigUInt64BE`, `writeBigInt64BE`) when values exceed `Number.MAX_SAFE_INTEGER`

---

## Next

In [Lesson 06 — Buffer Slicing, Copying & Concatenation](lesson-06-buffer-slicing-copying.md) you will learn how `slice()` shares memory with the original Buffer (a common source of bugs), how to make independent copies, and how to combine multiple Buffers efficiently.
