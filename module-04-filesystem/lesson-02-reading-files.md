# Module 04 / Lesson 02 — Reading Files

> Reading files is the most common file system operation in any Node.js application — configuration files, templates, static assets, log analysis. Node.js gives you three different API styles (callback, synchronous, Promise-based), a low-level fd-based read for surgical precision, and an encoding parameter that determines whether you get a Buffer or a string. Choosing the right combination for each situation is what keeps your event loop responsive and your memory usage predictable.

## Learning Objectives

- Read files using `readFile`, `readFileSync`, and `fs.promises.readFile`
- Understand the encoding parameter and when to omit it (Buffers) versus when to specify it (strings)
- Use low-level `fs.read()` with file descriptors for partial reads at specific positions
- Handle file-reading errors properly, especially `ENOENT`, `EACCES`, and `EISDIR`
- Choose the right API style (callback, sync, Promise) based on the application context

---

## `readFileSync` — Synchronous, Blocking

`readFileSync` reads the entire file into memory and blocks the event loop until the OS delivers every byte. Simple, predictable, and dangerous in a server.

```javascript
'use strict';

const fs = require('node:fs');

// Without encoding — returns a Buffer
const buf = fs.readFileSync('/etc/hostname');
console.log(typeof buf);     // object
console.log(Buffer.isBuffer(buf)); // true
console.log(buf);            // <Buffer 6d 79 2d 68 6f 73 74 0a>
console.log(buf.toString()); // my-host

// With encoding — returns a string
const str = fs.readFileSync('/etc/hostname', 'utf8');
console.log(typeof str); // string
console.log(str);         // my-host
```

### When Synchronous Is Acceptable

- **Application startup**: Loading config files before the server starts listening.
- **CLI tools**: Single-run scripts where blocking does not matter.
- **require() of JSON files**: `require('./config.json')` uses `readFileSync` internally.

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

// Acceptable: load config at startup, before the server starts
const configPath = path.join(__dirname, 'config.json');
let config;

try {
  const raw = fs.readFileSync(configPath, 'utf8');
  config = JSON.parse(raw);
} catch (err) {
  if (err.code === 'ENOENT') {
    console.error('Config file not found, using defaults');
    config = { port: 3000, host: '127.0.0.1' };
  } else if (err instanceof SyntaxError) {
    console.error('Config file contains invalid JSON');
    process.exit(1);
  } else {
    throw err;
  }
}

console.log('Config loaded:', config);
```

---

## `readFile` — Callback API

The callback API reads the file asynchronously. The event loop continues processing other work while the OS reads the file.

```javascript
'use strict';

const fs = require('node:fs');

// Without encoding — Buffer
fs.readFile('/tmp/data.txt', (err, data) => {
  if (err) {
    console.error('Read error:', err.message);
    return;
  }
  console.log('Read', data.length, 'bytes');
  console.log(data); // Buffer
});

// With encoding — string
fs.readFile('/tmp/data.txt', 'utf8', (err, data) => {
  if (err) {
    console.error('Read error:', err.message);
    return;
  }
  console.log(typeof data); // string
  console.log(data);
});

// With options object
fs.readFile('/tmp/data.txt', { encoding: 'utf8', flag: 'r' }, (err, data) => {
  if (err) {
    console.error('Read error:', err.message);
    return;
  }
  console.log(data);
});
```

### The Options Object

`readFile` accepts either a string (encoding) or an options object:

```javascript
{
  encoding: 'utf8',   // null for Buffer, 'utf8'/'ascii'/'hex'/etc. for string
  flag: 'r',          // File open flag (default: 'r')
  signal: abortController.signal  // AbortSignal for cancellation
}
```

---

## `fs.promises.readFile` — The Modern Approach

The Promises API is the cleanest for modern async code. It works with `async/await` naturally.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function loadFile(filePath) {
  try {
    const content = await fs.readFile(filePath, 'utf8');
    console.log('Content length:', content.length);
    return content;
  } catch (err) {
    if (err.code === 'ENOENT') {
      console.log('File does not exist:', filePath);
      return null;
    }
    throw err; // Re-throw unexpected errors
  }
}

loadFile('/tmp/example.txt').then(console.log);
```

### Cancellation with AbortSignal

```javascript
'use strict';

const fs = require('node:fs/promises');

async function readWithTimeout(filePath, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const data = await fs.readFile(filePath, {
      encoding: 'utf8',
      signal: controller.signal,
    });
    return data;
  } catch (err) {
    if (err.name === 'AbortError') {
      console.log('Read timed out after', timeoutMs, 'ms');
      return null;
    }
    throw err;
  } finally {
    clearTimeout(timer);
  }
}

readWithTimeout('/tmp/large-file.txt', 5000).catch(console.error);
```

---

## The Encoding Parameter — Buffer vs String

This is one of the most important decisions when reading files: do you want a Buffer or a string?

```javascript
'use strict';

const fs = require('node:fs');

// No encoding → Buffer (binary-safe, no decoding cost)
const buf = fs.readFileSync('/tmp/image.png');
console.log(Buffer.isBuffer(buf)); // true
console.log(buf.length);           // byte count

// With encoding → String (decoded from bytes to characters)
const str = fs.readFileSync('/tmp/data.txt', 'utf8');
console.log(typeof str);  // string
console.log(str.length);  // character count (may differ from byte count for UTF-8)
```

### When to Use Each

| Use Buffer (no encoding) | Use String (with encoding) |
|--------------------------|---------------------------|
| Binary files (images, audio, archives) | Text files (config, logs, HTML) |
| Cryptographic operations | JSON parsing |
| Passing data to streams | String manipulation / regex |
| When you will parse the bytes yourself | When you need `.split()`, `.trim()`, etc. |
| When performance matters (skip decoding) | When readability matters |

### UTF-8 Byte Count vs Character Count

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

// Write a file with multi-byte characters
const text = 'Hello, world! cafe\u0301'; // é as base + combining accent
fs.writeFileSync('/tmp/unicode-test.txt', text, 'utf8');

// Read as Buffer
const buf = fs.readFileSync('/tmp/unicode-test.txt');
console.log('Byte length:', buf.length);

// Read as string
const str = fs.readFileSync('/tmp/unicode-test.txt', 'utf8');
console.log('String length:', str.length);

// They may differ because multi-byte characters take more than 1 byte
```

---

## Low-Level Reading with `fs.read()`

When `readFile` is too coarse — you only need 100 bytes from a 10GB file — use the low-level `fs.read()` with a file descriptor.

```javascript
fs.read(fd, buffer, offset, length, position, callback)
```

- **fd**: File descriptor from `fs.open()`
- **buffer**: The Buffer to read data into
- **offset**: Where in the buffer to start writing (not the file position)
- **length**: How many bytes to read
- **position**: Where in the file to start reading (`null` for current position)
- **callback**: `(err, bytesRead, buffer)`

```javascript
'use strict';

const fs = require('node:fs');

// Read only the first 100 bytes of a large file
const fd = fs.openSync('/tmp/large-file.dat', 'r');
const buf = Buffer.alloc(100);

try {
  const bytesRead = fs.readSync(fd, buf, 0, 100, 0);
  console.log(`Read ${bytesRead} bytes`);
  console.log(buf.subarray(0, bytesRead));
} finally {
  fs.closeSync(fd);
}
```

### Reading at Specific Positions (Random Access)

```javascript
'use strict';

const fs = require('node:fs');

// Read bytes 1000-1099 from a file (skipping the first 1000 bytes)
const fd = fs.openSync('/tmp/large-file.dat', 'r');
const buf = Buffer.alloc(100);

try {
  const bytesRead = fs.readSync(fd, buf, 0, 100, 1000);
  console.log(`Read ${bytesRead} bytes starting at position 1000`);
} finally {
  fs.closeSync(fd);
}
```

### Promise-Based Low-Level Read with FileHandle

```javascript
'use strict';

const fs = require('node:fs/promises');

async function readRange(filePath, start, length) {
  const handle = await fs.open(filePath, 'r');

  try {
    const buf = Buffer.alloc(length);
    const { bytesRead } = await handle.read(buf, 0, length, start);
    return buf.subarray(0, bytesRead);
  } finally {
    await handle.close();
  }
}

// Read bytes 500-599
readRange('/tmp/data.bin', 500, 100)
  .then(data => console.log('Read', data.length, 'bytes'))
  .catch(console.error);
```

---

## Reading Multiple Files

### Sequential (When Order Matters or Resources Are Limited)

```javascript
'use strict';

const fs = require('node:fs/promises');

async function readSequentially(paths) {
  const results = [];
  for (const p of paths) {
    const content = await fs.readFile(p, 'utf8');
    results.push({ path: p, content });
  }
  return results;
}
```

### Parallel (When Speed Matters)

```javascript
'use strict';

const fs = require('node:fs/promises');

async function readInParallel(paths) {
  const promises = paths.map(async (p) => {
    const content = await fs.readFile(p, 'utf8');
    return { path: p, content };
  });

  return Promise.all(promises);
}
```

### Controlled Concurrency (Production Pattern)

Reading 10,000 files in parallel will exhaust file descriptors. Limit concurrency.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function readWithConcurrency(paths, limit = 10) {
  const results = new Array(paths.length);
  let index = 0;

  async function worker() {
    while (index < paths.length) {
      const i = index++;
      try {
        results[i] = await fs.readFile(paths[i], 'utf8');
      } catch (err) {
        results[i] = { error: err.code };
      }
    }
  }

  // Spawn 'limit' workers that pull from the shared index
  const workers = Array.from({ length: Math.min(limit, paths.length) }, () => worker());
  await Promise.all(workers);

  return results;
}

// Read 1000 files, max 10 at a time
// const files = Array.from({ length: 1000 }, (_, i) => `/tmp/file-${i}.txt`);
// const contents = await readWithConcurrency(files, 10);
```

---

## Error Handling

File reading produces predictable errors. Handle them explicitly.

| Error Code | Meaning | Common Cause |
|------------|---------|--------------|
| `ENOENT` | No such file or directory | Typo in path, file deleted, wrong cwd |
| `EACCES` | Permission denied | File owned by root, wrong chmod |
| `EISDIR` | Is a directory | Path points to a directory, not a file |
| `EMFILE` | Too many open files | File descriptor leak |
| `ENOMEM` | Not enough memory | Reading a huge file into memory |

```javascript
'use strict';

const fs = require('node:fs/promises');

async function safeRead(filePath) {
  try {
    return await fs.readFile(filePath, 'utf8');
  } catch (err) {
    switch (err.code) {
      case 'ENOENT':
        console.error(`File not found: ${filePath}`);
        return null;

      case 'EACCES':
        console.error(`Permission denied: ${filePath}`);
        return null;

      case 'EISDIR':
        console.error(`Path is a directory, not a file: ${filePath}`);
        return null;

      default:
        // Unexpected error — let it propagate
        throw err;
    }
  }
}
```

---

## `readFile` vs `read` vs Streams: When to Use What

| Approach | Use When |
|----------|----------|
| `readFile` / `readFileSync` | File fits comfortably in memory (< 50MB typically) |
| `fs.read()` with fd | You need specific byte ranges from a large file |
| `createReadStream` (Module 05) | File is too large for memory, or you want to process it incrementally |

```javascript
'use strict';

const fs = require('node:fs');

// Check file size before deciding how to read it
const stats = fs.statSync('/tmp/data.dat');
const ONE_MB = 1024 * 1024;

if (stats.size < 50 * ONE_MB) {
  // Small enough for readFile
  const data = fs.readFileSync('/tmp/data.dat');
  console.log('Read entire file:', data.length, 'bytes');
} else {
  // Too large — use streams (covered in Module 05)
  console.log('File is', (stats.size / ONE_MB).toFixed(1), 'MB — use a stream');
}
```

---

## Practical Example: JSON Config Loader with Validation

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

async function loadConfig(configPath, defaults = {}) {
  const absolutePath = path.resolve(configPath);

  let raw;
  try {
    raw = await fs.readFile(absolutePath, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') {
      console.log(`Config not found at ${absolutePath}, using defaults`);
      return { ...defaults };
    }
    throw new Error(`Failed to read config: ${err.message}`);
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new Error(`Invalid JSON in ${absolutePath}: ${err.message}`);
  }

  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error(`Config must be a JSON object, got ${typeof parsed}`);
  }

  return { ...defaults, ...parsed };
}

// Usage:
// const config = await loadConfig('./config.json', { port: 3000, debug: false });
```

---

## Key Takeaways

- `readFileSync` blocks the event loop and is only appropriate during startup or in CLI tools; use `fs.promises.readFile` for server-side code
- Omitting the encoding parameter returns a Buffer (binary-safe); specifying `'utf8'` returns a decoded string — choose based on whether the file is binary or text
- Low-level `fs.read(fd, buf, offset, length, position)` gives you surgical precision for reading specific byte ranges without loading the entire file
- Always handle `ENOENT` (file not found) and `EACCES` (permission denied) explicitly; let unexpected errors propagate
- When reading many files in parallel, limit concurrency to avoid exhausting file descriptors (`EMFILE`)

---

## Next

In [Lesson 03 — Writing Files](lesson-03-writing-files.md) you will learn how to write files safely — including the critical atomic write pattern (write to temp, then rename) that prevents your users from ever seeing a half-written file.
