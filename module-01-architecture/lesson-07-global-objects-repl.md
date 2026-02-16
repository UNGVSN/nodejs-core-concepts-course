# Module 01 / Lesson 07 — Global Objects & the REPL

> Every programming environment gives you a set of built-in objects that are always available — no imports needed. In Node.js, these globals are different from what browsers provide. Understanding `process`, `global`, `Buffer`, timers, and the REPL is the foundation for writing effective server-side JavaScript. If you have ever wondered why `setTimeout` works without an import, or how `process.env` gets populated, this lesson answers those questions.

## Learning Objectives

- Explain the difference between `global`, `globalThis`, and `window`, and why Node.js does not have a `window` object
- Use the `process` object to inspect the runtime environment, parse command-line arguments, measure memory, and control the exit code
- Apply `console` methods beyond `.log()` — including `.table()`, `.time()`, `.trace()`, and `.count()` — for structured debugging
- Distinguish between `setTimeout`, `setInterval`, `setImmediate`, and `queueMicrotask` and predict their execution order
- Start and customize the Node.js REPL for rapid prototyping and debugging

---

## The global Object

In browsers, the top-level object is `window`. In Node.js, it is `global`. They serve the same purpose — a namespace for things that should be available everywhere — but they are not interchangeable.

```javascript
'use strict';

// In Node.js, there is no 'window'
console.log(typeof window);  // 'undefined'
console.log(typeof global);  // 'object'

// You can attach properties to global (but you should not)
global.myAppName = 'demo';
console.log(myAppName);      // 'demo' — accessible without global. prefix

// Clean up — avoid polluting global scope
delete global.myAppName;
```

### globalThis: The Universal Top-Level Object

ES2020 introduced `globalThis` as a cross-environment way to access the global object. It works in browsers, Node.js, Deno, Bun, and Web Workers.

```javascript
'use strict';

// globalThis is the same object as global in Node.js
console.log(globalThis === global); // true

// In a browser, globalThis === window
// In a Web Worker, globalThis === self
// In Node.js, globalThis === global

// Prefer globalThis when writing code that runs in multiple environments
globalThis.universalFlag = true;
console.log(global.universalFlag); // true

delete globalThis.universalFlag;
```

**Rule:** Never attach application state to `global` or `globalThis`. Use module exports instead. Global pollution leads to untraceable bugs in large codebases.

---

## The process Object

`process` is arguably the most important global in Node.js. It is an instance of `EventEmitter` and provides information about — and control over — the current Node.js process.

### process.env — Environment Variables

```javascript
'use strict';

// Read environment variables
console.log('NODE_ENV:', process.env.NODE_ENV);   // e.g., 'production'
console.log('HOME:',     process.env.HOME);       // e.g., '/home/user'
console.log('PATH:',     process.env.PATH);       // System PATH

// Environment variables are always strings
process.env.PORT = 3000;
console.log(typeof process.env.PORT); // 'string' — not 'number'!
console.log(process.env.PORT);        // '3000'

// Parse numeric env vars explicitly
const port = parseInt(process.env.PORT, 10) || 8080;
console.log('Parsed port:', port, typeof port); // 3000 'number'

// Check if a variable is set
if (process.env.DEBUG) {
  console.log('Debug mode is enabled');
}
```

### process.argv — Command-Line Arguments

```javascript
'use strict';

// Run: node script.js --name Alice --verbose
console.log('Raw argv:');
console.log(process.argv);
// [
//   '/usr/local/bin/node',     // argv[0] — path to Node.js binary
//   '/home/user/script.js',    // argv[1] — path to script
//   '--name',                  // argv[2] — first user argument
//   'Alice',                   // argv[3]
//   '--verbose'                // argv[4]
// ]

// Skip the first two elements to get user arguments
const args = process.argv.slice(2);
console.log('User args:', args); // ['--name', 'Alice', '--verbose']

// Simple argument parser (no npm packages needed)
function parseArgs(argv) {
  const result = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      const key = argv[i].slice(2);
      const next = argv[i + 1];
      if (next && !next.startsWith('--')) {
        result[key] = next;
        i++; // skip the value
      } else {
        result[key] = true; // flag with no value
      }
    }
  }
  return result;
}

const parsed = parseArgs(args);
console.log('Parsed:', parsed);
// { name: 'Alice', verbose: true }
```

### process.cwd(), process.pid, process.uptime()

```javascript
'use strict';

// Current working directory (where the user ran `node`)
console.log('CWD:', process.cwd());

// Process ID (useful for logging and debugging)
console.log('PID:', process.pid);

// Parent process ID
console.log('PPID:', process.ppid);

// How long this process has been running (in seconds)
console.log('Uptime:', process.uptime().toFixed(2), 'seconds');

// Node.js version
console.log('Node version:', process.version);
// 'v22.x.x'

// Detailed version info for V8, libuv, OpenSSL, etc.
console.log('Version details:', process.versions);

// Operating system platform and CPU architecture
console.log('Platform:', process.platform); // 'linux', 'darwin', 'win32'
console.log('Arch:',     process.arch);     // 'x64', 'arm64'
```

### process.memoryUsage()

```javascript
'use strict';

const mem = process.memoryUsage();
console.log('Memory usage:');
console.log('  RSS:          ', (mem.rss / 1024 / 1024).toFixed(2), 'MB');
console.log('  Heap Total:   ', (mem.heapTotal / 1024 / 1024).toFixed(2), 'MB');
console.log('  Heap Used:    ', (mem.heapUsed / 1024 / 1024).toFixed(2), 'MB');
console.log('  External:     ', (mem.external / 1024 / 1024).toFixed(2), 'MB');
console.log('  Array Buffers:', (mem.arrayBuffers / 1024 / 1024).toFixed(2), 'MB');

// RSS    = Resident Set Size (total memory allocated for the process)
// Heap   = V8 heap (where JS objects live)
// External = C++ objects bound to JS objects (Buffers, etc.)
```

### process.hrtime.bigint() — High-Resolution Timing

```javascript
'use strict';

// process.hrtime.bigint() returns nanoseconds as a BigInt
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

// Why not Date.now()? Date.now() has millisecond precision and can drift
// if the system clock is adjusted. hrtime is monotonic and nanosecond-precise.
```

### process.exit() and Exit Codes

```javascript
'use strict';

// Set exit code without immediately exiting
process.exitCode = 0; // 0 = success (default)

// Listen for the 'exit' event (last chance to do synchronous work)
process.on('exit', (code) => {
  console.log(`Process exiting with code: ${code}`);
  // You cannot do async work here — only synchronous cleanup
});

// Force immediate exit (skips pending async work)
// process.exit(1); // 1 = generic error

// Preferred: set exitCode and let Node.js exit naturally
// process.exitCode = 1;

// Common exit codes:
// 0 — success
// 1 — generic error
// 2 — misuse of shell command
// 126 — command not executable
// 127 — command not found
// 128 + N — killed by signal N (e.g., 130 = SIGINT, 137 = SIGKILL)
```

---

## console — Beyond .log()

The `console` object in Node.js writes to `stdout` (for `.log`, `.info`) and `stderr` (for `.error`, `.warn`). It offers much more than `.log()`.

```javascript
'use strict';

// .error() and .warn() write to stderr, not stdout
console.log('This goes to stdout');
console.error('This goes to stderr');
console.warn('This also goes to stderr');

// This matters when piping: node app.js > out.txt 2> err.txt
// stdout → out.txt, stderr → err.txt
```

### console.table()

```javascript
'use strict';

const users = [
  { name: 'Alice',   role: 'admin',  age: 32 },
  { name: 'Bob',     role: 'editor', age: 28 },
  { name: 'Charlie', role: 'viewer', age: 45 },
];

console.table(users);
// ┌─────────┬───────────┬──────────┬─────┐
// │ (index) │   name    │   role   │ age │
// ├─────────┼───────────┼──────────┼─────┤
// │    0    │  'Alice'  │ 'admin'  │ 32  │
// │    1    │   'Bob'   │ 'editor' │ 28  │
// │    2    │ 'Charlie' │ 'viewer' │ 45  │
// └─────────┴───────────┴──────────┴─────┘

// Show only specific columns
console.table(users, ['name', 'role']);
```

### console.time() / console.timeEnd()

```javascript
'use strict';

console.time('array-creation');

const arr = [];
for (let i = 0; i < 1_000_000; i++) {
  arr.push(i * 2);
}

console.timeEnd('array-creation');
// array-creation: 42.567ms

// You can have multiple timers running simultaneously
console.time('sort');
arr.sort((a, b) => b - a);
console.timeEnd('sort');
// sort: 128.234ms

// console.timeLog() checks elapsed time without stopping the timer
console.time('phases');
// ... phase 1 ...
console.timeLog('phases', 'phase 1 done');
// ... phase 2 ...
console.timeEnd('phases');
```

### console.trace(), console.count(), console.dir()

```javascript
'use strict';

// .trace() prints a stack trace from the current position
function innerFunction() {
  console.trace('Where am I?');
}
function outerFunction() {
  innerFunction();
}
outerFunction();
// Trace: Where am I?
//     at innerFunction (script.js:4:11)
//     at outerFunction (script.js:7:3)
//     at Object.<anonymous> (script.js:9:1)

// .count() counts how many times it has been called with a given label
for (let i = 0; i < 5; i++) {
  if (i % 2 === 0) {
    console.count('even');
  } else {
    console.count('odd');
  }
}
// even: 1
// odd: 1
// even: 2
// odd: 2
// even: 3

console.countReset('even'); // reset the counter

// .dir() inspects an object with options (depth, colors)
const nested = { a: { b: { c: { d: 42 } } } };
console.dir(nested, { depth: null, colors: true });
// Shows the full nested structure regardless of depth
```

---

## Buffer as a Global

`Buffer` is available globally in Node.js — no `require` needed. It represents fixed-length sequences of raw binary data.

```javascript
'use strict';

// Buffer is global — no import required
const buf = Buffer.from('Hello, Node.js!', 'utf8');
console.log(buf);
// <Buffer 48 65 6c 6c 6f 2c 20 4e 6f 64 65 2e 6a 73 21>

console.log(buf.length);         // 15 (bytes, not characters)
console.log(buf.toString());     // 'Hello, Node.js!'
console.log(buf.toString('hex')); // '48656c6c6f2c204e6f64652e6a7321'

// Buffer is covered extensively in Module 03.
// For now, know that it is a global and that it deals with raw bytes.

// Allocate a zero-filled buffer
const zeroed = Buffer.alloc(16);
console.log(zeroed); // <Buffer 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00>
```

---

## Timers: setTimeout, setInterval, setImmediate, queueMicrotask

Node.js provides the same timer functions as browsers, but their implementations differ because Node.js uses libuv's event loop instead of the browser's rendering loop.

### setTimeout and setInterval

```javascript
'use strict';

// setTimeout — execute once after a delay
const timeoutId = setTimeout(() => {
  console.log('Fired after ~1000ms');
}, 1000);

// clearTimeout cancels the timer
// clearTimeout(timeoutId);

// setInterval — execute repeatedly
let count = 0;
const intervalId = setInterval(() => {
  count++;
  console.log(`Interval tick: ${count}`);
  if (count >= 3) {
    clearInterval(intervalId);
    console.log('Interval cleared');
  }
}, 500);
```

### setImmediate — Node.js Only

`setImmediate` schedules a callback to run in the next iteration of the event loop, after I/O events but before timers. It does not exist in browsers.

```javascript
'use strict';

// setImmediate vs setTimeout(fn, 0)
setTimeout(() => {
  console.log('setTimeout 0');
}, 0);

setImmediate(() => {
  console.log('setImmediate');
});

// The order of these two is NON-DETERMINISTIC when called from the main module.
// Inside an I/O callback, setImmediate ALWAYS fires before setTimeout(fn, 0).

const { readFile } = require('node:fs');

readFile(__filename, () => {
  setTimeout(() => console.log('timeout inside I/O'), 0);
  setImmediate(() => console.log('immediate inside I/O'));
  // Output is always:
  // immediate inside I/O
  // timeout inside I/O
});
```

### queueMicrotask and process.nextTick

Microtasks run before the event loop continues to the next phase. There are two ways to queue them in Node.js:

```javascript
'use strict';

// process.nextTick — Node.js specific, runs before microtasks
process.nextTick(() => {
  console.log('1: process.nextTick');
});

// queueMicrotask — standard Web API, runs after nextTick
queueMicrotask(() => {
  console.log('2: queueMicrotask');
});

// Promise .then() is also a microtask
Promise.resolve().then(() => {
  console.log('3: Promise.then');
});

setTimeout(() => {
  console.log('4: setTimeout');
}, 0);

setImmediate(() => {
  console.log('5: setImmediate');
});

console.log('0: synchronous');

// Output (guaranteed order for 0-3):
// 0: synchronous
// 1: process.nextTick
// 2: queueMicrotask
// 3: Promise.then
// 4: setTimeout        (4 and 5 may swap in main module)
// 5: setImmediate
```

### Execution Priority Table

| Priority | Mechanism             | When It Runs                          |
|----------|-----------------------|---------------------------------------|
| 1 (highest) | Synchronous code    | Immediately, blocks everything       |
| 2        | `process.nextTick()`  | After current operation, before microtasks |
| 3        | Microtasks (`queueMicrotask`, Promise `.then`) | After nextTick, before event loop continues |
| 4        | Timers (`setTimeout`, `setInterval`) | Timer phase of event loop            |
| 5        | I/O callbacks         | Poll phase of event loop              |
| 6        | `setImmediate()`      | Check phase of event loop             |

---

## __dirname and __filename (CommonJS Only)

These two variables are available in every CommonJS module but not in ESM modules. They are injected by the module wrapper function (see Lesson 06).

```javascript
'use strict';

// __filename — absolute path to the current file
console.log('__filename:', __filename);
// /home/user/project/src/app.js

// __dirname — absolute path to the directory containing the current file
console.log('__dirname:', __dirname);
// /home/user/project/src

// Common use: resolve paths relative to the current file
const path = require('node:path');
const configPath = path.join(__dirname, '..', 'config', 'default.json');
console.log('Config path:', configPath);
// /home/user/project/config/default.json

// In ESM, use import.meta.url instead:
// import { fileURLToPath } from 'node:url';
// import { dirname } from 'node:path';
// const __filename = fileURLToPath(import.meta.url);
// const __dirname = dirname(__filename);
```

---

## URL and URLSearchParams as Globals

Since Node.js 10, `URL` and `URLSearchParams` are available globally (matching the browser WHATWG URL API). No import is needed for basic usage.

```javascript
'use strict';

// URL — parse and construct URLs
const myUrl = new URL('https://example.com:8080/api/users?page=2&limit=10#results');

console.log('Protocol:', myUrl.protocol); // 'https:'
console.log('Hostname:', myUrl.hostname); // 'example.com'
console.log('Port:',     myUrl.port);     // '8080'
console.log('Pathname:', myUrl.pathname); // '/api/users'
console.log('Search:',   myUrl.search);   // '?page=2&limit=10'
console.log('Hash:',     myUrl.hash);     // '#results'
console.log('Origin:',   myUrl.origin);   // 'https://example.com:8080'

// Modify parts of the URL
myUrl.pathname = '/api/posts';
myUrl.searchParams.set('page', '3');
console.log('Modified:', myUrl.href);
// 'https://example.com:8080/api/posts?page=3&limit=10#results'

// Resolve relative URLs
const base = new URL('https://example.com/docs/guide/');
const resolved = new URL('../api/v2', base);
console.log('Resolved:', resolved.href);
// 'https://example.com/docs/api/v2'
```

```javascript
'use strict';

// URLSearchParams — work with query strings
const params = new URLSearchParams('color=red&size=large&color=blue');

console.log('Get color:', params.get('color'));      // 'red' (first match)
console.log('Get all colors:', params.getAll('color')); // ['red', 'blue']
console.log('Has size:', params.has('size'));         // true

params.append('weight', '5kg');
params.delete('size');
params.set('color', 'green'); // replaces ALL 'color' entries

console.log('Final:', params.toString());
// 'color=green&weight=5kg'

// Iterate over all entries
for (const [key, value] of params) {
  console.log(`  ${key} = ${value}`);
}
```

---

## The REPL

The REPL (Read-Eval-Print Loop) is Node.js's interactive shell. Start it by running `node` with no arguments.

### Basic REPL Commands

```
$ node
Welcome to Node.js v22.x.x.
Type ".help" for more information.
> 2 + 3
5
> 'hello'.toUpperCase()
'HELLO'
> _
'HELLO'           ← _ holds the last evaluated result
> .help
.break    Sometimes you get stuck, this gets you out
.clear    Alias for .break
.editor   Enter editor mode
.exit     Exit the REPL
.help     Print this help message
.load     Load JS from a file into the REPL session
.save     Save all evaluated commands in this REPL session to a file
> .exit
```

### Special REPL Features

```
> const fs = require('node:fs');
undefined
> fs.       ← press Tab here for auto-completion
fs.__defineGetter__      fs.__defineSetter__
fs.access                fs.accessSync
fs.appendFile            fs.appendFileSync
...

> .save session.js       ← saves all commands to a file
Session saved to: session.js

> .load session.js       ← loads and executes a file
```

### Creating a Custom REPL

You can embed a REPL in your application for debugging or building interactive tools.

```javascript
'use strict';

const repl = require('node:repl');

// Start a custom REPL with a custom prompt and context
const myRepl = repl.start({
  prompt: 'myapp> ',
  useColors: true,
  ignoreUndefined: true, // do not print 'undefined' for void expressions
});

// Add variables and functions to the REPL context
myRepl.context.greet = (name) => `Hello, ${name}!`;
myRepl.context.version = '1.0.0';
myRepl.context.db = { users: ['Alice', 'Bob', 'Charlie'] };

// Now in the REPL you can type:
// myapp> greet('World')
// 'Hello, World!'
// myapp> db.users.length
// 3

// Add a custom command
myRepl.defineCommand('status', {
  help: 'Show application status',
  action() {
    console.log('Status: running');
    console.log(`Version: ${this.context.version}`);
    console.log(`Users: ${this.context.db.users.length}`);
    this.displayPrompt();
  },
});

// Type .status in the REPL to run it
```

### REPL Over a Network Socket

You can start a REPL that listens on a TCP socket — useful for debugging long-running processes remotely.

```javascript
'use strict';

const net = require('node:net');
const repl = require('node:repl');

const server = net.createServer((socket) => {
  console.log('REPL client connected');

  const session = repl.start({
    prompt: 'remote> ',
    input: socket,
    output: socket,
    terminal: true,
  });

  session.context.app = {
    uptime: () => process.uptime().toFixed(2) + 's',
    memory: () => {
      const mem = process.memoryUsage();
      return (mem.heapUsed / 1024 / 1024).toFixed(2) + ' MB';
    },
  };

  session.on('exit', () => {
    socket.end();
    console.log('REPL client disconnected');
  });
});

server.listen(5001, '127.0.0.1', () => {
  console.log('REPL server listening on port 5001');
  console.log('Connect with: telnet 127.0.0.1 5001');
});
```

---

## Putting It All Together

Here is a diagnostic script that uses many of the globals covered in this lesson:

```javascript
'use strict';

const os = require('node:os');

console.log('=== Node.js Diagnostic Report ===');
console.log();

// Process info
console.table({
  'Node Version':  process.version,
  'PID':           process.pid,
  'Platform':      process.platform,
  'Architecture':  process.arch,
  'CWD':           process.cwd(),
  'Uptime':        process.uptime().toFixed(2) + 's',
});

// Memory usage
const mem = process.memoryUsage();
console.log('\nMemory:');
console.table({
  'RSS':           (mem.rss / 1024 / 1024).toFixed(2) + ' MB',
  'Heap Total':    (mem.heapTotal / 1024 / 1024).toFixed(2) + ' MB',
  'Heap Used':     (mem.heapUsed / 1024 / 1024).toFixed(2) + ' MB',
  'External':      (mem.external / 1024 / 1024).toFixed(2) + ' MB',
});

// Environment snapshot
console.log('\nEnvironment:');
console.log('  NODE_ENV:', process.env.NODE_ENV || '(not set)');
console.log('  HOME:',     process.env.HOME);
console.log('  SHELL:',    process.env.SHELL || '(not set)');

// Timing a computation
console.time('computation');
let sum = 0;
for (let i = 0; i < 10_000_000; i++) {
  sum += Math.sqrt(i);
}
console.timeEnd('computation');
console.log('  Sum:', sum.toFixed(2));

// Command-line arguments
console.log('\nArguments:', process.argv.slice(2).join(' ') || '(none)');
```

---

## Key Takeaways

- `global` is Node.js's top-level object (equivalent to `window` in browsers), and `globalThis` provides cross-environment compatibility — but you should never attach application state to either
- The `process` object is your gateway to the runtime environment: `process.env` for configuration, `process.argv` for CLI arguments, `process.memoryUsage()` for diagnostics, and `process.hrtime.bigint()` for high-resolution timing
- `console` methods like `.table()`, `.time()`/`.timeEnd()`, `.trace()`, `.count()`, and `.dir()` provide structured debugging without any external tools
- Node.js timers (`setTimeout`, `setInterval`, `setImmediate`, `queueMicrotask`, `process.nextTick`) follow a strict priority order — `nextTick` fires first, then microtasks, then timers, then I/O, then `setImmediate`
- The REPL is more than a calculator — you can create custom REPLs with `repl.start()`, add context variables, define commands, and even serve a REPL over a TCP socket for remote debugging

## Next

Continue to [Lesson 08 — Node.js vs Other Runtimes](lesson-08-nodejs-vs-runtimes.md) to see how Node.js compares to Deno and Bun in architecture, performance, and ecosystem.
