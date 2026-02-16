# Module 05 / Lesson 04 — Backpressure Mechanics

> Backpressure is the immune system of your stream pipeline. Without it, a fast producer overwhelms a slow consumer, memory balloons, and your process dies with a heap out-of-memory crash. Understanding backpressure mechanics is what separates stream code that works in demos from stream code that survives in production.

## Learning Objectives

- Explain why backpressure is necessary in producer-consumer pipelines
- Trace the signal path from `write()` returning `false` through the `'drain'` event
- Demonstrate what happens when backpressure is ignored (memory blowup)
- Implement correct backpressure handling in manual and piped scenarios
- Identify common backpressure bugs and how to diagnose them

---

## Why Backpressure Exists

Every stream pipeline has a producer (source) and a consumer (destination). In the real world, these two sides almost never operate at the same speed.

- Reading from an SSD: ~500 MB/s
- Writing over a network socket: ~10 MB/s
- Writing to a slow external API: ~1 MB/s

Without backpressure, the fast producer generates data far faster than the slow consumer can process it. Where does the excess data go? Into the internal buffer. And when the buffer has no limit, it grows until Node.js runs out of heap memory.

```
Producer (500 MB/s) ──→ [Buffer grows endlessly] ──→ Consumer (10 MB/s)
                          ↑
                    OOM crash incoming
```

Backpressure is the mechanism that tells the producer: "Slow down. The consumer cannot keep up." It propagates upstream through return values and events.

```
Producer (throttled) ──→ [Buffer ≤ highWaterMark] ──→ Consumer (10 MB/s)
                          ↑
                    Memory stays bounded
```

---

## The Signal Path

Here is exactly how backpressure propagates through a stream pipeline, step by step.

### Step 1: write() Returns false

When you call `write()` on a Writable stream, Node.js adds the chunk to the internal buffer. If the buffer size exceeds `highWaterMark`, `write()` returns `false`.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('output.dat', {
  highWaterMark: 1024 // 1 KB
});

// Write a 2 KB chunk — exceeds the 1 KB highWaterMark
const result = writable.write(Buffer.alloc(2048, 0x41));
console.log(result); // false — buffer is over the watermark
```

### Step 2: The Producer Pauses

When the producer receives `false` from `write()`, it must stop producing data and wait.

```js
'use strict';

const { Readable, Writable } = require('node:stream');

const producer = new Readable({
  read(size) {
    // Generate data on demand
    this.push(Buffer.alloc(size, 0x42));
  }
});

const consumer = new Writable({
  highWaterMark: 1024,
  write(chunk, encoding, callback) {
    // Simulate slow consumer: 100ms per chunk
    setTimeout(callback, 100);
  }
});

// pipe() handles backpressure automatically
producer.pipe(consumer);
```

When you use `pipe()`, the Readable automatically pauses when the Writable's buffer is full and resumes when it drains. You get backpressure for free.

### Step 3: The Buffer Drains

While the producer is paused, the consumer continues processing buffered chunks. As it calls `callback()` for each chunk, the internal buffer shrinks.

### Step 4: 'drain' Fires

When the internal buffer empties completely (drops to zero), the Writable emits a `'drain'` event. This tells the producer: "I have room again. Resume sending."

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('output.dat', {
  highWaterMark: 1024
});

writable.write(Buffer.alloc(2048)); // returns false

writable.on('drain', () => {
  console.log('Buffer drained — safe to write again');
  console.log('Buffer size:', writable.writableLength); // 0
});
```

### The Complete Cycle

```
write(chunk)
  ├─ returns true  → keep writing
  └─ returns false → STOP
                      │
                      ├─ consumer processes buffered data
                      │
                      └─ buffer empties → 'drain' fires → RESUME writing
```

---

## What Happens Without Backpressure

Let us see the failure mode. This is the single most common stream bug in Node.js applications.

### The Memory Blowup Demo

```js
'use strict';

const { Writable } = require('node:stream');

// A slow consumer that takes 10ms per chunk
const slowConsumer = new Writable({
  highWaterMark: 16384, // 16 KB
  write(chunk, encoding, callback) {
    // Simulate slow I/O (database write, network call, etc.)
    setTimeout(callback, 10);
  }
});

// BAD: Ignoring backpressure
let bytesWritten = 0;
const chunk = Buffer.alloc(65536, 0x41); // 64 KB chunks

function pourDataIgnoringBackpressure() {
  // This loop writes as fast as possible without checking write()'s return value
  for (let i = 0; i < 100000; i++) {
    slowConsumer.write(chunk); // Return value ignored!
    bytesWritten += chunk.length;
  }
  console.log(`Wrote ${(bytesWritten / 1024 / 1024).toFixed(0)} MB`);
}

// Monitor memory usage
const interval = setInterval(() => {
  const used = process.memoryUsage();
  console.log(
    `RSS: ${(used.rss / 1024 / 1024).toFixed(0)} MB, ` +
    `Heap: ${(used.heapUsed / 1024 / 1024).toFixed(0)} MB, ` +
    `Buffered: ${(slowConsumer.writableLength / 1024 / 1024).toFixed(0)} MB`
  );
}, 1000);

slowConsumer.on('finish', () => {
  clearInterval(interval);
  console.log('Done');
});

pourDataIgnoringBackpressure();
slowConsumer.end();
```

Running this will show memory climbing rapidly. The internal buffer grows to gigabytes because the producer never pauses. In production, this kills the process.

### The Fix: Respect the Signal

```js
'use strict';

const { Writable } = require('node:stream');

const slowConsumer = new Writable({
  highWaterMark: 16384,
  write(chunk, encoding, callback) {
    setTimeout(callback, 10);
  }
});

const chunk = Buffer.alloc(65536, 0x41);
let bytesWritten = 0;
let i = 0;
const total = 100000;

function writeWithBackpressure() {
  let ok = true;

  while (i < total && ok) {
    i++;
    bytesWritten += chunk.length;

    if (i === total) {
      slowConsumer.write(chunk, () => {
        console.log(`Wrote ${(bytesWritten / 1024 / 1024).toFixed(0)} MB`);
        slowConsumer.end();
      });
    } else {
      ok = slowConsumer.write(chunk);
    }
  }

  if (i < total) {
    // Backpressure: wait for drain before continuing
    slowConsumer.once('drain', writeWithBackpressure);
  }
}

// Monitor memory — it stays bounded now
const interval = setInterval(() => {
  const used = process.memoryUsage();
  console.log(
    `RSS: ${(used.rss / 1024 / 1024).toFixed(0)} MB, ` +
    `Buffered: ${(slowConsumer.writableLength / 1024).toFixed(0)} KB`
  );
}, 1000);

slowConsumer.on('finish', () => {
  clearInterval(interval);
  console.log('Complete');
});

writeWithBackpressure();
```

The memory stays bounded because the producer pauses whenever the buffer exceeds `highWaterMark` and only resumes when it drains.

---

## Backpressure in pipe()

When you use `pipe()`, backpressure is handled automatically. Here is what `pipe()` does internally (simplified):

```js
'use strict';

const { Readable, Writable } = require('node:stream');

// This is conceptually what pipe() does
function manualPipe(readable, writable) {
  readable.on('data', (chunk) => {
    const ok = writable.write(chunk);
    if (!ok) {
      // Writable buffer full — pause the readable
      readable.pause();
    }
  });

  writable.on('drain', () => {
    // Writable buffer drained — resume the readable
    readable.resume();
  });

  readable.on('end', () => {
    writable.end();
  });

  readable.on('error', (err) => {
    console.error('Read error:', err.message);
    writable.destroy(err);
  });

  // Note: pipe() does NOT handle writable errors!
  // This is one reason to prefer pipeline() — see Lesson 06
}
```

The key insight: `pipe()` calls `readable.pause()` when `write()` returns `false` and `readable.resume()` when `'drain'` fires. This creates the feedback loop that keeps memory bounded.

### Demonstrating pipe() Backpressure

```js
'use strict';

const fs = require('node:fs');
const { Transform } = require('node:stream');

// A slow transform that delays each chunk by 50ms
const slowTransform = new Transform({
  transform(chunk, encoding, callback) {
    setTimeout(() => {
      this.push(chunk);
      callback();
    }, 50);
  }
});

const readable = fs.createReadStream('large-file.dat');
const writable = fs.createWriteStream('copy.dat');

// pipe() automatically handles backpressure through the entire chain
readable.pipe(slowTransform).pipe(writable);

writable.on('finish', () => {
  console.log('Copy complete');
});
```

Even though the transform is slow, the file stream pauses when the transform's buffer is full. Memory stays flat.

---

## Backpressure with Async/Await

Modern code often uses async/await. Here is the clean pattern for writing with backpressure in an async context.

```js
'use strict';

const fs = require('node:fs');

function write(writable, chunk) {
  return new Promise((resolve, reject) => {
    if (writable.destroyed) {
      reject(new Error('Stream was destroyed'));
      return;
    }

    const ok = writable.write(chunk, (err) => {
      if (err) reject(err);
    });

    if (ok) {
      resolve();
    } else {
      writable.once('drain', resolve);
    }
  });
}

async function generateReport(outputPath) {
  const writable = fs.createWriteStream(outputPath);

  writable.on('error', (err) => {
    console.error('Stream error:', err.message);
  });

  for (let i = 0; i < 1000000; i++) {
    const line = `${i},${Math.random()},${Date.now()}\n`;
    await write(writable, line);
  }

  writable.end();

  await new Promise((resolve) => {
    writable.on('finish', resolve);
  });

  console.log('Report written');
}

generateReport('report.csv').catch(console.error);
```

Each `await write()` will resolve immediately when there is buffer room and pause until `'drain'` when the buffer is full. Memory stays bounded throughout.

---

## Diagnosing Backpressure Problems

### Symptom: RSS Grows Unbounded

If your process memory keeps climbing during a long-running stream operation, you likely have a backpressure leak.

```js
'use strict';

// Diagnostic: Monitor writable buffer size
const fs = require('node:fs');

const writable = fs.createWriteStream('output.dat');

const monitor = setInterval(() => {
  console.log({
    writableLength: writable.writableLength,        // Current buffer size
    writableHighWaterMark: writable.writableHighWaterMark, // The limit
    writableCorked: writable.writableCorked,         // Is it corked?
    writableFinished: writable.writableFinished,     // Has finish been emitted?
    rss: (process.memoryUsage().rss / 1024 / 1024).toFixed(0) + ' MB'
  });
}, 1000);

writable.on('finish', () => clearInterval(monitor));
```

### Symptom: 'drain' Never Fires

If the consumer's `_write` method never calls its `callback`, the buffer never drains. This is a deadlock.

```js
'use strict';

const { Writable } = require('node:stream');

// BUG: callback is never called
const buggy = new Writable({
  write(chunk, encoding, callback) {
    // Forgot to call callback()!
    console.log('Got chunk');
    // callback(); ← Missing!
  }
});

buggy.write('data');
// 'drain' will never fire
// The buffer will grow forever
```

### Symptom: Chunks Are Lost

If you destroy a Writable stream without calling `end()`, buffered data is lost silently.

```js
'use strict';

const fs = require('node:fs');

const writable = fs.createWriteStream('important.dat');

writable.write('Critical data\n');

// BAD: destroy loses buffered data
// writable.destroy();

// GOOD: end() flushes first
writable.end();
```

---

## Common Backpressure Mistakes

### Mistake 1: Wrapping Streams in Promises Without Drain

```js
'use strict';

const fs = require('node:fs');

// BAD: Does not handle backpressure
async function badWrite(path, lines) {
  const writable = fs.createWriteStream(path);

  for (const line of lines) {
    writable.write(line + '\n'); // Ignoring return value!
  }

  writable.end();
}

// GOOD: Awaits drain when needed
async function goodWrite(path, lines) {
  const writable = fs.createWriteStream(path);

  for (const line of lines) {
    const ok = writable.write(line + '\n');
    if (!ok) {
      await new Promise((resolve) => writable.once('drain', resolve));
    }
  }

  writable.end();
  await new Promise((resolve) => writable.on('finish', resolve));
}
```

### Mistake 2: Using 'data' Without Backpressure on the Consumer Side

```js
'use strict';

const fs = require('node:fs');

// BAD: 'data' flows at full speed, but consumer is slow
const readable = fs.createReadStream('huge.log');
const writable = fs.createWriteStream('copy.log');

readable.on('data', (chunk) => {
  writable.write(chunk); // No backpressure check!
});

// GOOD: Use pipe() or pipeline()
// readable.pipe(writable);
```

### Mistake 3: Multiple pipe() Destinations Without Backpressure Coordination

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.txt');
const dest1 = fs.createWriteStream('copy1.txt');
const dest2 = fs.createWriteStream('copy2.txt');

// pipe() to multiple destinations
readable.pipe(dest1);
readable.pipe(dest2);

// This works, but backpressure is applied based on the SLOWEST destination.
// pipe() handles this correctly — the readable will pause when
// EITHER destination's buffer is full.
```

---

## Visualizing Buffer Levels

Here is a utility to log buffer levels during a pipeline operation.

```js
'use strict';

const fs = require('node:fs');
const { Transform } = require('node:stream');

function createMonitoredPipeline(inputPath, outputPath) {
  const readable = fs.createReadStream(inputPath);
  const writable = fs.createWriteStream(outputPath, {
    highWaterMark: 16 * 1024
  });

  const slow = new Transform({
    highWaterMark: 8 * 1024,
    transform(chunk, encoding, callback) {
      // Simulate slow processing
      setTimeout(() => {
        this.push(chunk);
        callback();
      }, 20);
    }
  });

  const interval = setInterval(() => {
    const readBuf = readable.readableLength || 0;
    const transformBuf = slow.readableLength + slow.writableLength;
    const writeBuf = writable.writableLength;

    const bar = (n, max) => {
      const filled = Math.round((n / max) * 20);
      return '[' + '#'.repeat(filled) + '.'.repeat(20 - filled) + ']';
    };

    console.log(
      `Read ${bar(readBuf, 65536)} ${readBuf}B | ` +
      `Transform ${bar(transformBuf, 16384)} ${transformBuf}B | ` +
      `Write ${bar(writeBuf, 16384)} ${writeBuf}B`
    );
  }, 200);

  readable.pipe(slow).pipe(writable);

  writable.on('finish', () => {
    clearInterval(interval);
    console.log('Pipeline complete');
  });
}

createMonitoredPipeline('input.dat', 'output.dat');
```

Running this against a large file shows the buffer levels fluctuating as backpressure pulses through the pipeline. You will see the read buffer fill, the transform buffer fill, backpressure pause the reader, the buffers drain, and the cycle repeat.

---

## The Backpressure Contract

To summarize the contract every stream participant must uphold:

**Producers must:**
1. Check the return value of `write()`
2. Stop producing when `write()` returns `false`
3. Resume producing only when `'drain'` fires

**Consumers must:**
1. Call the `callback` in `_write()` when the chunk has been processed
2. Call it promptly — delaying it delays the entire pipeline
3. Call it with an error if processing fails

**Pipelines must:**
1. Propagate errors through the entire chain
2. Clean up all streams when any stream fails
3. Use `pipeline()` (Lesson 06) instead of `pipe()` for proper error propagation

---

## Key Takeaways

- Backpressure prevents memory blowup by signaling the producer to slow down when the consumer cannot keep up
- The `write()` return value (`false`) and the `'drain'` event form the core backpressure protocol
- Ignoring backpressure leads to unbounded buffer growth and eventual OOM crashes
- `pipe()` handles backpressure automatically by pausing/resuming the Readable based on the Writable's buffer state
- In async/await code, always `await` a drain promise when `write()` returns `false`

## Next

In Lesson 05, we explore Duplex and Transform streams — the two-way and data-transforming members of the stream family — including `net.Socket`, zlib compression, and building your own custom Transform.
