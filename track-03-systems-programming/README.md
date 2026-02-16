# Track 03 — Systems Programming

> Node.js is a systems programming platform disguised as a web framework. This track drops the disguise. You will write C addons, communicate over Unix sockets, share memory between processes, pass file descriptors across process boundaries, and work with raw network primitives.

---

## Overview

Most Node.js developers never leave the comfort of HTTP and JSON. This track takes you below that layer into the territory where Node.js meets the operating system directly. You will write native C addons using N-API, communicate between processes over Unix domain sockets and named pipes, share memory across `worker_threads` using `SharedArrayBuffer`, pass open file descriptors from parent to child processes, and use `node:dgram` for UDP multicast and raw network operations.

This is the track where JavaScript meets systems programming. The code is lower-level, the debugging is harder, and the understanding you gain is deeper than anything in the main course modules.

---

## Prerequisite Modules

- **Module 03** — Buffers & Binary Data
- **Module 08** — Unix, Processes & IPC

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| 01 | [N-API & C Addons](lesson-01-napi-c-addons.md) | Writing native addons with N-API, building with `node-gyp`, passing data between C and JavaScript, when native code is worth the complexity |
| 02 | [Unix Sockets & Named Pipes](lesson-02-unix-sockets.md) | `net.createServer({ path })`, IPC via Unix domain sockets, named pipes on different platforms, performance comparison vs TCP |
| 03 | [Shared Memory Between Processes](lesson-03-shared-memory.md) | `SharedArrayBuffer` with `worker_threads`, `Atomics` for synchronization, lock-free data structures, memory-mapped file concepts |
| 04 | [File Descriptor Passing](lesson-04-fd-passing.md) | Passing open file descriptors between processes via `child_process` `stdio` configuration, `sendHandle()`, real-world use cases |
| 05 | [Low-Level Networking](lesson-05-low-level-networking.md) | `node:dgram` advanced options, UDP multicast, broadcast, socket options (`SO_REUSEADDR`, `SO_REUSEPORT`), building a service discovery protocol |

---

## Who This Track Is For

- Developers building performance-critical Node.js services who need to drop below the JavaScript layer for compute-intensive operations
- Engineers working on IPC-heavy architectures (microservices on the same host, sidecar patterns, daemon-to-worker communication)
- Systems programmers from C/C++/Rust backgrounds who want to understand how Node.js interfaces with the OS kernel
- Anyone curious about what happens beneath `node:net`, `node:child_process`, and `node:worker_threads`

---

## What You Will Learn

- How to write, compile, and load native C addons using N-API — and when native code is actually justified versus staying in JavaScript
- How to set up IPC channels over Unix domain sockets and named pipes, and why they outperform TCP for local communication
- How to share memory between worker threads using `SharedArrayBuffer` and coordinate access with `Atomics` to avoid data races
- How to pass open file descriptors between parent and child processes so that a child can read/write a file the parent opened
- How to use `node:dgram` for UDP multicast, broadcast, and advanced socket options to build low-latency network services
- How Node.js bridges the gap between high-level JavaScript and low-level operating system primitives
