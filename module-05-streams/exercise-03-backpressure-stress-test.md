# E03: Backpressure Stress Test

## Objective

Demonstrate why backpressure matters by first building a pipeline that ignores it — watching memory explode — and then fixing it with proper `drain` handling. You will measure memory at regular intervals to produce hard evidence of the difference. This exercise turns an abstract concept into a visceral, measurable reality.
Backpressure is the single most important concept in Node.js stream programming.

## Prerequisites

- Module 05 / Lesson 01 — Stream Fundamentals
- Module 05 / Lesson 03 — Writable Streams
- Module 05 / Lesson 04 — Backpressure Mechanics
- Module 05 / Lesson 06 — Piping and Pipeline

## Instructions

1. **Create a fast producer.** Write a custom Readable stream (`FastProducer`) that generates 5 million chunks of 1 KB each (total: ~5 GB of data). Each chunk is a `Buffer.alloc(1024, 0x41)` (filled with `'A'`). In `_read()`, push chunks as fast as possible.

```js
'use strict';

const { Readable } = require('node:stream');

class FastProducer extends Readable {
  constructor(totalChunks) {
    super({ highWaterMark: 16 * 1024 });
    this.totalChunks = totalChunks;
    this.sent = 0;
  }

  _read() {
    if (this.sent >= this.totalChunks) {
      this.push(null);
      return;
    }
    this.push(Buffer.alloc(1024, 0x41));
    this.sent++;
  }
}
```

2. **Create a slow consumer.** Write a custom Writable stream (`SlowConsumer`) that introduces a 1 ms delay per write using `setTimeout`. This simulates a slow disk, database, or network endpoint.

```js
const { Writable } = require('node:stream');

class SlowConsumer extends Writable {
  constructor() {
    super({ highWaterMark: 16 * 1024 });
    this.received = 0;
  }

  _write(chunk, encoding, callback) {
    this.received++;
    setTimeout(callback, 1);  // simulate slow I/O
  }
}
```

3. **Build the BROKEN version (`no-backpressure.js`).** Connect producer to consumer using a manual loop that ignores the return value of `writable.write()`. Push chunks in a tight `while` loop without waiting for `'drain'`.

```js
const producer = new FastProducer(500_000);
const consumer = new SlowConsumer();

producer.on('data', (chunk) => {
  consumer.write(chunk);  // IGNORING return value — bad!
});
```

4. **Monitor memory.** Use `setInterval` every 500 ms to log `process.memoryUsage().rss` in MB. You will see RSS climb to hundreds of megabytes (or even gigabytes) as the internal write buffer grows without bound.

5. **Build the FIXED version (`with-backpressure.js`).** Respect the return value of `write()`. When it returns `false`, call `producer.pause()` and wait for the `'drain'` event before calling `producer.resume()`.

```js
producer.on('data', (chunk) => {
  const ok = consumer.write(chunk);
  if (!ok) {
    producer.pause();
    consumer.once('drain', () => producer.resume());
  }
});
```

6. **Build the PIPELINE version (`pipeline-version.js`).** Replace the manual wiring with `require('node:stream').pipeline(producer, consumer, callback)`. This handles backpressure automatically.

7. **Collect and compare results.** Run all three versions and record peak RSS, chunks processed per second, and total duration. Print a comparison table at the end.

8. **Add a memory limit test.** Run the broken version with `--max-old-space-size=128` and observe it crash with a heap out-of-memory error. Run the fixed version with the same flag and watch it complete successfully. This simulates a container with constrained memory — exactly the environment where backpressure bugs cause real production outages.

## Break-Then-Harden Challenge

1. **Set SlowConsumer's `highWaterMark` to 1.** This makes the consumer signal backpressure after a single chunk. In the broken version, the buffer grows even faster. In the fixed version, the producer pauses after nearly every write. Compare throughput and memory for `highWaterMark` values of 1, 1024, and 65536.

2. **Remove the `setTimeout` from SlowConsumer.** Make it synchronous. Now the broken version might actually work (because the consumer keeps up). This teaches that backpressure bugs only manifest when there is a genuine speed mismatch — the scariest kind of bug because it hides during testing and explodes in production.

3. **Introduce an error mid-stream.** After 100,000 chunks, have `SlowConsumer._write` call `callback(new Error('disk full'))`. In the manual version, the error is swallowed — the producer keeps sending data into a broken consumer. In the `pipeline()` version, the error propagates cleanly and all streams are destroyed. Add error handling to the manual version to match: listen for `'error'` on the consumer and call `producer.destroy()` when it fires.

4. **Vary the delay duration.** Run the fixed version with `setTimeout` delays of 0 ms, 1 ms, 5 ms, and 50 ms. Measure throughput and memory for each. This shows that backpressure overhead scales with the consumer's speed — not the producer's.

## Expected Output

```
=== No Backpressure (BROKEN) ===
  0.5s — RSS: 48 MB   | chunks: 12,400
  1.0s — RSS: 127 MB  | chunks: 24,100
  1.5s — RSS: 241 MB  | chunks: 35,600
  2.0s — RSS: 389 MB  | chunks: 47,200
  2.5s — RSS: 502 MB  | chunks: 58,800
  [Killed — out of memory at ~512 MB]

=== With Backpressure (FIXED) ===
  0.5s — RSS: 22 MB   | chunks: 490
  1.0s — RSS: 22 MB   | chunks: 982
  1.5s — RSS: 23 MB   | chunks: 1,471
  2.0s — RSS: 22 MB   | chunks: 1,960
  ...
  Final — RSS: 23 MB  | chunks: 500,000
  Duration: ~8 min (slow consumer is the bottleneck)

=== Pipeline Version ===
  Final — RSS: 23 MB  | chunks: 500,000
  Duration: ~8 min (same as fixed — pipeline just automates it)

Comparison:
  Version          | Peak RSS | Throughput    | Completed
  No Backpressure  | 502+ MB  | 23,500 ch/s   | NO (OOM)
  With Backpressure| 23 MB    | 980 ch/s      | YES
  Pipeline         | 23 MB    | 980 ch/s      | YES
```

## Bonus

1. **Graph the results.** Write RSS measurements to a CSV file (`timestamp_ms,rss_mb`) for each version. You can plot these in any spreadsheet or charting tool to visualize the memory trajectories.

2. **Add a Transform in the middle.** Insert a Transform stream between producer and consumer that computes a rolling checksum. Verify that backpressure propagates through three stages, not just two.

## Hints

1. `writable.write(chunk)` returns `false` when the internal buffer exceeds `highWaterMark`. This is your signal to stop pushing data. It does not mean the write failed — the data is still queued internally. The data will eventually be processed, but the buffer keeps growing.

2. The `'drain'` event fires once the internal buffer has been flushed below `highWaterMark`. Only resume the producer when you receive this event. Do not resume on a timer or after a fixed number of writes — let the consumer tell you when it is ready.

3. `pipeline()` does all the pause/resume/drain wiring internally. It also destroys all streams if any stage errors — something manual piping does not do. This is why `pipeline()` is always preferred over `.pipe()` in production code.

4. Use `process.memoryUsage().rss` (Resident Set Size) rather than `heapUsed` for the most accurate picture of total process memory. RSS includes the heap, stack, and memory-mapped files. `heapUsed` only shows V8 heap objects and misses Buffer allocations that live outside the heap.

5. To make the comparison fair, reduce `totalChunks` to 500,000 for the broken version (otherwise it may crash before producing useful data). Use the same count for all three versions.

6. If the broken version does not OOM on your machine (you have too much RAM), reduce `--max-old-space-size` to 128 MB or 64 MB to force the crash. This simulates a container environment with limited memory — which is where backpressure bugs cause real outages.
