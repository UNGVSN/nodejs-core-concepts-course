# E01: Parallel File Hasher

## Objective

Hash multiple large files in parallel using worker threads, where each worker computes the SHA-256 digest of a single file. Compare the wall-clock time of sequential hashing versus parallel hashing and report the speedup factor. This exercise proves that `worker_threads` deliver real parallelism for CPU-bound cryptographic work.

## Prerequisites

- Module 09 / Lesson 01 — Thread Fundamentals
- Module 09 / Lesson 02 — The worker_threads Module
- Module 09 / Lesson 03 — Message Passing Between Threads
- Module 10 / Lesson 02 — Hashing (SHA, MD5, HMAC) (or basic familiarity with `crypto.createHash`)

## Instructions

1. **Create `parallel-hasher.js`** with `'use strict';` at the top. Require the following core modules:

```javascript
'use strict';

const {
  Worker, isMainThread, parentPort, workerData
} = require('node:worker_threads');
const crypto = require('node:crypto');
const fs     = require('node:fs');
const path   = require('node:path');
const { performance } = require('node:perf_hooks');
const os     = require('node:os');
```

2. **Generate test files.** Write a `generateTestFiles(count, sizeMB)` function that creates files in a `./test-files/` directory. Each file should contain `sizeMB` megabytes of random data from `crypto.randomBytes()`. Name them `file-01.bin` through `file-08.bin`. Use `fs.mkdirSync(dir, { recursive: true })` to create the directory. Skip generation if all files already exist and have the correct size.

```javascript
function generateTestFiles(count = 8, sizeMB = 10) {
  const dir = path.join(__dirname, 'test-files');
  fs.mkdirSync(dir, { recursive: true });
  const files = [];
  for (let i = 1; i <= count; i++) {
    const name = `file-${String(i).padStart(2, '0')}.bin`;
    const filePath = path.join(dir, name);
    // Generate only if missing or wrong size
    // ... your implementation here
    files.push(filePath);
  }
  return files;
}
```

3. **Build the worker logic.** Use the `isMainThread` guard at the top of the file. When running as a worker, read `workerData.filePath`, compute its SHA-256 hash, and send the result back via `parentPort.postMessage()`. Measure per-file elapsed time with `performance.now()` inside the worker.

```javascript
if (!isMainThread) {
  const start = performance.now();
  const filePath = workerData.filePath;
  const buffer = fs.readFileSync(filePath);
  const hash = crypto.createHash('sha256').update(buffer).digest('hex');
  const elapsed = performance.now() - start;
  parentPort.postMessage({ filePath, hash, elapsed });
  // Worker automatically exits after postMessage
}
```

4. **Implement sequential hashing.** In the main thread, write an `async function hashSequential(files)` that iterates through every file path, reads each one with `fs.readFileSync()`, computes the SHA-256 hash with `crypto.createHash('sha256').update(buf).digest('hex')`, and pushes `{ filePath, hash, elapsed }` into a results array. Wrap the entire loop in `performance.now()` calls to get total wall-clock time.

5. **Implement parallel hashing.** Write an `async function hashParallel(files)` that spawns one `Worker` per file. For each file, create a Promise that resolves when the worker sends its message and rejects if the worker emits an error or exits with a non-zero code:

```javascript
function hashOneFile(filePath) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(__filename, {
      workerData: { filePath }
    });
    worker.on('message', resolve);
    worker.on('error', reject);
    worker.on('exit', (code) => {
      if (code !== 0) reject(new Error(`Worker exited with code ${code}`));
    });
  });
}
```

Use `Promise.all(files.map(hashOneFile))` to run all workers concurrently and collect results. Measure total time around the `await Promise.all()`.

6. **Collect and compare results.** After both functions complete, iterate through the results side by side. For each file, verify that the sequential hash matches the parallel hash. Count matches and mismatches.

7. **Print a summary table.** Display file name, hash (first 16 hex characters), and timing for both approaches. At the bottom, print the speedup factor (`sequentialTime / parallelTime`) and the number of available CPU cores from `os.availableParallelism()`.

8. **Handle errors gracefully.** If a worker crashes or a file is unreadable, the `'error'` and `'exit'` handlers on the worker should reject the Promise with a descriptive message including the file path. Wrap `Promise.all` in a try/catch and log which files failed.

9. **Add a `--clean` flag.** When `process.argv[2] === '--clean'`, recursively delete the `./test-files/` directory with `fs.rmSync(dir, { recursive: true, force: true })` and exit.

10. **Wire up the main function.** Create an `async function main()` that calls `generateTestFiles()`, then `hashSequential()`, then `hashParallel()`, compares results, and prints the summary. Call `main().catch(console.error)` at the bottom (inside the `isMainThread` block).

## Break-Then-Harden Challenge

### Scenario 1 — Too Many Workers

Change the file count from 8 to 200. Observe what happens when you spawn 200 workers simultaneously — memory spikes, potential `ERR_WORKER_OUT_OF_MEMORY` errors, or system slowdown beyond the benefit of parallelism. Fix it by batching workers into groups of `os.availableParallelism()` (or `os.cpus().length`) and processing each batch with `Promise.all()` before starting the next batch. Verify that the batched approach is faster than sequential but more stable than spawning all 200 at once.

### Scenario 2 — Mismatched Hashes

Replace `fs.readFileSync()` inside the worker with a streaming read that only reads the first 1024 bytes (`fs.createReadStream(filePath, { end: 1023 })`). Observe that worker hashes no longer match sequential hashes because the worker is hashing a truncated file. Fix it by ensuring the worker reads the entire file — either via `readFileSync` or by piping a `createReadStream` (with no `end` option) into `crypto.createHash()` and waiting for the `'finish'` event.

### Scenario 3 — Worker Crash Recovery

Add `if (Math.random() < 0.3) throw new Error('random crash');` at the beginning of the worker code block, before hashing begins. Observe that approximately 30% of Promises reject and the overall `Promise.all()` rejects on the first failure. Fix it by using `Promise.allSettled()` instead of `Promise.all()`, retrying failed files (up to 3 attempts), and reporting which files succeeded versus failed after all retries are exhausted.

## Expected Output

```
$ node parallel-hasher.js

Generating 8 test files (10 MB each)...
Created: test-files/file-01.bin (10,485,760 bytes)
Created: test-files/file-02.bin (10,485,760 bytes)
Created: test-files/file-03.bin (10,485,760 bytes)
Created: test-files/file-04.bin (10,485,760 bytes)
Created: test-files/file-05.bin (10,485,760 bytes)
Created: test-files/file-06.bin (10,485,760 bytes)
Created: test-files/file-07.bin (10,485,760 bytes)
Created: test-files/file-08.bin (10,485,760 bytes)

--- Sequential Hashing ---
file-01.bin  a3f2b8c1d9e74f20...  42.3 ms
file-02.bin  7e1d9f04b3a862c5...  41.8 ms
file-03.bin  b5c8e2a7f1d09384...  43.1 ms
file-04.bin  2a9d4e6f8c1b3720...  42.0 ms
file-05.bin  d1f3a5b7c9e20468...  41.5 ms
file-06.bin  6e8c0a2d4f617b93...  42.7 ms
file-07.bin  f0d2b4a6c8e13957...  43.4 ms
file-08.bin  1b3d5f7a9c0e2846...  42.9 ms
Total sequential time: 339.7 ms

--- Parallel Hashing ---
file-01.bin  a3f2b8c1d9e74f20...  48.2 ms (worker time)
file-02.bin  7e1d9f04b3a862c5...  47.9 ms (worker time)
file-03.bin  b5c8e2a7f1d09384...  49.1 ms (worker time)
file-04.bin  2a9d4e6f8c1b3720...  47.4 ms (worker time)
file-05.bin  d1f3a5b7c9e20468...  48.8 ms (worker time)
file-06.bin  6e8c0a2d4f617b93...  47.2 ms (worker time)
file-07.bin  f0d2b4a6c8e13957...  49.6 ms (worker time)
file-08.bin  1b3d5f7a9c0e2846...  46.7 ms (worker time)
Total parallel time (wall-clock): 112.4 ms

--- Results ---
Hash verification: 8/8 match
Speedup factor: 3.02x
CPU cores available: 4
Theoretical max speedup: 4.00x (limited by core count)
```

## Bonus

1. **Streaming hash in workers.** Replace `readFileSync` in the worker with `fs.createReadStream()` piped into `crypto.createHash()`. Listen for the `'digest'` on the `'finish'` event. This allows hashing files larger than available memory. Measure whether the streaming approach changes the speedup factor.

2. **Variable file sizes.** Generate files with sizes ranging from 1 MB to 100 MB. Run both sequential and parallel hashing across all files. Print a text chart showing how the speedup factor changes with file size — small files may show less benefit due to worker startup overhead (typically 5-30 ms per worker).

## Hints

1. Use `new Worker(__filename, { workerData: { filePath } })` so the same file serves as both main script and worker script. The `isMainThread` guard routes execution to the correct code path.

2. Wrap each worker in a `new Promise((resolve, reject) => { ... })` and use `Promise.all()` to wait for all workers to finish. Each Promise resolves with `{ filePath, hash, elapsed }`.

3. `crypto.createHash('sha256').update(buffer).digest('hex')` gives you the hex-encoded SHA-256 hash of a Buffer in one line.

4. `performance.now()` from `node:perf_hooks` gives sub-millisecond timing resolution — use it for both sequential and parallel measurements. Avoid `Date.now()` which only gives millisecond precision.

5. Worker startup has overhead (typically 5-30 ms depending on the system). For very small files, this overhead can eliminate any parallelism benefit. The speedup factor should approach `Math.min(fileCount, cpuCoreCount)` for sufficiently large files.
