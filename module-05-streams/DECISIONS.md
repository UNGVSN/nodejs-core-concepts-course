# Module 05 — Streams: Production Decisions

> Streams are the most powerful abstraction in Node.js and the easiest to get wrong. One missed `drain` event and your server eats 4GB of RAM before anyone notices. This document captures the decisions that separate working prototypes from production systems.

---

## Decision 1: `pipe()` vs `pipeline()` — Error Handling

**Context:**
`.pipe()` has existed since Node.js v0.x and is the classic way to chain streams. `stream.pipeline()` was added in v10 and fixes the biggest problem with `.pipe()`: error handling. With `.pipe()`, if the source stream errors, the destination is not automatically destroyed — it leaks. `pipeline()` destroys all streams in the chain when any stream errors.

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| `.pipe()` | Simple syntax, chainable | Does not propagate errors; destination stream leaks on source error; no cleanup |
| `stream.pipeline(callback)` | Automatic error propagation, destroys all streams on failure | Callback-based API feels dated |
| `stream.pipeline` (promise) | `require('node:stream/promises').pipeline` — clean `async/await` | Requires Node.js v15+ for the promise variant |
| `.pipe()` with manual error listeners | Full control over error handling | Verbose, easy to miss an error listener on one stream in the chain |

**Recommendation:**
Always use `stream.pipeline` from `node:stream/promises` in new code. The promise-based variant integrates cleanly with `async/await` and handles every cleanup scenario. Reserve `.pipe()` only for quick one-off scripts where you do not care about error recovery. If you must support Node.js < 15, use the callback-based `pipeline` from `node:stream`.

---

## Decision 2: `highWaterMark` Tuning

**Context:**
Every stream has a `highWaterMark` — the threshold at which the internal buffer is considered "full." For byte streams, the default is 16KB (16,384 bytes). For object-mode streams, the default is 16 objects. This value directly controls memory usage and throughput.

**Trade-offs:**

| highWaterMark | Throughput | Memory | Latency |
|---------------|------------|--------|---------|
| Small (1KB) | Lower (more syscalls) | Minimal | Low (data flows immediately) |
| Default (16KB) | Balanced | Moderate | Moderate |
| Large (1MB) | Higher (fewer syscalls, better disk/network batching) | High per stream | Higher (data buffered before flowing) |
| Very large (16MB+) | Diminishing returns | Dangerous with many concurrent streams | Significant buffering delay |

**Recommendation:**
Stick with the 16KB default for most use cases. Increase to 64KB-256KB for file streaming and network transfers where throughput matters more than latency. For HTTP response streaming where time-to-first-byte matters, consider lowering to 4KB-8KB. Never go above 1MB without benchmarking — at 10,000 concurrent streams, a 1MB `highWaterMark` reserves 10GB of potential buffer space. The right value is always workload-specific; profile with real data.

---

## Decision 3: Object Mode Trade-offs

**Context:**
By default, streams operate on Buffers and strings. Object mode (`objectMode: true`) allows streams to pass arbitrary JavaScript objects. This is powerful for transform pipelines (e.g., CSV row objects, parsed log entries) but changes backpressure semantics: `highWaterMark` counts objects, not bytes. A single object could be 1 byte or 10MB.

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| Object mode | Natural for structured data; no manual serialization | Backpressure is based on count, not size — 16 large objects could exhaust memory |
| Byte mode with serialization | Predictable memory; backpressure based on actual bytes | Must serialize/deserialize at boundaries; more boilerplate |
| Hybrid (object mode with size tracking) | Best of both; manually check size and cork when too large | Complex implementation; easy to get wrong |

**Recommendation:**
Use object mode for internal transform pipelines where you control the object size (parsed CSV rows, log lines, database records). Avoid object mode when objects have unbounded size (e.g., arrays of variable-length strings, nested documents). If you use object mode, set `highWaterMark` to a conservative value (4-8 objects) and monitor heap usage. For cross-process or cross-network streaming, always use byte mode with explicit framing.

---

## Decision 4: When to Use Streams vs `readFile`

**Context:**
Developers new to Node.js default to `readFile` for everything because the API is simpler. But `readFile` loads the entire file into memory, which is dangerous when file sizes are unpredictable or when serving many concurrent requests.

**Trade-offs:**

| Scenario | `readFile` | `createReadStream` |
|----------|------------|-------------------|
| Config files (< 100KB) | Appropriate — simple, fast, one-time | Overkill — adds complexity for no benefit |
| HTTP response (unknown size) | Dangerous — one 2GB request kills the process | Correct — constant memory regardless of size |
| Template rendering | Fine if templates are small and cached | Unnecessary unless templates are large or generated |
| Log processing (1GB+) | Out of memory guaranteed | The only viable option |
| JSON parsing | Required — `JSON.parse` needs the full string | Cannot parse incrementally without a streaming JSON parser |

**Recommendation:**
Use `readFile` for files you know are small AND where you need the entire content at once (config, templates, small JSON). Use `createReadStream` for everything else, especially: HTTP file serving, log processing, file copying, and any path where the file size comes from user input. When in doubt, stream. The small overhead of stream setup is nothing compared to the cost of an out-of-memory crash at 3 AM.

---

## Decision 5: `stream.compose()` vs Manual Piping

**Context:**
`stream.compose()` (added in Node.js v16.9 as experimental, stable in v21) takes multiple streams and returns a single Duplex stream. It replaces manual `pipeline(a, b, c)` chains with composable, reusable stream segments. But it is newer and less battle-tested.

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| `pipeline(a, b, c)` | Battle-tested, widely understood, automatic cleanup | Not composable — the pipeline is a side effect, not a stream you can pass around |
| `stream.compose(a, b, c)` | Returns a reusable Duplex; composable like Unix pipes | Newer API, experimental in some Node.js versions; less documentation |
| Manual `.pipe()` chains | Maximum control | No automatic error propagation; must manage cleanup manually |

**Recommendation:**
Use `pipeline` as your default for one-shot stream chains (e.g., read file, compress, write). Use `compose` when you need to build reusable stream segments that you pass as arguments (e.g., a "compression + encryption" segment you plug into different pipelines). Check your target Node.js version — `compose` requires v16.9+ and was not marked stable until v21. For Node.js < 16.9, stick with `pipeline`.

---

## Decision 6: Async Iteration vs Event-Based Consumption

**Context:**
Readable streams support `for await (const chunk of stream)` syntax since Node.js v10. This is cleaner than listening for `data` events, but it changes how backpressure works and has subtle behavior differences.

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| `for await...of` | Clean syntax, automatic backpressure, no manual event wiring | Locks the stream to a single consumer; errors throw (must try/catch) |
| `stream.on('data')` + `stream.on('end')` | Maximum flexibility, multiple listeners possible | Manual backpressure handling; easy to forget `error` listener |
| `stream.read()` in paused mode | Pull-based; you control exactly when data is consumed | Most verbose; rarely needed outside custom stream implementations |

**Recommendation:**
Use `for await...of` as your default for consuming Readable streams. It handles backpressure automatically (pausing the stream when the loop body is doing async work) and reads clearly. Fall back to event-based consumption when you need multiple concurrent consumers on the same stream, or when you need to dynamically pause/resume based on external signals. The `read()` pull API is rarely needed outside of custom `_read` implementations.
