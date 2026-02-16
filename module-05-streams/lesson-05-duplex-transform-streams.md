# Module 05 / Lesson 05 — Duplex and Transform Streams

> A TCP socket reads and writes simultaneously. A gzip compressor ingests raw bytes and emits compressed bytes. These are not two separate streams glued together — they are single objects with dual personalities. Duplex and Transform streams model bidirectional and data-transforming I/O with the same backpressure guarantees you already know.

## Learning Objectives

- Distinguish Duplex streams from two independent Readable/Writable streams
- Identify core Duplex streams like `net.Socket` and crypto streams
- Build custom Transform streams using `_transform()` and `_flush()`
- Use `PassThrough` as a diagnostic and buffering tool
- Understand when to choose Duplex vs Transform for your use case

---

## Duplex Streams

A Duplex stream implements both the Readable and Writable interfaces. The crucial distinction: the Readable side and the Writable side are **independent**. Data written to the Writable side does not automatically appear on the Readable side.

Think of a telephone: you speak into one end and listen from the other. What you hear has nothing to do with what you say.

### net.Socket: The Canonical Duplex

The TCP socket is the most common Duplex stream in Node.js. You write data to send it over the network, and you read data that arrives from the remote peer.

```js
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  // socket is a Duplex stream
  console.log('Client connected');

  // Readable side: data arriving from the client
  socket.on('data', (chunk) => {
    const message = chunk.toString().trim();
    console.log(`Client says: ${message}`);

    // Writable side: send data back to the client
    socket.write(`Echo: ${message}\n`);
  });

  socket.on('end', () => {
    console.log('Client disconnected');
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.listen(4000, () => {
  console.log('Echo server listening on port 4000');
});
```

### Independent Buffer Sides

A Duplex stream has two separate internal buffers: one for the Readable side and one for the Writable side. Each has its own `highWaterMark`.

```js
'use strict';

const { Duplex } = require('node:stream');

const duplex = new Duplex({
  readableHighWaterMark: 32 * 1024,  // 32 KB for reads
  writableHighWaterMark: 16 * 1024,  // 16 KB for writes

  read(size) {
    // Produce data for consumers to read
    this.push('Hello from the readable side\n');
    this.push(null);
  },

  write(chunk, encoding, callback) {
    // Handle data written by producers
    console.log(`Received on writable side: ${chunk}`);
    callback();
  }
});

// These two operations are completely independent
duplex.write('Data going IN\n');
duplex.on('data', (chunk) => {
  console.log(`Data coming OUT: ${chunk}`);
});
```

### Core Duplex Streams

| Stream                   | Readable side          | Writable side           |
|--------------------------|------------------------|------------------------|
| `net.Socket`             | Data from remote peer  | Data to remote peer     |
| `tls.TLSSocket`         | Decrypted data in      | Plaintext data out      |
| `child_process` stdio    | stdout/stderr from child | stdin to child        |

---

## Transform Streams

A Transform stream is a special kind of Duplex where the Readable side **is derived from** the Writable side. Data written in gets transformed and pushed out.

Think of a meat grinder: you push beef in one end, and ground beef comes out the other. The output is a function of the input.

### The Transform Contract

Transform streams implement a `_transform(chunk, encoding, callback)` method. Inside this method, you process the input chunk and call `this.push()` to emit output.

```js
'use strict';

const { Transform } = require('node:stream');

const upperCase = new Transform({
  transform(chunk, encoding, callback) {
    // Transform the input and push the result
    const upper = chunk.toString().toUpperCase();
    this.push(upper);
    callback(); // Signal that this chunk is processed
  }
});

// Pipe stdin through the transform to stdout
process.stdin.pipe(upperCase).pipe(process.stdout);
```

### The callback in _transform

The `callback` serves two purposes:

1. **Signal completion** — tells the stream that the current chunk has been fully processed
2. **Optionally push data** — `callback(null, data)` is equivalent to `this.push(data); callback()`

```js
'use strict';

const { Transform } = require('node:stream');

// These two are equivalent:

const transform1 = new Transform({
  transform(chunk, encoding, callback) {
    this.push(chunk.toString().toUpperCase());
    callback();
  }
});

const transform2 = new Transform({
  transform(chunk, encoding, callback) {
    // Shorthand: pass data as second argument
    callback(null, chunk.toString().toUpperCase());
  }
});
```

### Pushing Multiple Chunks per Input

A Transform can push zero, one, or many chunks for each input chunk. The output does not have to be the same size as the input.

```js
'use strict';

const { Transform } = require('node:stream');

// Split each input line into individual words
const wordSplitter = new Transform({
  transform(chunk, encoding, callback) {
    const line = chunk.toString();
    const words = line.split(/\s+/).filter(Boolean);

    for (const word of words) {
      this.push(word + '\n');
    }

    callback();
  }
});

// Or push nothing (filter):
const errorFilter = new Transform({
  transform(chunk, encoding, callback) {
    const line = chunk.toString();
    if (line.includes('ERROR')) {
      this.push(line);
    }
    // Non-error lines are dropped — nothing pushed
    callback();
  }
});
```

---

## The _flush Method

When the input stream ends, the Transform may need to emit final data. The `_flush(callback)` method is called once, after all input has been processed but before `'end'` is emitted on the Readable side.

### Use Case: Accumulating State

```js
'use strict';

const { Transform } = require('node:stream');

// Count lines and emit the total at the end
const lineCounter = new Transform({
  construct(callback) {
    this.count = 0;
    callback();
  },

  transform(chunk, encoding, callback) {
    const str = chunk.toString();
    for (let i = 0; i < str.length; i++) {
      if (str[i] === '\n') this.count++;
    }
    // Pass data through unchanged
    this.push(chunk);
    callback();
  },

  flush(callback) {
    // Emit the final count after all input is processed
    this.push(`\n--- Total lines: ${this.count} ---\n`);
    callback();
  }
});

process.stdin.pipe(lineCounter).pipe(process.stdout);
```

### Use Case: Buffering Incomplete Data

A common pattern is buffering incomplete records in `_transform` and flushing the remainder in `_flush`.

```js
'use strict';

const { Transform } = require('node:stream');

// Parse newline-delimited JSON (NDJSON)
const ndjsonParser = new Transform({
  objectMode: true, // Output JavaScript objects, not Buffers

  construct(callback) {
    this.buffer = '';
    callback();
  },

  transform(chunk, encoding, callback) {
    this.buffer += chunk.toString();

    const lines = this.buffer.split('\n');
    // Keep the last element — it may be incomplete
    this.buffer = lines.pop();

    for (const line of lines) {
      if (line.trim().length === 0) continue;
      try {
        this.push(JSON.parse(line));
      } catch (err) {
        // Skip malformed lines or emit an error
        this.destroy(err);
        return;
      }
    }

    callback();
  },

  flush(callback) {
    // Process any remaining data in the buffer
    if (this.buffer.trim().length > 0) {
      try {
        this.push(JSON.parse(this.buffer));
      } catch (err) {
        return callback(err);
      }
    }
    callback();
  }
});
```

---

## Building a Custom Uppercase Transform

Let us build a complete, production-quality Transform that converts text to uppercase while properly handling multi-byte characters and chunk boundaries.

```js
'use strict';

const { Transform } = require('node:stream');
const { StringDecoder } = require('node:string_decoder');

class UpperCaseTransform extends Transform {
  constructor(options = {}) {
    super(options);
    this.decoder = new StringDecoder('utf8');
  }

  _transform(chunk, encoding, callback) {
    // Use StringDecoder to handle multi-byte chars at chunk boundaries
    const str = this.decoder.write(chunk);

    if (str.length > 0) {
      this.push(str.toUpperCase());
    }

    callback();
  }

  _flush(callback) {
    // Flush any remaining bytes in the StringDecoder
    const remaining = this.decoder.end();
    if (remaining.length > 0) {
      this.push(remaining.toUpperCase());
    }
    callback();
  }
}

// Usage
const fs = require('node:fs');
const { pipeline } = require('node:stream/promises');

async function uppercaseFile(input, output) {
  await pipeline(
    fs.createReadStream(input),
    new UpperCaseTransform(),
    fs.createWriteStream(output)
  );
  console.log('Done');
}

uppercaseFile('input.txt', 'output.txt').catch(console.error);
```

This implementation is safe for any UTF-8 input because the `StringDecoder` handles characters that span chunk boundaries.

---

## PassThrough: The Identity Transform

`PassThrough` is a Transform that passes data through unchanged. It sounds useless, but it has several practical applications.

### Tapping a Pipeline

Insert a PassThrough to observe data flowing through a pipeline without altering it.

```js
'use strict';

const fs = require('node:fs');
const { PassThrough } = require('node:stream');
const { createGzip } = require('node:zlib');

const tap = new PassThrough();

let totalBytes = 0;
tap.on('data', (chunk) => {
  totalBytes += chunk.length;
});

tap.on('end', () => {
  console.log(`Total uncompressed bytes: ${totalBytes}`);
});

fs.createReadStream('data.txt')
  .pipe(tap)                       // Observe data before compression
  .pipe(createGzip())
  .pipe(fs.createWriteStream('data.txt.gz'));
```

### Lazy Piping

Use PassThrough as a placeholder when the final destination is not yet known.

```js
'use strict';

const { PassThrough } = require('node:stream');

function createLazyWriter() {
  const passthrough = new PassThrough();

  // Start writing to the passthrough immediately
  passthrough.write('Header data\n');

  // The actual destination can be connected later
  return passthrough;
}

const lazy = createLazyWriter();

// Some time later, connect to the real destination
const fs = require('node:fs');
lazy.pipe(fs.createWriteStream('output.txt'));

lazy.write('More data\n');
lazy.end('Final data\n');
```

### Buffering for Multiple Consumers

```js
'use strict';

const fs = require('node:fs');
const { PassThrough } = require('node:stream');
const { createGzip } = require('node:zlib');
const { createHash } = require('node:crypto');

const source = fs.createReadStream('data.txt');

// Create two independent consumers via PassThrough
const forHash = new PassThrough();
const forGzip = new PassThrough();

source.pipe(forHash);
source.pipe(forGzip);

// Consumer 1: compute SHA-256
const hash = createHash('sha256');
forHash.pipe(hash);
hash.on('readable', () => {
  const data = hash.read();
  if (data) {
    console.log('SHA-256:', data.toString('hex'));
  }
});

// Consumer 2: compress
forGzip.pipe(createGzip()).pipe(fs.createWriteStream('data.txt.gz'));
```

---

## Crypto Streams: Real-World Transforms

Node.js crypto module provides several Transform streams.

### Hashing

```js
'use strict';

const fs = require('node:fs');
const { createHash } = require('node:crypto');

// Hash is a Transform: bytes in, hash digest out
const hash = createHash('sha256');

const input = fs.createReadStream('large-file.iso');

input.pipe(hash);

hash.on('readable', () => {
  const digest = hash.read();
  if (digest) {
    console.log(`SHA-256: ${digest.toString('hex')}`);
  }
});
```

### Encryption / Decryption

```js
'use strict';

const fs = require('node:fs');
const { createCipheriv, createDecipheriv, randomBytes } = require('node:crypto');

const algorithm = 'aes-256-cbc';
const key = randomBytes(32);
const iv = randomBytes(16);

// Encrypt: Transform (plaintext in, ciphertext out)
function encryptFile(input, output) {
  const cipher = createCipheriv(algorithm, key, iv);

  fs.createReadStream(input)
    .pipe(cipher)
    .pipe(fs.createWriteStream(output));
}

// Decrypt: Transform (ciphertext in, plaintext out)
function decryptFile(input, output) {
  const decipher = createDecipheriv(algorithm, key, iv);

  fs.createReadStream(input)
    .pipe(decipher)
    .pipe(fs.createWriteStream(output));
}

encryptFile('secret.txt', 'secret.enc');
// Later: decryptFile('secret.enc', 'secret.dec');
```

---

## Zlib Streams: Compression Transforms

The `node:zlib` module provides Transform streams for compression and decompression.

```js
'use strict';

const fs = require('node:fs');
const { createGzip, createGunzip, createBrotliCompress } = require('node:zlib');
const { pipeline } = require('node:stream/promises');

// Gzip compression
async function gzipFile(input, output) {
  await pipeline(
    fs.createReadStream(input),
    createGzip(),
    fs.createWriteStream(output)
  );
}

// Gzip decompression
async function gunzipFile(input, output) {
  await pipeline(
    fs.createReadStream(input),
    createGunzip(),
    fs.createWriteStream(output)
  );
}

// Brotli compression (better ratio, slower)
async function brotliFile(input, output) {
  await pipeline(
    fs.createReadStream(input),
    createBrotliCompress(),
    fs.createWriteStream(output)
  );
}

gzipFile('data.json', 'data.json.gz')
  .then(() => console.log('Compressed'))
  .catch(console.error);
```

---

## Duplex vs Transform: When to Choose Which

| Question                                              | Answer           |
|-------------------------------------------------------|------------------|
| Is the output derived from the input?                 | Transform        |
| Are the read and write sides independent?             | Duplex           |
| Do I need to transform data in a pipeline?            | Transform        |
| Do I need bidirectional communication (like a socket)?| Duplex           |
| Do I need to buffer, observe, or tee a pipeline?      | PassThrough      |

### Decision Flowchart

```
Does the output depend on the input?
├── YES → Use Transform
│         Does it need state between chunks?
│         ├── YES → Implement _transform + _flush
│         └── NO  → Simple _transform is enough
└── NO  → Use Duplex
          Is it a network protocol?
          ├── YES → net.Socket / tls.TLSSocket
          └── NO  → Custom Duplex with separate read/write logic
```

---

## Chaining Transforms

One of the most powerful patterns is chaining multiple Transforms together. Each Transform does one thing, and the pipeline composes them.

```js
'use strict';

const { Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const fs = require('node:fs');

// Transform 1: Remove blank lines
const removeBlankLines = new Transform({
  transform(chunk, encoding, callback) {
    const lines = chunk.toString().split('\n');
    const filtered = lines.filter((line) => line.trim().length > 0);
    callback(null, filtered.join('\n') + '\n');
  }
});

// Transform 2: Add line numbers
let lineNumber = 0;
const addLineNumbers = new Transform({
  transform(chunk, encoding, callback) {
    const lines = chunk.toString().split('\n');
    const numbered = lines
      .filter((line) => line.length > 0)
      .map((line) => {
        lineNumber++;
        return `${String(lineNumber).padStart(6, ' ')} | ${line}`;
      });
    callback(null, numbered.join('\n') + '\n');
  }
});

// Transform 3: Uppercase
const uppercase = new Transform({
  transform(chunk, encoding, callback) {
    callback(null, chunk.toString().toUpperCase());
  }
});

// Compose: read file → remove blanks → add numbers → uppercase → write
pipeline(
  fs.createReadStream('input.txt'),
  removeBlankLines,
  addLineNumbers,
  uppercase,
  fs.createWriteStream('output.txt')
)
  .then(() => console.log('Pipeline complete'))
  .catch(console.error);
```

Each Transform is simple and testable in isolation. The pipeline composes them into complex behavior while maintaining backpressure through the entire chain.

---

## Key Takeaways

- Duplex streams have independent Readable and Writable sides — data in does not automatically become data out
- Transform streams derive their output from their input via `_transform()` and optionally `_flush()`
- `PassThrough` is a zero-op Transform useful for tapping, buffering, and lazy piping
- Core modules like `node:zlib` and `node:crypto` provide ready-made Transform streams for compression, hashing, and encryption
- Chain multiple single-purpose Transforms to build complex processing pipelines with full backpressure support

## Next

In Lesson 06, we tackle piping and `pipeline()` — the proper way to connect streams together with full error handling, cleanup, and `AbortController` support.
