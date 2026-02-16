# Module 03 — Buffers & Binary Data

> JavaScript was born in the browser, where strings were all you needed. Node.js broke out of that sandbox and had to deal with raw bytes — TCP packets, file contents, image data, cryptographic hashes. The `Buffer` class is how Node.js handles binary data, and understanding it is the difference between code that works and code that works correctly with every encoding, every protocol, and every edge case.

---

## Learning Objectives

- Convert between binary, hexadecimal, octal, and decimal number systems fluently
- Explain how ASCII, UTF-8, and UTF-16 encode characters into bytes
- Create Buffers using every allocation method and understand the security implications of each
- Read and write integers, floats, and strings at arbitrary byte offsets within a Buffer
- Slice, copy, and concatenate Buffers without unexpected shared-memory bugs
- Compare Buffer and TypedArray APIs and know when to use each
- Benchmark Buffer operations and identify common performance pitfalls

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| 01 | [Binary Number Systems](lesson-01-binary-number-systems.md) | Bits, bytes, powers of two, bitwise operators, and why they matter for I/O |
| 02 | [Hexadecimal & Octal](lesson-02-hexadecimal-octal.md) | Hex notation, octal notation, conversions, and how they appear in Buffers and protocols |
| 03 | [Character Encodings](lesson-03-character-encodings.md) | ASCII, UTF-8, UTF-16, Latin-1 — how characters become bytes and back again |
| 04 | [Buffer Creation & Allocation](lesson-04-buffer-creation-allocation.md) | `Buffer.alloc`, `Buffer.allocUnsafe`, `Buffer.from` — when each is safe and when it is not |
| 05 | [Buffer Reading & Writing](lesson-05-buffer-reading-writing.md) | `readUInt8`, `writeInt32BE`, `readFloatLE`, `toString` — byte-level precision |
| 06 | [Buffer Slicing, Copying & Concatenation](lesson-06-buffer-slicing-copying.md) | `slice`, `subarray`, `copy`, `Buffer.concat` — shared memory vs independent copies |
| 07 | [TypedArrays & ArrayBuffer](lesson-07-typedarrays-arraybuffer.md) | `Uint8Array`, `ArrayBuffer`, `DataView` — the Web standard that Buffer builds on |
| 08 | [Buffer Performance & Memory Management](lesson-08-buffer-performance.md) | Pooling, allocation overhead, zero-copy patterns, and when Buffers become a bottleneck |

---

## Exercises

| # | Exercise | Description |
|---|----------|-------------|
| 01 | [Hex Dump Utility](exercise-01-hex-dump-utility.md) | Build a `hexdump` CLI tool that displays file contents in hex + ASCII like `xxd` |
| 02 | [Binary Protocol Parser](exercise-02-binary-protocol-parser.md) | Parse a custom binary protocol with fixed-width headers, variable-length payloads, and checksums |
| 03 | [Image Header Reader](exercise-03-image-header-reader.md) | Read PNG, JPEG, and GIF magic bytes and headers to extract dimensions without loading the full image |
| 04 | [Buffer vs String Performance](exercise-04-buffer-vs-string-performance.md) | Benchmark Buffer concatenation vs string concatenation for building HTTP responses |
| 05 | [Endianness Converter](exercise-05-endianness-converter.md) | Build a utility that converts multi-byte integers between big-endian and little-endian formats |

---

## Progressive Project — Step 03: Buffer-Based Body Parsing

Building on the EventEmitter middleware chain from Step 02, you now add raw body parsing using Buffers.

When an HTTP request arrives with a body (POST, PUT, PATCH), the data comes in as chunks of binary data — not strings. Your body parser must:

1. **Collect incoming chunks** into an array of Buffers as they arrive
2. **Concatenate the chunks** into a single Buffer using `Buffer.concat` once the stream ends
3. **Respect Content-Length** — reject bodies that exceed a configurable maximum size (default: 1MB)
4. **Decode based on Content-Type** — parse the Buffer as JSON (`utf8`), URL-encoded form data, or raw binary
5. **Handle encoding edge cases** — multi-byte UTF-8 characters that split across chunk boundaries

```javascript
const { Buffer } = require('node:buffer');

class BodyParser {
  #maxBytes;

  constructor(maxBytes = 1024 * 1024) {
    this.#maxBytes = maxBytes;
  }

  async parse(chunks, contentType, contentLength) {
    if (contentLength > this.#maxBytes) {
      throw new Error(`Body exceeds max size: ${contentLength} > ${this.#maxBytes}`);
    }

    const body = Buffer.concat(chunks);

    if (contentType === 'application/json') {
      return JSON.parse(body.toString('utf8'));
    }

    if (contentType === 'application/x-www-form-urlencoded') {
      return Object.fromEntries(
        body.toString('utf8').split('&').map(pair => {
          const [key, val] = pair.split('=');
          return [decodeURIComponent(key), decodeURIComponent(val)];
        })
      );
    }

    return body; // raw binary
  }
}
```

**Deliverable:** A `BodyParser` middleware that integrates into the middleware chain, handles JSON and form-encoded bodies, enforces size limits, and includes tests for multi-byte character splitting and oversized payloads.

---

## Key Takeaways

After completing this module you will think in bytes, not just strings. You will understand exactly what happens when Node.js reads a file, receives a network packet, or computes a hash — and you will be able to manipulate that binary data with precision using Buffers, TypedArrays, and the right encoding for every situation.

---

## Next

[Module 04 — File System](../module-04-filesystem/README.md)
