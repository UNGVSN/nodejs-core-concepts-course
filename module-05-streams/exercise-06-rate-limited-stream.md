# E06: Rate-Limited Stream

## Objective

Build a Transform stream that throttles data throughput to a configurable number of bytes per second. This is useful for simulating slow network connections, rate-limiting API responses, or testing how your application behaves under bandwidth constraints. You will implement precise timing control using `setTimeout` and internal buffering to enforce the rate limit while maintaining correct backpressure semantics.

## Prerequisites

- Module 05 / Lesson 01 — Stream Fundamentals
- Module 05 / Lesson 04 — Backpressure Mechanics
- Module 05 / Lesson 05 — Duplex and Transform Streams
- Module 05 / Lesson 07 — Custom Streams

## Instructions

1. **Create the `RateLimitedTransform` class.** Extend `Transform`. The constructor accepts `bytesPerSecond` — the maximum throughput allowed.

```js
'use strict';

const { Transform } = require('node:stream');

class RateLimitedTransform extends Transform {
  constructor(bytesPerSecond) {
    super();
    this.bytesPerSecond = bytesPerSecond;
    this.bytesThisSecond = 0;
    this.windowStart = Date.now();
  }
}
```

2. **Implement `_transform()`.** When a chunk arrives, check if forwarding it would exceed the rate limit for the current time window. If the chunk fits within the budget, push it immediately and update the counter. If it would exceed the limit, split the chunk: push as many bytes as the budget allows, then use `setTimeout` to delay the remainder until the next time window.

3. **Handle the time window.** Use a sliding window approach: track when the current second started (`windowStart`). When `Date.now() - windowStart >= 1000`, reset `bytesThisSecond` to 0 and update `windowStart`. This gives you a fresh budget each second.

4. **Handle large chunks.** If a single chunk is larger than `bytesPerSecond`, it must be split across multiple seconds. Implement a recursive or iterative approach that pushes `bytesPerSecond` bytes, waits one second, pushes the next batch, and so on. Only call `callback()` once the entire chunk has been forwarded.

5. **Build a test harness.** Create a fast Readable that generates 10 MB of data. Pipe it through `RateLimitedTransform` set to 1 MB/s, then to a Writable that counts received bytes. Log actual throughput every second to verify the rate limit is enforced.

```js
'use strict';

const { Readable, Writable, pipeline } = require('node:stream');

const RATE = parseRate(process.argv[2] || '1m');
const TOTAL = 10 * 1024 * 1024;  // 10 MB

class DataProducer extends Readable {
  constructor(totalBytes) {
    super({ highWaterMark: 64 * 1024 });
    this.remaining = totalBytes;
  }

  _read(size) {
    const chunkSize = Math.min(size, this.remaining);
    if (chunkSize <= 0) { this.push(null); return; }
    this.push(Buffer.alloc(chunkSize, 0x42));
    this.remaining -= chunkSize;
  }
}

class ByteCounter extends Writable {
  constructor() {
    super();
    this.totalBytes = 0;
    this.bytesThisSecond = 0;
    this.secondCount = 0;
    this.interval = setInterval(() => this._report(), 1000);
  }

  _write(chunk, encoding, callback) {
    this.totalBytes += chunk.length;
    this.bytesThisSecond += chunk.length;
    callback();
  }

  _final(callback) {
    clearInterval(this.interval);
    callback();
  }

  _report() {
    this.secondCount++;
    const mbps = (this.bytesThisSecond / 1024 / 1024).toFixed(2);
    console.log(`  Second ${this.secondCount}: ${this.bytesThisSecond} bytes (${mbps} MB/s)`);
    this.bytesThisSecond = 0;
  }
}

pipeline(
  new DataProducer(TOTAL),
  new RateLimitedTransform(RATE),
  new ByteCounter(),
  (err) => {
    if (err) console.error('Error:', err.message);
    else console.log('Transfer complete.');
  }
);
```

6. **Measure accuracy.** Every second, compute the actual bytes transferred. The actual rate should be within 5% of the target rate. Print both target and actual rates for comparison. After the transfer completes, compute and display the overall average rate and the percentage error from the target.

7. **Support dynamic rate changes.** Add a `setRate(newBytesPerSecond)` method that changes the limit mid-stream. The method should reset the current time window to prevent stale budget calculations. Demonstrate it by starting at 512 KB/s, switching to 2 MB/s after 3 seconds, then dropping to 256 KB/s after 6 seconds. Log the rate changes and show that throughput adjusts accordingly.

8. **Add a `--rate` CLI flag.** Accept human-readable rates like `500k`, `2m`, `10m`. Parse the suffix and convert to bytes per second.

```js
function parseRate(str) {
  const match = str.match(/^(\d+(?:\.\d+)?)\s*([kmg])?$/i);
  if (!match) { console.error('Invalid rate:', str); process.exit(1); }
  const num = parseFloat(match[1]);
  const suffix = (match[2] || '').toLowerCase();
  const multipliers = { '': 1, 'k': 1024, 'm': 1024 * 1024, 'g': 1024 * 1024 * 1024 };
  return Math.floor(num * multipliers[suffix]);
}
```

9. **Verify data integrity.** Hash the output of the rate-limited stream with SHA-256 and compare it to the hash of the original data. Rate limiting must never corrupt data — every byte must pass through unchanged, just slower.

## Break-Then-Harden Challenge

1. **Call `callback()` before the delayed data is pushed.** This tells the upstream that you are ready for more data, but you have not finished processing the current chunk. The result: data arrives faster than the rate limit allows, defeating the purpose. Fix by only calling `callback()` after all bytes from the chunk have been pushed.

2. **Forget to reset the time window.** Without resetting `bytesThisSecond`, the rate limiter permanently blocks after the first second. The stream hangs. Add the window reset logic and verify the stream continues flowing.

3. **Set the rate to 1 byte per second.** This extreme setting takes forever to transfer even a small file. It stress-tests your timing precision and chunk-splitting logic. Verify that the data is still correct (byte-perfect) at the output, just very slow.

## Expected Output

```
Rate limiter: 1,048,576 bytes/sec (1.0 MB/s)
Source: 10,485,760 bytes (10.0 MB)

  Second 1:  1,048,491 bytes (1.00 MB/s) — target: 1.00 MB/s ✓
  Second 2:  1,048,802 bytes (1.00 MB/s) — target: 1.00 MB/s ✓
  Second 3:  1,048,210 bytes (1.00 MB/s) — target: 1.00 MB/s ✓
  Second 4:  1,048,693 bytes (1.00 MB/s) — target: 1.00 MB/s ✓
  Second 5:  1,048,576 bytes (1.00 MB/s) — target: 1.00 MB/s ✓
  Second 6:  1,048,401 bytes (1.00 MB/s) — target: 1.00 MB/s ✓
  Second 7:  1,048,288 bytes (1.00 MB/s) — target: 1.00 MB/s ✓
  Second 8:  1,048,576 bytes (1.00 MB/s) — target: 1.00 MB/s ✓
  Second 9:  1,048,719 bytes (1.00 MB/s) — target: 1.00 MB/s ✓
  Second 10: 1,053,004 bytes (1.00 MB/s) — target: 1.00 MB/s ✓

Transfer complete.
  Total bytes:  10,485,760
  Duration:     10.02s
  Avg rate:     1,046,483 bytes/s (0.998 MB/s)
  Rate error:   0.2%
```

## Bonus

1. **Burst mode.** Add a `burstBytes` option that allows the first N bytes to pass through unrestricted before the rate limit kicks in. This mimics real network behavior where TCP slow-start allows initial bursts.

2. **Token bucket algorithm.** Replace the simple time-window approach with a token bucket: tokens accumulate at `bytesPerSecond` rate, up to a maximum bucket size. Each byte consumes one token. When the bucket is empty, the stream waits. This produces smoother throughput than the window approach.

## Hints

1. `setTimeout` in `_transform` means you must delay calling `callback()` until after the timeout fires. The stream will naturally apply backpressure to the producer during this delay because the Transform is not signaling readiness.

2. To split a chunk: `const head = chunk.subarray(0, budget);` and `const tail = chunk.subarray(budget);`. Push `head` immediately, then schedule `tail` for the next window.

3. For human-readable rate parsing, check the last character: `k` or `K` means multiply by 1024, `m` or `M` means multiply by 1024 * 1024.

4. `Date.now()` has millisecond resolution, which is sufficient for rate limiting at the KB/s to MB/s range. For sub-millisecond precision, use `process.hrtime.bigint()`.

5. Do not use `setInterval` for the core timing. Instead, use `setTimeout` inside `_transform` to delay each chunk as needed. `setInterval` does not integrate cleanly with the stream callback mechanism.
