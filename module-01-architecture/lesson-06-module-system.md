# Module 01 / Lesson 06 — Module System (CommonJS & ESM)

> No Node.js application is a single file. The module system is how you split code into reusable pieces, control what is exported and what stays private, and manage dependencies. Node.js supports two module systems — CommonJS (the original, synchronous `require` system) and ECMAScript Modules (the JavaScript standard `import`/`export` system). Knowing both, and knowing when they conflict, is essential.

## Learning Objectives

- Trace the complete `require()` resolution algorithm: file extensions, directory lookups, and `node_modules` traversal
- Explain the difference between `module.exports` and `exports`, and why reassigning `exports` breaks
- Describe how module caching works and what `require.cache` contains
- Use ESM `import`/`export` syntax with `.mjs` files and `"type": "module"`
- Identify the key differences between CommonJS and ESM: synchronous vs async loading, `this` binding, top-level `await`

---

## CommonJS: The Original Module System

CommonJS was designed by Ryan Dahl for Node.js in 2009, long before JavaScript had a standard module system. It is synchronous, simple, and still the default in Node.js.

Every file in a CommonJS project is a module. Node.js wraps your code in a function before executing it:

```javascript
// What you write:
'use strict';
const x = 42;
module.exports = x;

// What Node.js actually executes:
(function(exports, require, module, __filename, __dirname) {
  'use strict';
  const x = 42;
  module.exports = x;
});
```

This wrapper function is why `__filename`, `__dirname`, `exports`, `require`, and `module` are available in every file without you declaring them — they are function parameters, not global variables.

---

## The require() Resolution Algorithm

When you call `require('something')`, Node.js follows a precise algorithm to find the module. Understanding this algorithm prevents mysterious "Cannot find module" errors.

### Step 1: Core Modules

If the argument matches a built-in module name (with or without the `node:` prefix), return the built-in module immediately:

```javascript
'use strict';

// Both resolve to the same built-in module
const fs1 = require('node:fs');
const fs2 = require('fs');

console.log(fs1 === fs2); // true
console.log('Core modules are always found first');
```

### Step 2: File Paths (Relative or Absolute)

If the argument starts with `./`, `../`, or `/`, Node.js treats it as a file path and tries these extensions in order:

1. Exact filename: `./math` (looks for a file literally named `math`)
2. `.js` extension: `./math.js`
3. `.json` extension: `./math.json`
4. `.node` extension: `./math.node` (compiled C++ addon)

```javascript
'use strict';

// Create these files to test resolution order:
// ./math.js       → module.exports = { add: (a, b) => a + b };
// ./math.json     → { "pi": 3.14159 }

// require('./math') finds math.js first because .js beats .json
const math = require('./math');
console.log(math);
```

### Step 3: Directory as Module

If the path points to a directory, Node.js looks for:

1. A `package.json` file with a `"main"` field
2. An `index.js` file
3. An `index.json` file
4. An `index.node` file

```javascript
'use strict';

// If you have:
// ./utils/package.json  → { "main": "lib/entry.js" }
// ./utils/lib/entry.js  → module.exports = 'from entry';
// ./utils/index.js      → module.exports = 'from index';

// require('./utils') reads package.json, follows "main" to lib/entry.js
const utils = require('./utils');
// If package.json has no "main", falls back to index.js
```

### Step 4: node_modules Lookup

If the argument does not start with `./`, `../`, or `/`, and is not a core module, Node.js searches for a `node_modules` directory:

```
require('lodash') from /home/user/project/src/app.js

Searches:
  /home/user/project/src/node_modules/lodash
  /home/user/project/node_modules/lodash
  /home/user/node_modules/lodash
  /home/node_modules/lodash
  /node_modules/lodash
```

Node.js walks up the directory tree, checking each `node_modules` folder until it finds the module or reaches the filesystem root.

```javascript
'use strict';

// You can see the full search path for any module:
console.log('Module search paths:');
console.log(module.paths);

// Output (example):
// [
//   '/home/user/project/src/node_modules',
//   '/home/user/project/node_modules',
//   '/home/user/node_modules',
//   '/home/node_modules',
//   '/node_modules'
// ]
```

---

## module.exports vs exports

This is one of the most common sources of confusion in Node.js. Here is the definitive explanation.

`module.exports` is the actual object that `require()` returns. `exports` is a *reference* to `module.exports` — a convenience shortcut.

```javascript
'use strict';

// These two are equivalent:
exports.add = (a, b) => a + b;
module.exports.add = (a, b) => a + b;

// Both work because exports === module.exports initially
console.log(exports === module.exports); // true
```

The trap: if you reassign `exports`, you break the reference:

```javascript
'use strict';

// BAD — this does NOT work
exports = { add: (a, b) => a + b };
// You reassigned the local variable 'exports'
// but module.exports still points to the original empty object
// require() returns module.exports, not your new object

// GOOD — reassign module.exports directly
module.exports = { add: (a, b) => a + b };
// require() returns this object
```

```javascript
'use strict';

// Demonstration of the broken reference

// In math.js:
// exports = { add: (a, b) => a + b };  // BROKEN

// In app.js:
// const math = require('./math');
// console.log(math);        // {} — empty object!
// console.log(math.add);    // undefined

// Fix: always use module.exports for full replacement
// module.exports = { add: (a, b) => a + b };  // CORRECT
```

**Rule:** Use `exports.foo = ...` to add properties. Use `module.exports = ...` to replace the entire export. Never reassign `exports` itself.

---

## Module Caching

Node.js caches modules after the first `require()`. Subsequent calls to `require()` with the same resolved path return the cached module — the file is not re-read or re-executed.

```javascript
'use strict';

// counter.js
// let count = 0;
// module.exports = {
//   increment() { return ++count; },
//   getCount() { return count; }
// };

// app.js
const counter1 = require('./counter');
const counter2 = require('./counter');

console.log(counter1 === counter2); // true — same cached object

counter1.increment();
counter1.increment();

console.log(counter2.getCount()); // 2 — they share state!
```

You can inspect and manipulate the cache:

```javascript
'use strict';

// See all cached modules
console.log('Cached modules:');
console.log(Object.keys(require.cache));

// Delete a module from cache (force re-evaluation on next require)
// delete require.cache[require.resolve('./counter')];
// const freshCounter = require('./counter'); // Re-executes the file
```

### Cache Key: The Resolved Path

The cache key is the **absolute, resolved file path**, not the argument you passed to `require()`. This means:

```javascript
'use strict';

// These all resolve to the same file → same cache entry
const a = require('./math');
const b = require('./math.js');
const c = require('../module-01-architecture/math');

// a === b === c (assuming they all resolve to the same absolute path)
```

---

## Circular Dependencies

CommonJS handles circular dependencies gracefully (though the results can be surprising). When module A requires module B, and module B requires module A, Node.js returns a **partially populated** version of module A to module B.

```javascript
'use strict';

// --- a.js ---
console.log('a.js: starting');
exports.loaded = false;

const b = require('./b');
console.log(`a.js: b.loaded = ${b.loaded}`);

exports.loaded = true;
console.log('a.js: done');

// --- b.js ---
console.log('b.js: starting');
exports.loaded = false;

const a = require('./a');
// At this point, a.js has NOT finished executing.
// a.loaded is false (the partial export from before b was required)
console.log(`b.js: a.loaded = ${a.loaded}`); // false!

exports.loaded = true;
console.log('b.js: done');

// --- main.js ---
const a = require('./a');

// Output:
// a.js: starting
// b.js: starting
// b.js: a.loaded = false    ← partial export!
// b.js: done
// a.js: b.loaded = true
// a.js: done
```

Circular dependencies are not errors, but they indicate tightly coupled modules. Refactor if you find them in your codebase.

---

## ECMAScript Modules (ESM)

ESM is the JavaScript standard module system, specified in the ECMAScript language spec. Node.js has supported ESM since version 12 (experimental) and version 16+ (stable).

### Enabling ESM

There are two ways to use ESM in Node.js:

1. **File extension:** Use `.mjs` instead of `.js`
2. **package.json:** Add `"type": "module"` — all `.js` files in the package become ESM

```javascript
// math.mjs — ESM module

export function add(a, b) {
  return a + b;
}

export function multiply(a, b) {
  return a * b;
}

export default function subtract(a, b) {
  return a - b;
}
```

```javascript
// app.mjs — ESM consumer

import subtract, { add, multiply } from './math.mjs';

console.log(add(2, 3));        // 5
console.log(multiply(4, 5));   // 20
console.log(subtract(10, 3));  // 7

// Named exports use { }
// Default export has no braces
```

### Top-Level Await

ESM supports `await` at the top level — no need to wrap everything in an `async function`:

```javascript
// fetch-data.mjs

import { readFile } from 'node:fs/promises';

// Top-level await — only works in ESM
const content = await readFile('./data.json', 'utf8');
const data = JSON.parse(content);

console.log(`Loaded ${Object.keys(data).length} keys`);
export { data };
```

This is one of the most compelling reasons to use ESM. In CommonJS, you would need an async IIFE or callback pattern.

### ESM vs CommonJS: Key Differences

| Feature | CommonJS | ESM |
|---------|----------|-----|
| Syntax | `require()` / `module.exports` | `import` / `export` |
| Loading | Synchronous | Asynchronous |
| Parsing | Dynamic (can `require()` inside if/else) | Static (imports must be top-level) |
| `this` at top level | `module.exports` (the exports object) | `undefined` |
| `__dirname` / `__filename` | Available | Not available (use `import.meta.url`) |
| Top-level `await` | Not supported | Supported |
| File extension | `.js` (default) or `.cjs` | `.mjs` or `.js` with `"type": "module"` |
| Strict mode | Optional (`'use strict'` required) | Always strict |
| Circular dependencies | Returns partial export | Returns live bindings (updated when source changes) |
| JSON import | `require('./data.json')` works | Requires import assertion or `createRequire` |

### Replacing __dirname and __filename in ESM

```javascript
// dirname-esm.mjs

import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

console.log(`__filename: ${__filename}`);
console.log(`__dirname:  ${__dirname}`);
```

---

## Interop: Mixing CommonJS and ESM

You can import CommonJS modules from ESM, but not the other way around (with standard `require`):

```javascript
// ESM importing CommonJS — works fine
// app.mjs

import cjsModule from './legacy-module.cjs';
// CJS default export becomes the default import

console.log(cjsModule);
```

```javascript
// CommonJS importing ESM — requires dynamic import()
// app.cjs
'use strict';

async function main() {
  // Cannot use require() for ESM modules
  // Must use dynamic import() which returns a Promise
  const esmModule = await import('./modern-module.mjs');
  console.log(esmModule.default);
  console.log(esmModule.namedExport);
}

main();
```

As of Node.js 22+, `require(esm)` is supported for ESM modules that do not use top-level `await`, making interop smoother.

---

## Module System Internals

Under the hood, `require()` uses the `Module` class from `node:module`:

```javascript
'use strict';

const Module = require('node:module');

// See the resolution algorithm in action
console.log('Resolve node:fs:', Module._resolveFilename('node:fs'));
console.log('Resolve this file:', Module._resolveFilename(__filename));

// See how Node.js wraps your code
console.log('\nModule wrapper:');
console.log(Module.wrap('const x = 42;'));
// Output:
// (function (exports, require, module, __filename, __dirname) { const x = 42;
// });

// List all built-in modules
console.log('\nBuilt-in modules:');
console.log(Module.builtinModules.filter(m => !m.startsWith('_')).join(', '));
```

---

## Practical Patterns

### Pattern 1: Exporting a Class

```javascript
'use strict';

// logger.js
class Logger {
  #prefix;

  constructor(prefix) {
    this.#prefix = prefix;
  }

  info(message) {
    console.log(`[${this.#prefix}] INFO: ${message}`);
  }

  error(message) {
    console.error(`[${this.#prefix}] ERROR: ${message}`);
  }
}

module.exports = Logger;

// Usage:
// const Logger = require('./logger');
// const log = new Logger('app');
// log.info('Server started');
```

### Pattern 2: Exporting a Singleton

```javascript
'use strict';

// config.js — singleton via module caching
const config = {
  port: parseInt(process.env.PORT, 10) || 3000,
  host: process.env.HOST || '127.0.0.1',
  env: process.env.NODE_ENV || 'development',
};

// Freeze to prevent accidental mutation
Object.freeze(config);

module.exports = config;

// Every file that requires('./config') gets the same frozen object
```

### Pattern 3: Conditional Exports

```javascript
'use strict';

// adapter.js — load the right implementation at runtime
const platform = process.platform;

let adapter;
if (platform === 'win32') {
  adapter = require('./adapters/windows');
} else if (platform === 'darwin') {
  adapter = require('./adapters/macos');
} else {
  adapter = require('./adapters/linux');
}

module.exports = adapter;

// This dynamic require is only possible in CommonJS.
// ESM imports are static — you would need dynamic import() for this.
```

---

## Key Takeaways

- `require()` follows a strict resolution algorithm: core modules first, then file extensions (`.js`, `.json`, `.node`), then directory lookup (`package.json` main, `index.js`), then `node_modules` traversal up the directory tree
- `module.exports` is the real export object; `exports` is a shortcut reference — never reassign `exports` directly, always use `module.exports` for full replacement
- Modules are cached by their resolved absolute path after first `require()` — subsequent calls return the cached object without re-executing the file
- ESM (`import`/`export`) is the JavaScript standard: it supports top-level `await`, static analysis, and is always in strict mode — prefer it for new projects
- CommonJS and ESM can interoperate: ESM can `import` CJS modules directly, CJS can use dynamic `import()` to load ESM modules

## Next

The next lesson explores the global objects and functions that Node.js provides out of the box — `process`, `global`, `Buffer`, `console`, and the REPL environment.
