# Track 03 / Lesson 02 — Unix Sockets & Named Pipes

> When two processes on the same machine need to talk, sending packets through the TCP/IP stack is like mailing a letter to your next-door neighbor. Unix domain sockets skip the network layer entirely, routing data through the kernel's internal memory — faster, simpler, and more secure. This lesson teaches you to build IPC channels that stay local.

## Learning Objectives

- Create a Unix domain socket server and client using `node:net` with the `path` option
- Explain why Unix domain sockets outperform TCP for local inter-process communication
- Implement named pipe communication patterns on POSIX and understand Windows pipe naming
- Handle socket file cleanup on crash and manage file permissions for security
- Build practical IPC patterns for inter-service communication on a single host

---

## Unix Domain Sockets vs TCP: What Is the Difference

TCP sockets communicate over the network stack, even when both endpoints are on `localhost`. Every packet travels through:

1. Application layer (your data)
2. Transport layer (TCP segmentation, checksums, congestion control)
3. Network layer (IP routing)
4. Loopback interface (for localhost)
5. Back up through the stack to the receiver

Unix domain sockets (UDS) bypass all of this. They are a kernel-level IPC mechanism that transfers data directly between processes through a file-system path. The data never touches the network stack.

```javascript
'use strict';

// Performance characteristics comparison:
//
// | Feature                | TCP localhost      | Unix Domain Socket |
// |------------------------|--------------------|--------------------|
// | Network stack overhead | Full (L3/L4)       | None               |
// | Latency                | ~50-100 us         | ~10-30 us          |
// | Throughput             | Good               | 20-50% higher      |
// | Authentication         | IP-based           | File permissions   |
// | Port conflicts         | Possible           | Impossible (paths) |
// | Cross-machine          | Yes                | No (same host)     |
// | File system entry      | No                 | Yes (.sock file)   |
// | Windows support        | Yes                | Named pipes only   |
```

---

## Creating a Unix Domain Socket Server

The `node:net` module supports Unix domain sockets natively. Instead of passing a `port`, you pass a `path`.

```javascript
'use strict';

const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');

const SOCKET_PATH = path.join('/tmp', 'myapp.sock');

// Clean up any stale socket file from a previous crash
if (fs.existsSync(SOCKET_PATH)) {
  fs.unlinkSync(SOCKET_PATH);
  console.log(`Removed stale socket: ${SOCKET_PATH}`);
}

const server = net.createServer((connection) => {
  console.log('Client connected');

  connection.on('data', (data) => {
    const message = data.toString().trim();
    console.log(`Received: ${message}`);

    // Echo back with a timestamp
    const response = JSON.stringify({
      echo: message,
      timestamp: Date.now(),
      pid: process.pid,
    });
    connection.write(response + '\n');
  });

  connection.on('end', () => {
    console.log('Client disconnected');
  });

  connection.on('error', (err) => {
    console.error(`Connection error: ${err.message}`);
  });
});

server.listen(SOCKET_PATH, () => {
  console.log(`Server listening on ${SOCKET_PATH}`);
  console.log(`Server PID: ${process.pid}`);
});

// Graceful cleanup
function cleanup() {
  server.close(() => {
    // Remove the socket file so the next startup does not fail
    if (fs.existsSync(SOCKET_PATH)) {
      fs.unlinkSync(SOCKET_PATH);
    }
    console.log('Server shut down cleanly');
    process.exit(0);
  });
}

process.on('SIGINT', cleanup);
process.on('SIGTERM', cleanup);
```

---

## Creating a Unix Domain Socket Client

```javascript
'use strict';

const net = require('node:net');
const path = require('node:path');
const readline = require('node:readline');

const SOCKET_PATH = path.join('/tmp', 'myapp.sock');

const client = net.connect({ path: SOCKET_PATH }, () => {
  console.log(`Connected to ${SOCKET_PATH}`);
  console.log('Type a message and press Enter (Ctrl+C to quit):\n');
});

// Handle incoming data from the server
let buffer = '';
client.on('data', (data) => {
  buffer += data.toString();

  // Process complete newline-delimited messages
  let newlineIndex;
  while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
    const message = buffer.slice(0, newlineIndex);
    buffer = buffer.slice(newlineIndex + 1);

    try {
      const parsed = JSON.parse(message);
      console.log(`Server response: ${JSON.stringify(parsed, null, 2)}\n`);
    } catch {
      console.log(`Server raw: ${message}\n`);
    }
  }
});

client.on('end', () => {
  console.log('Disconnected from server');
  process.exit(0);
});

client.on('error', (err) => {
  if (err.code === 'ENOENT') {
    console.error(`Socket not found at ${SOCKET_PATH}. Is the server running?`);
  } else if (err.code === 'ECONNREFUSED') {
    console.error('Connection refused. The server may have crashed.');
  } else {
    console.error(`Connection error: ${err.message}`);
  }
  process.exit(1);
});

// Read input from stdin and send to server
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
});

rl.on('line', (line) => {
  if (line.trim()) {
    client.write(line.trim() + '\n');
  }
});
```

---

## Socket File Cleanup: The Crash Problem

The biggest operational headache with Unix domain sockets is stale socket files. When a server crashes (kill -9, OOM, segfault), it cannot run cleanup code. The socket file remains, and the next startup fails with `EADDRINUSE`.

```javascript
'use strict';

const net = require('node:net');
const fs = require('node:fs');

const SOCKET_PATH = '/tmp/robust-app.sock';

/**
 * Safely start a Unix socket server, handling stale socket files.
 */
function createRobustServer(socketPath, connectionHandler) {
  return new Promise((resolve, reject) => {
    const server = net.createServer(connectionHandler);

    server.on('error', (err) => {
      if (err.code === 'EADDRINUSE') {
        // The socket file exists. Is someone actually listening?
        const testClient = net.connect({ path: socketPath }, () => {
          // Another server IS running — this is a real conflict
          testClient.end();
          reject(new Error(`Another server is already listening on ${socketPath}`));
        });

        testClient.on('error', (clientErr) => {
          if (clientErr.code === 'ECONNREFUSED') {
            // Stale socket file — no one is listening. Safe to remove.
            console.log('Detected stale socket file, removing...');
            fs.unlinkSync(socketPath);
            // Retry the listen
            server.listen(socketPath, () => resolve(server));
          } else {
            reject(clientErr);
          }
        });
      } else {
        reject(err);
      }
    });

    server.listen(socketPath, () => resolve(server));
  });
}

// Usage
async function main() {
  const server = await createRobustServer(SOCKET_PATH, (conn) => {
    conn.on('data', (data) => {
      conn.write(`ACK: ${data.toString().trim()}\n`);
    });
  });

  console.log(`Robust server listening on ${SOCKET_PATH}`);

  // Register cleanup for all termination signals
  const signals = ['SIGINT', 'SIGTERM', 'SIGHUP'];
  for (const signal of signals) {
    process.on(signal, () => {
      console.log(`\nReceived ${signal}, shutting down...`);
      server.close();
      try { fs.unlinkSync(SOCKET_PATH); } catch { /* ignore */ }
      process.exit(0);
    });
  }
}

main().catch((err) => {
  console.error(`Failed to start: ${err.message}`);
  process.exit(1);
});
```

---

## Permission Management

Unix domain sockets inherit file system permissions. You can restrict which users and groups can connect by setting permissions on the socket file.

```javascript
'use strict';

const net = require('node:net');
const fs = require('node:fs');

const SOCKET_PATH = '/tmp/secure-app.sock';

// Clean up stale socket
try { fs.unlinkSync(SOCKET_PATH); } catch { /* ignore */ }

const server = net.createServer((conn) => {
  conn.write('Welcome to the secure server\n');
  conn.on('data', (data) => {
    conn.write(`Echo: ${data}`);
  });
});

server.listen(SOCKET_PATH, () => {
  // Set permissions AFTER the socket is created
  // 0o700 = owner only (rwx------)
  // 0o770 = owner + group (rwxrwx---)
  // 0o777 = everyone (rwxrwxrwx) — avoid in production
  fs.chmodSync(SOCKET_PATH, 0o770);

  const stats = fs.statSync(SOCKET_PATH);
  console.log(`Socket created: ${SOCKET_PATH}`);
  console.log(`Permissions:    ${(stats.mode & 0o777).toString(8)}`);
  console.log(`Owner UID:      ${stats.uid}`);

  // Only processes running as the same user or in the same group
  // can connect to this socket. This is enforced by the kernel.
});
```

### Permission Gotcha: umask

The operating system's `umask` may strip permissions from the socket file. To ensure exact permissions:

```javascript
'use strict';

const net = require('node:net');
const fs = require('node:fs');

const SOCKET_PATH = '/tmp/precise-perms.sock';
try { fs.unlinkSync(SOCKET_PATH); } catch { /* ignore */ }

// Save and temporarily override umask
const originalUmask = process.umask(0o000);

const server = net.createServer((conn) => {
  conn.write('Connected\n');
});

server.listen(SOCKET_PATH, () => {
  // Restore original umask immediately
  process.umask(originalUmask);

  // Now set the exact permissions we want
  fs.chmodSync(SOCKET_PATH, 0o660);
  console.log('Socket created with exact 0660 permissions');
});
```

---

## Named Pipes on Different Platforms

Unix domain sockets are a POSIX concept. Windows uses a different mechanism: named pipes. Node.js `node:net` abstracts both behind the same API.

```javascript
'use strict';

const net = require('node:net');
const fs = require('node:fs');
const os = require('node:os');

/**
 * Generate a platform-appropriate IPC path.
 *
 * - POSIX:   /tmp/myapp.sock
 * - Windows: \\.\pipe\myapp
 */
function getIPCPath(name) {
  if (os.platform() === 'win32') {
    // Windows named pipes use a special path format
    return `\\\\.\\pipe\\${name}`;
  }
  // POSIX: use a socket file in /tmp
  return `/tmp/${name}.sock`;
}

const IPC_PATH = getIPCPath('myapp');
console.log(`Platform: ${os.platform()}`);
console.log(`IPC path: ${IPC_PATH}`);

// Clean up stale socket (only needed on POSIX — Windows pipes auto-clean)
if (os.platform() !== 'win32') {
  try { fs.unlinkSync(IPC_PATH); } catch { /* ignore */ }
}

// The server code is identical regardless of platform
const server = net.createServer((conn) => {
  console.log('Client connected via IPC');
  conn.on('data', (data) => {
    conn.write(`[${os.platform()}] Echo: ${data}`);
  });
  conn.on('end', () => console.log('Client disconnected'));
});

server.listen(IPC_PATH, () => {
  console.log(`IPC server listening on: ${IPC_PATH}`);
});

// Graceful shutdown
process.on('SIGINT', () => {
  server.close();
  if (os.platform() !== 'win32') {
    try { fs.unlinkSync(IPC_PATH); } catch { /* ignore */ }
  }
  process.exit(0);
});
```

---

## Performance Benchmark: Unix Socket vs TCP Localhost

```javascript
'use strict';

const net = require('node:net');
const fs = require('node:fs');
const { performance } = require('node:perf_hooks');

const SOCKET_PATH = '/tmp/bench.sock';
const TCP_PORT = 0; // Random available port
const ITERATIONS = 10_000;
const MESSAGE = Buffer.from('Hello from benchmark client\n');

try { fs.unlinkSync(SOCKET_PATH); } catch { /* ignore */ }

function createBenchServer(options) {
  return new Promise((resolve) => {
    const server = net.createServer((conn) => {
      conn.on('data', (data) => {
        conn.write(data); // Echo back
      });
    });
    server.listen(options, () => resolve(server));
  });
}

function runBenchmark(connectOptions, label) {
  return new Promise((resolve) => {
    const client = net.connect(connectOptions, () => {
      let received = 0;
      const start = performance.now();

      client.on('data', () => {
        received++;
        if (received >= ITERATIONS) {
          const elapsed = performance.now() - start;
          client.end();
          resolve({ label, elapsed, opsPerSec: (ITERATIONS / elapsed * 1000).toFixed(0) });
          return;
        }
        client.write(MESSAGE);
      });

      // Send the first message to start the ping-pong
      client.write(MESSAGE);
    });
  });
}

async function main() {
  console.log(`Benchmarking ${ITERATIONS} round-trip messages...\n`);

  // Start both servers
  const unixServer = await createBenchServer({ path: SOCKET_PATH });
  const tcpServer = await createBenchServer({ port: 0, host: '127.0.0.1' });
  const tcpPort = tcpServer.address().port;

  // Run Unix socket benchmark
  const unixResult = await runBenchmark({ path: SOCKET_PATH }, 'Unix Socket');
  console.log(`${unixResult.label}: ${unixResult.elapsed.toFixed(2)} ms (${unixResult.opsPerSec} ops/sec)`);

  // Run TCP benchmark
  const tcpResult = await runBenchmark({ port: tcpPort, host: '127.0.0.1' }, 'TCP localhost');
  console.log(`${tcpResult.label}: ${tcpResult.elapsed.toFixed(2)} ms (${tcpResult.opsPerSec} ops/sec)`);

  // Compare
  const speedup = (tcpResult.elapsed / unixResult.elapsed).toFixed(2);
  console.log(`\nUnix socket is ${speedup}x faster than TCP localhost`);

  // Cleanup
  unixServer.close();
  tcpServer.close();
  try { fs.unlinkSync(SOCKET_PATH); } catch { /* ignore */ }
}

main().catch(console.error);
```

Typical results on Linux/macOS show Unix domain sockets delivering 20-50% lower latency and higher throughput than TCP localhost for small messages. The gap narrows with larger payloads because the copy cost dominates.

---

## Practical Pattern: JSON-RPC Over Unix Socket

A common systems programming pattern is a daemon process that accepts JSON-RPC commands over a Unix socket. Docker, systemd, and many other tools use this pattern.

```javascript
'use strict';

const net = require('node:net');
const fs = require('node:fs');

const SOCKET_PATH = '/tmp/rpc-daemon.sock';
try { fs.unlinkSync(SOCKET_PATH); } catch { /* ignore */ }

// RPC method registry
const methods = {
  ping() {
    return { pong: true, timestamp: Date.now() };
  },

  status() {
    return {
      pid: process.pid,
      uptime: process.uptime(),
      memory: process.memoryUsage(),
      platform: process.platform,
    };
  },

  echo({ message }) {
    return { message };
  },
};

const server = net.createServer((conn) => {
  let buffer = '';

  conn.on('data', (data) => {
    buffer += data.toString();

    // Process newline-delimited JSON messages
    let newlineIndex;
    while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newlineIndex);
      buffer = buffer.slice(newlineIndex + 1);

      let request;
      try {
        request = JSON.parse(line);
      } catch {
        conn.write(JSON.stringify({ error: 'Invalid JSON' }) + '\n');
        continue;
      }

      const { id, method, params } = request;

      if (!methods[method]) {
        conn.write(JSON.stringify({
          id,
          error: `Unknown method: ${method}`,
        }) + '\n');
        continue;
      }

      try {
        const result = methods[method](params || {});
        conn.write(JSON.stringify({ id, result }) + '\n');
      } catch (err) {
        conn.write(JSON.stringify({ id, error: err.message }) + '\n');
      }
    }
  });
});

server.listen(SOCKET_PATH, () => {
  fs.chmodSync(SOCKET_PATH, 0o770);
  console.log(`RPC daemon listening on ${SOCKET_PATH}`);
});

process.on('SIGINT', () => {
  server.close();
  try { fs.unlinkSync(SOCKET_PATH); } catch { /* ignore */ }
  process.exit(0);
});
```

```javascript
'use strict';

// rpc-client.js — Send JSON-RPC requests to the daemon
const net = require('node:net');

const SOCKET_PATH = '/tmp/rpc-daemon.sock';
let requestId = 0;

function rpcCall(method, params = {}) {
  return new Promise((resolve, reject) => {
    const client = net.connect({ path: SOCKET_PATH });
    const id = ++requestId;
    let buffer = '';

    client.on('connect', () => {
      const request = JSON.stringify({ id, method, params });
      client.write(request + '\n');
    });

    client.on('data', (data) => {
      buffer += data.toString();
      const newlineIndex = buffer.indexOf('\n');
      if (newlineIndex !== -1) {
        const response = JSON.parse(buffer.slice(0, newlineIndex));
        client.end();
        if (response.error) {
          reject(new Error(response.error));
        } else {
          resolve(response.result);
        }
      }
    });

    client.on('error', reject);
  });
}

async function main() {
  const pong = await rpcCall('ping');
  console.log('Ping:', pong);

  const status = await rpcCall('status');
  console.log('Status:', JSON.stringify(status, null, 2));

  const echo = await rpcCall('echo', { message: 'Hello, daemon!' });
  console.log('Echo:', echo);

  try {
    await rpcCall('nonexistent');
  } catch (err) {
    console.log('Expected error:', err.message);
  }
}

main().catch(console.error);
```

---

## Abstract Sockets (Linux Only)

Linux supports abstract Unix domain sockets that do not create a file on disk. The path starts with a null byte (`\0`). The socket exists only in the kernel's namespace and is automatically cleaned up when the last file descriptor is closed.

```javascript
'use strict';

const net = require('node:net');
const os = require('node:os');

if (os.platform() !== 'linux') {
  console.log('Abstract sockets are Linux-only. Skipping demo.');
  process.exit(0);
}

// Abstract socket: path starts with \0
// Node.js represents this as a path starting with \0
const ABSTRACT_PATH = '\0myapp-abstract-socket';

const server = net.createServer((conn) => {
  conn.write('Connected to abstract socket\n');
  conn.on('data', (data) => conn.write(`Echo: ${data}`));
});

server.listen(ABSTRACT_PATH, () => {
  console.log('Listening on abstract socket (no file on disk)');
  console.log('No cleanup needed — kernel manages lifecycle');
});

// No fs.unlinkSync needed — the socket has no file system entry
process.on('SIGINT', () => {
  server.close();
  process.exit(0);
});
```

Abstract sockets solve the stale file problem entirely, but they are Linux-specific and cannot be secured with file permissions.

---

## Key Takeaways

- Unix domain sockets provide kernel-level IPC that bypasses the entire TCP/IP network stack, delivering 20-50% lower latency than TCP localhost for small messages
- The biggest operational risk is stale socket files after crashes — always implement robust cleanup with stale-socket detection (test-connect, then remove if `ECONNREFUSED`)
- Socket file permissions (`fs.chmodSync`) provide kernel-enforced access control that is simpler and more reliable than application-level authentication for local IPC
- Node.js `node:net` abstracts Unix domain sockets (POSIX) and named pipes (Windows) behind the same API — use a platform-detection helper to generate the correct path format
- JSON-RPC over Unix domain sockets is the standard pattern for local daemon communication, used by Docker, systemd, and countless other systems tools

## Next

In the next lesson, we go beyond message-passing IPC and share raw memory between processes using `SharedArrayBuffer` and `Atomics` — the fastest possible data sharing mechanism available in Node.js.
