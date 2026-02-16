# Module 04 / Lesson 07 — Path Module Deep Dive

> A path that works on your Mac will break on your teammate's Windows machine. Forward slashes versus backslashes, drive letters versus root directories, case sensitivity versus case preservation — the `path` module absorbs all of this complexity so your code does not have to. Every time you concatenate strings to build a file path, you are writing a bug that has not been discovered yet.

## Learning Objectives

- Use `path.join()` and `path.resolve()` to build paths safely across platforms
- Decompose paths into their components using `parse()`, `basename()`, `dirname()`, and `extname()`
- Understand the difference between `path.posix` and `path.win32` for forced platform behavior
- Prevent path traversal attacks by validating resolved paths against a root directory
- Apply practical patterns for static file serving, extension-based routing, and MIME type resolution

---

## Why String Concatenation Is Broken

The most common mistake in Node.js path handling:

```javascript
'use strict';

// WRONG — breaks on Windows where the separator is '\'
const filePath = '/data' + '/' + 'users' + '/' + 'profile.json';

// ALSO WRONG — double slashes, no normalization
const messy = '/data/' + '/users/' + '//profile.json';
console.log(messy); // /data//users///profile.json
```

The `path` module handles separators, removes redundant slashes, and resolves `.` and `..` segments correctly on every platform.

```javascript
'use strict';

const path = require('node:path');

// CORRECT — always use path.join()
const filePath = path.join('/data', 'users', 'profile.json');
console.log(filePath); // /data/users/profile.json (Unix)
                        // \data\users\profile.json (Windows)

// Handles messy input gracefully
const clean = path.join('/data/', '/users/', '//profile.json');
console.log(clean); // /data/users/profile.json
```

---

## `path.join()` — Joining Path Segments

`path.join()` concatenates path segments using the platform-specific separator and normalizes the result. It does not produce an absolute path — it simply joins what you give it.

```javascript
'use strict';

const path = require('node:path');

console.log(path.join('src', 'utils', 'helpers.js'));
// src/utils/helpers.js

console.log(path.join('/home', 'user', '..', 'admin'));
// /home/admin (the '..' resolved 'user')

console.log(path.join('a', '', 'b'));
// a/b (empty segments are ignored)

console.log(path.join('.', 'src', 'index.js'));
// ./src/index.js

// Zero arguments
console.log(path.join());
// . (current directory)
```

### `join()` Does Not Resolve to Absolute

```javascript
'use strict';

const path = require('node:path');

// join() preserves relative paths — it does not look at the filesystem
console.log(path.join('src', 'index.js'));
// src/index.js (still relative)

// Only if you start with an absolute segment do you get an absolute result
console.log(path.join('/usr', 'local', 'bin'));
// /usr/local/bin
```

---

## `path.resolve()` — Resolving to Absolute Paths

`path.resolve()` processes segments from right to left, prepending each one until it produces an absolute path. If no segment is absolute, it prepends the current working directory.

```javascript
'use strict';

const path = require('node:path');

// Relative segments are resolved against cwd
console.log(path.resolve('src', 'index.js'));
// e.g., /Users/dev/project/src/index.js

// An absolute segment stops the resolution
console.log(path.resolve('/etc', 'nginx', 'nginx.conf'));
// /etc/nginx/nginx.conf

// Later absolute segments override earlier ones (right-to-left processing)
console.log(path.resolve('/var', '/etc', 'hosts'));
// /etc/hosts ('/etc' is absolute, so '/var' is discarded)

// Resolving '..' works
console.log(path.resolve('/usr/local/bin', '..', 'lib'));
// /usr/local/lib
```

### `join()` vs `resolve()` — Key Differences

```javascript
'use strict';

const path = require('node:path');

// join() concatenates — resolve() builds absolute paths
console.log(path.join('a', 'b'));      // a/b (relative)
console.log(path.resolve('a', 'b'));   // /Users/dev/project/a/b (absolute, uses cwd)

// join() preserves leading slashes literally
// resolve() treats them as filesystem root
console.log(path.join('a', '/b'));     // a/b
console.log(path.resolve('a', '/b')); // /b ('/b' is absolute, overrides 'a')
```

| Behavior                           | `path.join()`     | `path.resolve()`         |
|------------------------------------|-------------------|--------------------------|
| Always returns absolute path       | No                | Yes                      |
| Uses current working directory     | No                | Yes, when needed         |
| Handles `..` and `.`               | Yes               | Yes                      |
| Right-to-left absolute override    | No                | Yes                      |

---

## `path.normalize()` — Cleaning Up Paths

`normalize()` resolves `.` and `..` segments and removes duplicate separators, but does not make the path absolute.

```javascript
'use strict';

const path = require('node:path');

console.log(path.normalize('/usr//local/./bin/../lib'));
// /usr/local/lib

console.log(path.normalize('src/./utils/../helpers/index.js'));
// src/helpers/index.js

console.log(path.normalize('////multiple///slashes///'));
// /multiple/slashes/

// Trailing separators are preserved on directories
console.log(path.normalize('/usr/local/'));
// /usr/local/
```

---

## Decomposing Paths — `basename`, `dirname`, `extname`

### `path.basename()` — The File Name

Returns the last portion of a path. Optionally strips an extension.

```javascript
'use strict';

const path = require('node:path');

console.log(path.basename('/home/user/docs/report.pdf'));
// report.pdf

console.log(path.basename('/home/user/docs/report.pdf', '.pdf'));
// report (extension stripped)

console.log(path.basename('/home/user/docs/'));
// docs

console.log(path.basename('/home/user/docs/archive.tar.gz', '.gz'));
// archive.tar (only the specified extension is stripped)
```

### `path.dirname()` — The Directory

Returns everything before the last segment.

```javascript
'use strict';

const path = require('node:path');

console.log(path.dirname('/home/user/docs/report.pdf'));
// /home/user/docs

console.log(path.dirname('/home/user/docs/'));
// /home/user

console.log(path.dirname('src/index.js'));
// src

console.log(path.dirname('file.txt'));
// . (current directory)
```

### `path.extname()` — The Extension

Returns the extension, including the leading dot. Returns an empty string if there is no extension.

```javascript
'use strict';

const path = require('node:path');

console.log(path.extname('report.pdf'));    // .pdf
console.log(path.extname('archive.tar.gz')); // .gz (only the last extension)
console.log(path.extname('.gitignore'));     // '' (dotfiles have no extension)
console.log(path.extname('Makefile'));       // '' (no extension)
console.log(path.extname('file.'));          // . (dot with nothing after)
```

---

## `path.parse()` and `path.format()` — Full Decomposition

`parse()` breaks a path into an object with five properties. `format()` reconstructs a path from such an object.

```javascript
'use strict';

const path = require('node:path');

const parsed = path.parse('/home/user/docs/report.pdf');
console.log(parsed);
// {
//   root: '/',
//   dir: '/home/user/docs',
//   base: 'report.pdf',
//   ext: '.pdf',
//   name: 'report'
// }
```

### The Parsed Path Object

```
  /       home/user/docs  /  report    .pdf
  |            |             |          |
 root         dir           name       ext
  |                     \________/
  |                        base
  \_________________________/
           dir
```

| Property | Value for `/home/user/docs/report.pdf` |
|----------|----------------------------------------|
| `root`   | `/`                                    |
| `dir`    | `/home/user/docs`                      |
| `base`   | `report.pdf`                           |
| `name`   | `report`                               |
| `ext`    | `.pdf`                                 |

### Reconstructing with `path.format()`

```javascript
'use strict';

const path = require('node:path');

// Build a path from components
const filePath = path.format({
  dir: '/home/user/docs',
  name: 'report',
  ext: '.pdf',
});
console.log(filePath); // /home/user/docs/report.pdf

// Change the extension
const parsed = path.parse('/data/output/results.csv');
parsed.base = ''; // Must clear 'base' — it takes priority over name+ext
parsed.ext = '.json';
console.log(path.format(parsed)); // /data/output/results.json
```

### `format()` Priority Rules

When both `base` and `name`/`ext` are set, `base` wins. Always clear `base` if you want `name` and `ext` to take effect.

```javascript
'use strict';

const path = require('node:path');

// base takes priority over name + ext
console.log(path.format({ dir: '/tmp', base: 'data.csv', name: 'output', ext: '.json' }));
// /tmp/data.csv  (base wins — name and ext are ignored)

// Clear base to use name + ext
console.log(path.format({ dir: '/tmp', name: 'output', ext: '.json' }));
// /tmp/output.json
```

---

## `path.relative()` — Computing Relative Paths

Given two absolute paths, `relative()` computes how to get from one to the other using `..` segments.

```javascript
'use strict';

const path = require('node:path');

console.log(path.relative('/home/user/project', '/home/user/project/src/index.js'));
// src/index.js

console.log(path.relative('/home/user/project/src', '/home/user/project/test'));
// ../test

console.log(path.relative('/home/user', '/var/log'));
// ../../var/log

// Same path returns empty string
console.log(path.relative('/home/user', '/home/user'));
// '' (empty string)
```

---

## `path.isAbsolute()` — Checking Absolute Paths

```javascript
'use strict';

const path = require('node:path');

// Unix
console.log(path.isAbsolute('/usr/local'));    // true
console.log(path.isAbsolute('./src'));          // false
console.log(path.isAbsolute('src/index.js'));   // false

// Windows (using path.win32)
console.log(path.win32.isAbsolute('C:\\Users')); // true
console.log(path.win32.isAbsolute('\\server'));   // true
console.log(path.win32.isAbsolute('src'));         // false
```

---

## Platform Constants — `sep`, `delimiter`, `posix`, `win32`

```javascript
'use strict';

const path = require('node:path');

// Path separator (used between directory components)
console.log(path.sep);
// '/' on Unix, '\\' on Windows

// PATH delimiter (used in environment variable lists like $PATH)
console.log(path.delimiter);
// ':' on Unix, ';' on Windows

// Parse the system PATH
const pathDirs = process.env.PATH.split(path.delimiter);
console.log('PATH directories:', pathDirs.length);
pathDirs.forEach((dir) => console.log(' ', dir));
```

### Forced Platform Behavior — `path.posix` and `path.win32`

When you need consistent behavior regardless of the current platform (e.g., generating URLs on a Windows server, or parsing Windows paths on Linux):

```javascript
'use strict';

const path = require('node:path');

// Always use forward slashes (useful for URLs)
console.log(path.posix.join('api', 'users', '123'));
// api/users/123 (always forward slashes, even on Windows)

// Parse a Windows path on any platform
console.log(path.win32.parse('C:\\Users\\admin\\file.txt'));
// { root: 'C:\\', dir: 'C:\\Users\\admin', base: 'file.txt', ext: '.txt', name: 'file' }

// Generate URLs from file paths
function filePathToUrl(filePath, baseUrl) {
  const relative = path.posix.join(...filePath.split(path.sep));
  return new URL(relative, baseUrl).href;
}

console.log(filePathToUrl('static/css/main.css', 'https://example.com/'));
// https://example.com/static/css/main.css
```

---

## Path Traversal Prevention

This is a critical security pattern. When serving files from a directory, you must ensure the resolved path stays within the root directory. Without this check, an attacker can request `../../../etc/passwd`.

```javascript
'use strict';

const path = require('node:path');

function safePath(rootDir, userInput) {
  // Resolve the root to an absolute path
  const root = path.resolve(rootDir);

  // Resolve the user input relative to the root
  const resolved = path.resolve(root, userInput);

  // Ensure the resolved path starts with the root + separator
  // (or equals the root exactly)
  if (!resolved.startsWith(root + path.sep) && resolved !== root) {
    throw new Error(`Path traversal detected: ${userInput}`);
  }

  return resolved;
}

// Safe inputs
console.log(safePath('/var/www/public', 'images/logo.png'));
// /var/www/public/images/logo.png

console.log(safePath('/var/www/public', 'css/style.css'));
// /var/www/public/css/style.css

// Attack attempts — all caught
try {
  safePath('/var/www/public', '../../../etc/passwd');
} catch (err) {
  console.error(err.message);
  // Path traversal detected: ../../../etc/passwd
}

try {
  safePath('/var/www/public', '/etc/passwd');
} catch (err) {
  console.error(err.message);
  // Path traversal detected: /etc/passwd
}
```

### Why `root + path.sep` Is Important

```javascript
'use strict';

const path = require('node:path');

const root = '/var/www/public';

// Without the separator check, this would pass:
// '/var/www/public-admin/secret.txt'.startsWith('/var/www/public') === true
// But with root + '/', it correctly fails:
// '/var/www/public-admin/secret.txt'.startsWith('/var/www/public/') === false
```

---

## Practical Pattern: Static File Server Path Resolution

A complete static file handler that combines path validation, extension detection, and MIME type mapping.

```javascript
'use strict';

const path = require('node:path');
const fs = require('node:fs');

const MIME_TYPES = {
  '.html': 'text/html',
  '.css':  'text/css',
  '.js':   'application/javascript',
  '.json': 'application/json',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif':  'image/gif',
  '.svg':  'image/svg+xml',
  '.ico':  'image/x-icon',
  '.txt':  'text/plain',
  '.pdf':  'application/pdf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
};

function resolveStaticFile(publicDir, requestUrl) {
  // Strip query string and decode URI components
  const urlPath = decodeURIComponent(requestUrl.split('?')[0]);

  // Map '/' to '/index.html'
  const fileName = urlPath === '/' ? '/index.html' : urlPath;

  // Resolve against the public directory
  const root = path.resolve(publicDir);
  const filePath = path.resolve(root, '.' + fileName);

  // Path traversal check
  if (!filePath.startsWith(root + path.sep) && filePath !== root) {
    return { error: 403, message: 'Forbidden' };
  }

  // Check if file exists and is a file (not a directory)
  try {
    const stat = fs.statSync(filePath);
    if (!stat.isFile()) {
      return { error: 404, message: 'Not Found' };
    }
  } catch {
    return { error: 404, message: 'Not Found' };
  }

  // Determine MIME type from extension
  const ext = path.extname(filePath).toLowerCase();
  const mimeType = MIME_TYPES[ext] || 'application/octet-stream';

  return { filePath, mimeType, error: null };
}

// Examples
console.log(resolveStaticFile('./public', '/css/style.css'));
// { filePath: '/abs/path/public/css/style.css', mimeType: 'text/css', error: null }

console.log(resolveStaticFile('./public', '/../../../etc/passwd'));
// { error: 403, message: 'Forbidden' }
```

---

## Practical Pattern: Extension-Based File Router

Route files to different handlers based on their extension.

```javascript
'use strict';

const path = require('node:path');

function createExtensionRouter(handlers) {
  const defaultHandler = handlers['*'] || ((filePath) => {
    console.log(`No handler for ${path.extname(filePath) || '(no extension)'}: ${filePath}`);
  });

  return function route(filePath) {
    const ext = path.extname(filePath).toLowerCase();
    const handler = handlers[ext] || defaultHandler;
    return handler(filePath);
  };
}

// Usage
const router = createExtensionRouter({
  '.js':   (f) => console.log(`Lint + bundle: ${path.basename(f)}`),
  '.css':  (f) => console.log(`Minify: ${path.basename(f)}`),
  '.json': (f) => console.log(`Validate schema: ${path.basename(f)}`),
  '.md':   (f) => console.log(`Render markdown: ${path.basename(f)}`),
  '*':     (f) => console.log(`Copy as-is: ${path.basename(f)}`),
});

router('/project/src/app.js');     // Lint + bundle: app.js
router('/project/styles/main.css'); // Minify: main.css
router('/project/data/config.json'); // Validate schema: config.json
router('/project/README.md');       // Render markdown: README.md
router('/project/assets/logo.png'); // Copy as-is: logo.png
```

---

## Common Mistakes

### Mistake 1: Using `__dirname` with `path.join()` vs `path.resolve()`

Both work for building absolute paths from `__dirname`, but `resolve()` is safer when user input is involved.

```javascript
'use strict';

const path = require('node:path');

// Both produce the same result from __dirname
console.log(path.join(__dirname, 'config', 'default.json'));
console.log(path.resolve(__dirname, 'config', 'default.json'));

// But with user input, resolve() is more predictable:
const userInput = '/etc/passwd'; // malicious input
console.log(path.join(__dirname, userInput));
// /Users/dev/project/etc/passwd — join just concatenates

console.log(path.resolve(__dirname, userInput));
// /etc/passwd — resolve treats it as absolute, which you can then validate
```

### Mistake 2: Forgetting that `extname('.gitignore')` Returns Empty

```javascript
'use strict';

const path = require('node:path');

// These are dotfiles, not files with extensions
console.log(path.extname('.gitignore'));  // ''
console.log(path.extname('.env'));        // ''
console.log(path.extname('.eslintrc'));   // ''

// These have actual extensions
console.log(path.extname('.eslintrc.js'));  // '.js'
console.log(path.extname('.env.local'));    // '.local'
```

### Mistake 3: Assuming `path.sep` When Building URLs

```javascript
'use strict';

const path = require('node:path');

// WRONG — on Windows, path.join uses backslashes
const badUrl = '/api/' + path.join('users', '123', 'profile');
// On Windows: /api/users\123\profile

// CORRECT — use path.posix for URL paths
const goodUrl = '/api/' + path.posix.join('users', '123', 'profile');
// /api/users/123/profile (always forward slashes)
```

---

## Key Takeaways

- Always use `path.join()` for concatenating path segments — string concatenation produces broken paths on Windows and does not normalize `..` or duplicate separators
- `path.resolve()` produces absolute paths by resolving right-to-left and prepending `cwd` when needed; `path.join()` simply concatenates and normalizes
- `path.parse()` gives you `{ root, dir, base, name, ext }` — clear `base` before setting `name`/`ext` in `path.format()` because `base` takes priority
- Always validate user-supplied paths with `path.resolve()` and check that the result starts with your root directory plus `path.sep` — this prevents path traversal attacks like `../../etc/passwd`
- Use `path.posix` when building URL paths and `path.win32` when parsing Windows paths on non-Windows platforms — the default `path` module uses the current platform's conventions

---

## Next

This concludes Module 04. Continue to [Module 05 — Streams](../module-05-streams/lesson-01-stream-fundamentals.md), where you will learn how streams process data incrementally without loading entire files into memory — the foundation of scalable I/O in Node.js.
