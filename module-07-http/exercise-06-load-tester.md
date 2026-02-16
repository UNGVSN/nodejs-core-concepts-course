# E06: Load Tester

## Objective

Build a command-line HTTP load testing tool that sends configurable concurrent requests to a target URL and measures latency percentiles (p50, p95, p99), throughput (requests per second), error rate, and status code distribution. This is a simplified version of tools like `wrk` and `autocannon`, built entirely with `node:http`.

## Prerequisites

- Module 01 / Lesson 04 — Event Loop Deep Dive
- Module 07 / Lesson 06 — The HTTP Module
- Module 07 / Exercise 02 — RESTful API Server (target to test against)
- Module 07 / Exercise 05 — HTTP Client

## Instructions

1. Create a file called `load-tester.js`. Add `'use strict';` at the top. Require `node:http`, `node:https`, and `node:url`.

2. Parse command-line arguments to configure the test:
   ```bash
   node load-tester.js --url http://localhost:3000/items --concurrency 10 --requests 1000 --method GET
   ```
   Support flags: `--url` (required), `--concurrency` / `-c` (default 10), `--requests` / `-n` (default 100), `--method` / `-m` (default `GET`), `--body` (optional JSON string for POST/PUT), `--duration` / `-d` (optional, seconds — run for a time instead of a fixed count).

3. Write a function `sendRequest(urlString, method, body, agent)` that returns a Promise resolving to `{ status, latency, error, bytes }`. Record `latency` using `process.hrtime.bigint()` — capture the start time before calling `http.request()` and the end time when the response `'end'` event fires. Convert to milliseconds with `Number(endNs - startNs) / 1e6`. Track `bytes` (total response body size). Consume the response body by calling `res.resume()` or listening for `data` events and discarding. If the request errors, resolve (do not reject) with `{ status: 0, latency: null, bytes: 0, error: err.message }` — this ensures failed requests are counted in the stats.

4. Implement a concurrency-limited worker pool. The pattern:
   ```javascript
   let completed = 0;
   async function worker() {
     while (completed < totalRequests) {
       const index = completed++;  // atomic-enough for single-threaded JS
       const result = await sendRequest(url, method, body, agent);
       results[index] = result;
       // update progress
     }
   }
   await Promise.all(Array.from({ length: concurrency }, () => worker()));
   ```
   Create N "workers" that each pull the next request off a shared counter and call `sendRequest`. When a worker finishes one request, it immediately starts the next. This maintains exactly N in-flight requests at any time. Create a shared `http.Agent` with `keepAlive: true` and `maxSockets: concurrency` and pass it to every `sendRequest` call.

5. Collect all results into an array of `{ status, latency, error }` objects. Track the overall start time and end time of the test.

6. Write a function `computeStats(results, totalTimeMs)` that calculates:
   - **Total requests**: count of all results
   - **Successful requests**: count where status is 2xx
   - **Failed requests**: count where status is 0 or 4xx/5xx
   - **Error rate**: percentage of failed requests
   - **Throughput**: requests per second (`total / (totalTimeMs / 1000)`)
   - **Latency percentiles**: sort all latency values, then compute p50, p95, p99, min, max, and mean
   - **Status code distribution**: a Map of status code to count

7. Write a function `percentile(sortedArray, p)` that returns the value at the given percentile. Use the nearest-rank method: `index = Math.ceil(p / 100 * length) - 1`.

8. Print a formatted report to the console after the test completes:
   ```
   ═══════════════════════════════════════════
   Load Test Results
   ═══════════════════════════════════════════
   Target:        http://localhost:3000/items
   Method:        GET
   Concurrency:   10
   Total Time:    2.45s
   ───────────────────────────────────────────
   Requests:      1000 total
   Successful:    987 (98.7%)
   Failed:        13 (1.3%)
   Throughput:    408.16 req/sec
   ───────────────────────────────────────────
   Latency (ms):
     Min:         1.23
     Mean:        24.51
     p50:         18.45
     p95:         67.89
     p99:         134.56
     Max:         245.78
   ───────────────────────────────────────────
   Status Codes:
     200: 987
     500: 13
   ═══════════════════════════════════════════
   ```

9. Add a progress indicator: every 10% of requests completed, print a progress line to stderr so the user knows the test is running (e.g., `[=====     ] 50% (500/1000)`).

10. Start a simple test target if no URL is provided: create an inline HTTP server on a random port that responds with `200 OK` and a small JSON body, then run the test against it. This allows the load tester to be self-testing.

## Break-Then-Harden Challenge

1. **Socket exhaustion.** Set concurrency to 1000 and requests to 5000. Observe `ECONNRESET` or `EADDRNOTAVAIL` errors as the OS runs out of ephemeral ports or file descriptors. Fix it by using an `http.Agent` with `maxSockets` set to the concurrency level and `keepAlive: true` to reuse connections.

2. **Target crash mid-test.** Start your RESTful API server from Exercise 02, begin a load test, then kill the server mid-test. Observe the error handling. Ensure your load tester does not crash — every failed request should be recorded in the results with an appropriate error, and the final report should still print.

3. **Memory leak on large tests.** Run 1,000,000 requests. Observe memory growing as you store every single result. Fix it by switching to a streaming statistics approach: maintain running min/max/sum/count and use a t-digest or a fixed-size reservoir sample for percentile approximation instead of storing all latency values.

## Expected Output

```
$ node load-tester.js --url http://localhost:3000/items -c 20 -n 500

Starting load test...
Target: http://localhost:3000/items
Concurrency: 20 | Requests: 500

[====                ] 20% (100/500)
[========            ] 40% (200/500)
[============        ] 60% (300/500)
[================    ] 80% (400/500)
[====================] 100% (500/500)

═══════════════════════════════════════════
Load Test Results
═══════════════════════════════════════════
Target:        http://localhost:3000/items
Method:        GET
Concurrency:   20
Total Time:    1.23s
───────────────────────────────────────────
Requests:      500 total
Successful:    500 (100.0%)
Failed:        0 (0.0%)
Throughput:    406.50 req/sec
───────────────────────────────────────────
Latency (ms):
  Min:         0.89
  Mean:        12.34
  p50:         10.21
  p95:         32.45
  p99:         48.67
  Max:         67.12
───────────────────────────────────────────
Status Codes:
  200: 500
═══════════════════════════════════════════
```

## Bonus

1. Add a `--output report.json` flag that writes the full results to a JSON file, including all individual latency values and the computed statistics. This enables post-hoc analysis and charting.

2. Add a warmup phase: send 10% of the total requests first (discarded from stats) to let the target server warm up its JIT, caches, and connection pools before the real measurement begins.

## Hints

1. Use `process.hrtime.bigint()` for nanosecond-precision latency measurement. Convert to milliseconds with `Number(endNs - startNs) / 1e6`.
2. The worker pool pattern: create N async functions that each loop `while (counter < total)`, atomically increment the counter, and await `sendRequest`. Launch all N with `Promise.all`.
3. `http.Agent({ keepAlive: true, maxSockets: concurrency })` dramatically reduces connection overhead and avoids socket exhaustion.
4. To drain the response body without storing it, listen for `data` events and do nothing, or call `res.resume()` to put the stream in flowing mode.
5. Sort the latency array once before computing all percentiles — sorting is O(n log n) but only done once at the end.
