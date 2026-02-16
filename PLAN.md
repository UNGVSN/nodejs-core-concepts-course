# Node.js Core Concepts Mastery Course — Full Plan

> Pure Node.js. Zero npm packages. Deep understanding of the runtime from binary data to cryptography.

**Source:** Joseph Heidari — "Understanding Node.js: Core Concepts" (Udemy, 77 hours, 231 lectures, 12 sections)
**Language:** All code JavaScript (Node.js core modules only) — never Python, never TypeScript, never npm packages
**Progressive Project:** "Build Your Own HTTP Framework" (10 steps across 10 modules)

---

## Course Statistics (Projected)

| Metric | Count |
|--------|-------|
| Modules | 10 |
| Lessons | 79 |
| Exercises | 52 |
| Capstone Projects | 4 |
| Specialized Tracks | 4 |
| Progressive Project Steps | 10 |
| Total .md files | ~165 |
| Estimated lines | ~65,000–80,000 |

---

## Style Guide

### Lessons
- `# Module XX / Lesson YY — Title`
- Opening blockquote (1–2 sentences, sets context)
- `## Learning Objectives` (3–5 bulleted)
- Content sections with `##` and `###` headers
- Code blocks: JavaScript only, with comments explaining "why" not "what"
- `## Key Takeaways` (3–5 bulleted, mirror objectives)
- `## Next` (1 sentence linking to next lesson)
- Target: ~400–700 lines per lesson
- Professional but conversational tone

### Exercises
- `# E0X: Title`
- `## Objective` (1–2 sentences)
- `## Prerequisites` (lessons required)
- `## Instructions` (numbered steps)
- `## Break-Then-Harden Challenge` (3 failure scenarios — break it, then fix it)
- `## Expected Output` (what success looks like)
- `## Bonus` (stretch goals)
- `## Hints` (collapsed or at bottom)

### Infrastructure
- Every exercise includes "Break-Then-Harden Challenge" (Node.js-specific failures: memory pressure, event loop starvation, backpressure collapse, file descriptor leaks, thread deadlocks)
- DECISIONS.md per module captures production trade-offs
- All code uses `'use strict';` at top of every file
- No npm packages — only `require('node:...')` syntax (e.g., `require('node:fs')`, `require('node:http')`)
- CommonJS (`require`) by default; ESM (`import`) introduced in Module 01 as alternative

---

## Module Map

### Module 01 — Node.js Architecture & the Event Loop
**Source Sections:** 1 (Introduction)
**Lessons:** 8 | **Exercises:** 5

| # | Lesson | Description |
|---|--------|-------------|
| L01 | What Is Node.js | Runtime vs language, V8 + libuv, single-threaded event-driven model |
| L02 | The V8 Engine | JIT compilation, hidden classes, inline caching, garbage collection |
| L03 | libuv and Asynchronous I/O | Thread pool, OS async primitives, the bridge between JS and the kernel |
| L04 | Event Loop Deep Dive | Phases (timers, pending, idle/prepare, poll, check, close), microtask queue |
| L05 | Call Stack, Callback Queue & Microtasks | Execution order, `process.nextTick` vs `queueMicrotask` vs `setImmediate` |
| L06 | Module System (CommonJS & ESM) | `require` resolution algorithm, `module.exports`, ESM `import/export`, `.mjs` |
| L07 | Global Objects & the REPL | `process`, `global`, `Buffer`, `console`, `__dirname`, `__filename`, REPL internals |
| L08 | Node.js vs Other Runtimes | Comparison with Deno, Bun; why the constraints in this course matter |

| # | Exercise | Description |
|---|----------|-------------|
| E01 | Map the Event Loop | Predict execution order of nested `setTimeout`, `setImmediate`, `process.nextTick`, Promises |
| E02 | Build an Event Loop Visualizer | CLI tool that logs which event loop phase each callback executes in |
| E03 | Module Resolution Detective | Trace `require()` calls through a multi-file project, predict resolution paths |
| E04 | GC Pressure Benchmark | Allocate objects in a loop, observe GC pauses with `--trace-gc`, optimize |
| E05 | Async Ordering Puzzle | 20 mixed async calls — predict and verify exact execution order |

**DECISIONS.md topics:** CommonJS vs ESM default, `node:` prefix convention, strict mode enforcement

**Progressive Project Step 01 — Event-Driven Request Dispatcher:**
Build the skeleton of an HTTP framework: an event loop-aware request dispatcher that accepts a callback registry and invokes handlers asynchronously. Demonstrate how the event loop processes incoming connections.

---

### Module 02 — EventEmitter & Event-Driven Patterns
**Source Sections:** 2 (EventEmitter)
**Lessons:** 6 | **Exercises:** 4

*Note: Source has only 2 lectures / 34 min. Expanded significantly to cover patterns and internals.*

| # | Lesson | Description |
|---|--------|-------------|
| L01 | EventEmitter Internals | How `EventEmitter` works under the hood, the listener registry, max listeners |
| L02 | Registering, Emitting & Removing Events | `on`, `once`, `off`, `removeAllListeners`, `emit` with arguments |
| L03 | Error Events & Edge Cases | The special `'error'` event, `captureRejections`, memory leak warnings |
| L04 | Building Custom EventEmitters | Extending `EventEmitter`, domain-specific event classes |
| L05 | EventEmitter in Node.js Core | How `Stream`, `http.Server`, `net.Socket`, `process` all extend EventEmitter |
| L06 | Observer Pattern & Pub/Sub | Design pattern theory, EventEmitter as Observer, building a simple pub/sub bus |

| # | Exercise | Description |
|---|----------|-------------|
| E01 | Build a Job Queue | EventEmitter-based job queue: `enqueue`, `process`, `complete`, `error` events |
| E02 | Event-Driven Logger | Logger class emitting `log`, `warn`, `error` events with pluggable transports |
| E03 | Memory Leak Hunter | Create a program that leaks listeners, detect it, fix it with proper cleanup |
| E04 | Typed Event System | Build a type-safe (JSDoc-documented) event system with predefined event names and payloads |

**DECISIONS.md topics:** EventEmitter vs callbacks vs Promises, `captureRejections` trade-offs, max listener limits in production

**Progressive Project Step 02 — EventEmitter-Based Middleware Chain:**
Add a middleware system to the framework. Each middleware is an event listener. Request flows through a chain of `use()` handlers via `emit()`, enabling logging, auth, and error handling middleware.

---

### Module 03 — Buffers & Binary Data
**Source Sections:** 3 (Buffers)
**Lessons:** 8 | **Exercises:** 5

| # | Lesson | Description |
|---|--------|-------------|
| L01 | Binary Number Systems | Binary, bits, bytes, bitwise operations (`&`, `|`, `^`, `~`, `<<`, `>>`) |
| L02 | Hexadecimal & Octal | Hex notation, `0x` prefix, practical uses in networking and crypto |
| L03 | Character Encodings | ASCII, UTF-8, UTF-16, Latin-1; encoding vs decoding, BOM, mojibake |
| L04 | Buffer Creation & Allocation | `Buffer.alloc`, `Buffer.allocUnsafe`, `Buffer.from`, memory implications |
| L05 | Buffer Reading & Writing | `readUInt8`, `writeInt32BE`, `readDoubleBE`, endianness, offset math |
| L06 | Buffer Slicing, Copying & Concatenation | `slice` (shared memory!), `copy`, `Buffer.concat`, `compare` |
| L07 | TypedArrays & ArrayBuffer | Relationship between Buffer, ArrayBuffer, Uint8Array; when to use which |
| L08 | Buffer Performance & Memory Management | Pool allocation, `--max-old-space-size`, avoiding Buffer-related memory leaks |

| # | Exercise | Description |
|---|----------|-------------|
| E01 | Hex Dump Utility | Build a `xxd`-like hex dumper that reads any file and outputs hex + ASCII |
| E02 | Binary Protocol Parser | Parse a custom binary protocol (header: 4 bytes magic, 2 bytes length, N bytes payload) |
| E03 | Image Header Reader | Read PNG/JPEG/GIF magic bytes to detect file type without extensions |
| E04 | Buffer vs String Performance | Benchmark string concatenation vs Buffer operations for large data |
| E05 | Endianness Converter | Convert between big-endian and little-endian for multi-byte values |

**DECISIONS.md topics:** `alloc` vs `allocUnsafe` (security vs speed), Buffer pooling, string encoding defaults

**Progressive Project Step 03 — Buffer-Based Body Parsing:**
Add request body parsing to the framework. Collect incoming data chunks as Buffers, parse `Content-Length`, handle chunked transfer encoding, and convert to string/JSON based on `Content-Type` header.

---

### Module 04 — File System
**Source Sections:** 4 (File System)
**Lessons:** 7 | **Exercises:** 5

| # | Lesson | Description |
|---|--------|-------------|
| L01 | File Descriptors & Handles | What an fd is, `fs.open`, `fs.close`, the OS-level reality behind file operations |
| L02 | Reading Files | `readFile`, `readFileSync`, `fs.promises.readFile`, `read` with fd, encoding |
| L03 | Writing Files | `writeFile`, `appendFile`, flags (`w`, `a`, `r+`, `wx`), atomic writes |
| L04 | File Stats & Metadata | `stat`, `lstat`, `fstat`, `BigInt` stats, inode, permissions, timestamps |
| L05 | Directory Operations | `mkdir`, `readdir`, `rmdir`, recursive options, `opendir` for large directories |
| L06 | Watching Files & Directories | `fs.watch`, `fs.watchFile`, polling vs native, platform differences, debouncing |
| L07 | Path Module Deep Dive | `path.join`, `path.resolve`, `path.parse`, `path.normalize`, cross-platform paths |

| # | Exercise | Description |
|---|----------|-------------|
| E01 | File Copy Utility | Build `cp` clone: copy files preserving stats, handle large files, recursive dirs |
| E02 | Directory Tree Printer | Recursive directory walker that prints tree structure (like the `tree` command) |
| E03 | File Watcher with Debounce | Watch a directory for changes, debounce rapid events, log change type |
| E04 | Atomic File Writer | Write files atomically (write to temp, then rename) to prevent corruption |
| E05 | Log File Rotator | Rotate log files when they exceed a size threshold, keep N backups |

**DECISIONS.md topics:** Sync vs async vs promises API, `fs.watch` reliability across platforms, `readdir` vs `opendir` for large directories, `copyFile` flags

**Progressive Project Step 04 — Static File Serving:**
Add static file serving to the framework. Map URL paths to file system paths, read files with proper MIME type detection (from extension), set `Content-Type` and `Content-Length` headers, handle `404 Not Found`, and implement directory index (`index.html`).

---

### Module 05 — Streams
**Source Sections:** 5 (Streams)
**Lessons:** 8 | **Exercises:** 6

| # | Lesson | Description |
|---|--------|-------------|
| L01 | Stream Fundamentals | Why streams exist, the four types, flowing vs paused mode, `highWaterMark` |
| L02 | Readable Streams | `fs.createReadStream`, `read()`, `data`/`end`/`error` events, async iteration |
| L03 | Writable Streams | `fs.createWriteStream`, `write()`, `end()`, `drain` event, return value |
| L04 | Backpressure Mechanics | Why backpressure happens, how `write()` returns false, `drain` protocol |
| L05 | Duplex & Transform Streams | `net.Socket` as Duplex, building Transform streams, `_transform` and `_flush` |
| L06 | Piping & Pipeline | `pipe()`, `stream.pipeline()`, error propagation, `AbortController` integration |
| L07 | Building Custom Streams | Extending `Readable`, `Writable`, `Transform`; `_read`, `_write`, `_transform` |
| L08 | Stream Performance Patterns | Object mode, `stream.compose()`, lazy streams, memory profiling streams |

| # | Exercise | Description |
|---|----------|-------------|
| E01 | Line-by-Line File Reader | Stream a large file, split by newline, process line by line without loading into memory |
| E02 | CSV Transform Pipeline | Read CSV → Transform to JSON → Write output, all streaming |
| E03 | Backpressure Stress Test | Produce data faster than consumer can handle, observe and fix backpressure |
| E04 | Progress Bar Stream | Transform stream that reports progress percentage for file operations |
| E05 | Stream Multiplexer | Read from multiple sources, merge into a single output stream with ordering |
| E06 | Rate-Limited Stream | Transform stream that throttles throughput to N bytes/second |

**DECISIONS.md topics:** `pipe` vs `pipeline` (error handling), `highWaterMark` tuning, object mode trade-offs, when to use streams vs `readFile`

**Progressive Project Step 05 — Streaming Response Support:**
Add streaming responses to the framework. Serve large files using `createReadStream` piped to the response, implement `Transfer-Encoding: chunked`, add backpressure handling between the file stream and the HTTP response, and support range requests (`206 Partial Content`).

---

### Module 06 — Networking
**Source Sections:** 6 (Networking)
**Lessons:** 8 | **Exercises:** 5

| # | Lesson | Description |
|---|--------|-------------|
| L01 | Network Fundamentals | OSI model, TCP/IP stack, packets, ports, sockets |
| L02 | IP Addressing | IPv4, IPv6, subnets, MAC addresses, ARP, `node:net` address utilities |
| L03 | TCP Protocol Deep Dive | Three-way handshake, flow control, congestion control, segments |
| L04 | UDP Protocol & Datagrams | `node:dgram`, connectionless communication, use cases (DNS, gaming, video) |
| L05 | DNS Resolution | How DNS works, `node:dns`, `dns.resolve` vs `dns.lookup`, caching |
| L06 | The `net` Module | `net.createServer`, `net.createConnection`, socket events, encoding |
| L07 | Building TCP Servers & Clients | Multi-client TCP server, framing protocols, connection pooling |
| L08 | Network Debugging | Using Wireshark, `tcpdump`, Node.js `--inspect`, debugging latency |

| # | Exercise | Description |
|---|----------|-------------|
| E01 | TCP Echo Server | Build echo server handling multiple concurrent clients with proper cleanup |
| E02 | TCP Chat Room | Multi-room chat: join, leave, broadcast, private messages, all on raw TCP |
| E03 | UDP Ping-Pong | UDP client/server measuring round-trip latency with timestamps |
| E04 | DNS Resolver | Build a basic DNS resolver that queries a DNS server and parses the response |
| E05 | TCP File Transfer | Send files over TCP with a custom framing protocol (length-prefixed messages) |

**DECISIONS.md topics:** TCP vs UDP selection criteria, `net.Server` `maxConnections`, Nagle's algorithm (`setNoDelay`), keepalive configuration

**Progressive Project Step 06 — TCP Server Foundation:**
Replace Node.js `http.createServer` with a raw TCP server using `net.createServer`. Parse raw HTTP request bytes from the TCP socket. This is where the framework starts handling HTTP at the protocol level.

---

### Module 07 — HTTP From Scratch
**Source Sections:** 7 (HTTP)
**Lessons:** 9 | **Exercises:** 6

| # | Lesson | Description |
|---|--------|-------------|
| L01 | HTTP Protocol Fundamentals | Request/response model, HTTP/1.0 vs 1.1 vs 2, connection lifecycle |
| L02 | Request Anatomy | Method, URL, headers, body; parsing the request line |
| L03 | Response Anatomy | Status line, status codes (1xx–5xx), headers, body |
| L04 | HTTP Methods & Semantics | GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS; idempotency, safety |
| L05 | Headers & MIME Types | Content-Type, Content-Length, Accept, Cache-Control, custom headers |
| L06 | The `http` Module | `http.createServer`, `IncomingMessage`, `ServerResponse`, request/response lifecycle |
| L07 | Routing & URL Parsing | `new URL()`, pathname matching, query parameters, route parameters (`:id`) |
| L08 | Body Parsing & File Uploads | Parsing JSON, URL-encoded, multipart/form-data bodies without npm packages |
| L09 | CORS & Security Headers | Same-origin policy, CORS headers, CSP, HSTS, X-Frame-Options |

| # | Exercise | Description |
|---|----------|-------------|
| E01 | HTTP Parser on TCP | Parse raw HTTP from a TCP socket — extract method, path, headers, body |
| E02 | RESTful API Server | CRUD API for a resource (in-memory store), proper status codes, JSON responses |
| E03 | Static File Server with Caching | Serve files with `ETag`, `Last-Modified`, `304 Not Modified` support |
| E04 | Multipart Form Parser | Parse `multipart/form-data` uploads, save files to disk, handle boundaries |
| E05 | HTTP Client | Build an HTTP client using `http.request`, handle redirects, timeouts, streaming |
| E06 | Load Tester | HTTP load testing tool: concurrent requests, measure latency percentiles (p50/p95/p99) |

**DECISIONS.md topics:** `http` module vs raw TCP, keep-alive tuning, `Transfer-Encoding: chunked` vs `Content-Length`, header size limits

**Progressive Project Step 07 — Full HTTP Protocol Implementation:**
Complete the HTTP layer of the framework. Implement full request parsing (method, URL, headers, body), response building (status codes, headers, body streaming), route matching with parameters (`:id`), JSON/form body parsing, and CORS middleware. The framework should now pass basic HTTP compliance tests.

---

### Module 08 — Unix, Processes & IPC
**Source Sections:** 8 (Unix) — process management, IPC, child processes, cluster
**Lessons:** 8 | **Exercises:** 5

| # | Lesson | Description |
|---|--------|-------------|
| L01 | Unix Fundamentals for Node.js | Processes, file descriptors, signals, stdin/stdout/stderr, exit codes |
| L02 | The `process` Module | `process.env`, `process.argv`, `process.cwd()`, `process.memoryUsage()`, `process.exit()` |
| L03 | Child Processes — `exec` & `execFile` | Spawning commands, capturing output, shell vs no-shell, security implications |
| L04 | Child Processes — `spawn` & `fork` | Streaming I/O with `spawn`, IPC channel with `fork`, when to use which |
| L05 | Inter-Process Communication | IPC channels, `process.send`, message passing patterns, serialization limits |
| L06 | Signals & Process Lifecycle | `SIGINT`, `SIGTERM`, `SIGHUP`, graceful shutdown, `process.on('uncaughtException')` |
| L07 | The `cluster` Module | Master/worker architecture, `cluster.fork`, load balancing, zero-downtime restart |
| L08 | OS Module & System Information | `os.cpus()`, `os.totalmem()`, `os.networkInterfaces()`, platform detection |

| # | Exercise | Description |
|---|----------|-------------|
| E01 | Process Monitor | Monitor child processes: spawn, track CPU/memory, restart on crash |
| E02 | Graceful Shutdown Handler | Handle SIGINT/SIGTERM, drain connections, close database handles, exit clean |
| E03 | CLI Task Runner | Build a task runner (like a mini `make`) that spawns child processes for each task |
| E04 | IPC Message Bus | Parent-child message bus with request/response pattern and timeouts |
| E05 | Clustered HTTP Server | Wrap an HTTP server with `cluster` module, benchmark single vs multi-process |

**DECISIONS.md topics:** `fork` vs `spawn` vs `exec`, cluster vs reverse proxy (nginx), graceful shutdown patterns, IPC serialization overhead

**Progressive Project Step 08 — Child Process Worker Pool:**
Add a worker pool to the framework for CPU-intensive tasks. Spawn a configurable number of child processes via `fork()`, route heavy computation (image resize, data crunching) to workers via IPC, implement round-robin dispatch, and handle worker crashes with automatic respawn.

---

### Module 09 — Multi-Threading & Performance
**Source Sections:** 10 (Multi-Threading) + Section 8 remainder
**Lessons:** 8 | **Exercises:** 5

| # | Lesson | Description |
|---|--------|-------------|
| L01 | Thread Fundamentals | Threads vs processes, shared memory, concurrency vs parallelism |
| L02 | The `worker_threads` Module | `new Worker()`, `workerData`, `parentPort`, `isMainThread` |
| L03 | Message Passing Between Threads | `postMessage`, `MessageChannel`, `MessagePort`, transferable objects |
| L04 | SharedArrayBuffer & Atomics | Shared memory, `Atomics.wait`, `Atomics.notify`, `Atomics.add`, lock-free patterns |
| L05 | Thread Synchronization | Race conditions, deadlocks, mutexes via Atomics, critical sections |
| L06 | Building a Custom Thread Pool | Fixed-size worker pool, task queue, result callbacks, graceful shutdown |
| L07 | Event Loop Optimization | `setImmediate` for chunking, avoiding event loop starvation, `--prof` profiling |
| L08 | Performance Profiling & Benchmarking | `perf_hooks`, `performance.now()`, histogram, `--inspect` with Chrome DevTools |

| # | Exercise | Description |
|---|----------|-------------|
| E01 | Parallel File Hasher | Hash multiple large files in parallel using worker threads |
| E02 | Thread Pool Implementation | Build a generic thread pool: queue tasks, dispatch to workers, collect results |
| E03 | Shared Memory Counter | Multiple threads increment a shared counter — observe race condition, then fix with Atomics |
| E04 | Mandelbrot Set Generator | Compute Mandelbrot set in parallel, each thread handles a horizontal slice |
| E05 | Event Loop Starvation Detector | Build a tool that detects when the event loop is blocked (measures loop delay) |

**DECISIONS.md topics:** Worker threads vs child processes vs cluster (when to use which), `SharedArrayBuffer` security implications, thread pool sizing (CPU count), transferable vs cloneable messages

**Progressive Project Step 09 — Worker Thread Request Handling:**
Add worker thread support to the framework. CPU-intensive request handlers can be offloaded to a worker thread pool. Implement `app.worker('/compute', handler)` that automatically dispatches to threads. Measure the performance difference between blocking the event loop vs offloading to workers.

---

### Module 10 — Cryptography, Compression & Security
**Source Sections:** 9 (Compression) + 11 (Cryptography) + 12 (Security)
**Lessons:** 9 | **Exercises:** 6

| # | Lesson | Description |
|---|--------|-------------|
| L01 | Cryptography Fundamentals | Symmetric vs asymmetric, keys, entropy, randomness, `crypto.randomBytes` |
| L02 | Hashing | SHA-256, SHA-512, MD5 (and why not), HMAC, `crypto.createHash`, `crypto.createHmac` |
| L03 | Symmetric Encryption (AES) | AES-256-GCM, `crypto.createCipheriv`, IV, authentication tags, key derivation |
| L04 | Asymmetric Encryption (RSA) | `crypto.generateKeyPair`, `crypto.publicEncrypt`, `crypto.privateDecrypt` |
| L05 | Diffie-Hellman & ECDH | Key exchange protocols, `crypto.createDiffieHellman`, `crypto.createECDH` |
| L06 | Digital Signatures & Certificates | `crypto.sign`, `crypto.verify`, X.509, self-signed certs, `tls.createServer` |
| L07 | TLS/HTTPS Implementation | `node:https`, `node:tls`, certificate chains, SNI, `tls.connect` |
| L08 | Zlib Compression | `zlib.gzip`, `zlib.deflate`, `zlib.brotliCompress`, streaming compression |
| L09 | Security Best Practices | Timing attacks, `crypto.timingSafeEqual`, password hashing (`scrypt`/`pbkdf2`), secure headers |

| # | Exercise | Description |
|---|----------|-------------|
| E01 | Password Hasher & Verifier | Hash passwords with `scrypt`, salt generation, timing-safe comparison |
| E02 | File Encryptor/Decryptor | AES-256-GCM file encryption with streaming (encrypt large files without loading into memory) |
| E03 | Self-Signed HTTPS Server | Generate certs, create HTTPS server, test with `curl --cacert` |
| E04 | Compression Benchmark | Compare gzip vs deflate vs brotli: compression ratio, speed, memory usage |
| E05 | Secure Key Exchange | Two Node.js processes exchange keys via ECDH, then communicate with AES |
| E06 | Digital Signature Verification | Sign files, distribute public key, verify signatures — detect tampering |

**DECISIONS.md topics:** AES-GCM vs AES-CBC, scrypt vs pbkdf2 vs argon2 (without npm!), brotli vs gzip, TLS 1.2 vs 1.3, randomBytes vs randomUUID

**Progressive Project Step 10 — TLS/HTTPS + Compression:**
Complete the framework with production security features. Add HTTPS support via `tls.createServer` with certificate loading, implement gzip/brotli response compression as middleware, add `Content-Encoding` negotiation based on `Accept-Encoding`, and implement security headers (HSTS, CSP, X-Content-Type-Options). The framework is now a production-capable HTTP server built entirely from Node.js core.

---

## Capstone Projects

### Project 01 — Production HTTP Server
**Modules Required:** All (01–10)
**Estimated Effort:** 15–20 hours

Build a fully-featured HTTP server from scratch using only Node.js core modules:
- Routing engine with path parameters and query strings
- Middleware chain (logging, auth, CORS, compression, error handling)
- Static file serving with caching (`ETag`, `Last-Modified`, `304`)
- JSON and multipart body parsing
- Streaming file uploads and downloads with range request support
- HTTPS with self-signed certificates
- Gzip/Brotli response compression
- Graceful shutdown on SIGTERM
- Request logging with configurable transports
- Benchmark: handle 10,000 concurrent connections on a 4-core machine

**Deliverables:**
- Working server (`server.js`)
- Configuration file support (`config.json`)
- Test suite (manual test scripts using `http.request`)
- Performance benchmark results
- Architecture diagram

---

### Project 02 — Real-Time Chat System
**Modules Required:** 02, 03, 06, 08, 11
**Estimated Effort:** 12–15 hours

Build a multi-room chat system on raw TCP:
- Custom binary protocol (message type byte + length prefix + payload)
- Room management (create, join, leave, list)
- Private messaging between users
- File transfer over TCP (send images/files to chat)
- Message history stored to disk (append-only log)
- Connection heartbeat / keepalive
- Cluster mode for multiple server processes sharing connections
- Encrypted messages using AES between clients

**Deliverables:**
- Server (`chat-server.js`)
- Client (`chat-client.js`)
- Protocol specification document
- Load test script (simulate 100 concurrent users)

---

### Project 03 — File Processing Pipeline
**Modules Required:** 03, 04, 05, 09, 10
**Estimated Effort:** 12–15 hours

Build a streaming ETL (Extract-Transform-Load) pipeline:
- Read large files (CSV, JSON lines, logs) via Readable streams
- Transform pipeline: parse → filter → map → aggregate
- Compress output with gzip or brotli
- Encrypt output with AES-256-GCM
- Distribute work across worker threads (partition by line ranges)
- Progress reporting via EventEmitter
- Configurable pipeline via JSON definition file
- Handle backpressure throughout the entire chain
- Process 1GB+ files with <100MB memory usage

**Deliverables:**
- Pipeline engine (`pipeline.js`)
- CLI interface (`cli.js`)
- Example pipeline configurations
- Memory usage benchmarks (before/after optimization)

---

### Project 04 — Mini Process Manager (PM2 Lite)
**Modules Required:** 01, 02, 06, 07, 08, 09
**Estimated Effort:** 15–20 hours

Build a lightweight process manager inspired by PM2:
- Start/stop/restart Node.js applications
- Cluster mode (fork N workers based on CPU count)
- Auto-restart on crash with exponential backoff
- Log management (stdout/stderr capture, log rotation)
- IPC-based health monitoring (memory, CPU, event loop delay)
- HTTP API for management (`GET /status`, `POST /restart/:app`)
- Graceful reload (zero-downtime restart)
- Environment variable management
- PID file management
- CLI interface for human operators

**Deliverables:**
- Daemon process (`daemon.js`)
- CLI tool (`pm.js`)
- HTTP management API
- Process configuration file format
- Integration test scripts

---

## Specialized Tracks

### Track 01 — Performance & Profiling
**Prerequisite Modules:** 01, 05, 09

| # | Lesson | Description |
|---|--------|-------------|
| T1-L01 | Event Loop Metrics | Measuring loop utilization, `monitorEventLoopDelay`, detecting stalls |
| T1-L02 | Memory Profiling | Heap snapshots, `--inspect`, `process.memoryUsage()`, finding leaks |
| T1-L03 | CPU Profiling & Flame Graphs | `--prof`, `--cpu-prof`, Chrome DevTools profiling, reading flame graphs |
| T1-L04 | Benchmarking Methodology | `perf_hooks`, `performance.timerify`, statistical significance, avoiding pitfalls |
| T1-L05 | Optimization Patterns | Stream vs buffer, worker offloading, connection pooling, avoiding `JSON.parse` on hot paths |

---

### Track 02 — Security Engineering
**Prerequisite Modules:** 07, 10

| # | Lesson | Description |
|---|--------|-------------|
| T2-L01 | Threat Modeling for Node.js | STRIDE model applied to Node.js servers, attack surface analysis |
| T2-L02 | TLS Deep Dive | Certificate chains, OCSP stapling, cipher suite selection, TLS 1.3 handshake |
| T2-L03 | Timing Attacks & Side Channels | `crypto.timingSafeEqual`, constant-time comparison, cache timing |
| T2-L04 | Input Validation & Sanitization | ReDoS prevention, path traversal, header injection, without npm |
| T2-L05 | Secure Server Hardening | Rate limiting, request size limits, slowloris protection, all in core Node.js |

---

### Track 03 — Systems Programming
**Prerequisite Modules:** 03, 08

| # | Lesson | Description |
|---|--------|-------------|
| T3-L01 | N-API & C Addons | Writing native addons, `node-addon-api` concepts, building with `node-gyp` |
| T3-L02 | Unix Sockets & Named Pipes | `net.createServer({path})`, IPC via Unix domain sockets, performance vs TCP |
| T3-L03 | Shared Memory Between Processes | `SharedArrayBuffer` with `worker_threads`, memory-mapped files concept |
| T3-L04 | File Descriptor Passing | Passing fds between processes, `child_process` `stdio` configuration |
| T3-L05 | Low-Level Networking | Raw sockets concept, ICMP, `dgram` advanced options, multicast |

---

### Track 04 — Network Protocol Design
**Prerequisite Modules:** 03, 06, 07

| # | Lesson | Description |
|---|--------|-------------|
| T4-L01 | Protocol Design Principles | Framing, versioning, extensibility, backward compatibility |
| T4-L02 | Binary Protocol Implementation | Length-prefixed messages, TLV encoding, magic bytes, checksums |
| T4-L03 | Request-Response & Streaming Protocols | Multiplexing, pipelining, bidirectional streaming on TCP |
| T4-L04 | Connection Pooling & Load Balancing | Reusing TCP connections, round-robin, least-connections, health checks |
| T4-L05 | WebSocket Protocol | Implement WebSocket handshake and framing from scratch on raw TCP |

---

## Infrastructure Files

| File | Purpose |
|------|---------|
| `README.md` | Course overview, philosophy, module map, prerequisites, how to use |
| `PLAN.md` | This file — full course architecture (remove before publishing) |
| `GLOSSARY.md` | ~80 terms: event loop, backpressure, IPC, file descriptor, TLS, etc. |
| `Makefile` | Targets: `count` (lesson/exercise counts), `audit` (quality checks), `lint` |
| `package.json` | Zero dependencies — only metadata, scripts, and Node.js engine version |
| `.gitignore` | `node_modules/`, `.DS_Store`, `*.log`, `tmp/` |
| `docs/architecture/system-overview.md` | Mermaid: Node.js runtime (V8 + libuv + core modules) |
| `docs/architecture/data-flow.md` | Mermaid: Request lifecycle (TCP → HTTP parse → router → handler → stream response) |
| `docs/architecture/module-dependencies.md` | Mermaid: How modules build on each other |

---

## Directory Structure

```
nodejs-core-concepts-course/
├── README.md
├── PLAN.md
├── GLOSSARY.md
├── COURSE_CONTENT.md          # Original source (keep for reference)
├── Makefile
├── package.json
├── .gitignore
├── docs/
│   └── architecture/
│       ├── system-overview.md
│       ├── data-flow.md
│       └── module-dependencies.md
├── module-01-architecture/
│   ├── README.md
│   ├── DECISIONS.md
│   ├── lesson-01-what-is-nodejs.md
│   ├── lesson-02-v8-engine.md
│   ├── ...
│   ├── exercise-01-map-the-event-loop.md
│   └── ...
├── module-02-eventemitter/
│   ├── README.md
│   ├── DECISIONS.md
│   ├── ...
├── module-03-buffers/
├── module-04-filesystem/
├── module-05-streams/
├── module-06-networking/
├── module-07-http/
├── module-08-unix-processes/
├── module-09-multithreading/
├── module-10-crypto-compression-security/
├── project-01-production-http-server/
│   └── README.md
├── project-02-realtime-chat-system/
│   └── README.md
├── project-03-file-processing-pipeline/
│   └── README.md
├── project-04-mini-process-manager/
│   └── README.md
├── track-01-performance/
│   └── README.md
├── track-02-security/
│   └── README.md
├── track-03-systems-programming/
│   └── README.md
└── track-04-network-protocols/
    └── README.md
```

---

## Source Mapping

| Module | Source Sections | Source Lectures | Source Hours |
|--------|----------------|-----------------|-------------|
| 01 Architecture & Event Loop | 1 | 7 | 5h 45m |
| 02 EventEmitter | 2 | 2 | 0h 34m |
| 03 Buffers | 3 | 11 | 3h 00m |
| 04 File System | 4 | 15 | 2h 16m |
| 05 Streams | 5 | 19 | 6h 19m |
| 06 Networking | 6 | 31 | 9h 04m |
| 07 HTTP | 7 | 33 | 9h 06m |
| 08 Unix & Processes | 8 | 42 | 15h 38m |
| 09 Multi-Threading | 10 | 31 | 10h 24m |
| 10 Crypto, Compression, Security | 9 + 11 + 12 | 41 | 14h 56m |
| **Total** | **12** | **231** | **77h 02m** |

---

## Build Order (Agent Strategy)

### Wave 1 — Infrastructure (direct)
- `README.md`, `GLOSSARY.md`, `Makefile`, `package.json`, `.gitignore`
- `docs/architecture/` (3 files)
- All 10 module directories created

### Wave 2 — READMEs & DECISIONS (agents, 5 per wave)
- 10 module READMEs + 10 DECISIONS.md = 20 files
- 4 project READMEs + 4 track READMEs = 8 files
- 2 agents × 14 files = ~7 files per agent

### Wave 3 — Lessons (agents, 3–5 files per agent)
- 79 lessons across 10 modules
- ~16–20 agents, 4–5 lessons each
- Provide each agent: style guide + module spec + source section content

### Wave 4 — Exercises (agents, 3–5 files per agent)
- 52 exercises across 10 modules
- ~12–15 agents, 3–4 exercises each
- Provide each agent: exercise template + module spec + relevant lesson summaries

### Wave 5 — Specialized Track Lessons (agents)
- 20 track lessons across 4 tracks
- 4 agents, 5 lessons each

### Wave 6 — Quality Audit (direct)
- Verify all links in READMEs
- Verify all sections present (Learning Objectives, Key Takeaways, Break-Then-Harden)
- Verify zero npm packages in code blocks
- Verify `require('node:...')` prefix used consistently
- Verify lesson/exercise counts match plan
- Fix filename divergence from READMEs

---

## Key Pedagogical Decisions

1. **`require('node:...')` prefix everywhere** — Modern Node.js best practice, distinguishes core from npm at a glance.

2. **No npm packages, ever** — The entire course uses only Node.js built-in modules. This forces deep understanding rather than package-surfing.

3. **`'use strict';` in every code block** — Catches silent errors, prevents accidental globals.

4. **CommonJS by default, ESM explained** — The source course uses CommonJS. We introduce ESM in Module 01 but use `require` throughout for consistency.

5. **Break-Then-Harden over theoretical warnings** — Every exercise has 3 failure scenarios the student must trigger deliberately, then fix. Node.js-specific failures:
   - Memory pressure (Buffer/heap exhaustion)
   - Event loop starvation (blocking the loop)
   - Backpressure collapse (stream memory blowup)
   - File descriptor leaks (forgetting to close)
   - Thread deadlocks (SharedArrayBuffer misuse)
   - Unhandled rejections (Promise error swallowing)

6. **Progressive project builds real understanding** — By Module 10, the student has built a production-grade HTTP framework that handles routing, middleware, streaming, compression, HTTPS, and worker threads — all without a single npm package.
