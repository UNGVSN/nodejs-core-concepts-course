# Module 04 / Lesson 01 — File Descriptors & Handles

> Every file operation in Node.js — every read, every write, every stat — ultimately passes through a file descriptor. A file descriptor is just an integer, but it is the operating system's way of tracking every open file, socket, pipe, and device in your process. Understanding file descriptors is understanding the real cost of file operations: why you must close files, why you can run out of handles, and why the Promises API introduced `FileHandle` to make this safer.

## Learning Objectives

- Define what a file descriptor is and how the operating system assigns them
- Open and close files using `fs.open()` and `fs.close()` in callback, sync, and Promise APIs
- Identify the three standard file descriptors (0, 1, 2) and their role in stdin, stdout, stderr
- Use `FileHandle` from the `fs.promises` API for safer, auto-closable file operations
- Recognize and prevent file descriptor leaks in long-running servers

---

## What Is a File Descriptor?

A file descriptor (fd) is a non-negative integer that the operating system kernel assigns to every open file, socket, pipe, or device in a process. When your Node.js program calls `fs.open()`, the kernel finds an available slot in the process's file descriptor table, assigns the lowest available integer, and returns it.

```
Process File Descriptor Table:
┌─────┬──────────────────────────────┐
│ fd  │ Kernel Resource              │
├─────┼──────────────────────────────┤
│  0  │ stdin  (keyboard / pipe)     │
│  1  │ stdout (terminal / pipe)     │
│  2  │ stderr (terminal / pipe)     │
│  3  │ /var/log/app.log (your file) │
│  4  │ TCP socket to 10.0.0.1:5432  │
│  5  │ /etc/config.json (your file) │
└─────┴──────────────────────────────┘
```

When you read from or write to a file, you pass the fd to the kernel. The kernel looks up the fd in the table, finds the underlying resource, and performs the operation. When you close the file, the kernel frees that slot, and the integer becomes available for reuse.

---

## The Three Standard File Descriptors

Every Unix process starts with three file descriptors already open:

| fd | Name | Constant | Node.js Object |
|----|------|----------|-----------------|
| 0 | Standard input | `STDIN_FILENO` | `process.stdin` |
| 1 | Standard output | `STDOUT_FILENO` | `process.stdout` |
| 2 | Standard error | `STDERR_FILENO` | `process.stderr` |

```javascript
'use strict';

const fs = require('node:fs');

// Write directly to stdout using fd 1
fs.writeSync(1, 'Hello from fd 1!\n');

// Write directly to stderr using fd 2
fs.writeSync(2, 'Error from fd 2!\n');

// Read from stdin using fd 0 (synchronous, blocking)
// const input = Buffer.alloc(256);
// const bytesRead = fs.readSync(0, input, 0, 256, null);
// console.log('You typed:', input.toString('utf8', 0, bytesRead));
```

These three fds are the foundation of Unix I/O redirection. When you run `node app.js > output.log`, the shell opens `output.log` and assigns it to fd 1 before your process starts. Your code writes to fd 1 thinking it is the terminal, but the bytes go to the file instead.

---

## Opening Files with `fs.open()`

### Callback API

```javascript
'use strict';

const fs = require('node:fs');

fs.open('/tmp/test.txt', 'w', (err, fd) => {
  if (err) {
    console.error('Failed to open:', err.message);
    return;
  }

  console.log('Opened file, fd:', fd); // e.g., 3

  // Write some data using the fd
  const data = Buffer.from('Hello, file descriptor!\n');
  fs.write(fd, data, 0, data.length, null, (writeErr, bytesWritten) => {
    if (writeErr) {
      console.error('Write failed:', writeErr.message);
    } else {
      console.log('Wrote', bytesWritten, 'bytes');
    }

    // ALWAYS close the fd when done
    fs.close(fd, (closeErr) => {
      if (closeErr) console.error('Close failed:', closeErr.message);
      else console.log('File closed');
    });
  });
});
```

### Synchronous API

```javascript
'use strict';

const fs = require('node:fs');

let fd;
try {
  fd = fs.openSync('/tmp/test.txt', 'w');
  console.log('Opened file, fd:', fd);

  const data = Buffer.from('Hello, sync!\n');
  fs.writeSync(fd, data);
  console.log('Written');
} catch (err) {
  console.error('Error:', err.message);
} finally {
  // 'finally' guarantees close even if write throws
  if (fd !== undefined) {
    fs.closeSync(fd);
    console.log('Closed');
  }
}
```

### File Open Flags

The second argument to `fs.open()` is a string flag that controls how the file is opened.

| Flag | Description |
|------|-------------|
| `'r'` | Open for reading. Fails if file does not exist. |
| `'r+'` | Open for reading and writing. Fails if file does not exist. |
| `'w'` | Open for writing. Creates the file or truncates it to zero length. |
| `'w+'` | Open for reading and writing. Creates or truncates. |
| `'a'` | Open for appending. Creates the file if it does not exist. |
| `'a+'` | Open for reading and appending. Creates if needed. |
| `'wx'` | Like `'w'` but fails if the file already exists (exclusive creation). |
| `'ax'` | Like `'a'` but fails if the file already exists. |

```javascript
'use strict';

const fs = require('node:fs');

// Exclusive create — fails if file exists (prevents overwriting)
try {
  const fd = fs.openSync('/tmp/unique-file.txt', 'wx');
  fs.writeSync(fd, 'Created exclusively\n');
  fs.closeSync(fd);
} catch (err) {
  if (err.code === 'EEXIST') {
    console.log('File already exists — not overwritten');
  } else {
    throw err;
  }
}
```

---

## FileHandle: The Promises API Approach

The `fs.promises` API returns `FileHandle` objects instead of raw integer fds. `FileHandle` wraps the fd in an object with async methods and, critically, supports explicit cleanup.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function writeWithHandle() {
  const handle = await fs.open('/tmp/handle-test.txt', 'w');

  try {
    console.log('FileHandle fd:', handle.fd); // The underlying integer fd

    await handle.write('Hello from FileHandle!\n');
    await handle.write('Second line\n');

    // Flush to disk
    await handle.sync();
  } finally {
    await handle.close();
    console.log('Handle closed');
  }
}

writeWithHandle().catch(console.error);
```

### FileHandle Methods

`FileHandle` provides Promise-based versions of all fd-level operations:

```javascript
'use strict';

const fs = require('node:fs/promises');

async function demonstrateHandle() {
  const handle = await fs.open('/tmp/handle-demo.txt', 'w+');

  try {
    // Write
    await handle.writeFile('Line 1\nLine 2\nLine 3\n');

    // Seek back to the beginning and read
    const contents = await handle.readFile({ encoding: 'utf8' });
    console.log(contents);

    // Stat
    const stats = await handle.stat();
    console.log('File size:', stats.size);

    // Truncate
    await handle.truncate(6); // Keep only "Line 1"

    // Read again
    const truncated = await handle.readFile({ encoding: 'utf8' });
    console.log('After truncate:', truncated);

    // Change permissions
    await handle.chmod(0o644);

  } finally {
    await handle.close();
  }
}

demonstrateHandle().catch(console.error);
```

### Why FileHandle Is Better Than Raw fds

1. **Method chaining**: Operations are methods on the handle, not standalone functions that take an fd.
2. **Garbage collection safety**: If a `FileHandle` is garbage collected without being closed, Node.js emits a warning and closes it automatically (but you should never rely on this).
3. **Cleaner error handling**: `try/finally` with `await handle.close()` is cleaner than nested callbacks.

---

## File Descriptor Limits

Every process has a limit on how many file descriptors it can have open simultaneously. On most Linux systems, the default is 1024 per process.

```javascript
'use strict';

const fs = require('node:fs');

// Check the soft limit (you can check via 'ulimit -n' in the shell)
// Node.js does not expose this directly, but you can observe it

const handles = [];

try {
  for (let i = 0; i < 2000; i++) {
    const fd = fs.openSync('/dev/null', 'r');
    handles.push(fd);
  }
} catch (err) {
  console.log(`Opened ${handles.length} files before error`);
  console.log('Error:', err.message); // EMFILE: too many open files
  console.log('Code:', err.code);     // EMFILE
} finally {
  // Clean up all opened fds
  for (const fd of handles) {
    fs.closeSync(fd);
  }
}
```

The `EMFILE` error ("too many open files") is one of the most common production issues in Node.js servers. It happens when your code opens files faster than it closes them.

### Increasing the Limit

```bash
# Check current limit
ulimit -n

# Increase for this shell session
ulimit -n 65536

# Or set it permanently in /etc/security/limits.conf (Linux)
# * soft nofile 65536
# * hard nofile 65536
```

---

## File Descriptor Leaks

A file descriptor leak happens when you open a file but never close it. In a long-running server, this eventually exhausts the fd limit and crashes the process.

### The Classic Leak

```javascript
'use strict';

const fs = require('node:fs');

// BAD: fd is leaked if the write throws
function writeDataLeaky(path, data) {
  const fd = fs.openSync(path, 'w');
  fs.writeSync(fd, data); // If this throws, closeSync never runs
  fs.closeSync(fd);
}

// GOOD: try/finally ensures close
function writeDataSafe(path, data) {
  const fd = fs.openSync(path, 'w');
  try {
    fs.writeSync(fd, data);
  } finally {
    fs.closeSync(fd);
  }
}
```

### The Async Leak

```javascript
'use strict';

const fs = require('node:fs');

// BAD: if the write callback has an error, close never happens
function writeDataAsyncLeaky(path, data, callback) {
  fs.open(path, 'w', (err, fd) => {
    if (err) return callback(err);

    fs.write(fd, data, (writeErr) => {
      if (writeErr) return callback(writeErr); // fd leaked!

      fs.close(fd, (closeErr) => {
        callback(closeErr);
      });
    });
  });
}

// GOOD: close the fd regardless of write outcome
function writeDataAsyncSafe(path, data, callback) {
  fs.open(path, 'w', (err, fd) => {
    if (err) return callback(err);

    fs.write(fd, data, (writeErr) => {
      fs.close(fd, (closeErr) => {
        callback(writeErr || closeErr);
      });
    });
  });
}
```

### Detecting Leaks

Node.js warns you about leaked `FileHandle` objects:

```
(node:12345) Warning: Closing file descriptor 7 on garbage collection
```

If you see this warning in production, you have a `FileHandle` that was not explicitly closed. Track it down and add proper cleanup.

---

## Low-Level Read and Write with File Descriptors

When you need precise control — reading specific byte ranges or writing at specific positions — you use the low-level `fs.read()` and `fs.write()` with fd, buffer, offset, length, and position arguments.

```javascript
'use strict';

const fs = require('node:fs');

const fd = fs.openSync('/tmp/low-level.txt', 'w+');

try {
  // Write at specific position
  const data = Buffer.from('ABCDEFGHIJ');
  fs.writeSync(fd, data, 0, data.length, 0); // write all 10 bytes at position 0

  // Read 3 bytes starting at position 4
  const readBuf = Buffer.alloc(3);
  const bytesRead = fs.readSync(fd, readBuf, 0, 3, 4);

  console.log('Bytes read:', bytesRead);       // 3
  console.log('Data:', readBuf.toString());     // EFG
} finally {
  fs.closeSync(fd);
}
```

The `position` parameter tells the kernel where in the file to read or write, independent of the file's current cursor position. This enables random access — jumping to any byte in the file without reading everything before it.

---

## Putting It All Together: A Simple File Database

Here is a practical example that uses file descriptors for random-access record storage.

```javascript
'use strict';

const fs = require('node:fs/promises');

class SimpleDB {
  #handle;
  #recordSize;

  constructor(recordSize = 64) {
    this.#recordSize = recordSize;
  }

  async open(filePath) {
    this.#handle = await fs.open(filePath, 'a+'); // create if needed, allow read+write
  }

  async writeRecord(index, data) {
    const buf = Buffer.alloc(this.#recordSize);
    buf.write(data, 'utf8');
    const position = index * this.#recordSize;
    await this.#handle.write(buf, 0, buf.length, position);
  }

  async readRecord(index) {
    const buf = Buffer.alloc(this.#recordSize);
    const position = index * this.#recordSize;
    const { bytesRead } = await this.#handle.read(buf, 0, this.#recordSize, position);
    if (bytesRead === 0) return null;
    // Trim trailing null bytes
    const end = buf.indexOf(0x00);
    return buf.toString('utf8', 0, end === -1 ? bytesRead : end);
  }

  async close() {
    if (this.#handle) {
      await this.#handle.close();
      this.#handle = null;
    }
  }
}

// Usage:
// const db = new SimpleDB(64);
// await db.open('/tmp/records.db');
// await db.writeRecord(0, 'Alice');
// await db.writeRecord(1, 'Bob');
// console.log(await db.readRecord(0)); // Alice
// console.log(await db.readRecord(1)); // Bob
// await db.close();
```

---

## Key Takeaways

- A file descriptor is an integer assigned by the OS kernel to track every open file, socket, and pipe in your process — it is the fundamental unit of I/O
- File descriptors 0, 1, and 2 are always stdin, stdout, and stderr; every additional `open()` call gets the next available integer
- Always close file descriptors when done — use `try/finally` for sync code or `try/finally` with `await handle.close()` for async code; leaked fds cause `EMFILE` crashes in production
- The `fs.promises` API's `FileHandle` wraps the raw fd in an object with async methods and GC-triggered warnings, making it safer than raw integer fds
- Use low-level `read(fd, buf, offset, length, position)` and `write(fd, buf, offset, length, position)` when you need random access to specific byte positions within a file

---

## Next

In [Lesson 02 — Reading Files](lesson-02-reading-files.md) you will learn the high-level file reading APIs — `readFile`, `readFileSync`, and `fs.promises.readFile` — and understand when to use them versus the low-level fd-based reads you just learned.
