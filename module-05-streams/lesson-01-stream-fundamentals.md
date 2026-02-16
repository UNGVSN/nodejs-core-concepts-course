# Module 05 / Lesson 01 — Stream Fundamentals

> Every time you read a multi-gigabyte log file into a single `Buffer`, a production server somewhere sheds a tear. Streams exist so you never have to hold an entire dataset in memory at once — they let you process data piece by piece, the way Unix pipes have done it since the 1970s.

## Learning Objectives

- Explain why streams are essential for memory-efficient I/O in Node.js
- Identify the four stream types: Readable, Writable, Duplex, and Transform
- Distinguish between flowing mode and paused mode in Readable streams
- Describe the role of `highWaterMark` in controlling internal buffering
- Recognize where streams appear throughout the Node.js core API

---

## Why Streams Exist

Consider a simple task: copy a 2 GB file from one location to another. The naive approach loads the entire file into memory first.

```js
'use strict';

const fs = require('node:fs');

// DON'T do this with large files
const contents = fs.readFileSync('/var/log/huge.log');
fs.writeFileSync('/tmp/huge-copy.log', contents);
// Peak memory: ~2 GB + overhead
```

This works for small files, but it forces Node.js to allocate a buffer large enough to hold the entire file. With a 2 GB file, you need at least 2 GB of free heap — and in a server handling multiple concurrent requests, that arithmetic gets deadly fast.

Streams solve this by processing data in chunks. Instead of "read everything, then write everything," you read a small piece, write that piece, read the next piece, and so on.

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('/var/log/huge.log');
const writable = fs.createWriteStream('/tmp/huge-copy.log');

readable.pipe(writable);
// Peak memory: ~64 KB (one highWaterMark chunk)
```

The memory footprint drops from gigabytes to kilobytes. That is the entire argument for streams in one example.

### The Fundamental Contract

Streams represent a sequence of data made available over time. Rather than requiring all data to exist in memory simultaneously, streams deliver data incrementally. This contract enables three things:

1. **Memory efficiency** — process data larger than available RAM
2. **Time efficiency** — start processing before all data has arrived
3. **Composability** — chain processing steps together like Unix pipes

---

## The Four Stream Types

Node.js defines four fundamental stream types in the `node:stream` module. Every stream you encounter in core — file I/O, HTTP, TCP sockets, zlib compression, crypto ciphers — is one of these four.

### Readable

A source of data. You consume from it.

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.txt');

readable.on('data', (chunk) => {
  console.log(`Received ${chunk.length} bytes`);
});

readable.on('end', () => {
  console.log('No more data');
});
```

Core examples of Readable streams:
- `fs.createReadStream()`
- `http.IncomingMessage` (request on the server, response on the client)
- `process.stdin`
- `crypto.createHash()` output side
- `child_process.stdout` / `child_process.stderr`

### Writable

A destination for data. You push data into it.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('output.txt');

writable.write('Hello, ');
writable.write('streams!\n');
writable.end(); // Signal that no more data will be written
```

Core examples of Writable streams:
- `fs.createWriteStream()`
- `http.ServerResponse`
- `process.stdout` / `process.stderr`
- `crypto.createCipher()` input side

### Duplex

Both Readable and Writable, independently. Data flows in both directions, but the two sides are not necessarily related.

```js
'use strict';

const net = require('node:net');

// A TCP socket is a Duplex stream
const server = net.createServer((socket) => {
  // socket is Duplex: you can read FROM and write TO it
  socket.on('data', (chunk) => {
    console.log(`Client says: ${chunk}`);
  });

  socket.write('Welcome!\n');
});

server.listen(3000);
```

Core examples of Duplex streams:
- `net.Socket`
- TCP sockets in general
- `tls.TLSSocket`

### Transform

A special Duplex where the output is computed from the input. Data goes in one side, gets transformed, and comes out the other.

```js
'use strict';

const { createGzip } = require('node:zlib');

// gzip is a Transform: uncompressed bytes in, compressed bytes out
const gzip = createGzip();

process.stdin.pipe(gzip).pipe(process.stdout);
```

Core examples of Transform streams:
- `zlib.createGzip()` / `zlib.createGunzip()`
- `crypto.createCipheriv()` / `crypto.createDecipheriv()`
- `crypto.createHash()`

### Quick Reference Table

| Type      | Reads? | Writes? | Example                  |
|-----------|--------|---------|--------------------------|
| Readable  | Yes    | No      | `fs.createReadStream()`  |
| Writable  | No     | Yes     | `fs.createWriteStream()` |
| Duplex    | Yes    | Yes     | `net.Socket`             |
| Transform | Yes    | Yes     | `zlib.createGzip()`      |

---

## Flowing Mode vs Paused Mode

Readable streams operate in one of two modes. Understanding these modes is critical to using streams correctly.

### Paused Mode (the default)

When a Readable stream is created, it starts in paused mode. Data accumulates in the internal buffer, and you must explicitly call `read()` to pull chunks out.

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.txt');

readable.on('readable', () => {
  // The 'readable' event means there is data in the buffer
  let chunk;
  while ((chunk = readable.read()) !== null) {
    console.log(`Read ${chunk.length} bytes`);
  }
});

readable.on('end', () => {
  console.log('Done');
});
```

In paused mode, you are in control. The stream will not push data at you — you pull it when you are ready.

### Flowing Mode

In flowing mode, data is read from the underlying source automatically and delivered to your code as fast as possible via events.

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.txt');

// Attaching a 'data' listener switches the stream to flowing mode
readable.on('data', (chunk) => {
  console.log(`Received ${chunk.length} bytes`);
});

readable.on('end', () => {
  console.log('Done');
});
```

### Switching Between Modes

A stream can switch between modes. Here are the triggers:

**Paused to Flowing:**
- Attaching a `'data'` event listener
- Calling `stream.resume()`
- Calling `stream.pipe(destination)`

**Flowing to Paused:**
- Calling `stream.pause()` (if there are no pipe destinations)
- Removing all pipe destinations with `stream.unpipe()`

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.txt');

// Start in paused mode (default)
console.log(readable.readableFlowing); // null

// Switch to flowing mode
readable.on('data', (chunk) => {
  console.log(`Chunk: ${chunk.length} bytes`);
});
console.log(readable.readableFlowing); // true

// Switch back to paused mode
readable.pause();
console.log(readable.readableFlowing); // false

// Resume flowing mode
readable.resume();
console.log(readable.readableFlowing); // true
```

### The Third State: `null`

Before any consumer is attached, `readableFlowing` is `null`. This is distinct from `false` (paused). In the `null` state, no mechanism for consuming data exists, so no data is generated. Attaching a `'data'` listener, calling `pipe()`, or calling `resume()` will switch the state to `true` and the stream will begin generating data.

---

## The highWaterMark

The `highWaterMark` is the single most important configuration option for any stream. It controls how much data the stream buffers internally before it stops reading from the underlying source.

### How It Works

Think of `highWaterMark` as the "fill line" on a glass of water. The stream fills its internal buffer up to this mark, then pauses until the consumer drains some data.

```js
'use strict';

const fs = require('node:fs');

// Default highWaterMark for file streams: 64 KB (65536 bytes)
const defaultStream = fs.createReadStream('data.txt');
console.log(defaultStream.readableHighWaterMark); // 65536

// Custom highWaterMark: 16 KB
const smallStream = fs.createReadStream('data.txt', {
  highWaterMark: 16 * 1024
});
console.log(smallStream.readableHighWaterMark); // 16384

// Very small highWaterMark for demonstration
const tinyStream = fs.createReadStream('data.txt', {
  highWaterMark: 8
});
console.log(tinyStream.readableHighWaterMark); // 8
```

### Default Values

| Stream type               | Default highWaterMark |
|---------------------------|-----------------------|
| Byte streams (Buffer)     | 16,384 (16 KB)        |
| Object mode streams       | 16 (objects)          |
| `fs.createReadStream()`   | 65,536 (64 KB)        |
| `fs.createWriteStream()`  | 65,536 (64 KB)        |

### The Buffering Dance

Here is what happens internally when you read from a file stream:

1. The stream reads up to `highWaterMark` bytes from the file into its internal buffer
2. It emits `'data'` events (flowing mode) or waits for `read()` calls (paused mode)
3. When the buffer drops below `highWaterMark`, it reads more from the file
4. When the file is exhausted, it emits `'end'`

```js
'use strict';

const fs = require('node:fs');

// With a tiny highWaterMark, you can see many small chunks
const readable = fs.createReadStream('data.txt', {
  highWaterMark: 32
});

let chunkCount = 0;

readable.on('data', (chunk) => {
  chunkCount++;
  console.log(`Chunk #${chunkCount}: ${chunk.length} bytes — "${chunk}"`);
});

readable.on('end', () => {
  console.log(`Total chunks: ${chunkCount}`);
});
```

### Choosing a highWaterMark

The default values work well for most cases. You might adjust `highWaterMark` when:

- **Processing line-by-line** — a smaller value reduces memory per chunk but increases syscall overhead
- **Bulk transfers** — a larger value (e.g., 1 MB) can improve throughput by reducing the number of read/write cycles
- **Memory-constrained environments** — a smaller value keeps the RSS footprint tighter
- **Object mode** — the default of 16 objects is usually fine, but high-throughput object pipelines may benefit from larger buffers

---

## Streams Across the Node.js API

Streams are not a niche feature tucked away in a corner of the standard library. They are woven into nearly every I/O subsystem.

```js
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const { createGzip } = require('node:zlib');

// HTTP response is a Writable stream
// fs.createReadStream returns a Readable stream
// createGzip() returns a Transform stream
const server = http.createServer((req, res) => {
  // req is Readable, res is Writable
  res.writeHead(200, { 'Content-Encoding': 'gzip' });

  fs.createReadStream('large-file.txt')
    .pipe(createGzip())
    .pipe(res);
});

server.listen(3000);
```

This single example chains three stream types together: a Readable file stream pipes into a Transform compression stream, which pipes into a Writable HTTP response. The entire file is compressed and sent to the client without ever fully loading into memory.

### Where You Will Find Streams

| Module            | Readable                 | Writable                  |
|-------------------|--------------------------|---------------------------|
| `node:fs`         | `createReadStream()`     | `createWriteStream()`     |
| `node:http`       | `IncomingMessage`        | `ServerResponse`          |
| `node:net`        | `Socket` (Duplex)        | `Socket` (Duplex)         |
| `node:zlib`       | Transform streams        | Transform streams         |
| `node:crypto`     | Hash, Cipher, Decipher   | Hash, Cipher, Decipher    |
| `node:child_process` | `stdout`, `stderr`    | `stdin`                   |
| `node:process`    | `stdin`                  | `stdout`, `stderr`        |
| `node:readline`   | Wraps any Readable       | —                         |

---

## A Complete Mental Model

Before moving on, let us consolidate. Here is the mental model you should carry through the rest of this module:

1. **Streams are lazy** — they only do work when someone is consuming (or producing) data
2. **Streams buffer internally** — up to `highWaterMark` bytes (or objects)
3. **Backpressure is automatic** — when the consumer is slow, the producer slows down (we will explore this deeply in Lesson 04)
4. **Composition is the point** — streams are designed to be chained together via `pipe()` or `pipeline()`
5. **Errors must be handled** — an unhandled `'error'` event on a stream will crash the process

```js
'use strict';

const { Readable, Writable } = require('node:stream');

// Minimal Readable: pushes three chunks then signals end
const source = new Readable({
  read() {
    this.push('Hello ');
    this.push('from ');
    this.push('streams!\n');
    this.push(null); // null signals end-of-stream
  }
});

// Minimal Writable: logs each chunk
const sink = new Writable({
  write(chunk, encoding, callback) {
    process.stdout.write(chunk);
    callback(); // Signal that this chunk has been processed
  }
});

source.pipe(sink);
// Output: Hello from streams!
```

The `callback()` in the Writable's `_write` method is how backpressure propagates upstream. If you delay calling the callback, the Readable will slow down. If you call it immediately, data flows as fast as the source can produce it. This dance between producer and consumer is the beating heart of the Node.js stream system.

---

## Key Takeaways

- Streams process data incrementally, keeping memory usage constant regardless of data size
- The four stream types — Readable, Writable, Duplex, Transform — cover every I/O pattern in Node.js
- Readable streams start in paused mode and switch to flowing mode when a consumer attaches
- The `highWaterMark` controls how much data a stream buffers internally before applying backpressure
- Streams appear throughout the entire Node.js core API, from file I/O to HTTP to child processes

## Next

In Lesson 02, we dive deep into Readable streams — `fs.createReadStream`, the `'data'`/`'end'`/`'error'` event trio, pull-based reading with `read()`, and the modern `for await...of` async iteration pattern.
