# Module 10 / Lesson 08 — Zlib Compression

> A 500 KB JSON response becomes 45 KB with gzip and 38 KB with Brotli — same data, 90% fewer bytes on the wire. The `node:zlib` module gives you streaming compression that plugs directly into Node's I/O model, turning bandwidth savings into a single `pipeline()` call.

## Learning Objectives

- Use the `node:zlib` module to compress and decompress data with Gzip, Deflate, and Brotli
- Choose between streaming Transform APIs and one-shot callback APIs based on data size
- Configure compression levels, memory levels, and strategies for optimal performance
- Build HTTP compression middleware that negotiates `Accept-Encoding` with clients
- Know when compression helps and when it hurts performance

---

## Why Compression Matters

Compression reduces the number of bytes transferred over a network or stored on disk. The trade-off is CPU time: you spend cycles compressing and decompressing in exchange for fewer bytes.

| Metric | Without Compression | With Gzip | With Brotli |
|---|---|---|---|
| JSON API response (500 KB) | 500 KB | ~50 KB | ~40 KB |
| HTML page (100 KB) | 100 KB | ~15 KB | ~12 KB |
| Transfer time (10 Mbps) | 400 ms | 40 ms | 32 ms |
| CPU cost | 0 ms | ~2 ms | ~5 ms |

For text-based formats (JSON, HTML, CSS, JS, XML, CSV), compression ratios of 70-90% are typical.

## The `node:zlib` Module

The `zlib` module provides bindings to the zlib (Gzip/Deflate) and Brotli C libraries. It exposes two types of APIs:

1. **Streaming APIs** — Transform streams for piping large data
2. **One-shot APIs** — Callback-based functions for small, in-memory data

## Compression Algorithms

```
┌─────────────────────────────────────────────────────────┐
│              Algorithm Comparison                        │
├──────────┬──────────┬───────────┬───────────────────────┤
│          │  Gzip    │  Deflate  │  Brotli               │
├──────────┼──────────┼───────────┼───────────────────────┤
│ Format   │ RFC 1952 │ RFC 1951  │ RFC 7932              │
│ Header   │ Yes (10B)│ No        │ No (minimal)          │
│ Checksum │ CRC-32   │ Adler-32  │ None                  │
│ Ratio    │ Good     │ Good      │ Better (5-20% smaller)│
│ Speed    │ Fast     │ Fast      │ Slower to compress    │
│ Browser  │ All      │ All       │ All modern            │
│ HTTP     │ gzip     │ deflate   │ br                    │
│ Files    │ .gz      │ .zz      │ .br                   │
└──────────┴──────────┴───────────┴───────────────────────┘
```

- **Gzip** — the most widely supported. Use it as the default.
- **Deflate** — the raw compression algorithm underneath Gzip (no header/trailer). Rarely used directly in HTTP.
- **Brotli** — developed by Google, better compression ratios for text. All modern browsers support `Content-Encoding: br`.

## Streaming Compression — Transform Streams

Each algorithm has a pair of Transform stream classes:

```js
'use strict';

const zlib = require('node:zlib');
const fs = require('node:fs');
const { pipeline } = require('node:stream/promises');
const path = require('node:path');

async function compressFile(inputPath, outputPath, algorithm = 'gzip') {
  const compressors = {
    gzip:    () => zlib.createGzip(),
    deflate: () => zlib.createDeflate(),
    brotli:  () => zlib.createBrotliCompress(),
  };

  const compressor = compressors[algorithm];
  if (!compressor) {
    throw new Error(`Unknown algorithm: ${algorithm}`);
  }

  const source = fs.createReadStream(inputPath);
  const destination = fs.createWriteStream(outputPath);

  await pipeline(source, compressor(), destination);

  const inputSize = fs.statSync(inputPath).size;
  const outputSize = fs.statSync(outputPath).size;
  const ratio = ((1 - outputSize / inputSize) * 100).toFixed(1);

  console.log(`Compressed ${inputPath}`);
  console.log(`  ${inputSize} → ${outputSize} bytes (${ratio}% reduction)`);
}

async function decompressFile(inputPath, outputPath, algorithm = 'gzip') {
  const decompressors = {
    gzip:    () => zlib.createGunzip(),
    deflate: () => zlib.createInflate(),
    brotli:  () => zlib.createBrotliDecompress(),
  };

  const decompressor = decompressors[algorithm];
  if (!decompressor) {
    throw new Error(`Unknown algorithm: ${algorithm}`);
  }

  const source = fs.createReadStream(inputPath);
  const destination = fs.createWriteStream(outputPath);

  await pipeline(source, decompressor(), destination);

  console.log(`Decompressed ${inputPath} → ${outputPath}`);
}

// Usage:
// await compressFile('data.json', 'data.json.gz', 'gzip');
// await decompressFile('data.json.gz', 'data-restored.json', 'gzip');
```

### All Streaming Classes

| Compress | Decompress | Algorithm |
|---|---|---|
| `zlib.createGzip()` | `zlib.createGunzip()` | Gzip |
| `zlib.createDeflate()` | `zlib.createInflate()` | Deflate (raw) |
| `zlib.createDeflateRaw()` | `zlib.createInflateRaw()` | Deflate (no header) |
| `zlib.createBrotliCompress()` | `zlib.createBrotliDecompress()` | Brotli |

## One-Shot APIs — Small Data

For small, in-memory data, use the callback-based convenience functions. They buffer the entire input and output.

```js
'use strict';

const zlib = require('node:zlib');
const { promisify } = require('node:util');

// Promisify the one-shot APIs for async/await
const gzip = promisify(zlib.gzip);
const gunzip = promisify(zlib.gunzip);
const brotliCompress = promisify(zlib.brotliCompress);
const brotliDecompress = promisify(zlib.brotliDecompress);
const deflate = promisify(zlib.deflate);
const inflate = promisify(zlib.inflate);

async function demo() {
  const original = JSON.stringify({
    users: Array.from({ length: 100 }, (_, i) => ({
      id: i + 1,
      name: `User ${i + 1}`,
      email: `user${i + 1}@example.com`,
      active: i % 3 !== 0,
    })),
  });

  const originalBuf = Buffer.from(original);
  console.log('Original size:', originalBuf.length, 'bytes');

  // Gzip
  const gzipped = await gzip(originalBuf);
  console.log('Gzip size:   ', gzipped.length, 'bytes',
    `(${((1 - gzipped.length / originalBuf.length) * 100).toFixed(1)}%)`);

  // Brotli
  const brotlied = await brotliCompress(originalBuf);
  console.log('Brotli size: ', brotlied.length, 'bytes',
    `(${((1 - brotlied.length / originalBuf.length) * 100).toFixed(1)}%)`);

  // Deflate
  const deflated = await deflate(originalBuf);
  console.log('Deflate size:', deflated.length, 'bytes',
    `(${((1 - deflated.length / originalBuf.length) * 100).toFixed(1)}%)`);

  // Verify round-trip
  const restored = await gunzip(gzipped);
  console.log('Round-trip OK:', restored.toString() === original);
}

demo().catch(console.error);
```

### All One-Shot Functions

| Async (callback) | Sync | Algorithm |
|---|---|---|
| `zlib.gzip(buf, cb)` | `zlib.gzipSync(buf)` | Gzip compress |
| `zlib.gunzip(buf, cb)` | `zlib.gunzipSync(buf)` | Gzip decompress |
| `zlib.deflate(buf, cb)` | `zlib.deflateSync(buf)` | Deflate compress |
| `zlib.inflate(buf, cb)` | `zlib.inflateSync(buf)` | Deflate decompress |
| `zlib.deflateRaw(buf, cb)` | `zlib.deflateRawSync(buf)` | Raw deflate |
| `zlib.inflateRaw(buf, cb)` | `zlib.inflateRawSync(buf)` | Raw inflate |
| `zlib.brotliCompress(buf, cb)` | `zlib.brotliCompressSync(buf)` | Brotli compress |
| `zlib.brotliDecompress(buf, cb)` | `zlib.brotliDecompressSync(buf)` | Brotli decompress |

**Warning:** The `Sync` variants block the event loop. Use them only during startup or in worker threads — never in request handlers.

## Compression Options

### Gzip / Deflate Options

```js
'use strict';

const zlib = require('node:zlib');

// Compression level: 0 (no compression) to 9 (maximum compression)
// Default: zlib.constants.Z_DEFAULT_COMPRESSION (usually 6)

const fast = zlib.createGzip({ level: 1 });     // Fastest, largest output
const balanced = zlib.createGzip({ level: 6 });  // Default balance
const max = zlib.createGzip({ level: 9 });       // Slowest, smallest output

// Memory level: 1 (minimum memory) to 9 (maximum memory, faster)
// Default: 8
const lowMem = zlib.createGzip({ level: 6, memLevel: 1 });

// Strategy: hints to the compressor about the data type
const strategies = {
  default:  zlib.constants.Z_DEFAULT_STRATEGY,  // General purpose
  filtered: zlib.constants.Z_FILTERED,           // Data from a filter (e.g., diff)
  huffman:  zlib.constants.Z_HUFFMAN_ONLY,       // Huffman coding only (fast)
  rle:      zlib.constants.Z_RLE,                // Run-length encoding (good for images)
  fixed:    zlib.constants.Z_FIXED,              // Fixed Huffman codes
};

// Chunk size: internal buffer size (default 16384 = 16 KB)
const largeChunks = zlib.createGzip({
  level: 6,
  chunkSize: 65536, // 64 KB chunks
});
```

### Brotli Options

```js
'use strict';

const zlib = require('node:zlib');

// Brotli quality: 0 (fastest) to 11 (maximum compression)
// Default: 11 (which is quite slow!)
// Recommendation: use 4-6 for dynamic content, 11 for static pre-compressed assets

const brotliFast = zlib.createBrotliCompress({
  params: {
    [zlib.constants.BROTLI_PARAM_QUALITY]: 4,
  },
});

const brotliMax = zlib.createBrotliCompress({
  params: {
    [zlib.constants.BROTLI_PARAM_QUALITY]: 11,
  },
});

// Brotli mode hints
const modes = {
  generic: zlib.constants.BROTLI_MODE_GENERIC,  // Default
  text:    zlib.constants.BROTLI_MODE_TEXT,      // UTF-8 text
  font:    zlib.constants.BROTLI_MODE_FONT,      // WOFF 2.0 fonts
};

const brotliText = zlib.createBrotliCompress({
  params: {
    [zlib.constants.BROTLI_PARAM_MODE]: zlib.constants.BROTLI_MODE_TEXT,
    [zlib.constants.BROTLI_PARAM_QUALITY]: 5,
  },
});

// Window size: 10-24 (log2 of the window), affects memory and ratio
// Default: 22 (4 MB window)
const brotliSmallWindow = zlib.createBrotliCompress({
  params: {
    [zlib.constants.BROTLI_PARAM_QUALITY]: 5,
    [zlib.constants.BROTLI_PARAM_LGWIN]: 16, // 64 KB window
  },
});
```

### Performance vs Compression Level

```
Compression Level vs Speed (approximate, for 1 MB JSON):

Level   Gzip Size   Gzip Time   Brotli Size   Brotli Time
─────   ─────────   ─────────   ───────────   ───────────
  1      120 KB       1 ms         —              —
  4       95 KB       3 ms       90 KB           5 ms
  6       90 KB       5 ms       80 KB          15 ms
  9       88 KB      20 ms       75 KB          50 ms
 11        —           —         70 KB         500 ms

Rule of thumb:
  - Dynamic responses (API): Gzip level 6 or Brotli quality 4
  - Static assets (pre-compressed): Gzip level 9 or Brotli quality 11
```

## HTTP Compression

HTTP compression uses content negotiation. The client sends `Accept-Encoding` to declare what it supports, and the server responds with `Content-Encoding` to declare what it used.

```
Request:
  GET /api/users HTTP/1.1
  Accept-Encoding: gzip, deflate, br

Response:
  HTTP/1.1 200 OK
  Content-Encoding: gzip
  Content-Type: application/json
  Vary: Accept-Encoding

  [gzip-compressed body]
```

### Building Compression Middleware

```js
'use strict';

const http = require('node:http');
const zlib = require('node:zlib');
const { pipeline } = require('node:stream');
const { Readable } = require('node:stream');

// Parse Accept-Encoding header and pick the best algorithm
function selectEncoding(acceptEncoding) {
  if (!acceptEncoding) return null;

  // Prefer Brotli > Gzip > Deflate
  if (acceptEncoding.includes('br')) return 'br';
  if (acceptEncoding.includes('gzip')) return 'gzip';
  if (acceptEncoding.includes('deflate')) return 'deflate';
  return null;
}

function createCompressor(encoding) {
  switch (encoding) {
    case 'br':
      return zlib.createBrotliCompress({
        params: {
          [zlib.constants.BROTLI_PARAM_QUALITY]: 4, // Fast for dynamic
        },
      });
    case 'gzip':
      return zlib.createGzip({ level: 6 });
    case 'deflate':
      return zlib.createDeflate({ level: 6 });
    default:
      return null;
  }
}

// Types that benefit from compression
const COMPRESSIBLE_TYPES = new Set([
  'text/html',
  'text/css',
  'text/plain',
  'text/xml',
  'application/json',
  'application/javascript',
  'application/xml',
  'image/svg+xml',
]);

function shouldCompress(contentType, contentLength) {
  // Do not compress if payload is too small
  if (contentLength !== undefined && contentLength < 1024) return false;

  // Only compress text-based types
  const baseType = contentType.split(';')[0].trim();
  return COMPRESSIBLE_TYPES.has(baseType);
}

const server = http.createServer((req, res) => {
  // Generate a response body
  const data = JSON.stringify({
    users: Array.from({ length: 200 }, (_, i) => ({
      id: i + 1,
      name: `User ${i + 1}`,
      email: `user${i + 1}@example.com`,
      role: i % 5 === 0 ? 'admin' : 'user',
      createdAt: new Date(Date.now() - i * 86400000).toISOString(),
    })),
  });

  const contentType = 'application/json';
  const acceptEncoding = req.headers['accept-encoding'] || '';
  const encoding = selectEncoding(acceptEncoding);

  if (encoding && shouldCompress(contentType, Buffer.byteLength(data))) {
    const compressor = createCompressor(encoding);

    // Important: remove Content-Length (compressed size differs)
    // and add Content-Encoding + Vary headers
    res.writeHead(200, {
      'Content-Type': contentType,
      'Content-Encoding': encoding,
      'Vary': 'Accept-Encoding',
    });

    // Pipe the data through the compressor to the response
    const readable = Readable.from([data]);
    pipeline(readable, compressor, res, (err) => {
      if (err) console.error('Compression pipeline error:', err);
    });
  } else {
    // No compression — send raw
    res.writeHead(200, {
      'Content-Type': contentType,
      'Content-Length': Buffer.byteLength(data),
    });
    res.end(data);
  }
});

server.listen(3000, () => {
  console.log('Server with compression on http://localhost:3000');
  console.log('Test: curl -H "Accept-Encoding: gzip" -v http://localhost:3000');
});
```

### Testing Compression

```bash
# See compressed response with curl
curl -s -H "Accept-Encoding: gzip" http://localhost:3000 | wc -c
curl -s http://localhost:3000 | wc -c

# Verbose output shows Content-Encoding header
curl -v -H "Accept-Encoding: br, gzip" http://localhost:3000 -o /dev/null
```

## Compressing and Decompressing Buffers in Memory

Sometimes you need to compress data that lives in memory — for caching, for storing in a database, or for embedding in a message.

```js
'use strict';

const zlib = require('node:zlib');
const { promisify } = require('node:util');

const gzip = promisify(zlib.gzip);
const gunzip = promisify(zlib.gunzip);

class CompressedCache {
  constructor() {
    this.store = new Map();
  }

  async set(key, value) {
    const json = JSON.stringify(value);
    const compressed = await gzip(Buffer.from(json), { level: 6 });

    this.store.set(key, compressed);

    const ratio = ((1 - compressed.length / Buffer.byteLength(json)) * 100).toFixed(1);
    console.log(`Cache set: ${key} (${Buffer.byteLength(json)} → ${compressed.length} bytes, ${ratio}% saved)`);
  }

  async get(key) {
    const compressed = this.store.get(key);
    if (!compressed) return undefined;

    const decompressed = await gunzip(compressed);
    return JSON.parse(decompressed.toString());
  }

  has(key) {
    return this.store.has(key);
  }

  // Total memory used by compressed data
  get memoryUsage() {
    let total = 0;
    for (const buf of this.store.values()) {
      total += buf.length;
    }
    return total;
  }
}

// Usage
(async () => {
  const cache = new CompressedCache();

  const largeData = {
    records: Array.from({ length: 1000 }, (_, i) => ({
      id: i,
      timestamp: Date.now(),
      payload: 'x'.repeat(100),
    })),
  };

  await cache.set('report-2026-02', largeData);

  const retrieved = await cache.get('report-2026-02');
  console.log('Records retrieved:', retrieved.records.length);
  console.log('Cache memory:', cache.memoryUsage, 'bytes');
})();
```

## Performance Comparison — Gzip vs Brotli

```js
'use strict';

const zlib = require('node:zlib');
const { promisify } = require('node:util');

const gzip = promisify(zlib.gzip);
const brotliCompress = promisify(zlib.brotliCompress);

async function benchmark(data, label) {
  const buf = Buffer.from(data);
  console.log(`\n--- ${label} (${buf.length} bytes) ---`);

  // Gzip level 6
  const gzipStart = process.hrtime.bigint();
  const gzipped = await gzip(buf, { level: 6 });
  const gzipTime = Number(process.hrtime.bigint() - gzipStart) / 1e6;

  // Brotli quality 4 (fast)
  const br4Start = process.hrtime.bigint();
  const brotli4 = await brotliCompress(buf, {
    params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 4 },
  });
  const br4Time = Number(process.hrtime.bigint() - br4Start) / 1e6;

  // Brotli quality 11 (maximum)
  const br11Start = process.hrtime.bigint();
  const brotli11 = await brotliCompress(buf, {
    params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 },
  });
  const br11Time = Number(process.hrtime.bigint() - br11Start) / 1e6;

  console.log(`  Gzip-6:    ${gzipped.length} bytes in ${gzipTime.toFixed(1)} ms`);
  console.log(`  Brotli-4:  ${brotli4.length} bytes in ${br4Time.toFixed(1)} ms`);
  console.log(`  Brotli-11: ${brotli11.length} bytes in ${br11Time.toFixed(1)} ms`);
}

// Test with different data types
(async () => {
  // JSON data
  const json = JSON.stringify(
    Array.from({ length: 500 }, (_, i) => ({
      id: i, name: `Item ${i}`, value: Math.random(),
    }))
  );
  await benchmark(json, 'JSON Data');

  // Repetitive text
  const text = 'The quick brown fox jumps over the lazy dog. '.repeat(1000);
  await benchmark(text, 'Repetitive Text');

  // Random data (incompressible)
  const random = require('node:crypto').randomBytes(50000).toString('hex');
  await benchmark(random, 'Random Data');
})();
```

## When NOT to Compress

Compression is not always beneficial. Applying it blindly can waste CPU or even increase payload size.

| Scenario | Reason to Skip |
|---|---|
| **Already compressed formats** (JPEG, PNG, MP4, ZIP, GZ) | Re-compressing gains nothing and can increase size |
| **Small payloads** (< 1 KB) | Compression header overhead exceeds savings |
| **Random/encrypted data** | Incompressible by definition — no patterns to exploit |
| **CPU-constrained servers** | Compression consumes CPU; under high load, skip it |
| **WebSocket messages** | Per-message compression exists but adds latency per frame |
| **Streaming real-time data** | Latency from buffering chunks can exceed transfer savings |

```js
'use strict';

const zlib = require('node:zlib');
const { promisify } = require('node:util');
const crypto = require('node:crypto');

const gzip = promisify(zlib.gzip);

async function demonstrateIncompressible() {
  // Already random data — compression makes it LARGER
  const random = crypto.randomBytes(1000);
  const compressed = await gzip(random);

  console.log('Random data:');
  console.log(`  Original:   ${random.length} bytes`);
  console.log(`  Compressed: ${compressed.length} bytes`);
  console.log(`  Result:     ${compressed.length > random.length ? 'LARGER (waste of CPU)' : 'Smaller'}`);

  // Small payload — overhead exceeds savings
  const tiny = Buffer.from('{"ok":true}');
  const tinyCompressed = await gzip(tiny);

  console.log('\nTiny payload:');
  console.log(`  Original:   ${tiny.length} bytes`);
  console.log(`  Compressed: ${tinyCompressed.length} bytes`);
  console.log(`  Result:     ${tinyCompressed.length > tiny.length ? 'LARGER (not worth it)' : 'Smaller'}`);
}

demonstrateIncompressible().catch(console.error);
```

## Flushing Behavior

When compressing streaming data, the compressor may buffer internally for better ratios. You can force a flush to send data immediately — useful for real-time applications.

```js
'use strict';

const zlib = require('node:zlib');

const gzip = zlib.createGzip({ flush: zlib.constants.Z_SYNC_FLUSH });

// Flush constants:
// Z_NO_FLUSH      — default, let the compressor decide when to flush
// Z_SYNC_FLUSH    — flush and align to a byte boundary (decompressor can read so far)
// Z_FULL_FLUSH    — flush and reset state (allows partial decompression)
// Z_FINISH        — signal end of input

// Manual flush example:
gzip.write('First chunk of data\n');
gzip.flush(zlib.constants.Z_SYNC_FLUSH, () => {
  console.log('First chunk flushed');
});

gzip.write('Second chunk of data\n');
gzip.flush(zlib.constants.Z_SYNC_FLUSH, () => {
  console.log('Second chunk flushed');
});

gzip.end();
```

## Key Takeaways

- The `node:zlib` module provides Gzip, Deflate, and Brotli compression through both streaming Transform APIs and one-shot callback APIs
- Use streaming (`createGzip`, `pipeline`) for files and large data; use one-shot (`promisify(zlib.gzip)`) for small, in-memory buffers
- Brotli achieves 5-20% better compression than Gzip for text but is significantly slower at high quality levels — use quality 4-6 for dynamic content, 11 for pre-compressed static assets
- HTTP compression requires `Accept-Encoding` / `Content-Encoding` negotiation and a `Vary: Accept-Encoding` response header
- Skip compression for already-compressed formats, payloads under 1 KB, random/encrypted data, and CPU-constrained environments

## Next

Continue to [Lesson 09 — Security Best Practices](lesson-09-security-best-practices.md), where we bring together everything from this module into a comprehensive security checklist for Node.js applications.
