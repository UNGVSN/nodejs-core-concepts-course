# E04: Mandelbrot Set Generator

## Objective

Compute the Mandelbrot set in parallel by dividing the image into horizontal slices and assigning each slice to a worker thread. Workers write their computed pixel data directly into a `SharedArrayBuffer`, eliminating message-passing overhead for the pixel data. The main thread assembles the final image and writes it as a PPM file. This exercise demonstrates real-world CPU-bound parallelism with zero-copy shared memory output.

## Prerequisites

- Module 09 / Lesson 02 — The worker_threads Module
- Module 09 / Lesson 03 — Message Passing Between Threads
- Module 09 / Lesson 04 — SharedArrayBuffer & Atomics

## Instructions

1. **Create `mandelbrot.js`** with `'use strict';` at the top. Require the following:

```javascript
'use strict';

const {
  Worker, isMainThread, parentPort, workerData
} = require('node:worker_threads');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { performance } = require('node:perf_hooks');
```

2. **Define image parameters as constants.** Set `WIDTH = 800`, `HEIGHT = 600`, and `MAX_ITERATIONS = 1000`. Define the complex plane bounds that produce the classic Mandelbrot view: `RE_MIN = -2.5`, `RE_MAX = 1.0`, `IM_MIN = -1.0`, `IM_MAX = 1.0`.

3. **Allocate shared memory.** In the main thread, create a `SharedArrayBuffer` of size `WIDTH * HEIGHT * 3` bytes (3 bytes per pixel for R, G, B channels). Create a `Uint8Array` view over it. This buffer will be written to directly by workers and read by the main thread to produce the output file.

```javascript
const pixelBytes = WIDTH * HEIGHT * 3;
const sharedBuffer = new SharedArrayBuffer(pixelBytes);
const pixels = new Uint8Array(sharedBuffer);
```

4. **Implement the Mandelbrot iteration in the worker.** Each worker receives via `workerData`: the shared buffer, `startRow`, `endRow`, `WIDTH`, `HEIGHT`, `RE_MIN`, `RE_MAX`, `IM_MIN`, `IM_MAX`, and `MAX_ITERATIONS`. For each pixel `(px, py)` in its assigned row range, the worker:
   - Maps pixel coordinates to complex plane: `cr = RE_MIN + (px / WIDTH) * (RE_MAX - RE_MIN)` and `ci = IM_MIN + (py / HEIGHT) * (IM_MAX - IM_MIN)`
   - Iterates `z = z^2 + c` starting from `z = 0 + 0i`
   - Counts iterations until `|z|^2 > 4` (escape) or `MAX_ITERATIONS` is reached
   - Writes RGB color bytes into the shared buffer at the correct offset

```javascript
if (!isMainThread) {
  const { buffer, startRow, endRow, WIDTH, HEIGHT,
          RE_MIN, RE_MAX, IM_MIN, IM_MAX, MAX_ITERATIONS } = workerData;
  const pixels = new Uint8Array(buffer);

  for (let py = startRow; py < endRow; py++) {
    for (let px = 0; px < WIDTH; px++) {
      const cr = RE_MIN + (px / WIDTH) * (RE_MAX - RE_MIN);
      const ci = IM_MIN + (py / HEIGHT) * (IM_MAX - IM_MIN);

      let zr = 0, zi = 0;
      let iter = 0;
      while (zr * zr + zi * zi <= 4.0 && iter < MAX_ITERATIONS) {
        const tmp = zr * zr - zi * zi + cr;
        zi = 2 * zr * zi + ci;
        zr = tmp;
        iter++;
      }

      const offset = (py * WIDTH + px) * 3;
      if (iter === MAX_ITERATIONS) {
        pixels[offset] = 0;     // R
        pixels[offset + 1] = 0; // G
        pixels[offset + 2] = 0; // B (black = inside the set)
      } else {
        pixels[offset]     = (iter * 9) % 256;
        pixels[offset + 1] = (iter * 5) % 256;
        pixels[offset + 2] = (iter * 13) % 256;
      }
    }
  }

  parentPort.postMessage({ startRow, endRow, elapsed: performance.now() });
}
```

5. **Color mapping.** The code above uses a simple modulo-based color scheme: `r = (iter * 9) % 256`, `g = (iter * 5) % 256`, `b = (iter * 13) % 256`. Pixels that reach `MAX_ITERATIONS` are black (inside the Mandelbrot set). Escaped pixels get a color proportional to their escape iteration count.

6. **Spawn workers and divide rows.** Determine the worker count from `os.availableParallelism()` or a CLI argument. Divide `HEIGHT` rows among workers. Each worker gets a contiguous, non-overlapping range:

```javascript
const workerCount = parseInt(process.argv[2]) || os.availableParallelism();
const rowsPerWorker = Math.ceil(HEIGHT / workerCount);

for (let i = 0; i < workerCount; i++) {
  const startRow = i * rowsPerWorker;
  const endRow = Math.min(startRow + rowsPerWorker, HEIGHT);
  // Spawn worker with these bounds...
}
```

7. **Wait for completion.** Wrap each worker in a Promise that resolves on `'message'`. Use `Promise.all()` to wait for every worker. Once all resolve, the shared buffer contains the complete image.

8. **Write the PPM file.** PPM (Portable Pixmap) P6 format is the simplest binary image format. Write the ASCII header followed by raw RGB bytes:

```javascript
const header = `P6\n${WIDTH} ${HEIGHT}\n255\n`;
const headerBuf = Buffer.from(header, 'ascii');
const pixelBuf = Buffer.from(sharedBuffer);
const outputPath = path.join(__dirname, 'mandelbrot.ppm');
fs.writeFileSync(outputPath, Buffer.concat([headerBuf, pixelBuf]));
```

9. **Benchmark against sequential.** Also compute the Mandelbrot set sequentially in the main thread (single loop, same algorithm, writing to a plain `Uint8Array`). Measure wall-clock time for both approaches. Print the speedup factor.

10. **Accept CLI arguments.** Support overriding parameters via command line: `node mandelbrot.js [workers] [width] [height] [iterations]`. Print the configuration before starting computation.

## Break-Then-Harden Challenge

### Scenario 1 — Off-by-One Row Assignment

Change `endRow` to `startRow + rowsPerWorker` without the `Math.min(..., HEIGHT)` clamp. When `HEIGHT` is not evenly divisible by `workerCount`, the last worker writes past the end of the image (or one row is never computed, leaving a black stripe). Fix it by always clamping `endRow` to `HEIGHT` and verifying that the union of all `[startRow, endRow)` ranges covers `[0, HEIGHT)` exactly.

### Scenario 2 — Buffer Offset Miscalculation

Use `(py * WIDTH + px)` instead of `(py * WIDTH + px) * 3` when computing the byte offset. This writes RGB triplets into every third of the buffer, producing a garbled, compressed-looking image. Fix it by always multiplying by 3 (bytes per pixel) and add a comment explaining the formula.

### Scenario 3 — Non-Divisible Row Count

Set `HEIGHT = 601` and `workerCount = 4`. Since 601 is not divisible by 4, naive integer division (`Math.floor(601/4) = 150`) assigns rows 0-149, 150-299, 300-449, 450-599 — row 600 is never computed. Fix it by using `Math.ceil()` and clamping the last worker, ensuring all rows are covered with no gaps.

## Expected Output

```
$ node mandelbrot.js

Mandelbrot Set Generator
  Dimensions:  800 x 600 (480,000 pixels)
  Iterations:  1000
  Workers:     4
  Buffer size: 1,440,000 bytes (shared)

Computing sequentially (single thread)...
Sequential time: 1,847.2 ms

Computing in parallel (4 workers)...
Worker 0: rows   0-149  done (478.3 ms)
Worker 1: rows 150-299  done (512.1 ms)
Worker 2: rows 300-449  done (489.7 ms)
Worker 3: rows 450-599  done (467.9 ms)
Parallel time (wall-clock): 523.4 ms

Speedup: 3.53x (4 cores available)
Image written: mandelbrot.ppm (1,440,015 bytes)
Open with: open mandelbrot.ppm (macOS) or display mandelbrot.ppm (Linux)
```

## Bonus

1. **Smooth coloring.** Replace the simple modulo color mapping with the smooth iteration count algorithm: after escape, compute `smoothIter = iter + 1 - Math.log2(Math.log2(Math.sqrt(zr*zr + zi*zi)))`. Map `smoothIter` to a continuous HSV-to-RGB gradient for a visually dramatic result. Convert HSV to RGB with a pure-math function (no dependencies needed).

2. **Zoom mode.** Accept `--center-re`, `--center-im`, and `--zoom` arguments to render zoomed-in regions. For example, the Seahorse Valley: `--center-re -0.75 --center-im 0.1 --zoom 50`. Compute `RE_MIN/MAX` and `IM_MIN/MAX` from center and zoom factor. Increase `MAX_ITERATIONS` proportionally to zoom level for sharper detail.

## Hints

1. The Mandelbrot iteration formula is: `zr_new = zr*zr - zi*zi + cr` and `zi_new = 2*zr*zi + ci`. A point escapes the set when `zr*zr + zi*zi > 4.0` (equivalent to `|z| > 2`).

2. Map pixel `(px, py)` to complex coordinates with: `cr = RE_MIN + (px / WIDTH) * (RE_MAX - RE_MIN)` and `ci = IM_MIN + (py / HEIGHT) * (IM_MAX - IM_MIN)`.

3. The byte offset for pixel `(x, y)` in the shared buffer is `(y * WIDTH + x) * 3`. The three consecutive bytes at that offset store R, G, B values (each 0-255).

4. PPM files can be viewed with most image viewers: `open mandelbrot.ppm` on macOS, `display mandelbrot.ppm` or `eog mandelbrot.ppm` on Linux, IrfanView or GIMP on Windows. You can also convert to PNG with `convert mandelbrot.ppm mandelbrot.png` if ImageMagick is installed.

5. Workers write directly into the `SharedArrayBuffer` — no `postMessage` is needed to transfer pixel data. The only message workers send is a "done" signal with timing info. This is the key performance advantage of shared memory over message passing for large data.
