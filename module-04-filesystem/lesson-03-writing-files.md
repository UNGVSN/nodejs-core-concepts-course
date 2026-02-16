# Module 04 / Lesson 03 — Writing Files

> Reading files is safe — the worst that happens is you get an error. Writing files is dangerous. A crash mid-write corrupts your config. A missing directory silently swallows your logs. A race condition between two writers interleaves their output into gibberish. This lesson teaches you every way Node.js can write to disk, from the simple one-liner to the atomic write pattern that production systems depend on.

## Learning Objectives

- Write files using `fs.writeFile()`, `fs.writeFileSync()`, and `fs.promises.writeFile()`
- Distinguish write flags (`'w'`, `'a'`, `'wx'`, `'ax'`) and choose the correct one for each scenario
- Use low-level `fs.open()` + `fs.write()` + `fs.close()` for positional writes and fine-grained control
- Implement the atomic write pattern (write to temp file, then rename) to prevent corruption
- Handle common write errors (`EACCES`, `ENOSPC`, `ENOENT`, `EEXIST`) with appropriate recovery strategies

---

## `writeFileSync` — Synchronous, Blocking

The simplest way to write a file. It blocks the event loop until the write completes. Use it only during startup or in CLI tools.

```javascript
'use strict';

const fs = require('node:fs');

// Write a string (default encoding: utf8)
fs.writeFileSync('/tmp/hello.txt', 'Hello, world!\n');

// Write with explicit encoding
fs.writeFileSync('/tmp/hello.txt', 'Hello, world!\n', 'utf8');

// Write with options object
fs.writeFileSync('/tmp/hello.txt', 'Hello, world!\n', {
  encoding: 'utf8',
  mode: 0o644,    // rw-r--r--
  flag: 'w',      // overwrite (default)
});

// Write a Buffer (no encoding needed)
const buf = Buffer.from([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x0A]);
fs.writeFileSync('/tmp/hello.bin', buf);

// Verify
const content = fs.readFileSync('/tmp/hello.txt', 'utf8');
console.log(content); // Hello, world!
```

---

## `writeFile` — Callback API

The asynchronous callback API writes the file without blocking the event loop.

```javascript
'use strict';

const fs = require('node:fs');

fs.writeFile('/tmp/async-hello.txt', 'Hello from callback!\n', 'utf8', (err) => {
  if (err) {
    console.error('Write failed:', err.message);
    return;
  }
  console.log('File written successfully');
});

// With options object
fs.writeFile('/tmp/async-hello.txt', 'Hello from callback!\n', {
  encoding: 'utf8',
  mode: 0o644,
  flag: 'w',
}, (err) => {
  if (err) {
    console.error('Write failed:', err.message);
    return;
  }
  console.log('File written with options');
});
```

---

## `fs.promises.writeFile` — The Modern Approach

The Promise-based API is the cleanest for modern async code.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function writeConfig(configPath, data) {
  const json = JSON.stringify(data, null, 2) + '\n';

  try {
    await fs.writeFile(configPath, json, 'utf8');
    console.log('Config written to', configPath);
  } catch (err) {
    console.error('Failed to write config:', err.message);
    throw err;
  }
}

writeConfig('/tmp/config.json', {
  port: 3000,
  host: '127.0.0.1',
  debug: false,
}).catch(console.error);
```

---

## Write Flags

The `flag` option controls how the file is opened for writing.

| Flag | Behavior | Creates File? | Fails If Exists? |
|------|----------|---------------|-------------------|
| `'w'` | Overwrite (truncate + write) | Yes | No |
| `'a'` | Append (write at end) | Yes | No |
| `'wx'` | Exclusive create + write | Yes | Yes (`EEXIST`) |
| `'ax'` | Exclusive create + append | Yes | Yes (`EEXIST`) |
| `'r+'` | Read and write (no truncate) | No | No (fails with `ENOENT`) |
| `'w+'` | Read and write (truncate) | Yes | No |

```javascript
'use strict';

const fs = require('node:fs');

// 'w' — Overwrite: creates file or truncates existing
fs.writeFileSync('/tmp/flag-test.txt', 'First write\n', { flag: 'w' });
fs.writeFileSync('/tmp/flag-test.txt', 'Second write\n', { flag: 'w' });
console.log(fs.readFileSync('/tmp/flag-test.txt', 'utf8'));
// Second write   ← first content is gone

// 'a' — Append: creates file or appends to existing
fs.writeFileSync('/tmp/flag-test.txt', 'Line 1\n', { flag: 'w' });
fs.writeFileSync('/tmp/flag-test.txt', 'Line 2\n', { flag: 'a' });
fs.writeFileSync('/tmp/flag-test.txt', 'Line 3\n', { flag: 'a' });
console.log(fs.readFileSync('/tmp/flag-test.txt', 'utf8'));
// Line 1
// Line 2
// Line 3

// 'wx' — Exclusive write: fails if file already exists
try {
  fs.writeFileSync('/tmp/flag-test.txt', 'Should fail\n', { flag: 'wx' });
} catch (err) {
  console.log(err.code); // EEXIST — file already exists
}

// 'wx' succeeds for a new file
fs.writeFileSync('/tmp/flag-test-new.txt', 'Created exclusively\n', { flag: 'wx' });
console.log(fs.readFileSync('/tmp/flag-test-new.txt', 'utf8'));
// Created exclusively
```

### When to Use Each Flag

- **`'w'` (default)**: Configuration files, generated reports, cache files — anything where the new content replaces the old completely.
- **`'a'`**: Log files, audit trails, append-only data stores — adding to the end without disturbing existing content.
- **`'wx'`**: Lock files, unique ID files, temp files — when you need a guarantee that you are the creator and no race condition can overwrite an existing file.
- **`'ax'`**: Append-only logs with creation guarantee — create and start appending, but fail if another process already created the file.

---

## `appendFile` — The Append Shortcut

`fs.appendFile()` is syntactic sugar for `writeFile` with `flag: 'a'`.

```javascript
'use strict';

const fs = require('node:fs');

// These two are equivalent:
fs.appendFileSync('/tmp/log.txt', 'Entry 1\n');
fs.writeFileSync('/tmp/log.txt', 'Entry 2\n', { flag: 'a' });

console.log(fs.readFileSync('/tmp/log.txt', 'utf8'));
// Entry 1
// Entry 2

// Promise-based append
const fsp = require('node:fs/promises');

async function appendLog(filePath, message) {
  const timestamp = new Date().toISOString();
  const line = `[${timestamp}] ${message}\n`;
  await fsp.appendFile(filePath, line, 'utf8');
}

// Usage:
// await appendLog('/tmp/app.log', 'Server started');
// await appendLog('/tmp/app.log', 'Request received');
```

Note: when multiple processes append to the same file, writes can interleave if each write exceeds `PIPE_BUF` (4096 bytes on Linux). Keep log lines short for safe concurrent appending with `O_APPEND`.

---

## Low-Level Writing: `open` + `write` + `close`

For fine-grained control — writing at specific positions, writing partial buffers, or keeping a file open across multiple writes — use the low-level API.

```javascript
'use strict';

const fs = require('node:fs');

// Open for writing (creates or truncates)
const fd = fs.openSync('/tmp/low-level.dat', 'w');

try {
  // Write a string at the current position
  const bytesWritten1 = fs.writeSync(fd, 'Hello, ');
  console.log('Bytes written:', bytesWritten1); // 7

  // Write more at the current position (continues after previous write)
  const bytesWritten2 = fs.writeSync(fd, 'world!\n');
  console.log('Bytes written:', bytesWritten2); // 7
} finally {
  fs.closeSync(fd);
}

console.log(fs.readFileSync('/tmp/low-level.dat', 'utf8')); // Hello, world!
```

### Writing at Specific Positions

```javascript
'use strict';

const fs = require('node:fs');

// Create a file with known content
fs.writeFileSync('/tmp/positional.dat', 'AAAAAAAAAA'); // 10 'A's

// Open for read+write (no truncation)
const fd = fs.openSync('/tmp/positional.dat', 'r+');

try {
  // Write 'BBB' starting at byte position 3
  const buf = Buffer.from('BBB');
  fs.writeSync(fd, buf, 0, buf.length, 3);

  // Write 'CC' starting at byte position 7
  const buf2 = Buffer.from('CC');
  fs.writeSync(fd, buf2, 0, buf2.length, 7);
} finally {
  fs.closeSync(fd);
}

console.log(fs.readFileSync('/tmp/positional.dat', 'utf8'));
// AAABBBACCAA  → original A's with B's and C's patched in
```

### Promise-Based Low-Level Write with FileHandle

```javascript
'use strict';

const fs = require('node:fs/promises');

async function writeBinaryHeader(filePath, version, flags, dataLength) {
  const handle = await fs.open(filePath, 'w');

  try {
    const header = Buffer.alloc(8);
    header.writeUInt16BE(version, 0);
    header.writeUInt16BE(flags, 2);
    header.writeUInt32BE(dataLength, 4);

    const { bytesWritten } = await handle.write(header, 0, header.length, 0);
    console.log(`Wrote ${bytesWritten} byte header`);
  } finally {
    await handle.close();
  }
}

writeBinaryHeader('/tmp/binary.dat', 1, 0x00FF, 1024).catch(console.error);
```

### FileHandle.writeFile()

```javascript
'use strict';

const fs = require('node:fs/promises');

async function writeViaHandle(filePath, content) {
  const handle = await fs.open(filePath, 'w');

  try {
    // writeFile on a FileHandle writes the entire content
    await handle.writeFile(content, 'utf8');
    console.log('Written via FileHandle');
  } finally {
    await handle.close();
  }
}

writeViaHandle('/tmp/handle-write.txt', 'Written via FileHandle API\n')
  .catch(console.error);
```

---

## Atomic Writes — Preventing Corruption

The single most important pattern for writing files in production. A crash, power failure, or kill signal during a `writeFile` call can leave a file half-written. The atomic write pattern prevents this.

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { randomBytes } = require('node:crypto');

function writeFileAtomic(filePath, data, options = {}) {
  const dir = path.dirname(filePath);
  const tmpName = path.join(dir, `.${path.basename(filePath)}.${randomBytes(6).toString('hex')}.tmp`);

  try {
    // Step 1: Write to a temporary file in the same directory
    fs.writeFileSync(tmpName, data, options);

    // Step 2: fsync to ensure data is flushed to disk
    const fd = fs.openSync(tmpName, 'r');
    fs.fsyncSync(fd);
    fs.closeSync(fd);

    // Step 3: Atomic rename (on the same filesystem, rename is atomic)
    fs.renameSync(tmpName, filePath);
  } catch (err) {
    // Clean up the temp file if anything failed
    try {
      fs.unlinkSync(tmpName);
    } catch {
      // Ignore cleanup errors
    }
    throw err;
  }
}

// Usage
writeFileAtomic('/tmp/config.json', JSON.stringify({ port: 3000 }, null, 2));
console.log('Atomic write complete');
console.log(fs.readFileSync('/tmp/config.json', 'utf8'));
```

### Why Atomic Writes Matter

```
Normal writeFile (DANGEROUS):

1. Open file (truncates to 0 bytes)    ← file is now EMPTY
2. Write bytes 0-1023                  ← crash here = partial file
3. Write bytes 1024-2047               ← crash here = partial file
4. Close file                          ← only now is file complete

Atomic write (SAFE):

1. Write to /tmp/.config.abc123.tmp    ← original file untouched
2. fsync the temp file                 ← data flushed to disk
3. rename temp → config.json           ← atomic operation (instant)

If crash occurs at step 1 or 2: original config.json is still intact
If crash occurs at step 3: extremely unlikely (rename is atomic)
```

### Async Atomic Write

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { randomBytes } = require('node:crypto');

async function writeFileAtomicAsync(filePath, data, options = {}) {
  const dir = path.dirname(filePath);
  const tmpName = path.join(
    dir,
    `.${path.basename(filePath)}.${randomBytes(6).toString('hex')}.tmp`
  );

  let handle;
  try {
    // Write and sync the temp file
    handle = await fs.open(tmpName, 'w', options.mode || 0o644);
    await handle.writeFile(data, options.encoding || 'utf8');
    await handle.sync(); // fsync — flush to disk
    await handle.close();
    handle = null;

    // Atomic rename
    await fs.rename(tmpName, filePath);
  } catch (err) {
    if (handle) await handle.close().catch(() => {});
    await fs.unlink(tmpName).catch(() => {});
    throw err;
  }
}

// Usage
writeFileAtomicAsync('/tmp/atomic-config.json', '{"status":"ok"}\n')
  .then(() => console.log('Async atomic write complete'))
  .catch(console.error);
```

---

## Writing Buffers vs Strings

```javascript
'use strict';

const fs = require('node:fs');

// Writing a string — Node.js encodes it to bytes using the specified encoding
fs.writeFileSync('/tmp/string-write.txt', 'Hello, world!\n', 'utf8');

// Writing a Buffer — bytes are written directly, no encoding step
const buf = Buffer.from('Hello, world!\n', 'utf8');
fs.writeFileSync('/tmp/buffer-write.txt', buf);

// Both produce identical files
const a = fs.readFileSync('/tmp/string-write.txt');
const b = fs.readFileSync('/tmp/buffer-write.txt');
console.log(a.equals(b)); // true

// When to use Buffer writes:
// - Binary data (images, audio, protocol messages)
// - When you already have a Buffer from another operation
// - When you need precise byte-level control

// When to use string writes:
// - Text files (config, logs, HTML, JSON)
// - When the data is already a string
// - When readability matters more than performance
```

---

## Error Handling

File writing produces specific, actionable errors. Handle each one appropriately.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function safeWrite(filePath, data) {
  try {
    await fs.writeFile(filePath, data, 'utf8');
    console.log(`Written: ${filePath}`);
  } catch (err) {
    switch (err.code) {
      case 'EACCES':
        console.error(`Permission denied: ${filePath}`);
        console.error('Check file ownership and chmod permissions');
        break;

      case 'ENOENT':
        console.error(`Directory does not exist for: ${filePath}`);
        console.error('Create the directory first with fs.mkdir(path, { recursive: true })');
        break;

      case 'ENOSPC':
        console.error('Disk full — cannot write file');
        console.error('Free disk space or write to a different volume');
        break;

      case 'EEXIST':
        console.error(`File already exists: ${filePath} (using 'wx' flag)`);
        break;

      case 'EISDIR':
        console.error(`Path is a directory, not a file: ${filePath}`);
        break;

      case 'EROFS':
        console.error('Read-only file system');
        break;

      default:
        console.error(`Unexpected write error [${err.code}]: ${err.message}`);
        throw err;
    }
  }
}
```

### Auto-Creating Parent Directories

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

async function writeFileEnsureDir(filePath, data, options = {}) {
  const dir = path.dirname(filePath);

  try {
    await fs.writeFile(filePath, data, options);
  } catch (err) {
    if (err.code === 'ENOENT') {
      // Parent directory does not exist — create it
      await fs.mkdir(dir, { recursive: true });
      await fs.writeFile(filePath, data, options);
    } else {
      throw err;
    }
  }
}

// This works even if /tmp/deep/nested/dir/ does not exist
writeFileEnsureDir('/tmp/deep/nested/dir/output.txt', 'Hello!\n')
  .then(() => console.log('Written with directory creation'))
  .catch(console.error);
```

---

## File Permissions: The `mode` Option

The `mode` option sets Unix file permissions on the created file.

```javascript
'use strict';

const fs = require('node:fs');

// Default mode: 0o666 (rw-rw-rw-), modified by umask (usually 0o022 → 0o644)
fs.writeFileSync('/tmp/default-perms.txt', 'default permissions\n');

// Explicit mode: owner read/write, group read, others nothing
fs.writeFileSync('/tmp/restricted.txt', 'restricted\n', { mode: 0o640 });

// Executable script
fs.writeFileSync('/tmp/script.sh', '#!/bin/bash\necho "Hello"\n', { mode: 0o755 });

// Permission reference:
// 0o644 = rw-r--r--  (owner rw, group r, others r) — typical file
// 0o600 = rw-------  (owner rw only) — secrets, keys
// 0o755 = rwxr-xr-x  (owner rwx, group rx, others rx) — executables
// 0o640 = rw-r-----  (owner rw, group r, others none) — group-shared config

// Verify permissions
const stats = fs.statSync('/tmp/restricted.txt');
console.log('Permissions:', '0o' + (stats.mode & 0o777).toString(8)); // 0o640
```

---

## Practical Patterns

### Pattern 1: Writing JSON Config

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { randomBytes } = require('node:crypto');

async function saveConfig(configPath, config) {
  // Validate input
  if (typeof config !== 'object' || config === null) {
    throw new TypeError('Config must be a non-null object');
  }

  // Pretty-print with trailing newline (POSIX convention)
  const json = JSON.stringify(config, null, 2) + '\n';

  // Atomic write to prevent corruption
  const dir = path.dirname(configPath);
  const tmpPath = path.join(dir, `.config.${randomBytes(4).toString('hex')}.tmp`);

  const handle = await fs.open(tmpPath, 'w', 0o644);
  try {
    await handle.writeFile(json, 'utf8');
    await handle.sync();
    await handle.close();
    await fs.rename(tmpPath, configPath);
  } catch (err) {
    await handle.close().catch(() => {});
    await fs.unlink(tmpPath).catch(() => {});
    throw err;
  }
}

saveConfig('/tmp/app-config.json', {
  server: { port: 8080, host: '0.0.0.0' },
  database: { url: 'postgres://localhost/mydb' },
  features: { darkMode: true, beta: false },
}).then(() => console.log('Config saved')).catch(console.error);
```

### Pattern 2: Append-Only Logger

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

class AppendLogger {
  constructor(logDir, prefix = 'app') {
    this._logDir = logDir;
    this._prefix = prefix;
    this._fd = null;
    this._currentDate = null;
    fs.mkdirSync(logDir, { recursive: true });
  }

  _ensureFd() {
    const now = new Date();
    const today = now.toISOString().slice(0, 10);

    if (this._currentDate !== today) {
      if (this._fd !== null) fs.closeSync(this._fd);
      const logPath = path.join(this._logDir, `${this._prefix}-${today}.log`);
      this._fd = fs.openSync(logPath, 'a');
      this._currentDate = today;
    }
    return this._fd;
  }

  log(level, message) {
    const fd = this._ensureFd();
    const timestamp = new Date().toISOString();
    fs.writeSync(fd, `[${timestamp}] [${level.toUpperCase()}] ${message}\n`);
  }

  close() {
    if (this._fd !== null) { fs.closeSync(this._fd); this._fd = null; }
  }
}

// Usage
const logger = new AppendLogger('/tmp/logs', 'myapp');
logger.log('info', 'Application started');
logger.log('error', 'Connection refused');
logger.close();
```

---

## `fsync` and `fdatasync` — Flushing to Disk

`writeFile` only guarantees that data reaches the OS kernel buffer, not the physical disk. A power failure after `writeFile` returns but before the OS flushes its buffers can lose data.

```javascript
'use strict';

const fs = require('node:fs');

// fsyncSync forces the OS to flush all data AND metadata to disk
const fd = fs.openSync('/tmp/durable.txt', 'w');
fs.writeSync(fd, 'This data must survive a power failure\n');
fs.fsyncSync(fd); // Data is now on disk (not just in OS cache)
fs.closeSync(fd);

// fdatasyncSync flushes data but not necessarily metadata (faster)
const fd2 = fs.openSync('/tmp/durable2.txt', 'w');
fs.writeSync(fd2, 'Data without metadata sync\n');
fs.fdatasyncSync(fd2); // Data on disk, metadata may still be cached
fs.closeSync(fd2);
```

| Method | Flushes Data | Flushes Metadata | Speed |
|--------|-------------|-----------------|-------|
| `writeFile` alone | To OS cache | To OS cache | Fast |
| `fsync` | To disk | To disk | Slow |
| `fdatasync` | To disk | Maybe | Medium |

---

## Key Takeaways

- `fs.promises.writeFile()` is the default choice for writing files in server-side code; use `writeFileSync` only during startup or in CLI tools
- Write flags control behavior: `'w'` overwrites, `'a'` appends, `'wx'` fails if the file exists (use for lock files and unique-creation guarantees)
- The atomic write pattern (write to temp file, `fsync`, then `rename`) prevents half-written files and is essential for any file that must survive crashes — configuration, databases, state files
- Always handle `EACCES` (permission denied), `ENOENT` (directory does not exist), `ENOSPC` (disk full), and `EEXIST` (exclusive create failed) explicitly in your error handling
- `fsync` ensures data reaches the physical disk, not just the OS buffer cache — critical for durability guarantees in databases, write-ahead logs, and transaction files

---

## Next

Continue to [Lesson 04 — File Stats & Metadata](lesson-04-file-stats-metadata.md) where you will learn how to inspect file size, timestamps, permissions, and type — and how to use this information for caching, monitoring, and security checks.
