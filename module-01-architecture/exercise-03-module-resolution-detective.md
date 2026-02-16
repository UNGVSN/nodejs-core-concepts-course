# E03: Module Resolution Detective

## Objective

Instrument Node.js's `require()` mechanism to trace the full resolution path for every loaded module. You will hook into the internal module resolution machinery to see exactly where Node.js looks for files, how caching works, and why some paths are tried and rejected before the final path is found.

## Prerequisites

- Module 01 / Lesson 06 — Module System (CommonJS, ESM, and Resolution)
- Module 01 / Lesson 07 — Global Objects and the REPL

## Instructions

1. Create a file called `module-detective.js`. Add `'use strict';` at the top:

```javascript
'use strict';

const Module = require('node:module');
const path = require('node:path');
```

2. Save a reference to the original `Module._resolveFilename` before monkey-patching it:

```javascript
const originalResolve = Module._resolveFilename;
const resolutionLog = [];
```

3. Replace `Module._resolveFilename` with a wrapper that logs every resolution attempt. The function signature is `_resolveFilename(request, parent, isMain, options)`:

```javascript
Module._resolveFilename = function(request, parent, isMain, options) {
  const parentFile = parent ? parent.filename : '(main)';
  const entry = {
    request,
    parentFile: path.relative(process.cwd(), parentFile),
    isMain,
    resolvedTo: null,
    timestamp: Date.now(),
  };

  try {
    const resolved = originalResolve.call(this, request, parent, isMain, options);
    entry.resolvedTo = resolved;
    resolutionLog.push(entry);
    return resolved;
  } catch (err) {
    entry.resolvedTo = `ERROR: ${err.code}`;
    resolutionLog.push(entry);
    throw err;
  }
};
```

4. Create three local modules to test resolution paths:
   - `detective-utils.js` — exports a single `greet(name)` function
   - `detective-data.json` — a simple JSON file with `{ "version": 1 }`
   - A `detective-lib/` directory with an `index.js` that exports `{ name: 'detective-lib' }`

5. In `module-detective.js`, require all three local modules plus two core modules (`node:fs` and `node:path`). Also attempt to require a non-existent module inside a `try/catch` to capture the failed resolution:

```javascript
const utils = require('./detective-utils');
const data = require('./detective-data.json');
const lib = require('./detective-lib');
const fs = require('node:fs');
const pathMod = require('node:path');

try {
  require('./does-not-exist');
} catch (e) {
  console.log(`Expected error: ${e.code}`);
}
```

6. Print a formatted resolution report after all requires complete:

```javascript
console.log('\n=== Module Resolution Report ===\n');
console.log(`Total resolutions: ${resolutionLog.length}\n`);

resolutionLog.forEach((entry, i) => {
  console.log(`[${i + 1}] require('${entry.request}')`);
  console.log(`    From: ${entry.parentFile}`);
  console.log(`    Resolved: ${entry.resolvedTo}`);
  console.log(`    Main: ${entry.isMain}`);
  console.log('');
});
```

7. Add a cache inspection section. After all requires, iterate `require.cache` and print every cached module path:

```javascript
console.log('=== Module Cache ===\n');
const cached = Object.keys(require.cache);
cached.forEach((key) => {
  const mod = require.cache[key];
  console.log(`  ${path.relative(process.cwd(), key)}`);
  console.log(`    children: ${mod.children.map(c => path.basename(c.filename)).join(', ') || '(none)'}`);
});
```

8. Require the same module twice (`./detective-utils`) and verify the resolution hook fires only once for the cached version. Log whether the second `require()` triggered resolution or hit the cache directly.

9. Add a `Module._resolveFilename` counter that tracks how many times resolution is called vs. how many times the cache was used. Print the summary.

10. Run the script with `node module-detective.js` and verify your output shows the full resolution chain, failed lookups, cache hits, and the module dependency tree.

## Break-Then-Harden Challenge

1. **Circular dependency.** Create two files `circle-a.js` and `circle-b.js` that require each other. Instrument `_resolveFilename` to detect when a circular require occurs (the requested module is already in `require.cache` but not yet fully loaded). Log a warning when this happens.

2. **Cache busting.** After requiring `./detective-utils`, delete it from `require.cache` and require it again. Observe that `_resolveFilename` fires again. Then modify the module's exports between the two requires and prove that the second require loads fresh code.

3. **Relative path confusion.** Require the same file using three different paths: `'./detective-utils'`, `'./detective-utils.js'`, and the absolute path. Check whether Node.js treats them as the same cached module or creates separate cache entries.

## Expected Output

```
Expected error: MODULE_NOT_FOUND

=== Module Resolution Report ===

Total resolutions: 6

[1] require('./detective-utils')
    From: module-detective.js
    Resolved: /full/path/to/detective-utils.js
    Main: false

[2] require('./detective-data.json')
    From: module-detective.js
    Resolved: /full/path/to/detective-data.json
    Main: false

[3] require('./detective-lib')
    From: module-detective.js
    Resolved: /full/path/to/detective-lib/index.js
    Main: false

[4] require('node:fs')
    From: module-detective.js
    Resolved: node:fs
    Main: false

[5] require('node:path')
    From: module-detective.js
    Resolved: node:path
    Main: false

[6] require('./does-not-exist')
    From: module-detective.js
    Resolved: ERROR: MODULE_NOT_FOUND
    Main: false

=== Module Cache ===

  module-detective.js
    children: detective-utils.js, detective-data.json, index.js
  detective-utils.js
    children: (none)
  detective-data.json
    children: (none)
  detective-lib/index.js
    children: (none)
```

## Bonus

1. Extend the detective to also hook `Module._load` and measure the time each module takes to load (parse + execute). Print a "slowest modules" ranking.

2. Generate a module dependency graph in DOT format (Graphviz) by tracking the parent-child relationships from the resolution log. Output it to `module-graph.dot`.

## Hints

1. `Module._resolveFilename` is called even for built-in modules — but built-ins resolve to strings like `'node:fs'`, not file paths.
2. The `parent` argument is the `Module` object of the file that called `require()`. For the main script, there is no parent.
3. Core modules with the `node:` prefix bypass the file system entirely — `_resolveFilename` returns the string as-is.
4. `require.cache` keys are always **absolute paths**. Two different relative paths resolving to the same absolute path share one cache entry.
5. Directory requires try `index.js`, then `index.json`, then `index.node` — your hook will show each attempt if the first ones fail.
