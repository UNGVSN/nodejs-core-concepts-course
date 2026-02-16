# Module 09 — Multi-Threading & Performance: Production Decisions

> Threads are powerful, but they are not free. Every decision here trades simplicity against performance, safety against speed. Get them wrong and you introduce bugs that only manifest under load at 3 AM.

---

## Decision 01: `worker_threads` vs `child_process` vs `cluster`

**Context:** Node.js offers three parallelism models: `worker_threads` (threads sharing process memory), `child_process` (separate processes with IPC), and `cluster` (specialized child processes sharing a server port). Choosing the wrong one wastes resources or adds unnecessary complexity.

**Trade-offs:**

| Factor | `worker_threads` | `child_process` | `cluster` |
|--------|-----------------|-----------------|-----------|
| Memory overhead | Low — shared V8 isolate memory | High — full V8 heap per process | High — full V8 heap per worker |
| Startup time | Fast (~5-15ms) | Slow (~30-100ms) | Slow (~30-100ms) |
| Shared memory | Yes — `SharedArrayBuffer` | No | No |
| Crash isolation | Thread crash can destabilize process | Full isolation — child crash is contained | Full isolation |
| Communication | `postMessage` + shared memory | IPC `send()`/`on('message')` | IPC `send()`/`on('message')` |
| Use case | CPU-bound computation, parallel algorithms | Shell commands, untrusted code, separate runtimes | Multi-core HTTP serving |
| Debugging | Harder — shared state bugs | Easier — isolated state | Easier — isolated state |

**Recommendation:** Use `worker_threads` for CPU-bound computation within your application (hashing, image processing, data transformation). Use `child_process` when you need full isolation (running untrusted code, calling non-Node executables). Use `cluster` specifically for scaling HTTP servers across cores. If your workload is I/O-bound, you probably need none of these — the event loop already handles concurrent I/O efficiently.

---

## Decision 02: `SharedArrayBuffer` Security Implications

**Context:** `SharedArrayBuffer` enables zero-copy shared memory between threads, but it was disabled in browsers after the Spectre CPU vulnerability (2018). Node.js kept it enabled, but the security implications are real: any thread can read any byte of shared memory, and timing attacks via `SharedArrayBuffer` can leak data from other memory regions.

**Trade-offs:**

| Factor | SharedArrayBuffer enabled | Message passing only |
|--------|--------------------------|---------------------|
| Performance | Zero-copy, microsecond access | Copy per message (~50-100us overhead) |
| Security | Spectre-class side channels possible | Fully isolated — no shared state |
| Correctness | Race conditions, ordering bugs | No data races — messages are atomic |
| Debugging | Extremely difficult — heisenbugs | Straightforward — deterministic message order |
| Browser compat | Requires COOP/COEP headers | Works everywhere |
| Code complexity | Manual Atomics, memory layout | Simple send/receive API |

**Recommendation:** Default to message passing via `postMessage`. Only use `SharedArrayBuffer` when profiling proves that serialization is a bottleneck — typically this means over 100,000 messages per second or large binary data (images, audio buffers). When you do use it, limit the shared region to a well-defined struct (counters, ring buffers) and access it exclusively through `Atomics` operations. Never store sensitive data (passwords, tokens) in shared memory.

---

## Decision 03: Thread Pool Sizing

**Context:** A thread pool needs a fixed size. Too few threads and you under-utilize CPUs. Too many and you waste memory on idle threads and increase context-switching overhead. The ideal size depends on whether the work is CPU-bound or mixed.

**Trade-offs:**

| Pool size | CPU count | CPU count * 2 | Fixed (e.g., 4) |
|-----------|-----------|--------------|-----------------|
| CPU-bound tasks | Optimal — one thread per core | Wasteful — threads compete for cores | Under-utilizes on large machines |
| Mixed I/O + CPU | Under-utilizes — threads idle during I/O | Better utilization during I/O waits | Predictable but not adaptive |
| Memory cost | Moderate | High — each thread has V8 overhead | Fixed and predictable |
| Latency | Low contention | Higher contention on CPU-bound work | Depends on workload |
| Scaling | Scales with hardware | Scales with hardware | Does not scale |

**Recommendation:** For pure CPU-bound work (hashing, compression, math), set pool size to `os.cpus().length` — one thread per physical core. For mixed workloads with some I/O waiting, use `os.cpus().length + 1` to keep one thread ready while others wait. Note that Node.js's internal libuv thread pool (default size 4, max 1024 via `UV_THREADPOOL_SIZE`) is separate from your `worker_threads` pool — if your workers do file I/O, the libuv pool becomes the bottleneck, not your thread count.

---

## Decision 04: Transferable vs Cloneable Messages

**Context:** When you call `worker.postMessage(data)`, Node.js clones the data using the structured clone algorithm (deep copy). For `ArrayBuffer` and `MessagePort`, you can instead transfer ownership — the sending thread loses access and the receiving thread gets it at zero copy cost.

**Trade-offs:**

| Factor | Clone (default) | Transfer |
|--------|----------------|----------|
| Copy cost | O(n) — full deep copy | O(1) — pointer handoff |
| Sender access | Retains full access | Loses access (buffer becomes zero-length) |
| Data types | Any cloneable type (objects, arrays, Maps) | Only `ArrayBuffer`, `MessagePort`, some streams |
| Safety | No surprises — both sides independent | Must track ownership — use-after-transfer bugs |
| Use case | Small/medium messages, config, JSON | Large binary data — images, audio, file content |
| Composability | Easy — sender keeps building on the data | Harder — must finish with data before transfer |

**Recommendation:** Clone by default for any message under 64 KiB — the copy cost is negligible and you avoid ownership bugs. Transfer `ArrayBuffer`s when passing large binary payloads (file chunks, image data, audio frames) where the sender does not need the data afterward. Create a clear convention in your codebase: if a function transfers a buffer, name it `sendTransfer()` not `send()` so callers know their data will be neutered.

---

## Decision 05: When NOT to Use Threads

**Context:** Developers coming from Java or C++ instinctively reach for threads when they want concurrency. In Node.js, the event loop already provides excellent concurrency for I/O-bound work. Adding threads for I/O tasks adds complexity without performance benefit — and sometimes makes things slower.

**Trade-offs:**

| Workload | Event loop (no threads) | Worker threads |
|----------|------------------------|----------------|
| HTTP requests to APIs | Excellent — non-blocking I/O | Waste — thread sits idle during network wait |
| Database queries | Excellent — async drivers | Waste — thread blocked on I/O |
| File reads (many small) | Good — libuv thread pool handles it | Marginal gain, high complexity |
| CPU computation (crypto, math) | Blocks event loop | Excellent — true parallelism |
| Image/video processing | Blocks event loop | Excellent — embarrassingly parallel |
| JSON parsing (large) | May block if > 100ms | Worthwhile for very large payloads |

**Recommendation:** Do not use threads until you have measured event loop lag (via `perf_hooks.monitorEventLoopDelay()`) and confirmed that a specific operation is blocking the loop for more than 50-100ms. Most Node.js applications are I/O-bound and will never need threads. When you do find a CPU bottleneck, first try `setImmediate` chunking to break the work into cooperative pieces. Only reach for `worker_threads` if chunking is insufficient or the work is not naturally chunkable.

---

## Decision 06: `Atomics` vs Mutex Patterns

**Context:** When multiple threads share a `SharedArrayBuffer`, you need synchronization to prevent data corruption. `Atomics` provides low-level atomic operations (`add`, `compareExchange`, `wait`, `notify`). Higher-level mutex patterns can be built on top of `Atomics`, but there is no built-in `Mutex` class in Node.js.

**Trade-offs:**

| Factor | Raw Atomics operations | Mutex (built on Atomics) | Lock-free algorithms |
|--------|----------------------|--------------------------|---------------------|
| Complexity | Moderate — must understand memory model | Lower — familiar lock/unlock API | Very high — requires deep expertise |
| Performance | Fast for simple counters | Slower — lock contention under load | Fastest, but hard to get right |
| Deadlock risk | Low (no locks) | High — nested locks, ordering bugs | None — no locks |
| Correctness | Easy to reason about per-operation | Easy to reason about critical sections | Extremely hard to prove correct |
| Scalability | High — no contention for independent ops | Low — all threads contend on same lock | High — threads rarely interfere |
| Use cases | Counters, flags, simple state | Protecting complex shared structures | Ring buffers, concurrent queues |

**Recommendation:** Use `Atomics.add` and `Atomics.compareExchange` for simple shared counters and flags — they are fast and deadlock-free. If you need to protect a complex multi-field structure, build a simple spinlock using `Atomics.compareExchange` as a test-and-set, but keep critical sections short (under 1 microsecond). Avoid lock-free algorithms unless you are writing a shared ring buffer or concurrent queue and can prove correctness with formal reasoning. In most cases, if your shared state is complex enough to need a mutex, you should rethink whether message passing is the better design.
