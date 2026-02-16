# E04: Progress Bar Stream

## Objective

Build a Transform stream that tracks the number of bytes passing through it, calculates progress as a percentage of the total file size, and renders a live-updating progress bar in the terminal. This stream can be inserted into any pipeline without altering the data — it is purely an observation tap that demonstrates how Transform streams enable composable, non-invasive instrumentation.

## Prerequisites

- Module 05 / Lesson 01 — Stream Fundamentals
- Module 05 / Lesson 05 — Duplex and Transform Streams
- Module 05 / Lesson 06 — Piping and Pipeline
- Module 04 / Lesson 01 — File System Foundations (`fs.statSync` for file size)

## Instructions

1. **Create the `ProgressTransform` class.** Extend `require('node:stream').Transform`. The constructor accepts `totalBytes` (the known total size) and an optional `label` string.

```js
'use strict';

const { Transform } = require('node:stream');

class ProgressTransform extends Transform {
  constructor(totalBytes, label = 'Progress') {
    super();
    this.totalBytes = totalBytes;
    this.label = label;
    this.bytesProcessed = 0;
    this.startTime = Date.now();
  }

  _transform(chunk, encoding, callback) {
    this.bytesProcessed += chunk.length;
    this._renderBar();
    callback(null, chunk);  // pass data through unchanged
  }

  _flush(callback) {
    this._renderBar();
    process.stderr.write('\n');
    callback();
  }
}
```

2. **Implement `_renderBar()`.** Calculate percentage (`bytesProcessed / totalBytes * 100`). Build a bar with filled and empty segments. Use `process.stderr.write('\r...')` to overwrite the same terminal line. Write to `stderr` so `stdout` remains clean for piped data.

```
Progress: [████████████████░░░░░░░░░░░░░░] 53.2% | 27.3 MB/s | ETA 4s
```

3. **Calculate throughput and ETA.** Track elapsed time. Compute bytes per second. Estimate remaining time: `(totalBytes - bytesProcessed) / bytesPerSecond`.

4. **Format bytes for humans.** Write a helper that displays bytes as KB, MB, or GB with one decimal place. Use it for the `bytesProcessed`, `totalBytes`, and throughput display.

5. **Build a file copy pipeline.** Use `pipeline()` to connect `fs.createReadStream(src)` -> `ProgressTransform` -> `fs.createWriteStream(dest)`. Get `totalBytes` from `fs.statSync(src).size`.

```js
const fs = require('node:fs');
const { pipeline } = require('node:stream');
const path = require('node:path');

const src = process.argv[2];
const dest = process.argv[3] || path.join(__dirname, 'copy-' + path.basename(src));
const { size } = fs.statSync(src);

pipeline(
  fs.createReadStream(src),
  new ProgressTransform(size, path.basename(src)),
  fs.createWriteStream(dest),
  (err) => {
    if (err) { console.error('Pipeline failed:', err.message); process.exit(1); }
    console.log(`\nCopied ${size} bytes successfully.`);
  }
);
```

6. **Handle edge cases.** If `totalBytes` is 0, display an indeterminate spinner instead of a percentage (cycle through `|`, `/`, `-`, `\`). If `totalBytes` is unknown (`null`), display only bytes processed and throughput without a percentage or ETA. If the source file does not exist, exit with code 1 and a clear error message.

7. **Emit progress events.** Make `ProgressTransform` emit a `'progress'` event with `{ bytesProcessed, totalBytes, percentage, bytesPerSecond }` every time the percentage crosses a whole-number threshold. External code can listen for this event without touching the terminal.

```js
_renderBar() {
  const pct = Math.min(100, (this.bytesProcessed / this.totalBytes) * 100);
  const wholePct = Math.floor(pct);

  if (wholePct > this.lastEmittedPct) {
    this.lastEmittedPct = wholePct;
    const elapsed = (Date.now() - this.startTime) / 1000;
    const bps = elapsed > 0 ? this.bytesProcessed / elapsed : 0;
    this.emit('progress', {
      bytesProcessed: this.bytesProcessed,
      totalBytes: this.totalBytes,
      percentage: pct,
      bytesPerSecond: bps,
    });
  }

  // Throttle visual rendering to 10 fps
  const now = Date.now();
  if (now - this.lastRenderTime < 100) return;
  this.lastRenderTime = now;

  // ... draw bar to stderr ...
}
```

8. **Support throttled rendering.** Only redraw the bar at most 10 times per second. If `_transform` is called more frequently (it will be), skip the render and only update `bytesProcessed`. This prevents terminal flicker and reduces syscall overhead.

9. **Print a completion summary.** After the pipeline finishes, print the source file name and size, destination path, total duration, and average throughput. Format all byte values with the human-readable helper from step 4.

10. **Accept CLI arguments.** The tool should be invoked as `node copy.js <source> [destination]`. If no destination is provided, default to `copy-<basename>` in the current directory. Validate that the source exists before starting.

## Break-Then-Harden Challenge

1. **Write to `stdout` instead of `stderr`.** The progress bar text will corrupt the file data if the output is piped to a file. Switch back to `stderr` and verify that `node copy.js big.bin /dev/null > /dev/null` still shows the progress bar (because it goes to stderr) while stdout is clean.

2. **Forget to call `callback(null, chunk)`.** If you call `callback()` without passing the chunk, the data is swallowed — the destination file will be empty. If you forget `callback()` entirely, the pipeline hangs. Reproduce both failure modes and then fix them.

3. **Pass a wrong `totalBytes`.** Set it to half the actual file size. The progress bar will hit 100% halfway through, then show >100% and a negative ETA. Add clamping logic: cap percentage at 100 and set ETA to "calculating..." when `bytesProcessed > totalBytes`.

## Expected Output

```
$ node copy.js test-large.bin output.bin

test-large.bin: [████████████████████████████░░] 93.7% | 245.1 MB/s | ETA 0s

Copied 536,870,912 bytes successfully.

Copy complete:
  Source:     test-large.bin (512.0 MB)
  Dest:       output.bin
  Duration:   2.08s
  Throughput: 246.1 MB/s
```

## Bonus

1. **Multi-file progress.** Accept a list of files as CLI arguments. Show one progress bar per file (stacked vertically using ANSI cursor movement), plus an overall progress bar at the bottom. This requires `\x1b[<N>A` (cursor up) and `\x1b[<N>B` (cursor down) escape codes.

2. **Pipe-friendly mode.** When `!process.stderr.isTTY` (piped to a file or another process), skip the progress bar entirely and only print a final summary line. This makes the tool well-behaved in automation scripts.

## Hints

1. `\r` (carriage return) moves the cursor to the beginning of the current line without advancing to the next line. Writing `\r` followed by your bar string overwrites the previous bar in place.

2. Use `process.stderr.columns` (or default to 80) to calculate the available width for the bar. Subtract space for the label, percentage, throughput, and ETA to determine how many `█` and `░` characters fit.

3. The `_flush(callback)` method is called once after all data has passed through. Use it to print the final 100% state and a newline so the bar does not get overwritten by subsequent output.

4. `Date.now()` returns milliseconds. For throughput, compute `this.bytesProcessed / ((Date.now() - this.startTime) / 1000)` to get bytes per second.

5. To throttle rendering, store `this.lastRenderTime` and only call the actual render logic when `Date.now() - this.lastRenderTime >= 100` (10 fps).
