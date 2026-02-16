# Module 05 / Lesson 02 — Readable Streams

> A Readable stream is a faucet you can turn on and off. Whether you want data delivered as fast as possible or pulled one chunk at a time, the Readable API gives you both options — and modern async iteration makes the choice even easier.

## Learning Objectives

- Create file-based Readable streams with `fs.createReadStream()` and its key options
- Handle stream lifecycle through the `'data'`, `'end'`, and `'error'` events
- Pull data manually using `read()` in paused mode
- Consume Readable streams with `for await...of` async iteration
- Control encoding to receive strings instead of Buffers

---

## Creating a Readable Stream with fs.createReadStream

The most common Readable stream in everyday Node.js code is `fs.createReadStream()`. It opens a file descriptor and delivers the file contents in chunks.

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('server.log');

readable.on('data', (chunk) => {
  // chunk is a Buffer by default
  console.log(typeof chunk);       // 'object'
  console.log(Buffer.isBuffer(chunk)); // true
  console.log(chunk.length);       // up to 65536 bytes
});

readable.on('end', () => {
  console.log('Finished reading');
});

readable.on('error', (err) => {
  console.error('Read error:', err.message);
});
```

### Key Options

`fs.createReadStream()` accepts a path and an options object. The options worth knowing:

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.csv', {
  encoding: 'utf8',        // Decode chunks as strings (default: null → Buffer)
  highWaterMark: 32 * 1024, // 32 KB chunks instead of default 64 KB
  start: 0,                // Byte offset to start reading from
  end: 1023,               // Byte offset to stop reading at (inclusive)
  flags: 'r',              // File system flags (default: 'r')
  autoClose: true,         // Automatically close fd on 'end' or 'error' (default: true)
  emitClose: true          // Emit 'close' event after stream is destroyed (default: true)
});

readable.on('data', (chunk) => {
  // With encoding: 'utf8', chunk is now a string
  console.log(typeof chunk); // 'string'
});
```

### Reading a Byte Range

The `start` and `end` options let you read a specific byte range from a file. This is useful for implementing HTTP range requests or reading specific sections of a binary format.

```js
'use strict';

const fs = require('node:fs');

// Read only the first 256 bytes of a file
const readable = fs.createReadStream('large-binary.dat', {
  start: 0,
  end: 255  // inclusive, so this reads 256 bytes
});

const chunks = [];

readable.on('data', (chunk) => {
  chunks.push(chunk);
});

readable.on('end', () => {
  const header = Buffer.concat(chunks);
  console.log(`Read ${header.length} bytes`);
  console.log('Magic bytes:', header.subarray(0, 4).toString('hex'));
});
```

---

## The Event Trio: 'data', 'end', 'error'

These three events form the backbone of Readable stream consumption in flowing mode.

### 'data' — A Chunk Has Arrived

Emitted whenever the stream delivers a chunk of data to the consumer. Attaching a `'data'` listener switches the stream to flowing mode.

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('access.log', { encoding: 'utf8' });

let totalBytes = 0;
let lineCount = 0;

readable.on('data', (chunk) => {
  totalBytes += Buffer.byteLength(chunk);
  // Count newlines in this chunk
  for (let i = 0; i < chunk.length; i++) {
    if (chunk[i] === '\n') lineCount++;
  }
});

readable.on('end', () => {
  console.log(`Total: ${totalBytes} bytes, ${lineCount} lines`);
});

readable.on('error', (err) => {
  console.error('Failed:', err.message);
});
```

### 'end' — No More Data

Emitted when there is no more data to be consumed from the stream. This event fires only after all data has been delivered via `'data'` events or `read()` calls.

Important: `'end'` does **not** fire if the stream is destroyed or encounters an error before the data is fully consumed.

### 'error' — Something Went Wrong

Emitted if the stream encounters an error. Common causes: file not found, permission denied, disk read failure.

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('/nonexistent/path.txt');

readable.on('error', (err) => {
  console.error(`Error code: ${err.code}`);    // 'ENOENT'
  console.error(`Message: ${err.message}`);
  console.error(`Path: ${err.path}`);
});

// Without the 'error' handler, this would throw an
// uncaught exception and crash the process
```

**Rule: always attach an `'error'` handler to every stream.** An unhandled stream error is an unhandled exception.

### 'close' — The File Descriptor Is Released

After `'end'` (or after destruction/error with `autoClose: true`), the stream emits `'close'` to signal that the underlying resource (file descriptor, socket, etc.) has been released.

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.txt');

readable.on('end', () => {
  console.log('1. All data consumed');
});

readable.on('close', () => {
  console.log('2. File descriptor closed');
});

readable.on('data', () => {
  // consume data to reach 'end'
});

// Output order:
// 1. All data consumed
// 2. File descriptor closed
```

---

## Paused Mode: Manual Reading with read()

In paused mode, you pull data out of the stream's internal buffer manually. This gives you fine-grained control over consumption pace.

### The 'readable' Event

The `'readable'` event signals that new data is available in the internal buffer, or that the end of the stream has been reached. Inside the handler, call `read()` in a loop until it returns `null`.

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.txt', {
  highWaterMark: 64
});

readable.on('readable', () => {
  let chunk;
  // read() returns null when the buffer is empty
  while ((chunk = readable.read()) !== null) {
    console.log(`Chunk (${chunk.length} bytes): ${chunk.toString()}`);
  }
});

readable.on('end', () => {
  console.log('Stream exhausted');
});
```

### Reading a Specific Number of Bytes

You can pass a size argument to `read(n)` to request exactly `n` bytes. If fewer than `n` bytes are available, `read(n)` returns `null` (the data stays in the buffer for the next attempt).

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('binary.dat', {
  highWaterMark: 1024
});

readable.on('readable', () => {
  // Read a 4-byte header
  const header = readable.read(4);
  if (header === null) return;

  const messageLength = header.readUInt32BE(0);
  console.log(`Message length: ${messageLength}`);

  // Read the message body
  const body = readable.read(messageLength);
  if (body === null) {
    // Not enough data yet — unshift the header back
    readable.unshift(header);
    return;
  }

  console.log(`Body: ${body.toString()}`);
});
```

### unshift() — Putting Data Back

If you read too much (or realize you need to re-parse), `unshift()` pushes data back to the front of the internal buffer.

```js
'use strict';

const { Readable } = require('node:stream');

// Simulate a stream that delivers lines
const source = new Readable({
  read() {
    this.push('first line\nsecond line\nthird');
    this.push(' line\n');
    this.push(null);
  }
});

source.on('readable', () => {
  let chunk;
  while ((chunk = source.read()) !== null) {
    const str = chunk.toString();
    const lastNewline = str.lastIndexOf('\n');

    if (lastNewline === -1) {
      // No complete line — put it all back and wait
      source.unshift(chunk);
      break;
    }

    // Process complete lines
    const complete = str.slice(0, lastNewline + 1);
    const remainder = str.slice(lastNewline + 1);

    process.stdout.write(complete);

    if (remainder.length > 0) {
      source.unshift(Buffer.from(remainder));
    }
  }
});
```

---

## Async Iteration: for await...of

The most modern and ergonomic way to consume a Readable stream is with `for await...of`. This pattern handles backpressure automatically and integrates cleanly with async/await code.

```js
'use strict';

const fs = require('node:fs');

async function processFile(path) {
  const readable = fs.createReadStream(path, { encoding: 'utf8' });

  let totalChars = 0;

  for await (const chunk of readable) {
    totalChars += chunk.length;
    // The loop automatically applies backpressure:
    // if you do slow async work here, the stream waits
  }

  console.log(`Total characters: ${totalChars}`);
}

processFile('data.txt').catch(console.error);
```

### Error Handling with Async Iteration

Errors thrown by the stream will reject the iterator, which means a `try/catch` around the `for await` loop catches stream errors.

```js
'use strict';

const fs = require('node:fs');

async function safeRead(path) {
  try {
    const readable = fs.createReadStream(path, { encoding: 'utf8' });

    for await (const chunk of readable) {
      console.log(`Got ${chunk.length} chars`);
    }

    console.log('Done');
  } catch (err) {
    if (err.code === 'ENOENT') {
      console.error(`File not found: ${path}`);
    } else {
      console.error(`Read error: ${err.message}`);
    }
  }
}

safeRead('/nonexistent/file.txt');
```

### Line-by-Line Reading

Combine `for await...of` with `readline.createInterface` for line-by-line processing without loading the entire file.

```js
'use strict';

const fs = require('node:fs');
const readline = require('node:readline');

async function countMatchingLines(path, pattern) {
  const fileStream = fs.createReadStream(path, { encoding: 'utf8' });

  const rl = readline.createInterface({
    input: fileStream,
    crlfDelay: Infinity // Treat \r\n as a single newline
  });

  let matchCount = 0;
  let lineNumber = 0;

  for await (const line of rl) {
    lineNumber++;
    if (line.includes(pattern)) {
      matchCount++;
      console.log(`Line ${lineNumber}: ${line}`);
    }
  }

  console.log(`\n${matchCount} matching lines out of ${lineNumber} total`);
}

countMatchingLines('access.log', 'ERROR').catch(console.error);
```

### When to Use Each Pattern

| Pattern                  | Best for                                    |
|--------------------------|---------------------------------------------|
| `'data'` event           | Maximum throughput, fire-and-forget          |
| `'readable'` + `read()`  | Protocol parsing, precise byte control       |
| `for await...of`         | Async processing, clean error handling       |

---

## Encoding: Strings vs Buffers

By default, Readable streams deliver `Buffer` objects. You can get strings instead by setting an encoding.

### Setting Encoding at Creation

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.txt', {
  encoding: 'utf8'
});

readable.on('data', (chunk) => {
  // chunk is a string, not a Buffer
  console.log(typeof chunk); // 'string'
});
```

### Setting Encoding After Creation

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.txt');

// Call setEncoding() before consuming
readable.setEncoding('utf8');

readable.on('data', (chunk) => {
  console.log(typeof chunk); // 'string'
});
```

### Why setEncoding() Matters for Multi-Byte Characters

When you manually call `chunk.toString('utf8')`, you risk splitting a multi-byte character across chunk boundaries. A chunk might end with the first byte of a 3-byte UTF-8 character, producing garbled output.

`setEncoding()` uses an internal `StringDecoder` that handles split characters correctly.

```js
'use strict';

const fs = require('node:fs');

// BAD: Manual toString() can break multi-byte characters
const badStream = fs.createReadStream('unicode.txt', {
  highWaterMark: 8 // Tiny buffer to force splits
});

badStream.on('data', (chunk) => {
  // If a multi-byte char (e.g., emoji) spans two chunks,
  // toString() on each chunk individually will produce garbage
  process.stdout.write(chunk.toString('utf8'));
});

// GOOD: setEncoding handles split characters
const goodStream = fs.createReadStream('unicode.txt', {
  highWaterMark: 8,
  encoding: 'utf8'
});

goodStream.on('data', (chunk) => {
  // chunk is already a properly decoded string
  process.stdout.write(chunk);
});
```

### Supported Encodings

Node.js supports the same encodings in streams as it does in `Buffer`:

- `'utf8'` — the most common, multi-byte Unicode
- `'ascii'` — 7-bit ASCII
- `'utf16le'` — Little-endian UTF-16
- `'base64'` — Base64 encoding
- `'base64url'` — URL-safe Base64
- `'hex'` — Hexadecimal encoding
- `'latin1'` — ISO-8859-1 (also known as `'binary'`)

---

## Destroying a Readable Stream

Sometimes you need to stop reading before the stream reaches its natural end. The `destroy()` method releases the underlying resource immediately.

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('huge-file.log', { encoding: 'utf8' });

let found = false;

readable.on('data', (chunk) => {
  if (chunk.includes('CRITICAL ERROR')) {
    console.log('Found the error, stopping');
    found = true;
    readable.destroy(); // Stops reading, closes the file descriptor
  }
});

readable.on('close', () => {
  console.log('Stream closed');
  if (!found) {
    console.log('Error pattern not found in file');
  }
});

readable.on('error', (err) => {
  // destroy() does NOT emit 'error' unless you pass an error:
  // readable.destroy(new Error('reason'));
  console.error('Stream error:', err.message);
});
```

### destroy() with an Error

Pass an `Error` to `destroy()` to simultaneously stop the stream and emit an `'error'` event.

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.txt');

readable.on('data', (chunk) => {
  const isValid = validateChunk(chunk);
  if (!isValid) {
    readable.destroy(new Error('Invalid data format'));
  }
});

readable.on('error', (err) => {
  console.error('Stopped due to:', err.message);
});

function validateChunk(chunk) {
  // Placeholder validation
  return chunk.length > 0;
}
```

---

## Putting It All Together

Here is a practical example that reads a JSON Lines file (one JSON object per line), parses each line, filters for specific records, and counts them.

```js
'use strict';

const fs = require('node:fs');
const readline = require('node:readline');

async function analyzeJsonLines(filePath, filterFn) {
  const fileStream = fs.createReadStream(filePath, { encoding: 'utf8' });

  const rl = readline.createInterface({
    input: fileStream,
    crlfDelay: Infinity
  });

  let total = 0;
  let matched = 0;
  let parseErrors = 0;

  for await (const line of rl) {
    if (line.trim().length === 0) continue;

    total++;
    try {
      const record = JSON.parse(line);
      if (filterFn(record)) {
        matched++;
      }
    } catch {
      parseErrors++;
    }
  }

  return { total, matched, parseErrors };
}

// Usage: find all error-level log entries
analyzeJsonLines('app.jsonl', (record) => record.level === 'error')
  .then((stats) => {
    console.log(`Total records: ${stats.total}`);
    console.log(`Error records: ${stats.matched}`);
    console.log(`Parse errors:  ${stats.parseErrors}`);
  })
  .catch(console.error);
```

This uses `for await...of` via `readline`, processes each line individually (never loading the full file), and handles parse errors gracefully — all in under 40 lines.

---

## Key Takeaways

- `fs.createReadStream()` is the workhorse Readable stream — configure it with `encoding`, `highWaterMark`, `start`, and `end`
- Always handle the `'error'` event on every Readable stream to prevent uncaught exceptions
- Paused mode with `read()` gives byte-level control; flowing mode with `'data'` events gives maximum throughput
- `for await...of` is the modern, ergonomic way to consume Readable streams with automatic backpressure and clean error handling via `try/catch`
- Use `setEncoding()` or the `encoding` option rather than manual `toString()` to avoid corrupting multi-byte characters at chunk boundaries

## Next

In Lesson 03, we turn to the other side of the stream contract — Writable streams — where `write()`, `'drain'`, `end()`, and the `cork()`/`uncork()` mechanism control how data flows into destinations.
