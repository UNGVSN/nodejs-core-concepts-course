# Module 04 / Lesson 04 — File Stats & Metadata

> Every file on disk carries invisible metadata alongside its content: when it was created, who owns it, how large it is, what permissions it has, and whether it is a file, directory, symlink, or something stranger. The `fs.stat()` family of methods exposes all of this through the `Stats` object. Mastering file metadata is essential for building file watchers, cache invalidation, security checks, backup tools, and any system that needs to reason about files without reading their contents.

## Learning Objectives

- Retrieve file metadata using `fs.stat()`, `fs.statSync()`, and `fs.promises.stat()`
- Interpret the `Stats` object's properties: size, timestamps, mode, uid, gid, inode, and link count
- Use type-checking methods (`isFile()`, `isDirectory()`, `isSymbolicLink()`) to classify filesystem entries
- Check file accessibility with `fs.access()` and the `fs.constants` permission flags
- Modify file timestamps, ownership, and permissions programmatically

---

## Getting File Stats

The `fs.stat()` family returns a `Stats` object containing all metadata the operating system tracks about a file.

```javascript
'use strict';

const fs = require('node:fs');

// Synchronous
const stats = fs.statSync('/tmp');
console.log(stats);
// Stats {
//   dev: 16777220,
//   mode: 16877,
//   nlink: 12,
//   uid: 0,
//   gid: 0,
//   rdev: 0,
//   blksize: 4096,
//   ino: 1152921500312408142,
//   size: 384,
//   blocks: 0,
//   atimeMs: 1707900000000,
//   mtimeMs: 1707899000000,
//   ctimeMs: 1707899000000,
//   birthtimeMs: 1707800000000,
//   atime: 2024-02-14T...,
//   mtime: 2024-02-14T...,
//   ctime: 2024-02-14T...,
//   birthtime: 2024-02-13T...
// }
```

### Promise API

```javascript
'use strict';

const fs = require('node:fs/promises');

async function getFileInfo(filePath) {
  try {
    const stats = await fs.stat(filePath);
    return {
      size: stats.size,
      isFile: stats.isFile(),
      isDirectory: stats.isDirectory(),
      created: stats.birthtime,
      modified: stats.mtime,
    };
  } catch (err) {
    if (err.code === 'ENOENT') {
      return null; // File does not exist
    }
    throw err;
  }
}

getFileInfo('/tmp').then(console.log).catch(console.error);
```

---

## The Stats Object — Property Reference

### Key Properties in Action

```javascript
'use strict';

const fs = require('node:fs');

fs.writeFileSync('/tmp/stats-test.txt', 'Hello, world!\n');
const stats = fs.statSync('/tmp/stats-test.txt');

// Size and blocks
console.log('size:',    stats.size);    // 14 — file size in bytes
console.log('blocks:',  stats.blocks);  // 512-byte blocks allocated
console.log('blksize:', stats.blksize); // Preferred I/O block size (typically 4096)

// Identity (device + inode = unique file ID)
console.log('dev:',   stats.dev);   // Device number (filesystem identifier)
console.log('ino:',   stats.ino);   // Inode number (unique within filesystem)
console.log('nlink:', stats.nlink); // Hard link count

// Ownership and permissions
console.log('uid:',  stats.uid);  // Owner user ID
console.log('gid:',  stats.gid);  // Owner group ID
console.log('mode:', '0o' + (stats.mode & 0o777).toString(8)); // e.g., 0o644
```

### Complete Property Table

| Property | Type | Description |
|----------|------|-------------|
| `dev` | number | Device number containing the file |
| `ino` | number | Inode number (unique per filesystem) |
| `mode` | number | File type + permission bits |
| `nlink` | number | Hard link count |
| `uid` | number | Owner user ID |
| `gid` | number | Owner group ID |
| `rdev` | number | Device type (for device files) |
| `size` | number | File size in bytes |
| `blksize` | number | Preferred I/O block size |
| `blocks` | number | Number of 512-byte blocks allocated |
| `atimeMs` | number | Last access time (ms since epoch) |
| `mtimeMs` | number | Last content modification time (ms) |
| `ctimeMs` | number | Last metadata change time (ms) |
| `birthtimeMs` | number | Creation time (ms, macOS/Windows) |
| `atime` | Date | Last access time |
| `mtime` | Date | Last content modification time |
| `ctime` | Date | Last metadata change time |
| `birthtime` | Date | Creation time |

---

## Type-Checking Methods

The `Stats` object has methods to determine what kind of filesystem entity you are looking at.

```javascript
'use strict';

const fs = require('node:fs');

function classifyPath(p) {
  let stats;
  try {
    stats = fs.statSync(p);
  } catch (err) {
    return `Error: ${err.code}`;
  }

  if (stats.isFile())            return 'Regular file';
  if (stats.isDirectory())       return 'Directory';
  if (stats.isSymbolicLink())    return 'Symbolic link';  // Only with lstat
  if (stats.isBlockDevice())     return 'Block device';
  if (stats.isFIFO())            return 'FIFO (named pipe)';
  if (stats.isSocket())          return 'Unix socket';
  if (stats.isCharacterDevice()) return 'Character device';
  return 'Unknown';
}

console.log(classifyPath('/tmp'));                // Directory
console.log(classifyPath('/tmp/stats-test.txt')); // Regular file
console.log(classifyPath('/dev/null'));            // Character device
console.log(classifyPath('/nonexistent'));         // Error: ENOENT
```

### Type-Checking Summary

| Method | Returns true for |
|--------|-----------------|
| `stats.isFile()` | Regular files |
| `stats.isDirectory()` | Directories |
| `stats.isSymbolicLink()` | Symbolic links (only with `lstat`) |
| `stats.isBlockDevice()` | Block devices (`/dev/sda`) |
| `stats.isCharacterDevice()` | Character devices (`/dev/null`, `/dev/tty`) |
| `stats.isFIFO()` | Named pipes (FIFOs) |
| `stats.isSocket()` | Unix domain sockets |

---

## `lstat` — Stats Without Following Symlinks

`fs.stat()` follows symbolic links and returns stats for the target. `fs.lstat()` returns stats for the link itself.

```javascript
'use strict';

const fs = require('node:fs');

// Create a test file and a symlink to it
fs.writeFileSync('/tmp/real-file.txt', 'I am the real file\n');

try { fs.unlinkSync('/tmp/link-to-file.txt'); } catch {}
fs.symlinkSync('/tmp/real-file.txt', '/tmp/link-to-file.txt');

// stat follows the symlink — returns info about the target
const statResult = fs.statSync('/tmp/link-to-file.txt');
console.log('stat isFile:', statResult.isFile());           // true
console.log('stat isSymbolicLink:', statResult.isSymbolicLink()); // false!

// lstat does NOT follow the symlink — returns info about the link itself
const lstatResult = fs.lstatSync('/tmp/link-to-file.txt');
console.log('lstat isFile:', lstatResult.isFile());           // false
console.log('lstat isSymbolicLink:', lstatResult.isSymbolicLink()); // true

// Different sizes: the symlink is small (just a path), the file is larger
console.log('stat size (target):', statResult.size);     // 19 (content bytes)
console.log('lstat size (link):', lstatResult.size);     // length of target path

// Different inodes: the link and its target are different filesystem entities
console.log('stat ino (target):', statResult.ino);
console.log('lstat ino (link):', lstatResult.ino);
console.log('Different inodes:', statResult.ino !== lstatResult.ino); // true
```

---

## `fstat` — Stats for an Open File Descriptor

When you already have a file open, `fstat` avoids a path lookup. It is also the only way to stat a file you opened by descriptor number (e.g., inherited from a parent process).

```javascript
'use strict';

const fs = require('node:fs');

const fd = fs.openSync('/tmp/stats-test.txt', 'r');

try {
  const stats = fs.fstatSync(fd);
  console.log('Size:', stats.size);
  console.log('Is file:', stats.isFile());
  console.log('Modified:', stats.mtime.toISOString());
} finally {
  fs.closeSync(fd);
}

// Promise-based: FileHandle also has .stat()
// const handle = await fs.promises.open(filePath, 'r');
// const stats = await handle.stat();
// await handle.close();
```

---

## `fs.access()` — Checking Permissions

`fs.access()` tests whether the calling process has the specified permissions on a file. It uses permission flags from `fs.constants`.

```javascript
'use strict';

const fs = require('node:fs');

// Permission flags
const { F_OK, R_OK, W_OK, X_OK } = fs.constants;

// F_OK — file exists (visible)
// R_OK — file is readable
// W_OK — file is writable
// X_OK — file is executable

// Synchronous check
try {
  fs.accessSync('/tmp/stats-test.txt', R_OK | W_OK);
  console.log('File is readable and writable');
} catch (err) {
  console.log('File is NOT accessible:', err.code);
}

// Combine flags with bitwise OR
try {
  fs.accessSync('/tmp/stats-test.txt', R_OK | W_OK | X_OK);
  console.log('File is readable, writable, and executable');
} catch {
  console.log('File is NOT executable');
}
```

### Warning: TOCTOU Race Condition

Using `access()` to check before an operation creates a Time-Of-Check-Time-Of-Use (TOCTOU) race condition. Another process can change the file between your check and your operation. Prefer try-the-operation-and-handle-the-error:

```javascript
'use strict';

const fs = require('node:fs/promises');

// GOOD: Just try the operation and handle the error
async function readIfReadable(filePath) {
  try {
    return await fs.readFile(filePath, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT' || err.code === 'EACCES') return null;
    throw err;
  }
}
```

---

## Timestamps Explained

Every file has four timestamps. Understanding what triggers each one is essential for caching, backups, and file watchers.

```
Timestamp     Name          Updated When
──────────    ──────────    ─────────────────────────────────
birthtime     Creation      File is first created
mtime         Modified      File CONTENT is written to
atime         Accessed      File CONTENT is read from
ctime         Changed       File METADATA changes (chmod, chown, rename, link)
```

```javascript
'use strict';

const fs = require('node:fs');

fs.writeFileSync('/tmp/timestamps.txt', 'Initial content\n');
const s1 = fs.statSync('/tmp/timestamps.txt');
console.log('birthtime:', s1.birthtime.toISOString()); // When file was created
console.log('mtime:',     s1.mtime.toISOString());     // When content last changed
console.log('ctime:',     s1.ctime.toISOString());     // When metadata last changed
console.log('atime:',     s1.atime.toISOString());     // When content last read
```

### Millisecond-Precision Timestamps

The `*Ms` variants provide millisecond precision as numbers (milliseconds since Unix epoch). Use these when you need to compare timestamps arithmetically.

```javascript
'use strict';

const fs = require('node:fs');

const stats = fs.statSync('/tmp/timestamps.txt');

// Date objects (human-friendly)
console.log('mtime (Date):', stats.mtime);

// Millisecond timestamps (computation-friendly)
console.log('mtime (ms):',  stats.mtimeMs);

// Nanosecond precision (where supported)
console.log('mtime (ns):',  stats.mtimeNs); // BigInt on platforms that support it

// Computing file age
const ageMs = Date.now() - stats.mtimeMs;
const ageSeconds = Math.floor(ageMs / 1000);
const ageMinutes = Math.floor(ageSeconds / 60);
const ageHours = Math.floor(ageMinutes / 60);
console.log(`File age: ${ageHours}h ${ageMinutes % 60}m ${ageSeconds % 60}s`);
```

---

## Modifying Timestamps with `utimes`

`fs.utimes()` changes the `atime` and `mtime` of a file.

```javascript
'use strict';

const fs = require('node:fs');

// Set specific timestamps (atime, mtime)
const pastDate = new Date('2020-01-01T00:00:00Z');
fs.utimesSync('/tmp/timestamps.txt', pastDate, pastDate);

const stats = fs.statSync('/tmp/timestamps.txt');
console.log('atime:', stats.atime.toISOString()); // 2020-01-01T00:00:00.000Z
console.log('mtime:', stats.mtime.toISOString()); // 2020-01-01T00:00:00.000Z

// "Touch" a file — update timestamps to now
const now = new Date();
fs.utimesSync('/tmp/timestamps.txt', now, now);
```

---

## Changing Ownership and Permissions

### `chmod` — Changing Permissions

```javascript
'use strict';

const fs = require('node:fs');

// Make a file read-only for everyone
fs.chmodSync('/tmp/timestamps.txt', 0o444);
const stats1 = fs.statSync('/tmp/timestamps.txt');
console.log('Permissions:', '0o' + (stats1.mode & 0o777).toString(8)); // 0o444

// Restore read/write for owner
fs.chmodSync('/tmp/timestamps.txt', 0o644);
const stats2 = fs.statSync('/tmp/timestamps.txt');
console.log('Permissions:', '0o' + (stats2.mode & 0o777).toString(8)); // 0o644

// Promise-based
const fsp = require('node:fs/promises');
async function makeReadOnly(filePath) {
  await fsp.chmod(filePath, 0o444);
  console.log(`${filePath} is now read-only`);
}
```

### Understanding Permission Bits

```javascript
'use strict';

const fs = require('node:fs');

function modeToRwx(mode) {
  const perms = mode & 0o777;
  let str = '';
  for (const bit of [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]) {
    str += (perms & bit) ? 'rwxrwxrwx'['rwxrwxrwx'.length - str.length - (9 - str.length)] : '-';
  }
  // Simpler: map each trio of bits
  const chars = 'rwx';
  str = '';
  for (let i = 8; i >= 0; i--) {
    str += (perms & (1 << i)) ? chars[2 - (i % 3)] : '-';
  }
  return str;
}

const stats = fs.statSync('/tmp/timestamps.txt');
const perms = stats.mode & 0o777;
console.log('Octal:', '0o' + perms.toString(8)); // 0o644
// Manually: owner rw-, group r--, others r-- → rw-r--r--
```

### `chown` — Changing Ownership

`fs.chown(path, uid, gid, callback)` changes file ownership (requires root on most systems). Use `fs.lchown()` to change the symlink itself rather than its target. The Promise-based equivalent is `fs.promises.chown()`.

---

## Inodes Explained

An inode (index node) is the fundamental data structure that represents a file in Unix filesystems. The inode stores all metadata (size, permissions, timestamps, data block pointers) but NOT the filename. Filenames are stored in directory entries that point to inodes.

```
Directory Entry          Inode #12345              Disk Blocks
┌──────────────┐        ┌──────────────────┐      ┌─────────────┐
│ "hello.txt"  │───────▶│ size: 14         │─────▶│ Hello, world│
│ inode: 12345 │        │ mode: 0o644      │      │ !\n          │
└──────────────┘        │ uid: 501         │      └─────────────┘
                        │ mtime: ...       │
┌──────────────┐        │ nlink: 2         │
│ "greet.txt"  │───────▶│ blocks: [78, 79] │
│ inode: 12345 │        └──────────────────┘
└──────────────┘
  (hard link)
```

```javascript
'use strict';

const fs = require('node:fs');

// Every file has a unique inode number within its filesystem
const stats = fs.statSync('/tmp/stats-test.txt');
console.log('Inode:', stats.ino);

// Hard links share the same inode
fs.writeFileSync('/tmp/original.txt', 'Shared content\n');

try { fs.unlinkSync('/tmp/hardlink.txt'); } catch {}
fs.linkSync('/tmp/original.txt', '/tmp/hardlink.txt');

const s1 = fs.statSync('/tmp/original.txt');
const s2 = fs.statSync('/tmp/hardlink.txt');

console.log('Original inode:', s1.ino);
console.log('Hardlink inode:', s2.ino);
console.log('Same inode:', s1.ino === s2.ino); // true
console.log('Link count:', s1.nlink);          // 2 — two directory entries point here

// Deleting one name does not affect the other
fs.unlinkSync('/tmp/original.txt');
console.log('Hardlink still readable:', fs.readFileSync('/tmp/hardlink.txt', 'utf8'));
// Shared content

// Symlinks have their OWN inode
try { fs.unlinkSync('/tmp/symlink.txt'); } catch {}
fs.writeFileSync('/tmp/target.txt', 'Target content\n');
fs.symlinkSync('/tmp/target.txt', '/tmp/symlink.txt');

const targetStats = fs.statSync('/tmp/target.txt');
const symlinkStats = fs.lstatSync('/tmp/symlink.txt');
console.log('Target inode:', targetStats.ino);
console.log('Symlink inode:', symlinkStats.ino);
console.log('Different inodes:', targetStats.ino !== symlinkStats.ino); // true
```

---

## Practical Example: File Age Calculator

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

async function fileAge(filePath) {
  const stats = await fs.stat(filePath);
  const now = Date.now();

  const ageMs = now - stats.mtimeMs;
  const seconds = Math.floor(ageMs / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  return {
    path: path.resolve(filePath),
    size: stats.size,
    modified: stats.mtime,
    age: {
      days,
      hours: hours % 24,
      minutes: minutes % 60,
      seconds: seconds % 60,
      totalMs: ageMs,
    },
    stale: ageMs > 24 * 60 * 60 * 1000, // older than 24 hours
  };
}

// Usage
fileAge('/tmp/stats-test.txt')
  .then((info) => {
    console.log(`File: ${info.path}`);
    console.log(`Size: ${info.size} bytes`);
    console.log(`Modified: ${info.modified.toISOString()}`);
    console.log(`Age: ${info.age.days}d ${info.age.hours}h ${info.age.minutes}m`);
    console.log(`Stale (>24h): ${info.stale}`);
  })
  .catch(console.error);
```

---

## Practical Example: Permission Checker

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

function auditPermissions(dirPath) {
  const entries = fs.readdirSync(dirPath, { withFileTypes: true });
  const issues = [];

  for (const entry of entries) {
    if (!entry.isFile()) continue;

    const fullPath = path.join(dirPath, entry.name);
    const stats = fs.statSync(fullPath);
    const perms = stats.mode & 0o777;

    if (perms & 0o002) {
      issues.push({ file: fullPath, issue: 'World-writable', severity: 'HIGH' });
    }
    if (entry.name.match(/\.(key|pem|env|secret)$/) && (perms & 0o004)) {
      issues.push({ file: fullPath, issue: 'Sensitive file is world-readable', severity: 'CRITICAL' });
    }
  }

  return issues;
}

// Usage:
// const issues = auditPermissions('/etc');
// issues.forEach(i => console.log(`[${i.severity}] ${i.file}: ${i.issue}`));
```

---

## Practical Example: Duplicate File Finder by Inode

Hard links create multiple directory entries pointing to the same inode. Detect them by grouping files by `dev:ino`.

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

function findHardLinks(dirPath) {
  const entries = fs.readdirSync(dirPath, { withFileTypes: true });
  const inodeMap = new Map();

  for (const entry of entries) {
    if (!entry.isFile()) continue;
    const fullPath = path.join(dirPath, entry.name);
    const stats = fs.statSync(fullPath);

    if (stats.nlink > 1) {
      const key = `${stats.dev}:${stats.ino}`;
      if (!inodeMap.has(key)) inodeMap.set(key, []);
      inodeMap.get(key).push(fullPath);
    }
  }

  return [...inodeMap.values()].filter(paths => paths.length > 1);
}

// Usage:
// findHardLinks('/tmp').forEach(group => console.log('Linked:', group));
```

---

## Practical Example: Conditional Cache Invalidation

Use `mtime` to skip re-processing files that have not changed.

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

class FileCache {
  constructor() {
    this._cache = new Map(); // filePath -> { mtimeMs, data }
  }

  async get(filePath) {
    const absPath = path.resolve(filePath);
    const stats = await fs.stat(absPath);
    const cached = this._cache.get(absPath);

    if (cached && cached.mtimeMs === stats.mtimeMs) {
      return cached.data; // Cache hit — file unchanged
    }

    const data = await fs.readFile(absPath, 'utf8');
    this._cache.set(absPath, { mtimeMs: stats.mtimeMs, data });
    return data; // Cache miss — file read and cached
  }

  invalidate(filePath) {
    this._cache.delete(path.resolve(filePath));
  }
}

// Usage:
// const cache = new FileCache();
// const v1 = await cache.get('/tmp/config.json'); // reads from disk
// const v2 = await cache.get('/tmp/config.json'); // returns cached (if unchanged)
```

---

## `bigint` Option for High-Precision Stats

For nanosecond-precision timestamps or very large file sizes, pass `{ bigint: true }` to `stat`.

```javascript
'use strict';

const fs = require('node:fs');

const stats = fs.statSync('/tmp/stats-test.txt', { bigint: true });

console.log('size:', stats.size);           // BigInt: 14n
console.log('ino:', stats.ino);             // BigInt
console.log('mtimeMs:', stats.mtimeMs);     // BigInt (ms since epoch)
console.log('mtimeNs:', stats.mtimeNs);     // BigInt (ns since epoch)

// BigInt comparisons
const oneHourAgo = BigInt(Date.now() - 3600000) * 1000000n; // convert ms to ns
console.log('Modified in last hour:', stats.mtimeNs > oneHourAgo);
```

---

## Key Takeaways

- `fs.stat()` returns a `Stats` object with size, timestamps, permissions, ownership, inode number, and type-checking methods; use `fs.promises.stat()` in async code
- Use `stats.isFile()`, `stats.isDirectory()`, and `stats.isSymbolicLink()` (with `lstat`) to classify filesystem entries — never assume a path is a file without checking
- `fs.access()` with `fs.constants.R_OK`, `W_OK`, `X_OK`, and `F_OK` tests permissions, but prefer try-the-operation-and-handle-the-error over check-then-act to avoid TOCTOU race conditions
- Four timestamps track a file's lifecycle: `birthtime` (creation), `mtime` (content modification), `atime` (access), and `ctime` (metadata change); `mtime` is the most reliable and widely used for cache invalidation
- Inodes are the true identity of a file — filenames are just directory entries pointing to inodes; hard links share an inode, and `stats.nlink` tells you how many names point to the same file

---

## Next

Continue to [Lesson 05 — Directory Operations](lesson-05-directory-operations.md) where you will learn how to create, read, and remove directories — including recursive operations, `readdir` with file types, and the `opendir` API for memory-efficient traversal of large directories.
