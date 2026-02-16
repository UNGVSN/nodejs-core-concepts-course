# Module 08 / Lesson 02 — The process Module

> The `process` object is Node.js's bridge to the operating system. It is a global — available everywhere without `require` — and it exposes everything from command-line arguments to memory consumption to high-resolution timing. Mastering it is the foundation for building CLI tools, monitoring systems, and production-grade servers.

---

## Learning Objectives

- Parse command-line arguments with `process.argv` and build a simple CLI interface
- Read and write environment variables through `process.env` with proper type handling
- Measure memory consumption using `process.memoryUsage()` and understand the difference between RSS, heap, and external memory
- Use `process.hrtime.bigint()` for microsecond-accurate performance profiling
- Control process termination with `process.exit()` and `process.exitCode`

---

## process.argv — Command-Line Arguments

`process.argv` is an array of strings. The first two elements are always the same:

| Index | Value |
|-------|-------|
| 0     | Path to the `node` executable |
| 1     | Path to the script being executed |
| 2+    | User-supplied arguments |

```javascript
'use strict';

// Run: node lesson-02-demo.js --port 3000 --verbose
console.log('Raw argv:', process.argv);
// [
//   '/usr/local/bin/node',
//   '/home/user/lesson-02-demo.js',
//   '--port',
//   '3000',
//   '--verbose'
// ]

// Slice off node and script path to get user arguments
const userArgs = process.argv.slice(2);
console.log('User args:', userArgs);
// ['--port', '3000', '--verbose']
```

### Building a Minimal Argument Parser

You do not need a third-party package to parse arguments. A simple loop handles most CLI tools:

```javascript
'use strict';

// Run: node cli.js --port 8080 --host 0.0.0.0 --verbose

function parseArgs(args) {
  const parsed = {};

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    if (arg.startsWith('--')) {
      const key = arg.slice(2);
      const next = args[i + 1];

      // If next arg exists and is not a flag, treat it as the value
      if (next && !next.startsWith('--')) {
        parsed[key] = next;
        i += 1; // Skip the value in the next iteration
      } else {
        parsed[key] = true; // Boolean flag
      }
    }
  }

  return parsed;
}

const options = parseArgs(process.argv.slice(2));
console.log('Parsed options:', options);
// { port: '8080', host: '0.0.0.0', verbose: true }

// Remember: all values from argv are strings
const port = parseInt(options.port, 10) || 3000;
console.log('Port (as number):', port);
```

### Node.js Built-In Argument Parser (v18.3+)

Starting with Node.js 18.3, the `node:util` module provides `parseArgs`:

```javascript
'use strict';

const { parseArgs } = require('node:util');

// Run: node cli.js --port 8080 --verbose --name myapp
try {
  const { values, positionals } = parseArgs({
    options: {
      port: { type: 'string', short: 'p', default: '3000' },
      verbose: { type: 'boolean', short: 'v', default: false },
      name: { type: 'string', short: 'n' }
    },
    allowPositionals: true
  });

  console.log('values:', values);
  console.log('positionals:', positionals);
} catch (err) {
  console.error('Invalid arguments:', err.message);
  process.exit(1);
}
```

---

## process.env — Environment Variables

`process.env` is an object containing the user environment. Every value is a string, even if the original value looks like a number or boolean.

```javascript
'use strict';

// Reading standard variables
console.log('NODE_ENV:', process.env.NODE_ENV);  // undefined if not set
console.log('PATH:', process.env.PATH);
console.log('HOME:', process.env.HOME);

// Common pattern: default values
const port = parseInt(process.env.PORT, 10) || 3000;
const host = process.env.HOST || '127.0.0.1';
const isProduction = process.env.NODE_ENV === 'production';

console.log(`Server config: ${host}:${port} (production: ${isProduction})`);
```

### The String Coercion Trap

Every value in `process.env` is a string. This is a common source of bugs:

```javascript
'use strict';

// Set a "numeric" environment variable
process.env.MAX_RETRIES = 5;
console.log(typeof process.env.MAX_RETRIES); // 'string'
console.log(process.env.MAX_RETRIES === 5);  // false
console.log(process.env.MAX_RETRIES === '5'); // true

// Set a "boolean" environment variable
process.env.DEBUG = 'false';
console.log(Boolean(process.env.DEBUG)); // true! Non-empty string is truthy

// The correct way to check boolean env vars
const debug = process.env.DEBUG === 'true' || process.env.DEBUG === '1';
console.log('Debug enabled:', debug); // false
```

### Enumerating the Environment

```javascript
'use strict';

// List all environment variables
const envEntries = Object.entries(process.env);
console.log(`Total environment variables: ${envEntries.length}`);

// Find all Node-related variables
const nodeVars = envEntries.filter(([key]) => key.startsWith('NODE'));
for (const [key, value] of nodeVars) {
  console.log(`  ${key} = ${value}`);
}
```

---

## process.cwd() and process.chdir()

`process.cwd()` returns the current working directory — the directory from which the Node.js process was launched, not the directory where the script file lives.

```javascript
'use strict';

const path = require('node:path');

// Where was the process launched from?
console.log('Working directory:', process.cwd());

// Where does this script file live?
console.log('Script directory:', __dirname);

// These can be different:
// If you run: cd /tmp && node /home/user/app.js
//   cwd() → /tmp
//   __dirname → /home/user

// You can change the working directory
try {
  process.chdir('/tmp');
  console.log('Changed to:', process.cwd()); // /tmp
} catch (err) {
  console.error('chdir failed:', err.message);
}
```

A critical point: relative file paths in `fs` operations resolve against `process.cwd()`, not `__dirname`. This is a frequent source of "file not found" errors when scripts are run from unexpected directories.

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

// FRAGILE: depends on where you run the command from
// fs.readFileSync('config.json');

// ROBUST: always resolve relative to the script's location
const configPath = path.join(__dirname, 'config.json');
// fs.readFileSync(configPath);

console.log('Resolved config path:', configPath);
```

---

## process.memoryUsage() — Measuring Memory

`process.memoryUsage()` returns an object with four fields, all measured in bytes:

| Field | Meaning |
|-------|---------|
| `rss` | **Resident Set Size** — total memory allocated by the OS for this process (code, stack, heap) |
| `heapTotal` | Total size of the V8 heap (allocated from the OS) |
| `heapUsed` | Amount of the V8 heap currently in use by JavaScript objects |
| `external` | Memory used by C++ objects bound to JavaScript (e.g., Buffers allocated outside V8) |
| `arrayBuffers` | Memory allocated for `ArrayBuffer` and `SharedArrayBuffer` (subset of `external`) |

```javascript
'use strict';

function formatBytes(bytes) {
  const mb = bytes / 1024 / 1024;
  return `${mb.toFixed(2)} MB`;
}

function logMemory(label) {
  const mem = process.memoryUsage();
  console.log(`\n--- ${label} ---`);
  console.log(`  RSS:          ${formatBytes(mem.rss)}`);
  console.log(`  Heap Total:   ${formatBytes(mem.heapTotal)}`);
  console.log(`  Heap Used:    ${formatBytes(mem.heapUsed)}`);
  console.log(`  External:     ${formatBytes(mem.external)}`);
  console.log(`  ArrayBuffers: ${formatBytes(mem.arrayBuffers)}`);
}

// Baseline
logMemory('Startup');

// Allocate JavaScript objects (goes to heapUsed)
const objects = [];
for (let i = 0; i < 100_000; i++) {
  objects.push({ index: i, data: `item-${i}` });
}
logMemory('After 100k objects');

// Allocate Buffers (goes to external)
const buffers = [];
for (let i = 0; i < 1000; i++) {
  buffers.push(Buffer.alloc(1024 * 10)); // 10 KB each = ~10 MB total
}
logMemory('After 10 MB of Buffers');
```

### RSS vs Heap

RSS is always larger than heapTotal because it includes:
- The V8 heap (where your JavaScript objects live)
- The Node.js binary code itself
- C++ memory (libuv, OpenSSL, zlib, etc.)
- Stack memory for the main thread and thread pool

In production, RSS is the number your container memory limit cares about. A container with a 512 MB limit will be killed by the OOM killer when RSS crosses that threshold, regardless of what heapUsed says.

---

## process.uptime() — How Long Has This Process Been Running?

`process.uptime()` returns the number of seconds the current Node.js process has been running, as a floating-point number.

```javascript
'use strict';

console.log(`Uptime at start: ${process.uptime().toFixed(3)} seconds`);

// Simulate some work
const start = Date.now();
while (Date.now() - start < 200) {
  // busy wait 200ms
}

console.log(`Uptime after work: ${process.uptime().toFixed(3)} seconds`);

// Useful for health checks and status endpoints
function getStatus() {
  const uptimeSeconds = process.uptime();
  const hours = Math.floor(uptimeSeconds / 3600);
  const minutes = Math.floor((uptimeSeconds % 3600) / 60);
  const seconds = Math.floor(uptimeSeconds % 60);

  return {
    uptime: `${hours}h ${minutes}m ${seconds}s`,
    uptimeRaw: uptimeSeconds,
    pid: process.pid,
    memory: process.memoryUsage()
  };
}

console.log('Status:', getStatus());
```

---

## process.hrtime.bigint() — High-Resolution Timing

`Date.now()` gives you millisecond precision, which is too coarse for benchmarking. `process.hrtime.bigint()` returns the current high-resolution time in nanoseconds as a BigInt.

```javascript
'use strict';

// Measure the duration of an operation in nanoseconds
const start = process.hrtime.bigint();

// Do some work
let sum = 0;
for (let i = 0; i < 1_000_000; i++) {
  sum += i;
}

const end = process.hrtime.bigint();
const durationNs = end - start;
const durationMs = Number(durationNs) / 1_000_000;

console.log(`Sum: ${sum}`);
console.log(`Duration: ${durationNs} nanoseconds`);
console.log(`Duration: ${durationMs.toFixed(3)} milliseconds`);
```

### Building a Simple Profiler

```javascript
'use strict';

class Profiler {
  #timers = new Map();

  start(label) {
    this.#timers.set(label, process.hrtime.bigint());
  }

  end(label) {
    const startTime = this.#timers.get(label);
    if (!startTime) {
      throw new Error(`No timer found for label: ${label}`);
    }

    const duration = process.hrtime.bigint() - startTime;
    this.#timers.delete(label);

    return {
      label,
      nanoseconds: duration,
      microseconds: Number(duration) / 1_000,
      milliseconds: Number(duration) / 1_000_000
    };
  }

  measure(label, fn) {
    this.start(label);
    const result = fn();
    const timing = this.end(label);
    return { result, timing };
  }
}

const profiler = new Profiler();

// Profile array creation
const { timing: t1 } = profiler.measure('array-fill', () => {
  return Array.from({ length: 100_000 }, (_, i) => i * 2);
});
console.log(`array-fill: ${t1.milliseconds.toFixed(3)} ms`);

// Profile string concatenation
const { timing: t2 } = profiler.measure('string-concat', () => {
  let s = '';
  for (let i = 0; i < 10_000; i++) {
    s += 'x';
  }
  return s;
});
console.log(`string-concat: ${t2.milliseconds.toFixed(3)} ms`);

// Profile array join (faster alternative)
const { timing: t3 } = profiler.measure('array-join', () => {
  const parts = [];
  for (let i = 0; i < 10_000; i++) {
    parts.push('x');
  }
  return parts.join('');
});
console.log(`array-join: ${t3.milliseconds.toFixed(3)} ms`);
```

---

## process.exit() vs process.exitCode

There are two ways to end a Node.js process explicitly:

### process.exit(code)

Forces immediate termination. The event loop is abandoned. Any pending I/O — unfinished writes, open connections, queued callbacks — is discarded. Use this only when you need to bail out fast.

```javascript
'use strict';

// Validate required configuration at startup
const required = ['DATABASE_URL', 'SECRET_KEY'];
const missing = required.filter((key) => !process.env[key]);

if (missing.length > 0) {
  console.error(`Missing required env vars: ${missing.join(', ')}`);
  process.exit(1); // Immediate termination
}

// This code never runs if env vars are missing
console.log('Configuration validated, starting server...');
```

### process.exitCode

Sets the exit code without forcing termination. The process continues running and exits naturally when the event loop drains.

```javascript
'use strict';

// Preferred: set exitCode and let the process drain naturally
async function main() {
  try {
    // Simulate some async work
    await performTask();
    process.exitCode = 0;
  } catch (err) {
    console.error('Task failed:', err.message);
    process.exitCode = 1;
  }
  // Process will exit with the set code once the event loop drains
}

async function performTask() {
  // Simulate work
  return new Promise((resolve) => setTimeout(resolve, 100));
}

main();
```

### The 'exit' Event

The `'exit'` event fires when the process is about to terminate. Only synchronous operations work here — any async operations queued in this handler will be abandoned.

```javascript
'use strict';

process.on('exit', (code) => {
  console.log(`Process exiting with code: ${code}`);
  // You can do synchronous cleanup here
  // BUT: setTimeout, setInterval, Promises will NOT execute
});

process.on('beforeExit', (code) => {
  // Fires when the event loop empties but before 'exit'
  // You CAN schedule async work here (which will delay exit)
  // Does NOT fire when process.exit() is called explicitly
  console.log(`Event loop empty, about to exit with code: ${code}`);
});

console.log('Main script complete');
// Output order:
// Main script complete
// Event loop empty, about to exit with code: 0
// Process exiting with code: 0
```

---

## process.title — Naming Your Process

You can set `process.title` to change how your process appears in tools like `ps` and `top`:

```javascript
'use strict';

process.title = 'my-api-server';
console.log('Process title:', process.title);

// Now `ps aux | grep my-api-server` will find this process
// Useful when running multiple Node.js processes on the same machine
```

---

## process.versions and process.config

```javascript
'use strict';

// All the version strings for Node.js and its dependencies
console.log('Node.js versions:');
for (const [component, version] of Object.entries(process.versions)) {
  console.log(`  ${component}: ${version}`);
}
// node, v8, uv, zlib, brotli, ares, modules, nghttp2, openssl, icu, unicode, etc.

// The arch and platform
console.log('\nPlatform:', process.platform); // 'darwin', 'linux', 'win32'
console.log('Architecture:', process.arch);   // 'x64', 'arm64', etc.
```

---

## Practical Example: A Self-Reporting Health Check

Combine everything from this lesson into a health-check function suitable for a production server:

```javascript
'use strict';

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function healthCheck() {
  const mem = process.memoryUsage();
  const uptimeSec = process.uptime();

  return {
    status: 'healthy',
    pid: process.pid,
    ppid: process.ppid,
    title: process.title,
    nodeVersion: process.version,
    platform: `${process.platform}/${process.arch}`,
    uptime: {
      seconds: Math.floor(uptimeSec),
      human: `${Math.floor(uptimeSec / 3600)}h ${Math.floor((uptimeSec % 3600) / 60)}m ${Math.floor(uptimeSec % 60)}s`
    },
    memory: {
      rss: formatBytes(mem.rss),
      heapTotal: formatBytes(mem.heapTotal),
      heapUsed: formatBytes(mem.heapUsed),
      external: formatBytes(mem.external),
      heapUtilization: `${((mem.heapUsed / mem.heapTotal) * 100).toFixed(1)}%`
    },
    cwd: process.cwd(),
    env: process.env.NODE_ENV || 'development'
  };
}

console.log(JSON.stringify(healthCheck(), null, 2));
```

---

## Key Takeaways

- `process.argv` gives you raw command-line arguments as an array of strings; slice from index 2 to get user-supplied values, or use `util.parseArgs()` for structured parsing.
- `process.env` values are always strings — compare booleans against `'true'`/`'1'` and parse numbers with `parseInt()` to avoid subtle bugs.
- `process.memoryUsage()` returns RSS (total OS allocation), heapTotal/heapUsed (V8 JavaScript heap), and external (C++ objects like Buffers) — RSS is what your container memory limit enforces.
- `process.hrtime.bigint()` provides nanosecond-resolution timing for benchmarks where `Date.now()` is too coarse.
- Prefer `process.exitCode = N` over `process.exit(N)` to allow pending I/O to flush — use `process.exit()` only for fatal startup failures.

---

## Next

In the next lesson you will learn how to spawn external commands using `exec` and `execFile` — buffered child processes that capture stdout and stderr into strings, along with the security implications of running shell commands from Node.js.
