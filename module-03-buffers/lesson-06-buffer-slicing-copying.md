# Module 03 / Lesson 06 — Buffer Slicing, Copying & Concatenation

> Buffers are fixed-size chunks of memory. You cannot resize them, but you can carve them into slices, copy regions between them, concatenate them into new buffers, and search within them. The critical trap: `slice()` shares memory with the original buffer, so mutating one mutates the other. This lesson teaches you to manipulate buffers precisely and avoid the shared-memory bugs that plague production systems.

## Learning Objectives

- Understand that `slice()` and `subarray()` return views that share the same underlying memory
- Create independent copies using `Buffer.from()`, `copy()`, and spread patterns
- Concatenate multiple Buffers into a single new Buffer with `Buffer.concat()`
- Compare Buffers using `compare()` and `equals()` for sorting and equality checks
- Search within Buffers using `indexOf()`, `lastIndexOf()`, and `includes()`

---

## `slice()` and `subarray()` — Views, Not Copies

Both `slice()` and `subarray()` return a new Buffer object that references the **same underlying memory**. They do not allocate new memory or copy data.

```javascript
'use strict';

const original = Buffer.from([0x01, 0x02, 0x03, 0x04, 0x05]);

// slice(start, end) — end is exclusive
const sliced = original.slice(1, 4);
console.log(sliced); // <Buffer 02 03 04>

// Mutate the slice — the original changes too!
sliced[0] = 0xFF;
console.log(sliced);   // <Buffer ff 03 04>
console.log(original); // <Buffer 01 ff 03 04 05>  <-- byte at index 1 changed
```

This is by design. Shared memory avoids the cost of copying, which matters when you are processing megabytes of network data. But it is also the most common source of Buffer-related bugs.

### `subarray()` — The Modern Equivalent

`subarray()` behaves identically to `slice()`. It exists because Buffer is a subclass of `Uint8Array`, and `subarray()` is the standard TypedArray method.

```javascript
'use strict';

const buf = Buffer.from('Hello, world!', 'utf8');

const view1 = buf.slice(0, 5);
const view2 = buf.subarray(0, 5);

console.log(view1.toString()); // Hello
console.log(view2.toString()); // Hello

// Both share memory with buf
view1[0] = 0x4A; // 'J'
console.log(buf.toString()); // Jello, world!
```

In modern code, prefer `subarray()` over `slice()`. The `slice()` method on TypedArrays is being standardized to create a copy (matching `Array.prototype.slice`), and future Node.js versions may change Buffer's `slice()` to match. Using `subarray()` explicitly communicates "I want a view, not a copy."

---

## The Shared Memory Trap

Here is a bug you will encounter in production. A server receives data, slices out the interesting part, and stores it. Later, new incoming data overwrites the stored slice because they share memory.

```javascript
'use strict';

// Simulating a network data processor
const incomingBuffer = Buffer.alloc(1024);

function processChunk(chunk) {
  // BAD: storing a view into the original buffer
  const header = chunk.subarray(0, 4);
  return header; // This is NOT a safe copy
}

// First chunk arrives
incomingBuffer.write('ABCD', 0, 'ascii');
const savedHeader = processChunk(incomingBuffer);
console.log(savedHeader.toString()); // ABCD

// Second chunk arrives — overwrites the same memory
incomingBuffer.write('WXYZ', 0, 'ascii');
console.log(savedHeader.toString()); // WXYZ <-- our "saved" header changed!
```

### The Fix: Make a Copy

```javascript
'use strict';

function processChunkSafely(chunk) {
  // GOOD: create an independent copy
  const header = Buffer.from(chunk.subarray(0, 4));
  return header; // Safe — this is a new allocation
}

const incomingBuffer = Buffer.alloc(1024);
incomingBuffer.write('ABCD', 0, 'ascii');
const savedHeader = processChunkSafely(incomingBuffer);

incomingBuffer.write('WXYZ', 0, 'ascii');
console.log(savedHeader.toString()); // ABCD — preserved
```

The rule is simple: if you need to store or return a portion of a Buffer that might be mutated later, copy it.

---

## `copy()` — Targeted Byte Copying

`Buffer.prototype.copy()` copies bytes from the source buffer into a target buffer.

```javascript
source.copy(target, targetStart, sourceStart, sourceEnd)
```

```javascript
'use strict';

const source = Buffer.from('Hello, World!', 'utf8');
const target = Buffer.alloc(5);

// Copy 'World' from source to target
source.copy(target, 0, 7, 12);
console.log(target.toString()); // World
```

### Partial Overwrites

`copy()` only writes to the region you specify. Existing bytes in the target outside that range are untouched.

```javascript
'use strict';

const target = Buffer.from('AAAAAAAAAA', 'ascii'); // 10 bytes of 'A'
const source = Buffer.from('XYZ', 'ascii');

source.copy(target, 3); // Copy all of source starting at target offset 3
console.log(target.toString()); // AAAXYZAAAA
```

### Overlapping Copies Within the Same Buffer

`copy()` handles overlapping regions correctly, even when source and target are the same buffer.

```javascript
'use strict';

const buf = Buffer.from('ABCDE');

// Shift bytes right by 2 positions
buf.copy(buf, 2, 0, 3); // Copy bytes 0-2 to positions 2-4
console.log(buf.toString()); // ABABC
```

---

## `Buffer.concat()` — Combining Buffers

`Buffer.concat()` takes an array of Buffers and returns a single new Buffer containing all of their bytes in order.

```javascript
'use strict';

const chunk1 = Buffer.from('Hello');
const chunk2 = Buffer.from(', ');
const chunk3 = Buffer.from('World!');

const combined = Buffer.concat([chunk1, chunk2, chunk3]);
console.log(combined.toString()); // Hello, World!
console.log(combined.length);     // 13
```

### Specifying Total Length

If you know the total length ahead of time, pass it as the second argument. This avoids an internal loop to calculate the sum.

```javascript
'use strict';

const chunks = [
  Buffer.from([0x01, 0x02]),
  Buffer.from([0x03, 0x04]),
  Buffer.from([0x05]),
];

const totalLength = 5;
const result = Buffer.concat(chunks, totalLength);
console.log(result); // <Buffer 01 02 03 04 05>
```

If the specified length is shorter than the actual combined data, the result is truncated. If it is longer, the extra bytes are zero-filled.

```javascript
'use strict';

const a = Buffer.from([0xAA, 0xBB]);
const b = Buffer.from([0xCC, 0xDD]);

// Truncation
const short = Buffer.concat([a, b], 3);
console.log(short); // <Buffer aa bb cc>

// Padding
const long = Buffer.concat([a, b], 6);
console.log(long); // <Buffer aa bb cc dd 00 00>
```

### The Streaming Pattern

This is the most common real-world usage — collecting chunks from a stream and combining them at the end.

```javascript
'use strict';

const { Readable } = require('node:stream');

function collectStream(readable) {
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
```

Tracking `totalLength` incrementally is a micro-optimization — it lets `Buffer.concat` skip its internal length calculation.

---

## `compare()` — Buffer Ordering

`Buffer.compare()` works like the comparators used in sorting: it returns a negative number, zero, or a positive number.

```javascript
'use strict';

const a = Buffer.from('abc');
const b = Buffer.from('abd');
const c = Buffer.from('abc');

console.log(a.compare(b)); // -1 (a < b, because 'c' < 'd')
console.log(b.compare(a)); //  1 (b > a)
console.log(a.compare(c)); //  0 (equal)
```

### Sorting Buffers

Because `compare()` returns the standard comparator value, you can pass it directly to `Array.prototype.sort`.

```javascript
'use strict';

const buffers = [
  Buffer.from('cherry'),
  Buffer.from('apple'),
  Buffer.from('banana'),
];

buffers.sort(Buffer.compare);
console.log(buffers.map(b => b.toString()));
// [ 'apple', 'banana', 'cherry' ]
```

### Partial Comparison

`compare()` accepts optional arguments for comparing sub-ranges.

```javascript
buf.compare(target, targetStart, targetEnd, sourceStart, sourceEnd)
```

```javascript
'use strict';

const a = Buffer.from('xxHelloxx');
const b = Buffer.from('Hello');

// Compare bytes 2-6 of 'a' against all of 'b'
console.log(a.compare(b, 0, 5, 2, 7)); // 0 — equal
```

---

## `equals()` — Exact Equality

`equals()` returns `true` if two Buffers contain exactly the same bytes.

```javascript
'use strict';

const a = Buffer.from([0x01, 0x02, 0x03]);
const b = Buffer.from([0x01, 0x02, 0x03]);
const c = Buffer.from([0x01, 0x02, 0x04]);

console.log(a.equals(b)); // true
console.log(a.equals(c)); // false

// This is NOT the same as ===
console.log(a === b); // false — different objects in memory
```

Use `equals()` for comparing cryptographic hashes, protocol magic bytes, or any binary identity check. Never use `===` — that checks object reference identity, not content equality.

---

## `indexOf()`, `lastIndexOf()`, and `includes()`

Buffers support the same search methods as arrays and strings.

```javascript
'use strict';

const buf = Buffer.from('Hello, World! Hello, Node!', 'utf8');

// indexOf — first occurrence
console.log(buf.indexOf('Hello'));        // 0
console.log(buf.indexOf('Hello', 1));     // 14 (search starting at offset 1)
console.log(buf.indexOf('missing'));      // -1

// lastIndexOf — last occurrence
console.log(buf.lastIndexOf('Hello'));    // 14

// includes — boolean check
console.log(buf.includes('World'));       // true
console.log(buf.includes('Python'));      // false
```

### Searching for Byte Sequences

You can search for raw byte values, not just strings.

```javascript
'use strict';

const buf = Buffer.from([0x00, 0xFF, 0x00, 0xFF, 0x00]);

// Search for a single byte
console.log(buf.indexOf(0xFF));    // 1
console.log(buf.indexOf(0xFF, 2)); // 3

// Search for a byte sequence
const needle = Buffer.from([0xFF, 0x00]);
console.log(buf.indexOf(needle));  // 1 (found 0xFF 0x00 starting at index 1)
```

### Finding Delimiters in Binary Protocols

```javascript
'use strict';

// HTTP headers end with \r\n\r\n
const httpData = Buffer.from(
  'GET / HTTP/1.1\r\nHost: example.com\r\n\r\nBody here'
);

const HEADER_END = Buffer.from('\r\n\r\n');
const separatorIndex = httpData.indexOf(HEADER_END);

if (separatorIndex !== -1) {
  const headers = httpData.subarray(0, separatorIndex).toString('utf8');
  const body = httpData.subarray(separatorIndex + HEADER_END.length).toString('utf8');

  console.log('Headers:', headers);
  // Headers: GET / HTTP/1.1\r\nHost: example.com

  console.log('Body:', body);
  // Body: Body here
}
```

---

## `fill()` — Overwriting Buffer Contents

`fill()` writes a value to every position (or a range of positions) in the Buffer.

```javascript
'use strict';

const buf = Buffer.alloc(10);

buf.fill(0xFF);
console.log(buf); // <Buffer ff ff ff ff ff ff ff ff ff ff>

buf.fill(0x00, 3, 7); // fill bytes 3-6 with zeros
console.log(buf); // <Buffer ff ff ff 00 00 00 00 ff ff ff>

// Fill with a string
buf.fill('AB', 'utf8');
console.log(buf.toString()); // ABABABABAB

// Fill with a multi-byte pattern
buf.fill('xyz');
console.log(buf.toString()); // xyzxyzxyzx (pattern repeats, truncated at buffer end)
```

`fill()` is commonly used to zero out sensitive data before releasing a buffer — for example, wiping a password or key from memory.

---

## `swap16()`, `swap32()`, `swap64()` — Byte-Order Reversal

These methods reverse the byte order within each 16-bit, 32-bit, or 64-bit group. They modify the buffer in place.

```javascript
'use strict';

const buf16 = Buffer.from([0x01, 0x02, 0x03, 0x04]);
buf16.swap16();
console.log(buf16); // <Buffer 02 01 04 03>

const buf32 = Buffer.from([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
buf32.swap32();
console.log(buf32); // <Buffer 04 03 02 01 08 07 06 05>

const buf64 = Buffer.from([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
buf64.swap64();
console.log(buf64); // <Buffer 08 07 06 05 04 03 02 01>
```

The buffer length must be a multiple of the swap size, or you get an error. These methods are useful when converting between big-endian and little-endian representations for entire data blocks.

---

## Putting It All Together: A Message Reassembler

Here is a practical example that uses most of the methods from this lesson: a function that reassembles fragmented messages from a binary stream.

```javascript
'use strict';

class MessageReassembler {
  #fragments = [];
  #totalLength = 0;

  // Each message starts with 0xFE and ends with 0xFF
  static HEADER = 0xFE;
  static FOOTER = 0xFF;

  addFragment(fragment) {
    // Make a copy — the caller may reuse the buffer
    this.#fragments.push(Buffer.from(fragment));
    this.#totalLength += fragment.length;
  }

  tryExtractMessage() {
    // Combine all fragments
    const combined = Buffer.concat(this.#fragments, this.#totalLength);

    // Look for a complete message
    const start = combined.indexOf(MessageReassembler.HEADER);
    if (start === -1) {
      // No header found — discard everything before the search point
      this.#fragments = [];
      this.#totalLength = 0;
      return null;
    }

    const end = combined.indexOf(MessageReassembler.FOOTER, start + 1);
    if (end === -1) {
      // Header found but no footer yet — keep fragments, wait for more data
      return null;
    }

    // Extract the message payload (between header and footer)
    const message = Buffer.from(combined.subarray(start + 1, end));

    // Keep any remaining data after the footer
    const remaining = combined.subarray(end + 1);
    if (remaining.length > 0) {
      this.#fragments = [Buffer.from(remaining)];
      this.#totalLength = remaining.length;
    } else {
      this.#fragments = [];
      this.#totalLength = 0;
    }

    return message;
  }
}

// Usage
const reassembler = new MessageReassembler();

reassembler.addFragment(Buffer.from([0xFE, 0x48, 0x65])); // header + 'He'
console.log(reassembler.tryExtractMessage()); // null — incomplete

reassembler.addFragment(Buffer.from([0x6C, 0x6C, 0x6F, 0xFF])); // 'llo' + footer
const msg = reassembler.tryExtractMessage();
console.log(msg.toString()); // Hello
```

---

## Key Takeaways

- `slice()` and `subarray()` create views that share memory with the original Buffer — mutating one mutates the other, which is the single most common Buffer bug in Node.js applications
- Use `Buffer.from(view)` or `copy()` to create independent copies when you need to store or return partial buffer data
- `Buffer.concat()` creates a new buffer from an array of buffers; pass the total length as the second argument to skip the internal length calculation
- `compare()` enables byte-level sorting; `equals()` checks content equality (never use `===` for buffer comparison)
- `indexOf()` and `includes()` work with strings, single bytes, and byte sequences — essential for finding delimiters and markers in binary protocols

---

## Next

In [Lesson 07 — TypedArrays & ArrayBuffer](lesson-07-typedarrays-arraybuffer.md) you will discover the Web standard that Node.js Buffers are built on: `ArrayBuffer`, `Uint8Array`, `DataView`, and the full family of TypedArrays.
