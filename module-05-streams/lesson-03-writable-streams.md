# Module 05 / Lesson 03 — Writable Streams

> If Readable streams are faucets, Writable streams are drains. Understanding how data flows into a Writable — and what happens when you pour faster than it can swallow — is essential for building servers that stay alive under load.

## Learning Objectives

- Create file-based Writable streams with `fs.createWriteStream()` and its key options
- Interpret the boolean return value of `write()` as a backpressure signal
- Implement the `'drain'` protocol to respect buffer limits
- Use `end()` to signal completion and listen for `'finish'`
- Batch writes efficiently with `cork()` and `uncork()`

---

## Creating a Writable Stream with fs.createWriteStream

The most common Writable stream is `fs.createWriteStream()`. It opens a file descriptor and writes data to disk in chunks.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('output.log');

writable.write('First line\n');
writable.write('Second line\n');
writable.write('Third line\n');
writable.end('Final line\n'); // Write last chunk and close

writable.on('finish', () => {
  console.log('All data has been flushed to disk');
});

writable.on('error', (err) => {
  console.error('Write error:', err.message);
});
```

### Key Options

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('output.log', {
  flags: 'a',              // 'w' = overwrite (default), 'a' = append
  encoding: 'utf8',        // Default encoding for string writes
  highWaterMark: 32 * 1024, // 32 KB internal buffer (default: 64 KB for fs)
  autoClose: true,         // Auto-close fd on 'finish' or 'error' (default: true)
  emitClose: true,         // Emit 'close' after stream is destroyed (default: true)
  start: 0                 // Byte offset to start writing at (only with 'r+' flag)
});
```

### Append Mode

A common pattern is appending to a log file that already exists.

```js
'use strict';

const fs = require('node:fs');

const logger = fs.createWriteStream('app.log', { flags: 'a' });

function log(level, message) {
  const timestamp = new Date().toISOString();
  logger.write(`[${timestamp}] [${level}] ${message}\n`);
}

log('INFO', 'Server starting');
log('INFO', 'Listening on port 3000');
log('WARN', 'Slow query detected: 2340ms');

// When done logging
// logger.end();
```

---

## The write() Method and Its Return Value

The `write()` method is deceptively simple. It takes data, an optional encoding, and an optional callback. But its return value is the most important signal in the entire stream API.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('output.dat');

// Signature: writable.write(chunk, encoding?, callback?)
const canContinue = writable.write('some data', 'utf8', (err) => {
  if (err) {
    console.error('Write failed:', err.message);
  } else {
    console.log('Chunk flushed');
  }
});

console.log(canContinue); // true or false
```

### What the Return Value Means

| Return value | Meaning |
|-------------|---------|
| `true`      | The internal buffer has room. Keep writing. |
| `false`     | The internal buffer has reached `highWaterMark`. Stop writing and wait for `'drain'`. |

This is the backpressure signal. When `write()` returns `false`, you are writing faster than the underlying resource can consume. If you ignore this and keep calling `write()`, the internal buffer grows without bound, eventually consuming all available memory.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('output.dat', {
  highWaterMark: 1024 // 1 KB buffer for demonstration
});

// Write 1 MB of data in tiny bursts
const oneMB = Buffer.alloc(1024, 'x');

for (let i = 0; i < 1024; i++) {
  const ok = writable.write(oneMB);
  if (!ok) {
    console.log(`Backpressure at iteration ${i}`);
    // In a real program, you MUST stop and wait for 'drain'
    // This loop does not, which is why it is a bad example
  }
}

writable.end();
```

---

## The 'drain' Event

When `write()` returns `false`, the `'drain'` event tells you it is safe to resume writing. The internal buffer has been flushed below `highWaterMark`.

### The Drain Protocol

1. Call `write()`
2. If it returns `false`, stop writing
3. Wait for the `'drain'` event
4. Resume writing

```js
'use strict';

const fs = require('node:fs');

function writeData(writable, data, callback) {
  let i = 0;

  function write() {
    let ok = true;

    while (i < data.length && ok) {
      const chunk = data[i];
      i++;

      if (i === data.length) {
        // Last chunk — pass callback to write
        writable.write(chunk, callback);
      } else {
        ok = writable.write(chunk);
      }
    }

    if (i < data.length) {
      // write() returned false — wait for drain
      writable.once('drain', write);
    }
  }

  write();
}

// Usage
const writable = fs.createWriteStream('output.txt');
const lines = Array.from({ length: 100000 }, (_, i) => `Line ${i + 1}\n`);

writeData(writable, lines, () => {
  console.log('All data written');
  writable.end();
});
```

### Promise-Based Drain

For async/await code, you can wrap the drain protocol in a promise.

```js
'use strict';

const fs = require('node:fs');

function drainableWrite(writable, chunk) {
  return new Promise((resolve, reject) => {
    const ok = writable.write(chunk);
    if (ok) {
      resolve();
    } else {
      writable.once('drain', resolve);
      writable.once('error', reject);
    }
  });
}

async function writeLines(path, count) {
  const writable = fs.createWriteStream(path);

  for (let i = 0; i < count; i++) {
    await drainableWrite(writable, `Line ${i + 1}\n`);
  }

  writable.end();

  return new Promise((resolve) => {
    writable.on('finish', resolve);
  });
}

writeLines('output.txt', 1000000)
  .then(() => console.log('Done'))
  .catch(console.error);
```

---

## end() — Signaling Completion

The `end()` method signals that no more data will be written. You can optionally pass a final chunk to write before closing.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('report.txt');

writable.write('Header\n');
writable.write('Body\n');

// Three valid signatures:
// writable.end()
// writable.end(finalChunk)
// writable.end(finalChunk, encoding, callback)

writable.end('Footer\n', 'utf8', () => {
  console.log('File written and closed');
});
```

### What Happens After end()

- No more `write()` calls are allowed (they will emit an `'error'` event)
- The stream flushes its internal buffer
- The `'finish'` event fires when all data has been flushed to the underlying resource
- The `'close'` event fires after the file descriptor is released

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('output.txt');

writable.write('data\n');
writable.end();

writable.on('finish', () => {
  console.log('1. All data flushed');
});

writable.on('close', () => {
  console.log('2. File descriptor closed');
});

// This will emit an error:
writable.write('too late\n');

writable.on('error', (err) => {
  console.error('3. Error:', err.message);
  // 'write after end'
});
```

---

## The 'finish' Event

The `'finish'` event fires when `end()` has been called **and** all data has been flushed to the underlying system. This is your confirmation that the write is complete.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('results.json');

const data = { users: 42, timestamp: Date.now() };

writable.write(JSON.stringify(data, null, 2));
writable.end('\n');

writable.on('finish', () => {
  // Safe to read the file now — all data is flushed
  const contents = fs.readFileSync('results.json', 'utf8');
  console.log('Written:', contents);
});
```

### finish vs close

| Event    | When it fires                                   |
|----------|--------------------------------------------------|
| `finish` | All data has been flushed to the underlying system |
| `close`  | The underlying resource (fd) has been released     |

`'finish'` fires first, then `'close'`. For file streams, both will fire on a clean shutdown. The distinction matters more for network streams where the connection might be severed before all data is acknowledged.

---

## cork() and uncork() — Batching Writes

Calling `cork()` tells the stream to buffer all writes in memory instead of flushing them individually. Calling `uncork()` flushes the entire batch at once. This reduces the number of system calls for many small writes.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('batch.txt');

// Without cork: each write() may trigger a separate fs.write() syscall
writable.write('Line 1\n');
writable.write('Line 2\n');
writable.write('Line 3\n');

// With cork: all writes are batched into a single fs.write() syscall
writable.cork();
writable.write('Line 4\n');
writable.write('Line 5\n');
writable.write('Line 6\n');
writable.uncork(); // Flush all three at once
```

### process.nextTick Uncork Pattern

A common pattern is to cork at the start of a synchronous code section and uncork on `process.nextTick()`. This batches all synchronous writes automatically.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('metrics.txt');

function writeMetrics(metrics) {
  writable.cork();

  for (const metric of metrics) {
    writable.write(`${metric.name}: ${metric.value}\n`);
  }

  // Uncork on the next tick — after all synchronous writes
  process.nextTick(() => writable.uncork());
}

writeMetrics([
  { name: 'cpu', value: 72.4 },
  { name: 'memory', value: 1024 },
  { name: 'requests', value: 5832 },
  { name: 'latency_p99', value: 42 }
]);
```

### Nested cork/uncork

Each `cork()` call increments an internal counter. You must call `uncork()` the same number of times to actually flush.

```js
'use strict';

const { Writable } = require('node:stream');

const writable = new Writable({
  write(chunk, encoding, callback) {
    console.log(`Flushed: ${chunk.toString().trim()}`);
    callback();
  }
});

writable.cork();
writable.cork(); // counter = 2
writable.write('Hello\n');
writable.uncork(); // counter = 1 — NOT flushed yet
writable.uncork(); // counter = 0 — NOW flushed

// Output: Flushed: Hello
```

---

## Error Handling

Always attach an `'error'` handler to Writable streams. Common error scenarios include disk full, permission denied, and broken pipes.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('/read-only/path.txt');

writable.on('error', (err) => {
  switch (err.code) {
    case 'EACCES':
      console.error('Permission denied');
      break;
    case 'ENOSPC':
      console.error('Disk full');
      break;
    case 'EPIPE':
      console.error('Broken pipe');
      break;
    default:
      console.error('Write error:', err.message);
  }
});

writable.write('This will fail\n');
```

### The write() Callback vs 'error' Event

The callback passed to `write()` receives an error if that specific chunk failed. The `'error'` event fires for any error on the stream. Both should be handled.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('output.txt');

writable.write('data\n', (err) => {
  if (err) {
    // This specific write failed
    console.error('Write callback error:', err.message);
  }
});

writable.on('error', (err) => {
  // Any error on the stream
  console.error('Stream error:', err.message);
});
```

---

## Destroying a Writable Stream

Call `destroy()` to immediately stop the stream and release its underlying resource. Unlike `end()`, `destroy()` does not flush buffered data.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('output.txt');

writable.write('This will be written\n');
writable.write('This might not be flushed\n');

// Destroy immediately — buffered data may be lost
writable.destroy();

writable.on('close', () => {
  console.log('Stream destroyed and fd closed');
});

// destroy() with an error
const writable2 = fs.createWriteStream('output2.txt');
writable2.destroy(new Error('Aborting'));

writable2.on('error', (err) => {
  console.error('Destroyed with:', err.message);
});
```

### end() vs destroy()

| Method      | Flushes buffer? | Emits 'finish'? | Emits 'close'? |
|-------------|-----------------|-----------------|-----------------|
| `end()`     | Yes             | Yes             | Yes             |
| `destroy()` | No              | No              | Yes             |

Use `end()` for graceful shutdown. Use `destroy()` when you need to abort immediately and do not care about buffered data.

---

## Practical Example: CSV Writer

Here is a complete example that writes CSV data to a file, respecting backpressure.

```js
'use strict';

const fs = require('node:fs');

class CSVWriter {
  constructor(filePath, headers) {
    this.writable = fs.createWriteStream(filePath);
    this.headers = headers;

    // Write header row
    this.writable.write(headers.join(',') + '\n');
  }

  async writeRow(values) {
    const escaped = values.map((v) => {
      const str = String(v);
      // Escape commas and quotes in CSV
      if (str.includes(',') || str.includes('"') || str.includes('\n')) {
        return `"${str.replace(/"/g, '""')}"`;
      }
      return str;
    });

    const line = escaped.join(',') + '\n';

    return new Promise((resolve, reject) => {
      const ok = this.writable.write(line);
      if (ok) {
        resolve();
      } else {
        this.writable.once('drain', resolve);
        this.writable.once('error', reject);
      }
    });
  }

  async close() {
    return new Promise((resolve, reject) => {
      this.writable.end();
      this.writable.on('finish', resolve);
      this.writable.on('error', reject);
    });
  }
}

// Usage
async function main() {
  const csv = new CSVWriter('users.csv', ['id', 'name', 'email']);

  for (let i = 1; i <= 100000; i++) {
    await csv.writeRow([i, `User ${i}`, `user${i}@example.com`]);
  }

  await csv.close();
  console.log('CSV written with 100,000 rows');
}

main().catch(console.error);
```

This example demonstrates every concept from this lesson: creating a Writable, checking the return value of `write()`, waiting for `'drain'`, calling `end()`, and listening for `'finish'`.

---

## Key Takeaways

- The boolean return value of `write()` is a backpressure signal: `false` means "stop writing and wait for `'drain'`"
- Always call `end()` when you are done writing — it flushes the buffer and triggers the `'finish'` event
- `cork()` and `uncork()` batch multiple small writes into a single system call, reducing overhead
- Use `destroy()` for immediate abort; use `end()` for graceful shutdown with full data flush
- Every Writable stream needs an `'error'` handler to prevent uncaught exceptions

## Next

In Lesson 04, we zoom into the mechanics of backpressure — why it exists, what happens when you ignore it, and how the `write()`/`'drain'` protocol keeps memory usage bounded under any load.
