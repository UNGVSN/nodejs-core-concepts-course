# Module 01 — Architecture Decisions

> Production trade-offs you will encounter when working with Node.js architecture fundamentals. Each decision documents the context, competing options, and a recommended default.

---

## Decision 1: CommonJS vs ESM as Project Default

**Decision:** Choose CommonJS (`require`) or ESM (`import`) as the default module system for new projects.

**Context:** Node.js supports both module systems. CommonJS is synchronous, mature, and universally supported. ESM is the JavaScript standard, supports top-level `await`, and enables static analysis for tree-shaking. As of Node.js 22+, ESM is stable and most core APIs work seamlessly with it.

**Trade-offs:**
- CommonJS: synchronous `require()` is easier to reason about in scripts; dynamic requires work naturally; massive ecosystem assumes CJS; circular dependencies resolved lazily
- ESM: top-level `await` simplifies startup logic; static imports enable better tooling; `.mjs` extension or `"type": "module"` in `package.json` required; interop with CJS packages occasionally breaks
- Dual-publishing (CJS + ESM) doubles maintenance cost and introduces subtle bugs with module identity

**Recommendation:** Default to ESM (`"type": "module"` in `package.json`) for new projects. Use CommonJS only when maintaining legacy codebases or when a critical dependency has no ESM entry point. In this course, we use CommonJS with the `node:` prefix to teach the resolution algorithm explicitly — production projects should prefer ESM.

---

## Decision 2: The `node:` Prefix Convention

**Decision:** Whether to use the `node:` prefix when importing core modules (e.g., `require('node:fs')` vs `require('fs')`).

**Context:** Node.js 16.0+ supports the `node:` prefix for all built-in modules. The prefix makes it unambiguous that you are importing a core module rather than a user-land package with the same name.

**Trade-offs:**
- With prefix: eliminates name collisions (a malicious `fs` package cannot shadow the real one); immediately signals "this is a core API" in code review; required for newer core modules like `node:test`
- Without prefix: shorter; works across all Node.js versions; familiar to existing developers
- Migration cost is near-zero — find and replace across the codebase

**Recommendation:** Always use the `node:` prefix. The security benefit alone justifies it. A single `require('events')` without the prefix could theoretically resolve to a malicious package. This course uses `node:` everywhere.

---

## Decision 3: Strict Mode Enforcement

**Decision:** Whether to enforce `'use strict'` globally or per-file in CommonJS projects.

**Context:** Strict mode catches silent errors (assigning to undeclared variables, duplicate parameter names, `this` coercion in functions). ESM modules are strict by default. CommonJS modules are not.

**Trade-offs:**
- Per-file `'use strict'`: explicit, works everywhere, no Node.js flags needed; easy to forget in new files
- `--use-strict` CLI flag: enforces globally; breaks third-party code that relies on sloppy mode; not safe in production
- ESM: strict by default — no action needed
- Linter enforcement (ESLint `strict` rule): catches missing strict pragmas at lint time, not runtime

**Recommendation:** For CommonJS projects, add `'use strict';` to every file and enforce it via ESLint. For new projects, prefer ESM where strict mode is automatic. Never use the `--use-strict` flag in production — it applies to `node_modules` too.

---

## Decision 4: UV_THREADPOOL_SIZE Tuning

**Decision:** Whether and how to increase the libuv thread pool size beyond the default of 4.

**Context:** libuv uses a fixed-size thread pool (default: 4 threads) for blocking operations like DNS lookups (`dns.lookup`), file system calls, and some crypto operations. Under high concurrency, this pool becomes a bottleneck — requests queue behind each other.

**Trade-offs:**
- Default (4 threads): sufficient for low-to-medium I/O workloads; minimal memory overhead (~2MB stack per thread)
- Increased (16-128 threads): reduces queueing for DNS-heavy or fs-heavy workloads; each thread consumes stack memory; OS context-switching overhead increases beyond ~128
- `UV_THREADPOOL_SIZE` must be set before the event loop starts (typically via environment variable, not at runtime)
- Alternative: use `dns.resolve` (async, does not use the thread pool) instead of `dns.lookup`

**Recommendation:** Set `UV_THREADPOOL_SIZE` to match your expected concurrent blocking operations. For HTTP servers doing DNS lookups, 16-32 is a reasonable starting point. Profile before tuning — most applications never saturate the default pool. Prefer async alternatives (`dns.resolve`, `fs.promises` with native async where available) to avoid the thread pool entirely.

---

## Decision 5: --max-old-space-size Defaults

**Decision:** Whether to increase V8's heap limit beyond the default (~1.5-2GB on 64-bit systems).

**Context:** V8 limits the old generation heap size to prevent runaway memory consumption. Data-intensive applications (large JSON parsing, in-memory caches, report generation) can hit this limit and crash with `FATAL ERROR: CALL_AND_RETRY_LAST Allocation failed - JavaScript heap out of memory`.

**Trade-offs:**
- Default (~1.7GB): safe for most web servers; prevents single-process memory hogging; forces you to stream large data
- Increased (4-8GB): necessary for batch processing, large dataset transformations, or SSR with heavy caching; delays GC pauses (larger heap = longer mark-sweep)
- Very large (16GB+): GC pauses can exceed 1 second; consider splitting work across child processes or worker threads instead
- Streaming approach: avoids the problem entirely by never holding full datasets in memory

**Recommendation:** Keep the default for HTTP servers. Increase to 4GB only for batch/CLI tools that genuinely need it. If you find yourself going beyond 8GB, redesign with streams or worker threads. Always monitor heap usage with `process.memoryUsage()` and set up alerts at 70% of your configured limit.

---

## Decision 6: Event Loop Monitoring in Production

**Decision:** Whether to instrument event loop lag in production and how to respond to it.

**Context:** Event loop lag — the delay between when a timer is scheduled and when it actually fires — is the single best indicator of Node.js application health. High lag means the event loop is blocked, and every connected client feels it.

**Trade-offs:**
- `monitorEventLoopDelay()` (built-in since Node.js 11): low overhead, histogram-based, gives p50/p99 lag; requires manual wiring to metrics pipeline
- Manual `setTimeout` probe: schedule a 0ms timer, measure actual delay; simple but imprecise; adds its own tiny overhead
- No monitoring: zero overhead; you only discover problems when users complain
- Alert thresholds: p99 > 50ms warrants investigation; p99 > 200ms is an incident

**Recommendation:** Always enable `perf_hooks.monitorEventLoopDelay()` in production. Export the histogram to your metrics system (Prometheus, Datadog, etc.). Set alerts at p99 > 100ms. Combine with `--trace-warnings` and `--trace-sync-io` in staging to catch synchronous operations before they reach production.
