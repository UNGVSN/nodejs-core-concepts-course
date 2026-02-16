# Module 04 — File System: Production Decisions

> Every file system call hides a trade-off. This document captures the decisions that trip up teams in production and the reasoning behind each recommendation.

---

## Decision 1: Sync vs Async vs Promises API

**Context:**
Node.js `node:fs` exposes three flavors of every operation: synchronous (`readFileSync`), callback-based (`readFile`), and Promise-based (`fs.promises.readFile`). New developers often reach for sync because the code reads top-to-bottom. Production servers pay the price.

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| Sync (`readFileSync`) | Simple control flow, no callbacks | Blocks the event loop — one slow disk read stalls every connection |
| Callback (`readFile`) | Non-blocking, available since Node.js v0.x | Callback nesting, error handling scattered across callbacks |
| Promises (`fs.promises.readFile`) | Non-blocking, clean `async/await` flow, composable | Slightly more memory per operation (Promise object allocation) |

**Recommendation:**
Use `fs.promises` with `async/await` for all server-side code. Reserve sync methods strictly for startup-time tasks (loading config, reading certs) where blocking is acceptable because no requests are being served yet. Never use sync in a request handler.

---

## Decision 2: `fs.watch` Reliability Across Platforms

**Context:**
`fs.watch` delegates to the OS kernel's native file-watching API: `inotify` on Linux, `FSEvents` on macOS, `ReadDirectoryChangesW` on Windows. Each behaves differently. Events may fire twice, filenames may arrive as `null`, and recursive watching is not supported everywhere.

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| `fs.watch` (native) | Low CPU usage, real-time on supported platforms | Inconsistent across OSes, duplicate events, `filename` can be null on Linux |
| `fs.watchFile` (polling) | Consistent behavior everywhere | Polls on an interval (default 5007ms), high CPU with many files |
| Hybrid (watch + debounce + fallback) | Best of both worlds | More code to maintain, must test on every target platform |

**Recommendation:**
Use `fs.watch` with a debounce timer (100-300ms) to collapse duplicate events. Always handle the case where `filename` is `null` by falling back to a full directory scan. For production file watchers that must be cross-platform reliable, test on every target OS in CI. If you only need to detect "something changed" (not which file), `fs.watch` on a directory is sufficient.

---

## Decision 3: `readdir` vs `opendir` for Large Directories

**Context:**
`fs.readdir` reads all directory entries into memory at once as an array. For a directory with 100,000 files, that is 100,000 strings allocated before you process a single one. `fs.opendir` returns an async iterable `Dir` object that yields entries one at a time.

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| `readdir` | Simple API, returns full array | Entire listing in memory; O(n) memory for n entries |
| `readdir` with `withFileTypes: true` | Avoids separate `stat` calls per entry | Still allocates the full array |
| `opendir` (async iterable) | Constant memory regardless of directory size | Slightly more verbose code, requires `for await` loop |

**Recommendation:**
Use `readdir({ withFileTypes: true })` for directories you know are small (under ~10,000 entries). Switch to `opendir` when directory size is unknown or potentially large. The memory difference is negligible for small directories but dramatic for large ones — `readdir` on a 500,000-entry directory can consume 50-100MB of heap, while `opendir` stays under 1MB.

---

## Decision 4: `copyFile` Flags — Overwrite Behavior

**Context:**
`fs.copyFile(src, dest, flags)` accepts a `mode` parameter that controls behavior when the destination already exists. The default (`0`) silently overwrites. `fs.constants.COPYFILE_EXCL` fails if the destination exists. `fs.constants.COPYFILE_FICLONE` attempts a copy-on-write clone on file systems that support it (APFS, Btrfs, XFS).

**Trade-offs:**

| Flag | Pros | Cons |
|------|------|------|
| Default (overwrite) | Simple, idempotent | Silent data loss if destination was important |
| `COPYFILE_EXCL` | Prevents accidental overwrites | Requires explicit handling of "already exists" errors |
| `COPYFILE_FICLONE` | Near-instant on supported FS, saves disk space | Falls back to full copy silently on unsupported FS — no error, but no speed benefit |
| `COPYFILE_FICLONE_FORCE` | Guarantees CoW or fails | Breaks on ext4, NTFS, and most file systems |

**Recommendation:**
Use `COPYFILE_EXCL` when copying user-uploaded files or any operation where overwriting would lose data. Use `COPYFILE_FICLONE` (without FORCE) as the default for server-side file operations — you get the performance win on modern file systems and transparent fallback on older ones. Never use `COPYFILE_FICLONE_FORCE` in production unless you control the exact file system.

---

## Decision 5: `readFile` vs `createReadStream` — When to Buffer, When to Stream

**Context:**
`readFile` loads the entire file into a single Buffer in memory. `createReadStream` reads the file in chunks (default 64KB `highWaterMark`). For a 10MB file, `readFile` allocates 10MB; `createReadStream` allocates 64KB.

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| `readFile` | Simple API, entire content available at once | Memory proportional to file size; dangerous with user-controlled paths |
| `createReadStream` | Constant memory, handles files of any size | More complex code, must handle stream events or use `pipeline` |
| `readFile` with size check | Simple API with a safety valve | Extra `stat` call; still loads entire file into memory |

**Recommendation:**
Set a hard threshold: files under 1MB can use `readFile`; anything above should use `createReadStream`. For HTTP responses serving user-requested files, always stream — you cannot predict file sizes and one large request should not exhaust server memory. When you must use `readFile` (e.g., parsing a JSON config), always check the file size first with `stat` and reject files above your threshold.

---

## Decision 6: Choosing the Right Write Flag

**Context:**
`fs.writeFile` and `fs.open` accept flags that control how the file is opened: `'w'` (write, create or truncate), `'a'` (append, create if missing), `'r+'` (read-write, file must exist), and `'wx'` (write exclusive, fail if file exists). Choosing wrong leads to data loss or silent errors.

**Trade-offs:**

| Flag | Behavior | Risk |
|------|----------|------|
| `'w'` | Create or truncate | Destroys existing content without warning |
| `'a'` | Create or append | Safe for logs, but no way to "update in place" |
| `'r+'` | Read-write, no create | Fails if file does not exist — good for updates, bad for fresh writes |
| `'wx'` | Exclusive create | Fails if file exists — prevents accidental overwrites |

**Recommendation:**
Use `'wx'` for any operation where overwriting would be harmful (uploaded files, generated IDs). Use `'a'` for log files — it is append-only and safe with concurrent writers (on POSIX, appends under `PIPE_BUF` bytes are atomic). Use `'w'` only when truncation is the explicit intent (e.g., regenerating a cache file). For atomic updates to existing files, write to a temp file with `'wx'`, then `rename` — this is the pattern behind every reliable config writer, database journal, and log rotator.
