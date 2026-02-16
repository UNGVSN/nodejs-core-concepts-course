# Module 08 / Lesson 04 — Child Processes: spawn & fork

> When `exec` and `execFile` hit their limits — output too large for memory, process runs for hours, or you need real-time data — you reach for `spawn`. And when you need two Node.js processes to talk to each other directly, you reach for `fork`. These are the workhorses of the `child_process` module.

---

## Learning Objectives

- Create streaming child processes with `spawn` and process their output incrementally
- Configure the `stdio` option to control how stdin, stdout, and stderr are connected ('pipe', 'inherit', 'ignore')
- Use `fork` to spawn a new Node.js process with a built-in IPC channel
- Choose the right child process method for a given use case
- Handle child process lifecycle events: 'exit', 'close', 'error', and 'disconnect'

---

## spawn — Streaming Child Processes

`spawn` launches a new process and returns a `ChildProcess` object with streams for stdin, stdout, and stderr. Unlike `exec`, it does not buffer output — data flows through streams in real time.

```javascript
'use strict';

const { spawn } = require('node:child_process');

// Spawn a child process — no shell by default
const child = spawn('ls', ['-la', '/tmp']);

// stdout and stderr are readable streams
child.stdout.on('data', (chunk) => {
  console.log('stdout:', chunk.toString());
});

child.stderr.on('data', (chunk) => {
  console.error('stderr:', chunk.toString());
});

// 'close' fires when all stdio streams are closed and the process has exited
child.on('close', (code, signal) => {
  console.log(`Child exited: code=${code}, signal=${signal}`);
});
```

### spawn vs exec — The Key Difference

| Feature | exec / execFile | spawn |
|---------|-----------------|-------|
| Output delivery | Buffered in memory, delivered in callback | Streamed via readable streams |
| Memory usage | Proportional to output size | Constant (chunk-by-chunk) |
| Max output | Limited by `maxBuffer` (default ~1 MB) | Unlimited |
| Shell | Yes (exec) / No (execFile) | No (unless `shell: true`) |
| Use case | Short commands, small output | Long-running processes, large output |

```javascript
'use strict';

const { spawn } = require('node:child_process');

// Stream output from a long-running process
// This would overflow exec's maxBuffer
const find = spawn('find', ['/usr', '-type', 'f']);

let lineCount = 0;

find.stdout.on('data', (chunk) => {
  // Process each chunk as it arrives — memory stays flat
  const lines = chunk.toString().split('\n');
  lineCount += lines.length;
});

find.on('close', (code) => {
  console.log(`Found approximately ${lineCount} files (exit code: ${code})`);
});
```

---

## The stdio Option

The `stdio` option controls how the child's stdin (fd 0), stdout (fd 1), and stderr (fd 2) are connected. It accepts an array of three values, one per file descriptor:

| Value | Meaning |
|-------|---------|
| `'pipe'` | Create a pipe between parent and child (default) |
| `'inherit'` | Share the parent's stream — child writes directly to the parent's terminal |
| `'ignore'` | Discard the stream — connect to `/dev/null` |

```javascript
'use strict';

const { spawn } = require('node:child_process');

// Default: all three streams are piped
// Equivalent to stdio: ['pipe', 'pipe', 'pipe']
const piped = spawn('echo', ['hello pipe']);
piped.stdout.on('data', (d) => console.log('Piped:', d.toString().trim()));

// Inherit: child writes directly to parent's terminal
// child.stdout is null (no pipe to read from)
const inherited = spawn('echo', ['hello inherit'], {
  stdio: 'inherit' // Shorthand for ['inherit', 'inherit', 'inherit']
});
inherited.on('close', () => console.log('Inherited child done'));

// Ignore: discard all output
const ignored = spawn('echo', ['hello void'], {
  stdio: 'ignore' // Shorthand for ['ignore', 'ignore', 'ignore']
});
ignored.on('close', () => console.log('Ignored child done'));
```

### Mixed stdio Configurations

You can mix modes for different file descriptors:

```javascript
'use strict';

const { spawn } = require('node:child_process');

// Pipe stdout (so we can read it), but let stderr go to the terminal
const child = spawn('node', [
  '-e',
  `console.log("result: 42");
   console.error("debug: computing...");`
], {
  stdio: ['ignore', 'pipe', 'inherit']
  //       stdin     stdout   stderr
});

// Only stdout is available as a stream
child.stdout.on('data', (chunk) => {
  console.log('Captured stdout:', chunk.toString().trim());
});
// stderr goes directly to the parent's terminal — we see it immediately
```

### Writing to the Child's stdin

When stdin is `'pipe'`, the parent gets a writable stream:

```javascript
'use strict';

const { spawn } = require('node:child_process');

// Spawn a child that reads from stdin and converts to uppercase
const child = spawn('node', [
  '-e',
  `process.stdin.on('data', (d) => {
    process.stdout.write(d.toString().toUpperCase());
  });
  process.stdin.on('end', () => process.exit(0));`
]);

// Write to the child's stdin
child.stdin.write('hello ');
child.stdin.write('world\n');
child.stdin.end(); // Signal end of input

child.stdout.on('data', (chunk) => {
  console.log('Child says:', chunk.toString().trim());
  // "HELLO WORLD"
});
```

---

## spawn with a Shell

By default, `spawn` does not use a shell. If you need shell features, pass `shell: true`:

```javascript
'use strict';

const { spawn } = require('node:child_process');

// Without shell: true, pipes don't work
// spawn('cat /etc/hosts | grep localhost') would fail — "cat /etc/hosts | grep localhost" is not a binary

// With shell: true, the command is passed to /bin/sh -c
const child = spawn('cat /etc/hosts | grep localhost', {
  shell: true,
  stdio: ['ignore', 'pipe', 'pipe']
});

child.stdout.on('data', (chunk) => {
  console.log(chunk.toString().trim());
});

child.on('close', (code) => {
  console.log('Exit code:', code);
});
```

The same security warning from `exec` applies: with `shell: true`, never interpolate user input into the command string.

---

## fork — Spawning Node.js Processes with IPC

`fork` is a specialized version of `spawn` designed for Node.js scripts. It does two things that `spawn` does not:

1. Automatically runs the script with the same `node` executable
2. Opens an **IPC (Inter-Process Communication) channel** between parent and child

```javascript
'use strict';

const { fork } = require('node:child_process');
const path = require('node:path');

// fork() runs the script with the same Node.js binary
// No need to specify 'node' as the command
const child = fork(path.join(__dirname, 'worker.js'));

// IPC: send a message to the child
child.send({ type: 'task', payload: { x: 10, y: 20 } });

// IPC: receive messages from the child
child.on('message', (msg) => {
  console.log('Parent received:', msg);
  child.disconnect(); // Close the IPC channel
});

child.on('exit', (code) => {
  console.log('Worker exited with code:', code);
});
```

The worker script (`worker.js`):

```javascript
'use strict';

// In a forked process, process.send and process.on('message') are available
process.on('message', (msg) => {
  if (msg.type === 'task') {
    const result = msg.payload.x + msg.payload.y;
    process.send({ type: 'result', value: result });
  }
});
```

### fork Options

```javascript
'use strict';

const { fork } = require('node:child_process');
const path = require('node:path');

const child = fork(path.join(__dirname, 'worker.js'), ['--verbose'], {
  // Arguments to pass to the script (not to node itself)
  // The first argument above (['--verbose']) is process.argv for the child

  // Control stdio — default is ['pipe', 'pipe', 'pipe', 'ipc']
  // The 4th element is the IPC channel (always present with fork)
  stdio: ['ignore', 'inherit', 'inherit', 'ipc'],

  // Environment for the child
  env: { ...process.env, WORKER_ID: '1' },

  // Arguments for the Node.js executable itself
  execArgv: ['--max-old-space-size=256'],

  // Use a different Node.js binary (rare, but possible)
  // execPath: '/usr/local/bin/node18',

  // Detach the child from the parent (see below)
  // detached: false,
});

child.on('message', (msg) => console.log('Received:', msg));
child.send({ action: 'start' });
```

---

## ChildProcess Events

The object returned by `spawn` and `fork` emits several events:

```javascript
'use strict';

const { spawn } = require('node:child_process');

const child = spawn('node', [
  '-e',
  'setTimeout(() => { console.log("done"); process.exit(0); }, 500);'
]);

// 'spawn' — fires when the process is successfully launched
child.on('spawn', () => {
  console.log('Child process spawned, PID:', child.pid);
});

// 'error' — fires when the process could not be spawned or killed
child.on('error', (err) => {
  console.error('Failed to start child:', err.message);
});

// 'exit' — fires when the process exits
// code is the exit code, signal is the signal that killed it
child.on('exit', (code, signal) => {
  console.log(`Exit event: code=${code}, signal=${signal}`);
});

// 'close' — fires when all stdio streams are closed
// This can fire AFTER 'exit' if there's buffered data in the streams
child.on('close', (code, signal) => {
  console.log(`Close event: code=${code}, signal=${signal}`);
});

child.stdout.on('data', (d) => console.log('stdout:', d.toString().trim()));
```

### exit vs close

The distinction matters. `'exit'` fires when the child process terminates. `'close'` fires when the stdio streams are fully closed. If the child piped data to another process, the streams might stay open after the child exits. Always use `'close'` when you need to be sure you have received all the data.

---

## Killing Child Processes

```javascript
'use strict';

const { spawn } = require('node:child_process');

const child = spawn('sleep', ['30']);

console.log('Spawned sleep process, PID:', child.pid);

// Kill with SIGTERM (default)
setTimeout(() => {
  console.log('Sending SIGTERM...');
  child.kill(); // Equivalent to child.kill('SIGTERM')
}, 1000);

// Kill with SIGKILL (forceful — cannot be caught)
// child.kill('SIGKILL');

child.on('exit', (code, signal) => {
  console.log(`Exited: code=${code}, signal=${signal}`);
  // code=null, signal='SIGTERM'
});
```

### Timeout Pattern

```javascript
'use strict';

const { spawn } = require('node:child_process');

function spawnWithTimeout(cmd, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args);
    let stdout = '';
    let stderr = '';

    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`Process timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });

    child.on('close', (code) => {
      clearTimeout(timer);
      if (code === 0) {
        resolve({ stdout, stderr });
      } else {
        reject(new Error(`Process exited with code ${code}: ${stderr}`));
      }
    });

    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

spawnWithTimeout('node', ['-e', 'setTimeout(() => console.log("done"), 100)'], 5000)
  .then((result) => console.log('Success:', result.stdout.trim()))
  .catch((err) => console.error('Error:', err.message));
```

---

## Detached Processes

By default, the parent waits for all children to exit. A **detached** child runs independently — the parent can exit without killing it.

```javascript
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');

// Spawn a detached child that outlives the parent
const logFile = fs.openSync('/tmp/detached-child.log', 'a');

const child = spawn('node', [
  '-e',
  `setInterval(() => {
    const msg = new Date().toISOString() + ' — still running\\n';
    process.stdout.write(msg);
  }, 1000);`
], {
  detached: true,
  stdio: ['ignore', logFile, logFile]
});

// Allow the parent to exit without waiting for the child
child.unref();

console.log(`Spawned detached child PID: ${child.pid}`);
console.log('Parent exiting. Child continues writing to /tmp/detached-child.log');
```

---

## Piping Between Processes

You can connect the stdout of one child to the stdin of another, replicating Unix pipes:

```javascript
'use strict';

const { spawn } = require('node:child_process');

// Equivalent to: cat /etc/hosts | grep localhost | wc -l
const cat = spawn('cat', ['/etc/hosts']);
const grep = spawn('grep', ['localhost']);
const wc = spawn('wc', ['-l']);

// Pipe cat's stdout → grep's stdin
cat.stdout.pipe(grep.stdin);

// Pipe grep's stdout → wc's stdin
grep.stdout.pipe(wc.stdin);

// Read the final result from wc's stdout
wc.stdout.on('data', (chunk) => {
  console.log('Matching lines:', chunk.toString().trim());
});

wc.on('close', (code) => {
  console.log('Pipeline complete, exit code:', code);
});
```

---

## When to Use Each Method

| Scenario | Method | Reason |
|----------|--------|--------|
| Run a shell one-liner | `exec` | Needs shell features (pipes, globs) |
| Run a binary safely | `execFile` | No shell, arguments as array |
| Stream large output | `spawn` | No memory buffering |
| Long-running background process | `spawn` | Streaming, can detach |
| Send messages to a Node.js script | `fork` | Built-in IPC channel |
| Parallel computation in Node.js | `fork` | Separate V8 instance, IPC |
| Quick scripting | `execSync` | Blocking is acceptable |

---

## Practical Example: A Process Pool

```javascript
'use strict';

const { fork } = require('node:child_process');
const path = require('node:path');

class ProcessPool {
  #workers = [];
  #available = [];
  #queue = [];
  #workerScript;

  constructor(workerScript, size) {
    this.#workerScript = workerScript;

    for (let i = 0; i < size; i++) {
      this.#addWorker();
    }
  }

  #addWorker() {
    const worker = fork(this.#workerScript);
    worker.on('message', (msg) => {
      if (msg.type === 'ready' || msg.type === 'result') {
        this.#available.push(worker);
        this.#processQueue();
      }
    });
    worker.on('exit', (code) => {
      // Remove dead worker and replace it
      this.#workers = this.#workers.filter((w) => w !== worker);
      this.#available = this.#available.filter((w) => w !== worker);
      if (code !== 0) {
        console.log(`Worker ${worker.pid} crashed, respawning...`);
        this.#addWorker();
      }
    });
    this.#workers.push(worker);
    this.#available.push(worker);
  }

  dispatch(task) {
    return new Promise((resolve, reject) => {
      this.#queue.push({ task, resolve, reject });
      this.#processQueue();
    });
  }

  #processQueue() {
    while (this.#queue.length > 0 && this.#available.length > 0) {
      const worker = this.#available.shift();
      const { task, resolve } = this.#queue.shift();

      const handler = (msg) => {
        if (msg.type === 'result') {
          worker.removeListener('message', handler);
          resolve(msg.value);
        }
      };

      worker.on('message', handler);
      worker.send({ type: 'task', payload: task });
    }
  }

  async shutdown() {
    for (const worker of this.#workers) {
      worker.disconnect();
    }
  }
}

// Usage (if pool-worker.js exists):
// const pool = new ProcessPool(path.join(__dirname, 'pool-worker.js'), 4);
// pool.dispatch({ compute: 'fibonacci', n: 40 }).then(console.log);

module.exports = { ProcessPool };
```

---

## Key Takeaways

- `spawn` streams child process I/O through readable/writable streams, making it suitable for large output and long-running processes without hitting memory limits.
- The `stdio` option controls how each file descriptor is connected: `'pipe'` for parent access, `'inherit'` to share the terminal, and `'ignore'` to discard.
- `fork` is `spawn` specialized for Node.js scripts — it automatically uses the same `node` binary and opens an IPC channel for `send()`/`on('message')` communication.
- Always listen for both `'exit'` and `'error'` on child processes; `'close'` is the safest event for ensuring all streamed data has been received.
- Use `detached: true` with `child.unref()` when you need a child that outlives its parent, and connect stdio to files instead of pipes.

---

## Next

In the next lesson you will dive deeper into IPC — the message-passing protocol between parent and child processes, serialization constraints, and patterns for building reliable request-response communication.
