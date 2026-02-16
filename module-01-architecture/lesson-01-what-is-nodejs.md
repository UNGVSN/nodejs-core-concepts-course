# Module 01 / Lesson 01 — What Is Node.js

> Most developers describe Node.js as "JavaScript on the server." That sentence is technically correct and practically useless. To write reliable, performant server-side code you need to understand what Node.js actually *is* — a runtime environment that fuses Google's V8 engine with the libuv asynchronous I/O library, wired together through a layer of C++ bindings. This lesson tears open the box.

## Learning Objectives

- Distinguish between a programming language, a runtime, and a framework
- Identify the three core pillars of Node.js: V8, libuv, and the C++ binding layer
- Explain why Node.js uses a single-threaded, event-driven architecture instead of a thread-per-request model
- Describe the high-level request lifecycle from JavaScript function call to operating system and back
- Run a minimal Node.js program and inspect what the runtime provides beyond raw JavaScript

---

## A Runtime, Not a Language

JavaScript is a language specification (ECMAScript). V8 is an engine that compiles that specification into machine code. Node.js is a *runtime environment* — it takes V8, adds APIs for file systems, networking, cryptography, and child processes, then wraps everything in an event loop that can handle thousands of concurrent connections on a single thread.

When you type `node app.js`, you are not "running JavaScript." You are:

1. Starting the Node.js process, which initializes V8 and libuv
2. Loading your JavaScript source code into V8 for compilation
3. Executing the compiled code, which registers callbacks with the event loop
4. Entering the event loop, which continues until there is no more work to do

This distinction matters. The language gives you `const`, `async/await`, and `class`. The runtime gives you `require('node:fs')`, `process.env`, TCP sockets, and everything else that makes server-side programming possible.

### A Quick Proof

```javascript
'use strict';

// This runs in V8 — pure ECMAScript
const square = (n) => n * n;
console.log(square(7)); // 49

// This runs via Node.js bindings — not available in a browser
const os = require('node:os');
console.log(`Platform: ${os.platform()}`);
console.log(`CPUs:     ${os.cpus().length}`);
console.log(`Free mem: ${(os.freemem() / 1024 / 1024).toFixed(0)} MB`);
console.log(`Uptime:   ${os.uptime()} seconds`);
```

Run this with `node lesson-01-demo.js`. The `square` function is pure JavaScript — it works in any engine. The `os` module is a Node.js binding to the operating system. Browsers have no equivalent. That gap between "what the language provides" and "what the runtime provides" is the entire subject of this course.

---

## The Three Pillars

Node.js is built from three layers. Every Node.js program touches all three, whether you realize it or not.

### Pillar 1: V8 (The JavaScript Engine)

V8 is Google's open-source JavaScript and WebAssembly engine, written in C++. It compiles JavaScript directly to native machine code using a technique called Just-In-Time (JIT) compilation. V8 handles:

- **Parsing** your JavaScript into an Abstract Syntax Tree (AST)
- **Compiling** the AST to bytecode (via the Ignition interpreter)
- **Optimizing** hot code paths to native machine code (via the TurboFan compiler)
- **Garbage collecting** objects that are no longer reachable

V8 knows nothing about files, networks, or the operating system. It is a pure computation engine. When your code calls `require('node:fs').readFile(...)`, V8 does not perform the read — it calls into the C++ binding layer, which hands the work to libuv.

### Pillar 2: libuv (The Asynchronous I/O Library)

libuv is a C library originally written for Node.js but now used by many projects (Julia, Luvit, and others). It provides:

- **An event loop** that polls the operating system for I/O readiness
- **A thread pool** (default 4 threads) for blocking operations like file system calls and DNS lookups
- **Cross-platform abstractions** over OS-specific async primitives (epoll on Linux, kqueue on macOS, IOCP on Windows)
- **Timers**, signal handling, child process management, and more

libuv is the reason you can write `fs.readFile('data.json', callback)` and the callback fires later, without blocking the main thread. The file read happens on a thread pool thread; when it finishes, libuv pushes the callback onto the event loop's queue.

### Pillar 3: C++ Bindings (The Glue)

The binding layer is the interface between V8's JavaScript world and libuv's C world. When you call a built-in Node.js function, the call path is:

```
JavaScript → V8 → C++ Binding → libuv (or OS directly) → kernel
```

For example, `fs.readFile` is not implemented in JavaScript. The JavaScript function in the `node:fs` module is a thin wrapper that calls a C++ function (`FSReqCallback::Read`), which asks libuv to schedule the read on the thread pool.

Node.js also embeds other C/C++ libraries through this binding layer: **c-ares** for async DNS, **OpenSSL** (or BoringSSL) for TLS/crypto, **zlib** for compression, and **llhttp** for HTTP parsing.

---

## Why Single-Threaded and Event-Driven?

Traditional web servers like Apache httpd spawn a new thread (or process) for every incoming connection. With 10,000 concurrent connections, you need 10,000 threads. Each thread consumes memory for its stack (typically 1-8 MB), and the operating system spends significant CPU time context-switching between them.

Node.js takes a different approach: one thread, one event loop, many connections.

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // This callback fires for EVERY request, but it runs
  // on the SAME thread. No new threads are spawned.
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Hello from the single thread\n');
});

server.listen(3000, () => {
  console.log('Server listening on port 3000');
  console.log(`PID: ${process.pid}`);
  console.log(`Main thread only — no thread pool involved for this response`);
});
```

This works because most of what a web server does is *wait* — wait for a database query to return, wait for a file to be read, wait for a network response. While waiting, a traditional thread sits idle, consuming memory. Node.js registers a callback and moves on to serve the next request. When the I/O completes, the event loop picks up the callback and runs it.

### When Single-Threaded Hurts

The single-thread model has a critical weakness: CPU-bound work blocks the event loop. If your request handler computes a Fibonacci number for 2 seconds, every other connected client waits 2 seconds.

```javascript
'use strict';

// WARNING: This blocks the event loop.
// Every client waits while this runs.
function fibonacciBlocking(n) {
  if (n <= 1) return n;
  return fibonacciBlocking(n - 1) + fibonacciBlocking(n - 2);
}

const http = require('node:http');

const server = http.createServer((req, res) => {
  // This takes ~1-2 seconds for n=40. All other requests are frozen.
  const result = fibonacciBlocking(40);
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end(`fib(40) = ${result}\n`);
});

server.listen(3001, () => {
  console.log('Blocking server on port 3001 — try two requests simultaneously');
});
```

The solution is not to abandon single-threading. It is to offload CPU work to worker threads (Module 09) or child processes (Module 08), keeping the main event loop free for I/O coordination.

---

## The Request Lifecycle

When a client sends an HTTP request to a Node.js server, here is the complete path:

1. **OS kernel** receives the TCP packet and places it on the socket's receive buffer
2. **libuv** detects the socket is readable (via epoll/kqueue/IOCP) during the event loop's poll phase
3. **C++ binding** reads the raw bytes and passes them to **llhttp** for parsing
4. **llhttp** parses the HTTP method, URL, headers, and body
5. **V8** invokes your JavaScript request handler callback with `(req, res)` objects
6. Your handler runs synchronously on the call stack — reading `req.url`, calling `res.end()`
7. **V8** calls back into the C++ binding, which writes the response bytes to the socket via libuv
8. **libuv** hands the socket write to the OS kernel
9. The event loop returns to step 2, waiting for the next event

This entire cycle typically completes in microseconds for a simple response. The event loop never blocks because every I/O operation is delegated to the kernel or the thread pool.

---

## Your First Node.js Introspection

Node.js exposes a wealth of runtime information through the `process` global. Here is a script that reveals what the runtime provides before you even write application code:

```javascript
'use strict';

// --- Runtime identity ---
console.log('=== Node.js Runtime Introspection ===\n');
console.log(`Node.js version:  ${process.version}`);
console.log(`V8 version:       ${process.versions.v8}`);
console.log(`libuv version:    ${process.versions.uv}`);
console.log(`OpenSSL version:  ${process.versions.openssl}`);
console.log(`Architecture:     ${process.arch}`);
console.log(`Platform:         ${process.platform}`);
console.log(`PID:              ${process.pid}`);

// --- Memory ---
const mem = process.memoryUsage();
console.log('\n=== Memory Usage ===\n');
console.log(`Heap total:  ${(mem.heapTotal / 1024 / 1024).toFixed(2)} MB`);
console.log(`Heap used:   ${(mem.heapUsed / 1024 / 1024).toFixed(2)} MB`);
console.log(`RSS:         ${(mem.rss / 1024 / 1024).toFixed(2)} MB`);
console.log(`External:    ${(mem.external / 1024 / 1024).toFixed(2)} MB`);
console.log(`Array bufs:  ${(mem.arrayBuffers / 1024 / 1024).toFixed(2)} MB`);

// --- Feature flags ---
console.log('\n=== Active V8 Flags ===\n');
console.log(process.execArgv.length > 0
  ? process.execArgv.join(', ')
  : '(none — running with defaults)');

// --- Built-in modules ---
const builtins = require('node:module').builtinModules
  .filter((m) => !m.startsWith('_'));
console.log(`\n=== Built-in Modules (${builtins.length}) ===\n`);
console.log(builtins.join(', '));
```

Run this script and study the output. Pay attention to the V8 version (it determines which ECMAScript features you get), the libuv version (it determines async I/O behavior), and the memory numbers (you will learn to optimize these in later modules).

---

## The Node.js Process Model

Every time you run `node script.js`, the operating system creates a process. That process contains:

| Component | Purpose |
|-----------|---------|
| V8 isolate | A sandboxed V8 instance with its own heap |
| Event loop | The libuv loop that drives async I/O |
| Main thread | The single thread running JavaScript |
| Thread pool | 4 background threads (by default) for blocking ops |
| C++ bindings | Bridge functions between JS and native code |

A single Node.js process can handle tens of thousands of concurrent connections. For production workloads, you typically run one process per CPU core using `node:cluster` or an external process manager — but each process is independently single-threaded.

```javascript
'use strict';

const { Worker, isMainThread, threadId } = require('node:worker_threads');

if (isMainThread) {
  console.log(`Main thread ID: ${threadId}`);
  console.log(`PID: ${process.pid}`);
  console.log(`This is the ONLY thread running your JavaScript.`);
  console.log(`libuv has additional threads, but you never see them.`);

  // Proof: the thread pool threads are invisible to JavaScript
  const fs = require('node:fs');
  fs.readFile(__filename, () => {
    // This callback runs on the MAIN thread,
    // even though the file read happened on a thread pool thread.
    console.log(`\nFile read callback — still thread ${threadId}`);
  });
} else {
  console.log(`Worker thread ID: ${threadId}`);
}
```

The key insight: libuv's thread pool threads are invisible to your JavaScript code. Every callback, every Promise resolution, every event handler — they all run on the main thread. The thread pool is an implementation detail of the I/O layer.

---

## Historical Context: Why Node.js Exists

Ryan Dahl created Node.js in 2009 to solve a specific problem: the C10K problem — handling 10,000 concurrent connections on a single server. His thesis was that I/O is the bottleneck, not computation, and the dominant threading model wasted resources by allocating one thread per connection.

Key milestones:

- **2009**: Ryan Dahl presents Node.js at JSConf EU. Initial release built on V8 and libev (later replaced by libuv).
- **2010**: npm is created by Isaac Schlueter, giving Node.js a package ecosystem.
- **2012**: libuv replaces libev to add Windows support.
- **2014**: io.js forks from Node.js over governance concerns.
- **2015**: Node.js Foundation merges io.js and Node.js. Node.js 4.0 ships with V8 4.5 (ES2015 features).
- **2018**: Node.js 10 introduces `fs.promises` and experimental `worker_threads`.
- **2019**: Node.js 12 makes `worker_threads` stable. ESM support lands (experimental).
- **2023**: Node.js 21 includes a stable built-in test runner, single executable applications, and `--watch` mode.
- **2024-2025**: Node.js 22+ stabilizes ESM interop, `require(esm)` support, and the permissions model.

Today Node.js powers Netflix, PayPal, LinkedIn, NASA, Walmart, and millions of smaller applications. Understanding its internals is not academic — it is the difference between writing code that scales and code that crashes under load.

---

## Key Takeaways

- Node.js is a runtime environment, not a language — it combines V8 (JavaScript compilation), libuv (async I/O), and C++ bindings into a single executable
- The single-threaded, event-driven model handles massive concurrency by never blocking the main thread on I/O — callbacks fire when work completes
- CPU-bound work is the enemy of the event loop — offload it to worker threads or child processes
- Every I/O callback runs on the main thread, even though the actual I/O may happen on a libuv thread pool thread
- The `process` global reveals runtime internals (V8 version, memory usage, loaded modules) that help you debug and optimize

## Next

In the next lesson, we crack open the V8 engine to understand how JavaScript goes from source text to machine code — and why the way you write your code affects how fast V8 can compile and optimize it.
