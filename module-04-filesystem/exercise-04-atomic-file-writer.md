# E04: Atomic File Writer

> Write files that never corrupt, even if the process crashes mid-write. This exercise teaches the write-to-temp-then-rename pattern used by every serious database, editor, and configuration manager.

## Objective

Build an `atomic-write.js` module that writes files atomically: data goes to a temporary file in the same directory, then `fs.renameSync()` moves it to the final path in a single filesystem operation. Because `rename` is atomic on POSIX systems (when source and destination are on the same filesystem), the target file is either the old version or the new version — never a half-written corrupted mess. You will verify this by simulating crashes mid-write.

## Prerequisites

- Module 04, Lesson 01 (File Descriptors and Handles)
- Module 04, Lesson 02 (Reading Files)
- Module 04, Lesson 03 (Writing Files)
- Module 04, Lesson 04 (File Stats and Metadata)
- Module 04, Lesson 07 (Path Module)

## Instructions

1. **Create `atomic-write.js`** with `'use strict';` and require `node:fs`, `node:path`, `node:crypto`, and `node:os`.

2. **Implement `atomicWriteSync(filePath, data, options)`.** The algorithm:
   - Generate a temp filename in the same directory: `path.join(dir, '.tmp-' + crypto.randomBytes(8).toString('hex'))`.
   - Write data to the temp file with `fs.writeFileSync(tempPath, data, options)`.
   - If `options.mode` is specified, apply it with `fs.chmodSync(tempPath, options.mode)`.
   - Call `fs.renameSync(tempPath, filePath)` to atomically replace the target.
   - Wrap everything in try/catch: if any step fails, clean up the temp file with `fs.unlinkSync(tempPath)` in the catch block.

   ```javascript
   function atomicWriteSync(filePath, data, options = {}) {
     const dir = path.dirname(filePath);
     const tempPath = path.join(dir, '.tmp-' + crypto.randomBytes(8).toString('hex'));
     try {
       fs.writeFileSync(tempPath, data, options);
       if (options.mode) fs.chmodSync(tempPath, options.mode);
       fs.renameSync(tempPath, filePath);
     } catch (err) {
       try { fs.unlinkSync(tempPath); } catch (_) {}
       throw err;
     }
   }
   ```

3. **Implement `atomicWriteAsync(filePath, data, options, callback)`.** Same algorithm but using `fs.writeFile`, `fs.chmod`, `fs.rename`, and `fs.unlink` with callbacks (no Promises — practice the callback pattern).

4. **Implement `atomicWriteJSON(filePath, obj, options)`.** A convenience wrapper that calls `JSON.stringify(obj, null, 2)` then `atomicWriteSync`. Add a trailing newline.

5. **Build a crash simulation test.** Write a script that:
   - Creates a config file with known content using `atomicWriteSync`.
   - Starts a child process (using `require('node:child_process').fork()`) that writes a large file (10 MB) using REGULAR `fs.writeFileSync`.
   - Kills the child with `process.kill(child.pid, 'SIGKILL')` after 5ms.
   - Checks the file: is it complete, truncated, or missing?
   - Repeats the test with `atomicWriteSync` — the file should always be either the old version or fully complete.

6. **Add `fsync` support.** Before the rename, call `fs.fsyncSync(fd)` on the temp file to flush OS buffers to disk. This makes the write durable against power failures, not just process crashes. Open the temp file with `fs.openSync`, write, fsync, close, then rename.

   ```javascript
   const fd = fs.openSync(tempPath, 'w', options.mode || 0o644);
   fs.writeSync(fd, data);
   fs.fsyncSync(fd);
   fs.closeSync(fd);
   fs.renameSync(tempPath, filePath);
   ```

7. **Add directory fsync.** After the rename, open the directory itself and `fsync` it. This ensures the directory entry update is flushed to disk. On Linux, this is necessary for full crash safety.

   ```javascript
   const dirFd = fs.openSync(dir, 'r');
   fs.fsyncSync(dirFd);
   fs.closeSync(dirFd);
   ```

8. **Handle cross-device rename.** `fs.renameSync` fails with `EXDEV` if the temp file and target are on different filesystems. Detect this error and fall back to copy + unlink (non-atomic, but the best you can do).

9. **Write a concurrency test.** Launch 10 concurrent writes to the same file path from 10 `setTimeout` callbacks, each with different content. Verify that the final file contains one of the 10 values — never a mix. Without atomic writes, race conditions produce corrupted output.

10. **Build a CLI demo.** `node atomic-write.js <file> <content>` writes content atomically. `node atomic-write.js --test` runs the crash simulation.

## Break-Then-Harden Challenge

### Scenario 1 — Temp File in /tmp
Change the temp file location to `os.tmpdir()` instead of the same directory as the target. Attempt the rename. On most systems, `/tmp` is a different filesystem, so `renameSync` throws `EXDEV`. Fix by always creating the temp file in `path.dirname(filePath)`.

### Scenario 2 — No Cleanup on Error
Remove the `try/catch` around the write + rename. Trigger an error (e.g., write to a read-only directory). Observe orphaned `.tmp-*` files accumulating. Fix by restoring the cleanup logic and adding a `cleanupOrphans(dir)` function that removes any `.tmp-*` files older than 1 hour.

### Scenario 3 — Race Between Read and Write
Start a continuous reader that reads the config file every 1ms. Start a writer that atomically writes new content every 5ms. Without atomic writes, the reader occasionally gets empty or partial content. With atomic writes, the reader always sees a complete file. Verify this with a 5-second stress test.

## Expected Output

```
$ node atomic-write.js config.json '{"port": 3000}'
Atomic write complete: config.json (15 bytes)
  Temp file: .tmp-a3b2c1d4e5f6a7b8
  fsync: yes
  Rename: .tmp-a3b2c1d4e5f6a7b8 -> config.json

$ node atomic-write.js --test
=== Crash Simulation Test ===

Regular writeFileSync with SIGKILL:
  Trial 1: file truncated (4,194,304 of 10,485,760 bytes) CORRUPTED
  Trial 2: file truncated (7,340,032 of 10,485,760 bytes) CORRUPTED
  Trial 3: file complete (10,485,760 bytes) OK

Atomic write with SIGKILL:
  Trial 1: file is old version (1,024 bytes) SAFE
  Trial 2: file is new version (10,485,760 bytes) SAFE
  Trial 3: file is old version (1,024 bytes) SAFE

Result: atomic write prevents corruption in all cases.

=== Concurrency Test ===
10 concurrent writers, 100 iterations...
  Corrupted reads: 0 / 1000
  Result: PASS
```

## Implementation Guidance

Here is the orphan cleanup function for the Break-Then-Harden challenge:

```javascript
function cleanupOrphans(dir, maxAgeMs = 3600000) {
  const entries = fs.readdirSync(dir);
  let cleaned = 0;
  for (const name of entries) {
    if (!name.startsWith('.tmp-')) continue;
    const fullPath = path.join(dir, name);
    try {
      const stat = fs.statSync(fullPath);
      if (Date.now() - stat.mtimeMs > maxAgeMs) {
        fs.unlinkSync(fullPath);
        cleaned++;
        console.log(`  Cleaned orphan: ${name} (age: ${((Date.now() - stat.mtimeMs) / 60000).toFixed(0)} min)`);
      }
    } catch (_) { /* file may have been deleted between readdir and stat */ }
  }
  return cleaned;
}
```

And the concurrency test skeleton:

```javascript
function concurrencyTest(filePath, numWriters, iterations) {
  let corrupted = 0;
  // Write initial content
  atomicWriteSync(filePath, 'initial');

  for (let iter = 0; iter < iterations; iter++) {
    // Launch numWriters concurrent writes
    const promises = [];
    for (let w = 0; w < numWriters; w++) {
      const content = `writer-${w}-iter-${iter}-${'X'.repeat(1000)}`;
      setTimeout(() => atomicWriteSync(filePath, content), 0);
    }
    // Read and verify no mixed content
    const result = fs.readFileSync(filePath, 'utf8');
    if (!result.startsWith('writer-') && result !== 'initial') {
      corrupted++;
    }
  }
  return corrupted;
}
```

## Bonus

1. **Add backup rotation.** Before the atomic rename, copy the existing file to `filePath + '.bak'`. Keep up to 3 backups (`.bak`, `.bak.1`, `.bak.2`), rotating them on each write.

2. **Implement a simple write-ahead log (WAL).** Before writing, append the operation to a `wal.log` file. After the rename, mark the WAL entry as committed. On startup, replay any uncommitted WAL entries. This is how databases recover from crashes.

## Hints

1. `crypto.randomBytes(8).toString('hex')` generates a 16-character random hex string for unique temp filenames. This avoids collisions when multiple processes write simultaneously.

2. `fs.renameSync()` is atomic on POSIX when source and dest are on the same filesystem. On Windows, it is atomic as of Node.js 14+ (uses `MoveFileEx` with `MOVEFILE_REPLACE_EXISTING`).

3. `fs.fsyncSync(fd)` flushes both data and metadata to disk. `fs.fdatasyncSync(fd)` flushes only data (slightly faster, skips metadata like atime). Use `fsync` for maximum safety.

4. To detect cross-device: `catch (err) { if (err.code === 'EXDEV') { /* fallback */ } else { throw err; } }`.

5. The temp file prefix `.tmp-` makes orphaned files easy to find and clean up. Adding a timestamp or PID to the name helps with debugging: `.tmp-${process.pid}-${Date.now()}-${random}`.
