# Track 01 — Performance & Profiling

> You cannot optimize what you cannot measure. This track teaches you to measure everything — event loop latency, heap allocations, CPU hot paths, and throughput under load — using only the profiling tools built into Node.js and V8.

---

## Overview

Performance work in Node.js is not about micro-optimizing `for` loops. It is about understanding the event loop, knowing when you are blocking it, finding memory leaks before they crash your server at 3 AM, and making informed decisions backed by flame graphs and benchmarks rather than guesswork.

This track covers the full performance engineering workflow: instrument your application with `node:perf_hooks`, profile it with V8's built-in profiler and Chrome DevTools, benchmark it with statistical rigor, and apply optimization patterns that actually matter in production. No APM tools. No npm profiling packages. Just the tools that ship with Node.js.

---

## Prerequisite Modules

- **Module 01** — Node.js Architecture & the Event Loop
- **Module 05** — Streams
- **Module 09** — Multi-Threading & Performance

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| 01 | [Event Loop Metrics](lesson-01-event-loop-metrics.md) | Measuring loop utilization with `monitorEventLoopDelay`, detecting event loop stalls, building a loop-lag monitor |
| 02 | [Memory Profiling](lesson-02-memory-profiling.md) | Heap snapshots via `--inspect`, `process.memoryUsage()`, tracking allocations, finding and fixing memory leaks |
| 03 | [CPU Profiling & Flame Graphs](lesson-03-cpu-profiling-flame-graphs.md) | V8's `--prof` and `--cpu-prof` flags, Chrome DevTools CPU profiler, reading flame graphs, identifying hot functions |
| 04 | [Benchmarking Methodology](lesson-04-benchmarking-methodology.md) | `perf_hooks.performance.timerify()`, `PerformanceObserver`, statistical significance, warmup runs, avoiding common pitfalls |
| 05 | [Optimization Patterns](lesson-05-optimization-patterns.md) | Stream vs buffer trade-offs, worker thread offloading, connection pooling, avoiding `JSON.parse` on hot paths, object reuse |

---

## Who This Track Is For

- Backend engineers who need to debug slow endpoints and high-latency responses in production Node.js services
- Developers who have hit memory limits or event loop stalls and want to diagnose the root cause systematically
- Anyone preparing for senior/staff-level interviews where performance analysis is expected
- Engineers who want to stop guessing and start profiling

---

## What You Will Learn

- How to measure event loop delay and detect when the loop is being starved by synchronous work
- How to take heap snapshots, compare them over time, and identify objects that are leaking memory
- How to generate CPU profiles, read flame graphs, and pinpoint which functions consume the most CPU time
- How to write statistically valid benchmarks that account for JIT warmup, garbage collection variance, and system noise
- Which optimization patterns deliver measurable improvements in Node.js (and which "optimizations" are myths)
- How to combine all of these techniques into a performance investigation workflow you can apply to any Node.js application
