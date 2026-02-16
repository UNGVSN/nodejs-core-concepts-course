# Module 05 / Lesson 06 — Piping and pipeline()

> Connecting streams together should be simple. And `pipe()` makes it simple — until an error occurs midway through the chain and you discover that half your streams leaked file descriptors. The `pipeline()` function exists precisely to solve the error handling and cleanup problems that `pipe()` ignores.

## Learning Objectives

- Use `pipe()` for quick stream chaining and understand its limitations
- Identify the error handling gap in `pipe()` that causes resource leaks
- Use `stream.pipeline()` for proper error propagation and automatic cleanup
- Use the promise-based `stream/promises` pipeline for async/await code
- Cancel pipelines with `AbortController` for timeout and cancellation patterns

---

## pipe() — The Convenient Default

The `pipe()` method connects a Readable to a Writable in a single call. It handles backpressure automatically and returns the destination stream, enabling chaining.

```js
'use strict';

const fs = require('node:fs');
const { createGzip } = require('node:zlib');

// Simple pipe
fs.createReadStream('input.txt')
  .pipe(fs.createWriteStream('copy.txt'));

// Chained pipe: read → compress → write
fs.createReadStream('data.json')
  .pipe(createGzip())
  .pipe(fs.createWriteStream('data.json.gz'));
```

### pipe() Returns the Destination

The return value of `pipe()` is the destination stream. This is what enables chaining — each `.pipe()` call returns the next stream in the chain.

```js
'use strict';

const fs = require('node:fs');
const { createGzip } = require('node:zlib');
const { Transform } = require('node:stream');

const addTimestamp = new Transform({
  transform(chunk, encoding, callback) {
    const timestamp = new Date().toISOString();
    callback(null, `[${timestamp}] ${chunk}`);
  }
});

// Each pipe() returns its destination, so you can chain
const finalDest = fs.createReadStream('app.log')
  .pipe(addTimestamp)     // returns addTimestamp
  .pipe(createGzip())     // returns the gzip transform
  .pipe(fs.createWriteStream('app.log.gz')); // returns the write stream

console.log(finalDest.constructor.name); // WriteStream
```

### pipe() Options

The `pipe()` method accepts an options object with a single property:

```js
'use strict';

const fs = require('node:fs');

const readable = fs.createReadStream('data.txt');
const writable = fs.createWriteStream('output.txt');

// By default, pipe() calls writable.end() when the readable ends
readable.pipe(writable);

// To prevent auto-end (useful when piping multiple sources to one dest):
readable.pipe(writable, { end: false });
```

### Piping Multiple Sources to One Destination

```js
'use strict';

const fs = require('node:fs');

const dest = fs.createWriteStream('combined.txt');

const files = ['part1.txt', 'part2.txt', 'part3.txt'];
let index = 0;

function pipeNext() {
  if (index >= files.length) {
    dest.end();
    return;
  }

  const source = fs.createReadStream(files[index]);
  index++;

  // Don't auto-end the destination — we have more files
  source.pipe(dest, { end: false });

  source.on('end', pipeNext);
  source.on('error', (err) => {
    console.error(`Error reading ${files[index - 1]}:`, err.message);
    dest.destroy(err);
  });
}

pipeNext();

dest.on('finish', () => {
  console.log('All files combined');
});
```

---

## The Problem with pipe()

`pipe()` handles backpressure well, but its error handling is incomplete. Specifically:

1. **Errors on the source propagate** — if the Readable emits `'error'`, the pipe is destroyed
2. **Errors on the destination do NOT propagate** — if the Writable emits `'error'`, the Readable is NOT destroyed
3. **Intermediate streams are NOT cleaned up** — if any stream in the middle of a chain errors, the other streams may leak

### Demonstrating the Leak

```js
'use strict';

const fs = require('node:fs');
const { Transform } = require('node:stream');

const source = fs.createReadStream('input.txt');

const buggyTransform = new Transform({
  transform(chunk, encoding, callback) {
    // Simulate an error after processing some data
    if (this.readableLength > 1000) {
      callback(new Error('Transform failed'));
    } else {
      callback(null, chunk);
    }
  }
});

const dest = fs.createWriteStream('output.txt');

// pipe() chain
source.pipe(buggyTransform).pipe(dest);

// You must manually handle errors on EVERY stream
source.on('error', (err) => console.error('Source error:', err.message));
buggyTransform.on('error', (err) => console.error('Transform error:', err.message));
dest.on('error', (err) => console.error('Dest error:', err.message));

// Even with error handlers, source and dest are NOT automatically
// cleaned up when buggyTransform fails. File descriptors may leak.
```

This is the fundamental problem: `pipe()` was designed for simple cases. For production pipelines, you need `pipeline()`.

---

## stream.pipeline() — The Production Solution

`stream.pipeline()` connects streams together and:

1. Propagates errors through the entire chain
2. Destroys all streams when any stream errors or finishes
3. Calls a final callback when the pipeline is done (success or failure)

```js
'use strict';

const fs = require('node:fs');
const { createGzip } = require('node:zlib');
const { pipeline } = require('node:stream');

pipeline(
  fs.createReadStream('input.txt'),
  createGzip(),
  fs.createWriteStream('input.txt.gz'),
  (err) => {
    if (err) {
      console.error('Pipeline failed:', err.message);
    } else {
      console.log('Pipeline succeeded');
    }
  }
);
```

### What pipeline() Does Internally

Conceptually, `pipeline()` does this:

```js
'use strict';

// Simplified pseudocode of what pipeline() does
function simplifiedPipeline(...streams) {
  const callback = streams.pop(); // Last argument is the callback

  // Pipe each stream to the next
  for (let i = 0; i < streams.length - 1; i++) {
    streams[i].pipe(streams[i + 1]);
  }

  // On error from ANY stream, destroy ALL streams
  for (const stream of streams) {
    stream.on('error', (err) => {
      for (const s of streams) {
        if (!s.destroyed) s.destroy();
      }
      callback(err);
    });
  }

  // On finish of the last stream, call callback with no error
  const last = streams[streams.length - 1];
  last.on('finish', () => callback(null));
}
```

The real implementation is more sophisticated (handles edge cases, prevents double callbacks, etc.), but this captures the essential behavior.

### pipeline() vs pipe() Comparison

| Feature                          | `pipe()`           | `pipeline()`       |
|----------------------------------|--------------------|---------------------|
| Backpressure                     | Yes                | Yes                 |
| Error propagation                | Source only        | All streams         |
| Automatic cleanup on error       | No                 | Yes                 |
| Callback/promise on completion   | No                 | Yes                 |
| AbortController support          | No                 | Yes                 |
| Returns                          | Destination stream | (varies by form)    |

---

## Promise-Based pipeline()

The `stream/promises` module provides a promise-based version of `pipeline()` that integrates cleanly with async/await.

```js
'use strict';

const fs = require('node:fs');
const { createGzip, createGunzip } = require('node:zlib');
const { pipeline } = require('node:stream/promises');

async function compressFile(input, output) {
  await pipeline(
    fs.createReadStream(input),
    createGzip(),
    fs.createWriteStream(output)
  );
  console.log(`Compressed ${input} → ${output}`);
}

async function decompressFile(input, output) {
  await pipeline(
    fs.createReadStream(input),
    createGunzip(),
    fs.createWriteStream(output)
  );
  console.log(`Decompressed ${input} → ${output}`);
}

async function main() {
  try {
    await compressFile('data.json', 'data.json.gz');
    await decompressFile('data.json.gz', 'data-restored.json');
  } catch (err) {
    console.error('Failed:', err.message);
  }
}

main();
```

### Error Handling with try/catch

The promise-based pipeline rejects on any error in the chain. A single `try/catch` handles everything.

```js
'use strict';

const fs = require('node:fs');
const { Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');

async function processLog(inputPath, outputPath) {
  const errorFilter = new Transform({
    transform(chunk, encoding, callback) {
      const lines = chunk.toString().split('\n');
      const errors = lines
        .filter((line) => line.includes('ERROR'))
        .join('\n');

      if (errors.length > 0) {
        callback(null, errors + '\n');
      } else {
        callback();
      }
    }
  });

  try {
    await pipeline(
      fs.createReadStream(inputPath),
      errorFilter,
      fs.createWriteStream(outputPath)
    );
    console.log('Error log extracted');
  } catch (err) {
    if (err.code === 'ENOENT') {
      console.error(`File not found: ${inputPath}`);
    } else if (err.code === 'ERR_STREAM_PREMATURE_CLOSE') {
      console.error('Stream closed unexpectedly');
    } else {
      console.error('Pipeline failed:', err.message);
    }
  }
}

processLog('app.log', 'errors.log');
```

---

## AbortController — Cancelling Pipelines

`pipeline()` accepts an `AbortSignal` via the `signal` option. When the signal is aborted, the pipeline destroys all streams immediately.

### Timeout Pattern

```js
'use strict';

const fs = require('node:fs');
const { createGzip } = require('node:zlib');
const { pipeline } = require('node:stream/promises');

async function compressWithTimeout(input, output, timeoutMs) {
  const ac = new AbortController();
  const { signal } = ac;

  // Set a timeout to abort the pipeline
  const timer = setTimeout(() => ac.abort(), timeoutMs);

  try {
    await pipeline(
      fs.createReadStream(input),
      createGzip(),
      fs.createWriteStream(output),
      { signal }
    );
    console.log('Compression complete');
  } catch (err) {
    if (err.name === 'AbortError') {
      console.error(`Compression timed out after ${timeoutMs}ms`);
      // Clean up the partial output file
      fs.unlink(output, () => {});
    } else {
      console.error('Compression failed:', err.message);
    }
  } finally {
    clearTimeout(timer);
  }
}

compressWithTimeout('huge-file.dat', 'huge-file.dat.gz', 5000);
```

### User-Initiated Cancellation

```js
'use strict';

const fs = require('node:fs');
const { pipeline } = require('node:stream/promises');
const readline = require('node:readline');

async function downloadWithCancel(inputPath, outputPath) {
  const ac = new AbortController();

  // Listen for user pressing Ctrl+C (or 'q')
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (line) => {
    if (line.trim().toLowerCase() === 'q') {
      console.log('Cancellation requested...');
      ac.abort();
    }
  });

  console.log('Processing... Press q + Enter to cancel');

  try {
    await pipeline(
      fs.createReadStream(inputPath),
      fs.createWriteStream(outputPath),
      { signal: ac.signal }
    );
    console.log('Complete');
  } catch (err) {
    if (err.name === 'AbortError') {
      console.log('Operation cancelled by user');
    } else {
      console.error('Error:', err.message);
    }
  } finally {
    rl.close();
  }
}

downloadWithCancel('source.dat', 'dest.dat');
```

---

## Generator Functions in pipeline()

The promise-based `pipeline()` supports async generator functions as intermediate steps. This is a powerful pattern for transformation without creating explicit Transform streams.

```js
'use strict';

const fs = require('node:fs');
const { pipeline } = require('node:stream/promises');

async function* toUpperCase(source) {
  for await (const chunk of source) {
    yield chunk.toString().toUpperCase();
  }
}

async function* addLineNumbers(source) {
  let lineNum = 0;
  let buffer = '';

  for await (const chunk of source) {
    buffer += chunk;
    const lines = buffer.split('\n');
    buffer = lines.pop(); // Keep incomplete last line

    for (const line of lines) {
      lineNum++;
      yield `${String(lineNum).padStart(4, ' ')} | ${line}\n`;
    }
  }

  // Flush remaining buffer
  if (buffer.length > 0) {
    lineNum++;
    yield `${String(lineNum).padStart(4, ' ')} | ${buffer}\n`;
  }
}

async function main() {
  await pipeline(
    fs.createReadStream('input.txt', { encoding: 'utf8' }),
    toUpperCase,
    addLineNumbers,
    fs.createWriteStream('output.txt')
  );
  console.log('Done');
}

main().catch(console.error);
```

Generator functions in pipelines are particularly useful because:

1. They are plain functions — easy to test in isolation
2. They handle backpressure automatically via `for await...of`
3. They compose naturally with other generators or Transform streams

### Filtering with Generators

```js
'use strict';

const fs = require('node:fs');
const readline = require('node:readline');
const { pipeline } = require('node:stream/promises');

async function* parseJsonLines(source) {
  const rl = readline.createInterface({ input: source, crlfDelay: Infinity });

  for await (const line of rl) {
    if (line.trim().length === 0) continue;
    try {
      yield JSON.parse(line);
    } catch {
      // Skip malformed lines
    }
  }
}

async function* filterByLevel(source, level) {
  for await (const record of source) {
    if (record.level === level) {
      yield record;
    }
  }
}

async function* serialize(source) {
  for await (const record of source) {
    yield JSON.stringify(record) + '\n';
  }
}

async function extractErrors(inputPath, outputPath) {
  await pipeline(
    fs.createReadStream(inputPath),
    parseJsonLines,
    (source) => filterByLevel(source, 'error'),
    serialize,
    fs.createWriteStream(outputPath)
  );
}

extractErrors('app.jsonl', 'errors.jsonl').catch(console.error);
```

---

## unpipe() — Disconnecting Streams

The `unpipe()` method disconnects a previously piped destination.

```js
'use strict';

const fs = require('node:fs');

const source = fs.createReadStream('data.txt');
const dest = fs.createWriteStream('output.txt');

source.pipe(dest);

// Later, disconnect
setTimeout(() => {
  source.unpipe(dest);
  console.log('Unpiped — data stops flowing to dest');

  // You can pipe to a different destination
  const altDest = fs.createWriteStream('alternate.txt');
  source.pipe(altDest);
}, 1000);
```

### unpipe() with No Arguments

Calling `unpipe()` with no arguments removes all pipe destinations.

```js
'use strict';

const fs = require('node:fs');

const source = fs.createReadStream('data.txt');
const dest1 = fs.createWriteStream('copy1.txt');
const dest2 = fs.createWriteStream('copy2.txt');

source.pipe(dest1);
source.pipe(dest2);

// Remove all destinations
source.unpipe();
```

---

## Error Patterns in Production

### Pattern 1: Retry on Failure

```js
'use strict';

const fs = require('node:fs');
const { createGzip } = require('node:zlib');
const { pipeline } = require('node:stream/promises');

async function compressWithRetry(input, output, maxRetries = 3) {
  let lastError;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      await pipeline(
        fs.createReadStream(input),
        createGzip(),
        fs.createWriteStream(output)
      );
      return; // Success
    } catch (err) {
      lastError = err;
      console.error(`Attempt ${attempt} failed: ${err.message}`);

      // Clean up partial output
      try {
        fs.unlinkSync(output);
      } catch {
        // File may not exist
      }

      if (attempt < maxRetries) {
        // Wait before retrying (exponential backoff)
        await new Promise((resolve) =>
          setTimeout(resolve, 1000 * Math.pow(2, attempt - 1))
        );
      }
    }
  }

  throw lastError;
}

compressWithRetry('data.json', 'data.json.gz')
  .then(() => console.log('Done'))
  .catch((err) => console.error('All retries failed:', err.message));
```

### Pattern 2: Progress Reporting

```js
'use strict';

const fs = require('node:fs');
const { Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');

function createProgressReporter(totalBytes) {
  let processed = 0;
  let lastReport = 0;

  return new Transform({
    transform(chunk, encoding, callback) {
      processed += chunk.length;
      const pct = Math.floor((processed / totalBytes) * 100);

      if (pct >= lastReport + 5) {
        lastReport = pct;
        process.stderr.write(`\rProgress: ${pct}%`);
      }

      callback(null, chunk);
    },

    flush(callback) {
      process.stderr.write('\rProgress: 100%\n');
      callback();
    }
  });
}

async function copyWithProgress(input, output) {
  const stats = fs.statSync(input);
  const progress = createProgressReporter(stats.size);

  await pipeline(
    fs.createReadStream(input),
    progress,
    fs.createWriteStream(output)
  );

  console.log('Copy complete');
}

copyWithProgress('large-file.dat', 'large-file-copy.dat').catch(console.error);
```

---

## When to Use pipe() vs pipeline()

| Scenario                                    | Use                 |
|---------------------------------------------|---------------------|
| Quick one-liner in a script                 | `pipe()`            |
| Production server code                      | `pipeline()`        |
| Need a completion callback or promise       | `pipeline()`        |
| Need cancellation with AbortController      | `pipeline()`        |
| Piping to HTTP response in request handler  | `pipeline()`        |
| Simple stdin → stdout transform             | `pipe()` is fine    |

The general rule: if the code runs in production and handles untrusted or variable-size input, use `pipeline()`. The extra safety is worth the slightly longer syntax.

---

## Key Takeaways

- `pipe()` handles backpressure but not errors on downstream streams — it can leak file descriptors and sockets
- `stream.pipeline()` propagates errors through the entire chain and destroys all streams on failure
- The `stream/promises` version of `pipeline()` returns a promise, integrating cleanly with async/await and `try/catch`
- `AbortController` support in `pipeline()` enables timeout and cancellation patterns
- Async generator functions can serve as pipeline stages, offering a lightweight alternative to explicit Transform streams

## Next

In Lesson 07, we build custom streams from scratch — extending `Readable`, `Writable`, and `Transform` classes, implementing `_read`, `_write`, `_writev`, and `objectMode`.
