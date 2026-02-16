# Track 03 / Lesson 04 — File Descriptor Passing

> In Unix, everything is a file — and every open file is a number. When you can pass that number from one process to another, you unlock patterns that would otherwise be impossible: zero-downtime deploys, graceful restarts, and socket handoff between workers. This lesson teaches you how file descriptor passing works in Node.js and why it matters for production systems.

## Learning Objectives

- Explain what a file descriptor is and why passing one between processes is fundamentally different from passing data
- Configure `child_process.spawn` `stdio` to pass file descriptors to child processes
- Use `subprocess.send()` with `sendHandle()` to transfer `net.Server` and `net.Socket` objects between cluster workers
- Pass `MessagePort` objects between workers using `postMessage` with `transferList`
- Implement real-world patterns: graceful restart, zero-downtime deployment, and pre-opened socket handoff

---

## What Is a File Descriptor

Every open file, socket, pipe, or device in a Unix process is represented by a small non-negative integer called a file descriptor (fd). The kernel maintains a per-process table mapping these integers to internal kernel structures.

```javascript
'use strict';

const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const os = require('node:os');

// Standard file descriptors (always open)
// fd 0 = stdin
// fd 1 = stdout
// fd 2 = stderr

// When you open a file, the kernel assigns the next available fd
const tmpFile = path.join(os.tmpdir(), 'fd-demo.txt');
fs.writeFileSync(tmpFile, 'Hello, file descriptors!\n');

const fd = fs.openSync(tmpFile, 'r');
console.log(`Opened file, got fd: ${fd}`); // Likely fd 3 or higher

// Read using the raw fd
const buf = Buffer.alloc(64);
const bytesRead = fs.readSync(fd, buf, 0, 64, 0);
console.log(`Read ${bytesRead} bytes: ${buf.toString('utf8', 0, bytesRead).trim()}`);
fs.closeSync(fd);

// Sockets are also file descriptors
const server = net.createServer();
server.listen(0, () => {
  const addr = server.address();
  console.log(`Server listening on port ${addr.port}`);

  // The server's underlying socket has a file descriptor
  // (accessible via internal handle, not directly exposed)
  console.log(`Server fd is managed by libuv internally`);

  server.close();
});

// Clean up
fs.unlinkSync(tmpFile);
```

The key insight for this lesson: when you "pass a file descriptor" between processes, you are not passing data. You are telling the kernel to create a new entry in the *receiving* process's fd table that points to the *same* underlying kernel object. Both processes can then read from or write to the same file/socket/pipe.

---

## Passing File Descriptors via child_process.spawn

The `stdio` option in `child_process.spawn` controls how the child's standard I/O streams are connected. You can pass specific file descriptors.

### Basic stdio Configuration

```javascript
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

// Create a log file that the child will write to
const logPath = path.join(os.tmpdir(), 'child-output.log');
const logFd = fs.openSync(logPath, 'w');

// Spawn a child process with custom stdio:
// [stdin, stdout, stderr]
// - 'pipe'   : create a pipe between parent and child
// - 'inherit': use the parent's fd (child shares parent's terminal)
// - fd number : pass a specific file descriptor
// - 'ignore' : /dev/null
const child = spawn('node', ['-e', `
  'use strict';
  // This child's stdout (fd 1) is connected to our log file
  console.log('This goes to the log file, not the terminal');
  console.log('PID: ' + process.pid);
  console.log('Timestamp: ' + new Date().toISOString());
`], {
  stdio: [
    'ignore',  // stdin: /dev/null
    logFd,     // stdout: redirect to our log file descriptor
    'inherit', // stderr: share parent's stderr
  ],
});

child.on('exit', (code) => {
  fs.closeSync(logFd);
  console.log(`Child exited with code ${code}`);
  console.log(`Log file contents:`);
  console.log(fs.readFileSync(logPath, 'utf8'));
  fs.unlinkSync(logPath);
});
```

### Extra stdio Channels

Beyond stdin/stdout/stderr (fds 0-2), you can create additional pipe channels:

```javascript
'use strict';

const { spawn } = require('node:child_process');

// Create a child with an extra pipe on fd 3
const child = spawn('node', ['-e', `
  'use strict';
  const fs = require('node:fs');

  // fd 3 is the extra pipe passed by the parent
  const pipe = fs.createWriteStream(null, { fd: 3 });
  pipe.write('Message on fd 3 from child\\n');
  pipe.write('PID: ' + process.pid + '\\n');
  pipe.end();
`], {
  stdio: [
    'inherit', // 0: stdin
    'inherit', // 1: stdout
    'inherit', // 2: stderr
    'pipe',    // 3: extra pipe (parent can read from child.stdio[3])
  ],
});

// Read from the extra pipe
let data = '';
child.stdio[3].on('data', (chunk) => {
  data += chunk.toString();
});

child.stdio[3].on('end', () => {
  console.log('Received on fd 3:');
  console.log(data);
});
```

---

## Passing Sockets with sendHandle

The `child_process` IPC channel supports sending `net.Server` and `net.Socket` handles between a parent and child process. This is the foundation of the `node:cluster` module.

### Parent Sends a Socket to Child

```javascript
'use strict';

const { fork } = require('node:child_process');
const net = require('node:net');

if (process.argv[2] === 'child') {
  // Child process: wait for a socket handle from parent
  process.on('message', (msg, handle) => {
    if (msg === 'socket' && handle) {
      console.log(`[Child ${process.pid}] Received a client socket!`);

      // We can now communicate directly with the client
      handle.write(`Hello from child process ${process.pid}\n`);
      handle.on('data', (data) => {
        console.log(`[Child ${process.pid}] Client sent: ${data.toString().trim()}`);
        handle.write(`[Child ${process.pid}] Echo: ${data}`);
      });
      handle.on('end', () => {
        console.log(`[Child ${process.pid}] Client disconnected`);
      });
    }
  });
} else {
  // Parent process: create a TCP server and pass connections to children
  const workers = [];
  for (let i = 0; i < 2; i++) {
    workers.push(fork(__filename, ['child']));
  }

  let workerIndex = 0;

  const server = net.createServer((socket) => {
    // Round-robin: pass each new connection to the next worker
    const worker = workers[workerIndex % workers.length];
    workerIndex++;

    console.log(`[Parent] Passing connection to worker ${worker.pid}`);

    // Send the socket handle to the child process
    worker.send('socket', socket);

    // IMPORTANT: After sending, the parent should not use the socket
    // The child now owns it
  });

  server.listen(8000, () => {
    console.log(`[Parent ${process.pid}] Server on port 8000`);
    console.log('Connect with: nc localhost 8000');
  });

  process.on('SIGINT', () => {
    console.log('\nShutting down...');
    for (const w of workers) w.kill();
    server.close();
    process.exit(0);
  });
}
```

### Parent Sends a Server to Child

You can also send the entire `net.Server` to a child, letting the child accept connections directly:

```javascript
'use strict';

const { fork } = require('node:child_process');
const net = require('node:net');

if (process.argv[2] === 'child') {
  process.on('message', (msg, handle) => {
    if (msg === 'server' && handle) {
      console.log(`[Child ${process.pid}] Received server handle`);

      // The child now listens on the same port as the parent
      handle.on('connection', (socket) => {
        console.log(`[Child ${process.pid}] New connection`);
        socket.write(`Handled by child ${process.pid}\n`);
        socket.end();
      });
    }
  });
} else {
  const server = net.createServer();

  server.listen(8001, () => {
    console.log(`[Parent] Server created on port 8001`);

    // Fork children and send them the server handle
    for (let i = 0; i < 3; i++) {
      const child = fork(__filename, ['child']);
      child.send('server', server);
    }

    // The parent can optionally close its reference to the server.
    // The children will continue accepting connections.
    // server.close();
    console.log('[Parent] Server handle sent to 3 children');
    console.log('Connections will be distributed by the OS kernel');
  });

  process.on('SIGINT', () => process.exit(0));
}
```

When multiple processes listen on the same port via a shared server handle, the operating system's kernel distributes incoming connections among them. On Linux, this uses `SO_REUSEPORT` semantics.

---

## How the Cluster Module Uses fd Passing

The `node:cluster` module is built on top of the `sendHandle` mechanism. Understanding the internals demystifies its behavior:

```javascript
'use strict';

const cluster = require('node:cluster');
const http = require('node:http');
const os = require('node:os');

if (cluster.isPrimary) {
  const numWorkers = Math.min(os.cpus().length, 4);
  console.log(`[Primary ${process.pid}] Forking ${numWorkers} workers`);

  for (let i = 0; i < numWorkers; i++) {
    cluster.fork();
  }

  // What happens internally:
  // 1. Primary creates a net.Server bound to the port
  // 2. Primary forks child processes using child_process.fork()
  // 3. When a worker calls server.listen(), it sends a message to the primary
  // 4. Primary sends the server handle to the worker via sendHandle()
  // 5. On Linux, the kernel distributes connections via SO_REUSEPORT
  // 6. On other platforms, the primary accepts and round-robins to workers

  cluster.on('exit', (worker, code) => {
    console.log(`[Primary] Worker ${worker.process.pid} exited (code ${code})`);
    // Respawn the dead worker
    cluster.fork();
  });
} else {
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`Handled by worker ${process.pid}\n`);
  });

  // This does NOT bind a new port — it receives the primary's server handle
  server.listen(8002, () => {
    console.log(`[Worker ${process.pid}] Listening on port 8002`);
  });
}
```

---

## Graceful Restart: Zero-Downtime Deployment

File descriptor passing enables zero-downtime restarts. The old process passes its listening socket to the new process before exiting.

```javascript
'use strict';

const net = require('node:net');
const { fork } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const PID_FILE = path.join('/tmp', 'graceful-server.pid');
const PORT = 8003;

function startServer() {
  const server = net.createServer((socket) => {
    const version = process.env.APP_VERSION || 'v1';
    socket.write(`Hello from ${version} (PID ${process.pid})\n`);
    socket.end();
  });

  server.listen(PORT, () => {
    console.log(`[${process.pid}] Server listening on port ${PORT}`);
    fs.writeFileSync(PID_FILE, String(process.pid));
  });

  // Handle SIGUSR2 as the "graceful restart" signal
  process.on('SIGUSR2', () => {
    console.log(`[${process.pid}] Received SIGUSR2 — starting graceful restart`);

    // Fork a new process with the updated code
    const newProcess = fork(__filename, [], {
      env: { ...process.env, APP_VERSION: 'v2' },
    });

    // Send the server handle to the new process
    newProcess.send('server', server);

    newProcess.on('message', (msg) => {
      if (msg === 'ready') {
        console.log(`[${process.pid}] New process ready, closing old server`);

        // Stop accepting new connections
        server.close(() => {
          console.log(`[${process.pid}] All connections drained, exiting`);
          process.exit(0);
        });

        // Force exit after timeout if connections do not drain
        setTimeout(() => {
          console.log(`[${process.pid}] Drain timeout, forcing exit`);
          process.exit(0);
        }, 5000);
      }
    });
  });

  return server;
}

// Check if we received a server handle from a parent process
process.on('message', (msg, handle) => {
  if (msg === 'server' && handle) {
    console.log(`[${process.pid}] Received server handle from parent`);

    // Use the received server handle
    handle.on('connection', (socket) => {
      const version = process.env.APP_VERSION || 'v1';
      socket.write(`Hello from ${version} (PID ${process.pid})\n`);
      socket.end();
    });

    fs.writeFileSync(PID_FILE, String(process.pid));
    process.send('ready');
    console.log(`[${process.pid}] Ready to serve`);
  }
});

// If not a child process, start normally
if (!process.send) {
  startServer();
}

// Usage:
// Terminal 1: node lesson-04-graceful-restart.js
// Terminal 2: kill -USR2 $(cat /tmp/graceful-server.pid)
// Terminal 3: nc localhost 8003
```

---

## Worker Threads: Transferring MessagePort

Within the same process, `worker_threads` can transfer `MessagePort` objects (not just copy them) using the `transferList` parameter:

```javascript
'use strict';

const {
  Worker,
  isMainThread,
  parentPort,
  MessageChannel,
  workerData,
} = require('node:worker_threads');

if (isMainThread) {
  // Create a MessageChannel — two connected ports
  const { port1, port2 } = new MessageChannel();

  // Create two workers
  const workerA = new Worker(__filename, {
    workerData: { name: 'Worker-A' },
  });
  const workerB = new Worker(__filename, {
    workerData: { name: 'Worker-B' },
  });

  // Transfer port1 to Worker-A and port2 to Worker-B
  // After transfer, the main thread can no longer use these ports
  workerA.postMessage({ type: 'port', port: port1 }, [port1]);
  workerB.postMessage({ type: 'port', port: port2 }, [port2]);

  // Workers A and B can now communicate DIRECTLY
  // without routing through the main thread
  console.log('[Main] Transferred ports — workers can talk directly');

  workerA.on('message', (msg) => console.log(`[Main from A] ${msg}`));
  workerB.on('message', (msg) => console.log(`[Main from B] ${msg}`));
} else {
  let directPort = null;

  parentPort.on('message', (msg) => {
    if (msg.type === 'port') {
      directPort = msg.port;

      // Set up direct communication
      directPort.on('message', (data) => {
        console.log(`[${workerData.name}] Direct message: ${data}`);
        parentPort.postMessage(`${workerData.name} received: ${data}`);
      });

      // Send a greeting through the direct channel
      directPort.postMessage(`Hello from ${workerData.name}!`);
    }
  });
}
```

The `transferList` parameter is critical. Without it, `postMessage` would try to clone the `MessagePort`, which is not allowed. Transfer moves ownership — the sender can no longer use the object.

---

## Listening on a Pre-Opened File Descriptor

Some process managers (systemd, inetd) open a socket and pass the fd number to the child process via environment variable or convention. Node.js can listen on these pre-opened fds:

```javascript
'use strict';

const net = require('node:net');
const { spawn } = require('node:child_process');

// Parent: create a TCP server, get its fd, pass it to child
if (process.argv[2] !== 'child') {
  const server = net.createServer();
  server.listen(0, () => {
    const port = server.address().port;
    console.log(`[Parent] Server on port ${port}`);

    // Get the underlying fd (internal API, for demonstration)
    const handle = server._handle;
    const fd = handle.fd;
    console.log(`[Parent] Server fd: ${fd}`);

    // Spawn child with the server's fd passed as fd 3
    const child = spawn('node', [__filename, 'child', String(port)], {
      stdio: ['inherit', 'inherit', 'inherit', handle],
      env: { ...process.env, LISTEN_FD: '3' },
    });

    child.on('exit', (code) => {
      console.log(`[Parent] Child exited: ${code}`);
      server.close();
    });
  });
} else {
  // Child: listen on the pre-opened fd
  const listenFd = parseInt(process.env.LISTEN_FD, 10);
  const port = process.argv[3];

  console.log(`[Child ${process.pid}] Listening on pre-opened fd ${listenFd}`);
  console.log(`[Child] Original port was ${port}`);

  // Create a server from the pre-opened fd
  const server = net.createServer((socket) => {
    socket.write(`Hello from child ${process.pid}\n`);
    socket.end();
  });

  // server.listen({ fd: listenFd }) would work if the fd is properly inherited
  // In practice, systemd socket activation passes LISTEN_FDS and LISTEN_PID
  // and the child constructs the server from the inherited fd

  console.log('[Child] In production, systemd passes the listening fd');
  console.log('[Child] The child calls server.listen({ fd: N })');

  setTimeout(() => process.exit(0), 1000);
}
```

### systemd Socket Activation Pattern

```javascript
'use strict';

const net = require('node:net');
const http = require('node:http');

/**
 * Detect if we are running under systemd socket activation.
 *
 * systemd sets:
 *   LISTEN_PID  = our PID
 *   LISTEN_FDS  = number of fds passed (starting from fd 3)
 */
function getSystemdFds() {
  const listenPid = parseInt(process.env.LISTEN_PID, 10);
  const listenFds = parseInt(process.env.LISTEN_FDS, 10);

  if (listenPid !== process.pid || !listenFds) {
    return [];
  }

  // fds start at 3 (0=stdin, 1=stdout, 2=stderr)
  const fds = [];
  for (let i = 0; i < listenFds; i++) {
    fds.push(3 + i);
  }
  return fds;
}

const systemdFds = getSystemdFds();

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end(`PID ${process.pid}, activated: ${systemdFds.length > 0}\n`);
});

if (systemdFds.length > 0) {
  // Socket activation: listen on the pre-opened fd
  console.log(`systemd passed ${systemdFds.length} fd(s)`);
  server.listen({ fd: systemdFds[0] }, () => {
    console.log('Listening on systemd-provided socket');
  });
} else {
  // Fallback: open our own socket
  server.listen(8004, () => {
    console.log('Listening on port 8004 (no systemd activation)');
  });
}
```

---

## Practical Patterns: Connection Draining

When passing sockets during a graceful restart, you need to drain existing connections before the old process exits:

```javascript
'use strict';

const net = require('node:net');

/**
 * Track all active connections for graceful shutdown.
 */
function createTrackingServer(handler) {
  const connections = new Set();

  const server = net.createServer((socket) => {
    connections.add(socket);
    console.log(`Connection opened (active: ${connections.size})`);

    socket.on('close', () => {
      connections.delete(socket);
      console.log(`Connection closed (active: ${connections.size})`);
    });

    handler(socket);
  });

  server.drain = function drain(timeout = 5000) {
    return new Promise((resolve) => {
      // Stop accepting new connections
      server.close();

      if (connections.size === 0) {
        resolve('drained');
        return;
      }

      console.log(`Draining ${connections.size} active connections...`);

      // Notify connected clients that we are shutting down
      for (const conn of connections) {
        conn.write('Server shutting down. Finish your work.\n');
      }

      // Check periodically if all connections have closed
      const check = setInterval(() => {
        if (connections.size === 0) {
          clearInterval(check);
          clearTimeout(timer);
          resolve('drained');
        }
      }, 100);

      // Force-close remaining connections after timeout
      const timer = setTimeout(() => {
        clearInterval(check);
        console.log(`Timeout: force-closing ${connections.size} connections`);
        for (const conn of connections) {
          conn.destroy();
        }
        resolve('forced');
      }, timeout);
    });
  };

  return server;
}

// Usage
const server = createTrackingServer((socket) => {
  socket.write(`Connected to PID ${process.pid}\n`);
  socket.on('data', (data) => {
    socket.write(`Echo: ${data}`);
  });
});

server.listen(8005, () => {
  console.log(`Server on port 8005 (PID ${process.pid})`);
});

process.on('SIGINT', async () => {
  console.log('\nGraceful shutdown initiated...');
  const result = await server.drain(3000);
  console.log(`Shutdown complete: ${result}`);
  process.exit(0);
});
```

---

## Key Takeaways

- A file descriptor is a per-process integer that references a kernel object (file, socket, pipe) — passing an fd between processes shares the kernel object itself, not a copy of the data
- `child_process.spawn` `stdio` accepts file descriptor numbers, `'pipe'`, `'inherit'`, and `'ignore'` — this allows redirecting child I/O to files, pipes, or parent streams with zero application code in the child
- `subprocess.send(message, handle)` transfers `net.Server` and `net.Socket` objects between parent and child processes — this is the mechanism that powers the `node:cluster` module's multi-process request handling
- `worker_threads` `postMessage` with `transferList` moves ownership of `MessagePort`, `ArrayBuffer`, and other transferable objects — after transfer, the sender can no longer access the object
- Zero-downtime deployment relies on passing the listening socket from the old process to the new one, then draining existing connections before the old process exits — this is a production-critical pattern used by every serious Node.js deployment

## Next

In the next lesson, we drop down to the raw networking layer with `node:dgram`, exploring UDP multicast, broadcast, and advanced socket options for building low-latency network services.
