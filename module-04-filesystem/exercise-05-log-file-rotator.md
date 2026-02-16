# E05: Log File Rotator

> Build a log rotation system that prevents log files from consuming all disk space. This is the same mechanism behind `logrotate` on Linux and the logging infrastructure of every production Node.js application.

## Objective

Build a `log-rotator.js` module that monitors a log file's size and rotates it when it exceeds a threshold. Rotation means renaming `app.log` to `app.log.1`, shifting previous backups (`app.log.1` becomes `app.log.2`, etc.), compressing old backups with gzip, and creating a fresh empty `app.log`. You will also build a log writer that continuously appends entries to test the rotation under load.

## Prerequisites

- Module 03, Lesson 05 (Buffer Reading and Writing)
- Module 04, Lesson 02 (Reading Files)
- Module 04, Lesson 03 (Writing Files)
- Module 04, Lesson 04 (File Stats and Metadata)
- Module 04, Lesson 05 (Directory Operations)

## Instructions

1. **Create `log-rotator.js`** with `'use strict';` and require `node:fs`, `node:path`, `node:zlib`, and `node:stream`.

2. **Define configuration constants.**

   ```javascript
   const config = {
     logFile: './app.log',
     maxSize: 1024 * 1024,  // 1 MB
     maxBackups: 5,          // keep 5 rotated files
     compress: true,         // gzip backups older than .1
     checkInterval: 5000,    // check size every 5 seconds
   };
   ```

3. **Implement `rotateSync(logFile, maxBackups, compress)`.** The rotation algorithm:
   - Delete the oldest backup if it exists: `app.log.5.gz` (or `app.log.5` if compression is off).
   - Shift each backup up by one: `app.log.4.gz` -> `app.log.5.gz`, `app.log.3.gz` -> `app.log.4.gz`, etc.
   - Handle the `.1` -> `.2` transition: compress `app.log.1` into `app.log.2.gz` if `compress` is true.
   - Rename the current log: `app.log` -> `app.log.1`.
   - Create a fresh empty `app.log` with `fs.writeFileSync(logFile, '')`.

   ```javascript
   function rotateSync(logFile, maxBackups, compress) {
     // Delete oldest
     const oldest = compress
       ? `${logFile}.${maxBackups}.gz`
       : `${logFile}.${maxBackups}`;
     if (fs.existsSync(oldest)) fs.unlinkSync(oldest);

     // Shift backups N -> N+1 (from maxBackups-1 down to 2)
     for (let i = maxBackups - 1; i >= 2; i--) {
       const src = compress ? `${logFile}.${i}.gz` : `${logFile}.${i}`;
       const dest = compress ? `${logFile}.${i + 1}.gz` : `${logFile}.${i + 1}`;
       if (fs.existsSync(src)) fs.renameSync(src, dest);
     }

     // Special: .1 -> .2 (compress .1 into .2.gz)
     if (fs.existsSync(`${logFile}.1`)) {
       if (compress) {
         compressFileSync(`${logFile}.1`, `${logFile}.2.gz`);
         fs.unlinkSync(`${logFile}.1`);
       } else {
         fs.renameSync(`${logFile}.1`, `${logFile}.2`);
       }
     }

     // Current -> .1 (uncompressed, most recent backup)
     if (fs.existsSync(logFile)) {
       fs.renameSync(logFile, `${logFile}.1`);
     }

     // Create fresh log file
     fs.writeFileSync(logFile, '');
   }
   ```

4. **Implement `compressFileSync(src, dest)`.** Read the source file, compress with `zlib.gzipSync()`, and write to the destination.

   ```javascript
   function compressFileSync(src, dest) {
     const data = fs.readFileSync(src);
     const compressed = require('node:zlib').gzipSync(data);
     fs.writeFileSync(dest, compressed);
   }
   ```

5. **Implement `shouldRotate(logFile, maxSize)`.** Check if the file exists and if its size exceeds `maxSize` using `fs.statSync()`. Return `true` or `false`.

6. **Implement `startRotationMonitor(config)`.** Use `setInterval` to periodically check the file size and trigger rotation when needed. Return the interval ID so it can be stopped.

   ```javascript
   function startRotationMonitor(config) {
     return setInterval(() => {
       if (shouldRotate(config.logFile, config.maxSize)) {
         console.log(`[${new Date().toISOString()}] Rotating ${config.logFile}`);
         rotateSync(config.logFile, config.maxBackups, config.compress);
       }
     }, config.checkInterval);
   }
   ```

7. **Build a log writer for testing.** Write a `generateLogs(logFile, linesPerSecond, lineSize)` function that appends timestamped log entries at a steady rate using `fs.appendFileSync()`. Each line should be a fixed size to make size calculations predictable.

   ```javascript
   function generateLogs(logFile, linesPerSecond, lineSize) {
     return setInterval(() => {
       const timestamp = new Date().toISOString();
       const padding = 'X'.repeat(lineSize - timestamp.length - 2);
       fs.appendFileSync(logFile, `${timestamp} ${padding}\n`);
     }, 1000 / linesPerSecond);
   }
   ```

8. **Implement `decompressAndRead(gzFile)`.** Read a `.gz` backup and decompress it with `zlib.gunzipSync()` to verify backup integrity. Print the first and last 3 lines.

9. **Add a summary command.** `node log-rotator.js --status` lists all log files and backups with their sizes and modification dates.

10. **Run an end-to-end test.** Start the log writer at 100 lines/sec with 1 KB lines (100 KB/sec). Set max size to 500 KB. Watch the rotation happen 2-3 times. Verify backup files exist and are compressed. Decompress a backup and verify its contents.

## Break-Then-Harden Challenge

### Scenario 1 — Write During Rotation
Start the log writer, then trigger rotation while writes are happening. With the naive approach (`rename` then `writeFile('')`), some log entries land in the renamed file after rotation starts. Fix by opening a new file descriptor for `app.log` immediately after the rename, so subsequent `appendFileSync` calls create the new file.

### Scenario 2 — Disk Full
Set `maxBackups` to 100 and `compress` to `false`. Generate logs until the disk is full (simulate with a small tmpfs or ramdisk). Observe the `ENOSPC` error. Fix by checking available disk space before rotation and by always deleting the oldest backup BEFORE creating new ones.

### Scenario 3 — Corrupt Gzip
Manually truncate a `.gz` backup file (`fs.truncateSync('app.log.2.gz', 10)`). Try to decompress it. Observe the `Z_DATA_ERROR`. Fix by wrapping `gunzipSync` in try/catch and reporting corrupt backups instead of crashing. Add a `--verify` flag that checks all backup integrity.

## Expected Output

```
$ node log-rotator.js
Starting log rotation demo...
  Log file:    ./app.log
  Max size:    512 KB
  Max backups: 5
  Compress:    yes
  Write rate:  100 lines/sec @ 1 KB/line

[2026-02-15T14:00:05.123Z] Writing logs... (0 KB)
[2026-02-15T14:00:10.456Z] Rotating ./app.log (524 KB > 512 KB)
[2026-02-15T14:00:10.478Z] Compressed app.log.1 -> app.log.2.gz (524 KB -> 42 KB)
[2026-02-15T14:00:15.789Z] Writing logs... (312 KB)
[2026-02-15T14:00:20.012Z] Rotating ./app.log (518 KB > 512 KB)

$ node log-rotator.js --status
Log File Status:
  app.log       312.0 KB   2026-02-15 14:00:22
  app.log.1     518.0 KB   2026-02-15 14:00:20
  app.log.2.gz   42.3 KB   2026-02-15 14:00:10
  app.log.3.gz   41.8 KB   2026-02-15 14:00:05
Total: 914.1 KB (4 files)

$ node log-rotator.js --verify
Verifying backups...
  app.log.1     OK (518,000 bytes, 518 lines)
  app.log.2.gz  OK (decompressed: 524,288 bytes, 524 lines)
  app.log.3.gz  CORRUPT (Z_DATA_ERROR: incorrect data check)
```

## Bonus

1. **Add time-based rotation.** In addition to size-based rotation, rotate daily at midnight regardless of file size. Use `setTimeout` to schedule the next midnight rotation.

2. **Add streaming compression.** Instead of reading the entire file into memory for gzip, use `fs.createReadStream()` piped through `zlib.createGzip()` into `fs.createWriteStream()`. This handles backup files larger than available RAM.

## Hints

1. `fs.statSync(file).size` returns the file size in bytes. Wrap in try/catch to handle the case where the file does not exist yet.

2. `zlib.gzipSync(buffer)` compresses synchronously. `zlib.gunzipSync(buffer)` decompresses. Both return a Buffer.

3. Loop backwards when shifting backups (`for (let i = max - 1; i >= 1; i--)`) to avoid overwriting files. If you loop forwards, `app.log.2` gets overwritten before it can be moved to `app.log.3`.

4. `fs.appendFileSync(file, data)` creates the file if it does not exist. It is safe to call after rotation creates the fresh empty log.

5. Compression ratios for text logs are typically 10:1 to 20:1. A 1 MB log compresses to 50-100 KB with gzip. This is why production systems compress all but the most recent backup.
