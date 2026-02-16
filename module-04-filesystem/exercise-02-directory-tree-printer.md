# E02: Directory Tree Printer

> Build the `tree` command in pure JavaScript. This exercise drills recursive directory traversal, symbolic link handling, and formatted output — the three pillars of filesystem navigation.

## Objective

Build a `tree.js` CLI tool that recursively walks a directory and prints its structure using box-drawing characters (`├──`, `└──`, `│`), just like the Unix `tree` command. Include file sizes, handle symlinks gracefully, and support depth limiting. This teaches you `fs.readdirSync` with `withFileTypes`, recursive algorithm design, and the difference between `stat` and `lstat`.

## Prerequisites

- Module 04, Lesson 01 (File Descriptors and Handles)
- Module 04, Lesson 04 (File Stats and Metadata)
- Module 04, Lesson 05 (Directory Operations)
- Module 04, Lesson 07 (Path Module)

## Instructions

1. **Create `tree.js`** with `'use strict';` and require `node:fs` and `node:path`.

2. **Parse CLI arguments.** Accept `node tree.js [directory] [--depth N] [--all] [--size]`.
   - `directory` defaults to `.` (current working directory).
   - `--depth N` limits recursion depth (default: unlimited).
   - `--all` shows hidden files (those starting with `.`).
   - `--size` appends file sizes.

3. **Implement `walkDir(dirPath, prefix, depth, options)`.** This is the recursive core:
   - Read directory entries with `fs.readdirSync(dirPath, { withFileTypes: true })`.
   - Sort entries: directories first, then files, both alphabetically.
   - Filter out hidden files unless `--all` is set.
   - For each entry, determine if it is the last item in the list.

4. **Print with box-drawing characters.** Use these connectors:
   - Last item: `└── filename`
   - Other items: `├── filename`
   - Continuation for children of non-last items: `│   `
   - Continuation for children of last items: `    ` (4 spaces)

   ```javascript
   const BRANCH  = '├── ';
   const LAST    = '└── ';
   const PIPE    = '│   ';
   const SPACE   = '    ';
   ```

5. **Handle symlinks.** Use `entry.isSymbolicLink()` from the `Dirent` object. When you find a symlink, read its target with `fs.readlinkSync()` and display it as `linkname -> target`. Do NOT follow symlinks into recursive traversal (prevents infinite loops).

6. **Append file sizes.** When `--size` is enabled, call `fs.statSync()` on each file and format the size in human-readable units (B, KB, MB, GB). Align sizes in a column using padding.

   ```javascript
   function formatSize(bytes) {
     if (bytes < 1024) return `${bytes} B`;
     if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
     if (bytes < 1073741824) return `${(bytes / 1048576).toFixed(1)} MB`;
     return `${(bytes / 1073741824).toFixed(1)} GB`;
   }
   ```

7. **Track statistics.** Count total directories and total files as you walk. Print a summary line at the end: `N directories, M files`.

8. **Respect depth limits.** When `depth` reaches 0, stop recursing into subdirectories. Still list the directory entry itself but do not expand its contents.

9. **Handle permission errors.** Wrap `readdirSync` in try/catch. If you get `EACCES` (permission denied), print the directory name with `[Permission denied]` and continue.

10. **Test against real `tree` output.** Run your tool and the system `tree` command on the same directory. Compare the output. Fix any formatting differences.

## Break-Then-Harden Challenge

### Scenario 1 — Symlink Loop
Create a circular symlink: `mkdir -p /tmp/treetest/a && ln -s /tmp/treetest /tmp/treetest/a/loop`. Run your tree tool without symlink protection. Observe infinite recursion and stack overflow. Fix by never recursing into symlinks — display them as `name -> target` and move on.

### Scenario 2 — Giant Directory
Run your tree on `/usr` or `/node_modules` of a large project. Observe it takes forever. Fix by adding the `--depth` limit. Also add a `--max-files N` flag that stops after printing N entries and shows `... and M more entries`.

### Scenario 3 — Special Characters in Filenames
Create files with spaces, unicode, and control characters in their names: `touch "/tmp/treetest/hello world.txt"` and `touch $'/tmp/treetest/line\nbreak.txt'`. Verify your tool prints them correctly without breaking the tree structure. Fix by quoting filenames that contain spaces or special characters.

## Expected Output

```
$ node tree.js ./myproject --size
myproject
├── lib
│   ├── config.js            1.2 KB
│   ├── helpers.js           856 B
│   └── utils.js             2.3 KB
├── test
│   └── utils.test.js        1.1 KB
├── node_modules -> ../shared/node_modules
├── .gitignore               45 B
├── package.json              512 B
└── README.md                 3.4 KB

2 directories, 6 files, 1 symlink

$ node tree.js ./myproject --depth 1
myproject
├── lib
├── test
├── node_modules -> ../shared/node_modules
├── .gitignore
├── package.json
└── README.md

2 directories, 4 files, 1 symlink

$ node tree.js /root
/root [Permission denied]

0 directories, 0 files
```

## Implementation Guidance

Here is a skeleton for the recursive walker:

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const BRANCH = '\u251C\u2500\u2500 ';  // ├──
const LAST   = '\u2514\u2500\u2500 ';  // └──
const PIPE   = '\u2502   ';            // │
const SPACE  = '    ';

const stats = { dirs: 0, files: 0, symlinks: 0 };

function walkDir(dirPath, prefix, depth, options) {
  let entries;
  try {
    entries = fs.readdirSync(dirPath, { withFileTypes: true });
  } catch (err) {
    if (err.code === 'EACCES') {
      console.log(prefix + '[Permission denied]');
      return;
    }
    throw err;
  }

  // Filter hidden files unless --all
  if (!options.all) {
    entries = entries.filter(e => !e.name.startsWith('.'));
  }

  // Sort: directories first, then alphabetical
  entries.sort((a, b) => {
    const aDir = a.isDirectory() ? 0 : 1;
    const bDir = b.isDirectory() ? 0 : 1;
    return aDir - bDir || a.name.localeCompare(b.name);
  });

  entries.forEach((entry, index) => {
    const isLast = index === entries.length - 1;
    const connector = isLast ? LAST : BRANCH;
    const childPrefix = prefix + (isLast ? SPACE : PIPE);
    const fullPath = path.join(dirPath, entry.name);

    // TODO: Print entry with connector
    // TODO: If directory and depth > 0, recurse with childPrefix
    // TODO: If symlink, show target
    // TODO: If --size, append file size
  });
}
```

## Bonus

1. **Add `--json` output mode.** Instead of box-drawing characters, output the tree as a JSON object with nested `{ name, type, size, children }` structure. This is useful for programmatic consumption.

2. **Add glob filtering.** Add a `--pattern "*.js"` flag that only shows files matching the glob pattern. Directories are always shown if they contain matching files (pruned tree).

3. **Add color output.** Directories in blue (`\x1b[34m`), symlinks in cyan (`\x1b[36m`), executables in green (`\x1b[32m`). Check the executable bit with `stat.mode & 0o111`.

## Hints

1. `fs.readdirSync(dir, { withFileTypes: true })` returns `Dirent` objects with `.isFile()`, `.isDirectory()`, and `.isSymbolicLink()` methods — much faster than calling `statSync` on every entry.

2. The `prefix` parameter accumulates as you recurse: the parent's prefix plus either `PIPE` or `SPACE` depending on whether the parent was the last entry in its directory.

3. Sort entries with: `entries.sort((a, b) => { const aDir = a.isDirectory() ? 0 : 1; const bDir = b.isDirectory() ? 0 : 1; return aDir - bDir || a.name.localeCompare(b.name); });`

4. `path.join(dirPath, entry.name)` gives you the full path for `statSync` calls. Never concatenate paths with string `+` and `/`.

5. To check if an entry is the last one: `const isLast = (index === entries.length - 1);`. Use this to choose between `BRANCH`/`LAST` and `PIPE`/`SPACE`.
