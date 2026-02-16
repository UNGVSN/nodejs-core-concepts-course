# Module 05 — Streams

> Streams are the backbone of Node.js I/O. Every HTTP request, every TCP socket, every file read — they are all streams. Understanding streams is not optional; it is the difference between a server that handles 10,000 concurrent downloads and one that crashes after 50. This module takes you from the four stream types through backpressure mechanics to building your own custom streams.

---

## Learning Objectives

- Explain the four stream types (Readable, Writable, Duplex, Transform) and when to use each
- Distinguish between flowing and paused mode, and control mode transitions deliberately
- Implement correct backpressure handling so your server does not run out of memory under load
- Pipe streams together using both `.pipe()` and `stream.pipeline()`, understanding the error-handling differences
- Build custom Readable, Writable, and Transform streams by extending base classes
- Profile stream performance and choose optimal `highWaterMark` values for your workload

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| L01 | [Stream Fundamentals](lesson-01-stream-fundamentals.md) | Why streams exist, the four types, flowing vs paused mode, `highWaterMark` |
| L02 | [Readable Streams](lesson-02-readable-streams.md) | `fs.createReadStream`, `read()`, `data`/`end`/`error` events, async iteration |
| L03 | [Writable Streams](lesson-03-writable-streams.md) | `fs.createWriteStream`, `write()`, `end()`, `drain` event, return value semantics |
| L04 | [Backpressure Mechanics](lesson-04-backpressure-mechanics.md) | Why backpressure happens, how `write()` returns `false`, the `drain` protocol |
| L05 | [Duplex & Transform Streams](lesson-05-duplex-transform-streams.md) | `net.Socket` as Duplex, building Transform streams, `_transform` and `_flush` |
| L06 | [Piping & Pipeline](lesson-06-piping-pipeline.md) | `pipe()`, `stream.pipeline()`, error propagation, `AbortController` integration |
| L07 | [Building Custom Streams](lesson-07-custom-streams.md) | Extending `Readable`, `Writable`, `Transform`; implementing `_read`, `_write`, `_transform` |
| L08 | [Stream Performance Patterns](lesson-08-stream-performance.md) | Object mode, `stream.compose()`, lazy streams, memory profiling stream pipelines |

---

## Exercises

| # | Exercise | Description |
|---|----------|-------------|
| E01 | [Line-by-Line File Reader](exercise-01-line-by-line-reader.md) | Stream a large file, split by newline, process line by line without loading into memory |
| E02 | [CSV Transform Pipeline](exercise-02-csv-transform-pipeline.md) | Read CSV, transform to JSON objects, write output — all streaming, all backpressure-safe |
| E03 | [Backpressure Stress Test](exercise-03-backpressure-stress-test.md) | Produce data faster than the consumer can handle, observe memory blow-up, then fix it |
| E04 | [Progress Bar Stream](exercise-04-progress-bar-stream.md) | Transform stream that reports progress percentage for file copy operations |
| E05 | [Stream Multiplexer](exercise-05-stream-multiplexer.md) | Read from multiple source streams, merge into a single output with ordering preserved |
| E06 | [Rate-Limited Stream](exercise-06-rate-limited-stream.md) | Transform stream that throttles throughput to N bytes per second |

---

## Progressive Project — Step 05: Streaming Response Support

In this step you replace the `readFile`-based static file serving from Step 04 with proper streaming. By the end of Step 05, your framework serves a 2GB video file without consuming 2GB of memory.

**What you will build:**

- Replace `fs.promises.readFile` with `fs.createReadStream` piped directly to the HTTP response
- Implement `Transfer-Encoding: chunked` for responses where `Content-Length` is unknown or omitted
- Handle backpressure between the file read stream and the HTTP response writable stream
- Support HTTP Range Requests (`Range` header) to enable `206 Partial Content` responses for video seeking and download resumption
- Implement `Accept-Ranges: bytes` in response headers to advertise range support
- Add `ETag` and `Last-Modified` headers for conditional requests (`304 Not Modified`)

**Key code pattern:**

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { pipeline } = require('node:stream/promises');

async function serveFileStream(req, res, filePath, stat) {
  const ext = path.extname(filePath);
  const mimeType = MIME_TYPES[ext] || 'application/octet-stream';

  // Range request support
  const range = req.headers['range'];
  if (range) {
    const [startStr, endStr] = range.replace('bytes=', '').split('-');
    const start = parseInt(startStr, 10);
    const end = endStr ? parseInt(endStr, 10) : stat.size - 1;

    res.writeHead(206, {
      'Content-Range': `bytes ${start}-${end}/${stat.size}`,
      'Accept-Ranges': 'bytes',
      'Content-Length': end - start + 1,
      'Content-Type': mimeType,
    });

    const stream = fs.createReadStream(filePath, { start, end });
    await pipeline(stream, res);
  } else {
    res.writeHead(200, {
      'Content-Length': stat.size,
      'Content-Type': mimeType,
      'Accept-Ranges': 'bytes',
    });

    const stream = fs.createReadStream(filePath);
    await pipeline(stream, res);
  }
}
```

**Builds on:** Step 04 (Static File Serving) — you already map URLs to file paths and set MIME types; now you serve them efficiently via streams.

**Leads to:** Step 06 (TCP Server Foundation) — you will drop down from `http.createServer` to raw TCP with `net.createServer` and parse HTTP bytes yourself.

---

## Prerequisites

- Module 04 (File System) — you will create read and write streams from files
- Module 03 (Buffers) — stream chunks arrive as Buffers; you need to understand slicing, concatenation, and encoding
- Module 02 (EventEmitter) — every stream is an EventEmitter; `data`, `end`, `drain`, and `error` are all events

---

## Key Concepts Introduced

- **Backpressure** — the mechanism that prevents a fast producer from overwhelming a slow consumer
- **highWaterMark** — the internal buffer threshold (in bytes or objects) that triggers backpressure
- **Flowing vs paused mode** — the two states of a Readable stream that determine how data is consumed
- **Pipeline** — `stream.pipeline()` chains streams with automatic error propagation and cleanup
- **Transform stream** — a stream that reads input, modifies it, and writes output (e.g., compression, parsing)
- **Object mode** — streams that pass JavaScript objects instead of Buffers or strings

---

## Next

Continue to [Module 06 — Networking](../module-06-networking/README.md) to understand the TCP and UDP protocols that carry your streams across the network.
