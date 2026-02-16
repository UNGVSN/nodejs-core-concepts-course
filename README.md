# Node.js Core Concepts Mastery Course

> Pure Node.js. Zero npm packages. Deep understanding of the runtime from binary data to cryptography.

Build production-grade Node.js applications using **only built-in core modules**. No Express, no Axios, no lodash — just `require('node:http')` and your understanding of how things actually work.

By the end of this course, you will have built a fully-featured HTTP framework, a real-time chat system, a streaming file pipeline, and a process manager — all from scratch.

---

## Who This Is For

- **Backend developers** who use Node.js daily but rely on npm packages without understanding the primitives beneath them
- **Senior engineers** preparing for system design interviews who need to articulate how Node.js actually works
- **Anyone** who wants to go from "I can use Express" to "I can build Express"

## Who This Is NOT For

- Complete beginners to programming (you need at least 1 year of experience)
- Developers looking for a quick Express/NestJS tutorial
- Anyone who wants to copy-paste npm packages without understanding them

---

## Prerequisites

- At least one year of programming experience
- Solid JavaScript knowledge (closures, Promises, async/await)
- Basic terminal/command line familiarity
- A machine with Node.js 20+ installed
- CPU with at least 4 cores (recommended for Module 09 — Multi-Threading)

---

## Course Philosophy

**Zero npm packages.** Every line of code in this course uses only Node.js built-in modules (`node:fs`, `node:http`, `node:net`, `node:crypto`, etc.). This forces you to understand what those npm packages actually do under the hood.

**Break-Then-Harden.** Every exercise includes a section where you deliberately break your code — trigger memory exhaustion, stall the event loop, collapse backpressure, leak file descriptors — then fix it. You learn more from controlled failure than from happy paths.

**Build, don't just read.** The progressive project ("Build Your Own HTTP Framework") spans all 10 modules. By Module 10, you have a production-capable HTTP server with routing, middleware, streaming, compression, HTTPS, and worker threads.

---

## Module Map

| Module | Title | Lessons | Exercises | Progressive Project Step |
|--------|-------|---------|-----------|--------------------------|
| [01](module-01-architecture/README.md) | Node.js Architecture & the Event Loop | 8 | 5 | Event-Driven Request Dispatcher |
| [02](module-02-eventemitter/README.md) | EventEmitter & Event-Driven Patterns | 6 | 4 | EventEmitter-Based Middleware Chain |
| [03](module-03-buffers/README.md) | Buffers & Binary Data | 8 | 5 | Buffer-Based Body Parsing |
| [04](module-04-filesystem/README.md) | File System | 7 | 5 | Static File Serving |
| [05](module-05-streams/README.md) | Streams | 8 | 6 | Streaming Response Support |
| [06](module-06-networking/README.md) | Networking | 8 | 5 | TCP Server Foundation |
| [07](module-07-http/README.md) | HTTP From Scratch | 9 | 6 | Full HTTP Protocol Implementation |
| [08](module-08-unix-processes/README.md) | Unix, Processes & IPC | 8 | 5 | Child Process Worker Pool |
| [09](module-09-multithreading/README.md) | Multi-Threading & Performance | 8 | 5 | Worker Thread Request Handling |
| [10](module-10-crypto-compression-security/README.md) | Cryptography, Compression & Security | 9 | 6 | TLS/HTTPS + Compression |
| **Total** | | **79** | **52** | |

---

## Capstone Projects

| Project | Title | Key Modules |
|---------|-------|-------------|
| [01](project-01-production-http-server/README.md) | Production HTTP Server | All |
| [02](project-02-realtime-chat-system/README.md) | Real-Time Chat System | 02, 03, 06, 08, 10 |
| [03](project-03-file-processing-pipeline/README.md) | File Processing Pipeline | 03, 04, 05, 09, 10 |
| [04](project-04-mini-process-manager/README.md) | Mini Process Manager (PM2 Lite) | 01, 02, 06, 07, 08, 09 |

---

## Specialized Tracks

| Track | Title | Prerequisite Modules | Lessons |
|-------|-------|---------------------|---------|
| [01](track-01-performance/README.md) | Performance & Profiling | 01, 05, 09 | 5 |
| [02](track-02-security/README.md) | Security Engineering | 07, 10 | 5 |
| [03](track-03-systems-programming/README.md) | Systems Programming | 03, 08 | 5 |
| [04](track-04-network-protocols/README.md) | Network Protocol Design | 03, 06, 07 | 5 |

---

## Progressive Project: Build Your Own HTTP Framework

The thread that ties the entire course together. Each module contributes one layer to a fully-featured HTTP framework:

| Step | Module | What You Build |
|------|--------|---------------|
| 01 | Architecture | Event loop-aware request dispatcher |
| 02 | EventEmitter | Middleware chain via `emit()` |
| 03 | Buffers | Request body parsing from raw bytes |
| 04 | File System | Static file serving with MIME types |
| 05 | Streams | Streaming responses with backpressure |
| 06 | Networking | Raw TCP server foundation |
| 07 | HTTP | Full HTTP protocol (routing, headers, status codes) |
| 08 | Unix/Processes | Child process worker pool for CPU tasks |
| 09 | Multi-Threading | Worker thread request handling |
| 10 | Crypto/Compression | HTTPS + gzip/brotli compression |

---

## Technologies

- **Runtime:** Node.js 20+ (core modules only — zero npm packages)
- **Core Modules:** `node:fs`, `node:http`, `node:https`, `node:net`, `node:dgram`, `node:crypto`, `node:zlib`, `node:cluster`, `node:child_process`, `node:worker_threads`, `node:stream`, `node:events`, `node:path`, `node:os`, `node:dns`, `node:tls`, `node:perf_hooks`
- **Module System:** CommonJS (`require`) primary, ESM (`import`) introduced
- **Tools:** Wireshark (networking), Chrome DevTools (profiling), `node --inspect`
- **Languages:** JavaScript (some C for Track 03 — Systems Programming)

---

## How to Use This Course

1. **Sequential modules** — Modules build on each other. Complete them in order.
2. **Read lessons, then do exercises** — Each exercise lists prerequisite lessons.
3. **Break things on purpose** — The Break-Then-Harden sections are not optional. Controlled failure is the fastest path to understanding.
4. **Build the progressive project** — Each module's project step reinforces the concepts. By Module 10 you'll have a real HTTP framework.
5. **Capstones when ready** — Tackle capstone projects after completing the relevant modules.
6. **Tracks for depth** — Specialized tracks go deeper into specific domains after the core modules.

---

## Source

Based on Joseph Heidari's "Understanding Node.js: Core Concepts" (Udemy, 77 hours, 231 lectures). Restructured, expanded, and enhanced with production engineering practices, hands-on exercises, and progressive project architecture.
