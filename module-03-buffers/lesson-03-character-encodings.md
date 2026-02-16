# Module 03 / Lesson 03 — Character Encodings

> Every string on a computer is a lie — it is really just bytes. The encoding tells you which lie to believe. Understanding character encodings is essential for any developer who works with files, network protocols, or internationalized text. Get the encoding wrong and you get mojibake, data corruption, or silent truncation. Get it right and bytes flow seamlessly between systems, languages, and continents.

## Learning Objectives

- Explain what a character encoding is and why multiple encodings exist
- Compare ASCII, Latin-1, UTF-8, and UTF-16 in terms of byte width, character coverage, and trade-offs
- Convert strings to Buffers and Buffers back to strings using all Node.js-supported encodings
- Diagnose and fix the multi-byte split problem using `StringDecoder` and `TextDecoder`
- Use Base64 and hex encodings for safe binary-to-text transport

---

## What Is a Character Encoding?

A character encoding is a mapping between human-readable characters and sequences of bytes. When you type the letter "A", the computer stores one or more bytes that represent "A" — which bytes depend on the encoding.

```
Character   Encoding     Bytes (hex)
─────────   ─────────    ───────────
A           ASCII        41
A           UTF-8        41
A           UTF-16LE     41 00
A           UTF-16BE     00 41
cafe        UTF-8        63 61 66 C3 A9
cafe        Latin-1      63 61 66 E9
```

The same character can produce different byte sequences under different encodings, and the same bytes can decode to different characters under different encodings. This mismatch is the root cause of every encoding bug you will ever encounter.

---

## ASCII — The Foundation

ASCII (American Standard Code for Information Interchange) is a 7-bit encoding. It defines 128 characters: 33 control characters (0-31 and 127) and 95 printable characters (32-126).

```javascript
'use strict';

// ASCII maps characters to single bytes (0-127)
const buf = Buffer.from('Hello', 'ascii');
console.log(buf);          // <Buffer 48 65 6c 6c 6f>
console.log(buf.length);   // 5 — one byte per character

// Printable ASCII range: 32 (space) to 126 (~)
for (let i = 32; i <= 126; i++) {
  process.stdout.write(String.fromCharCode(i));
}
// Output: !"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGH...xyz{|}~
console.log();

// ASCII only handles English letters, digits, and basic punctuation
// Characters above 127 are masked to 7 bits
const buf2 = Buffer.from('\u00E9', 'ascii'); // e (code point 233)
console.log(buf2[0]); // 233 & 0x7F = 105 = 'i' — silent data corruption!
```

The key limitation: ASCII cannot represent accented characters, CJK ideographs, emoji, or any writing system beyond basic English. This is why ASCII was just the starting point, not the destination.

---

## Latin-1 (ISO-8859-1) — The 8-Bit Extension

Latin-1 extends ASCII to 8 bits (256 characters). It covers most Western European languages by adding accented characters, currency symbols, and typographic marks in positions 128-255.

```javascript
'use strict';

// Latin-1: one byte per character, 256 possible values
const buf = Buffer.from('cafe\u0301', 'latin1');
console.log(buf); // Note: combining accent is a separate byte

// Direct byte mapping — code point = byte value for 0-255
const latin1Buf = Buffer.from([0xE9]); // 0xE9 = 233 = e
console.log(latin1Buf.toString('latin1')); // e

// Latin-1 is lossless for code points 0-255
for (let i = 0; i < 256; i++) {
  const char = String.fromCharCode(i);
  const encoded = Buffer.from(char, 'latin1');
  const decoded = encoded.toString('latin1');
  if (char !== decoded) {
    console.log(`Round-trip failure at ${i}`); // Never fires
  }
}
console.log('All 256 code points survive round-trip in Latin-1');
```

Node.js uses `'latin1'` as the encoding name. The older name `'binary'` is an alias for `'latin1'` and is considered deprecated.

```javascript
'use strict';

// 'binary' is an alias for 'latin1'
const a = Buffer.from('cafe\u00E9', 'latin1');
const b = Buffer.from('cafe\u00E9', 'binary');
console.log(a.equals(b)); // true
```

---

## Unicode — The Universal Character Set

Unicode is not an encoding. It is a character set — a giant lookup table that assigns a unique number (called a code point) to every character in every writing system, plus emoji, mathematical symbols, musical notation, and more.

```
Code Point Range      Block                     Characters
──────────────────    ──────────────────────     ──────────
U+0000 – U+007F      Basic Latin (ASCII)        128
U+0080 – U+00FF      Latin-1 Supplement         128
U+0100 – U+024F      Latin Extended-A/B         336
U+0400 – U+04FF      Cyrillic                   256
U+4E00 – U+9FFF      CJK Unified Ideographs     20,992
U+1F600 – U+1F64F    Emoticons                  80
U+10000 – U+10FFFF   Supplementary planes       ~1M
```

Unicode defines over 149,000 characters across 161 scripts. The total addressable space is 1,114,112 code points (U+0000 to U+10FFFF), organized into 17 planes of 65,536 code points each.

```javascript
'use strict';

// JavaScript strings are sequences of UTF-16 code units
const emoji = '\u{1F600}'; // Grinning Face
console.log(emoji);              // (the emoji)
console.log(emoji.length);       // 2 — two UTF-16 code units (surrogate pair)
console.log(emoji.codePointAt(0).toString(16)); // 1f600

// Iterating by code point (not code unit)
for (const char of 'cafe\u0301') {
  console.log(char, '->', char.codePointAt(0).toString(16));
}
// c -> 63
// a -> 61
// f -> 66
// e -> 65 (base character)
// combining accent -> 301

// String.fromCodePoint for supplementary plane characters
const str = String.fromCodePoint(0x1F600, 0x1F601, 0x1F602);
console.log(str); // Three emoji
```

---

## UTF-8 — The Dominant Encoding

UTF-8 is a variable-length encoding for Unicode. It uses 1 to 4 bytes per character, and it is backward-compatible with ASCII: any valid ASCII text is also valid UTF-8.

```
Code Point Range         Bytes   Byte Pattern
─────────────────────    ─────   ──────────────────────────────
U+0000  – U+007F        1       0xxxxxxx
U+0080  – U+07FF        2       110xxxxx 10xxxxxx
U+0800  – U+FFFF        3       1110xxxx 10xxxxxx 10xxxxxx
U+10000 – U+10FFFF      4       11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
```

```javascript
'use strict';

// UTF-8 is the default encoding in Node.js
const examples = [
  ['A',      1],  // ASCII: 1 byte
  ['\u00E9', 2],  // e: 2 bytes (Latin Extended)
  ['\u4E16', 3],  // (Chinese character): 3 bytes (CJK)
  ['\u{1F600}', 4], // Emoji: 4 bytes (Supplementary plane)
];

for (const [char, expectedBytes] of examples) {
  const buf = Buffer.from(char, 'utf8');
  console.log(
    `'${char}' → ${buf.length} byte(s): ${buf.toString('hex')}` +
    ` ${buf.length === expectedBytes ? 'OK' : 'MISMATCH'}`
  );
}
// 'A' → 1 byte(s): 41 OK
// 'e' → 2 byte(s): c3a9 OK
// '...' → 3 byte(s): e4b896 OK
// '...' → 4 byte(s): f09f9880 OK

// UTF-8 is self-synchronizing: you can always tell if a byte is
// the start of a character (0xxxxxxx or 11xxxxxx) or a continuation (10xxxxxx)
const buf = Buffer.from('Hello, world!', 'utf8');
for (let i = 0; i < buf.length; i++) {
  const byte = buf[i];
  const type = (byte & 0x80) === 0     ? 'ASCII (1-byte)' :
               (byte & 0xC0) === 0x80  ? 'Continuation'   :
               (byte & 0xE0) === 0xC0  ? 'Start (2-byte)' :
               (byte & 0xF0) === 0xE0  ? 'Start (3-byte)' :
                                         'Start (4-byte)';
  if (i < 5) console.log(`Byte ${i}: 0x${byte.toString(16)} → ${type}`);
}
```

### Why UTF-8 Dominates

- Backward compatible with ASCII (every ASCII file is valid UTF-8)
- No byte-order issues (unlike UTF-16, which needs a BOM)
- Space-efficient for English and most Latin-script text
- Self-synchronizing: a decoder can recover from byte stream corruption
- Used by over 98% of web pages, mandated by JSON, YAML, TOML, and most modern formats

---

## UTF-16 — JavaScript's Internal Encoding

JavaScript strings are internally encoded as UTF-16: each element is a 16-bit code unit. Characters in the Basic Multilingual Plane (U+0000 to U+FFFF) use one code unit. Characters above U+FFFF use a surrogate pair: two 16-bit code units.

```javascript
'use strict';

// Node.js supports UTF-16LE (little-endian)
const buf = Buffer.from('Hello', 'utf16le');
console.log(buf);        // <Buffer 48 00 65 00 6c 00 6c 00 6f 00>
console.log(buf.length); // 10 — two bytes per ASCII character in UTF-16

// Surrogate pairs for characters above U+FFFF
const emoji = '\u{1F600}';
const emojiBuf = Buffer.from(emoji, 'utf16le');
console.log(emojiBuf);        // <Buffer 3d d8 00 de> — surrogate pair in LE
console.log(emojiBuf.length); // 4 bytes

// Decoding back
console.log(emojiBuf.toString('utf16le')); // The emoji character

// The surrogate pair math:
// U+1F600 → subtract 0x10000 = 0xF600
// High surrogate: 0xD800 + (0xF600 >> 10) = 0xD800 + 0x3D = 0xD83D
// Low surrogate:  0xDC00 + (0xF600 & 0x3FF) = 0xDC00 + 0x200 = 0xDE00
console.log(emoji.charCodeAt(0).toString(16)); // d83d (high surrogate)
console.log(emoji.charCodeAt(1).toString(16)); // de00 (low surrogate)
```

Node.js only supports `'utf16le'` (little-endian UTF-16), not `'utf16be'`. This is because V8 stores strings in little-endian format on all supported platforms.

---

## All Node.js Supported Encodings

```javascript
'use strict';

const encodings = [
  'utf8', 'ascii', 'latin1', 'binary',
  'base64', 'base64url', 'hex', 'utf16le',
];

const testString = 'Node.js';

for (const enc of encodings) {
  if (Buffer.isEncoding(enc)) {
    const buf = Buffer.from(testString, enc === 'hex' ? 'utf8' : enc);
    const encoded = buf.toString(enc);
    console.log(`${enc.padEnd(12)} → ${encoded}`);
  }
}
```

| Encoding | Description | Bytes/Char | Use Case |
|----------|-------------|------------|----------|
| `'utf8'` | Variable-length Unicode (default) | 1-4 | Text files, JSON, HTTP bodies |
| `'ascii'` | 7-bit, masks high bit | 1 | Legacy protocols, 7-bit clean data |
| `'latin1'` | ISO-8859-1, 8-bit | 1 | Binary passthrough, legacy Western European text |
| `'binary'` | Alias for `'latin1'` (deprecated) | 1 | Backward compatibility only |
| `'utf16le'` | UTF-16 little-endian | 2 or 4 | Windows APIs, some file formats |
| `'base64'` | Base64 (RFC 4648) | 4 per 3 input | Embedding binary in JSON/XML/email |
| `'base64url'` | URL-safe Base64 (no `+`, `/`, `=`) | 4 per 3 input | JWTs, URL parameters |
| `'hex'` | Hexadecimal (2 chars per byte) | 2 per 1 input | Debugging, hashes, checksums |

---

## Base64 Encoding

Base64 encodes binary data as printable ASCII characters. It exists because many protocols (email, JSON, URLs) cannot safely transport raw binary bytes.

```javascript
'use strict';

// Encoding: binary → Base64 text
const binaryData = Buffer.from([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE]);
const base64 = binaryData.toString('base64');
console.log(base64); // 3q2+78r+

// Decoding: Base64 text → binary
const decoded = Buffer.from(base64, 'base64');
console.log(decoded); // <Buffer de ad be ef ca fe>
console.log(decoded.equals(binaryData)); // true

// Base64 overhead: 4 output bytes for every 3 input bytes (33% larger)
const original = Buffer.from('Hello, world!');
const encoded = original.toString('base64');
console.log(`Original: ${original.length} bytes`);
console.log(`Base64:   ${encoded.length} chars`);
console.log(`Overhead: ${((encoded.length / original.length - 1) * 100).toFixed(1)}%`);
// Original: 13 bytes
// Base64:   20 chars
// Overhead: 53.8%

// Base64url — safe for URLs and filenames (replaces + with -, / with _)
const urlSafe = original.toString('base64url');
console.log(`base64:    ${encoded}`);
console.log(`base64url: ${urlSafe}`);
```

### Practical Use: Embedding an Image in JSON

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

// Read a binary file and embed it in a JSON payload
function imageToJson(imagePath) {
  const imageBuffer = fs.readFileSync(imagePath);
  return {
    filename: path.basename(imagePath),
    mimeType: 'image/png',
    size: imageBuffer.length,
    data: imageBuffer.toString('base64'),
  };
}

// Reconstruct the binary from JSON
function jsonToImage(json) {
  return Buffer.from(json.data, 'base64');
}

// Usage:
// const json = imageToJson('/tmp/photo.png');
// const reconstructed = jsonToImage(json);
```

---

## Hex Encoding

Hex encoding represents each byte as two hexadecimal characters. It is verbose (doubles the size) but extremely readable for debugging.

```javascript
'use strict';

// Buffer to hex string
const buf = Buffer.from([0x48, 0x65, 0x6C, 0x6C, 0x6F]);
console.log(buf.toString('hex')); // 48656c6c6f

// Hex string to Buffer
const fromHex = Buffer.from('48656c6c6f', 'hex');
console.log(fromHex.toString('utf8')); // Hello

// Common in cryptography: hashes are typically displayed as hex
const { createHash } = require('node:crypto');
const hash = createHash('sha256').update('Hello').digest('hex');
console.log(hash); // 185f8db32271fe25f561a6fc938b2e264306ec304eda518007d1764826381969

// Hex is case-insensitive on input
const lower = Buffer.from('deadbeef', 'hex');
const upper = Buffer.from('DEADBEEF', 'hex');
console.log(lower.equals(upper)); // true
```

---

## The Multi-Byte Split Problem

When reading UTF-8 data in chunks (from a stream, a network socket, or a series of `fs.read` calls), a multi-byte character can be split across chunk boundaries. This produces garbled output.

```javascript
'use strict';

// The three-byte UTF-8 character for Chinese "world" (U+4E16): e4 b8 96
const fullString = '\u4E16'; // One Chinese character
const buf = Buffer.from(fullString, 'utf8');
console.log(buf); // <Buffer e4 b8 96>

// Simulate a chunk boundary splitting the character
const chunk1 = buf.subarray(0, 2); // First two bytes: e4 b8
const chunk2 = buf.subarray(2, 3); // Last byte: 96

// Naive decoding produces garbage
console.log(chunk1.toString('utf8')); // '\ufffd\ufffd' — replacement characters!
console.log(chunk2.toString('utf8')); // '\ufffd' — more garbage!

// The correct output should be the single character
console.log(buf.toString('utf8')); // The Chinese character
```

This is not a theoretical problem. It happens in production whenever you process text streams chunk by chunk.

---

## StringDecoder — The Node.js Solution

`StringDecoder` from the `node:string_decoder` module buffers incomplete multi-byte characters across chunk boundaries.

```javascript
'use strict';

const { StringDecoder } = require('node:string_decoder');

// The three-byte character split across two chunks
const buf = Buffer.from('\u4E16', 'utf8'); // <Buffer e4 b8 96>
const chunk1 = buf.subarray(0, 2);
const chunk2 = buf.subarray(2, 3);

// StringDecoder handles the split gracefully
const decoder = new StringDecoder('utf8');

const result1 = decoder.write(chunk1); // Returns '' — holds incomplete bytes
const result2 = decoder.write(chunk2); // Returns the complete character
const result3 = decoder.end();         // Flush any remaining bytes

console.log(`Chunk 1 output: '${result1}'`); // ''
console.log(`Chunk 2 output: '${result2}'`); // The Chinese character
console.log(`Final flush:    '${result3}'`); // ''
console.log(`Combined: '${result1}${result2}${result3}'`); // The character
```

### How StringDecoder Works Internally

```javascript
'use strict';

const { StringDecoder } = require('node:string_decoder');

// Simulate a stream of mixed ASCII and multi-byte UTF-8
const original = 'Hello, \u4E16\u754C!'; // Hello, (world in Chinese)!
const buf = Buffer.from(original, 'utf8');

// Split into awkward 5-byte chunks
const decoder = new StringDecoder('utf8');
let output = '';

for (let i = 0; i < buf.length; i += 5) {
  const chunk = buf.subarray(i, Math.min(i + 5, buf.length));
  const decoded = decoder.write(chunk);
  console.log(
    `Bytes ${i}-${Math.min(i + 4, buf.length - 1)}: ` +
    `${chunk.toString('hex')} → '${decoded}'`
  );
  output += decoded;
}
output += decoder.end();

console.log(`\nFinal: '${output}'`);
console.log(`Match: ${output === original}`); // true
```

### StringDecoder Supported Encodings

`StringDecoder` supports `'utf8'`, `'utf16le'`, `'latin1'`, `'ascii'`, `'base64'`, and `'hex'`. For `'latin1'` and `'ascii'` (single-byte encodings), it provides no benefit — every byte is a complete character.

---

## TextEncoder and TextDecoder — The Web Standard APIs

Node.js provides the WHATWG `TextEncoder` and `TextDecoder` APIs, giving you the same encoding interface used in browsers.

```javascript
'use strict';

// TextEncoder always encodes to UTF-8
const encoder = new TextEncoder();
const encoded = encoder.encode('Hello, \u4E16\u754C!');
console.log(encoded);                     // Uint8Array (not a Buffer)
console.log(encoded instanceof Uint8Array); // true
console.log(Buffer.isBuffer(encoded));      // false

// Convert to Buffer if needed
const buf = Buffer.from(encoded.buffer, encoded.byteOffset, encoded.byteLength);
console.log(Buffer.isBuffer(buf)); // true

// TextDecoder supports many encodings (not just Node.js's 8)
const decoder = new TextDecoder('utf-8');
const text = decoder.decode(encoded);
console.log(text); // Hello, (world in Chinese)!

// TextDecoder with stream mode (handles multi-byte splits)
const streamDecoder = new TextDecoder('utf-8', { stream: true });
const bytes = Buffer.from('\u4E16', 'utf8'); // e4 b8 96

let result = '';
result += streamDecoder.decode(bytes.subarray(0, 2), { stream: true });
result += streamDecoder.decode(bytes.subarray(2, 3), { stream: true });
result += streamDecoder.decode(); // flush
console.log(result); // The Chinese character
```

### TextDecoder vs StringDecoder

| Feature | `StringDecoder` | `TextDecoder` |
|---------|----------------|---------------|
| Module | `node:string_decoder` | Global (Web API) |
| Input | Buffer | ArrayBuffer / TypedArray |
| Output | String | String |
| Encodings | 6 Node.js encodings | 40+ (including Windows-1252, Shift_JIS, etc.) |
| Streaming | `.write()` + `.end()` | `{ stream: true }` option |
| Use case | Node.js streams | Cross-platform, exotic encodings |
| BOM handling | No | Optional (`ignoreBOM: false`) |

```javascript
'use strict';

// TextDecoder can handle encodings that Node.js Buffer cannot
const decoder = new TextDecoder('windows-1252');
const buf = Buffer.from([0x80]); // Euro sign in Windows-1252
console.log(decoder.decode(buf)); // The Euro sign

// The fatal option throws on invalid byte sequences instead of replacing
const strictDecoder = new TextDecoder('utf-8', { fatal: true });
try {
  strictDecoder.decode(Buffer.from([0xFF, 0xFE])); // Invalid UTF-8
} catch (err) {
  console.log(err.message); // The encoded data was not valid
}
```

---

## Encoding Conversions in Practice

```javascript
'use strict';

// UTF-8 string → Buffer → Hex string
const original = 'Node.js Buffers';
const buf = Buffer.from(original, 'utf8');
const hex = buf.toString('hex');
console.log(hex); // 4e6f64652e6a7320427566666572s

// Hex → Buffer → Base64
const base64 = Buffer.from(hex, 'hex').toString('base64');
console.log(base64);

// Base64 → Buffer → UTF-8
const restored = Buffer.from(base64, 'base64').toString('utf8');
console.log(restored); // Node.js Buffers
console.log(restored === original); // true

// Round-trip test for all supported encodings
const testStr = 'Hello!';
const testBuf = Buffer.from(testStr, 'utf8');

const encodings = ['utf8', 'ascii', 'latin1', 'base64', 'base64url', 'hex'];
for (const enc of encodings) {
  const encoded = testBuf.toString(enc);
  const roundTrip = Buffer.from(encoded, enc).toString('utf8');
  console.log(`${enc.padEnd(12)}: encode='${encoded}' → roundTrip='${roundTrip}' match=${roundTrip === testStr}`);
}
```

---

## Buffer.byteLength — The Encoding-Aware Length

`Buffer.byteLength(string, encoding)` tells you how many bytes a string will occupy in a given encoding without actually creating a Buffer. This is critical for protocols that require a byte-length header.

```javascript
'use strict';

const str = 'Hello, \u4E16\u754C!'; // Mix of ASCII and 3-byte CJK

// String length (UTF-16 code units) vs byte length (UTF-8 bytes)
console.log('String length:', str.length);                    // 10
console.log('UTF-8 bytes:',  Buffer.byteLength(str, 'utf8')); // 14
console.log('UTF-16LE bytes:', Buffer.byteLength(str, 'utf16le')); // 20
console.log('ASCII bytes:',  Buffer.byteLength(str, 'ascii')); // 10
console.log('Latin1 bytes:', Buffer.byteLength(str, 'latin1')); // 10

// This is essential for HTTP Content-Length headers
const body = JSON.stringify({ message: 'cafe\u0301' });
const contentLength = Buffer.byteLength(body, 'utf8');
console.log(`Content-Length: ${contentLength}`);
// Do NOT use body.length — it counts characters, not bytes
```

---

## Common Encoding Pitfalls

### Pitfall 1: Using String Length for Byte Length

```javascript
'use strict';

const text = 'cafe'; // 5 characters but 6 bytes in UTF-8
console.log(text.length);                       // 5
console.log(Buffer.byteLength(text, 'utf8'));   // 6
// If you use text.length as Content-Length, the last byte is truncated
```

### Pitfall 2: Wrong Encoding on Decode

```javascript
'use strict';

const original = 'cafe';
const buf = Buffer.from(original, 'utf8');

// Correct decoding
console.log(buf.toString('utf8'));    // cafe (correct)

// Wrong decoding — interprets UTF-8 bytes as Latin-1
console.log(buf.toString('latin1')); // cafÃ© (mojibake!)
```

### Pitfall 3: Assuming ASCII for User Input

```javascript
'use strict';

const userName = 'Rene\u0301e'; // Renee with accent
const asciiBuf = Buffer.from(userName, 'ascii');
const restored = asciiBuf.toString('ascii');
console.log(restored === userName); // false — data corruption!

// Always use UTF-8 for user-facing text
const utf8Buf = Buffer.from(userName, 'utf8');
const safeRestored = utf8Buf.toString('utf8');
console.log(safeRestored === userName); // true
```

---

## Practical Example: Detecting File Encoding

```javascript
'use strict';

const fs = require('node:fs');

function detectBom(filePath) {
  const fd = fs.openSync(filePath, 'r');
  const buf = Buffer.alloc(4);
  const bytesRead = fs.readSync(fd, buf, 0, 4, 0);
  fs.closeSync(fd);

  if (bytesRead < 2) return { encoding: 'unknown', bomLength: 0 };

  // Check for Byte Order Marks (BOMs)
  if (buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) {
    return { encoding: 'utf-8-bom', bomLength: 3 };
  }
  if (buf[0] === 0xFF && buf[1] === 0xFE) {
    if (buf[2] === 0x00 && buf[3] === 0x00) {
      return { encoding: 'utf-32-le', bomLength: 4 };
    }
    return { encoding: 'utf-16-le', bomLength: 2 };
  }
  if (buf[0] === 0xFE && buf[1] === 0xFF) {
    return { encoding: 'utf-16-be', bomLength: 2 };
  }
  if (buf[0] === 0x00 && buf[1] === 0x00 && buf[2] === 0xFE && buf[3] === 0xFF) {
    return { encoding: 'utf-32-be', bomLength: 4 };
  }

  return { encoding: 'no-bom (likely utf-8)', bomLength: 0 };
}

// Usage:
// console.log(detectBom('/tmp/test.txt'));
// { encoding: 'utf-8-bom', bomLength: 3 }
```

---

## Encoding Quick-Reference Diagram

```
         ┌───────────────────────────────────────────────┐
         │                  Unicode                       │
         │         (Character Set: U+0000 to U+10FFFF)    │
         └────────────┬──────────────┬───────────────────┘
                      │              │
              ┌───────┴───────┐  ┌──┴──────────┐
              │    UTF-8      │  │   UTF-16     │
              │  1-4 bytes    │  │  2-4 bytes   │
              │  Web standard │  │  JS internal │
              └───────────────┘  └──────────────┘

   ┌─────────┐   ┌─────────────┐   ┌──────────┐   ┌──────────┐
   │  ASCII   │   │   Latin-1   │   │  Base64  │   │   Hex    │
   │  7-bit   │   │   8-bit     │   │ 6-bit    │   │  4-bit   │
   │  128 ch  │   │   256 ch    │   │ per char │   │ per char │
   │  subset  │   │  superset   │   │ bin→text │   │ bin→text │
   │  of UTF-8│   │  of ASCII   │   │ transport│   │ debugging│
   └─────────┘   └─────────────┘   └──────────┘   └──────────┘
```

---

## Key Takeaways

- A character encoding maps characters to bytes; using the wrong encoding on decode produces mojibake (garbled text) or silent data corruption
- UTF-8 is the default and correct choice for almost everything in Node.js — it is variable-length (1-4 bytes), ASCII-compatible, and self-synchronizing
- JavaScript strings are internally UTF-16, which means `string.length` counts 16-bit code units, not characters and not bytes — always use `Buffer.byteLength()` for byte counts
- When processing UTF-8 text in chunks, use `StringDecoder` (Node.js streams) or `TextDecoder` with `{ stream: true }` (Web API) to prevent multi-byte characters from being split across boundaries
- Base64 and hex encodings convert binary data into text-safe representations at the cost of size overhead (33% for Base64, 100% for hex)

---

## Next

Continue to [Lesson 04 — Buffer Creation & Allocation](lesson-04-buffer-creation-allocation.md) where you will learn the differences between `Buffer.alloc()`, `Buffer.allocUnsafe()`, and `Buffer.from()` — including the security risks of uninitialized memory and how Node.js's internal 8 KB pool works under the hood.
