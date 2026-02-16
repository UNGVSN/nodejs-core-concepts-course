# Module 01 / Lesson 08 — Node.js vs Other Runtimes

> Node.js is no longer the only server-side JavaScript runtime. Deno and Bun have entered the arena with fresh architectures and different trade-offs. Understanding where each runtime shines — and where it falls short — helps you make informed decisions for new projects and evaluate whether a migration makes sense. This lesson is a clear-eyed comparison, not a fanboy debate.

## Learning Objectives

- Compare the architectures of Node.js, Deno, and Bun, including their JavaScript engines and event loop implementations
- Explain Deno's permissions model and why it matters for security-sensitive applications
- Identify the key differences in module systems, TypeScript support, and built-in tooling across all three runtimes
- Evaluate when to choose each runtime based on ecosystem maturity, performance requirements, and team expertise
- Read and interpret benchmark data critically, understanding what synthetic benchmarks do and do not measure

---

## The Three Runtimes at a Glance

All three runtimes execute JavaScript (and TypeScript, to varying degrees) on the server. They differ in their engines, system-level bindings, philosophies, and maturity.

| Aspect | Node.js | Deno | Bun |
|--------|---------|------|-----|
| **Creator** | Ryan Dahl (2009) | Ryan Dahl (2018) | Jarred Sumner (2022) |
| **JS Engine** | V8 (Google) | V8 (Google) | JavaScriptCore (Apple) |
| **System Bindings** | libuv (C) | Tokio (Rust) | Custom (Zig) |
| **Language** | C++ | Rust | Zig + C++ |
| **Module System** | CommonJS + ESM | ESM only (now supports npm) | CommonJS + ESM |
| **TypeScript** | Requires transpilation | Built-in (first-class) | Built-in (transpiles only) |
| **Package Manager** | npm / yarn / pnpm | deno add / npm compat | bun install |
| **Permissions** | None (full access) | Explicit (deny by default) | None (full access) |
| **Test Runner** | Built-in (`node --test`) | Built-in (`deno test`) | Built-in (`bun test`) |
| **Bundler** | None built-in | None built-in | Built-in (`bun build`) |
| **LTS Releases** | Yes (even-numbered versions) | No formal LTS | No formal LTS |
| **First Stable Release** | 2009 | 2020 (v1.0) | 2023 (v1.0) |

---

## Node.js Architecture

Node.js uses V8 for JavaScript execution and libuv for asynchronous I/O. This combination has been battle-tested for over 15 years.

```
┌──────────────────────────────────────────────┐
│                 Your JavaScript               │
├──────────────────────────────────────────────┤
│              Node.js Bindings (C++)           │
├───────────────────────┬──────────────────────┤
│      V8 Engine        │       libuv          │
│   (JS execution)      │  (async I/O, timers, │
│                       │   thread pool, DNS)  │
├───────────────────────┴──────────────────────┤
│            Operating System (POSIX / Win32)    │
└──────────────────────────────────────────────┘
```

### Node.js Event Loop (libuv)

The event loop in Node.js has six distinct phases, as covered in Lesson 04:

```javascript
'use strict';

// Node.js event loop phases (review from Lesson 04)
// 1. Timers        — setTimeout, setInterval
// 2. Pending I/O   — deferred I/O callbacks
// 3. Idle/Prepare  — internal use
// 4. Poll          — retrieve new I/O events, execute I/O callbacks
// 5. Check         — setImmediate
// 6. Close         — close callbacks (e.g., socket.on('close'))

// Between every phase: process.nextTick and microtask queues drain

console.log('Node.js event loop demo');

setTimeout(() => console.log('Timer phase'), 0);
setImmediate(() => console.log('Check phase'));

const { readFile } = require('node:fs');
readFile(__filename, () => {
  console.log('Poll phase (I/O callback)');
});

process.nextTick(() => console.log('nextTick (between phases)'));
queueMicrotask(() => console.log('Microtask (between phases)'));
```

### Node.js Strengths

```javascript
'use strict';

// 1. Ecosystem: 2.5M+ packages on npm
//    No other runtime comes close to this number.

// 2. Stability: LTS releases with 30 months of support
console.log('Node.js version:', process.version);
console.log('LTS releases: Even-numbered majors (18, 20, 22, ...)');

// 3. Enterprise adoption: Used by Netflix, PayPal, LinkedIn, Walmart
//    Billions of requests per day in production.

// 4. Hosting: Every cloud provider supports Node.js natively
//    AWS Lambda, Google Cloud Functions, Azure Functions,
//    Vercel, Railway, Render, Fly.io — all first-class support.

// 5. Mature debugging and profiling tools
//    --inspect flag, Chrome DevTools integration, clinic.js,
//    0x (flamegraphs), built-in profiler

// 6. Native addons via N-API for performance-critical C/C++ code
const os = require('node:os');
console.log('CPUs:', os.cpus().length);
console.log('Platform:', process.platform);
```

---

## Deno Architecture

Deno was created by Ryan Dahl (the original creator of Node.js) as a "do-over" — fixing what he considered design mistakes in Node.js. Deno is written in Rust and uses Tokio for its async runtime.

```
┌──────────────────────────────────────────────┐
│         Your JavaScript / TypeScript          │
├──────────────────────────────────────────────┤
│              Deno Runtime (Rust)               │
├───────────────────────┬──────────────────────┤
│      V8 Engine        │       Tokio          │
│   (JS execution)      │  (async runtime,     │
│                       │   Rust ecosystem)    │
├───────────────────────┴──────────────────────┤
│            Operating System (POSIX / Win32)    │
└──────────────────────────────────────────────┘
```

### Deno's Permissions Model

The most distinctive feature of Deno is its security sandbox. By default, a Deno script cannot access the filesystem, network, or environment variables.

```
# Run with no permissions — script can only compute
deno run script.ts

# Grant specific permissions
deno run --allow-read=/tmp --allow-net=api.example.com script.ts

# Available permission flags:
# --allow-read[=paths]     Read filesystem
# --allow-write[=paths]    Write filesystem
# --allow-net[=hosts]      Network access
# --allow-env[=vars]       Environment variables
# --allow-run[=cmds]       Spawn subprocesses
# --allow-ffi              Foreign Function Interface
# --allow-sys              System info (hostname, OS, etc.)
# --allow-all / -A         Grant all permissions (defeats the purpose)
```

This is meaningful for security. In Node.js, any dependency in your `node_modules` can read your SSH keys, environment variables, or make network requests. In Deno, it cannot unless you explicitly grant permission.

### Deno's Module System

Deno originally used URL-based imports with no package manager. This was controversial, and Deno has since added npm compatibility.

```javascript
// Deno — original URL imports (still supported)
// import { serve } from "https://deno.land/std/http/server.ts";

// Deno — npm compatibility (added in Deno 1.28+)
// import express from "npm:express@4";

// Deno — node: prefix for Node.js built-in APIs
// import { readFile } from "node:fs/promises";
// import { EventEmitter } from "node:events";
```

### Deno's TypeScript Support

Deno runs TypeScript files directly — no `tsc`, no `ts-node`, no build step:

```
# Just run the .ts file
deno run server.ts

# Node.js equivalent requires extra tooling:
# npx tsx server.ts           (using tsx)
# npx ts-node server.ts       (using ts-node)
# tsc && node dist/server.js   (compile first)
```

### Deno's Built-in Tools

```
deno fmt          # Format code (like prettier, opinionated)
deno lint         # Lint code (built-in rules)
deno test         # Run tests (built-in test runner)
deno bench        # Run benchmarks
deno doc          # Generate documentation
deno compile      # Compile to standalone executable
deno check        # Type-check without running
deno task         # Run tasks from deno.json (like npm scripts)
deno jupyter      # Deno as a Jupyter kernel
```

---

## Bun Architecture

Bun is written primarily in Zig and uses Apple's JavaScriptCore engine (the same engine in Safari and WebKit). Its design goal is raw speed.

```
┌──────────────────────────────────────────────┐
│         Your JavaScript / TypeScript          │
├──────────────────────────────────────────────┤
│              Bun Runtime (Zig + C++)          │
├───────────────────────┬──────────────────────┤
│  JavaScriptCore       │   Custom I/O Layer   │
│ (Apple's JS engine)   │  (io_uring on Linux, │
│                       │   kqueue on macOS)   │
├───────────────────────┴──────────────────────┤
│            Operating System (POSIX / Win32)    │
└──────────────────────────────────────────────┘
```

### Bun's All-in-One Philosophy

Bun bundles tools that Node.js requires separate packages for:

```
bun run script.ts      # Runtime (runs JS and TS directly)
bun install            # Package manager (faster than npm/yarn/pnpm)
bun test               # Test runner (Jest-compatible API)
bun build              # Bundler (like esbuild/webpack)
bunx create-react-app  # Package runner (like npx)
bun init               # Project scaffolding
```

### Bun's Performance Claims

Bun markets itself heavily on performance. Here is what that means in practice:

```javascript
'use strict';

// What Bun optimizes:
// 1. Startup time — significantly faster than Node.js
//    Bun: ~5ms to start, Node.js: ~30-50ms
//    Matters for: CLI tools, serverless cold starts

// 2. Package installation — bun install is faster than npm install
//    Uses a global module cache, hardlinks instead of copies
//    Matters for: CI/CD pipelines, monorepos

// 3. Built-in SQLite — Bun ships with a native SQLite driver
//    No need for better-sqlite3 or other npm packages
//    bun:sqlite is a first-class module

// 4. File I/O — Bun.file() and Bun.write() are optimized
//    Uses system calls directly instead of going through libuv

// What to be cautious about:
// - Synthetic benchmarks (hello world, empty loops) rarely reflect
//   real application performance.
// - In real apps, the bottleneck is usually database queries,
//   network latency, or business logic — not the runtime.
// - Bun's compatibility with the Node.js ecosystem is ~95%,
//   not 100%. Some npm packages may not work.
```

### Bun's Node.js Compatibility

Bun aims to be a drop-in replacement for Node.js. It implements most Node.js APIs:

```javascript
'use strict';

// These Node.js APIs work in Bun:
const path = require('node:path');
const fs = require('node:fs');
const http = require('node:http');
const crypto = require('node:crypto');
const events = require('node:events');
const stream = require('node:stream');
const url = require('node:url');
const util = require('node:util');
const os = require('node:os');

// Bun supports both CommonJS and ESM
// Bun reads package.json, understands node_modules
// Bun supports .env files natively (no dotenv package needed)

console.log('This script runs on Node.js, Deno, and Bun');
console.log('Path separator:', path.sep);
console.log('Home directory:', os.homedir());
```

---

## Module System Comparison

| Feature | Node.js | Deno | Bun |
|---------|---------|------|-----|
| CommonJS (`require`) | Yes (default) | Partial (via npm compat) | Yes |
| ESM (`import`) | Yes | Yes (default, only format) | Yes |
| `package.json` | Required | Optional | Required |
| `node_modules` | Default | Optional (npm compat mode) | Default |
| URL imports | No | Yes | No |
| Import maps | Via `--import-map` flag | Yes (`deno.json`) | No |
| JSON imports | `require('./data.json')` | `import` with assertion | `require` or `import` |
| TypeScript imports | Needs transpiler | Native | Native |
| `.cjs` / `.mjs` extensions | Yes | `.mjs` yes, `.cjs` partial | Yes |

```javascript
'use strict';

// Node.js — CommonJS is the default
const path = require('node:path');
const fs = require('node:fs');

// Reading the module system configuration
const packagePath = path.join(process.cwd(), 'package.json');

if (fs.existsSync(packagePath)) {
  const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
  const moduleType = pkg.type || 'commonjs';
  console.log(`This project uses: ${moduleType}`);
  console.log('  .js files are treated as:', moduleType === 'module' ? 'ESM' : 'CommonJS');
  console.log('  To override per-file:');
  console.log('    .cjs → always CommonJS');
  console.log('    .mjs → always ESM');
} else {
  console.log('No package.json found — defaulting to CommonJS');
}
```

---

## Event Loop Comparison

The event loop is the heart of any JavaScript runtime. All three runtimes are single-threaded for JavaScript execution but handle I/O differently.

```
Node.js Event Loop (libuv — C):
  ┌─────────────────────────┐
  │  Timers (setTimeout)    │
  │  Pending I/O callbacks  │
  │  Idle / Prepare         │
  │  Poll (I/O)             │◄── epoll (Linux), kqueue (macOS)
  │  Check (setImmediate)   │
  │  Close callbacks        │
  └─────────────────────────┘
  Thread pool: 4 threads (UV_THREADPOOL_SIZE)
  Used for: DNS, fs, crypto, zlib

Deno Event Loop (Tokio — Rust):
  ┌─────────────────────────┐
  │  Single-threaded reactor│
  │  + work-stealing thread │◄── epoll/kqueue/IOCP via mio
  │    pool for blocking    │
  │    operations           │
  └─────────────────────────┘
  Tokio spawns threads as needed.
  Rust's async/await maps to JS Promises.

Bun Event Loop (Custom — Zig):
  ┌─────────────────────────┐
  │  Custom event loop      │
  │  io_uring on Linux      │◄── Fewer syscalls, zero-copy I/O
  │  kqueue on macOS        │
  │  Single allocation      │
  │  strategy               │
  └─────────────────────────┘
  Designed to minimize memory allocations.
  io_uring gives significant I/O performance on Linux 5.1+.
```

```javascript
'use strict';

// Demonstrating Node.js thread pool size (libuv)
const { execSync } = require('node:child_process');

// Default thread pool size
console.log('UV_THREADPOOL_SIZE:', process.env.UV_THREADPOOL_SIZE || '4 (default)');

// You can increase it (before any async operations):
// UV_THREADPOOL_SIZE=16 node app.js

// Thread pool is used for:
// - File system operations (fs.readFile, fs.writeFile, etc.)
// - DNS lookups (dns.lookup — NOT dns.resolve)
// - Crypto operations (crypto.pbkdf2, crypto.randomBytes, etc.)
// - Zlib compression (zlib.gzip, zlib.deflate, etc.)

// Network I/O does NOT use the thread pool — it uses
// the OS's async I/O primitives directly (epoll, kqueue, IOCP)
```

---

## TypeScript Support Comparison

| Feature | Node.js | Deno | Bun |
|---------|---------|------|-----|
| Run `.ts` files | Strip types (v22.6+) | Yes (full check) | Yes (transpile only) |
| Type checking | No (needs `tsc`) | Yes (built-in) | No (transpile only) |
| `tsconfig.json` | Optional | Optional (`deno.json`) | Optional |
| Speed | Depends on tooling | Fast (swc-based) | Very fast (no type check) |
| JSX/TSX | Needs transpiler | Built-in | Built-in |

```javascript
'use strict';

// Node.js 22.6+ can strip TypeScript type annotations:
// node --experimental-strip-types script.ts

// This removes types but does NOT type-check.
// You still need tsc for catching type errors.

// For Node.js projects with TypeScript, the typical setup is:
// 1. tsc for type checking (in CI or watch mode)
// 2. tsx or ts-node for development
// 3. tsc --build for production compilation

const { existsSync } = require('node:fs');
const { join } = require('node:path');

// Check if this project has TypeScript configured
const hasTsConfig = existsSync(join(process.cwd(), 'tsconfig.json'));
console.log('TypeScript configured:', hasTsConfig);

// Node.js experimental type stripping (22.6+)
const [major, minor] = process.versions.node.split('.').map(Number);
const supportsTypeStripping = major > 22 || (major === 22 && minor >= 6);
console.log('Type stripping support:', supportsTypeStripping);
```

---

## Security Model Comparison

```
Node.js:
  ┌──────────────────────────┐
  │   Full system access     │
  │   No sandboxing          │
  │   Trust all dependencies │
  └──────────────────────────┘
  Risk: Any package in node_modules can read ~/.ssh,
        process.env, make network requests, etc.
  Mitigation: Code audits, npm audit, lockfiles,
              using --experimental-permission (Node 20+)

Deno:
  ┌──────────────────────────┐
  │   Sandboxed by default   │
  │   Explicit permissions   │
  │   Granular control       │
  └──────────────────────────┘
  Risk: Developers may use --allow-all (-A) out of
        frustration, defeating the purpose.
  Benefit: Supply chain attacks are harder to exploit.

Bun:
  ┌──────────────────────────┐
  │   Full system access     │
  │   No sandboxing          │
  │   Same as Node.js        │
  └──────────────────────────┘
  Same risk profile as Node.js.
  No permission system planned.
```

```javascript
'use strict';

// Node.js 20+ introduced --experimental-permission
// This is Node.js's answer to Deno's security model

// Run with:
// node --experimental-permission --allow-fs-read=./data script.js

// In code, you can check permissions:
// (This API is experimental and may change)
const { permission } = require('node:process');

if (typeof permission !== 'undefined' && permission.has) {
  console.log('Permission model enabled');
  console.log('Can read CWD:', permission.has('fs.read', process.cwd()));
  console.log('Can write /tmp:', permission.has('fs.write', '/tmp'));
} else {
  console.log('Permission model not enabled (running without --experimental-permission)');
  console.log('This process has full system access.');
}
```

---

## Performance: What Actually Matters

Benchmarks are misleading without context. Here is a framework for thinking about runtime performance.

```javascript
'use strict';

// What synthetic benchmarks measure:
// - HTTP hello-world requests per second
// - File read/write throughput
// - JSON parse/stringify speed
// - Startup time to first output
// - Package installation speed

// What real applications depend on:
// - Database query latency (PostgreSQL, Redis, MongoDB)
// - Network round-trip time to external APIs
// - Business logic complexity
// - Memory efficiency under sustained load
// - Garbage collection pauses
// - Connection pooling efficiency
// - Error handling overhead

// The runtime overhead is typically <5% of total request time
// in a real application. The database query is 50-80%.

// Example: Measuring what actually matters
const { performance, PerformanceObserver } = require('node:perf_hooks');

// Create an observer to watch performance marks
const obs = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    console.log(`${entry.name}: ${entry.duration.toFixed(2)}ms`);
  }
});
obs.observe({ entryTypes: ['measure'] });

// Simulate a real request lifecycle
async function simulateRequest() {
  performance.mark('request-start');

  // 1. Parse request (runtime speed matters here — but it is fast)
  performance.mark('parse-start');
  const body = JSON.parse('{"user":"alice","action":"login"}');
  performance.mark('parse-end');
  performance.measure('1-parse', 'parse-start', 'parse-end');

  // 2. Business logic (your code — same speed in any runtime)
  performance.mark('logic-start');
  const validated = body.user.length > 0 && body.action.length > 0;
  performance.mark('logic-end');
  performance.measure('2-logic', 'logic-start', 'logic-end');

  // 3. "Database query" (simulated — this is the bottleneck)
  performance.mark('db-start');
  await new Promise((resolve) => setTimeout(resolve, 50)); // 50ms "query"
  performance.mark('db-end');
  performance.measure('3-database', 'db-start', 'db-end');

  // 4. Serialize response
  performance.mark('serialize-start');
  const response = JSON.stringify({ success: true, user: body.user });
  performance.mark('serialize-end');
  performance.measure('4-serialize', 'serialize-start', 'serialize-end');

  performance.measure('total', 'request-start', 'serialize-end');
}

simulateRequest().then(() => {
  // Notice: parse and serialize are <1ms, database is ~50ms
  // Switching runtimes would save microseconds, not milliseconds.
  setTimeout(() => obs.disconnect(), 100);
});
```

---

## Decision Framework: When to Use Which

### Choose Node.js When

- You need the largest ecosystem of packages (2.5M+ on npm)
- Your team has existing Node.js expertise
- You need long-term support (LTS releases with 30-month lifecycle)
- You are deploying to any cloud provider (universal support)
- You need native C++ addons (N-API is mature and stable)
- You are building enterprise software that requires proven stability

### Choose Deno When

- Security is a primary concern (sandboxed by default)
- You want TypeScript without any build tooling
- You are starting a greenfield project with no legacy dependencies
- You want built-in formatting, linting, and testing with zero config
- You are deploying to Deno Deploy (edge computing)
- You value standards compliance (Web APIs over Node.js-specific APIs)

### Choose Bun When

- Startup time is critical (CLI tools, serverless cold starts)
- You want the fastest `npm install` for CI/CD
- You need a built-in bundler and want to reduce tooling
- You are building a new project and can tolerate compatibility gaps
- You need built-in SQLite support
- Your project runs on macOS or Linux (Windows support is improving)

---

## Migration Considerations

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

// Checklist for evaluating a runtime migration
const migrationChecklist = {
  'Dependency Compatibility': [
    'Do all npm packages work in the target runtime?',
    'Are native addons (N-API / .node files) supported?',
    'Do devDependencies (test frameworks, linters) work?',
  ],
  'API Surface': [
    'Does the target runtime support all node: built-in modules you use?',
    'Are there behavioral differences in fs, http, crypto, stream?',
    'Do child_process and worker_threads work the same way?',
  ],
  'Ecosystem': [
    'Is your hosting provider / PaaS supported?',
    'Do your CI/CD pipelines support the new runtime?',
    'Are there official Docker images?',
  ],
  'Team': [
    'Does the team have expertise or willingness to learn?',
    'Is there adequate documentation and community support?',
    'What is the debugging story? (Inspector, DevTools, etc.)',
  ],
};

// Print the checklist
for (const [category, questions] of Object.entries(migrationChecklist)) {
  console.log(`\n${category}:`);
  for (const q of questions) {
    console.log(`  [ ] ${q}`);
  }
}
```

---

## Feature Comparison Table

| Feature | Node.js | Deno | Bun |
|---------|---------|------|-----|
| **Maturity** | 15+ years | 5 years | 3 years |
| **npm Packages** | Native | Compatible | Compatible |
| **TypeScript** | Strip types (22.6+) | First-class | Transpile only |
| **Permissions** | Experimental (20+) | Built-in | None |
| **Test Runner** | Built-in (18+) | Built-in | Built-in |
| **Benchmarker** | None built-in | Built-in | None built-in |
| **Formatter** | None built-in | Built-in | None built-in |
| **Linter** | None built-in | Built-in | None built-in |
| **Bundler** | None built-in | None built-in | Built-in |
| **SQLite** | None built-in | Built-in (KV) | Built-in |
| **Compile to binary** | `pkg`, SEA (20+) | Built-in | Built-in |
| **HTTP/2** | Built-in | Built-in | Partial |
| **Web Crypto API** | Built-in | Built-in | Built-in |
| **Web Streams API** | Built-in | Built-in | Built-in |
| **Worker Threads** | Built-in | Web Workers | Built-in |
| **FFI** | N-API / node-addon-api | `Deno.dlopen` | `bun:ffi` |
| **Top-level Await** | ESM only | Yes | Yes |
| **WASI** | Experimental | Built-in | Not yet |
| **Windows Support** | Full | Full | Improving |
| **Production Readiness** | Battle-tested | Production-ready | Maturing |

---

## The Convergence Trend

An important trend to notice: the three runtimes are converging, not diverging.

```javascript
'use strict';

// Evidence of convergence:

// 1. Deno added npm compatibility (1.28+)
//    → Deno can now use node_modules and package.json

// 2. Bun implemented Node.js APIs
//    → require('node:fs'), require('node:http'), etc.

// 3. Node.js added Deno-like features
//    → Built-in test runner (18+)
//    → Experimental permissions (20+)
//    → Type stripping (22.6+)
//    → Single executable applications (20+)

// 4. All three support Web Standard APIs
//    → fetch(), Request, Response, Headers
//    → Web Streams (ReadableStream, WritableStream)
//    → Web Crypto (crypto.subtle)
//    → URL, URLSearchParams
//    → TextEncoder, TextDecoder
//    → structuredClone()

// 5. WinterCG (Web-interoperable Runtimes Community Group)
//    → Industry group defining shared APIs across runtimes
//    → Members include Node.js, Deno, Bun, Cloudflare Workers

// The practical implication: code written with standard Web APIs
// is increasingly portable across all three runtimes.

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const bytes = encoder.encode('This works everywhere');
console.log(decoder.decode(bytes));
// 'This works everywhere' — runs on Node.js, Deno, and Bun
```

---

## Key Takeaways

- Node.js, Deno, and Bun all execute JavaScript on the server but differ in engines (V8/V8/JSC), system bindings (libuv/Tokio/custom Zig), and philosophy (ecosystem vs security vs speed)
- Deno's permissions model is its strongest differentiator — scripts cannot access the filesystem, network, or environment by default, which mitigates supply chain attacks
- Bun's speed advantages are real for startup time and package installation, but in typical web applications the database and network are the bottleneck, not the runtime
- Node.js remains the safest choice for production workloads due to its 15-year track record, LTS releases, universal hosting support, and the largest package ecosystem in any programming language
- The three runtimes are converging on Web Standard APIs (fetch, Web Streams, Web Crypto, URL) through the WinterCG initiative — code written against these standards is increasingly portable

## Next

This concludes Module 01. Continue to [Module 02 — EventEmitter](../module-02-eventemitter/lesson-01-eventemitter-internals.md) to learn how Node.js's event-driven architecture works at the code level.
