# Module 05 / Lesson 07 — Building Custom Streams

> The four built-in stream types — Readable, Writable, Duplex, and Transform — cover most use cases. But when you need a data source that generates synthetic data, a sink that writes to a custom database, or a transform that does something no existing module provides, you extend these classes yourself. Custom streams are how you integrate Node.js streaming with any data source or destination that does not ship with a `.pipe()` method.

## Learning Objectives

- Extend `Readable` by implementing `_read()` to create custom data sources
- Extend `Writable` by implementing `_write()`, `_writev()`, and `_final()` for custom data sinks
- Build `Duplex` and `Transform` streams for bidirectional and transformation use cases
- Use `_construct()` for async initialization and `_destroy()` for resource cleanup
- Understand object mode, error handling conventions, and `stream.Readable.from()` for quick stream creation

---

## The Underscore Convention

When you extend a stream class, you implement methods that start with an underscore: `_read()`, `_write()`, `_transform()`, `_flush()`, `_destroy()`, `_construct()`, `_final()`. These are internal methods — Node.js calls them for you. You never call them directly.

The public methods (`read()`, `write()`, `push()`, `end()`) are what consumers use. The underscore methods are what implementors provide.

```
Consumer API        Implementor API
-----------         ---------------
readable.read()  →  _read(size)
writable.write() →  _write(chunk, encoding, callback)
writable.end()   →  _final(callback)
stream.destroy() →  _destroy(err, callback)
```

---

## Custom Readable — Creating a Data Source

A custom Readable stream must implement `_read(size)`. Inside `_read()`, you push data into the internal buffer using `this.push(chunk)`. When there is no more data, push `null` to signal the end.

### Basic Counter Stream

```javascript
'use strict';

const { Readable } = require('node:stream');

class CounterStream extends Readable {
  constructor(max, options) {
    super(options);
    this.max = max;
    this.current = 0;
  }

  _read(size) {
    if (this.current >= this.max) {
      this.push(null); // Signal end of stream
      return;
    }

    this.current++;
    const data = `${this.current}\n`;
    this.push(data); // Push string (will be converted to Buffer internally)
  }
}

// Usage
const counter = new CounterStream(5);
counter.on('data', (chunk) => process.stdout.write(chunk.toString()));
counter.on('end', () => console.log('Done'));
// Output: 1\n2\n3\n4\n5\nDone
```

### Important `push()` Rules

```javascript
'use strict';

const { Readable } = require('node:stream');

class ExampleReadable extends Readable {
  _read(size) {
    // push() returns true if the consumer wants more data
    // push() returns false if the internal buffer is full (backpressure)
    const wantsMore = this.push('data\n');

    if (!wantsMore) {
      // Stop pushing — _read() will be called again when the consumer drains
      return;
    }

    // push(null) signals end-of-stream — NEVER push data after pushing null
    // this.push(null);

    // You can push multiple times in a single _read() call
    // this.push('line 1\n');
    // this.push('line 2\n');
  }
}
```

### Async Data Source

When your data source is asynchronous (database query, HTTP request), you can use `async _read()` or push data from the async callback.

```javascript
'use strict';

const { Readable } = require('node:stream');
const fs = require('node:fs/promises');
const path = require('node:path');

class DirectoryListStream extends Readable {
  constructor(dirPath, options) {
    super({ ...options, encoding: 'utf8' });
    this.dirPath = dirPath;
    this.entries = null;
    this.index = 0;
  }

  async _read(size) {
    // Lazy-load the directory listing on first read
    if (this.entries === null) {
      try {
        this.entries = await fs.readdir(this.dirPath, { withFileTypes: true });
      } catch (err) {
        this.destroy(err);
        return;
      }
    }

    // Push entries one at a time
    if (this.index >= this.entries.length) {
      this.push(null);
      return;
    }

    const entry = this.entries[this.index++];
    const type = entry.isDirectory() ? 'DIR ' : 'FILE';
    this.push(`${type} ${entry.name}\n`);
  }
}

// Usage
const listing = new DirectoryListStream('/tmp');
listing.pipe(process.stdout);
```

---

## Custom Writable — Creating a Data Sink

A custom Writable must implement `_write(chunk, encoding, callback)`. Call `callback()` when the write is complete, or `callback(err)` on failure.

### Console Logger Stream

```javascript
'use strict';

const { Writable } = require('node:stream');

class LoggerStream extends Writable {
  constructor(prefix, options) {
    super(options);
    this.prefix = prefix;
    this.lineCount = 0;
  }

  _write(chunk, encoding, callback) {
    const lines = chunk.toString().split('\n').filter((l) => l.length > 0);

    for (const line of lines) {
      this.lineCount++;
      console.log(`[${this.prefix}] #${this.lineCount}: ${line}`);
    }

    // Signal that we are ready for the next chunk
    callback();
  }

  _final(callback) {
    // Called when writable.end() is called — flush any remaining state
    console.log(`[${this.prefix}] Stream ended. Total lines: ${this.lineCount}`);
    callback();
  }
}

// Usage
const logger = new LoggerStream('APP');
logger.write('Hello\n');
logger.write('World\n');
logger.end();
// [APP] #1: Hello
// [APP] #2: World
// [APP] Stream ended. Total lines: 2
```

### `_writev()` — Batch Writes

When multiple `write()` calls are buffered (due to backpressure), Node.js can call `_writev()` instead of `_write()` for each chunk individually. This enables batch optimizations.

```javascript
'use strict';

const { Writable } = require('node:stream');
const fs = require('node:fs');

class BatchFileWriter extends Writable {
  constructor(filePath, options) {
    super(options);
    this.filePath = filePath;
    this.fd = null;
  }

  _construct(callback) {
    // Open the file before any writes (see _construct section below)
    fs.open(this.filePath, 'a', (err, fd) => {
      if (err) return callback(err);
      this.fd = fd;
      callback();
    });
  }

  _write(chunk, encoding, callback) {
    fs.write(this.fd, chunk, callback);
  }

  _writev(chunks, callback) {
    // Batch write — concatenate all pending chunks into a single write
    const combined = Buffer.concat(chunks.map((item) => {
      return typeof item.chunk === 'string'
        ? Buffer.from(item.chunk, item.encoding)
        : item.chunk;
    }));

    fs.write(this.fd, combined, (err) => {
      if (err) return callback(err);
      callback();
    });
  }

  _final(callback) {
    // Flush any OS buffers
    fs.fsync(this.fd, (err) => {
      if (err) return callback(err);
      callback();
    });
  }

  _destroy(err, callback) {
    if (this.fd !== null) {
      fs.close(this.fd, (closeErr) => {
        callback(closeErr || err);
      });
    } else {
      callback(err);
    }
  }
}

// Usage
const writer = new BatchFileWriter('/tmp/batch-output.txt');
writer.write('Line 1\n');
writer.write('Line 2\n');
writer.write('Line 3\n');
writer.end(() => console.log('All lines written'));
```

---

## Custom Transform — In-Flight Data Transformation

Transform streams implement `_transform(chunk, encoding, callback)` and optionally `_flush(callback)` for final processing when the input ends.

### CSV Line Parser

```javascript
'use strict';

const { Transform } = require('node:stream');

class CsvParser extends Transform {
  constructor(options) {
    super({ ...options, readableObjectMode: true });
    this.headers = null;
    this.buffer = '';
  }

  _transform(chunk, encoding, callback) {
    this.buffer += chunk.toString();
    const lines = this.buffer.split('\n');
    this.buffer = lines.pop(); // Keep incomplete last line in buffer

    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.length === 0) continue;

      const fields = trimmed.split(',').map((f) => f.trim());

      if (this.headers === null) {
        this.headers = fields;
        continue;
      }

      // Build an object from headers + values
      const record = {};
      for (let i = 0; i < this.headers.length; i++) {
        record[this.headers[i]] = fields[i] || '';
      }

      this.push(record); // Push object (objectMode on readable side)
    }

    callback();
  }

  _flush(callback) {
    // Process any remaining data in the buffer
    if (this.buffer.trim().length > 0 && this.headers !== null) {
      const fields = this.buffer.trim().split(',').map((f) => f.trim());
      const record = {};
      for (let i = 0; i < this.headers.length; i++) {
        record[this.headers[i]] = fields[i] || '';
      }
      this.push(record);
    }
    callback();
  }
}

// Usage
const fs = require('node:fs');
const { pipeline } = require('node:stream');

const parser = new CsvParser();

pipeline(
  fs.createReadStream('/tmp/data.csv'),
  parser,
  new (require('node:stream').Writable)({
    objectMode: true,
    write(record, encoding, callback) {
      console.log('Record:', record);
      callback();
    }
  }),
  (err) => {
    if (err) console.error('Pipeline error:', err.message);
    else console.log('Parsing complete');
  }
);
```

### Encryption Transform

```javascript
'use strict';

const { Transform } = require('node:stream');
const crypto = require('node:crypto');

class EncryptTransform extends Transform {
  constructor(algorithm, key, iv, options) {
    super(options);
    this.cipher = crypto.createCipheriv(algorithm, key, iv);
  }

  _transform(chunk, encoding, callback) {
    try {
      const encrypted = this.cipher.update(chunk);
      callback(null, encrypted);
    } catch (err) {
      callback(err);
    }
  }

  _flush(callback) {
    try {
      const final = this.cipher.final();
      callback(null, final);
    } catch (err) {
      callback(err);
    }
  }
}

// Usage
const key = crypto.randomBytes(32);
const iv = crypto.randomBytes(16);

const encryptor = new EncryptTransform('aes-256-cbc', key, iv);

// Encrypt a file
const fs = require('node:fs');
const { pipeline } = require('node:stream');

pipeline(
  fs.createReadStream('/tmp/plaintext.txt'),
  encryptor,
  fs.createWriteStream('/tmp/encrypted.bin'),
  (err) => {
    if (err) console.error('Encryption failed:', err.message);
    else console.log('File encrypted');
  }
);
```

---

## Custom Duplex — Bidirectional Streams

Duplex streams have independent readable and writable sides. The readable side does not have to produce data related to what the writable side receives.

```javascript
'use strict';

const { Duplex } = require('node:stream');

class EchoWithStats extends Duplex {
  constructor(options) {
    super(options);
    this.bytesWritten = 0;
    this.chunks = [];
  }

  _write(chunk, encoding, callback) {
    this.bytesWritten += chunk.length;
    this.chunks.push(chunk);
    callback();
  }

  _read(size) {
    if (this.chunks.length > 0) {
      const chunk = this.chunks.shift();
      this.push(chunk);
    } else {
      // No data available right now — _read will be called again
      // when more data is written
      this.push(null); // or wait for more data
    }
  }

  _final(callback) {
    // All writes are done — signal end on the readable side
    console.log(`Total bytes written: ${this.bytesWritten}`);
    callback();
  }
}
```

### When to Use Duplex vs Transform

| Use Case                                    | Type        |
|---------------------------------------------|-------------|
| Output depends on input (1:1 or 1:many)     | Transform   |
| Read and write sides are independent        | Duplex      |
| Network socket (send and receive)           | Duplex      |
| Data conversion (compress, parse, encrypt)  | Transform   |
| Buffering/queuing between producer/consumer | Duplex      |

---

## `_construct()` — Async Initialization

`_construct(callback)` runs before any `_read()` or `_write()` calls. It is the right place for async setup: opening files, connecting to databases, loading configuration.

```javascript
'use strict';

const { Writable } = require('node:stream');
const fs = require('node:fs');

class SafeFileWriter extends Writable {
  constructor(filePath, options) {
    super(options);
    this.filePath = filePath;
    this.fd = null;
  }

  _construct(callback) {
    // This runs before any _write() call
    fs.open(this.filePath, 'w', (err, fd) => {
      if (err) {
        callback(err); // Stream emits 'error' event
        return;
      }
      this.fd = fd;
      callback(); // Ready for writes
    });
  }

  _write(chunk, encoding, callback) {
    // this.fd is guaranteed to be set because _construct completed first
    fs.write(this.fd, chunk, callback);
  }

  _destroy(err, callback) {
    if (this.fd !== null) {
      fs.close(this.fd, (closeErr) => callback(closeErr || err));
    } else {
      callback(err);
    }
  }
}

// Usage — writes are buffered until _construct completes
const writer = new SafeFileWriter('/tmp/safe-output.txt');
writer.write('This is buffered until the file is opened\n');
writer.write('So is this\n');
writer.end('Final line\n');
writer.on('finish', () => console.log('Write complete'));
writer.on('error', (err) => console.error('Error:', err.message));
```

---

## `_destroy()` — Resource Cleanup

`_destroy(err, callback)` is called when the stream is destroyed (explicitly via `.destroy()` or automatically by `pipeline()`). Use it to close file descriptors, database connections, timers, or any other resource.

```javascript
'use strict';

const { Readable } = require('node:stream');

class TimerStream extends Readable {
  constructor(intervalMs, options) {
    super(options);
    this.intervalMs = intervalMs;
    this.timer = null;
    this.count = 0;
  }

  _construct(callback) {
    // Start a timer that pushes data periodically
    this.timer = setInterval(() => {
      this.count++;
      const ok = this.push(`tick ${this.count}\n`);
      if (!ok) {
        // Backpressure — pause the timer
        clearInterval(this.timer);
        this.timer = null;
      }
    }, this.intervalMs);

    callback();
  }

  _read(size) {
    // Resume the timer if it was paused by backpressure
    if (this.timer === null) {
      this.timer = setInterval(() => {
        this.count++;
        const ok = this.push(`tick ${this.count}\n`);
        if (!ok) {
          clearInterval(this.timer);
          this.timer = null;
        }
      }, this.intervalMs);
    }
  }

  _destroy(err, callback) {
    // ALWAYS clean up resources here
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
    callback(err);
  }
}

// Usage — timer is cleaned up when stream is destroyed
const ticks = new TimerStream(500);

ticks.on('data', (chunk) => process.stdout.write(chunk.toString()));

setTimeout(() => {
  ticks.destroy();
  console.log('Timer stream destroyed');
}, 3000);
```

---

## `stream.Readable.from()` — Quick Stream Creation

When you have an iterable or async iterable and just need to wrap it in a Readable stream, `Readable.from()` saves you from writing a class.

```javascript
'use strict';

const { Readable } = require('node:stream');

// From an array
const arrayStream = Readable.from(['hello\n', 'world\n']);
arrayStream.pipe(process.stdout);
```

### From an Async Generator

```javascript
'use strict';

const { Readable } = require('node:stream');

async function* generateLines(count) {
  for (let i = 1; i <= count; i++) {
    // Simulate async work
    await new Promise((resolve) => setTimeout(resolve, 100));
    yield `Line ${i}: ${new Date().toISOString()}\n`;
  }
}

const stream = Readable.from(generateLines(5));
stream.pipe(process.stdout);
```

### Object Mode with `Readable.from()`

When the iterable yields non-string/non-Buffer values, the stream automatically enters object mode.

```javascript
'use strict';

const { Readable, Writable } = require('node:stream');
const { pipeline } = require('node:stream');

function* generateRecords() {
  yield { id: 1, name: 'Alice', role: 'admin' };
  yield { id: 2, name: 'Bob', role: 'user' };
  yield { id: 3, name: 'Charlie', role: 'user' };
}

const objectStream = Readable.from(generateRecords());

const printer = new Writable({
  objectMode: true,
  write(record, encoding, callback) {
    console.log(`User #${record.id}: ${record.name} (${record.role})`);
    callback();
  },
});

pipeline(objectStream, printer, (err) => {
  if (err) console.error(err.message);
  else console.log('All records processed');
});
```

---

## Object Mode in Custom Streams

By default, streams operate on Buffers and strings. Setting `objectMode: true` lets you push and receive JavaScript objects, arrays, numbers — any value except `null` (which signals end-of-stream).

```javascript
'use strict';

const { Transform } = require('node:stream');

class JsonLineParser extends Transform {
  constructor(options) {
    super({
      ...options,
      readableObjectMode: true, // Output side: objects
      writableObjectMode: false, // Input side: Buffer/string
    });
    this.buffer = '';
  }

  _transform(chunk, encoding, callback) {
    this.buffer += chunk.toString();
    const lines = this.buffer.split('\n');
    this.buffer = lines.pop();

    for (const line of lines) {
      if (line.trim().length === 0) continue;
      try {
        this.push(JSON.parse(line));
      } catch (err) {
        // Skip malformed lines, or: this.destroy(err);
      }
    }
    callback();
  }

  _flush(callback) {
    if (this.buffer.trim().length > 0) {
      try {
        this.push(JSON.parse(this.buffer));
      } catch {
        // Ignore
      }
    }
    callback();
  }
}
```

### `highWaterMark` in Object Mode

In Buffer mode, `highWaterMark` is in bytes (default: 16,384 = 16 KB). In object mode, it is the number of objects (default: 16).

```javascript
'use strict';

const { Readable } = require('node:stream');

const objectStream = new Readable({
  objectMode: true,
  highWaterMark: 100, // Buffer up to 100 objects (not 100 bytes)
  read() {
    // ...
  },
});
```

---

## Error Handling in Custom Streams

### `callback(err)` — Signal an Error During Processing

Calling `callback(err)` from `_write()`, `_transform()`, or `_read()` emits an `'error'` event on the stream. If used inside a `pipeline()`, this properly destroys all connected streams.

```javascript
'use strict';

const { Transform } = require('node:stream');

class StrictJsonParser extends Transform {
  constructor(options) {
    super({ ...options, readableObjectMode: true });
  }

  _transform(chunk, encoding, callback) {
    try {
      const obj = JSON.parse(chunk.toString());
      callback(null, obj); // success: no error, push the parsed object
    } catch (err) {
      // Signal error — pipeline will destroy all streams
      callback(new Error(`Invalid JSON: ${err.message}`));
    }
  }
}
```

### `this.destroy(err)` — Abort the Stream Immediately

Use `destroy()` when recovery is impossible and you want to stop the stream immediately.

```javascript
'use strict';

const { Readable } = require('node:stream');
const fs = require('node:fs');

class FileChunkReader extends Readable {
  constructor(filePath, chunkSize, options) {
    super(options);
    this.filePath = filePath;
    this.chunkSize = chunkSize;
    this.fd = null;
    this.position = 0;
  }

  _construct(callback) {
    fs.open(this.filePath, 'r', (err, fd) => {
      if (err) return callback(err);
      this.fd = fd;
      callback();
    });
  }

  _read(size) {
    const buf = Buffer.alloc(this.chunkSize);
    fs.read(this.fd, buf, 0, this.chunkSize, this.position, (err, bytesRead) => {
      if (err) {
        // Unrecoverable — destroy the stream
        this.destroy(err);
        return;
      }

      if (bytesRead === 0) {
        this.push(null); // EOF
        return;
      }

      this.position += bytesRead;
      this.push(buf.subarray(0, bytesRead));
    });
  }

  _destroy(err, callback) {
    if (this.fd !== null) {
      fs.close(this.fd, (closeErr) => callback(closeErr || err));
    } else {
      callback(err);
    }
  }
}
```

### Error Handling Decision Guide

| Situation                              | Use                    |
|----------------------------------------|------------------------|
| Recoverable per-chunk error            | `callback(err)`        |
| Unrecoverable / corrupted state        | `this.destroy(err)`    |
| Cleanup on any destruction             | `_destroy(err, cb)`    |
| Final flush fails                      | `callback(err)` in `_flush`  |
| Async init fails                       | `callback(err)` in `_construct` |

---

## Putting It All Together — A Complete Example

A custom pipeline: generate random access log entries, parse them, filter by status code, and write a summary.

```javascript
'use strict';

const { Readable, Transform, Writable } = require('node:stream');
const { pipeline } = require('node:stream/promises');

// Custom Readable: generates fake access log entries
class LogGenerator extends Readable {
  constructor(count, options) {
    super({ ...options, encoding: 'utf8' });
    this.count = count;
    this.current = 0;
    this.paths = ['/api/users', '/api/orders', '/health', '/static/app.js'];
    this.statuses = [200, 200, 200, 301, 404, 500];
  }

  _read() {
    if (this.current >= this.count) {
      this.push(null);
      return;
    }
    this.current++;
    const p = this.paths[Math.floor(Math.random() * this.paths.length)];
    const s = this.statuses[Math.floor(Math.random() * this.statuses.length)];
    const ms = Math.floor(Math.random() * 500);
    this.push(`${new Date().toISOString()} ${s} ${ms}ms ${p}\n`);
  }
}

// Custom Transform: parse log lines into objects
class LogParser extends Transform {
  constructor(options) {
    super({ ...options, readableObjectMode: true });
    this.buffer = '';
  }

  _transform(chunk, encoding, callback) {
    this.buffer += chunk.toString();
    const lines = this.buffer.split('\n');
    this.buffer = lines.pop();

    for (const line of lines) {
      if (line.trim().length === 0) continue;
      const parts = line.split(' ');
      this.push({
        timestamp: parts[0],
        status: parseInt(parts[1], 10),
        duration: parts[2],
        path: parts[3],
      });
    }
    callback();
  }

  _flush(callback) {
    if (this.buffer.trim().length > 0) {
      const parts = this.buffer.split(' ');
      this.push({
        timestamp: parts[0],
        status: parseInt(parts[1], 10),
        duration: parts[2],
        path: parts[3],
      });
    }
    callback();
  }
}

// Custom Writable: aggregate and print summary
class LogSummarizer extends Writable {
  constructor(options) {
    super({ ...options, objectMode: true });
    this.statusCounts = {};
    this.totalRequests = 0;
  }

  _write(record, encoding, callback) {
    this.totalRequests++;
    const key = String(record.status);
    this.statusCounts[key] = (this.statusCounts[key] || 0) + 1;
    callback();
  }

  _final(callback) {
    console.log('\n--- Access Log Summary ---');
    console.log(`Total requests: ${this.totalRequests}`);
    for (const [status, count] of Object.entries(this.statusCounts).sort()) {
      const pct = ((count / this.totalRequests) * 100).toFixed(1);
      console.log(`  ${status}: ${count} (${pct}%)`);
    }
    callback();
  }
}

// Run the pipeline
async function main() {
  await pipeline(
    new LogGenerator(1000),
    new LogParser(),
    new LogSummarizer()
  );
  console.log('Pipeline complete');
}

main().catch(console.error);
```

---

## Key Takeaways

- Implement `_read(size)` in custom Readables and call `this.push(data)` to emit data; push `null` to signal end-of-stream and never push data after `null`
- Implement `_write(chunk, encoding, callback)` in custom Writables and always call `callback()` when done — use `_writev(chunks, callback)` for batch optimization when multiple writes are buffered
- Use `_construct(callback)` for async initialization (opening files, connecting to databases) that must complete before any read or write occurs
- Always implement `_destroy(err, callback)` to clean up resources (file descriptors, timers, connections) — this is called by both manual `.destroy()` and `pipeline()` cleanup
- Use `stream.Readable.from(iterable)` when you just need to wrap an array, generator, or async generator in a Readable — it saves you from writing a class for simple cases

---

## Next

Continue to [Lesson 08 — Stream Performance Patterns](lesson-08-stream-performance.md), where you will learn how to tune `highWaterMark`, benchmark different streaming approaches, avoid memory leaks, and know when streams are overkill.
