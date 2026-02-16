# Module 05 / Lesson 08 — Stream Performance Patterns

> Streams exist because loading an entire file into memory is wasteful. But using streams badly — wrong `highWaterMark`, leaked listeners, unbounded buffers — can be worse than no streams at all. This lesson is about measuring, tuning, and avoiding the performance pitfalls that turn streaming pipelines from efficient data processors into memory-leaking, CPU-spinning liabilities.

## Learning Objectives

- Tune `highWaterMark` based on workload and measure the performance impact of different values
- Use `stream.compose()` to build reusable, composable stream segments
- Identify and fix common memory leak patterns in stream-based code
- Benchmark `pipe()`, `pipeline()`, manual read/write loops, and async iteration to choose the right approach
- Know when NOT to use streams — the overhead threshold below which simpler code wins

---

## Measuring Stream Performance

Before you tune anything, you need to measure. The three metrics that matter for streams are throughput (MB/s), memory usage (RSS and heap), and latency (time to first byte, time to completion).

```javascript
'use strict';

const fs = require('node:fs');
const { pipeline } = require('node:stream/promises');

async function measurePipeline(label, fn) {
  // Force garbage collection if available (run with --expose-gc)
  if (global.gc) global.gc();

  const memBefore = process.memoryUsage();
  const start = process.hrtime.bigint();

  await fn();

  const elapsed = Number(process.hrtime.bigint() - start) / 1e6; // ms
  const memAfter = process.memoryUsage();

  const heapDelta = (memAfter.heapUsed - memBefore.heapUsed) / 1024 / 1024;
  const rssDelta = (memAfter.rss - memBefore.rss) / 1024 / 1024;

  console.log(`\n--- ${label} ---`);
  console.log(`Time:       ${elapsed.toFixed(1)} ms`);
  console.log(`Heap delta: ${heapDelta.toFixed(2)} MB`);
  console.log(`RSS delta:  ${rssDelta.toFixed(2)} MB`);
  console.log(`RSS total:  ${(memAfter.rss / 1024 / 1024).toFixed(1)} MB`);
}

// Example: measure a file copy
// measurePipeline('File copy', async () => {
//   await pipeline(
//     fs.createReadStream('/tmp/large-file.dat'),
//     fs.createWriteStream('/tmp/copy.dat')
//   );
// });
```

### Measuring Throughput

```javascript
'use strict';

const fs = require('node:fs');
const { Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');

function createThroughputMeter(label) {
  let totalBytes = 0;
  const start = process.hrtime.bigint();

  return new Transform({
    transform(chunk, encoding, callback) {
      totalBytes += chunk.length;
      callback(null, chunk);
    },
    flush(callback) {
      const elapsed = Number(process.hrtime.bigint() - start) / 1e9; // seconds
      const mbPerSec = (totalBytes / 1024 / 1024) / elapsed;
      console.log(`[${label}] ${(totalBytes / 1024 / 1024).toFixed(1)} MB in ${elapsed.toFixed(2)}s = ${mbPerSec.toFixed(1)} MB/s`);
      callback();
    },
  });
}

// Usage in a pipeline
// await pipeline(
//   fs.createReadStream('/tmp/data.bin'),
//   createThroughputMeter('read'),
//   fs.createWriteStream('/dev/null')
// );
```

---

## `highWaterMark` Tuning

The `highWaterMark` controls how much data a stream buffers internally before applying backpressure. The default is 16 KB for Buffer-mode streams and 16 objects for object-mode streams.

### Default Values

| Stream Type            | Default `highWaterMark` |
|------------------------|------------------------|
| Readable (Buffer mode) | 16,384 bytes (16 KB)   |
| Writable (Buffer mode) | 16,384 bytes (16 KB)   |
| Object mode            | 16 objects             |
| `fs.createReadStream`  | 65,536 bytes (64 KB)   |

### When to Increase `highWaterMark`

- **Large file transfers**: 64-256 KB reduces the number of read/write system calls
- **Network I/O**: Higher buffers smooth out network jitter
- **High-throughput pipelines**: Fewer backpressure cycles means less overhead

### When to Decrease `highWaterMark`

- **Memory-constrained environments**: Lower buffers use less memory per stream
- **Many concurrent streams**: 1,000 streams at 256 KB = 256 MB of buffers alone
- **Low-latency requirements**: Smaller buffers reduce time-to-first-byte

```javascript
'use strict';

const fs = require('node:fs');
const { pipeline } = require('node:stream/promises');

async function copyWithHWM(input, output, highWaterMark) {
  const start = process.hrtime.bigint();

  await pipeline(
    fs.createReadStream(input, { highWaterMark }),
    fs.createWriteStream(output, { highWaterMark })
  );

  const elapsed = Number(process.hrtime.bigint() - start) / 1e6;
  const stats = fs.statSync(input);
  const mbPerSec = (stats.size / 1024 / 1024) / (elapsed / 1000);

  console.log(`HWM ${String(highWaterMark).padStart(8)}: ${elapsed.toFixed(0)}ms (${mbPerSec.toFixed(1)} MB/s)`);
}

// Benchmark different highWaterMark values
async function benchmark(inputFile) {
  const values = [1024, 4096, 16384, 65536, 262144, 1048576];

  for (const hwm of values) {
    await copyWithHWM(inputFile, '/dev/null', hwm);
  }
}

// benchmark('/tmp/test-100mb.dat').catch(console.error);
```

### Typical Results (100 MB file)

```
HWM     1024: 420ms (238.1 MB/s)
HWM     4096: 190ms (526.3 MB/s)
HWM    16384: 110ms (909.1 MB/s)
HWM    65536:  85ms (1176.5 MB/s)
HWM   262144:  72ms (1388.9 MB/s)
HWM  1048576:  70ms (1428.6 MB/s)
```

The sweet spot is usually 64-256 KB for file I/O. Beyond 1 MB, the gains diminish while memory usage increases linearly with concurrency.

---

## `stream.compose()` — Composable Stream Segments

`stream.compose()` (Node 18+) combines multiple streams or functions into a single Duplex stream that can be reused as a pipeline segment.

```javascript
'use strict';

const { compose, Transform } = require('node:stream');
const { createGzip } = require('node:zlib');
const fs = require('node:fs');
const { pipeline } = require('node:stream/promises');

// Create a reusable compression-with-progress segment
function createCompressor(label) {
  let bytes = 0;

  const meter = new Transform({
    transform(chunk, encoding, callback) {
      bytes += chunk.length;
      callback(null, chunk);
    },
    flush(callback) {
      console.log(`[${label}] Compressed ${(bytes / 1024).toFixed(1)} KB`);
      callback();
    },
  });

  // compose() returns a single Duplex stream
  return compose(meter, createGzip());
}

// Use the composed stream like any single stream
async function compressFile(input, output) {
  await pipeline(
    fs.createReadStream(input),
    createCompressor('gzip'),
    fs.createWriteStream(output)
  );
}

// compressFile('/tmp/data.json', '/tmp/data.json.gz').catch(console.error);
```

### Composing Async Generators

```javascript
'use strict';

const { compose } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const fs = require('node:fs');

async function* splitLines(source) {
  let buffer = '';
  for await (const chunk of source) {
    buffer += chunk;
    const lines = buffer.split('\n');
    buffer = lines.pop();
    for (const line of lines) {
      yield line;
    }
  }
  if (buffer.length > 0) yield buffer;
}

async function* filterNonEmpty(source) {
  for await (const line of source) {
    if (line.trim().length > 0) {
      yield line;
    }
  }
}

async function* addLineNumbers(source) {
  let num = 0;
  for await (const line of source) {
    num++;
    yield `${String(num).padStart(5)} | ${line}\n`;
  }
}

// Compose multiple generators into a single reusable stream
const numberedLines = compose(splitLines, filterNonEmpty, addLineNumbers);

// Use it in a pipeline
// pipeline(
//   fs.createReadStream('input.txt', 'utf8'),
//   numberedLines,
//   fs.createWriteStream('output.txt')
// ).catch(console.error);
```

---

## Async Generators as Streams

Async generators offer a lightweight alternative to custom Transform classes. Combined with `Readable.from()` or `pipeline()`, they provide full streaming with backpressure.

```javascript
'use strict';

const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const fs = require('node:fs');

async function* chunkify(source, chunkSize) {
  let buffer = Buffer.alloc(0);

  for await (const chunk of source) {
    buffer = Buffer.concat([buffer, chunk]);

    while (buffer.length >= chunkSize) {
      yield buffer.subarray(0, chunkSize);
      buffer = buffer.subarray(chunkSize);
    }
  }

  if (buffer.length > 0) {
    yield buffer;
  }
}

// Re-chunk a stream into fixed-size pieces
async function rechunk(inputPath, outputPath, size) {
  await pipeline(
    fs.createReadStream(inputPath),
    (source) => chunkify(source, size),
    fs.createWriteStream(outputPath)
  );
  console.log(`Re-chunked into ${size}-byte pieces`);
}

// rechunk('/tmp/data.bin', '/tmp/rechunked.bin', 4096).catch(console.error);
```

### Performance: Generators vs Transform Classes

Generators have slightly more overhead per chunk than native Transform streams due to the async iteration protocol. For most workloads, the difference is negligible. For ultra-high-throughput byte processing (>1 GB/s), prefer Transform classes.

```javascript
'use strict';

const { Transform, Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');

// Transform class — faster for raw byte throughput
const upperTransform = new Transform({
  transform(chunk, encoding, callback) {
    callback(null, chunk.toString().toUpperCase());
  },
});

// Generator — more readable, slightly slower
async function* upperGenerator(source) {
  for await (const chunk of source) {
    yield chunk.toString().toUpperCase();
  }
}

// Both produce the same result. Choose based on:
// - Generator: cleaner code, easier testing, moderate throughput
// - Transform: maximum throughput, complex state management, _writev batching
```

---

## `pipeline()` with `AbortSignal` — Cancellation

Cancellation is a performance feature: stopping work you no longer need prevents wasted CPU, memory, and I/O.

```javascript
'use strict';

const fs = require('node:fs');
const { pipeline } = require('node:stream/promises');
const { createGzip } = require('node:zlib');

async function compressWithLimit(input, output, maxBytes) {
  const ac = new AbortController();
  let processed = 0;

  async function* limiter(source) {
    for await (const chunk of source) {
      processed += chunk.length;
      if (processed > maxBytes) {
        ac.abort();
        return;
      }
      yield chunk;
    }
  }

  try {
    await pipeline(
      fs.createReadStream(input),
      limiter,
      createGzip(),
      fs.createWriteStream(output),
      { signal: ac.signal }
    );
    console.log(`Compressed ${processed} bytes`);
  } catch (err) {
    if (err.name === 'AbortError') {
      console.log(`Stopped after ${processed} bytes (limit: ${maxBytes})`);
      // Clean up partial file
      try { fs.unlinkSync(output); } catch {}
    } else {
      throw err;
    }
  }
}

// compressWithLimit('/tmp/huge.dat', '/tmp/partial.gz', 10 * 1024 * 1024).catch(console.error);
```

---

## Memory Leak Patterns

### Leak 1: Unbounded Internal Buffers

When a Transform accumulates data without flushing, memory grows without bound.

```javascript
'use strict';

const { Transform } = require('node:stream');

// BAD — accumulates all data in memory, defeating the purpose of streams
class BadAccumulator extends Transform {
  constructor() {
    super();
    this.chunks = []; // Grows forever
  }

  _transform(chunk, encoding, callback) {
    this.chunks.push(chunk); // Never released
    callback(); // No output until _flush
  }

  _flush(callback) {
    const all = Buffer.concat(this.chunks);
    callback(null, all);
  }
}

// GOOD — process data incrementally
class GoodProcessor extends Transform {
  _transform(chunk, encoding, callback) {
    // Process and emit immediately — constant memory
    const processed = chunk.toString().toUpperCase();
    callback(null, processed);
  }
}
```

### Leak 2: Listener Accumulation

Adding event listeners inside loops without removing them causes the listener array to grow.

```javascript
'use strict';

const { Readable } = require('node:stream');

// BAD — adds a new 'data' listener on every tick
function badPattern(stream) {
  setInterval(() => {
    stream.on('data', (chunk) => {
      // This listener is NEVER removed
      // After 1000 ticks, there are 1000 listeners
    });
  }, 100);
}

// GOOD — add listener once, or use { once: true }
function goodPattern(stream) {
  stream.on('data', (chunk) => {
    // Single listener handles all events
  });
}
```

### Leak 3: Unclosed Streams

Streams that are never closed hold onto their internal buffers and OS resources.

```javascript
'use strict';

const fs = require('node:fs');

// BAD — stream is never closed if processing throws
function badRead(filePath) {
  const stream = fs.createReadStream(filePath);
  stream.on('data', (chunk) => {
    if (chunk.toString().includes('ERROR')) {
      throw new Error('Found error'); // Stream stays open!
    }
  });
}

// GOOD — always destroy on error
function goodRead(filePath) {
  const stream = fs.createReadStream(filePath);
  stream.on('data', (chunk) => {
    if (chunk.toString().includes('ERROR')) {
      stream.destroy(); // Clean up
      console.error('Found error — stream closed');
    }
  });
  stream.on('error', (err) => {
    console.error('Stream error:', err.message);
  });
}
```

### Detecting Leaks: The `maxListeners` Warning

Node.js warns when you add more than 10 listeners to a single event. This is almost always a bug.

```
(node:12345) MaxListenersExceededWarning: Possible EventEmitter memory leak detected.
11 'data' listeners added to [ReadStream].
Use emitter.setMaxListeners() to increase limit.
```

Never silence this warning with `setMaxListeners(0)`. Fix the root cause instead.

---

## Benchmarking: Comparing Stream Approaches

A head-to-head comparison of four approaches to process a file.

```javascript
'use strict';

const fs = require('node:fs');
const fsPromises = require('node:fs/promises');
const { pipeline } = require('node:stream/promises');
const { Transform } = require('node:stream');

// Approach 1: readFile (no streams)
async function approach1_readFile(input) {
  const data = await fsPromises.readFile(input);
  return data.toString().toUpperCase();
}

// Approach 2: pipe()
function approach2_pipe(input) {
  return new Promise((resolve, reject) => {
    const upper = new Transform({
      transform(chunk, enc, cb) {
        cb(null, chunk.toString().toUpperCase());
      },
    });

    const chunks = [];
    fs.createReadStream(input)
      .pipe(upper)
      .on('data', (chunk) => chunks.push(chunk))
      .on('end', () => resolve(Buffer.concat(chunks).toString()))
      .on('error', reject);
  });
}

// Approach 3: pipeline()
async function approach3_pipeline(input) {
  const chunks = [];

  await pipeline(
    fs.createReadStream(input),
    async function* (source) {
      for await (const chunk of source) {
        yield chunk.toString().toUpperCase();
      }
    },
    async function* (source) {
      for await (const chunk of source) {
        chunks.push(chunk);
      }
    }
  );

  return chunks.join('');
}

// Approach 4: async iteration (manual)
async function approach4_asyncIteration(input) {
  const stream = fs.createReadStream(input, { encoding: 'utf8' });
  let result = '';

  for await (const chunk of stream) {
    result += chunk.toUpperCase();
  }

  return result;
}

// Benchmark runner
async function runBenchmark(inputFile, iterations = 5) {
  const approaches = [
    { name: 'readFile', fn: approach1_readFile },
    { name: 'pipe()', fn: approach2_pipe },
    { name: 'pipeline()', fn: approach3_pipeline },
    { name: 'async iteration', fn: approach4_asyncIteration },
  ];

  for (const { name, fn } of approaches) {
    const times = [];

    for (let i = 0; i < iterations; i++) {
      const start = process.hrtime.bigint();
      await fn(inputFile);
      const elapsed = Number(process.hrtime.bigint() - start) / 1e6;
      times.push(elapsed);
    }

    const avg = times.reduce((a, b) => a + b) / times.length;
    const min = Math.min(...times);
    const max = Math.max(...times);

    console.log(`${name.padEnd(18)} avg: ${avg.toFixed(1)}ms  min: ${min.toFixed(1)}ms  max: ${max.toFixed(1)}ms`);
  }
}

// runBenchmark('/tmp/test-file.txt').catch(console.error);
```

### Typical Results (1 MB text file, 5 iterations)

```
readFile           avg:  4.2ms  min:  3.8ms  max:  5.1ms
pipe()             avg:  6.1ms  min:  5.5ms  max:  7.2ms
pipeline()         avg:  6.4ms  min:  5.9ms  max:  7.0ms
async iteration    avg:  5.8ms  min:  5.2ms  max:  6.5ms
```

For small files, `readFile` wins. Streams add overhead (buffer management, event emission, backpressure checks). The crossover point where streams become faster is typically around 50-100 MB, where `readFile` would consume too much memory.

---

## The `autoDestroy` Option

By default (`autoDestroy: true` since Node 14), streams automatically destroy themselves after `_read` pushes `null` or after `_final` completes. If you set `autoDestroy: false`, you must call `.destroy()` manually.

```javascript
'use strict';

const { Readable } = require('node:stream');

// Default: autoDestroy is true — stream is destroyed after push(null)
const autoStream = new Readable({
  read() {
    this.push('data\n');
    this.push(null);
    // Stream will be automatically destroyed after 'end' event
  },
});

autoStream.on('close', () => console.log('Auto: closed'));

// Manual: autoDestroy is false — you control when it's destroyed
const manualStream = new Readable({
  autoDestroy: false,
  read() {
    this.push('data\n');
    this.push(null);
    // Stream will NOT be automatically destroyed
  },
});

manualStream.on('end', () => {
  console.log('Manual: ended, but NOT closed yet');
  // You must destroy it yourself
  manualStream.destroy();
});

manualStream.on('close', () => console.log('Manual: now closed'));
```

---

## When NOT to Use Streams

Streams add complexity. They are worth it for large or continuous data, but they are overkill for small or one-shot operations.

### The Decision Framework

| File Size   | Concurrent Operations | Recommendation             |
|-------------|-----------------------|---------------------------|
| < 1 MB      | Any                   | `readFile` / `writeFile`  |
| 1-50 MB     | < 10                  | `readFile` is usually fine |
| 1-50 MB     | > 10 concurrent       | Streams (memory pressure)  |
| 50+ MB      | Any                   | Always streams             |
| Continuous   | N/A                  | Always streams             |

### Cases Where Streams Hurt

```javascript
'use strict';

const fs = require('node:fs');
const fsPromises = require('node:fs/promises');
const { pipeline } = require('node:stream/promises');

// OVERENGINEERED — streams for a 200-byte config file
async function overengineered() {
  const chunks = [];
  await pipeline(
    fs.createReadStream('config.json'),
    async function* (source) {
      for await (const chunk of source) {
        chunks.push(chunk);
      }
    }
  );
  return JSON.parse(Buffer.concat(chunks).toString());
}

// SIMPLE AND CORRECT — just read the file
async function simple() {
  const raw = await fsPromises.readFile('config.json', 'utf8');
  return JSON.parse(raw);
}
```

```javascript
'use strict';

// OVERENGINEERED — streaming a small string transformation
const { Transform } = require('node:stream');

function overengineeredUppercase(str) {
  return new Promise((resolve, reject) => {
    let result = '';
    const upper = new Transform({
      transform(chunk, enc, cb) { cb(null, chunk.toString().toUpperCase()); },
    });
    upper.on('data', (chunk) => { result += chunk; });
    upper.on('end', () => resolve(result));
    upper.on('error', reject);
    upper.end(str);
  });
}

// SIMPLE AND CORRECT
function simpleUppercase(str) {
  return str.toUpperCase();
}
```

### The Rule of Thumb

If you can hold the entire input in memory and the processing is synchronous or a single async step, do not use streams. Use streams when:

1. The data does not fit in memory
2. The data arrives incrementally (network, user input, sensors)
3. You need to process data before it has all arrived (time to first byte)
4. You are serving many concurrent requests and memory is a shared resource

---

## Stream Reuse and Pooling

Transform streams can sometimes be reused across multiple pipelines if they are stateless. Stateful streams (those that accumulate data in `_transform`) must be recreated for each use.

```javascript
'use strict';

const { Transform } = require('node:stream');

// Stateless — safe to reuse (but be careful with stream lifecycle)
function createUpperTransform() {
  return new Transform({
    transform(chunk, encoding, callback) {
      callback(null, chunk.toString().toUpperCase());
    },
  });
}

// Factory pattern — create fresh instances for each pipeline
async function processFiles(files) {
  const { pipeline } = require('node:stream/promises');
  const fs = require('node:fs');

  for (const file of files) {
    await pipeline(
      fs.createReadStream(file),
      createUpperTransform(), // Fresh instance each time
      fs.createWriteStream(file + '.upper')
    );
  }
}
```

### Why Not Reuse Stream Instances

```javascript
'use strict';

const { Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const fs = require('node:fs');

// DO NOT do this — a stream that has ended cannot be reused
const upper = new Transform({
  transform(chunk, encoding, callback) {
    callback(null, chunk.toString().toUpperCase());
  },
});

// First pipeline — works fine
// await pipeline(fs.createReadStream('a.txt'), upper, fs.createWriteStream('a.upper'));

// Second pipeline — FAILS because 'upper' was already ended and destroyed
// await pipeline(fs.createReadStream('b.txt'), upper, fs.createWriteStream('b.upper'));
// Error: Cannot call write after a stream was destroyed
```

---

## Zero-Copy Considerations

### `Buffer.allocUnsafe()` vs `Buffer.alloc()`

`Buffer.allocUnsafe()` skips zero-filling, which is faster but exposes old memory contents. Use it only when you will immediately overwrite every byte.

```javascript
'use strict';

const { Writable } = require('node:stream');

// In a custom Readable that reads from a file descriptor:
// Using allocUnsafe is safe because fs.read() fills the buffer
const buf1 = Buffer.allocUnsafe(65536); // Fast — no zero-fill
// fs.readSync(fd, buf1, 0, 65536, position); // Fills every byte

// Using alloc is safe but slower — zeroes 64 KB first
const buf2 = Buffer.alloc(65536); // Slower — zeroes memory
```

### Avoiding Buffer Copies

```javascript
'use strict';

const { Transform } = require('node:stream');

// BAD — toString() creates a new string copy of every chunk
class BadTransform extends Transform {
  _transform(chunk, encoding, callback) {
    const str = chunk.toString(); // Copy #1: Buffer → String
    const upper = str.toUpperCase(); // Copy #2: new String
    callback(null, Buffer.from(upper)); // Copy #3: String → Buffer
    // Total: 3 copies per chunk
  }
}

// BETTER for byte-level transforms — operate directly on the Buffer
class FastUpperTransform extends Transform {
  _transform(chunk, encoding, callback) {
    // Uppercase ASCII bytes in-place (a=97, z=122, offset=32)
    for (let i = 0; i < chunk.length; i++) {
      if (chunk[i] >= 97 && chunk[i] <= 122) {
        chunk[i] -= 32;
      }
    }
    callback(null, chunk); // Zero copies — modified in place
  }
}
```

---

## Key Takeaways

- The default `highWaterMark` of 16 KB works for most cases; increase to 64-256 KB for file and network I/O, but be aware that higher values multiply memory usage by the number of concurrent streams
- `stream.compose()` creates reusable pipeline segments by combining multiple streams or generators into a single Duplex — use it to build a library of composable transforms
- The three most common memory leaks in stream code are unbounded internal buffers in transforms, listener accumulation from adding handlers in loops, and unclosed streams after errors
- For files under 1 MB, `readFile`/`writeFile` is simpler and often faster than streams — streams add overhead (buffer management, event emission, backpressure) that only pays off with larger or continuous data
- Always benchmark with your actual workload before tuning `highWaterMark` or switching approaches — the performance characteristics depend on file size, transform complexity, I/O device speed, and concurrency level

---

## Next

This concludes Module 05. Continue to [Module 06 — Networking](../module-06-networking/lesson-01-network-fundamentals.md), where you will learn how Node.js handles TCP sockets, UDP datagrams, and DNS resolution — the foundation of every server and client application.
