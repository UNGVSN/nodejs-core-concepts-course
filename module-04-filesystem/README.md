# Module 04 — File System

> Everything in Node.js eventually touches the file system. Whether you are reading configuration, writing logs, serving static assets, or watching for changes, `node:fs` and `node:path` are the modules you will reach for first. This module takes you from raw file descriptors all the way up to cross-platform path manipulation, with a sharp focus on the async-first patterns that keep your event loop healthy.

---

## Learning Objectives

- Understand file descriptors and the OS-level mechanics behind every file operation
- Read and write files using callbacks, Promises, and synchronous APIs — and know when each is appropriate
- Query file stats, permissions, and timestamps to make runtime decisions
- Traverse and manipulate directory trees efficiently, even with tens of thousands of entries
- Watch files and directories for changes while handling platform-specific quirks
- Build cross-platform file paths with `node:path` that work on Linux, macOS, and Windows

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| L01 | [File Descriptors & Handles](lesson-01-file-descriptors-handles.md) | What an fd is, `fs.open`, `fs.close`, the OS-level reality behind file operations |
| L02 | [Reading Files](lesson-02-reading-files.md) | `readFile`, `readFileSync`, `fs.promises.readFile`, `read` with fd, encoding options |
| L03 | [Writing Files](lesson-03-writing-files.md) | `writeFile`, `appendFile`, flags (`w`, `a`, `r+`, `wx`), atomic writes |
| L04 | [File Stats & Metadata](lesson-04-file-stats-metadata.md) | `stat`, `lstat`, `fstat`, `BigInt` stats, inode, permissions, timestamps |
| L05 | [Directory Operations](lesson-05-directory-operations.md) | `mkdir`, `readdir`, `rmdir`, recursive options, `opendir` for large directories |
| L06 | [Watching Files & Directories](lesson-06-watching-files.md) | `fs.watch`, `fs.watchFile`, polling vs native, platform differences, debouncing |
| L07 | [Path Module Deep Dive](lesson-07-path-module.md) | `path.join`, `path.resolve`, `path.parse`, `path.normalize`, cross-platform paths |

---

## Exercises

| # | Exercise | Description |
|---|----------|-------------|
| E01 | [File Copy Utility](exercise-01-file-copy-utility.md) | Build a `cp` clone — copy files preserving stats, handle large files, recursive directory copy |
| E02 | [Directory Tree Printer](exercise-02-directory-tree-printer.md) | Recursive directory walker that prints tree structure like the `tree` command |
| E03 | [File Watcher with Debounce](exercise-03-file-watcher-debounce.md) | Watch a directory for changes, debounce rapid events, log change type and filename |
| E04 | [Atomic File Writer](exercise-04-atomic-file-writer.md) | Write files atomically — write to temp, then rename — to prevent corruption during crashes |
| E05 | [Log File Rotator](exercise-05-log-file-rotator.md) | Rotate log files when they exceed a size threshold, keep N backups, compress old files |

---

## Progressive Project — Step 04: Static File Serving

In this step you add static file serving to the HTTP framework. By the end of Step 04, a request to `/styles/main.css` resolves to a real file on disk and arrives at the client with the correct `Content-Type` header.

**What you will build:**

- Map URL paths to file system paths under a configurable static root directory
- Read files with `fs.promises.readFile` (switching to `createReadStream` in Module 05)
- Detect MIME types from file extensions using a hand-built extension map — no npm
- Set `Content-Type` and `Content-Length` response headers
- Return `404 Not Found` with a clean error body when the requested file does not exist
- Serve `index.html` automatically when the URL points to a directory
- Prevent path traversal attacks by normalizing and validating resolved paths against the static root

**Key code pattern:**

```javascript
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

const MIME_TYPES = {
  '.html': 'text/html',
  '.css':  'text/css',
  '.js':   'application/javascript',
  '.json': 'application/json',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.gif':  'image/gif',
  '.svg':  'image/svg+xml',
  '.txt':  'text/plain',
};

async function serveStatic(req, res, staticRoot) {
  const urlPath = req.url === '/' ? '/index.html' : req.url;
  const filePath = path.join(staticRoot, urlPath);

  // Guard against path traversal
  if (!filePath.startsWith(path.resolve(staticRoot))) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  try {
    const data = await fs.readFile(filePath);
    const ext = path.extname(filePath);
    res.writeHead(200, { 'Content-Type': MIME_TYPES[ext] || 'application/octet-stream' });
    res.end(data);
  } catch (err) {
    if (err.code === 'ENOENT') {
      res.writeHead(404);
      res.end('Not Found');
    } else {
      res.writeHead(500);
      res.end('Internal Server Error');
    }
  }
}
```

**Builds on:** Step 03 (Buffer-Based Body Parsing) — you already parse incoming request bodies; now you serve outgoing file responses.

**Leads to:** Step 05 (Streaming Response Support) — you will replace `readFile` with `createReadStream` to serve large files without loading them entirely into memory.

---

## Prerequisites

- Module 03 (Buffers & Binary Data) — you will work with file content as Buffers
- Module 01 (Architecture) — understanding async I/O and the event loop is essential for choosing between sync and async file APIs

---

## Key Concepts Introduced

- **File descriptor** — the integer handle the OS uses to track open files
- **`ENOENT`** — the error code for "file not found," the most common fs error you will handle
- **Atomic write** — write to temp file, then rename, so readers never see a half-written file
- **`fs.promises`** — the modern Promise-based API that replaces callback-style `fs` methods
- **Path traversal** — a security attack where `../` in a URL escapes the intended directory

---

## Next

Continue to [Module 05 — Streams](../module-05-streams/README.md) to learn how to process files and network data in chunks without loading everything into memory.
