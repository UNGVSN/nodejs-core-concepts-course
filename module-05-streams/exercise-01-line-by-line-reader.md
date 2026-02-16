# E01: Line-by-Line File Reader

## Objective

Build a streaming line-by-line file reader that processes arbitrarily large files without loading them into memory. Your reader must correctly handle lines that are split across chunk boundaries — the trickiest edge case in stream-based text processing. You will count total lines, track the longest line, and report memory usage to prove the solution stays constant regardless of file size.
This pattern is the foundation for log processing, CSV parsing, and any text-oriented stream pipeline.

## Prerequisites

- Module 05 / Lesson 01 — Stream Fundamentals
- Module 05 / Lesson 02 — Readable Streams
- Module 05 / Lesson 05 — Duplex and Transform Streams
- Module 04 / Lesson 02 — Reading Files (for `fs.createReadStream`)

## Instructions

1. **Generate a test file.** Write a script `generate-test-file.js` that creates a file with at least 1 million lines. Each line should contain a line number, a random word length (between 10 and 200 characters), and a newline character. The file should be at least 100 MB. Note how the generator itself respects backpressure by checking the return value of `ws.write()`.

```js
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const filePath = path.join(__dirname, 'test-large.txt');
const ws = fs.createWriteStream(filePath);

const TOTAL_LINES = 1_000_000;
let i = 0;

function write() {
  let ok = true;
  while (i < TOTAL_LINES && ok) {
    const len = 10 + Math.floor(Math.random() * 190);
    const line = `${i + 1}: ${'x'.repeat(len)}\n`;
    ok = ws.write(line);
    i++;
  }
  if (i < TOTAL_LINES) {
    ws.once('drain', write);
  } else {
    ws.end();
    console.log(`Generated ${TOTAL_LINES} lines → ${filePath}`);
  }
}

write();
```

2. **Create `line-reader.js`.** Open the generated file with `fs.createReadStream()`. Set `highWaterMark` to `64 * 1024` (64 KB) so you can observe chunked delivery. Accept the file path as a CLI argument with a sensible default.

```js
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const filePath = process.argv[2] || path.join(__dirname, 'test-large.txt');
const HWM = parseInt(process.argv[3] || String(64 * 1024), 10);

const readable = fs.createReadStream(filePath, { highWaterMark: HWM });
console.log(`Processing: ${path.basename(filePath)}`);
console.log(`  highWaterMark: ${HWM} bytes`);
```

3. **Handle chunk boundaries.** Maintain a `remainder` string that holds the tail of the previous chunk (the part after the last `\n`). When a new chunk arrives, prepend `remainder` to the chunk, split by `\n`, and set `remainder` to the final element (which may be incomplete).

4. **Process each line.** For every complete line, increment a `lineCount` counter. Track the longest line seen so far (store its length and line number). Track the shortest line too. Accumulate `totalBytes` by adding `chunk.length` on each `'data'` event.

5. **Handle the final remainder.** When the `'end'` event fires, check if `remainder` is non-empty — if so, it is the last line of the file (no trailing newline). Process it as the final line. If `remainder` is empty (file ended with `\n`), do nothing extra.

6. **Report memory usage.** Every 100,000 lines, log `process.memoryUsage().heapUsed` formatted in MB. This proves memory stays flat. Use a helper function to format bytes:

```js
function formatMB(bytes) {
  return (bytes / 1024 / 1024).toFixed(2);
}
```

7. **Print a summary.** After processing completes, print total lines, longest line number and length, shortest line number and length, total bytes read, final heap usage, and wall-clock duration.

8. **Add error handling.** Listen for `'error'` on the readable stream. If the file does not exist, print a clear message and exit with code 1. Also handle the case where the path points to a directory instead of a file.

9. **Validate with `wc -l`.** After running your reader, run `wc -l test-large.txt` in the terminal. The counts should match exactly. If they differ, your boundary handling or final-remainder logic has a bug.

10. **Refactor into a reusable function.** Wrap your logic into a `readLines(filePath, options)` function that returns a `Promise` resolving with `{ lineCount, longestLine, shortestLine, totalBytes, duration }`. This makes the reader composable for use in later exercises. Export it with `module.exports = { readLines };` so other scripts can `require()` it.

## Break-Then-Harden Challenge

1. **Remove the remainder logic.** Delete the code that carries incomplete lines across chunk boundaries. Run against the test file and observe that some "lines" are truncated or merged. Count the lines — the total will be wrong. Now restore the remainder logic and confirm the count matches.

2. **Set `highWaterMark` to 7 bytes.** This guarantees almost every line is split across multiple chunks. Verify your reader still produces the exact same line count and longest-line result as with the default `highWaterMark`. If it does not, your boundary handling has a bug.

3. **Feed a file with no trailing newline.** Create a test file where the last line has no `\n`. Verify your reader still counts and processes that final line. Then create a file that is completely empty (0 bytes) and confirm your reader handles it gracefully — it should report 0 lines, not crash or report 1 empty line.

4. **Test with a single-character file.** Create a file containing only `"a"` (1 byte, no newline). Your reader should report exactly 1 line of length 1. This edge case catches off-by-one errors in the remainder logic.

5. **Test with only newlines.** Create a file containing `"\n\n\n"` (3 newlines). Decide: does your reader count 3 empty lines, or 2 empty lines plus an empty remainder? Document your decision and be consistent.

## Expected Output

```
Processing: test-large.txt
  highWaterMark: 65536 bytes
  100,000 lines — heap: 8.42 MB
  200,000 lines — heap: 8.51 MB
  300,000 lines — heap: 8.47 MB
  400,000 lines — heap: 8.53 MB
  500,000 lines — heap: 8.49 MB
  600,000 lines — heap: 8.52 MB
  700,000 lines — heap: 8.48 MB
  800,000 lines — heap: 8.54 MB
  900,000 lines — heap: 8.50 MB
  1,000,000 lines — heap: 8.53 MB

Summary:
  Total lines:    1,000,000
  Longest line:   #742,318 (209 chars)
  Bytes read:     112,847,291
  Final heap:     8.53 MB
  Duration:       1.23s
```

## Bonus

1. **Accept a regex filter.** Add a `--grep <pattern>` CLI flag that only counts and reports lines matching the pattern. Print matching line count vs total line count. Example: `node line-reader.js test-large.txt --grep "^42:"` should find exactly one line.

2. **Compare with `fs.readFileSync`.** Write a version that uses `readFileSync` + `split('\n')` on the same file. Compare peak memory usage (`process.memoryUsage().rss`) between the two approaches and print a side-by-side comparison:

```
Method           | Lines     | Peak RSS  | Duration
Streaming        | 1,000,000 | 23 MB     | 1.23s
readFileSync     | 1,000,000 | 287 MB    | 0.98s
```

Note that `readFileSync` may be slightly faster (no event loop overhead), but uses 10-15x more memory. This is the core streams trade-off.

## Hints

1. When you call `chunk.toString().split('\n')`, the last element of the resulting array is either an empty string (if the chunk ended with `\n`) or an incomplete line. Either way, it becomes your new `remainder`.

2. Use `const parts = (remainder + chunk.toString()).split('\n');` then set `remainder = parts.pop();` — the `pop()` removes and returns the last element in one step.

3. To measure elapsed time, capture `process.hrtime.bigint()` at the start and compute the difference at the end. Divide by `1_000_000n` for milliseconds or `1_000_000_000n` for seconds.

4. The `'data'` event gives you a `Buffer`. You must call `.toString()` (or set `encoding: 'utf8'` on the stream) before splitting by `'\n'`. Setting the encoding on the stream is slightly more efficient because the stream decoder handles multi-byte character boundaries for you.

5. Memory should stay under 20 MB regardless of file size. If it grows linearly, you are accumulating data somewhere — check that you are not pushing lines into an array. The only state you should maintain is `remainder` (one partial line), `lineCount`, `longestLine`, and `totalBytes`.

6. The `'end'` event fires after all data has been consumed. The `'close'` event fires after the file descriptor is released. Use `'end'` for processing the final remainder; use `'close'` for cleanup if needed.
