# Module 04 / Lesson 05 — Directory Operations

> Files get all the attention, but directories are the skeleton of every file system. You cannot create a file unless its parent directory exists. You cannot deploy an application unless you can safely create, list, traverse, and remove entire directory trees. Node.js provides a full toolkit for directory manipulation — from one-shot `mkdir` calls to memory-efficient async iterators that handle directories containing millions of entries.

## Learning Objectives

- Create directories with `mkdir` and `mkdirSync`, including recursive creation of deep paths
- List directory contents using `readdir` and parse results with `Dirent` objects
- Use `opendir()` and async iterators for memory-efficient traversal of large directories
- Remove, rename, copy, and move directories safely using the modern `fs.rm()` and `fs.cp()` APIs
- Build a recursive directory tree walker and manage temporary directories with `mkdtemp`

---

## Creating Directories — `mkdir`

The most basic directory operation. Without `{ recursive: true }`, the parent directory must already exist.

```javascript
'use strict';

const fs = require('node:fs');

// Create a single directory — parent must exist
fs.mkdirSync('/tmp/my-app');

// This throws ENOENT if /tmp/my-app/data doesn't exist yet
try {
  fs.mkdirSync('/tmp/my-app/data/cache/thumbnails');
} catch (err) {
  console.error(err.code); // ENOENT
  console.error(err.message);
}
```

### Recursive Creation

The `{ recursive: true }` option creates every missing directory in the path. It does not throw if the directory already exists — making it idempotent.

```javascript
'use strict';

const fs = require('node:fs');

// Creates /tmp/my-app, /tmp/my-app/data, /tmp/my-app/data/cache — all at once
fs.mkdirSync('/tmp/my-app/data/cache', { recursive: true });

// Safe to call again — no error
fs.mkdirSync('/tmp/my-app/data/cache', { recursive: true });
```

### Return Value with `recursive: true`

When `recursive` is true, `mkdirSync` returns the first directory that was actually created (or `undefined` if nothing was created).

```javascript
'use strict';

const fs = require('node:fs');

// First call — returns the first created directory
const created = fs.mkdirSync('/tmp/project/src/utils', { recursive: true });
console.log(created); // '/tmp/project' (the first directory that didn't exist)

// Second call — everything exists already
const again = fs.mkdirSync('/tmp/project/src/utils', { recursive: true });
console.log(again); // undefined (nothing was created)
```

### Promise-Based `mkdir`

```javascript
'use strict';

const fs = require('node:fs/promises');

async function ensureDirectory(dirPath) {
  try {
    await fs.mkdir(dirPath, { recursive: true });
    console.log('Directory ready:', dirPath);
  } catch (err) {
    if (err.code === 'EACCES') {
      console.error('Permission denied:', dirPath);
    } else {
      throw err;
    }
  }
}

ensureDirectory('/tmp/uploads/2026/02/15');
```

---

## Listing Directory Contents — `readdir`

`readdir` returns the names of all entries in a directory. By default it returns an array of strings.

```javascript
'use strict';

const fs = require('node:fs');

// Returns array of strings: ['file1.txt', 'file2.txt', 'subdir']
const entries = fs.readdirSync('/tmp/my-app');
console.log(entries);
```

### The `withFileTypes` Option — Dirent Objects

Passing `{ withFileTypes: true }` returns `Dirent` objects instead of strings. This avoids an extra `stat` call for each entry — a significant performance win when you need to distinguish files from directories.

```javascript
'use strict';

const fs = require('node:fs');

const entries = fs.readdirSync('/tmp/my-app', { withFileTypes: true });

for (const entry of entries) {
  console.log(entry.name, {
    isFile: entry.isFile(),
    isDirectory: entry.isDirectory(),
    isSymbolicLink: entry.isSymbolicLink(),
    isBlockDevice: entry.isBlockDevice(),
    isCharacterDevice: entry.isCharacterDevice(),
    isFIFO: entry.isFIFO(),
    isSocket: entry.isSocket(),
  });
}
```

### Dirent Properties at a Glance

| Method                | Returns `true` When                    |
|-----------------------|---------------------------------------|
| `entry.isFile()`      | Regular file                          |
| `entry.isDirectory()` | Directory                             |
| `entry.isSymbolicLink()` | Symbolic link                      |
| `entry.isBlockDevice()` | Block device (disks)                |
| `entry.isCharacterDevice()` | Character device (terminals)    |
| `entry.isFIFO()`     | Named pipe                           |
| `entry.isSocket()`    | Unix domain socket                    |

### Recursive Listing (Node 18.17+)

Node 18.17 added a `{ recursive: true }` option to `readdir` that returns all entries in the tree.

```javascript
'use strict';

const fs = require('node:fs');

// Returns all files and directories, recursively, as relative paths
const all = fs.readdirSync('/tmp/my-app', { recursive: true });
console.log(all);
// ['README.md', 'src', 'src/index.js', 'src/utils', 'src/utils/helpers.js']

// Combine with withFileTypes for full power
const allWithTypes = fs.readdirSync('/tmp/my-app', {
  withFileTypes: true,
  recursive: true,
});

const allFiles = allWithTypes
  .filter((entry) => entry.isFile())
  .map((entry) => entry.name);

console.log('All files:', allFiles);
```

---

## Memory-Efficient Listing — `opendir`

`readdir` loads every entry into memory at once. For directories with hundreds of thousands of entries, this can consume significant memory. `opendir` returns a `Dir` object that supports async iteration, reading one entry at a time.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function listLargeDirectory(dirPath) {
  const dir = await fs.opendir(dirPath);
  let count = 0;

  for await (const entry of dir) {
    count++;
    if (entry.isFile()) {
      // Process file without loading the entire directory listing into memory
      console.log('File:', entry.name);
    }
  }

  console.log('Total entries:', count);
}

listLargeDirectory('/tmp/large-dir').catch(console.error);
```

### Manual Iteration with `dir.read()`

If you need more control than `for await`, you can read entries one at a time.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function findFirst(dirPath, predicate) {
  const dir = await fs.opendir(dirPath);

  try {
    let entry;
    while ((entry = await dir.read()) !== null) {
      if (predicate(entry)) {
        return entry;
      }
    }
    return null;
  } finally {
    await dir.close();
  }
}

// Find the first .json file in a directory
findFirst('/tmp/configs', (entry) => entry.name.endsWith('.json'))
  .then((result) => console.log('Found:', result?.name ?? 'none'))
  .catch(console.error);
```

### `readdir` vs `opendir` — When to Use Each

| Scenario                               | Preferred API    |
|----------------------------------------|------------------|
| Small directories (< 10,000 entries)   | `readdir`        |
| Large directories (100K+ entries)      | `opendir`        |
| Need all entries for sorting/filtering | `readdir`        |
| Processing entries one at a time       | `opendir`        |
| Building a file search tool            | `opendir`        |

---

## Removing Directories — `rmdir` vs `rm`

### `rmdir` — Empty Directories Only

`rmdir` removes only empty directories. If the directory contains any files or subdirectories, it throws `ENOTEMPTY`.

```javascript
'use strict';

const fs = require('node:fs');

try {
  fs.rmdirSync('/tmp/empty-dir');
  console.log('Removed empty directory');
} catch (err) {
  if (err.code === 'ENOTEMPTY') {
    console.error('Directory is not empty');
  } else if (err.code === 'ENOENT') {
    console.error('Directory does not exist');
  } else {
    throw err;
  }
}
```

### `rm` with `{ recursive: true }` — The Modern Approach

`fs.rm()` (Node 14.14+) replaces the deprecated `rmdir({ recursive: true })`. It removes files and directories recursively.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function cleanDirectory(dirPath) {
  try {
    await fs.rm(dirPath, { recursive: true, force: true });
    console.log('Removed:', dirPath);
  } catch (err) {
    console.error('Failed to remove:', err.message);
  }
}

// { force: true } prevents ENOENT if the path doesn't exist
cleanDirectory('/tmp/build-output');
```

### Understanding the `force` Option

| Options                              | Path exists    | Path missing   |
|--------------------------------------|---------------|----------------|
| `{ recursive: true }`               | Removes all   | Throws ENOENT  |
| `{ recursive: true, force: true }`  | Removes all   | No error       |
| `{ force: true }` (no recursive)    | Removes file  | No error       |

```javascript
'use strict';

const fs = require('node:fs');

// Safe cleanup — never throws, even if the path doesn't exist
fs.rmSync('/tmp/maybe-exists', { recursive: true, force: true });
```

---

## Renaming and Moving — `fs.rename()`

`rename` moves a file or directory from one path to another. On most Unix systems this is atomic within the same filesystem.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function moveDirectory(from, to) {
  try {
    await fs.rename(from, to);
    console.log(`Moved ${from} → ${to}`);
  } catch (err) {
    if (err.code === 'EXDEV') {
      console.error('Cannot rename across filesystems — use copy + delete');
    } else if (err.code === 'ENOENT') {
      console.error('Source path does not exist:', from);
    } else {
      throw err;
    }
  }
}

moveDirectory('/tmp/old-project', '/tmp/new-project');
```

### The Cross-Device Trap — `EXDEV`

`rename` cannot move files across filesystem boundaries (e.g., from `/tmp` to `/mnt/usb`). When this happens, you must copy the data and then delete the original.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function safeMove(from, to) {
  try {
    await fs.rename(from, to);
  } catch (err) {
    if (err.code === 'EXDEV') {
      // Cross-device: copy then remove
      await fs.cp(from, to, { recursive: true });
      await fs.rm(from, { recursive: true, force: true });
      console.log('Cross-device move complete');
    } else {
      throw err;
    }
  }
}
```

---

## Copying Directories — `fs.cp()` (Node 16.7+)

`fs.cp()` copies files and directories recursively. Before this API existed, you had to walk the directory tree manually.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function backupDirectory(source, destination) {
  try {
    await fs.cp(source, destination, {
      recursive: true,         // Copy directories recursively
      force: true,             // Overwrite existing files
      preserveTimestamps: true // Keep original mtime/atime
    });
    console.log('Backup complete');
  } catch (err) {
    console.error('Backup failed:', err.message);
  }
}

backupDirectory('/tmp/project', '/tmp/project-backup');
```

### `cp()` Options

| Option               | Default | Purpose                                           |
|----------------------|---------|---------------------------------------------------|
| `recursive`          | `false` | Copy subdirectories and their contents            |
| `force`              | `true`  | Overwrite existing destination files              |
| `preserveTimestamps` | `false` | Keep original `mtime` and `atime`                 |
| `errorOnExist`       | `false` | Throw if destination already exists               |
| `filter`             | —       | Function `(src, dest) => boolean` to skip entries |
| `dereference`        | `false` | Follow symlinks (copy their targets)              |

### Selective Copy with `filter`

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

async function copySourceOnly(source, destination) {
  await fs.cp(source, destination, {
    recursive: true,
    filter: (src) => {
      const basename = path.basename(src);
      // Skip node_modules, .git, and dotfiles
      if (basename === 'node_modules') return false;
      if (basename === '.git') return false;
      if (basename.startsWith('.') && basename !== '.') return false;
      return true;
    }
  });
  console.log('Filtered copy complete');
}

copySourceOnly('/tmp/my-project', '/tmp/my-project-clean');
```

---

## Temporary Directories — `fs.mkdtemp()`

`mkdtemp` creates a unique temporary directory by appending six random characters to a prefix. This is essential for test isolation and safe scratch space.

```javascript
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// The prefix MUST end with a path separator for proper placement
const prefix = path.join(os.tmpdir(), 'my-app-');

const tmpDir = fs.mkdtempSync(prefix);
console.log(tmpDir);
// e.g., /tmp/my-app-A1b2C3
```

### Temp Directory Lifecycle Pattern

Create, use, then clean up — the complete lifecycle.

```javascript
'use strict';

const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');

async function withTempDir(prefix, fn) {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), prefix));

  try {
    return await fn(tmpDir);
  } finally {
    // Always clean up, even if fn throws
    await fs.rm(tmpDir, { recursive: true, force: true });
  }
}

// Usage: safe scratch space that always gets cleaned up
withTempDir('build-', async (dir) => {
  const outFile = path.join(dir, 'output.txt');
  await fs.writeFile(outFile, 'build artifacts here');

  const content = await fs.readFile(outFile, 'utf8');
  console.log('Temp file content:', content);
  console.log('Working in:', dir);

  return content;
}).then((result) => {
  console.log('Result:', result);
  // dir has been removed by now
}).catch(console.error);
```

---

## Recursive Directory Traversal — Building a Tree Walker

The recursive `readdir` option is convenient, but building your own walker gives you control over depth limits, error handling, and early termination.

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

async function* walkDirectory(dirPath, options = {}) {
  const { maxDepth = Infinity, followSymlinks = false } = options;

  async function* walk(currentPath, depth) {
    if (depth > maxDepth) return;

    let entries;
    try {
      entries = await fs.readdir(currentPath, { withFileTypes: true });
    } catch (err) {
      if (err.code === 'EACCES') {
        // Skip directories we can't read
        return;
      }
      throw err;
    }

    for (const entry of entries) {
      const fullPath = path.join(currentPath, entry.name);

      yield { path: fullPath, entry, depth };

      if (entry.isDirectory()) {
        yield* walk(fullPath, depth + 1);
      } else if (followSymlinks && entry.isSymbolicLink()) {
        // Check if symlink points to a directory
        try {
          const stat = await fs.stat(fullPath);
          if (stat.isDirectory()) {
            yield* walk(fullPath, depth + 1);
          }
        } catch {
          // Broken symlink — skip
        }
      }
    }
  }

  yield* walk(dirPath, 0);
}

// Usage
async function main() {
  let fileCount = 0;
  let dirCount = 0;
  let totalSize = 0;

  for await (const { path: filePath, entry } of walkDirectory('/tmp/my-app', { maxDepth: 5 })) {
    if (entry.isFile()) {
      fileCount++;
      const stat = await fs.stat(filePath);
      totalSize += stat.size;
    } else if (entry.isDirectory()) {
      dirCount++;
    }
  }

  console.log(`Files: ${fileCount}, Directories: ${dirCount}`);
  console.log(`Total size: ${(totalSize / 1024).toFixed(1)} KB`);
}

main().catch(console.error);
```

### ASCII Tree Printer

A practical variant that prints a directory tree like the Unix `tree` command.

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

async function printTree(dirPath, prefix = '', isLast = true) {
  const basename = path.basename(dirPath);
  const connector = isLast ? '--- ' : '|-- ';

  console.log(prefix + connector + basename);

  let entries;
  try {
    entries = await fs.readdir(dirPath, { withFileTypes: true });
  } catch {
    return;
  }

  // Sort: directories first, then files, alphabetically within each group
  entries.sort((a, b) => {
    if (a.isDirectory() && !b.isDirectory()) return -1;
    if (!a.isDirectory() && b.isDirectory()) return 1;
    return a.name.localeCompare(b.name);
  });

  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    const childPath = path.join(dirPath, entry.name);
    const last = i === entries.length - 1;
    const newPrefix = prefix + (isLast ? '    ' : '|   ');

    if (entry.isDirectory()) {
      await printTree(childPath, newPrefix, last);
    } else {
      const childConnector = last ? '--- ' : '|-- ';
      console.log(newPrefix + childConnector + entry.name);
    }
  }
}

printTree('/tmp/my-app').catch(console.error);
```

---

## Resolving Paths — `fs.realpath()`

`realpath` resolves a path to its absolute, canonical form, following all symlinks.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function resolveLink(targetPath) {
  try {
    const real = await fs.realpath(targetPath);
    console.log(`${targetPath} → ${real}`);
    return real;
  } catch (err) {
    if (err.code === 'ENOENT') {
      console.error('Path does not exist:', targetPath);
      return null;
    }
    throw err;
  }
}

// If /tmp/link -> /var/data, then:
// resolveLink('/tmp/link') logs: /tmp/link → /var/data
resolveLink('/tmp/link');
```

### Symlink Detection Pattern

Combine `lstat` (which does not follow symlinks) with `realpath` to detect and resolve symlinks.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function inspectPath(targetPath) {
  const lstat = await fs.lstat(targetPath);

  if (lstat.isSymbolicLink()) {
    const target = await fs.readlink(targetPath);
    const resolved = await fs.realpath(targetPath);
    console.log(`Symlink: ${targetPath} → ${target} (resolved: ${resolved})`);
  } else if (lstat.isDirectory()) {
    console.log(`Directory: ${targetPath}`);
  } else if (lstat.isFile()) {
    console.log(`File: ${targetPath} (${lstat.size} bytes)`);
  }
}
```

---

## Practical Pattern: Safe Project Scaffolding

A realistic example combining several directory operations: create a project structure, write initial files, handle existing directories gracefully.

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

async function scaffoldProject(rootDir, projectName) {
  const projectDir = path.join(rootDir, projectName);

  // Check if project already exists
  try {
    await fs.access(projectDir);
    throw new Error(`Project "${projectName}" already exists at ${projectDir}`);
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
    // ENOENT means it doesn't exist — good, we can proceed
  }

  // Define the directory structure
  const dirs = [
    'src',
    'src/routes',
    'src/middleware',
    'src/utils',
    'test',
    'test/unit',
    'test/integration',
    'config',
    'docs',
  ];

  // Create all directories
  for (const dir of dirs) {
    await fs.mkdir(path.join(projectDir, dir), { recursive: true });
  }

  // Write initial files
  const files = {
    'src/index.js': `'use strict';\n\nconsole.log('Hello from ${projectName}');\n`,
    'config/default.json': JSON.stringify({ port: 3000, env: 'development' }, null, 2) + '\n',
    '.gitignore': 'node_modules/\n.env\ncoverage/\ndist/\n',
  };

  for (const [filePath, content] of Object.entries(files)) {
    await fs.writeFile(path.join(projectDir, filePath), content, 'utf8');
  }

  // Verify the structure
  const allEntries = await fs.readdir(projectDir, { recursive: true, withFileTypes: true });
  const dirCount = allEntries.filter((e) => e.isDirectory()).length;
  const fileCount = allEntries.filter((e) => e.isFile()).length;

  console.log(`Scaffolded "${projectName}": ${dirCount} directories, ${fileCount} files`);
  return projectDir;
}

scaffoldProject('/tmp', 'my-new-app').catch(console.error);
```

---

## Practical Pattern: Safe Directory Cleanup

Remove a directory only if it matches certain safety criteria — preventing accidental deletion of important paths.

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

// Paths that should NEVER be deleted
const PROTECTED_PATHS = new Set(['/', '/home', '/etc', '/usr', '/var', '/tmp']);

async function safeCleanup(dirPath, options = {}) {
  const { dryRun = false, maxDepth = 10 } = options;
  const resolved = path.resolve(dirPath);

  // Safety check: refuse to delete protected paths
  if (PROTECTED_PATHS.has(resolved)) {
    throw new Error(`Refusing to delete protected path: ${resolved}`);
  }

  // Safety check: refuse to delete paths that are too shallow
  const segments = resolved.split(path.sep).filter(Boolean);
  if (segments.length < 2) {
    throw new Error(`Path too shallow to delete safely: ${resolved}`);
  }

  // Verify the path exists and is actually a directory
  const stat = await fs.stat(resolved);
  if (!stat.isDirectory()) {
    throw new Error(`Not a directory: ${resolved}`);
  }

  if (dryRun) {
    const entries = await fs.readdir(resolved, { recursive: true });
    console.log(`[DRY RUN] Would delete ${resolved} (${entries.length} entries)`);
    return;
  }

  await fs.rm(resolved, { recursive: true, force: true });
  console.log(`Deleted: ${resolved}`);
}

// safeCleanup('/tmp/build-output').catch(console.error);
// safeCleanup('/tmp/build-output', { dryRun: true }).catch(console.error);
```

---

## Key Takeaways

- Use `fs.mkdir()` with `{ recursive: true }` for idempotent directory creation — it never throws if the directory already exists and creates all intermediate directories in one call
- Prefer `readdir({ withFileTypes: true })` over plain `readdir` followed by `stat` calls — `Dirent` objects give you file-type information without extra system calls
- Use `fs.opendir()` with `for await...of` for directories with thousands of entries — it reads one entry at a time instead of loading the entire listing into memory
- Use `fs.rm({ recursive: true, force: true })` instead of the deprecated `rmdir({ recursive: true })` — and always add `force: true` when you want to tolerate missing paths
- `fs.mkdtemp()` creates collision-proof temporary directories — wrap it in a try/finally pattern to guarantee cleanup even when processing throws

---

## Next

Continue to [Lesson 06 — Watching Files & Directories](lesson-06-watching-files.md), where you will learn how to react to file system changes in real time using `fs.watch()`, handle the notorious duplicate-event problem, and build reliable watchers with debouncing.
