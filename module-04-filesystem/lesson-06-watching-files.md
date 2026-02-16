# Module 04 / Lesson 06 — Watching Files & Directories

> Applications that reload configuration on change, development servers that restart on file edits, log processors that tail new entries — they all depend on file system watching. Node.js provides two APIs for this: `fs.watch()` (event-driven, efficient) and `fs.watchFile()` (polling, reliable). Neither is perfect. Understanding the platform-specific gotchas and building robust abstractions on top is what separates a watcher that works in demo from one that works in production.

## Learning Objectives

- Use `fs.watch()` to monitor files and directories for changes using OS-native events
- Understand why `fs.watch()` emits duplicate events and how debouncing solves the problem
- Use `fs.watchFile()` as a polling-based fallback and know when it is the better choice
- Cancel watchers using `AbortController` and the `signal` option
- Build practical patterns: auto-reloading config, debounced development watcher, and log file tailing

---

## `fs.watch()` — The Primary Watcher

`fs.watch()` uses the operating system's native file-watching mechanism: `inotify` on Linux, `FSEvents` on macOS, and `ReadDirectoryChangesW` on Windows. This makes it efficient — the OS notifies Node.js instead of Node.js polling the file system.

```javascript
'use strict';

const fs = require('node:fs');

const watcher = fs.watch('/tmp/config.json', (eventType, filename) => {
  console.log(`Event: ${eventType}, File: ${filename}`);
});

// eventType is either 'rename' or 'change'
// filename may be null on some platforms (Linux without inotify)

watcher.on('error', (err) => {
  console.error('Watcher error:', err.message);
});

// To stop watching:
// watcher.close();
```

### Event Types

`fs.watch()` emits only two event types, which can be confusing:

| Event Type  | Meaning                                              |
|-------------|------------------------------------------------------|
| `'change'`  | The file's content was modified                      |
| `'rename'`  | The file was created, deleted, or renamed            |

The `'rename'` event is overloaded — it fires for creation, deletion, and actual renames. You cannot distinguish between these from the event alone.

```javascript
'use strict';

const fs = require('node:fs');

// Watch a directory — fires for any change inside it
const watcher = fs.watch('/tmp/watched-dir', (eventType, filename) => {
  if (eventType === 'rename') {
    // Could be: file created, file deleted, or file renamed
    // Check if the file exists to determine which
    const fullPath = `/tmp/watched-dir/${filename}`;
    try {
      fs.accessSync(fullPath);
      console.log(`Created or renamed: ${filename}`);
    } catch {
      console.log(`Deleted: ${filename}`);
    }
  } else if (eventType === 'change') {
    console.log(`Modified: ${filename}`);
  }
});
```

### Watch Options

```javascript
'use strict';

const fs = require('node:fs');

const watcher = fs.watch('/tmp/project', {
  recursive: true,    // Watch subdirectories (macOS and Windows only)
  persistent: true,   // Keep the process running (default: true)
  encoding: 'utf8',   // Encoding for filename (default: 'utf8')
});

watcher.on('change', (eventType, filename) => {
  console.log(`[${eventType}] ${filename}`);
});
```

### Platform Support for `recursive`

| Platform | `recursive: true` Support | Underlying Mechanism          |
|----------|--------------------------|-------------------------------|
| macOS    | Yes                       | FSEvents (kernel-level)       |
| Windows  | Yes                       | ReadDirectoryChangesW         |
| Linux    | Node 19+ only             | inotify (one watch per dir)   |

On older Linux versions without recursive support, you must create a watcher for each subdirectory manually.

---

## The Duplicate Event Problem

This is the single most common complaint about `fs.watch()`. When you save a file in most editors, the watcher fires two or more events because editors typically:

1. Write to a temporary file
2. Rename the temporary file to the target name
3. Or: truncate the file, then write new content

```javascript
'use strict';

const fs = require('node:fs');

// This will fire multiple times for a single "save" operation
fs.watch('/tmp/config.json', (eventType, filename) => {
  console.log(`${Date.now()} - ${eventType}: ${filename}`);
});

// Saving config.json in VS Code might produce:
// 1708000001234 - change: config.json
// 1708000001235 - change: config.json
// 1708000001236 - rename: config.json
```

### Solving Duplicates with Debouncing

Debouncing collapses multiple rapid events into a single callback after a quiet period.

```javascript
'use strict';

const fs = require('node:fs');

function debounce(fn, delayMs) {
  let timer = null;
  return function (...args) {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      fn(...args);
    }, delayMs);
  };
}

const onChange = debounce((eventType, filename) => {
  console.log(`File changed: ${filename} (${eventType})`);
  // Your actual handler logic here
}, 100); // 100ms debounce window

const watcher = fs.watch('/tmp/config.json', onChange);
```

### Per-File Debouncing for Directory Watchers

When watching a directory, you need to debounce per file — otherwise a change to `a.txt` could suppress the event for `b.txt`.

```javascript
'use strict';

const fs = require('node:fs');

function createPerFileDebouncer(handler, delayMs) {
  const timers = new Map();

  return function (eventType, filename) {
    if (!filename) return;

    if (timers.has(filename)) {
      clearTimeout(timers.get(filename));
    }

    timers.set(
      filename,
      setTimeout(() => {
        timers.delete(filename);
        handler(eventType, filename);
      }, delayMs)
    );
  };
}

const onFileChange = createPerFileDebouncer((eventType, filename) => {
  console.log(`[${new Date().toISOString()}] ${eventType}: ${filename}`);
}, 100);

const watcher = fs.watch('/tmp/project/src', { recursive: true }, onFileChange);
```

---

## `fs.watchFile()` — Polling-Based Fallback

`fs.watchFile()` uses stat polling — it calls `fs.stat()` at a regular interval and compares the results. It is less efficient than `fs.watch()` but more reliable on network file systems (NFS, SMB) where OS-level notifications do not work.

```javascript
'use strict';

const fs = require('node:fs');

fs.watchFile('/tmp/config.json', { interval: 1000 }, (current, previous) => {
  // current and previous are fs.Stats objects
  if (current.mtime > previous.mtime) {
    console.log('File was modified');
    console.log('Previous mtime:', previous.mtime);
    console.log('Current mtime:', current.mtime);
    console.log('Current size:', current.size);
  }
});

// To stop polling:
// fs.unwatchFile('/tmp/config.json');
```

### `watchFile` Options

| Option        | Default | Purpose                                      |
|---------------|---------|----------------------------------------------|
| `persistent`  | `true`  | Keep process running while watching          |
| `interval`    | `5007`  | Polling interval in milliseconds             |
| `bigint`      | `false` | Use BigInt for stat values                   |

### Detecting File Deletion with `watchFile`

```javascript
'use strict';

const fs = require('node:fs');

fs.watchFile('/tmp/important.dat', (current, previous) => {
  if (current.nlink === 0) {
    // File has been deleted (hard link count dropped to zero)
    console.log('File was deleted!');
    fs.unwatchFile('/tmp/important.dat');
  } else if (current.mtime > previous.mtime) {
    console.log('File was modified');
  }
});
```

### `watch()` vs `watchFile()` — Decision Matrix

| Criteria                        | `fs.watch()`       | `fs.watchFile()`    |
|---------------------------------|--------------------|---------------------|
| Efficiency                      | High (OS events)   | Low (stat polling)  |
| Network filesystems (NFS/SMB)   | Unreliable         | Works               |
| Directory watching              | Yes                | No (files only)     |
| Duplicate events                | Common             | No                  |
| Cross-platform consistency      | Inconsistent       | Consistent          |
| Latency                         | Near-instant       | Up to `interval` ms |

---

## Cancellation with `AbortController`

Node.js 16+ supports `AbortController` with `fs.watch()`, giving you clean cancellation without keeping a reference to the watcher.

```javascript
'use strict';

const fs = require('node:fs');

const ac = new AbortController();

const watcher = fs.watch('/tmp/config.json', { signal: ac.signal }, (eventType, filename) => {
  console.log(`${eventType}: ${filename}`);
});

watcher.on('error', (err) => {
  if (err.name === 'AbortError') {
    console.log('Watcher was cancelled');
  } else {
    console.error('Watcher error:', err.message);
  }
});

// Cancel the watcher after 30 seconds
setTimeout(() => {
  ac.abort();
  console.log('Watcher cancelled');
}, 30_000);
```

### Watching with a Timeout

```javascript
'use strict';

const fs = require('node:fs');

function watchWithTimeout(filePath, timeoutMs, handler) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);

  const watcher = fs.watch(filePath, { signal: ac.signal }, (eventType, filename) => {
    handler(eventType, filename);
  });

  watcher.on('error', (err) => {
    if (err.name !== 'AbortError') {
      console.error('Watch error:', err.message);
    }
  });

  watcher.on('close', () => {
    clearTimeout(timer);
  });

  // Return an abort function for manual cancellation
  return () => {
    clearTimeout(timer);
    ac.abort();
  };
}

const cancel = watchWithTimeout('/tmp/config.json', 60_000, (eventType, filename) => {
  console.log(`Change detected: ${filename}`);
});

// Cancel early if needed:
// cancel();
```

---

## `fs.promises.watch()` — Async Iterable Interface

Node 18.11+ provides an async iterable version of `watch()` that integrates with `for await...of`.

```javascript
'use strict';

const fs = require('node:fs/promises');

async function watchForChanges(dirPath) {
  const ac = new AbortController();

  // Stop after 60 seconds
  setTimeout(() => ac.abort(), 60_000);

  try {
    const watcher = fs.watch(dirPath, { signal: ac.signal });

    for await (const event of watcher) {
      console.log(`Event: ${event.eventType}, File: ${event.filename}`);
    }
  } catch (err) {
    if (err.name === 'AbortError') {
      console.log('Watch period ended');
    } else {
      throw err;
    }
  }
}

watchForChanges('/tmp/project').catch(console.error);
```

### Watching Until a Specific File Appears

A practical pattern: wait for a file to be created, then stop watching.

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

async function waitForFile(dirPath, targetFilename, timeoutMs = 30_000) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);

  try {
    const watcher = fs.watch(dirPath, { signal: ac.signal });

    for await (const event of watcher) {
      if (event.filename === targetFilename && event.eventType === 'rename') {
        // Verify the file actually exists (rename fires on delete too)
        try {
          await fs.access(path.join(dirPath, targetFilename));
          clearTimeout(timer);
          return true; // File appeared
        } catch {
          // File was deleted, keep waiting
        }
      }
    }
  } catch (err) {
    if (err.name === 'AbortError') {
      return false; // Timed out
    }
    throw err;
  } finally {
    clearTimeout(timer);
  }

  return false;
}

waitForFile('/tmp/uploads', 'report.pdf', 10_000)
  .then((found) => console.log(found ? 'File arrived' : 'Timed out'))
  .catch(console.error);
```

---

## Practical Pattern: Auto-Reloading Configuration

Watch a config file and reload it when it changes, with debouncing and validation.

```javascript
'use strict';

const fs = require('node:fs');
const fsPromises = require('node:fs/promises');
const path = require('node:path');

class ConfigWatcher {
  constructor(configPath) {
    this.configPath = path.resolve(configPath);
    this.config = null;
    this.watcher = null;
    this.debounceTimer = null;
    this.listeners = [];
  }

  async start() {
    // Load initial config
    await this._reload();

    // Start watching
    this.watcher = fs.watch(this.configPath, (eventType) => {
      if (eventType === 'change') {
        this._debouncedReload();
      }
    });

    this.watcher.on('error', (err) => {
      console.error('Config watcher error:', err.message);
    });

    console.log('Watching config:', this.configPath);
  }

  _debouncedReload() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => this._reload(), 200);
  }

  async _reload() {
    try {
      const raw = await fsPromises.readFile(this.configPath, 'utf8');
      const parsed = JSON.parse(raw);

      // Validate required fields
      if (typeof parsed !== 'object' || parsed === null) {
        console.error('Config must be a JSON object');
        return;
      }

      const previous = this.config;
      this.config = Object.freeze(parsed);

      if (previous !== null) {
        console.log('Config reloaded');
        this._notify(this.config, previous);
      }
    } catch (err) {
      if (err instanceof SyntaxError) {
        console.error('Invalid JSON in config file — keeping previous config');
      } else {
        console.error('Failed to reload config:', err.message);
      }
    }
  }

  onChange(listener) {
    this.listeners.push(listener);
  }

  _notify(current, previous) {
    for (const listener of this.listeners) {
      try {
        listener(current, previous);
      } catch (err) {
        console.error('Config change listener error:', err.message);
      }
    }
  }

  stop() {
    if (this.watcher) {
      this.watcher.close();
      this.watcher = null;
    }
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
  }

  get() {
    return this.config;
  }
}

// Usage:
// const configWatcher = new ConfigWatcher('./config.json');
// configWatcher.onChange((current, previous) => {
//   console.log('Port changed from', previous.port, 'to', current.port);
// });
// await configWatcher.start();
```

---

## Practical Pattern: Development File Watcher

A minimal dev server watcher that detects source file changes and triggers a rebuild.

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

function createDevWatcher(srcDir, options = {}) {
  const {
    extensions = ['.js', '.json', '.mjs'],
    debounceMs = 150,
    ignore = ['node_modules', '.git'],
    onRebuild = () => {},
  } = options;

  const timers = new Map();

  const watcher = fs.watch(srcDir, { recursive: true }, (eventType, filename) => {
    if (!filename) return;

    // Check extension
    const ext = path.extname(filename);
    if (!extensions.includes(ext)) return;

    // Check ignore patterns
    const parts = filename.split(path.sep);
    if (parts.some((part) => ignore.includes(part))) return;

    // Debounce per file
    if (timers.has(filename)) {
      clearTimeout(timers.get(filename));
    }

    timers.set(
      filename,
      setTimeout(() => {
        timers.delete(filename);
        console.log(`[${new Date().toLocaleTimeString()}] Changed: ${filename}`);
        onRebuild(filename, eventType);
      }, debounceMs)
    );
  });

  watcher.on('error', (err) => {
    console.error('Watcher error:', err.message);
  });

  console.log(`Watching ${srcDir} for changes...`);

  return {
    close() {
      watcher.close();
      for (const timer of timers.values()) {
        clearTimeout(timer);
      }
      timers.clear();
      console.log('Watcher closed');
    },
  };
}

// Usage:
// const watcher = createDevWatcher('./src', {
//   extensions: ['.js', '.json'],
//   onRebuild: (filename) => {
//     console.log(`Rebuilding due to change in ${filename}...`);
//     // Trigger your build process here
//   },
// });
//
// process.on('SIGINT', () => {
//   watcher.close();
//   process.exit(0);
// });
```

---

## Practical Pattern: Log File Tailing

Watch a log file and process new lines as they are appended — similar to `tail -f`.

```javascript
'use strict';

const fs = require('node:fs');

function tailFile(filePath, onLine) {
  let fileSize = 0;

  // Get initial file size
  try {
    const stats = fs.statSync(filePath);
    fileSize = stats.size;
  } catch {
    fileSize = 0;
  }

  const watcher = fs.watchFile(filePath, { interval: 500 }, (current, previous) => {
    if (current.size <= previous.size) {
      // File was truncated or rotated — reset position
      fileSize = 0;
    }

    if (current.size > fileSize) {
      // New data was appended
      const readSize = current.size - fileSize;
      const buf = Buffer.alloc(readSize);

      let fd;
      try {
        fd = fs.openSync(filePath, 'r');
        fs.readSync(fd, buf, 0, readSize, fileSize);
      } catch (err) {
        console.error('Read error:', err.message);
        return;
      } finally {
        if (fd !== undefined) fs.closeSync(fd);
      }

      fileSize = current.size;

      // Split into lines and emit each
      const text = buf.toString('utf8');
      const lines = text.split('\n');
      for (const line of lines) {
        if (line.length > 0) {
          onLine(line);
        }
      }
    }
  });

  return {
    stop() {
      fs.unwatchFile(filePath);
    },
  };
}

// Usage:
// const tail = tailFile('/var/log/app.log', (line) => {
//   console.log('New log:', line);
//   if (line.includes('ERROR')) {
//     console.log('*** ERROR DETECTED ***');
//   }
// });
//
// // Later: tail.stop();
```

---

## Common Mistakes and Pitfalls

### Mistake 1: Not Handling the `filename` Being `null`

On some Linux configurations, `fs.watch()` may not provide the filename. Always check.

```javascript
'use strict';

const fs = require('node:fs');

fs.watch('/tmp/data', (eventType, filename) => {
  if (filename === null) {
    console.log('Change detected but filename unavailable');
    return;
  }
  console.log(`${eventType}: ${filename}`);
});
```

### Mistake 2: Watching a File That Gets Replaced

Some editors (Vim, for example) delete the original file and write a new one. This breaks `fs.watch()` because the inode changes.

```javascript
'use strict';

const fs = require('node:fs');

function resilientWatch(filePath, handler) {
  let watcher;

  function startWatching() {
    try {
      watcher = fs.watch(filePath, (eventType, filename) => {
        if (eventType === 'rename') {
          // File might have been replaced — restart the watcher
          watcher.close();
          setTimeout(startWatching, 100);
        }
        handler(eventType, filename);
      });

      watcher.on('error', () => {
        setTimeout(startWatching, 1000);
      });
    } catch {
      // File doesn't exist yet — try again later
      setTimeout(startWatching, 1000);
    }
  }

  startWatching();

  return {
    close() {
      if (watcher) watcher.close();
    },
  };
}
```

### Mistake 3: Forgetting to Close Watchers

Open watchers keep the Node.js process alive (when `persistent: true`, the default). Always close them when you are done.

```javascript
'use strict';

const fs = require('node:fs');

// BAD — this watcher keeps the process alive forever
// fs.watch('/tmp/data', () => {});

// GOOD — close on shutdown
const watcher = fs.watch('/tmp/data', () => {});

process.on('SIGINT', () => {
  watcher.close();
  process.exit(0);
});

process.on('SIGTERM', () => {
  watcher.close();
  process.exit(0);
});
```

---

## Key Takeaways

- `fs.watch()` uses OS-native mechanisms (`inotify`, `FSEvents`, `ReadDirectoryChangesW`) and is efficient, but it fires duplicate events and behaves differently across platforms
- Always debounce `fs.watch()` events — most editors trigger two to three events per save, and a 100-200ms debounce window collapses them into one
- `fs.watchFile()` uses stat polling and is slower but reliable on network file systems (NFS, SMB) where OS-level notifications do not work
- Use `AbortController` with `fs.watch({ signal })` for clean cancellation instead of keeping watcher references and calling `.close()` manually
- When watching files edited by Vim or similar editors that replace files (delete + create), re-establish the watcher on `'rename'` events to avoid watching a stale inode

---

## Next

Continue to [Lesson 07 — Path Module Deep Dive](lesson-07-path-module.md), where you will master cross-platform path manipulation, learn why string concatenation breaks on Windows, and build path traversal prevention for secure static file serving.
