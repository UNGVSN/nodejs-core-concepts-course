# E01: File Copy Utility

> Build a `cp` clone from scratch using only Node.js core modules. This exercise bridges Buffers and the filesystem: you will handle large files with streams, preserve metadata, and walk directories recursively.

## Objective

Build a `copyfile.js` CLI tool that copies a single file or an entire directory tree from source to destination. The tool must preserve timestamps and permissions, handle files larger than available RAM by streaming, and provide a progress indicator for large copies. This is your first exercise combining `node:fs` read/write operations with real-world edge cases.

## Prerequisites

- Module 03, Lesson 05 (Buffer Reading and Writing)
- Module 04, Lesson 01 (File Descriptors and Handles)
- Module 04, Lesson 02 (Reading Files)
- Module 04, Lesson 03 (Writing Files)
- Module 04, Lesson 04 (File Stats and Metadata)
- Module 04, Lesson 05 (Directory Operations)

## Instructions

1. **Create `copyfile.js`** with `'use strict';` and require `node:fs`, `node:path`, and `node:stream` (for `pipeline`).

2. **Parse CLI arguments.** Accept `node copyfile.js <source> <destination> [--recursive]`. Validate that source exists. If destination is a directory and source is a file, join the source filename to the destination path.

3. **Implement `copyFileStreaming(src, dest)`.** Open a readable stream with `fs.createReadStream(src)` and a writable stream with `fs.createWriteStream(dest)`. Pipe them together using `require('node:stream').pipeline()`. Use the callback form to handle errors.

4. **Preserve metadata.** After the copy completes, use `fs.statSync(src)` to get the original file's mode (permissions) and timestamps. Apply them with `fs.chmodSync(dest, stat.mode)` and `fs.utimesSync(dest, stat.atime, stat.mtime)`.

5. **Add progress reporting.** Track bytes copied by listening to the `'data'` event on the read stream (or use `Transform` stream). Print progress as percentage and MB copied, using `\r` to overwrite the same line.

   ```javascript
   let bytesCopied = 0;
   readStream.on('data', (chunk) => {
     bytesCopied += chunk.length;
     const pct = ((bytesCopied / totalSize) * 100).toFixed(1);
     process.stdout.write(`\rCopying: ${pct}% (${(bytesCopied / 1048576).toFixed(1)} MB)`);
   });
   ```

6. **Implement `copyDirRecursive(src, dest)`.** Read the source directory with `fs.readdirSync(src, { withFileTypes: true })`. For each entry:
   - If it is a file, call `copyFileStreaming()`.
   - If it is a directory, create it with `fs.mkdirSync()` and recurse.
   - If it is a symlink, read the target with `fs.readlinkSync()` and recreate it with `fs.symlinkSync()`.

7. **Handle the `--recursive` flag.** If the source is a directory and `--recursive` is not set, print an error and exit. If it is set, call `copyDirRecursive()`.

8. **Prevent self-copy.** Resolve both source and destination to absolute paths with `path.resolve()`. If they are the same, abort with an error message.

9. **Handle destination conflicts.** If the destination file already exists, print a warning and skip (do not overwrite by default). Add a `--force` flag to overwrite.

10. **Test with real files.** Create a test directory with nested subdirectories, files of various sizes (including a 100 MB file generated with `node -e "require('node:fs').writeFileSync('big.bin', Buffer.alloc(100*1024*1024))"`), and a symlink. Verify the copy is byte-identical using `diff` or by comparing checksums.

## Break-Then-Harden Challenge

### Scenario 1 — Destination on Read-Only Filesystem
Copy a file to `/usr/bin/testfile` (or any read-only path). Observe the `EACCES` error. Fix by wrapping the write stream creation in a try/catch and printing a friendly error message with the path and required permissions.

### Scenario 2 — Source Disappears Mid-Copy
Start copying a large file. In another terminal, delete the source file while the copy is in progress. Observe the read stream error. Fix by handling the `'error'` event on the read stream: clean up the partial destination file with `fs.unlinkSync(dest)` and exit with a non-zero code.

### Scenario 3 — Circular Symlinks
Create a circular symlink: `ln -s dirA dirA/link_to_self`. Run your recursive copy. Observe infinite recursion or ELOOP error. Fix by tracking visited inodes (using `stat.ino`) in a `Set` and skipping already-visited directories.

## Expected Output

```
$ node copyfile.js largefile.bin backup/largefile.bin
Copying: 100.0% (95.4 MB)
Copied: largefile.bin -> backup/largefile.bin
  Size: 100,000,000 bytes
  Mode: 0644
  Modified: 2026-02-15T10:30:00.000Z

$ node copyfile.js src/ dest/ --recursive
Copying directory: src/ -> dest/
  src/index.js -> dest/index.js (2.1 KB)
  src/lib/ -> dest/lib/
  src/lib/utils.js -> dest/lib/utils.js (856 bytes)
  src/lib/config.js -> dest/lib/config.js (1.2 KB)
  src/data -> dest/data (symlink -> ../data)
Copied 3 files, 1 directory, 1 symlink

$ node copyfile.js src/ dest/
Error: src/ is a directory. Use --recursive to copy directories.

$ node copyfile.js copyfile.js copyfile.js
Error: Source and destination are the same file.
```

## Implementation Guidance

Here is a skeleton for the argument parser:

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { pipeline } = require('node:stream');

const args = process.argv.slice(2);
const flags = {
  recursive: args.includes('--recursive') || args.includes('-r'),
  force: args.includes('--force') || args.includes('-f'),
  verbose: args.includes('--verbose') || args.includes('-v'),
};
const positional = args.filter(a => !a.startsWith('--') && !a.startsWith('-'));

if (positional.length < 2) {
  console.error('Usage: node copyfile.js <source> <destination> [--recursive] [--force]');
  process.exit(1);
}

const [src, dest] = positional.map(p => path.resolve(p));
```

And the core copy function:

```javascript
function copyFileStreaming(src, dest, callback) {
  const stat = fs.statSync(src);
  const totalSize = stat.size;
  let bytesCopied = 0;

  const readStream = fs.createReadStream(src);
  const writeStream = fs.createWriteStream(dest);

  readStream.on('data', (chunk) => {
    bytesCopied += chunk.length;
    const pct = ((bytesCopied / totalSize) * 100).toFixed(1);
    process.stdout.write(`\rCopying: ${pct}% (${(bytesCopied / 1048576).toFixed(1)} MB)`);
  });

  pipeline(readStream, writeStream, (err) => {
    if (err) return callback(err);
    process.stdout.write('\n');
    // Preserve metadata
    fs.chmodSync(dest, stat.mode);
    fs.utimesSync(dest, stat.atime, stat.mtime);
    callback(null, { size: totalSize, mode: stat.mode, mtime: stat.mtime });
  });
}
```

## Bonus

1. **Add `--verbose` mode** that prints every file operation as it happens, including the `chmod` and `utimes` calls with their arguments.

2. **Add parallel directory copy.** When copying a directory, process up to 4 files concurrently using a simple concurrency limiter (counter + callback queue). Measure the speedup on an SSD vs sequential copy.

3. **Add checksum verification.** After copying, compute SHA-256 of both source and destination using `require('node:crypto').createHash('sha256')` fed by read streams. Report whether the copy is verified.

## Hints

1. `fs.statSync(src).isDirectory()` tells you if the source is a directory. `fs.statSync(src).isFile()` for files. `fs.lstatSync(src).isSymbolicLink()` for symlinks (use `lstat`, not `stat`, to avoid following the link).

2. `stream.pipeline(readStream, writeStream, callback)` handles error propagation and cleanup automatically — it is always preferred over `.pipe()`.

3. `fs.mkdirSync(dest, { recursive: true })` creates the entire directory tree if intermediate directories are missing.

4. `fs.utimesSync(dest, atime, mtime)` accepts `Date` objects or Unix timestamps in seconds. The `stat` object gives you `atime` and `mtime` as `Date` objects — pass them directly.

5. To generate a large test file without loading it into memory: `const ws = fs.createWriteStream('big.bin'); for (let i = 0; i < 100; i++) ws.write(Buffer.alloc(1024*1024)); ws.end();`
