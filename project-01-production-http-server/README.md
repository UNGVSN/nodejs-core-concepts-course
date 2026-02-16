# Project 01 — Production HTTP Server

> Everything you have learned across all 10 modules converges here. You will build a fully-featured HTTP server from scratch — routing, middleware, static files, compression, HTTPS, streaming, and graceful shutdown — using nothing but Node.js core modules. No Express. No Fastify. Just `require('node:http')` and deep understanding.

---

## Overview

This capstone project is the culmination of the entire course. You take the progressive project you have been building module by module and extend it into a production-grade HTTP server capable of handling 10,000 concurrent connections on a 4-core machine.

The server must support every feature a modern web framework provides — routing with path parameters, a composable middleware chain, static file serving with proper cache headers, body parsing for JSON and multipart payloads, streaming uploads and downloads with range requests, TLS/HTTPS, response compression, and graceful shutdown. All without a single npm package.

---

## Prerequisite Modules

All 10 modules are required:

- **Module 01** — Node.js Architecture & the Event Loop
- **Module 02** — EventEmitter & Event-Driven Patterns
- **Module 03** — Buffers & Binary Data
- **Module 04** — File System
- **Module 05** — Streams
- **Module 06** — Networking
- **Module 07** — HTTP From Scratch
- **Module 08** — Unix, Processes & IPC
- **Module 09** — Multi-Threading & Performance
- **Module 10** — Cryptography, Compression & Security

---

## Features to Build

- **Routing engine** with path parameters (`:id`), query string parsing, and wildcard routes
- **Middleware chain** — logging, authentication, CORS, compression, and error handling, composed via `EventEmitter`
- **Static file serving** with MIME type detection, `ETag`/`Last-Modified` headers, and `304 Not Modified` responses
- **JSON body parsing** from raw `Buffer` chunks on the request stream
- **Multipart body parsing** — parse `multipart/form-data` boundaries to extract file uploads
- **Streaming uploads** — accept large files without buffering the entire payload in memory
- **Streaming downloads with range requests** — support `Range` headers for resumable downloads and media seeking
- **HTTPS** with self-signed TLS certificates via `node:https` and `node:tls`
- **Gzip and Brotli response compression** using `node:zlib` transform streams
- **Graceful shutdown** — drain active connections on `SIGTERM`/`SIGINT`, close the server socket, and exit cleanly
- **Request logging** with configurable transports (stdout, file, or both)
- **Cluster mode** — fork workers across all available CPU cores using `node:cluster`
- **Worker thread offloading** — delegate CPU-intensive request handlers to `node:worker_threads`

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    server.js (main)                      │
│                                                         │
│  ┌──────────┐   ┌──────────────┐   ┌────────────────┐  │
│  │ Cluster  │──▶│  TLS/HTTPS   │──▶│  Middleware     │  │
│  │ Manager  │   │  Listener    │   │  Chain          │  │
│  └──────────┘   └──────────────┘   └───────┬────────┘  │
│                                            │            │
│                 ┌──────────────────────────┬┴─────────┐ │
│                 ▼                          ▼          ▼ │
│          ┌────────────┐          ┌──────────┐ ┌──────┐ │
│          │   Router    │          │  Static  │ │ Body │ │
│          │  (params,   │          │  Files   │ │Parser│ │
│          │   query)    │          │ (ETag,   │ │(JSON,│ │
│          └─────┬──────┘          │  304,    │ │multi)│ │
│                │                  │  Range)  │ └──────┘ │
│                ▼                  └──────────┘          │
│          ┌────────────┐                                 │
│          │  Handler   │──▶ zlib Compress ──▶ Response   │
│          └────────────┘                                 │
│                                                         │
│  ┌────────────────┐  ┌──────────────┐  ┌────────────┐  │
│  │ Worker Threads │  │  Graceful    │  │  Request   │  │
│  │ (CPU tasks)    │  │  Shutdown    │  │  Logger    │  │
│  └────────────────┘  └──────────────┘  └────────────┘  │
└─────────────────────────────────────────────────────────┘
```

**Key design constraints:**

1. **Zero npm packages** — every feature uses only `node:*` core modules
2. **Backpressure-aware** — all streaming paths (uploads, downloads, compression) must respect `highWaterMark` and drain events
3. **Event-loop-safe** — no synchronous operations on the hot path; CPU work goes to worker threads
4. **Memory-bounded** — no request or response should buffer more than 64KB unless explicitly configured

---

## Deliverables

| File | Description |
|------|-------------|
| `server.js` | Main entry point — bootstraps cluster, TLS, middleware chain, and router |
| `lib/router.js` | Routing engine with path parameter extraction and query parsing |
| `lib/middleware.js` | Middleware chain implementation (compose, logging, auth, CORS, compression, error) |
| `lib/static.js` | Static file server with MIME detection, ETag, Last-Modified, 304, and Range |
| `lib/body-parser.js` | JSON and multipart body parser operating on raw Buffer streams |
| `lib/compress.js` | Gzip/Brotli response compression via `node:zlib` transform streams |
| `lib/shutdown.js` | Graceful shutdown handler — connection draining and clean exit |
| `config.json` | Server configuration (port, TLS paths, static root, log transports, cluster workers) |
| `test/` | Manual test scripts using `require('node:http').request()` — no test frameworks |
| `bench/` | Benchmark scripts measuring requests/sec, latency p99, and memory under load |
| `docs/architecture.md` | Architecture diagram and design decisions |

---

## Acceptance Criteria

- [ ] Server starts in both HTTP and HTTPS modes via `config.json` toggle
- [ ] Routes with path parameters (`/users/:id`) correctly extract params
- [ ] Middleware chain executes in registration order; errors skip to error middleware
- [ ] Static files return correct MIME types, `ETag` headers, and `304` on cache hit
- [ ] JSON bodies up to 1MB are parsed; payloads exceeding the limit return `413`
- [ ] Multipart uploads are parsed and files are written to disk via streams
- [ ] Range requests return `206 Partial Content` with correct byte ranges
- [ ] Responses are compressed with gzip or brotli based on `Accept-Encoding`
- [ ] `SIGTERM` triggers graceful shutdown — in-flight requests complete, no new connections accepted
- [ ] Cluster mode forks one worker per CPU core; workers restart on crash
- [ ] Request logger writes structured JSON to both stdout and a log file
- [ ] Benchmark: sustains 10,000 concurrent connections on a 4-core machine without crashing
- [ ] Zero npm packages — `node_modules/` does not exist

---

## Estimated Effort

**15-20 hours** for a developer who has completed all 10 modules.

| Phase | Hours |
|-------|-------|
| Routing engine + middleware chain | 3-4 |
| Static file serving (ETag, 304, Range) | 2-3 |
| Body parsing (JSON + multipart) | 2-3 |
| Streaming uploads/downloads | 2-3 |
| HTTPS + compression | 1-2 |
| Cluster mode + worker threads | 2-3 |
| Graceful shutdown + logging | 1-2 |
| Benchmarking + optimization | 2-3 |

---

## Hints

- Start with the progressive project code you built across Modules 01-10 and refactor it into the `lib/` structure above
- Use `node:perf_hooks` to instrument request latency at each middleware step
- Test range requests with `curl --range 0-1023 https://localhost:3000/bigfile.bin`
- Generate self-signed certs with: `openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 365 -nodes`
- For the 10,000 concurrent connections benchmark, use `node:http` to write a custom load generator — or use the system `wrk` tool if available
