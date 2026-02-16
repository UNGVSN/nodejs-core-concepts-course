# E04: Compression Benchmark

## Objective

Compare the three compression algorithms available in Node.js core — gzip, deflate, and brotli — across multiple dimensions: compression ratio, compression speed, decompression speed, and memory usage. Test each algorithm against different file types (English text, structured JSON, random binary) and at multiple compression levels. Present results in a formatted table that exposes the real-world engineering tradeoffs behind choosing a compression strategy for HTTP responses, file storage, and data transfer.

## Prerequisites

- Module 10 / Lesson 08 — Zlib Compression (gzip, deflate, brotli)
- Module 03 — Buffers & Binary Data (Buffer operations)

## Instructions

1. **Create `compression-benchmark.js`** with `'use strict';` at the top. Require:

```javascript
'use strict';

const zlib   = require('node:zlib');
const fs     = require('node:fs');
const crypto = require('node:crypto');
const path   = require('node:path');
const { performance } = require('node:perf_hooks');
```

2. **Generate test data.** Write a `generateTestData()` function that creates three 1 MB files in a `./bench-data/` directory:

```javascript
function generateTestData() {
  const dir = path.join(__dirname, 'bench-data');
  fs.mkdirSync(dir, { recursive: true });

  // 1. Repeated English prose (highly compressible)
  const paragraph = 'The quick brown fox jumps over the lazy dog. ' +
    'Pack my box with five dozen liquor jugs. ' +
    'How vexingly quick daft zebras jump. ';
  const textSize = 1024 * 1024;
  let text = '';
  while (text.length < textSize) text += paragraph;
  fs.writeFileSync(path.join(dir, 'text.txt'), text.slice(0, textSize));

  // 2. Structured JSON (moderately compressible — repeated keys, varied values)
  const records = [];
  for (let i = 0; i < 5000; i++) {
    records.push({
      id: i, name: `user_${i}`,
      email: `user${i}@example.com`,
      address: `${i} Main Street, City ${i % 100}`,
      timestamp: new Date(Date.now() - i * 60000).toISOString()
    });
  }
  const jsonStr = JSON.stringify(records, null, 2);
  fs.writeFileSync(path.join(dir, 'data.json'), jsonStr.slice(0, textSize));

  // 3. Random bytes (incompressible — control group)
  fs.writeFileSync(path.join(dir, 'random.bin'), crypto.randomBytes(textSize));
}
```

3. **Create promisified compression helpers.** Wrap each callback-based zlib function in a Promise:

```javascript
function compress(algorithm, buffer, options = {}) {
  return new Promise((resolve, reject) => {
    zlib[algorithm](buffer, options, (err, result) => {
      err ? reject(err) : resolve(result);
    });
  });
}

function decompress(algorithm, buffer, options = {}) {
  return new Promise((resolve, reject) => {
    zlib[algorithm](buffer, options, (err, result) => {
      err ? reject(err) : resolve(result);
    });
  });
}
```

The algorithm names map to: `'gzip'`/`'gunzip'`, `'deflate'`/`'inflate'`, `'brotliCompress'`/`'brotliDecompress'`.

4. **Define the benchmark matrix.** Test these combinations:

```javascript
const algorithms = [
  { name: 'gzip',    compress: 'gzip',           decompress: 'gunzip',            levelKey: 'level',  levels: [1, 6, 9] },
  { name: 'deflate', compress: 'deflate',         decompress: 'inflate',           levelKey: 'level',  levels: [1, 6, 9] },
  { name: 'brotli',  compress: 'brotliCompress',  decompress: 'brotliDecompress',  levelKey: 'params', levels: [1, 6, 11] }
];

const files = ['text.txt', 'data.json', 'random.bin'];
```

For gzip/deflate, pass `{ level: N }`. For brotli, pass `{ params: { [zlib.constants.BROTLI_PARAM_QUALITY]: N } }`.

5. **Run the benchmarks.** For each `(algorithm, level, file)` combination:
   - Read the file into a Buffer
   - Run 5 compression iterations, average the time with `performance.now()`
   - Record compressed size
   - Run 5 decompression iterations, average the time
   - Verify correctness: `Buffer.compare(decompressed, original) === 0`
   - Record RSS memory before and after with `process.memoryUsage().rss`

```javascript
async function benchmark(algo, level, buffer) {
  const options = algo.levelKey === 'level'
    ? { level }
    : { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: level } };

  const RUNS = 5;
  let compressedBuf;
  let compressTime = 0;
  for (let i = 0; i < RUNS; i++) {
    const start = performance.now();
    compressedBuf = await compress(algo.compress, buffer, options);
    compressTime += performance.now() - start;
  }
  compressTime /= RUNS;

  let decompressTime = 0;
  let decompressedBuf;
  for (let i = 0; i < RUNS; i++) {
    const start = performance.now();
    decompressedBuf = await decompress(algo.decompress, compressedBuf);
    decompressTime += performance.now() - start;
  }
  decompressTime /= RUNS;

  const valid = Buffer.compare(decompressedBuf, buffer) === 0;
  return { compressedSize: compressedBuf.length, compressTime, decompressTime, valid };
}
```

6. **Print the results table.** Format output as a fixed-width aligned table with columns: Algorithm, Level, File, Original, Compressed, Ratio, Compress (ms), Decompress (ms), Valid. Use `String.prototype.padStart()` and `padEnd()` for alignment.

7. **Print the summary.** After the table, draw conclusions:
   - Best compression ratio for text
   - Fastest compression for text
   - Whether random data is compressible (it is not)
   - The brotli tradeoff: brotli-11 gives the best ratio but is 10-50x slower than gzip-1
   - A recommendation: brotli levels 4-6 for static assets (pre-compressed at build time), gzip-6 for dynamic HTTP responses (compressed per-request)

8. **Handle edge cases.** If a compressed result is larger than the original (common with random data), display the ratio as `1.00x` and flag it with `(expansion)` in the notes.

## Break-Then-Harden Challenge

### Scenario 1 — Compression Bomb

Create a 100-byte file of repeated `'A'` characters. Compress it — observe an extreme ratio (maybe 1000:1). Then consider the reverse: craft a 1 KB gzip payload that decompresses to 1 GB. Protect against this "zip bomb" by setting `maxOutputLength` in the decompress options: `zlib.gunzip(buf, { maxOutputLength: 10 * 1024 * 1024 }, cb)`. Verify that exceeding the limit throws `ERR_BUFFER_TOO_LARGE`.

### Scenario 2 — Wrong Decompression Algorithm

Compress a buffer with gzip. Try to decompress with `zlib.inflate()` (deflate decompressor). Observe the `incorrect header check` error because gzip and raw deflate have different framing. Fix it by storing the algorithm name alongside compressed data (e.g., a 1-byte prefix: `0x01` for gzip, `0x02` for deflate, `0x03` for brotli) or using the file extension convention (`.gz`, `.zz`, `.br`).

### Scenario 3 — Invalid Compression Level

Pass level 15 to `zlib.gzip()` (valid range is `zlib.constants.Z_NO_COMPRESSION` (0) through `zlib.constants.Z_BEST_COMPRESSION` (9)). Observe the `Invalid compression level` error. Fix it by validating the level before compression, clamping to the valid range, and printing a warning: `"Level 15 out of range [0-9], clamped to 9"`.

## Expected Output

```
$ node compression-benchmark.js

Generating test data (1 MB each)...
  text.txt:    1,048,576 bytes (repeated English prose)
  data.json:   1,048,576 bytes (structured JSON, 5000 records)
  random.bin:  1,048,576 bytes (cryptographic random)

Running benchmarks (5 iterations each, 27 combinations)...

Algorithm  | Level | File       | Original  | Compressed | Ratio  | Comp ms | Decomp ms | Valid
-----------|-------|------------|-----------|------------|--------|---------|-----------|------
gzip       |     1 | text.txt   | 1,048,576 |    105,231 |  9.96x |     8.4 |       3.2 | YES
gzip       |     6 | text.txt   | 1,048,576 |     82,147 | 12.76x |    24.1 |       3.0 | YES
gzip       |     9 | text.txt   | 1,048,576 |     79,892 | 13.12x |    47.3 |       2.9 | YES
deflate    |     1 | text.txt   | 1,048,576 |    105,213 |  9.97x |     7.9 |       2.8 | YES
deflate    |     6 | text.txt   | 1,048,576 |     82,129 | 12.77x |    23.4 |       2.7 | YES
deflate    |     9 | text.txt   | 1,048,576 |     79,874 | 13.13x |    46.1 |       2.6 | YES
brotli     |     1 | text.txt   | 1,048,576 |     97,408 | 10.76x |    11.2 |       2.1 | YES
brotli     |     6 | text.txt   | 1,048,576 |     68,224 | 15.37x |    42.8 |       1.9 | YES
brotli     |    11 | text.txt   | 1,048,576 |     61,440 | 17.07x |   892.4 |       1.8 | YES
gzip       |     6 | data.json  | 1,048,576 |     94,720 | 11.07x |    22.3 |       3.4 | YES
...
gzip       |     6 | random.bin | 1,048,576 |  1,048,893 |  1.00x |    31.2 |       5.1 | YES (expansion)
brotli     |     6 | random.bin | 1,048,576 |  1,048,640 |  1.00x |    18.7 |       2.3 | YES (expansion)

--- Conclusions ---
Best ratio (text):       brotli level 11 (17.07x) — but 106x slower than gzip level 1
Best speed (text):       deflate level 1 (7.9 ms) — 13% less compression vs gzip-9
Best decompression:      brotli (1.8 ms) — fastest regardless of compression level
Random data:             Incompressible — all algorithms expand output by ~300 bytes (headers)
Recommendation:          brotli 4-6 for static assets, gzip 6 for dynamic HTTP responses
```

## Bonus

1. **Streaming benchmark.** Instead of buffered `zlib.gzip(buffer, cb)`, use streaming via `stream.pipeline(readable, zlib.createGzip({ level }), writable)`. Compare throughput in MB/s for a 100 MB file. Determine whether streaming is faster or slower than buffered for large inputs (streaming avoids loading the entire file into memory at once).

2. **HTTP content negotiation.** Create a small HTTP server that serves a large JSON response. Parse the `Accept-Encoding` header and respond with the best supported algorithm (prefer brotli over gzip over identity). Set the `Content-Encoding` header. Measure response sizes with: `curl -H "Accept-Encoding: gzip" -o /dev/null -w '%{size_download}\n' http://localhost:3000/data`.

## Hints

1. Wrap callback-based zlib: `new Promise((resolve, reject) => zlib.gzip(buf, opts, (err, result) => err ? reject(err) : resolve(result)))`.

2. Brotli options use a different structure: `{ params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 6 } }` instead of `{ level: 6 }`. The constant name is `BROTLI_PARAM_QUALITY`, not `level`.

3. `Buffer.compare(a, b) === 0` is a fast, allocation-free way to verify two Buffers are byte-for-byte identical.

4. Random data is incompressible because compression algorithms exploit patterns and repetition — cryptographic random data has neither. The compressed output will be slightly larger due to format headers and framing overhead.

5. Brotli quality 11 is designed for offline/static asset precompression where speed does not matter. For real-time HTTP compression, brotli 3-6 provides excellent ratio with acceptable latency. Never use brotli 11 for dynamic responses — it can take seconds per megabyte.
