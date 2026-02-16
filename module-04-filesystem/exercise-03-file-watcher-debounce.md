# E03: File Watcher with Debounce

> Watch a directory for changes and debounce the flood of duplicate events that `fs.watch()` fires. This exercise teaches you the realities of filesystem event APIs — they are noisy, platform-dependent, and require careful engineering to be useful.

## Objective

Build a `watcher.js` tool that monitors a directory for file creates, modifications, and deletions. Because `fs.watch()` fires multiple events for a single file save (sometimes 2-4 events within milliseconds), you must implement a debounce mechanism that collapses rapid-fire events on the same file into a single reported change. This is the exact same problem that every build tool (webpack, esbuild, nodemon) solves.

## Prerequisites

- Module 04, Lesson 04 (File Stats and Metadata)
- Module 04, Lesson 05 (Directory Operations)
- Module 04, Lesson 06 (Watching Files)
- Module 04, Lesson 07 (Path Module)

## Instructions

1. **Create `watcher.js`** with `'use strict';` and require `node:fs`, `node:path`, and `node:process`.

2. **Parse CLI arguments.** Accept `node watcher.js <directory> [--debounce N]` where N is the debounce window in milliseconds (default: 100ms).

3. **Take an initial snapshot.** Before starting the watcher, scan the directory and record every file's path and `mtimeMs` (modification time) in a `Map`. This is your baseline for detecting creates vs modifications vs deletions.

   ```javascript
   function snapshot(dir) {
     const files = new Map();
     for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
       if (entry.isFile()) {
         const fullPath = path.join(dir, entry.name);
         const stat = fs.statSync(fullPath);
         files.set(entry.name, stat.mtimeMs);
       }
     }
     return files;
   }
   ```

4. **Start `fs.watch()`** on the directory with `{ persistent: true }`. The callback receives `(eventType, filename)` where `eventType` is `'rename'` or `'change'`.

5. **Implement the debounce.** Maintain a `Map<filename, timeoutId>` for pending events. When an event fires:
   - If there is already a pending timeout for this filename, clear it with `clearTimeout()`.
   - Set a new timeout for the debounce window.
   - When the timeout fires, classify the event and report it.

   ```javascript
   const pending = new Map();

   function debounceEvent(filename) {
     if (pending.has(filename)) {
       clearTimeout(pending.get(filename));
     }
     pending.set(filename, setTimeout(() => {
       pending.delete(filename);
       classifyAndReport(filename);
     }, debounceMs));
   }
   ```

6. **Classify the event.** When the debounce timer fires, determine what happened:
   - **Created:** filename is NOT in the baseline snapshot but now exists on disk (`fs.existsSync()`).
   - **Modified:** filename IS in the baseline snapshot and still exists, but `mtimeMs` has changed.
   - **Deleted:** filename IS in the baseline snapshot but no longer exists on disk.
   - Update the baseline snapshot after classification.

7. **Format the output.** Print a timestamp, event type, and filename:

   ```
   [14:23:15.042] CREATED  index.js
   [14:23:18.901] MODIFIED config.json
   [14:23:22.330] DELETED  temp.txt
   ```

8. **Handle watcher errors.** Listen for the `'error'` event on the watcher. Common errors: `ENOSPC` (too many watchers on Linux), `ENOENT` (directory deleted). Print the error and exit gracefully.

9. **Add graceful shutdown.** Listen for `SIGINT` (Ctrl+C). Close the watcher with `watcher.close()`, print a summary (total events by type), and exit.

10. **Test the debounce.** Create a test script that writes to the same file 5 times in rapid succession (10ms apart). Verify that your watcher reports only 1 `MODIFIED` event, not 5.

    ```javascript
    // test-rapid-writes.js
    'use strict';
    const fs = require('node:fs');
    const target = './watched/test.txt';
    for (let i = 0; i < 5; i++) {
      setTimeout(() => fs.writeFileSync(target, `write ${i}\n`), i * 10);
    }
    ```

## Break-Then-Harden Challenge

### Scenario 1 — No Debounce
Remove the debounce logic entirely. Save a file in VS Code and observe 2-4 duplicate events printed (VS Code writes to temp file, renames, triggers multiple events). Restore the debounce. Experiment with windows of 50ms, 100ms, and 500ms to find the sweet spot.

### Scenario 2 — Rename vs Change Confusion
On macOS, `fs.watch()` reports `'rename'` for both file creation and deletion. On Linux, it reports `'rename'` for renames and `'change'` for modifications. Test on your platform and observe the inconsistency. Fix by never relying on `eventType` — always check the filesystem state (`existsSync` + `statSync`) to determine what actually happened.

### Scenario 3 — Watched Directory Deleted
While the watcher is running, delete the watched directory with `rm -rf`. Observe the unhandled error. Fix by catching `ENOENT` in the `'error'` handler and printing "Watched directory was deleted" before exiting.

## Expected Output

```
$ node watcher.js ./watched --debounce 100
Watching: ./watched (debounce: 100ms)
Baseline: 3 files

[14:23:15.042] CREATED  newfile.js
[14:23:18.901] MODIFIED config.json
[14:23:18.901] MODIFIED config.json    <-- without debounce, this would print 3x
[14:23:22.330] DELETED  temp.txt
[14:23:30.100] CREATED  data.csv

^C
--- Watcher Summary ---
  Created:  2
  Modified: 1
  Deleted:  1
  Total:    4
  Uptime:   15.1 seconds
```

## Implementation Guidance

Here is the graceful shutdown handler:

```javascript
const eventCounts = { created: 0, modified: 0, deleted: 0 };
const startTime = Date.now();

process.on('SIGINT', () => {
  watcher.close();
  const uptime = ((Date.now() - startTime) / 1000).toFixed(1);
  console.log('\n--- Watcher Summary ---');
  console.log(`  Created:  ${eventCounts.created}`);
  console.log(`  Modified: ${eventCounts.modified}`);
  console.log(`  Deleted:  ${eventCounts.deleted}`);
  console.log(`  Total:    ${eventCounts.created + eventCounts.modified + eventCounts.deleted}`);
  console.log(`  Uptime:   ${uptime} seconds`);
  process.exit(0);
});
```

## Bonus

1. **Add recursive watching.** Use `{ recursive: true }` on macOS/Windows (where supported) or manually walk subdirectories and create a watcher for each on Linux. Handle new subdirectories being created mid-watch.

2. **Add glob filtering.** Accept a `--filter "*.js"` flag that only reports changes to files matching the pattern. Use `path.extname()` or a simple glob matcher (no npm packages).

3. **Add a "command" mode.** Accept `--exec "node test.js"` that runs a shell command (via `require('node:child_process').execSync()`) every time a matching file changes. This is how `nodemon` works at its core.

## Hints

1. `fs.watch()` returns a `FSWatcher` object. Call `.close()` to stop watching. The object also emits `'error'` events.

2. `setTimeout` returns an opaque timeout ID. `clearTimeout(id)` cancels a pending timeout. This is the core of debouncing.

3. `fs.existsSync(filepath)` is the simplest way to check if a file still exists. It does not throw on missing files.

4. `new Date().toLocaleTimeString('en-US', { hour12: false, fractionalSecondDigits: 3 })` gives you a timestamp with milliseconds like `14:23:15.042`.

5. On Linux, `fs.watch()` uses `inotify` under the hood. Each watcher consumes a file descriptor. The system limit is in `/proc/sys/fs/inotify/max_user_watches` (default 8192). The `ENOSPC` error means you have hit this limit.
