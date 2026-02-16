# Module 08 / Lesson 01 — Unix Fundamentals for Node.js

> Node.js did not invent its process model — it inherited it from Unix. Before you can master `child_process`, `cluster`, or graceful shutdown, you need to understand the operating system primitives that make them possible: processes, file descriptors, standard streams, exit codes, and environment variables.

---

## Learning Objectives

- Explain what a Unix process is and how the OS manages it with a PID, UID, and memory space
- Describe the "everything is a file" philosophy and how file descriptors connect processes to I/O resources
- Identify stdin (fd 0), stdout (fd 1), and stderr (fd 2) and their roles in process communication
- Interpret exit codes and understand the convention of 0 for success and non-zero for failure
- Access environment variables from Node.js and understand how they propagate to child processes

---

## What Is a Process?

A process is the operating system's unit of execution. When you run `node app.js`, the OS creates a new process with its own:

- **PID** (Process ID) — a unique integer identifying the process
- **Memory space** — heap, stack, and code segments isolated from other processes
- **File descriptor table** — a map of integer handles pointing to open files, sockets, and pipes
- **Environment** — a set of key-value pairs inherited from the parent process

Every process has a parent. The first process on a Unix system (PID 1, traditionally `init` or `systemd`) spawns all others. When you open a terminal and type `node`, your shell (`bash`, `zsh`) forks a child process to run the Node.js binary.

```javascript
'use strict';

// Node.js exposes the current process's identity through the process global
console.log('PID:', process.pid);           // e.g., 42317
console.log('Parent PID:', process.ppid);   // e.g., 42100 (the shell)
console.log('User ID:', process.getuid());  // e.g., 501
console.log('Group ID:', process.getgid()); // e.g., 20
```

### Process Isolation

Each process gets its own virtual memory space. Process A cannot read or write the memory of Process B. This isolation is a security boundary — a crashed process does not corrupt its neighbors. It is also why inter-process communication (IPC) requires explicit mechanisms like pipes, sockets, or shared memory.

```javascript
'use strict';

// This variable exists only in THIS process's memory
let counter = 0;

// If we fork a child process later, the child gets a COPY
// Changing counter in the child has zero effect on the parent
setInterval(() => {
  counter += 1;
  console.log(`[PID ${process.pid}] counter = ${counter}`);
}, 1000);
```

---

## Everything Is a File

Unix's most powerful abstraction is: **everything is a file**. Regular files, directories, network sockets, pipes, terminals, and even devices are accessed through the same interface — file descriptors.

A **file descriptor** (fd) is a non-negative integer that acts as an index into the process's file descriptor table. When you open a file, the OS returns the lowest available fd. When you close it, that fd becomes available again.

```javascript
'use strict';

const fs = require('node:fs');

// Open a file — the OS assigns the next available fd
const fd = fs.openSync('/tmp/unix-demo.txt', 'w');
console.log('Assigned fd:', fd); // Likely 3 or higher (0, 1, 2 are taken)

// Write using the raw fd
fs.writeSync(fd, 'Hello from a file descriptor\n');

// Close when done — releases the fd back to the pool
fs.closeSync(fd);
```

### Why File Descriptors Matter

File descriptor leaks are a real production issue. Every open file, socket, or pipe consumes an fd. The OS imposes a per-process limit (commonly 1024 on older systems, 65536 on modern ones). If your Node.js server opens connections without closing them, it will eventually hit `EMFILE: too many open files` and refuse new connections.

```javascript
'use strict';

const { execSync } = require('node:child_process');

// Check the current fd limit on macOS/Linux
try {
  const limit = execSync('ulimit -n', { encoding: 'utf8' }).trim();
  console.log('File descriptor limit:', limit);
} catch {
  console.log('Could not read fd limit (Windows?)');
}
```

---

## Standard Streams: stdin, stdout, stderr

Every Unix process is born with three file descriptors already open:

| fd | Name   | Purpose                              | Node.js API        |
|----|--------|--------------------------------------|--------------------|
| 0  | stdin  | Read input from the user or a pipe   | `process.stdin`    |
| 1  | stdout | Write normal output                  | `process.stdout`   |
| 2  | stderr | Write error and diagnostic output    | `process.stderr`   |

These three streams are the foundation of Unix piping. When you write `cat file.txt | grep error | wc -l`, each `|` connects stdout of one process to stdin of the next.

### stdout vs stderr

Separating output into two streams is deliberate. Normal results go to stdout; diagnostics, progress, and errors go to stderr. This lets you redirect them independently:

```bash
# stdout goes to output.log, stderr goes to errors.log
node app.js > output.log 2> errors.log
```

In Node.js, `console.log()` writes to stdout and `console.error()` writes to stderr:

```javascript
'use strict';

// These go to stdout (fd 1)
console.log('Result: 42');
process.stdout.write('Also stdout\n');

// These go to stderr (fd 2)
console.error('Something went wrong');
process.stderr.write('Also stderr\n');
```

### Reading from stdin

`process.stdin` is a readable stream. When your process is connected to a terminal, it waits for keyboard input. When piped, it reads from the previous process's stdout.

```javascript
'use strict';

// Read all data from stdin, then process it
// Run: echo "hello world" | node this-file.js
const chunks = [];

process.stdin.on('data', (chunk) => {
  chunks.push(chunk);
});

process.stdin.on('end', () => {
  const input = Buffer.concat(chunks).toString('utf8');
  console.log('Received from stdin:', input.trim());
  console.log('Word count:', input.trim().split(/\s+/).length);
});
```

### Blocking vs Non-Blocking

An important subtlety: `process.stdout` and `process.stderr` behave differently depending on what they are connected to.

- **TTY (terminal):** Usually line-buffered, writes are asynchronous
- **Pipe or file:** Writes are synchronous (blocking) — this can stall the event loop if you write enormous amounts of data

```javascript
'use strict';

// Check what each stream is connected to
console.log('stdin  isTTY:', process.stdin.isTTY);   // true in terminal, undefined when piped
console.log('stdout isTTY:', process.stdout.isTTY);  // true in terminal, undefined when piped
console.log('stderr isTTY:', process.stderr.isTTY);  // true in terminal, undefined when piped
```

---

## Exit Codes

When a process terminates, it returns an **exit code** — an integer between 0 and 255 — to its parent. The universal convention is:

| Code | Meaning |
|------|---------|
| 0    | Success |
| 1    | General error |
| 2    | Misuse of shell command |
| 126  | Command not executable |
| 127  | Command not found |
| 128+N | Killed by signal N (e.g., 130 = SIGINT, 137 = SIGKILL, 143 = SIGTERM) |

Node.js exits with code 0 by default when the event loop drains. You can set the exit code explicitly:

```javascript
'use strict';

// Method 1: Set the code and let the process exit naturally
process.exitCode = 1;

// Method 2: Force immediate exit (skips cleanup — use sparingly)
// process.exit(1);

// Method 3: Listen for the exit event
process.on('exit', (code) => {
  // This is your last chance to do synchronous work
  // Async operations will NOT complete here
  console.log('Exiting with code:', code);
});
```

### Why Exit Codes Matter

Exit codes are how shell scripts, CI/CD pipelines, and process managers decide what to do next. A non-zero exit code from `npm test` fails your build. A supervisor like `systemd` or `pm2` reads the exit code to decide whether to restart the process.

```javascript
'use strict';

const { execSync } = require('node:child_process');

try {
  // This will throw because 'nonexistent-command' does not exist
  execSync('nonexistent-command', { encoding: 'utf8' });
} catch (err) {
  console.log('Command failed with exit code:', err.status); // 127
  console.log('stderr:', err.stderr.trim());
}
```

---

## Environment Variables

Environment variables are key-value pairs passed from a parent process to its children. They are the standard Unix mechanism for configuration — database URLs, API keys, feature flags, log levels.

```javascript
'use strict';

// Read environment variables
console.log('PATH:', process.env.PATH);
console.log('HOME:', process.env.HOME);
console.log('NODE_ENV:', process.env.NODE_ENV || '(not set)');
console.log('SHELL:', process.env.SHELL);

// Count all environment variables
const envCount = Object.keys(process.env).length;
console.log(`Total environment variables: ${envCount}`);
```

### Setting Environment Variables

You can set environment variables before launching a process:

```bash
# Set for a single command
NODE_ENV=production node app.js

# Export for the entire shell session
export DATABASE_URL=postgres://localhost:5432/mydb
node app.js
```

From within Node.js, you can modify `process.env`, but these changes only affect the current process and any children it spawns afterward:

```javascript
'use strict';

// Modify process.env — affects this process and future children only
process.env.MY_CUSTOM_VAR = 'hello';
console.log(process.env.MY_CUSTOM_VAR); // 'hello'

// WARNING: All values are coerced to strings
process.env.PORT = 3000;
console.log(typeof process.env.PORT); // 'string', not 'number'
console.log(process.env.PORT);        // '3000'

// Deleting an environment variable
delete process.env.MY_CUSTOM_VAR;
console.log(process.env.MY_CUSTOM_VAR); // undefined
```

### Environment Inheritance

When you spawn a child process, it inherits a copy of the parent's environment by default. You can override this by passing a custom `env` option:

```javascript
'use strict';

const { execSync } = require('node:child_process');

// Child inherits parent's environment by default
const output1 = execSync('node -e "console.log(process.env.HOME)"', {
  encoding: 'utf8'
});
console.log('Inherited HOME:', output1.trim());

// Override the child's environment entirely
const output2 = execSync('node -e "console.log(process.env.CUSTOM)"', {
  encoding: 'utf8',
  env: { CUSTOM: 'from-parent', PATH: process.env.PATH }
  // Must include PATH or the child cannot find `node`
});
console.log('Custom env:', output2.trim());
```

---

## The Process Tree

Every process except PID 1 has a parent. This creates a tree structure. When a parent process dies, its children become orphans and are adopted by PID 1. When a child process dies, the parent receives a `SIGCHLD` signal (Node.js handles this internally when you use `child_process`).

```javascript
'use strict';

const { spawn } = require('node:child_process');

// Spawn a child and observe the relationship
const child = spawn('node', [
  '-e',
  `console.log('Child PID:', process.pid);
   console.log('Parent PID:', process.ppid);`
], { stdio: 'inherit' });

console.log('Parent PID:', process.pid);
console.log('Child PID from parent:', child.pid);

child.on('exit', (code) => {
  console.log('Child exited with code:', code);
});
```

### Zombie Processes

A **zombie** process is one that has exited but whose parent has not yet read its exit status. The OS keeps the process entry in the table so the parent can retrieve the exit code. In Node.js, the `child_process` module handles this automatically — when you listen for the `'exit'` event, Node reads the exit status and clears the zombie.

If you spawn children without ever handling their exit, you can accumulate zombies. Always attach an `'exit'` or `'close'` listener to child processes.

---

## Putting It Together: A Unix-Aware Script

Here is a script that demonstrates every concept from this lesson — process identity, file descriptors, standard streams, exit codes, and environment variables:

```javascript
'use strict';

const fs = require('node:fs');

// 1. Process identity
console.log('=== Process Identity ===');
console.log(`PID: ${process.pid}`);
console.log(`Parent PID: ${process.ppid}`);
console.log(`Platform: ${process.platform}`);
console.log(`Node version: ${process.version}`);

// 2. File descriptors
console.log('\n=== File Descriptors ===');
const fd = fs.openSync('/tmp/fd-demo.txt', 'w');
console.log(`Opened /tmp/fd-demo.txt on fd ${fd}`);
fs.writeSync(fd, `Written by PID ${process.pid}\n`);
fs.closeSync(fd);
console.log('File descriptor closed');

// 3. Standard streams
console.log('\n=== Standard Streams ===');
process.stdout.write('This is stdout\n');
process.stderr.write('This is stderr\n');

// 4. Environment
console.log('\n=== Environment ===');
console.log(`NODE_ENV: ${process.env.NODE_ENV || 'development'}`);
console.log(`HOME: ${process.env.HOME}`);

// 5. Exit code
process.exitCode = 0;
process.on('exit', (code) => {
  console.log(`\nExiting with code ${code}`);
});
```

---

## Key Takeaways

- A Unix process is an isolated unit of execution with its own PID, memory space, file descriptor table, and environment — Node.js gives you access to all of these through the `process` global.
- File descriptors are integers that point to open I/O resources; leaking them (by not closing files or sockets) leads to `EMFILE` errors in production.
- Every process starts with three open streams — stdin (fd 0), stdout (fd 1), and stderr (fd 2) — which form the backbone of Unix piping and redirection.
- Exit codes (0 for success, non-zero for failure) are how parent processes, shell scripts, and CI pipelines determine whether your program succeeded.
- Environment variables propagate from parent to child by default; children get a copy, so mutations in the child never affect the parent.

---

## Next

In the next lesson you will explore the `process` module in depth — parsing command-line arguments, measuring memory usage, tracking uptime, and using high-resolution timers for performance profiling.
